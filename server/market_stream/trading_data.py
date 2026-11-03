"""Public derivatives panels use the Java client's field and time-bucket contract."""
from copy import deepcopy
import math

from django.core.cache import cache
from market_stream.core import INTERVAL_MS
from market_stream.service import public_request

SERIES = {
    "openInterest": ("openInterestHist", {"sumOpenInterest": "openInterest", "sumOpenInterestValue": "openInterestNotional"}),
    "topAccountRatio": ("topLongShortAccountRatio", {"longAccount": "topLongAccount", "shortAccount": "topShortAccount", "longShortRatio": "topLongShortAccountRatio"}),
    "topPositionRatio": ("topLongShortPositionRatio", {"longAccount": "topLongPosition", "shortAccount": "topShortPosition", "longShortRatio": "topLongShortPositionRatio"}),
    "globalAccountRatio": ("globalLongShortAccountRatio", {"longAccount": "globalLongAccount", "shortAccount": "globalShortAccount", "longShortRatio": "globalLongShortAccountRatio"}),
    "buySellVolume": ("takerlongshortRatio", {"buyVol": "takerBuyVolume", "sellVol": "takerSellVolume"}),
    "basis": ("basis", {"basis": "basis", "basisRate": "basisRate", "futuresPrice": "futuresPrice", "indexPrice": "indexPrice"}),
}

STATISTICS_INTERVALS = {"5m", "15m", "30m", "1h", "2h", "4h", "1d"}


def series_key(result, name):
    # Aligned to the selected candle, rather than the volatile live close time.
    end = result["items"][-1]["openTime"]
    return f"market:stats:v2:{result['symbol']}:{result['interval']}:{name}:{end}"


def load_series(result, name):
    """Collector-only public REST request; never called in an HTTP read."""
    if not result["items"] or result["interval"] not in STATISTICS_INTERVALS:
        return
    endpoint, _ = SERIES[name]
    params = {"period": result["interval"], "limit": 500,
              "endTime": result["items"][-1]["closeTime"]}
    params.update({"pair": result["symbol"], "contractType": "PERPETUAL"} if name == "basis" else {"symbol": result["symbol"]})
    rows = public_request(f"/futures/data/{endpoint}", params)
    if not isinstance(rows, list):
        raise ValueError("Invalid market statistics response")
    cache.set(series_key(result, name), rows, 30)


def attach(result, requested):
    from market_stream import repair
    if not requested or result["interval"] not in STATISTICS_INTERVALS or not result["items"]:
        return result
    by_time = {}
    pending = False
    width = INTERVAL_MS[result["interval"]]
    for name in sorted(requested):
        rows = cache.get(series_key(result, name))
        if rows is None:
            repair.schedule(result["symbol"], result["interval"], kind=f"stats:{name}")
            pending = True
            continue
        _, fields = SERIES[name]
        for row in rows:
            timestamp = int(row.get("timestamp", 0)) // width * width
            values = by_time.setdefault(timestamp, {})
            for source, target in fields.items():
                try:
                    value = float(row[source])
                    if math.isfinite(value):
                        values[target] = value
                except (ValueError, TypeError, KeyError):
                    pass
    result = deepcopy(result)
    result["statisticsPending"] = pending
    for candle in result["items"]:
        if candle["openTime"] in by_time:
            candle["tradingData"] = by_time[candle["openTime"]]
    return result
