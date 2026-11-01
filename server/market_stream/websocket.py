import asyncio
import json
import re
import time
import uuid

from asgiref.sync import sync_to_async
from django.conf import settings
import redis.asyncio as redis
from rest_framework_simplejwt.authentication import JWTAuthentication

from market_stream.bus import BUS_CHANNEL, subscription_topics
from market_stream.core import INTERVAL_MS

PUBLIC_CHANNELS = {"market.kline", "market.ticker", "market.history", "strategy.signal"}
PRIVATE_CHANNELS = {"trading.account", "trading.position", "trading.order", "trading.fill"}


def authenticate(headers):
    header = headers.get(b"authorization", b"").decode()
    authenticator = JWTAuthentication()
    token = authenticator.get_raw_token(header.encode())
    if token is None:
        raise ValueError("Missing bearer token")
    validated = authenticator.get_validated_token(token)
    user = authenticator.get_user(validated)
    return str(user.pk), int(validated["exp"])


def message(kind, **fields):
    return {"version": 1, "type": kind, "timestamp": int(time.time()*1000), **fields}


def validate_subscription(item):
    channel = item.get("channel")
    if channel not in PUBLIC_CHANNELS | PRIVATE_CHANNELS:
        raise ValueError("Unsupported channel")
    filters = item.get("filters", {})
    if not isinstance(filters, dict):
        raise ValueError("Invalid filters")
    symbols = filters.get("symbols", [])
    intervals = filters.get("intervals", [])
    if not isinstance(symbols, list) or not isinstance(intervals, list) or len(symbols) > 1000:
        raise ValueError("Too many symbols")
    if any(not isinstance(s, str) or not re.fullmatch(r"[A-Z0-9]{2,32}", s) for s in symbols):
        raise ValueError("Invalid symbols")
    if any(i not in INTERVAL_MS for i in intervals):
        raise ValueError("Invalid intervals")
    return channel, {"symbols": set(symbols), "intervals": set(intervals)}


def matches(payload, subscriptions, user_id, mode):
    channel = payload.get("channel")
    if channel not in subscriptions:
        return False
    if payload.get("_user") is not None and (payload["_user"] != user_id or payload.get("_mode") != mode):
        return False
    if channel in PRIVATE_CHANNELS and payload.get("_user") != user_id:
        return False
    filters = subscriptions[channel]
    data = payload.get("data", {})
    return ((not filters["symbols"] or data.get("symbol") in filters["symbols"])
            and (not filters["intervals"] or data.get("interval") in filters["intervals"]))


async def application(scope, receive, send):
    if scope["path"].rstrip("/") != "/ws/v1":
        await send({"type": "websocket.close", "code": 4404})
        return
    await receive()
    headers = dict(scope.get("headers", []))
    try:
        user_id, expires = await sync_to_async(authenticate, thread_sensitive=False)(headers)
        mode = headers.get(b"x-trading-mode", b"ordinary").decode()
        if mode not in {"ordinary", "lead"}:
            raise ValueError("Invalid mode")
    except Exception:
        await send({"type": "websocket.close", "code": 4401})
        return
    await send({"type": "websocket.accept"})
    outgoing = asyncio.Queue(maxsize=128)
    subscriptions = {}
    client = redis.Redis.from_url(settings.MARKET_REDIS_URL, socket_connect_timeout=3)
    pubsub = client.pubsub()
    tasks = []
    topics = set()
    applied_topics = set()
    subscription_applied = asyncio.Event()

    async def enqueue(payload):
        outgoing.put_nowait(json.dumps(payload, separators=(",", ":")))

    async def sender():
        while True:
            payload = await outgoing.get()
            await asyncio.wait_for(send({"type": "websocket.send", "text": payload}), 5)

    async def receiver():
        nonlocal topics
        while True:
            incoming = await asyncio.wait_for(receive(), 60)
            if incoming["type"] == "websocket.disconnect":
                return
            raw = incoming.get("text", "")
            if len(raw) > 65536:
                raise ValueError("Message too large")
            try:
                data = json.loads(raw)
                if data.get("version", 1) != 1:
                    raise ValueError("Unsupported version")
                kind, request_id = data.get("type"), data.get("requestId")
                if kind == "ping":
                    await enqueue(message("pong", requestId=request_id, data={"clientTimestamp": data.get("timestamp", 0)}))
                elif kind in {"subscribe", "unsubscribe"}:
                    items = data.get("subscriptions", [])
                    if not isinstance(items, list) or len(items) > 16:
                        raise ValueError("Too many subscriptions")
                    validated = [validate_subscription(item) for item in items]
                    for channel, filters in validated:
                        if kind == "subscribe":
                            subscriptions[channel] = filters
                        else:
                            subscriptions.pop(channel, None)
                    desired = subscription_topics(subscriptions)
                    if desired - topics:
                        await pubsub.psubscribe(*sorted(desired - topics))
                    if topics - desired:
                        await pubsub.punsubscribe(*sorted(topics - desired))
                    topics = desired
                    # Acknowledge only after Redis has installed the new routes.
                    # The client can then read once to recover a notice published
                    # before its subscription became active.
                    while not desired.issubset(applied_topics):
                        subscription_applied.clear()
                        await asyncio.wait_for(subscription_applied.wait(), 3)
                    await enqueue(message("ack", requestId=request_id, data={"subscriptions": items}))
                else:
                    raise ValueError("Unsupported message type")
            except (ValueError, TypeError, AttributeError):
                await enqueue(message("error", error={"code": "INVALID_MESSAGE", "message": "订阅参数不正确"}))

    async def subscriber():
        while True:
            if time.time() >= expires:
                return
            incoming = await pubsub.get_message(ignore_subscribe_messages=False, timeout=1)
            if incoming is None:
                await asyncio.sleep(0.01)
                continue
            if incoming["type"] not in {"message", "pmessage"}:
                topic = incoming["channel"]
                topic = topic.decode() if isinstance(topic, bytes) else topic
                if incoming["type"] == "psubscribe":
                    applied_topics.add(topic)
                elif incoming["type"] == "punsubscribe":
                    applied_topics.discard(topic)
                subscription_applied.set()
                continue
            payload = json.loads(incoming["data"])
            if matches(payload, subscriptions, user_id, mode):
                await enqueue({key: value for key, value in payload.items() if not key.startswith("_")})

    try:
        await pubsub.subscribe(BUS_CHANNEL)
        await enqueue(message("ready", data={"connectionId": str(uuid.uuid4()), "heartbeatIntervalMillis": 20000,
                                              "clientTimeoutMillis": 60000, "capabilities": ["market.history"]}))
        tasks = [asyncio.create_task(sender()), asyncio.create_task(receiver()), asyncio.create_task(subscriber())]
        done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for task in done:
            task.result()
    except (Exception, asyncio.CancelledError):
        pass
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await pubsub.aclose()
        await client.aclose()
        try:
            await send({"type": "websocket.close", "code": 4401 if time.time() >= expires else 1013})
        except Exception:
            pass
