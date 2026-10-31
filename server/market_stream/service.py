import logging
import time

from django.conf import settings
from django.core.cache import cache
from django.db import close_old_connections, connection, transaction

from common.binance import BinanceCredentials, BinanceFuturesClient
from market_stream import bus
from market_stream.core import INTERVAL_MS, PRICE_FIELDS, aggregate_complete, rest_candle, wire_candle
from market_stream.models import MarketCandle

log = logging.getLogger(__name__)
FIELD_MAP = dict(zip(PRICE_FIELDS, ("open_price", "high_price", "low_price", "close_price", "volume", "quote_volume")))
RETENTION_DAYS = {"1m": 7, "5m": 14, "15m": 30, "1h": 90, "4h": 180, "1d": 365}


def public_request(path, query=None):
    client = BinanceFuturesClient(BinanceCredentials("", ""))
    return client._request("GET", path, query=query, signed=False, budget_priority="background")


def symbols(refresh=False):
    key = "market:universe"
    result = cache.get(key)
    if result is None or refresh:
        info = public_request("/fapi/v1/exchangeInfo")
        result = sorted(row["symbol"] for row in info["symbols"] if row.get("status") == "TRADING"
                        and row.get("contractType") == "PERPETUAL" and row.get("quoteAsset") == settings.MARKET_QUOTE_ASSET)
        cache.set(key, result, 300)
    return result


def ticker_payload(raw, now=None):
    return {"symbol": raw["s"] if "s" in raw else raw["symbol"],
            "lastPrice": float(raw.get("c", raw.get("lastPrice", 0))),
            "quoteVolume24h": float(raw.get("q", raw.get("quoteVolume", 0))),
            "priceChangePercent24h": float(raw.get("P", raw.get("priceChangePercent", 0))),
            "eventTime": int(raw.get("E", now or time.time() * 1000))}


def update_tickers(rows, *, emit=True):
    allowed = set(symbols())
    current = cache.get("market:tickers", {})
    updates = []
    for raw in rows:
        item = ticker_payload(raw)
        old = current.get(item["symbol"])
        if item["symbol"] in allowed and (old is None or item["eventTime"] >= old["eventTime"]):
            current[item["symbol"]] = item
            updates.append(item)
    cache.set("market:tickers", current, 86400)
    if emit:
        for item in updates:
            bus.publish(bus.event("market.ticker", item["symbol"], item))
    return current


def tickers():
    current = cache.get("market:tickers")
    if not current:
        current = update_tickers(public_request("/fapi/v1/ticker/24hr"), emit=False)
    return sorted(current.values(), key=lambda row: row["quoteVolume24h"], reverse=True)


def from_model(row):
    return {"symbol": row.symbol, "contractType": "PERPETUAL", "interval": row.interval,
            "openTime": row.open_time, "closeTime": row.close_time, "closed": True,
            "eventTime": row.close_time, **{wire: str(getattr(row, field)) for wire, field in FIELD_MAP.items()}}


def persist(rows):
    closed = [row for row in rows if row["closed"]]
    if not closed:
        return
    # Duplicate close events and REST repair share the same database identity.
    objects = [MarketCandle(symbol=row["symbol"], interval=row["interval"],
                            open_time=row["openTime"], close_time=row["closeTime"],
                            **{field: row[wire] for wire, field in FIELD_MAP.items()}) for row in closed]
    MarketCandle.objects.bulk_create(objects, update_conflicts=True,
                                    update_fields=["close_time", *FIELD_MAP.values()],
                                    unique_fields=["symbol", "interval", "open_time"] if connection.vendor != "mysql" else None)


