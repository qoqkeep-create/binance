"""Public derivatives panels use the Java client's field and time-bucket contract."""
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
import logging
import math

from django.core.cache import cache
from market_stream.core import INTERVAL_MS
from market_stream.service import public_request

log = logging.getLogger(__name__)
POOL = ThreadPoolExecutor(max_workers=6, thread_name_prefix="market-statistics")
SERIES = {
    "openInterest": ("openInterestHist", {"sumOpenInterest": "openInterest", "sumOpenInterestValue": "openInterestNotional"}),
    "topAccountRatio": ("topLongShortAccountRatio", {"longAccount": "topLongAccount", "shortAccount": "topShortAccount", "longShortRatio": "topLongShortAccountRatio"}),
    "topPositionRatio": ("topLongShortPositionRatio", {"longAccount": "topLongPosition", "shortAccount": "topShortPosition", "longShortRatio": "topLongShortPositionRatio"}),
    "globalAccountRatio": ("globalLongShortAccountRatio", {"longAccount": "globalLongAccount", "shortAccount": "globalShortAccount", "longShortRatio": "globalLongShortAccountRatio"}),
    "buySellVolume": ("takerlongshortRatio", {"buyVol": "takerBuyVolume", "sellVol": "takerSellVolume"}),
    "basis": ("basis", {"basis": "basis", "basisRate": "basisRate", "futuresPrice": "futuresPrice", "indexPrice": "indexPrice"}),
}


def attach(result, requested):
    if not requested or result["interval"] == "1m" or not result["items"]:
        return result
    symbol, interval = result["symbol"], result["interval"]
    end = result["items"][-1]["closeTime"]
    start = result["items"][0]["openTime"]
    def load(name):
        endpoint, fields = SERIES[name]
        key = f"market:stats:{symbol}:{interval}:{name}:{start}:{end // 60000}"
        rows = cache.get(key)
        if rows is None:
            params = {"period": interval, "limit": 500, "startTime": start, "endTime": end}
            params.update({"pair": symbol, "contractType": "PERPETUAL"} if name == "basis" else {"symbol": symbol})
            try:
                rows = public_request(f"/futures/data/{endpoint}", params)
                if not isinstance(rows, list):
                    rows = []
                cache.set(key, rows, 30)
            except Exception as exc:
                log.warning("Market statistics unavailable symbol=%s series=%s (%s)", symbol, name, type(exc).__name__)
                rows = []
        return rows, fields
    futures = [POOL.submit(load, name) for name in sorted(requested)]
    by_time = {}
    width = INTERVAL_MS[interval]
    for future in futures:
        rows, fields = future.result()
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
    for candle in result["items"]:
        if candle["openTime"] in by_time:
            candle["tradingData"] = by_time[candle["openTime"]]
    return result
