"""Public-market regressions: no live DB dependency and no polling barrier."""
import asyncio
import json
import os
import socket
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from unittest import skipUnless
from unittest.mock import patch

from django.core.cache import cache
from django.test import SimpleTestCase, TestCase, override_settings

from market_stream import bus, history_cache, repair, service
from market_stream.collector import MarketCollector
from market_stream.core import rest_candle


def candle(at=0, *, closed=False):
    row = rest_candle("BTCUSDT", "1m", [at, "1", "2", "1", "1.5", "3", at + 59999, "4.5"], at)
    return {**row, "closed": closed, "eventTime": at + 1000}


class LiveFastPathTests(SimpleTestCase):
    def setUp(self):
        cache.clear()

    @patch("market_stream.bus.publish_batch")
    def test_unclosed_update_never_opens_a_database_transaction(self, publish):
        # SimpleTestCase rejects all database access, including BEGIN.
        service.publish_live_batch([candle()])
        self.assertEqual(publish.call_args.args[1][0][1]["openTime"], 0)

    def test_market_topics_filter_before_each_websocket_receives_the_event(self):
        subscriptions = {"market.kline": {"symbols": {"BTCUSDT"}, "intervals": {"1m"}}}
        topics = bus.subscription_topics(subscriptions)
        btc = bus.delivery_topic({"channel": "market.kline", "data": candle()})
        eth = bus.delivery_topic({"channel": "market.kline", "data": {**candle(), "symbol": "ETHUSDT"}})
        self.assertIn(btc, topics)
        self.assertNotIn(eth, topics)
        private = {"channel": "trading.order", "_user": "qa", "data": {}}
        self.assertEqual(bus.delivery_topic(private), bus.BUS_CHANNEL)

    @patch("market_stream.bus.publish_batch")
    def test_late_live_update_cannot_reopen_a_closed_candle(self, publish):
        service.publish_live_batch([candle(closed=True)])
        publish.reset_mock()
        service.publish_live_batch([candle()])
        self.assertEqual(publish.call_args.args[1], [])
        self.assertTrue(cache.get("market:live:BTCUSDT:1m")["closed"])

    @patch("market_stream.bus.publish_batch")
    def test_concurrent_live_and_closed_updates_preserve_the_closed_cache(self, _):
        read_live, release_live, closed_started, read_closed = (threading.Event() for _ in range(4))
        get_many = cache.get_many

        def paused_read(keys):
            result = get_many(keys)
            if threading.current_thread().name.startswith("live-reader"):
                read_live.set()
                self.assertTrue(release_live.wait(2))
            else:
                read_closed.set()
            return result

        def close():
            closed_started.set()
            service.publish_live_batch([candle(closed=True)])

        # Django's cache proxy resolves a separate backend per thread. Patch
        # the service reference so both producers pass through this barrier.
        with patch("market_stream.service.cache", wraps=cache) as shared_cache:
            shared_cache.get_many.side_effect = paused_read
            with ThreadPoolExecutor(1, thread_name_prefix="live-reader") as live, ThreadPoolExecutor(1) as closed:
                first = live.submit(service.publish_live_batch, [candle()])
                try:
                    self.assertTrue(read_live.wait(2))
                    second = closed.submit(close)
                    self.assertTrue(closed_started.wait(2))
                    read_closed.wait(0.1)
                finally:
                    release_live.set()
                first.result(timeout=2)
                second.result(timeout=2)
        self.assertTrue(cache.get("market:live:BTCUSDT:1m")["closed"])

    async def test_slow_closed_writer_does_not_hold_up_the_next_live_candle(self):
        collector = MarketCollector()
        entered, release, delivered = asyncio.Event(), asyncio.Event(), asyncio.Event()

        async def slow_write(*_):
            entered.set()
            await release.wait()

        async def work(function, rows, **_):
            if function is service.consume_batch:
                await slow_write()
            elif function is service.publish_live_batch:
                delivered.set()

        with patch("market_stream.collector.asyncio.to_thread", side_effect=work):
            writer = asyncio.create_task(collector.store_closed())
            live = asyncio.create_task(collector.flush())
            try:
                collector.accept(candle(closed=True))
                await asyncio.wait_for(entered.wait(), 1)
                collector.accept(candle(60000))
                await asyncio.wait_for(delivered.wait(), 0.1)
                self.assertFalse(release.is_set())
            finally:
                release.set()
                writer.cancel(); live.cancel()
                await asyncio.gather(writer, live, return_exceptions=True)

    @patch("market_stream.collector.MAX_PENDING_CLOSED", 2)
    def test_slow_storage_has_a_bounded_closed_buffer(self):
        collector = MarketCollector()
        for at in (0, 60000, 120000):
            collector.accept(candle(at, closed=True))
        self.assertEqual([row["openTime"] for row in collector.closed_pending.values()], [60000, 120000])
        self.assertEqual(collector.closed_overflow, 1)


