"""Shared public-market connection guard; separate from account/order budgets."""
import logging
import math
import random
import re
import threading
import time
import uuid
from email.utils import parsedate_to_datetime

from django.conf import settings
from django.core.cache import cache

from common.binance import rate_limit_cooldown_remaining
from market_stream import bus

log = logging.getLogger(__name__)
LOCAL_LOCK = threading.Lock()
STATE = "market:upstream:v1"
# Rolling minute and spacing are conservative project limits, not Binance quotas.
RESERVE = """
local now = tonumber(ARGV[1])
local cooldown = tonumber(redis.call('GET', KEYS[3]) or '0')
if cooldown > now then return math.ceil((cooldown-now)*1000) end
redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', now-60)
local next = tonumber(redis.call('GET', KEYS[2]) or '0')
if next > now then return math.ceil((next-now)*1000) end
if redis.call('ZCARD', KEYS[1]) >= tonumber(ARGV[2]) then
    local oldest = redis.call('ZRANGE', KEYS[1], 0, 0, 'WITHSCORES')
    return math.ceil((tonumber(oldest[2])+60-now)*1000)
end
redis.call('ZADD', KEYS[1], now, ARGV[4])
redis.call('EXPIRE', KEYS[1], 120)
redis.call('SET', KEYS[2], now+tonumber(ARGV[3]), 'EX', 120)
return 0
"""
COOLDOWN = """
local deadline = math.max(tonumber(redis.call('GET', KEYS[1]) or '0'), tonumber(ARGV[1]))
redis.call('SET', KEYS[1], deadline, 'EX', math.ceil(deadline-tonumber(ARGV[2]))+120)
return tostring(deadline)
"""


def reserve_connection(*, now=None):
    """Zero admits one attempt; positive seconds mean wait and retry admission.

    Shared Redis failure stops public reconnections rather than multiplying a
    per-process fallback allowance. Healthy existing streams stay connected.
    """
    now = time.time() if now is None else now
    cooldown = rate_limit_cooldown_remaining("futures")
    if cooldown > 0:
        return cooldown
    limit = max(1, min(30, settings.MARKET_WS_ATTEMPTS_PER_MINUTE))
    spacing = max(1, settings.MARKET_WS_CONNECT_SPACING_SECONDS)
    if settings.USE_REDIS_CACHE:
        try:
            return bus.connection().eval(RESERVE, 3,
                cache.make_key(STATE + ":attempts"), cache.make_key(STATE + ":next"), cache.make_key(STATE + ":cooldown"),
                now, limit, spacing, uuid.uuid4().hex) / 1000
        except Exception as exc:
            log.warning("Market connection budget unavailable (%s); deferred", type(exc).__name__)
            return 5
    with LOCAL_LOCK:
        state = cache.get(STATE, {"attempts": [], "next": 0, "cooldown": 0})
        attempts = [at for at in state["attempts"] if at > now - 60]
        wait = max(state["next"] - now, state["cooldown"] - now, 0)
        if len(attempts) >= limit:
            wait = max(wait, attempts[0] + 60 - now)
        if not wait:
            state.update(attempts=attempts + [now], next=now + spacing)
            cache.set(STATE, state, 120)
        return wait


def defer_handshake(exc):
    """Honor 429/418, Retry-After and banned-until without logging response text."""
    response = getattr(exc, "response", None)
    status = getattr(response, "status_code", None)
    if status not in (418, 429):
        return 0
    now = time.time()
    delay = 120 if status == 418 else 30
    for key, value in (getattr(response, "headers", {}) or {}).items():
        if str(key).lower() == "retry-after":
            try:
                delay = max(delay, float(value))
            except (ValueError, TypeError):
                try:
                    delay = max(delay, parsedate_to_datetime(value).timestamp() - now)
                except (ValueError, TypeError, OverflowError):
                    pass
    body = getattr(response, "body", b"")
    match = re.search(r"banned until\s+(\d{13})", str(body)[:2000], re.IGNORECASE)
    if match:
        delay = max(delay, int(match[1]) / 1000 - now)
    until = now + delay
    if settings.USE_REDIS_CACHE:
        try:
            until = float(bus.connection().eval(COOLDOWN, 1, cache.make_key(STATE + ":cooldown"), until, now))
        except Exception as error:
            log.warning("Market connection cooldown unavailable (%s)", type(error).__name__)
            # The reconnect loop still waits locally. Admission fails closed
            # until the shared store is available again.
            pass
    else:
        with LOCAL_LOCK:
            state = cache.get(STATE, {"attempts": [], "next": 0, "cooldown": 0})
            until = max(until, state["cooldown"])
            state["cooldown"] = until
            cache.set(STATE, state, math.ceil(until - now) + 120)
    return max(0, until - now)


def reconnect_delay(attempt):
    return min(60, 2 ** min(max(attempt - 1, 0), 6) * random.uniform(0.8, 1.2))


def rotation_seconds():
    return random.uniform(23.5 * 3600, 23.75 * 3600)
