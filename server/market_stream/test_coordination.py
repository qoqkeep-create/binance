"""Deterministic failure injection: no exchange traffic or trading operations."""
import asyncio
import threading
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch

from django.core.cache import cache
from django.test import SimpleTestCase, TestCase, override_settings

from market_stream import history_cache


class HistoryCoordinationTests(SimpleTestCase):
    def setUp(self):
        cache.clear()

    def test_concurrent_cold_reads_share_one_loader(self):
        entered, release = threading.Event(), threading.Event()
        def load():
            entered.set()
            self.assertTrue(release.wait(2))
            return [{"openTime": 1}]
        loader = Mock(side_effect=load)
        with ThreadPoolExecutor(4) as pool:
            first = pool.submit(history_cache.read_through, "qa:shared", loader)
            try:
                self.assertTrue(entered.wait(1))
                others = [pool.submit(history_cache.read_through, "qa:shared", loader) for _ in range(3)]
            finally:
                release.set()
            self.assertEqual(first.result(2), [{"openTime": 1}])
            self.assertTrue(all(item.result(2) == [{"openTime": 1}] for item in others))
        self.assertEqual(loader.call_count, 1)

    def test_cache_outage_reads_local_snapshot_without_calling_exchange(self):
        from redis.exceptions import ConnectionError
        loader = Mock(return_value=[{"openTime": 2}])
        with patch.object(history_cache, "get", side_effect=ConnectionError), patch.object(history_cache, "put", side_effect=ConnectionError):
            self.assertEqual(history_cache.read_through("qa:outage", loader), [{"openTime": 2}])
        loader.assert_called_once()

    def test_busy_builder_has_a_bounded_wait_before_local_database_fallback(self):
        entered, release = threading.Event(), threading.Event()
        def slow():
            entered.set()
            self.assertTrue(release.wait(2))
            return [{"openTime": 1}]
        with ThreadPoolExecutor(1) as pool, patch.object(history_cache, "BUILD_WAIT", 0.03):
            first = pool.submit(history_cache.read_through, "qa:bounded", slow)
            try:
                self.assertTrue(entered.wait(1))
                import time
                started = time.monotonic()
                self.assertEqual(history_cache.read_through("qa:bounded", lambda: [{"openTime": 2}]), [{"openTime": 2}])
                self.assertLess(time.monotonic() - started, 0.5)
            finally:
                release.set()
            first.result(2)


class UpstreamGuardTests(SimpleTestCase):
    def setUp(self):
        cache.clear()

    def test_shared_attempts_are_spaced_and_rolling_budget_is_bounded(self):
        from market_stream.upstream import reserve_connection
        with override_settings(MARKET_WS_ATTEMPTS_PER_MINUTE=2, MARKET_WS_CONNECT_SPACING_SECONDS=1):
            self.assertEqual(reserve_connection(now=100), 0)
            self.assertGreaterEqual(reserve_connection(now=100), 1)
            self.assertEqual(reserve_connection(now=101), 0)
            self.assertGreaterEqual(reserve_connection(now=102), 58)
            self.assertEqual(reserve_connection(now=161), 0)

    def test_handshake_ban_and_shorter_retry_do_not_shorten_cooldown(self):
        from market_stream.upstream import defer_handshake, reserve_connection
        def rejection(status, wait):
            return SimpleNamespace(response=SimpleNamespace(status_code=status, headers={"Retry-After": str(wait)}, body=b""))
        with patch("market_stream.upstream.time.time", return_value=100):
            self.assertGreaterEqual(defer_handshake(rejection(418, 120)), 120)
            defer_handshake(rejection(429, 30))
            self.assertGreaterEqual(reserve_connection(now=101), 119)

    @override_settings(USE_REDIS_CACHE=True)
    def test_shared_guard_outage_defers_public_reconnect(self):
        from market_stream.upstream import reserve_connection
        with patch("market_stream.upstream.bus.connection", side_effect=ConnectionError):
            self.assertGreaterEqual(reserve_connection(now=100), 5)

    def test_reconnect_delay_grows_and_rotation_is_before_exchange_expiry(self):
        from market_stream.upstream import reconnect_delay, rotation_seconds
        self.assertGreater(reconnect_delay(4), reconnect_delay(1))
        for _ in range(20):
            self.assertTrue(23 * 3600 < rotation_seconds() < 24 * 3600)


class PublicRestGuardTests(SimpleTestCase):
    def setUp(self):
        from common.binance_rate_limit import _clear_local_budget_state
        cache.clear()
        _clear_local_budget_state()

    @override_settings(USE_REDIS_CACHE=True)
    def test_public_repair_defers_when_only_process_local_budget_is_available(self):
        from common.binance import BinanceApiError
        from market_stream import service
        with patch("common.binance_rate_limit.cache.add", side_effect=ConnectionError), \
             patch("common.binance._perform_http_request") as exchange:
            with self.assertRaises(BinanceApiError) as caught:
                service.public_request("/fapi/v1/continuousKlines", {"limit": 1500})
            self.assertEqual(caught.exception.code, "LOCAL_RATE_BUDGET")
            exchange.assert_not_called()


