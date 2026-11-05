"""One Redis reader per ASGI event loop; connection queues remain independent."""
import asyncio
import json
from weakref import WeakKeyDictionary

from django.conf import settings
import redis.asyncio as redis

from market_stream.bus import BUS_CHANNEL

_fanouts = WeakKeyDictionary()
CLOSE_TIMEOUT = 3


class FanoutError(Exception):
    def __init__(self, reason):
        self.reason = reason


class Subscription:
    def __init__(self, owner, queue, accepts):
        self.owner, self.queue, self.accepts = owner, queue, accepts
        self.topics = set()
        self.failure = asyncio.get_running_loop().create_future()

    def fail(self, reason):
        if not self.failure.done():
            self.failure.set_result(reason)

    async def update(self, topics, timeout=3):
        await self.owner.change(self, set(topics), timeout)

    async def close(self):
        await self.owner.detach(self)


class MarketFanout:
    def __init__(self):
        self._members = set()
        self._routes = {}
        self._lock = asyncio.Lock()
        self._changed = asyncio.Event()
        self._requested, self._applied = set(), set()
        self._client = self._pubsub = self._reader = None
        self._failure = None
        self.closed = False

    async def attach(self, queue, accepts, timeout=3):
        member = Subscription(self, queue, accepts)
        try:
            await self.change(member, set(), timeout, attach=True)
        except BaseException:
            await member.close()
            raise
        return member

    async def change(self, member, topics, timeout, *, attach=False):
        # A departing socket must not cancel a half-written Redis subscription.
        # Complete the bounded change under the lock; detach reconciles after it.
        task = asyncio.create_task(self._change(member, topics, timeout, attach))
        try:
            await asyncio.shield(task)
        except asyncio.CancelledError:
            task.add_done_callback(lambda done: None if done.cancelled() else done.exception())
            raise

    async def _change(self, member, topics, timeout, attach):
        async with self._lock:
            if self.closed or self._failure:
                raise FanoutError(self._failure or "cancelled")
            if attach:
                self._members.add(member)
            elif member not in self._members:
                raise FanoutError("cancelled")
            member.topics = topics
            try:
                async with asyncio.timeout(timeout):
                    if self._reader is None:
                        self._client = redis.Redis.from_url(settings.MARKET_REDIS_URL, socket_connect_timeout=3)
                        self._pubsub = self._client.pubsub()
                        await self._pubsub.subscribe(BUS_CHANNEL)
                        self._requested.add(BUS_CHANNEL)
                        self._reader = asyncio.create_task(self._receive())
                    await self._reconcile(timeout)
            except TimeoutError:
                self._fail("subscription_timeout")
                raise FanoutError("subscription_timeout") from None
            except redis.RedisError:
                self._fail("redis_error")
                raise FanoutError("redis_error") from None

    async def _reconcile(self, timeout):
        self._routes = {}
        for member in self._members:
            for topic in member.topics:
                self._routes.setdefault(topic, set()).add(member)
        desired = {BUS_CHANNEL, *self._routes}
        try:
            async with asyncio.timeout(timeout):
                added, removed = desired - self._requested, self._requested - desired
                if added:
                    await self._pubsub.psubscribe(*sorted(added))
                if removed:
                    await self._pubsub.punsubscribe(*sorted(removed))
                self._requested = desired
                while self._applied != desired:
                    if self._failure:
                        raise FanoutError(self._failure)
                    self._changed.clear()
                    await self._changed.wait()
        except TimeoutError:
            self._fail("subscription_timeout")
            raise FanoutError("subscription_timeout") from None
        if self._failure:
            raise FanoutError(self._failure)

    async def detach(self, member):
        async with self._lock:
            self._members.discard(member)
            member.fail("client_disconnect")
            if not self._members:
                await self._close_locked()
            elif not self.closed and not self._failure:
                try:
                    await self._reconcile(CLOSE_TIMEOUT)
                except redis.RedisError:
                    self._fail("redis_error")
                except FanoutError:
                    pass

    def _fail(self, reason):
        self._failure = self._failure or reason
        self._changed.set()
        for member in self._members:
            member.fail(self._failure)

    async def _receive(self):
        try:
            while True:
                incoming = await self._pubsub.get_message(ignore_subscribe_messages=False, timeout=1)
                if incoming is None:
                    continue
                kind = incoming["type"]
                if kind in {"subscribe", "psubscribe", "unsubscribe", "punsubscribe"}:
                    topic = self._text(incoming["channel"])
                    if kind in {"subscribe", "psubscribe"}:
                        self._applied.add(topic)
                    else:
                        self._applied.discard(topic)
                    self._changed.set()
                elif kind in {"message", "pmessage"}:
                    self._dispatch(incoming)
                    # Buffered Redis reads may complete without suspending. Let
                    # healthy senders drain before a burst fills their queues.
                    await asyncio.sleep(0)
        except redis.RedisError:
            # Preserve the existing reconnect + snapshot recovery boundary.
            # Continuing silently after Redis reconnect could hide lost events.
            self._fail("redis_error")
        except (ValueError, TypeError, KeyError, AttributeError):
            self._fail("invalid_event")
        except Exception:
            self._fail("internal_error")

    @staticmethod
    def _text(value):
        return value.decode("utf-8") if isinstance(value, bytes) else value

    def _dispatch(self, incoming):
        topic = self._text(incoming.get("channel", BUS_CHANNEL))
        # subscription_topics permits wildcards only for symbol and interval.
        # Four lookups replace a scan of every connection's topic collection.
        parts = topic.rsplit(":", 2)
        patterns = {topic}
        if len(parts) == 3:
            prefix, symbol, interval = parts
            patterns.update((f"{prefix}:*:{interval}", f"{prefix}:{symbol}:*", f"{prefix}:*:*"))
        if incoming["type"] == "pmessage":
            # Redis delivers once per matching pattern. Use one active pattern
            # as the owner, including during subscribe/unsubscribe transitions.
            matching = patterns.intersection(self._applied)
            if not matching or self._text(incoming["pattern"]) != min(matching):
                return
        candidates = self._members if topic == BUS_CHANNEL else set().union(
            *(self._routes.get(pattern, ()) for pattern in patterns))
        recipients = [member for member in candidates if not member.failure.done()]
        if not recipients:
            return
        try:
            wire = self._text(incoming["data"])
            payload = json.loads(wire)
            if not isinstance(payload, dict):
                raise ValueError("Invalid event")
            if any(key.startswith("_") for key in payload):
                wire = json.dumps({key: value for key, value in payload.items() if not key.startswith("_")},
                                  separators=(",", ":"))
        except (ValueError, TypeError, KeyError, AttributeError):
            for member in recipients:
                member.fail("invalid_event")
            return
        for member in recipients:
            try:
                # Filter the original envelope, before stripping private identity.
                if member.accepts(payload):
                    member.queue.put_nowait(wire)
            except asyncio.QueueFull:
                member.fail("slow_consumer")
            except (ValueError, TypeError, KeyError, AttributeError):
                member.fail("invalid_event")
            except Exception:
                member.fail("internal_error")

    async def close(self):
        async with self._lock:
            self._fail("cancelled")
            await self._close_locked()

    async def _close_locked(self):
        if self.closed:
            return
        self.closed = True
        if self._reader is not None:
            self._reader.cancel()
            await asyncio.gather(self._reader, return_exceptions=True)
        for resource in (self._pubsub, self._client):
            if resource is not None:
                try:
                    async with asyncio.timeout(CLOSE_TIMEOUT):
                        await resource.aclose()
                except (Exception, asyncio.CancelledError):
                    pass
        self._members.clear()
        self._routes.clear()
        loop = asyncio.get_running_loop()
        if _fanouts.get(loop) is self:
            del _fanouts[loop]


def get_fanout():
    loop = asyncio.get_running_loop()
    current = _fanouts.get(loop)
    if current is None or current.closed or current._failure:
        current = _fanouts[loop] = MarketFanout()
    return current


async def close_fanout():
    current = _fanouts.get(asyncio.get_running_loop())
    if current is not None:
        await current.close()
