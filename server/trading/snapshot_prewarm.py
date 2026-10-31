"""预热公开 K 线快照的 CDN 缓存，消除首屏历史 K 线的跨境回源。

主站公开快照 `/market-data/klines/<SYMBOL>/<interval>.json` 由阿里云 CDN 缓存；
边缘及其 L2 层都未命中时需回源到境外源站（新加坡）。实测跨境未命中时 27KB 的
1h 快照 20 秒仍传不完，命中时约 0.07 秒。本任务按各周期 s-maxage 的节奏请求
该公开 URL，使 CDN 始终保有可用副本；用户首屏即使正遇边缘过期，也由 CDN 直接
返回或走 stale-while-revalidate，不再同步跨境回源。

请求的是公开行情 URL，不带任何凭证；命中 CDN 不回源，回源时后端先读共享缓存，
因此不会额外增加 Binance 调用。
"""
from __future__ import annotations

import logging
import os
import time
from concurrent.futures import ThreadPoolExecutor
from urllib import request as urlrequest

from django.conf import settings
from django.core.cache import cache

from common.errors import safe_error_summary
from trading.constants import ALLOWED_TRADING_SYMBOLS, PINNED_TRADING_SYMBOLS

logger = logging.getLogger(__name__)

# 取各周期 s-maxage 再加一点宽限：CDN 副本在第 S 秒过期，那次之后的第一个预热
# 请求（约第 S+30 秒）才重新回源，所以「副本已过期」的窗口约为这 30 秒。节奏
# 若短于 s-maxage，命中不会续期，过期后反而要等到下一个整周期才补热，窗口更大。
SNAPSHOT_PREWARM_CADENCE_SECONDS = {
    "3m": 150,
    "15m": 630,
    "1h": 1830,
    "4h": 7230,
    "1d": 21630,
}
SNAPSHOT_PREWARM_MARKER_PREFIX = "trade:market-snapshot-prewarm"
SNAPSHOT_PREWARM_TIMEOUT_SECONDS = float(os.getenv("MARKET_SNAPSHOT_PREWARM_TIMEOUT_SECONDS", "15"))
# 每轮批量必须不小于置顶币种数：同一周期的全部组合会同时到期，若每轮只取一部分，
# 按序靠后的币种会被持续饿死、副本长期过期（真实并发由下面的 worker 数限制）。
SNAPSHOT_PREWARM_BATCH_SIZE = max(1, int(os.getenv("MARKET_SNAPSHOT_PREWARM_BATCH_SIZE", "24")))
# 并发发出，让一轮请求以「最慢一条」而非「累加」计时；否则冷启动时
# 数条跨境回源会把单轮拖到数分钟，后续轮次被跳过、CDN 副本出现空窗。
SNAPSHOT_PREWARM_MAX_WORKERS = max(1, int(os.getenv("MARKET_SNAPSHOT_PREWARM_MAX_WORKERS", "8")))


def _prewarm_due(now: float) -> list[tuple[float, str, str, int]]:
    due: list[tuple[float, str, str, int]] = []
    for symbol in PINNED_TRADING_SYMBOLS:
        if symbol not in ALLOWED_TRADING_SYMBOLS:
            continue
        for interval, cadence in SNAPSHOT_PREWARM_CADENCE_SECONDS.items():
            try:
                marked = cache.get(f"{SNAPSHOT_PREWARM_MARKER_PREFIX}:{symbol}:{interval}")
                last = float(marked) if marked is not None else 0.0
            except Exception:  # noqa: BLE001
                last = 0.0
            if now - last >= cadence:
                due.append((last, symbol, interval, cadence))
    due.sort()
    return due


def _prewarm_once(base_url: str, symbol: str, interval: str, cadence: int, now: float) -> bool:
    url = f"{base_url}/market-data/klines/{symbol}/{interval}.json"
    succeeded = True
    try:
        with urlrequest.urlopen(url, timeout=SNAPSHOT_PREWARM_TIMEOUT_SECONDS) as response:
            response.read()
    except Exception as exc:  # noqa: BLE001
        succeeded = False
        logger.warning("公开快照 CDN 预热失败 %s %s: %s", symbol, interval, safe_error_summary(exc))
    try:
        # 无论成败都记录尝试时间，避免持续失败时每轮重试造成请求风暴。
        cache.set(f"{SNAPSHOT_PREWARM_MARKER_PREFIX}:{symbol}:{interval}", now, timeout=cadence * 2)
    except Exception:  # noqa: BLE001
        pass
    return succeeded


def prewarm_public_snapshot_caches() -> dict[str, int]:
    """scheduler 定时调用：按周期节奏请求公开快照 URL，保持 CDN 副本常热。"""
    result = {"checked": 0, "warmed": 0, "failed": 0}
    if not getattr(settings, "MARKET_SNAPSHOT_PREWARM_ENABLED", False):
        return result
    base_url = str(getattr(settings, "MARKET_SNAPSHOT_PREWARM_URL", "") or "").rstrip("/")
    if not base_url:
        return result

    now = time.time()
    due = _prewarm_due(now)
    result["checked"] = len(due)
    batch = due[:SNAPSHOT_PREWARM_BATCH_SIZE]
    if not batch:
        return result
    workers = min(SNAPSHOT_PREWARM_MAX_WORKERS, len(batch))
    with ThreadPoolExecutor(max_workers=workers) as pool:
        outcomes = list(
            pool.map(lambda item: _prewarm_once(base_url, item[1], item[2], item[3], now), batch)
        )
    result["warmed"] = sum(1 for succeeded in outcomes if succeeded)
    result["failed"] = len(outcomes) - result["warmed"]
    return result
