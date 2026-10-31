import json
import time
from functools import lru_cache

from django.conf import settings
import redis

BUS_CHANNEL = "integrated:events:v1"


@lru_cache(maxsize=1)
def connection():
    return redis.Redis.from_url(settings.MARKET_REDIS_URL, socket_connect_timeout=3, socket_timeout=3)


def event(channel, key, data, *, user_id=None, mode=None):
    client = connection()
    sequence_key = f"integrated:sequence:{channel}:{key}"
    with client.pipeline() as pipe:
        pipe.incr(sequence_key)
        pipe.expire(sequence_key, 86400)
        sequence, _ = pipe.execute()
    payload = {"version": 1, "type": "event", "channel": channel, "event": "upsert",
               "key": key, "sequence": sequence, "timestamp": int(time.time() * 1000), "data": data}
    if user_id is not None:
        payload["_user"] = str(user_id)
        payload["_mode"] = mode or "ordinary"
    return payload


def publish(payload):
    connection().publish(BUS_CHANNEL, json.dumps(payload, separators=(",", ":")))
