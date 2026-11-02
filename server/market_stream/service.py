import logging
import time
from threading import RLock
from uuid import uuid4

from django.conf import settings
from django.core.cache import cache
from django.db import close_old_connections, connection, transaction

from common.binance import BinanceCredentials, BinanceFuturesClient
from market_stream import bus, history_cache
from market_stream.core import INTERVAL_MS, PRICE_FIELDS, aggregate_complete, rest_candle, wire_candle
from market_stream.models import MarketCandle, MarketSymbol

log = logging.getLogger(__name__)
FIELD_MAP = dict(zip(PRICE_FIELDS, ("open_price", "high_price", "low_price", "close_price", "volume", "quote_volume")))
RETENTION_DAYS = {"1m": 7, "3m": 7, "5m": 14, "15m": 30, "1h": 90, "4h": 180, "1d": 365}
# Every HTTP page is capped at 1500. Older history has a separate boundary key;
# materializing 3000 here only doubled cold reads and cache serialization work.
HOT_WINDOW_SIZE = {interval: 1500 for interval in INTERVAL_MS}
# All live-cache writers run in the single collector process. Keep its cache
# comparison/write/publication ordered, without holding this lock for DB I/O.
LIVE_STATE_LOCK = RLock()


def public_request(path, query=None):
    client = BinanceFuturesClient(BinanceCredentials("", ""))
    return client._request("GET", path, query=query, signed=False, budget_priority="background",
                           require_shared_budget=settings.USE_REDIS_CACHE)


def symbols(refresh=False, *, cached_only=False):
    key = "market:universe"
    result = cache.get(key)
    if result is None and cached_only:
        previous = cache.get("market:universe:last")
        if previous is not None:
            return previous
        return list(MarketSymbol.objects.filter(active=True, quote_asset=settings.MARKET_QUOTE_ASSET)
                    .order_by("symbol").values_list("symbol", flat=True))
    if result is None or refresh:
        info = public_request("/fapi/v1/exchangeInfo")
        result = sorted(row["symbol"] for row in info["symbols"] if row.get("status") == "TRADING"
                        and row.get("contractType") == "PERPETUAL" and row.get("quoteAsset") == settings.MARKET_QUOTE_ASSET)
        # Publish only complete, nonempty snapshots. Failed upstream reads keep
        # both the previous database directory and cache available to clients.
        if not result:
            raise ValueError("Empty market directory")
        if refresh:
            with transaction.atomic():
                MarketSymbol.objects.filter(quote_asset=settings.MARKET_QUOTE_ASSET).exclude(symbol__in=result).update(active=False)
                onboard = {row["symbol"]: int(row.get("onboardDate", 0)) for row in info["symbols"] if row["symbol"] in result}
                objects = [MarketSymbol(symbol=symbol, quote_asset=settings.MARKET_QUOTE_ASSET,
                                        onboard_date=onboard[symbol]) for symbol in result]
                MarketSymbol.objects.bulk_create(objects, update_conflicts=True,
                    update_fields=["quote_asset", "onboard_date", "active", "updated_at"],
                    unique_fields=["symbol"] if connection.vendor != "mysql" else None)
        cache.set(key, result, 300)
        cache.set("market:universe:last", result, 86400)
        cache.set("market:onboard", {row["symbol"]: int(row.get("onboardDate", 0))
                                     for row in info["symbols"] if row["symbol"] in result}, 86400)
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
        bus.publish_batch("market.ticker", [(item["symbol"], item) for item in updates])
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
    for symbol, interval in {(row["symbol"], row["interval"]) for row in closed}:
        transaction.on_commit(lambda key=f"market:revision:{symbol}:{interval}": cache.set(key, uuid4().hex, 86400))


def warm_history(symbol, interval, before=None, *, prewarm=False):
    """A shared, limit-independent hot window, also populated at startup."""
    revision = cache.get(f"market:revision:{symbol}:{interval}", "initial")
    key = f"market:history:v4:{symbol}:{interval}:{before or 'latest'}:{revision}"
    def read_window():
        query = MarketCandle.objects.filter(symbol=symbol, interval=interval)
        if before is not None:
            query = query.filter(open_time__lt=before)
        size = HOT_WINDOW_SIZE[interval] if before is None else 1500
        return [from_model(row) for row in reversed(list(query.order_by("-open_time")[:size]))]
    return history_cache.read_through(key, read_window, prewarm=prewarm)