class HistoryFastPathTests(TestCase):
    def setUp(self):
        cache.clear()

    def test_partial_bucket_only_reads_minutes_inside_the_current_bucket(self):
        # Older minutes must not add cold-database work to the current 1h bar.
        start = 3_600_000
        service.persist([candle(at, closed=True) for at in range(0, start + 120_000, 60_000)])
        cache.set("market:live:BTCUSDT:1m", candle(start + 120_000))
        with patch("market_stream.service.from_model", wraps=service.from_model) as convert:
            partial = service.partial_bucket("BTCUSDT", "1h", start + 130_000)
        self.assertEqual(convert.call_count, 2)
        self.assertEqual(partial["openTime"], start)
        self.assertEqual(partial["closeTime"], start + 3_600_000 - 1)
        self.assertEqual(float(partial["volume"]), 9)
        self.assertFalse(partial["closed"])

    def test_partial_bucket_does_not_invent_a_missing_opening_minute(self):
        service.persist([candle(3_660_000, closed=True)])
        cache.set("market:live:BTCUSDT:1m", candle(3_720_000))
        self.assertIsNone(service.partial_bucket("BTCUSDT", "1h", 3_730_000))

    @patch("market_stream.bus.publish_batch")
    @patch("market_stream.service.public_request", return_value=[])
    def test_history_worker_skips_statistics_and_publishes_completion(self, _request, publish):
        from market_stream.models import MarketHistoryTask
        stats = repair.schedule("BTCUSDT", "1h", kind="stats:openInterest", priority=0)
        history = repair.schedule("BTCUSDT", "1h")
        with self.captureOnCommitCallbacks(execute=True):
            self.assertTrue(repair.run_next(lane="history"))
        history.refresh_from_db(); stats.refresh_from_db()
        self.assertGreater(history.completed_at, 0)
        self.assertEqual(stats.completed_at, 0)
        self.assertEqual(publish.call_args.args[0], "market.history")
        self.assertEqual(publish.call_args.args[1][0][1]["kind"], "history")
        self.assertEqual(MarketHistoryTask.objects.count(), 2)

    @patch("market_stream.service.time.time", return_value=600)
    def test_prewarmed_latest_window_serves_another_limit_without_database_query(self, _):
        service.persist([candle(540000, closed=True)])
        service.warm_history("BTCUSDT", "1m")
        with self.assertNumQueries(0):
            response = service.load_history("BTCUSDT", "1m", 1)
        self.assertEqual(response["items"][0]["openTime"], 540000)

    @patch("market_stream.history_cache.has_room", return_value=False)
    def test_full_public_cache_skips_background_prewarm_database_work(self, _):
        with self.assertNumQueries(0):
            self.assertEqual(service.warm_history("BTCUSDT", "1h", prewarm=True), [])

    @patch("market_stream.service.time.time", return_value=600)
    @patch("market_stream.service.public_request")
    def test_onboard_date_prevents_requests_before_listing(self, request, _):
        from market_stream.models import MarketHistoryTask
        cache.set("market:onboard", {"BTCUSDT": 300000})
        task = MarketHistoryTask(symbol="BTCUSDT", interval="1m", before=300000, kind="history")
        exhausted, _ = repair.repair_history(task)
        self.assertTrue(exhausted)
        request.assert_not_called()

    @patch("market_stream.service.time.time", return_value=600)
    def test_larger_interval_first_snapshot_contains_the_local_partial_bucket(self, _):
        service.persist([candle(at, closed=True) for at in range(300000, 600000, 60000)])
        # At 10 minutes this is the completed 5m bucket; add a fresh minute in
        # the new bucket and inspect while it is still forming.
        cache.set("market:live:BTCUSDT:1m", candle(600000))
        with patch("market_stream.service.time.time", return_value=620):
            response = service.load_history("BTCUSDT", "5m", 1500)
        self.assertEqual(response["items"][-1]["openTime"], 600000)
        self.assertFalse(response["items"][-1]["closed"])