class SocketDiagnosticTests(SimpleTestCase):
    def setUp(self):
        cache.clear()

    async def run_socket(self, reason):
        import time
        from redis.exceptions import ConnectionError as RedisConnectionError
        from market_stream import websocket
        incoming, sent = asyncio.Queue(), []
        await incoming.put({"type": "websocket.connect"})
        if reason == "client_disconnect":
            await incoming.put({"type": "websocket.disconnect"})
        elif reason == "slow_consumer":
            for _ in range(12):
                await incoming.put({"type": "websocket.receive", "text": '{"type":"ping"}'})
        elif reason == "subscription_timeout":
            await incoming.put({"type": "websocket.receive", "text": '{"type":"subscribe","subscriptions":[{"channel":"market.ticker"}]}'})
        elif reason == "invalid_event":
            pass
        pubsub = Mock(subscribe=AsyncMock(), psubscribe=AsyncMock(), aclose=AsyncMock())
        first = True
        async def get_message(**_):
            nonlocal first
            if reason == "redis_error":
                raise RedisConnectionError("fixture secret must not be logged")
            if reason == "invalid_event" and first:
                first = False
                return {"type": "message", "data": b'private malformed fixture'}
            await asyncio.sleep(0.001)
            return None
        pubsub.get_message = get_message
        client = Mock(pubsub=Mock(return_value=pubsub), aclose=AsyncMock())
        async def send(message):
            sent.append(message)
            if message["type"] == "websocket.send" and reason in {"send_timeout", "slow_consumer"}:
                await asyncio.Event().wait()
        expires = int(time.time()) + (-1 if reason == "token_expired" else 100)
        with patch.object(websocket, "authenticate", return_value=("qa", expires)), \
             patch.object(websocket.redis.Redis, "from_url", return_value=client), \
             patch.object(websocket, "SEND_TIMEOUT", 0.03, create=True), \
             patch.object(websocket, "SUBSCRIPTION_TIMEOUT", 0.03, create=True), \
             patch.object(websocket, "OUTGOING_CAPACITY", 4, create=True), \
             patch.object(websocket, "record_close", create=True) as record:
            await asyncio.wait_for(websocket.application({"path": "/ws/v1", "headers": []}, incoming.get, send), 1)
            record.assert_called_once_with(reason)
        pubsub.aclose.assert_awaited_once()
        client.aclose.assert_awaited_once()
        return sent

    async def test_disconnect_expiry_redis_and_malformed_event_are_classified(self):
        for reason in ("client_disconnect", "token_expired", "redis_error", "invalid_event"):
            with self.subTest(reason=reason):
                await self.run_socket(reason)

    async def test_slow_sender_and_consumer_and_subscription_timeout_are_classified(self):
        for reason in ("send_timeout", "slow_consumer", "subscription_timeout"):
            with self.subTest(reason=reason):
                await self.run_socket(reason)


class RepairCooldownTests(TestCase):
    def setUp(self):
        cache.clear()

    def test_banned_repair_waits_until_shared_cooldown_and_is_not_reclaimed(self):
        from common.binance import BinanceApiError, mark_rate_limit_cooldown
        from market_stream import repair
        task = repair.schedule("BTCUSDT", "1h")
        def ban(_):
            mark_rate_limit_cooldown(headers={"Retry-After": "120"})
            raise BinanceApiError("fixture", code="418")
        with patch("market_stream.repair.time.time", return_value=100):
            with patch("market_stream.repair.repair_history", side_effect=ban) as read:
                self.assertTrue(repair.run_next())
                task.refresh_from_db()
                self.assertGreaterEqual(task.due_at, 220)
                self.assertFalse(repair.run_next())
                read.assert_called_once()


class CollectorReconnectTests(SimpleTestCase):
    async def test_short_lived_connections_keep_increasing_backoff(self):
        from market_stream.collector import MarketCollector
        async def messages():
            if False:
                yield ""
        socket = Mock(__aiter__=lambda _: messages())
        context = Mock(__aenter__=AsyncMock(return_value=socket), __aexit__=AsyncMock(return_value=False))
        async def inline(function, *args, **kwargs):
            return function(*args, **kwargs)
        delays = []
        async def sleep(delay):
            delays.append(delay)
            if len(delays) == 3:
                raise asyncio.CancelledError
        with patch("market_stream.collector.connect", return_value=context), \
             patch("market_stream.collector.asyncio.to_thread", side_effect=inline), \
             patch("market_stream.collector.asyncio.sleep", side_effect=sleep), \
             patch("market_stream.upstream.reserve_connection", return_value=0), \
             patch("market_stream.upstream.reconnect_delay", side_effect=float):
            with self.assertRaises(asyncio.CancelledError):
                await MarketCollector().consume(["btcusdt_perpetual@continuousKline_1m"])
        self.assertEqual(delays, [1, 2, 3])
        self.assertEqual(context.__aexit__.await_count, 3)

    async def test_budget_wait_does_not_open_a_connection_and_remains_cancellable(self):
        from market_stream.collector import MarketCollector
        with patch("market_stream.upstream.reserve_connection", return_value=30), \
             patch("market_stream.collector.asyncio.sleep", side_effect=asyncio.CancelledError), \
             patch("market_stream.collector.connect") as connect:
            with self.assertRaises(asyncio.CancelledError):
                await MarketCollector().consume(["!ticker@arr"])
            connect.assert_not_called()

    async def test_planned_rotation_closes_then_reacquires_shared_admission(self):
        from market_stream.collector import MarketCollector
        async def messages():
            await asyncio.Event().wait()
            yield ""
        socket = Mock(__aiter__=lambda _: messages())
        context = Mock(__aenter__=AsyncMock(return_value=socket), __aexit__=AsyncMock(return_value=False))
        with patch("market_stream.collector.connect", return_value=context), \
             patch("market_stream.upstream.rotation_seconds", return_value=0.01), \
             patch("market_stream.upstream.reserve_connection", side_effect=[0, asyncio.CancelledError]), \
             patch("market_stream.upstream.reconnect_delay") as failure_delay:
            with self.assertRaises(asyncio.CancelledError):
                await MarketCollector().consume(["!ticker@arr"])
            context.__aexit__.assert_awaited_once()
            failure_delay.assert_not_called()
