"""Binance and iOS wire formats, independent of network and persistence."""
from decimal import Decimal, InvalidOperation
import re

INTERVAL_MS = {"1m": 60_000, "3m": 180_000, "5m": 300_000, "15m": 900_000, "30m": 1_800_000,
               "1h": 3_600_000, "2h": 7_200_000, "4h": 14_400_000, "8h": 28_800_000,
               "16h": 57_600_000, "1d": 86_400_000, "3d": 259_200_000, "1w": 604_800_000}
# Preserve the existing startup repair/warmup budget. Additional periods load on demand.
PREWARM_INTERVALS = ("1m", "3m", "5m", "15m", "1h", "4h", "1d")
PRICE_FIELDS = ("openPrice", "highPrice", "lowPrice", "closePrice", "volume", "quoteVolume")


def bucket_open_time(timestamp, interval):
    offset = 345_600_000 if interval == "1w" else 0  # Monday 00:00 UTC
    width = INTERVAL_MS[interval]
    return (timestamp - offset) // width * width + offset


def number(value):
    try:
        parsed = Decimal(str(value))
        if not parsed.is_finite() or parsed < 0:
            raise ValueError("Invalid nonnegative market number")
        return parsed
    except (InvalidOperation, TypeError) as exc:
        raise ValueError("Invalid market number") from exc


def symbol_name(value, quote_asset):
    name = str(value).upper()
    if not re.fullmatch(r"[A-Z0-9]{2,32}", name) or not name.endswith(quote_asset):
        raise ValueError("交易对不属于当前报价资产")
    return name


def normalize_kline(event):
    raw = event["k"]
    interval = raw["i"]
    if interval not in INTERVAL_MS:
        raise ValueError("Unsupported interval")
    result = {"symbol": event.get("ps") or raw.get("s"), "contractType": "PERPETUAL",
              "interval": interval, "eventTime": int(event["E"]), "openTime": int(raw["t"]),
              "closeTime": int(raw["T"]), "closed": bool(raw["x"])}
    for key, source in zip(PRICE_FIELDS, ("o", "h", "l", "c", "v", "q")):
        result[key] = str(number(raw[source]))
    return result


def rest_candle(symbol, interval, row, now):
    result = {"symbol": symbol, "contractType": "PERPETUAL", "interval": interval,
              "openTime": int(row[0]), "closeTime": int(row[6]), "eventTime": now,
              "closed": int(row[6]) < now}
    for key, index in zip(PRICE_FIELDS, (1, 2, 3, 4, 5, 7)):
        result[key] = str(number(row[index]))
    return result


def wire_candle(candle):
    return {**candle, **{key: float(candle[key]) for key in PRICE_FIELDS}}


def aggregate_complete(minutes, interval, source_interval="1m"):
    """Only complete, contiguous, closed source buckets become persisted candles."""
    return aggregate_bucket(minutes, interval, source_interval=source_interval)


def aggregate_bucket(rows, interval, *, source_interval="1m", partial=False):
    width = INTERVAL_MS[interval]
    step = INTERVAL_MS[source_interval]
    if not rows or width % step:
        return None
    ordered = sorted(rows, key=lambda row: row["openTime"])
    start = bucket_open_time(ordered[0]["openTime"], interval)
    end = ordered[-1]["openTime"] + step if partial else start + width
    expected = list(range(start, end, step))
    if end > start + width or [row["openTime"] for row in ordered] != expected:
        return None
    # The last forming source candle may be partial; earlier sources must be closed.
    if not all(row["closed"] for row in (ordered[:-1] if partial else ordered)):
        return None
    return {**ordered[-1], "interval": interval, "openTime": start, "closeTime": start + width - 1,
            "openPrice": ordered[0]["openPrice"],
            "highPrice": str(max(number(row["highPrice"]) for row in ordered)),
            "lowPrice": str(min(number(row["lowPrice"]) for row in ordered)),
            "closePrice": ordered[-1]["closePrice"],
            "volume": str(sum((number(row["volume"]) for row in ordered), Decimal(0))),
            "quoteVolume": str(sum((number(row["quoteVolume"]) for row in ordered), Decimal(0))), "closed": not partial}
