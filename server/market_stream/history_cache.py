"""Bounded public-history cache; never evict account locks or budget keys."""
import json
import time
import zlib
from threading import Lock

from redis.exceptions import RedisError

from django.conf import settings
from django.core.cache import cache

from market_stream import bus

MAX_WINDOWS = 64
MAX_WINDOW_BYTES = 256 * 1024
TTL = 300
INDEX = "market:history:v4:lru"

READ = """
local value = redis.call('GET', KEYS[1])
if value then
    redis.call('ZADD', KEYS[2], ARGV[1], KEYS[1])
    redis.call('EXPIRE', KEYS[1], ARGV[2])
    redis.call('EXPIRE', KEYS[2], ARGV[2] * 2)
else
    redis.call('ZREM', KEYS[2], KEYS[1])
end
return value
"""

WRITE = """
if ARGV[5] == '1' and redis.call('ZCARD', KEYS[2]) >= tonumber(ARGV[4])
    and redis.call('EXISTS', KEYS[1]) == 0 then return 0 end
redis.call('SET', KEYS[1], ARGV[1], 'EX', ARGV[2])
redis.call('ZADD', KEYS[2], ARGV[3], KEYS[1])
while redis.call('ZCARD', KEYS[2]) > tonumber(ARGV[4]) do
    local oldest = redis.call('ZPOPMIN', KEYS[2], 1)
    redis.call('DEL', oldest[1])
end
redis.call('EXPIRE', KEYS[2], ARGV[2] * 2)
return 1
"""


def get(key):
    if settings.USE_REDIS_CACHE:
        raw = bus.connection().eval(READ, 2, cache.make_key(key), cache.make_key(INDEX), time.time(), TTL)
    else:
        raw = cache.get(key)
    return json.loads(zlib.decompress(raw)) if raw is not None else None


def has_room():
    if not settings.USE_REDIS_CACHE:
        return True
    client = bus.connection()
    index = cache.make_key(INDEX)
    with client.pipeline() as pipe:
        pipe.zremrangebyscore(index, "-inf", time.time() - TTL)
        pipe.zcard(index)
        _, count = pipe.execute()
    return count < MAX_WINDOWS


def put(key, rows, *, prewarm=False):
    raw = zlib.compress(json.dumps(rows, separators=(",", ":")).encode(), level=1)
    if len(raw) > MAX_WINDOW_BYTES:
        return False
    if settings.USE_REDIS_CACHE:
        return bool(bus.connection().eval(WRITE, 2, cache.make_key(key), cache.make_key(INDEX),
                                         raw, TTL, time.time(), MAX_WINDOWS, int(prewarm)))
    cache.set(key, raw, TTL)
    return True


# Fixed stripes bound local synchronization memory even for arbitrary page keys.
_BUILD_LOCKS = tuple(Lock() for _ in range(64))
BUILD_WAIT = 0.3


def read_through(key, loader, *, prewarm=False):
    """Coalesce cache misses; a slow builder never holds up HTTP indefinitely.

    Locks only cover a local SQL snapshot, never an exchange request. Redis
    leases use owner tokens so an expired builder cannot release a newer lease.
    """
    cache_failed = False
    def read():
        nonlocal cache_failed
        if cache_failed:
            return None
        try:
            return get(key)
        except RedisError:
            cache_failed = True
            return None

    stored = read()
    if stored is not None:
        return stored
    deadline = time.monotonic() + (0 if prewarm else BUILD_WAIT)
    local = _BUILD_LOCKS[hash(key) % len(_BUILD_LOCKS)]
    acquired = local.acquire(timeout=max(0, deadline - time.monotonic()))
    lease = None
    try:
        if acquired and settings.USE_REDIS_CACHE and not cache_failed:
            try:
                candidate = bus.connection().lock(cache.make_key(key + ":build"), timeout=10,
                    blocking_timeout=max(0, deadline - time.monotonic()), sleep=0.02)
                if candidate.acquire():
                    lease = candidate
            except RedisError:
                cache_failed = True
        stored = read()
        if stored is not None:
            return stored
        # Prewarm never competes with an active request or evicts a hot window.
        if prewarm:
            if not acquired or (settings.USE_REDIS_CACHE and lease is None):
                return []
            try:
                if not has_room():
                    return []
            except RedisError:
                return []
        stored = loader()
        if not cache_failed:
            try:
                put(key, stored, prewarm=prewarm)
            except RedisError:
                pass
        return stored
    finally:
        if lease is not None:
            try:
                lease.release()
            except RedisError:
                pass
        if acquired:
            local.release()