def load_history(symbol, interval, limit=300, before=None):
    now = int(time.time() * 1000)
    key = f"market:history:{symbol}:{interval}:{limit}:{before or 'latest'}"
    hit = cache.get(key)
    if hit is not None:
        return hit
    query = MarketCandle.objects.filter(symbol=symbol, interval=interval)
    if before is not None:
        query = query.filter(open_time__lt=before)
    stored = [from_model(row) for row in reversed(list(query.order_by("-open_time")[:limit]))]
    width = INTERVAL_MS[interval]
    latest_closed_open = now // width * width - width
    stale = before is None and (not stored or stored[-1]["openTime"] < latest_closed_open)
    gaps = any(b["openTime"] - a["openTime"] != width for a, b in zip(stored, stored[1:]))
    if len(stored) < limit or stale or gaps:
        params = {"pair": symbol, "contractType": "PERPETUAL", "interval": interval, "limit": limit}
        if before is not None:
            params["endTime"] = before - 1
        try:
            raw = public_request("/fapi/v1/continuousKlines", params)
            received = [rest_candle(symbol, interval, row, now) for row in raw]
            with transaction.atomic():
                persist(received)
            merged = {row["openTime"]: row for row in stored}
            merged.update({row["openTime"]: row for row in received})
            stored = sorted(merged.values(), key=lambda row: row["openTime"])[-limit:]
        except Exception:
            if not stored:
                raise
            log.warning("Market history repair deferred symbol=%s interval=%s", symbol, interval)
    if before is None:
        live = cache.get(f"market:live:{symbol}:{interval}")
        if live and live["openTime"] >= now // width * width:
            merged = {row["openTime"]: row for row in stored}
            merged[live["openTime"]] = live
            stored = sorted(merged.values(), key=lambda row: row["openTime"])[-limit:]
    result = {"symbol": symbol, "interval": interval, "items": [wire_candle(row) for row in stored],
              "lastOpenTime": stored[-1]["openTime"] if stored else None,
              "serverTime": now, "stale": not stored or stored[-1]["openTime"] < latest_closed_open}
    cache.set(key, result, 2 if before is None else 300)
    return result


def repair_minute_gaps(symbol, *, now=None):
    """Repair one bounded page per pass, including gaps older than the warm tail."""
    close_old_connections()
    try:
        now = int(time.time() * 1000) if now is None else now
        retained = now - RETENTION_DAYS["1m"] * 86400000
        times = MarketCandle.objects.filter(symbol=symbol, interval="1m", open_time__gte=retained).order_by("open_time").values_list("open_time", flat=True)
        previous = None
        for at in times.iterator(chunk_size=2000):
            if previous is not None and at > previous + 60000:
                start = previous + 60000
                end = min(at-1, start+1000*60000-1)
                raw = public_request("/fapi/v1/continuousKlines", {"pair": symbol, "contractType": "PERPETUAL",
                    "interval": "1m", "startTime": start, "endTime": end, "limit": 1000})
                rows = [rest_candle(symbol, "1m", row, now) for row in raw if start <= row[0] <= end]
                with transaction.atomic():
                    persist(rows)
                return len(rows)
            previous = at
        return 0
    finally:
        close_old_connections()


def prune_history(*, now=None, batch_size=2000):
    now = int(time.time()*1000) if now is None else now
    close_old_connections()
    try:
        for interval, days in RETENTION_DAYS.items():
            for _ in range(100):
                ids = list(MarketCandle.objects.filter(interval=interval, open_time__lt=now-days*86400000)
                    .order_by("id").values_list("id", flat=True)[:batch_size])
                if not ids:
                    break
                MarketCandle.objects.filter(id__in=ids).delete()
    finally:
        close_old_connections()


def consume_batch(rows):
    close_old_connections()
    try:
        with transaction.atomic():
            persist(rows)
        for row in rows:
            key = f"market:live:{row['symbol']}:{row['interval']}"
            previous = cache.get(key)
            if previous and (row["openTime"], row["eventTime"]) < (previous["openTime"], previous["eventTime"]):
                continue
            cache.set(key, row, 180)
            bus.publish(bus.event("market.kline", f"{row['symbol']}:{row['interval']}", wire_candle(row)))
            if row["closed"] and row["interval"] == "1m":
                aggregate_closed(row)
    finally:
        close_old_connections()


def aggregate_closed(last):
    end = last["openTime"] + 60000
    for interval, width in INTERVAL_MS.items():
        if interval == "1m" or end % width:
            continue
        minutes = MarketCandle.objects.filter(symbol=last["symbol"], interval="1m",
                                               open_time__gte=end-width, open_time__lt=end).order_by("open_time")
        result = aggregate_complete([from_model(row) for row in minutes], interval)
        if result:
            with transaction.atomic():
                persist([result])
            cache.set(f"market:live:{last['symbol']}:{interval}", result, 180)
            bus.publish(bus.event("market.kline", f"{last['symbol']}:{interval}", wire_candle(result)))