@skipUnless(os.getenv("MARKET_TEST_REDIS_BINARY"), "opt-in isolated Redis protocol test")
class RedisMarketProtocolTests(SimpleTestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        cls.process = subprocess.Popen([os.environ["MARKET_TEST_REDIS_BINARY"], "--bind", "127.0.0.1",
            "--port", str(port), "--save", "", "--appendonly", "no"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.settings = override_settings(MARKET_REDIS_URL=f"redis://127.0.0.1:{port}/0")
        cls.settings.enable()
        bus.connection.cache_clear()
        deadline = time.monotonic() + 3
        while True:
            try:
                bus.connection().ping()
                break
            except Exception:
                if time.monotonic() >= deadline:
                    cls.process.terminate()
                    cls.settings.disable()
                    raise
                time.sleep(0.02)

    @classmethod
    def tearDownClass(cls):
        bus.connection().close()
        bus.connection.cache_clear()
        cls.settings.disable()
        cls.process.terminate()
        cls.process.wait(timeout=5)
        super().tearDownClass()

    def test_sequence_delivery_remains_ordered_when_a_producer_pauses_after_redis(self):
        client = bus.connection()
        subscriber = client.pubsub()
        topic = bus.delivery_topic({"channel": "market.kline", "data": candle()})
        subscriber.subscribe(topic)
        self.assertEqual(subscriber.get_message(timeout=2)["type"], "subscribe")
        first_returned, release_first = threading.Event(), threading.Event()
        original_pipeline = client.pipeline

        def paused_pipeline(*args, **kwargs):
            pipe = original_pipeline(*args, **kwargs)
            execute = pipe.execute

            def execute_and_pause(*args, **kwargs):
                result = execute(*args, **kwargs)
                if threading.current_thread().name.startswith("paused-producer") and not first_returned.is_set():
                    first_returned.set()
                    self.assertTrue(release_first.wait(2))
                return result

            pipe.execute = execute_and_pause
            return pipe

        try:
            with patch.object(client, "pipeline", side_effect=paused_pipeline):
                with ThreadPoolExecutor(1, thread_name_prefix="paused-producer") as producer:
                    first = producer.submit(bus.publish_batch, "market.kline", [("BTCUSDT:1m", candle())])
                    try:
                        self.assertTrue(first_returned.wait(2))
                        bus.publish_batch("market.kline", [("BTCUSDT:1m", candle(60000))])
                    finally:
                        release_first.set()
                    first.result(timeout=2)
            delivered = [json.loads(subscriber.get_message(timeout=2)["data"]) for _ in range(2)]
            self.assertEqual(delivered[1]["sequence"], delivered[0]["sequence"] + 1)
            self.assertEqual([row["data"]["openTime"] for row in delivered], [0, 60000])
        finally:
            subscriber.close()

    @override_settings(USE_REDIS_CACHE=True)
    @patch("market_stream.history_cache.MAX_WINDOWS", 2)
    def test_history_cache_evicts_its_own_oldest_window_and_preserves_private_keys(self):
        client = bus.connection()
        private = "qa:account-lease"
        client.set(private, "fence-only-fixture")
        self.assertTrue(history_cache.put("qa:window:1", [candle()]))
        self.assertTrue(history_cache.put("qa:window:2", [candle(60000)]))
        self.assertEqual(history_cache.get("qa:window:1"), [candle()])
        self.assertTrue(history_cache.put("qa:window:3", [candle(120000)]))
        self.assertIsNone(history_cache.get("qa:window:2"))
        self.assertEqual(history_cache.get("qa:window:1"), [candle()])
        self.assertEqual(client.get(private), b"fence-only-fixture")
        self.assertFalse(history_cache.has_room())
        self.assertFalse(history_cache.put("qa:window:4", [candle()], prewarm=True))
        with patch("market_stream.history_cache.MAX_WINDOW_BYTES", 1):
            self.assertFalse(history_cache.put("qa:window:5", [candle()]))
        self.assertEqual(client.zcard(cache.make_key(history_cache.INDEX)), 2)

    async def test_real_asgi_routes_kline_history_and_private_events_by_subscription(self):
        from market_stream.websocket import application
        receive_queue, sent = asyncio.Queue(), asyncio.Queue()
        await receive_queue.put({"type": "websocket.connect"})

        async def receive():
            return await receive_queue.get()

        async def send(message):
            await sent.put(message)

        async def next_message():
            wire = await asyncio.wait_for(sent.get(), 2)
            self.assertEqual(wire["type"], "websocket.send")
            return json.loads(wire["text"])

        async def command(kind, subscriptions):
            await receive_queue.put({"type": "websocket.receive", "text": json.dumps({
                "type": kind, "requestId": "test-only", "subscriptions": subscriptions})})
            return await next_message()

        with patch("market_stream.websocket.authenticate", return_value=("qa", int(time.time()) + 100)):
            task = asyncio.create_task(application({"path": "/ws/v1", "headers": []}, receive, send))
            try:
                self.assertEqual((await asyncio.wait_for(sent.get(), 2))["type"], "websocket.accept")
                ready = await next_message()
                self.assertIn("market.history", ready["data"]["capabilities"])
                subscriptions = [
                    {"channel": "market.kline", "filters": {"symbols": ["BTCUSDT"], "intervals": ["1m"]}},
                    {"channel": "market.history", "filters": {"symbols": ["BTCUSDT"], "intervals": ["1m"]}},
                    {"channel": "trading.order"},
                ]
                self.assertEqual((await command("subscribe", subscriptions))["type"], "ack")
                # Only BTC matches the installed Redis topic; ETH never enters
                # this connection's queue. Private events still check identity.
                await asyncio.to_thread(bus.publish_batch, "market.kline", [
                    ("ETHUSDT:1m", {**candle(), "symbol": "ETHUSDT"}), ("BTCUSDT:1m", candle())])
                first = await next_message()
                self.assertEqual(first["data"]["symbol"], "BTCUSDT")
                await asyncio.to_thread(bus.publish_batch, "market.kline", [("BTCUSDT:1m", candle(60000))])
                second = await next_message()
                self.assertEqual(second["sequence"], first["sequence"] + 1)
                await asyncio.to_thread(bus.publish_batch, "market.history", [("BTCUSDT:1m", {
                    "symbol": "BTCUSDT", "interval": "1m", "kind": "history", "beforeOpenTime": None})])
                self.assertEqual((await next_message())["channel"], "market.history")
                for user, mode in [("other", "ordinary"), ("qa", "lead"), ("qa", "ordinary")]:
                    payload = await asyncio.to_thread(bus.event, "trading.order", "test-order", {}, user_id=user, mode=mode)
                    await asyncio.to_thread(bus.publish, payload)
                self.assertEqual((await next_message())["channel"], "trading.order")
                self.assertTrue(sent.empty())
                self.assertEqual((await command("unsubscribe", subscriptions))["type"], "ack")
            finally:
                await receive_queue.put({"type": "websocket.disconnect"})
                await asyncio.wait_for(task, 3)
