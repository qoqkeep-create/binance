import asyncio
import json
import logging
import re
import time
import uuid

from asgiref.sync import sync_to_async
from django.core.cache import cache
from django.db import close_old_connections
from rest_framework_simplejwt.authentication import JWTAuthentication

from market_stream.bus import subscription_topics
from market_stream.core import INTERVAL_MS
from market_stream.fanout import FanoutError, get_fanout

PUBLIC_CHANNELS = {"market.kline", "market.ticker", "market.history", "strategy.signal"}
PRIVATE_CHANNELS = {"trading.account", "trading.position", "trading.order", "trading.fill"}
logger = logging.getLogger(__name__)
OUTGOING_CAPACITY = 128
SEND_TIMEOUT = 5
SUBSCRIPTION_TIMEOUT = 3
CLOSE_REASONS = frozenset({"client_disconnect", "token_expired", "slow_consumer", "send_timeout",
    "receive_timeout", "subscription_timeout", "redis_error", "invalid_event", "invalid_message",
    "authentication_rejected", "cancelled", "internal_error"})


class SocketEnded(Exception):
    def __init__(self, reason):
        self.reason = reason


def record_close(reason):
    # A fixed set of reasons and 120s TTL bound metric cardinality. No identities,
    # tokens, URLs or payloads enter metrics/logs, including exception messages.
    reason = reason if reason in CLOSE_REASONS else "internal_error"
    logger.info("market_ws_closed reason=%s", reason)
    try:
        key = f"market:ws:closed:{int(time.time() // 60)}:{reason}"
        if not cache.add(key, 1, 120):
            cache.incr(key)
    except Exception:
        pass


def authenticate(headers):
    # ASGI sockets do not pass through Django's HTTP request connection cleanup.
    # A reused authentication thread must not retain an idle MySQL connection.
    close_old_connections()
    try:
        header = headers.get(b"authorization", b"").decode()
        authenticator = JWTAuthentication()
        token = authenticator.get_raw_token(header.encode())
        if token is None:
            raise ValueError("Missing bearer token")
        validated = authenticator.get_validated_token(token)
        user = authenticator.get_user(validated)
        return str(user.pk), int(validated["exp"])
    finally:
        close_old_connections()


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
    except Exception as exc:
        logger.warning("WebSocket authentication rejected (%s)", type(exc).__name__)
        await asyncio.to_thread(record_close, "authentication_rejected")
        await send({"type": "websocket.close", "code": 4401})
        return
    await send({"type": "websocket.accept"})
    outgoing = asyncio.Queue(maxsize=OUTGOING_CAPACITY)
    subscriptions = {}
    member = None
    tasks = []

    async def enqueue_wire(wire):
        try:
            outgoing.put_nowait(wire)
        except asyncio.QueueFull:
            raise SocketEnded("slow_consumer") from None

    async def enqueue(payload):
        await enqueue_wire(json.dumps(payload, separators=(",", ":")))

    async def sender():
        while True:
            payload = await outgoing.get()
            try:
                async with asyncio.timeout(SEND_TIMEOUT):
                    await send({"type": "websocket.send", "text": payload})
            except TimeoutError:
                raise SocketEnded("send_timeout") from None

    async def receiver():
        while True:
            try:
                async with asyncio.timeout(60):
                    incoming = await receive()
            except TimeoutError:
                raise SocketEnded("receive_timeout") from None
            if incoming["type"] == "websocket.disconnect":
                return "client_disconnect"
            raw = incoming.get("text", "")
            if len(raw) > 65536:
                raise SocketEnded("invalid_message")
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
                    # Acknowledge only after Redis has installed the new routes.
                    # The client can then read once to recover a notice published
                    # before its subscription became active.
                    await member.update(subscription_topics(subscriptions), SUBSCRIPTION_TIMEOUT)
                    await enqueue(message("ack", requestId=request_id, data={"subscriptions": items}))
                else:
                    raise ValueError("Unsupported message type")
            except (ValueError, TypeError, AttributeError):
                await enqueue(message("error", error={"code": "INVALID_MESSAGE", "message": "订阅参数不正确"}))

    async def subscriber():
        return await member.failure

    async def expiry():
        await asyncio.sleep(max(0, expires - time.time()))
        return "token_expired"

    reason = "internal_error"
    try:
        member = await get_fanout().attach(outgoing,
            lambda payload: matches(payload, subscriptions, user_id, mode), SUBSCRIPTION_TIMEOUT)
        await enqueue(message("ready", data={"connectionId": str(uuid.uuid4()), "heartbeatIntervalMillis": 20000,
                                              "clientTimeoutMillis": 60000, "capabilities": ["market.history"]}))
        tasks = [asyncio.create_task(sender()), asyncio.create_task(receiver()),
                 asyncio.create_task(subscriber()), asyncio.create_task(expiry())]
        done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for task in done:
            reason = task.result() or reason
    except (SocketEnded, FanoutError) as exc:
        reason = exc.reason
    except asyncio.CancelledError:
        reason = "cancelled"
        raise
    except Exception as exc:
        logger.warning("Market WebSocket ended (%s)", type(exc).__name__)
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        if member is not None:
            await member.close()
        await asyncio.to_thread(record_close, reason)
        try:
            code = 4401 if reason == "token_expired" else 1000 if reason == "client_disconnect" else 1013
            async with asyncio.timeout(SEND_TIMEOUT):
                await send({"type": "websocket.close", "code": code})
        except Exception:
            pass
