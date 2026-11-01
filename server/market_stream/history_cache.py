"""Bounded public-history cache; never evict account locks or budget keys."""
import json
import time
import zlib

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
