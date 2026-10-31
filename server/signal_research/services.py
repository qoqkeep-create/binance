from __future__ import annotations

from statistics import mean, pstdev
from typing import Any, Iterable

from common.binance import binance_get_historical_candles, to_inst_id


TIMEFRAME_MS = {
    "1m": 60_000,
    "3m": 180_000,
    "5m": 300_000,
    "15m": 900_000,
    "1h": 3_600_000,
    "4h": 14_400_000,
    "1d": 86_400_000,
}
SUPPORTED_TIMEFRAMES = tuple(TIMEFRAME_MS)
STRATEGY_NAME = "EMA-SuperTrend 回踩策略 v1"


def _ema(values: list[float], period: int) -> list[float | None]:
    answer: list[float | None] = [None] * len(values)
    if len(values) < period:
        return answer
    multiplier = 2 / (period + 1)
    current = mean(values[:period])
    answer[period - 1] = current
    for index in range(period, len(values)):
        current = (values[index] - current) * multiplier + current
        answer[index] = current
    return answer


def _atr(candles: list[dict[str, Any]], period: int = 10) -> list[float | None]:
    answer: list[float | None] = [None] * len(candles)
    if len(candles) <= period:
        return answer
    ranges = [0.0] * len(candles)
    for index, candle in enumerate(candles):
        high, low = float(candle["high"]), float(candle["low"])
        prior_close = float(candles[index - 1]["close"]) if index else float(candle["close"])
        ranges[index] = max(high - low, abs(high - prior_close), abs(low - prior_close))
    current = mean(ranges[1 : period + 1])
    answer[period] = current
    for index in range(period + 1, len(candles)):
        current = ((current * (period - 1)) + ranges[index]) / period
        answer[index] = current
    return answer