def partial_bucket(symbol, interval, now):
    width = INTERVAL_MS[interval]
    start = now // width * width
    # Like USDC's selectClosedInRange: only read this forming bucket.
    # Warming 3000 unrelated minutes here made a cache miss delay first paint.
    source = MarketCandle.objects.filter(symbol=symbol, interval="1m",
        open_time__gte=start, open_time__lt=start + width).order_by("open_time")
    minutes = {row.open_time: from_model(row) for row in source}
    live = cache.get(f"market:live:{symbol}:1m")
    if live and start <= live["openTime"] <= now:
        minutes[live["openTime"]] = live
    ordered = sorted(minutes.values(), key=lambda row: row["openTime"])
    # Match USDC's local partial bucket without inventing missing minutes.
    if not ordered or [row["openTime"] for row in ordered] != list(range(start, ordered[-1]["openTime"] + 60000, 60000)):
        return None
    from market_stream.core import number
    return {**ordered[-1], "interval": interval, "openTime": start, "closeTime": start + width - 1,
            "openPrice": ordered[0]["openPrice"], "closed": False,
            "highPrice": str(max(number(row["highPrice"]) for row in ordered)),
            "lowPrice": str(min(number(row["lowPrice"]) for row in ordered)),
            "volume": str(sum((number(row["volume"]) for row in ordered), number(0))),
            "quoteVolume": str(sum((number(row["quoteVolume"]) for row in ordered), number(0)))}


def load_history(symbol, interval, limit=300, before=None, *, schedule_repair=True):
    """Read a local snapshot only. Exchange I/O belongs to the repair worker."""
    from market_stream import repair
    now = int(time.time() * 1000)
    width = INTERVAL_MS[interval]
    stored = warm_history(symbol, interval, before)[-limit:]
    latest_closed_open = now // width * width - width
    stale = before is None and (not stored or stored[-1]["openTime"] < latest_closed_open)
    gaps = any(b["openTime"] - a["openTime"] != width for a, b in zip(stored, stored[1:]))
    pending = False
    if schedule_repair and (len(stored) < limit or stale or gaps):
        task = repair.schedule(symbol, interval, before=before)
        pending = not task.completed_at or task.attempts > 0 or task.lease_until > time.time() or task.due_at <= time.time()
        if stale and task.completed_at and time.time() - task.completed_at >= 60:
            pending = True
    if before is None:
        live = cache.get(f"market:live:{symbol}:{interval}")
        if (not live or live["openTime"] < now // width * width) and interval != "1m":
            live = partial_bucket(symbol, interval, now)
        if live and live["openTime"] >= now // width * width:
            merged = {row["openTime"]: row for row in stored}
            merged[live["openTime"]] = live
            stored = sorted(merged.values(), key=lambda row: row["openTime"])[-limit:]
    return {"symbol": symbol, "interval": interval, "items": [wire_candle(row) for row in stored],
            "lastOpenTime": stored[-1]["openTime"] if stored else None,
            "serverTime": now, "stale": stale, "historyPending": pending,
            "hasMoreHistory": pending or len(stored) == limit}


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


def publish_live_batch(rows, *, emit=True):
    """No database access: live display never waits for closed-bar storage."""
    if not rows:
        return
    with LIVE_STATE_LOCK:
        previous_rows = cache.get_many([f"market:live:{row['symbol']}:{row['interval']}" for row in rows])
        updates, events = {}, []
        for row in rows:
            key = f"market:live:{row['symbol']}:{row['interval']}"
            previous = previous_rows.get(key)
            if previous and not row["closed"] and (
                (row["openTime"], row["eventTime"]) < (previous["openTime"], previous["eventTime"])
                or (previous["closed"] and previous["openTime"] == row["openTime"])
            ):
                continue
            if not previous or (row["openTime"], row["eventTime"]) >= (previous["openTime"], previous["eventTime"]) or (
                row["closed"] and row["openTime"] == previous["openTime"]
            ):
                updates[key] = row
                previous_rows[key] = row
            events.append((f"{row['symbol']}:{row['interval']}", wire_candle(row)))
        cache.set_many(updates, 180)
        if emit:
            bus.publish_batch("market.kline", events)


def consume_batch(rows):
    close_old_connections()
    try:
        live = [row for row in rows if not row["closed"]]
        closed = [row for row in rows if row["closed"]]
        publish_live_batch(live)
        if not closed:
            return
        with transaction.atomic():
            persist(closed)
        publish_live_batch(closed)
        for row in closed:
            if row["interval"] == "1m":
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
            publish_live_batch([result])
