"""Shared delivery lifecycle with isolated Redis and deterministic ACK barriers."""
import asyncio
import json
import os
import time
from contextlib import AsyncExitStack
from types import SimpleNamespace
from unittest import skipUnless
from unittest.mock import AsyncMock, Mock, patch

from django.test import SimpleTestCase
from redis.exceptions import ConnectionError as RedisConnectionError

from market_stream import bus, fanout
from market_stream.test_fast_path import IsolatedMarketRedisMixin, candle


@skipUnless(os.getenv("MARKET_TEST_REDIS_BINARY"), "opt-in isolated Redis protocol test")
class SharedFanoutRedisTests(IsolatedMarketRedisMixin, SimpleTestCase):
    async def attach(self, stack, symbols=("BTCUSDT",), intervals=("1m",), *, capacity=128):
        queue = asyncio.Queue(maxsize=capacity)
        member = await fanout.get_fanout().attach(queue, lambda _: True)
        stack.push_async_callback(member.close)
        topics = bus.subscription_topics({"market.kline": {
            "symbols": set(symbols), "intervals": set(intervals)}})
        await member.update(topics)
        return member, queue

    async def publish(self, at=0, symbol="BTCUSDT"):
        await asyncio.to_thread(bus.publish_batch, "market.kline", [
            (f"{symbol}:1m", {**candle(at), "symbol": symbol})])

    async def next(self, queue):
        return json.loads(await asyncio.wait_for(queue.get(), 2))

    async def test_burst_gives_fast_socket_senders_a_turn_before_queues_fill(self):
        from market_stream import websocket
        queues, tasks = [], []
        with patch.object(websocket, "authenticate", return_value=("qa", int(time.time()) + 100)), \
             patch.object(websocket, "OUTGOING_CAPACITY", 8):
            try:
                for _ in range(2):
                    incoming, sent = asyncio.Queue(), asyncio.Queue()
                    queues.append((incoming, sent))
                    await incoming.put({"type": "websocket.connect"})
                    tasks.append(asyncio.create_task(websocket.application(
                        {"path": "/ws/v1", "headers": []}, incoming.get, sent.put)))
                    self.assertEqual((await asyncio.wait_for(sent.get(), 2))["type"], "websocket.accept")
                    self.assertEqual(json.loads((await asyncio.wait_for(sent.get(), 2))["text"])["type"], "ready")
                    await incoming.put({"type": "websocket.receive", "text": json.dumps({
                        "type": "subscribe", "subscriptions": [{"channel": "market.kline",
                            "filters": {"symbols": ["BTCUSDT"], "intervals": ["1m"]}}]})})
                    self.assertEqual(json.loads((await asyncio.wait_for(sent.get(), 2))["text"])["type"], "ack")
                # Immediate ASGI send callbacks are healthy consumers. A single
                # Redis burst must yield to them before declaring a full queue.
                await asyncio.to_thread(bus.publish_batch, "market.kline", [
                    ("BTCUSDT:1m", candle(index * 60000)) for index in range(64)])
                for index in range(64):
                    for _, sent in queues:
                        item = await asyncio.wait_for(sent.get(), 2)
                        self.assertEqual(item["type"], "websocket.send")
                        self.assertEqual(json.loads(item["text"])["data"]["openTime"], index * 60000)
            finally:
                for incoming, _ in queues:
                    await incoming.put({"type": "websocket.disconnect"})
                await asyncio.wait_for(asyncio.gather(*tasks), 3)

    async def test_overlapping_exact_and_wildcard_topics_decode_and_deliver_once(self):
        decoder = Mock(wraps=json.loads)
        codec = SimpleNamespace(loads=decoder, dumps=json.dumps)
        async with AsyncExitStack() as stack:
            _, exact = await self.attach(stack)
            _, all_intervals = await self.attach(stack, intervals=())
            _, all_symbols = await self.attach(stack, symbols=())
            with patch.object(fanout, "json", codec):
                for at in (0, 60000, 120000):
                    await self.publish(at)
                    for queue in (exact, all_intervals, all_symbols):
                        self.assertEqual((await self.next(queue))["data"]["openTime"], at)
                self.assertEqual(decoder.call_count, 3)
            # A BUS event is a delivery barrier after all pattern copies.
            await asyncio.to_thread(bus.publish_batch, "strategy.signal", [("fence", {"fence": True})])
            for queue in (exact, all_intervals, all_symbols):
                self.assertEqual((await self.next(queue))["channel"], "strategy.signal")

    async def test_topic_references_survive_replacement_unsubscribe_and_last_close(self):
        async with AsyncExitStack() as stack:
            first, first_queue = await self.attach(stack)
            second, second_queue = await self.attach(stack)
            self.assertEqual(await asyncio.to_thread(bus.connection().pubsub_numpat), 1)
            await first.update(bus.subscription_topics({"market.kline": {
                "symbols": {"ETHUSDT"}, "intervals": {"1m"}}}))
            self.assertEqual(await asyncio.to_thread(bus.connection().pubsub_numpat), 2)
            await self.publish()
            await self.publish(symbol="ETHUSDT")
            self.assertEqual((await self.next(first_queue))["data"]["symbol"], "ETHUSDT")
            self.assertEqual((await self.next(second_queue))["data"]["symbol"], "BTCUSDT")
            await first.update(set())
            self.assertEqual(await asyncio.to_thread(bus.connection().pubsub_numpat), 1)
            await self.publish(60000)
            self.assertEqual((await self.next(second_queue))["data"]["openTime"], 60000)
            self.assertTrue(first_queue.empty())
            await second.close()
            self.assertEqual(await asyncio.to_thread(bus.connection().pubsub_numpat), 0)
        self.assertEqual((await asyncio.to_thread(bus.connection().pubsub_numsub, bus.BUS_CHANNEL))[0][1], 0)

    async def test_slow_member_isolated_and_remaining_delivery_stays_ordered(self):
        async with AsyncExitStack() as stack:
            slow, slow_queue = await self.attach(stack, capacity=1)
            healthy, queue = await self.attach(stack)
            delivered = []
            for at in (0, 60000, 120000):
                await self.publish(at)
                delivered.append(await self.next(queue))
            self.assertEqual(await asyncio.wait_for(slow.failure, 1), "slow_consumer")
            self.assertEqual(slow_queue.qsize(), 1)
            self.assertFalse(healthy.failure.done())
            self.assertEqual([item["data"]["openTime"] for item in delivered], [0, 60000, 120000])
            self.assertEqual([item["sequence"] for item in delivered],
                             list(range(delivered[0]["sequence"], delivered[0]["sequence"] + 3)))

    async def test_malformed_topic_fails_only_its_receivers(self):
        async with AsyncExitStack() as stack:
            broken, _ = await self.attach(stack)
            healthy, queue = await self.attach(stack, symbols=("ETHUSDT",))
            topic = bus.delivery_topic({"channel": "market.kline", "data": candle()})
            await asyncio.to_thread(bus.connection().publish, topic, b"invalid event")
            self.assertEqual(await asyncio.wait_for(broken.failure, 1), "invalid_event")
            await self.publish(symbol="ETHUSDT")
            self.assertEqual((await self.next(queue))["data"]["symbol"], "ETHUSDT")
            self.assertFalse(healthy.failure.done())

    async def test_redis_disconnect_requires_new_receiver_and_restored_subscription(self):
        async with AsyncExitStack() as stack:
            first, _ = await self.attach(stack)
            second, _ = await self.attach(stack)
            await asyncio.to_thread(bus.connection().client_kill_filter, _type="pubsub")
            self.assertEqual(await asyncio.wait_for(first.failure, 2), "redis_error")
            self.assertEqual(await asyncio.wait_for(second.failure, 2), "redis_error")
            # A new WSS attaches to a fresh receiver; old cleanup cannot remove it.
            restored, queue = await self.attach(stack)
            await first.close()
            await second.close()
            await self.publish()
            self.assertEqual((await self.next(queue))["data"]["openTime"], 0)
            self.assertFalse(restored.failure.done())
            self.assertEqual((await asyncio.to_thread(bus.connection().pubsub_numsub, bus.BUS_CHANNEL))[0][1], 1)

    async def test_asgi_shutdown_releases_active_receiver(self):
        from riskon.asgi import application
        async with AsyncExitStack() as stack:
            member, _ = await self.attach(stack)
            incoming = asyncio.Queue()
            await incoming.put({"type": "lifespan.startup"})
            await incoming.put({"type": "lifespan.shutdown"})
            sent = []
            async def send(event):
                sent.append(event["type"])
            await application({"type": "lifespan"}, incoming.get, send)
            self.assertEqual(sent, ["lifespan.startup.complete", "lifespan.shutdown.complete"])
            self.assertEqual(await member.failure, "cancelled")
            self.assertEqual((await asyncio.to_thread(bus.connection().pubsub_numsub, bus.BUS_CHANNEL))[0][1], 0)