def enrich_candles(raw_candles: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    candles = []
    for row in raw_candles:
        try:
            candles.append({
                "time": int(row["open_time"]) // 1000,
                "open_time": int(row["open_time"]),
                "close_time": int(row["close_time"]),
                "open": float(row["open"]), "high": float(row["high"]),
                "low": float(row["low"]), "close": float(row["close"]),
                "volume": float(row["volume"]),
            })
        except (KeyError, TypeError, ValueError):
            continue
    candles.sort(key=lambda item: item["open_time"])
    closes = [item["close"] for item in candles]
    ema21, ema55, ema144 = _ema(closes, 21), _ema(closes, 55), _ema(closes, 144)
    atr = _atr(candles)
    final_upper: list[float | None] = [None] * len(candles)
    final_lower: list[float | None] = [None] * len(candles)
    supertrend: list[float | None] = [None] * len(candles)
    trend: list[int | None] = [None] * len(candles)
    for i, candle in enumerate(candles):
        candle.update({"ema21": ema21[i], "ema55": ema55[i], "ema144": ema144[i], "atr10": atr[i]})
        if atr[i] is None:
            candle.update({"supertrend": None, "trend": None})
            continue
        midpoint = (candle["high"] + candle["low"]) / 2
        basic_upper, basic_lower = midpoint + 6 * atr[i], midpoint - 6 * atr[i]
        previous_close = candles[i - 1]["close"] if i else candle["close"]
        final_upper[i] = basic_upper if i == 0 or final_upper[i - 1] is None or basic_upper < final_upper[i - 1] or previous_close > final_upper[i - 1] else final_upper[i - 1]
        final_lower[i] = basic_lower if i == 0 or final_lower[i - 1] is None or basic_lower > final_lower[i - 1] or previous_close < final_lower[i - 1] else final_lower[i - 1]
        prior_trend = trend[i - 1] if i else 1
        if prior_trend == -1 and candle["close"] > final_upper[i]:
            trend[i] = 1
        elif prior_trend == 1 and candle["close"] < final_lower[i]:
            trend[i] = -1
        else:
            trend[i] = prior_trend or 1
        supertrend[i] = final_lower[i] if trend[i] == 1 else final_upper[i]
        candle.update({"supertrend": supertrend[i], "trend": trend[i]})
    return candles


def calculate_features(candles: list[dict[str, Any]], index: int) -> dict[str, Any]:
    candle = candles[index]
    if not candle.get("ema144") or not candle.get("atr10"):
        return {"ready": False}
    close, atr = candle["close"], candle["atr10"]
    start = max(0, index - 20)
    history = candles[start : index + 1]
    prior = candles[index - 1] if index else candle
    volume_avg = mean(item["volume"] for item in history[:-1] or history)
    volumes = [item["volume"] for item in history[:-1] or history]
    volume_std = pstdev(volumes) if len(volumes) > 1 else 0
    closes = [item["close"] for item in history]
    sma20 = mean(closes)
    close_std = pstdev(closes) if len(closes) > 1 else 0
    upper_band, lower_band = sma20 + 2 * close_std, sma20 - 2 * close_std
    returns = [((history[i]["close"] / history[i - 1]["close"]) - 1) for i in range(1, len(history)) if history[i - 1]["close"]]
    highest20, lowest20 = max(item["high"] for item in history), min(item["low"] for item in history)
    history55 = candles[max(0, index - 54) : index + 1]
    highest55, lowest55 = max(item["high"] for item in history55), min(item["low"] for item in history55)
    trend_age = 0
    for row in reversed(candles[: index + 1]):
        if row.get("trend") != candle.get("trend"):
            break
        trend_age += 1
    body = candle["close"] - candle["open"]
    range_value = max(candle["high"] - candle["low"], 1e-12)
    close_location = (candle["close"] - candle["low"]) / range_value
    ema21_20 = candles[max(0, index - 20)]["ema21"]
    return {
        "ready": True,
        "trend": "多头" if candle["trend"] == 1 else "空头",
        "supertrend_flip": ("空转多" if candle["trend"] == 1 else "多转空") if prior.get("trend") != candle.get("trend") else "无",
        "ema_alignment": "多头排列" if candle["ema21"] > candle["ema55"] > candle["ema144"] else "空头排列" if candle["ema21"] < candle["ema55"] < candle["ema144"] else "混合",
        "close_to_ema21_atr": round((close - candle["ema21"]) / atr, 3),
        "close_to_ema55_atr": round((close - candle["ema55"]) / atr, 3),
        "close_to_ema144_atr": round((close - candle["ema144"]) / atr, 3),
        "ema21_slope_5": round((candle["ema21"] - candles[max(0, index - 5)]["ema21"]) / atr, 3),
        "ema21_slope_10_atr": round((candle["ema21"] - candles[max(0, index - 10)]["ema21"]) / atr, 3),
        "ema21_slope_20_atr": round((candle["ema21"] - ema21_20) / atr, 3),
        "ema21_55_gap_atr": round((candle["ema21"] - candle["ema55"]) / atr, 3),
        "ema55_144_gap_atr": round((candle["ema55"] - candle["ema144"]) / atr, 3),
        "supertrend_age_bars": trend_age,
        "atr_percent": round(atr / close * 100, 3),
        "range_atr": round((candle["high"] - candle["low"]) / atr, 3),
        "volume_ratio_20": round(candle["volume"] / volume_avg, 3) if volume_avg else 0,
        "volume_zscore_20": round((candle["volume"] - volume_avg) / volume_std, 3) if volume_std else 0,
        "return_1_pct": round((close / prior["close"] - 1) * 100, 3) if prior["close"] else 0,
        "return_5_pct": round((close / candles[max(0, index - 5)]["close"] - 1) * 100, 3),
        "return_20_pct": round((close / candles[max(0, index - 20)]["close"] - 1) * 100, 3),
        "realized_volatility_20_pct": round(pstdev(returns) * 100, 3) if len(returns) > 1 else 0,
        "close_position_20": round((close - lowest20) / (highest20 - lowest20), 3) if highest20 > lowest20 else 0.5,
        "close_position_55": round((close - lowest55) / (highest55 - lowest55), 3) if highest55 > lowest55 else 0.5,
        "drawdown_from_20_high_pct": round((close / highest20 - 1) * 100, 3),
        "upside_from_20_low_pct": round((close / lowest20 - 1) * 100, 3),
        "bollinger_width_pct": round((upper_band - lower_band) / sma20 * 100, 3) if sma20 else 0,
        "bollinger_percent_b": round((close - lower_band) / (upper_band - lower_band), 3) if upper_band > lower_band else 0.5,
        "body_atr": round(body / atr, 3),
        "upper_wick_atr": round((candle["high"] - max(candle["open"], close)) / atr, 3),
        "lower_wick_atr": round((min(candle["open"], close) - candle["low"]) / atr, 3),
        "close_location_value": round(close_location, 3),
        "pullback_to_ema21": candle["low"] <= candle["ema21"] <= candle["high"],
        "close": close,
    }


def strategy_signal(candles: list[dict[str, Any]], index: int, definition: dict[str, Any] | None = None) -> str | None:
    """Closed-bar-only v1 rule: recent SuperTrend flip + aligned EMA + EMA21 retest."""
    if index < 1 or not all(candles[index].get(key) is not None for key in ("ema21", "ema55", "ema144", "atr10", "trend")):
        return None
    definition = definition or {}
    flip_window = max(1, min(20, int(definition.get("flip_window", 8))))
    min_gap = max(0.0, float(definition.get("min_ema_gap_atr", 0)))
    max_distance = max(0.05, float(definition.get("max_close_distance_atr", 0.35)))
    align_144 = bool(definition.get("require_ema144_alignment", False))
    row = candles[index]
    flips = [candles[j].get("trend") for j in range(max(1, index - flip_window), index + 1) if candles[j].get("trend") != candles[j - 1].get("trend")]
    long_flip = 1 in flips
    short_flip = -1 in flips
    long_alignment = row["ema21"] > row["ema55"] and (not align_144 or row["ema55"] > row["ema144"])
    short_alignment = row["ema21"] < row["ema55"] and (not align_144 or row["ema55"] < row["ema144"])
    close_distance = abs(row["close"] - row["ema21"]) / row["atr10"]
    gap = abs(row["ema21"] - row["ema55"]) / row["atr10"]
    if row["trend"] == 1 and long_flip and long_alignment and gap >= min_gap and close_distance <= max_distance and row["low"] <= row["ema21"] and row["close"] > row["ema21"]:
        return "long"
    if row["trend"] == -1 and short_flip and short_alignment and gap >= min_gap and close_distance <= max_distance and row["high"] >= row["ema21"] and row["close"] < row["ema21"]:
        return "short"
    return None


def fetch_candles(symbol: str, timeframe: str, *, end_time_ms: int | None = None, start_time_ms: int | None = None, limit: int = 500) -> list[dict[str, Any]]:
    if start_time_ms is None or end_time_ms is None:
        rows = binance_get_historical_candles(to_inst_id(symbol), bar=timeframe, limit=limit, end_time=end_time_ms, start_time=start_time_ms)
        return enrich_candles(rows)
    rows: list[dict[str, str]] = []
    cursor = start_time_ms
    interval = TIMEFRAME_MS[timeframe]
    while cursor <= end_time_ms:
        batch = binance_get_historical_candles(
            to_inst_id(symbol), bar=timeframe, limit=1500, start_time=cursor, end_time=end_time_ms
        )
        if not batch:
            break
        rows.extend(batch)
        next_cursor = int(batch[-1]["open_time"]) + interval
        if next_cursor <= cursor:
            break
        cursor = next_cursor
        if len(batch) < 1500:
            break
    unique_rows = {int(row["open_time"]): row for row in rows}
    return enrich_candles(unique_rows.values())


def candle_payload(candles: list[dict[str, Any]]) -> list[dict[str, Any]]:
    keys = ("time", "open_time", "close_time", "open", "high", "low", "close", "volume", "ema21", "ema55", "ema144", "atr10", "supertrend", "trend")
    return [{key: row.get(key) for key in keys} for row in candles]


def scan_backtest(symbol: str, timeframe: str, start_time_ms: int, end_time_ms: int, definition: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    warmup = 220 * TIMEFRAME_MS[timeframe]
    candles = fetch_candles(symbol, timeframe, start_time_ms=start_time_ms - warmup, end_time_ms=end_time_ms, limit=1500)
    results = []
    for index, candle in enumerate(candles):
        if candle["close_time"] < start_time_ms or candle["close_time"] > end_time_ms:
            continue
        side = strategy_signal(candles, index, definition)
        if side:
            results.append({"symbol": symbol, "timeframe": timeframe, "signal_time": candle["close_time"], "direction": side, "features": calculate_features(candles, index)})
    return results


def format_rule_text() -> list[str]:
    return [
        "SuperTrend（ATR 10、倍数 6）在最近 8 根已收盘 K 线内完成方向翻转。",
        "做多：当前趋势为多，EMA21 > EMA55，K 线最低价回踩 EMA21 后收盘重新站上 EMA21。",
        "做空：当前趋势为空，EMA21 < EMA55，K 线最高价反弹至 EMA21 后收盘重新跌回 EMA21 下方。",
        "仅在 K 线收盘后确认；策略不会使用当前 K 线之后的数据。",
    ]
