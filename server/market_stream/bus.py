import json
import time
from functools import lru_cache

from django.conf import settings
import redis

BUS_CHANNEL = "integrated:events:v1"
MARKET_CHANNELS = {"market.kline", "market.ticker", "market.ticker.batch", "market.history"}
PUBLISH_SEQUENCED = """
local sequence = redis.call('INCR', KEYS[1])
redis.call('EXPIRE', KEYS[1], 86400)
redis.call('PUBLISH', ARGV[1], ARGV[2] .. sequence .. '}')
return sequence
"""


def delivery_topic(payload):
    if payload.get("channel") == "market.ticker.batch":
        return "integrated:market:v2:market.ticker.batch:all:-"
    if payload.get("channel") not in MARKET_CHANNELS:
        return BUS_CHANNEL
    data = payload["data"]
    return f"integrated:market:v2:{payload['channel']}:{data['symbol']}:{data.get('interval', '-')}"


def subscription_topics(subscriptions):
    """Redis routes public data before an individual connection receives it."""
    topics = set()
    for channel, filters in subscriptions.items():
        if channel not in MARKET_CHANNELS:
            continue
        if channel == "market.ticker.batch":
            topics.add("integrated:market:v2:market.ticker.batch:all:-")
            continue
        symbols = filters["symbols"] or {"*"}
        intervals = {"-"} if channel == "market.ticker" else filters["intervals"] or {"*"}
        topics.update(f"integrated:market:v2:{channel}:{symbol}:{interval}"
                      for symbol in symbols for interval in intervals)
        if channel == "market.ticker":
            topics.add("integrated:market:v2:market.ticker.batch:all:-")
    return topics


@lru_cache(maxsize=1)
def connection():
    return redis.Redis.from_url(settings.MARKET_REDIS_URL, socket_connect_timeout=3, socket_timeout=3)


def publish_batch(channel, entries):
    _publish_batch([(channel, key, data, None, None) for key, data in entries])


def publish_private_batch(entries):
    """Publish ordered (channel, key, data, user_id, mode) entries in one trip."""
    entries = list(entries)
    if any(channel in MARKET_CHANNELS or user_id is None or mode not in {"ordinary", "lead"}
           for channel, _, _, user_id, mode in entries):
        raise ValueError("Private events require an account scope and private channel")
    _publish_batch(entries)


def sequence_key(channel, key, data):
    suffix = ":closed" if channel == "market.kline" and data.get("closed") is True else ""
    return f"integrated:sequence:{channel}:{key}{suffix}"


def _publish_batch(entries):
    """Allocate sequence and publish atomically, including across producers."""
    if not entries:
        return
    client = connection()
    now = int(time.time() * 1000)
    with client.pipeline() as pipe:
        for channel, key, data, user_id, mode in entries:
            payload = {"version": 1, "type": "event", "channel": channel, "event": "upsert",
                       "key": key, "timestamp": now, "data": data}
            if user_id is not None:
                payload.update(_user=str(user_id), _mode=mode)
            prefix = json.dumps(payload, separators=(",", ":"))[:-1] + ',"sequence":'
            pipe.eval(PUBLISH_SEQUENCED, 1, sequence_key(channel, key, data),
                      delivery_topic(payload), prefix)
        pipe.execute()
