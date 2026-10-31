"""Short-lived public market snapshots, independent of trading and warmup locks."""

import logging
import time
from collections.abc import Callable
from uuid import uuid4

from django.core.cache import cache

logger = logging.getLogger(__name__)


class SnapshotBusy(Exception):
    pass


def fresh_snapshot(key: str, fetch: Callable[[], dict], valid: Callable[[object], bool]) -> dict:
    key = f"{key}:fresh"
    cached = cache.get(key)
    if valid(cached):
        return cached

    lock_key = f"{key}:lock"
    token = uuid4().hex
    if not cache.add(lock_key, token, timeout=60):
        # Bound waiter occupancy; clients already retry on their polling cadence.
        for _ in range(20):
            time.sleep(0.05)
            cached = cache.get(key)
            if valid(cached):
                return cached
        raise SnapshotBusy

    try:
        cached = cache.get(key)
        if valid(cached):
            return cached
        data = fetch()
        cache.set(key, data, timeout=2)
        return data
    finally:
        try:
            if cache.get(lock_key) == token:
                cache.delete(lock_key)
        except Exception:  # noqa: BLE001
            logger.warning("release market snapshot lock failed")
