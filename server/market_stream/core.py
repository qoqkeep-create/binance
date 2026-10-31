"""Binance and iOS wire formats, independent of network and persistence."""
from decimal import Decimal, InvalidOperation
import re

INTERVAL_MS = {"1m": 60_000, "5m": 300_000, "15m": 900_000, "1h": 3_600_000, "4h": 14_400_000, "1d": 86_400_000}
PRICE_FIELDS = ("openPrice", "highPrice", "lowPrice", "closePrice", "volume", "quoteVolume")


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


def aggregate_complete(minutes, interval):
    """Only complete, contiguous, closed 1m buckets become persisted candles."""
    width = INTERVAL_MS[interval]
    if not minutes:
        return None
    ordered = sorted(minutes, key=lambda row: row["openTime"])
    start = ordered[0]["openTime"] // width * width
    expected = list(range(start, start + width, 60_000))
    if [row["openTime"] for row in ordered] != expected or not all(row["closed"] for row in ordered):
        return None
    return {**ordered[-1], "interval": interval, "openTime": start, "closeTime": start + width - 1,
            "openPrice": ordered[0]["openPrice"],
            "highPrice": str(max(number(row["highPrice"]) for row in ordered)),
            "lowPrice": str(min(number(row["lowPrice"]) for row in ordered)),
            "closePrice": ordered[-1]["closePrice"],
            "volume": str(sum((number(row["volume"]) for row in ordered), Decimal(0))),
            "quoteVolume": str(sum((number(row["quoteVolume"]) for row in ordered), Decimal(0))), "closed": True}