class ControlledPubSub:
    def __init__(self):
        self.messages = asyncio.Queue()
        self.commands = asyncio.Queue()
        self.pending = []
        self.hold_patterns = False
        self.aclose = AsyncMock()

    async def subscribe(self, *topics):
        for topic in topics:
            await self.messages.put({"type": "subscribe", "channel": topic})

    async def psubscribe(self, *topics):
        await self.commands.put(("psubscribe", topics))
        for topic in topics:
            ack = {"type": "psubscribe", "channel": topic}
            if self.hold_patterns:
                self.pending.append(ack)
            else:
                await self.messages.put(ack)

    async def punsubscribe(self, *topics):
        await self.commands.put(("punsubscribe", topics))
        for topic in topics:
            await self.messages.put({"type": "punsubscribe", "channel": topic})

    async def get_message(self, **_):
        message = await self.messages.get()
        if isinstance(message, Exception):
            raise message
        return message

    async def release(self):
        for message in self.pending:
            await self.messages.put(message)
        self.pending.clear()


class SharedFanoutLifecycleTests(SimpleTestCase):
    async def test_subscription_network_stall_is_bounded_and_other_members_are_not_left_waiting(self):
        pubsub = ControlledPubSub()
        entered = asyncio.Event()
        async def blocked(*_):
            entered.set()
            await asyncio.Event().wait()
        client = Mock(pubsub=Mock(return_value=pubsub), aclose=AsyncMock())
        with patch.object(fanout.redis.Redis, "from_url", return_value=client):
            first = await fanout.get_fanout().attach(asyncio.Queue(), lambda _: True)
            second = await fanout.get_fanout().attach(asyncio.Queue(), lambda _: True)
            try:
                pubsub.psubscribe = blocked
                with self.assertRaises(fanout.FanoutError) as caught:
                    await asyncio.wait_for(first.update({"fixture:topic"}, 0.03), 1)
                self.assertTrue(entered.is_set())
                self.assertEqual(caught.exception.reason, "subscription_timeout")
                self.assertEqual(await second.failure, "subscription_timeout")
            finally:
                await first.close()
                await second.close()
        client.aclose.assert_awaited_once()

    async def test_ack_waits_for_redis_and_cancelled_update_releases_only_its_topics(self):
        pubsub = ControlledPubSub()
        client = Mock(pubsub=Mock(return_value=pubsub), aclose=AsyncMock())
        topics = bus.subscription_topics({"market.kline": {"symbols": {"BTCUSDT"}, "intervals": {"1m"}}})
        with patch.object(fanout.redis.Redis, "from_url", return_value=client):
            owner = fanout.get_fanout()
            first = await owner.attach(asyncio.Queue(), lambda _: True)
            second = await owner.attach(asyncio.Queue(), lambda _: True)
            try:
                pubsub.hold_patterns = True
                update = asyncio.create_task(first.update(topics))
                self.assertEqual((await asyncio.wait_for(pubsub.commands.get(), 1))[0], "psubscribe")
                self.assertFalse(update.done(), "The WSS cannot ACK before Redis confirms installation")
                update.cancel()
                with self.assertRaises(asyncio.CancelledError):
                    await update
                close = asyncio.create_task(first.close())
                await pubsub.release()
                await asyncio.wait_for(close, 1)
                self.assertEqual((await asyncio.wait_for(pubsub.commands.get(), 1))[0], "punsubscribe")
                self.assertFalse(second.failure.done())
            finally:
                await first.close()
                await second.close()
        pubsub.aclose.assert_awaited_once()
        client.aclose.assert_awaited_once()

    async def test_cancelled_first_attach_closes_client_and_next_attach_works(self):
        pubsub = ControlledPubSub()
        entered = asyncio.Event()
        async def withheld(*_):
            entered.set()
        pubsub.subscribe = withheld
        client = Mock(pubsub=Mock(return_value=pubsub), aclose=AsyncMock())
        with patch.object(fanout.redis.Redis, "from_url", return_value=client):
            attach = asyncio.create_task(fanout.get_fanout().attach(asyncio.Queue(), lambda _: True, 0.03))
            await entered.wait()
            attach.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await asyncio.wait_for(attach, 1)
        pubsub.aclose.assert_awaited_once()
        client.aclose.assert_awaited_once()
        fresh = ControlledPubSub()
        client = Mock(pubsub=Mock(return_value=fresh), aclose=AsyncMock())
        with patch.object(fanout.redis.Redis, "from_url", return_value=client):
            member = await fanout.get_fanout().attach(asyncio.Queue(), lambda _: True)
            await member.close()
        fresh.aclose.assert_awaited_once()

    async def test_redis_failure_during_update_wakes_all_waiters_and_closes_once(self):
        pubsub = ControlledPubSub()
        client = Mock(pubsub=Mock(return_value=pubsub), aclose=AsyncMock())
        with patch.object(fanout.redis.Redis, "from_url", return_value=client):
            first = await fanout.get_fanout().attach(asyncio.Queue(), lambda _: True)
            second = await fanout.get_fanout().attach(asyncio.Queue(), lambda _: True)
            try:
                pubsub.hold_patterns = True
                update = asyncio.create_task(first.update({"integrated:market:v2:market.ticker:BTCUSDT:-"}))
                await asyncio.wait_for(pubsub.commands.get(), 1)
                await pubsub.messages.put(RedisConnectionError("fixture detail must not be logged"))
                with self.assertRaises(fanout.FanoutError) as caught:
                    await asyncio.wait_for(update, 1)
                self.assertEqual(caught.exception.reason, "redis_error")
                self.assertEqual(await first.failure, "redis_error")
                self.assertEqual(await second.failure, "redis_error")
            finally:
                await first.close()
                await second.close()
        pubsub.aclose.assert_awaited_once()
        client.aclose.assert_awaited_once()
