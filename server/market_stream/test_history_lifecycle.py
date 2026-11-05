"""History cache lifecycle and statistics handoff; no exchange or trading I/O."""
import threading
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch

from django.core.cache import cache
from django.db import transaction
from django.test import TestCase, TransactionTestCase, override_settings

from market_stream import bus, history_cache, repair, service, trading_data
from market_stream.core import rest_candle
from market_stream.models import MarketHistoryTask
from market_stream.test_fast_path import IsolatedMarketRedisMixin


def closed(at=0, symbol="BTCUSDT", price="1.5"):
    return rest_candle(symbol, "1m", [at, "1", "2", "1", price, "3", at + 59999, "4.5"], at + 60000)


def snapshot(at=3600000):
    return {"symbol": "BTCUSDT", "interval": "1h",
            "items": [{"openTime": at, "closeTime": at + 3599999}]}


class StatisticsHandoffTests(TestCase):
    def setUp(self):
        cache.clear()

    @patch("common.binance.rate_limit_cooldown_remaining", return_value=0)
    @patch("market_stream.trading_data.public_request", return_value=[])
    def test_six_statistics_jobs_share_snapshot_context_without_loading_history(self, request, _):
        original = snapshot()
        self.assertTrue(trading_data.attach(original, set(trading_data.SERIES))["statisticsPending"])
        with patch.object(service, "load_history", side_effect=AssertionError("Statistics must not load history")), \
             patch.object(service, "warm_history", side_effect=AssertionError("Statistics must not touch foreground LRU")), \
             patch.object(repair, "notify_ready") as notify, self.captureOnCommitCallbacks(execute=True):
            for _ in trading_data.SERIES:
                self.assertTrue(repair.run_next("statistics"))
        self.assertEqual(request.call_count, 6)
        self.assertEqual(notify.call_count, 6)
        self.assertFalse(MarketHistoryTask.objects.filter(completed_at=0).exists())
        self.assertFalse(MarketHistoryTask.objects.filter(attempts__gt=0).exists())
        for call in request.call_args_list:
            self.assertEqual(call.args[1]["endTime"], original["items"][-1]["closeTime"])
            self.assertEqual(call.args[1]["period"], "1h")
        for name in trading_data.SERIES:
            self.assertEqual(cache.get(trading_data.series_key(original, name)), [])

    @patch("common.binance.rate_limit_cooldown_remaining", return_value=0)
    @patch("market_stream.trading_data.public_request", return_value=[])
    def test_missing_context_retries_without_false_ready_or_history_read(self, request, _):
        trading_data.attach(snapshot(), {"openInterest"})
        cache.clear()  # Eviction / rollout before the HTTP context existed.
        with patch.object(service, "load_history", side_effect=AssertionError("No history fallback")), \
             patch.object(repair, "notify_ready") as notify, self.captureOnCommitCallbacks(execute=True):
            repair.run_next("statistics")
        task = MarketHistoryTask.objects.get()
        self.assertEqual(task.completed_at, 0)
        self.assertEqual(task.attempts, 1)
        self.assertEqual(task.lease_until, 0)
        self.assertGreater(task.due_at, 0)
        request.assert_not_called()
        notify.assert_not_called()

    @patch("common.binance.rate_limit_cooldown_remaining", return_value=0)
    @patch("market_stream.trading_data.public_request", return_value=[])
    def test_queued_statistics_follow_the_latest_requested_bucket(self, request, _):
        trading_data.attach(snapshot(), {"openInterest"})
        newer = snapshot(7200000)
        trading_data.attach(newer, {"openInterest"})
        with patch.object(repair, "notify_ready"):
            repair.run_next("statistics")
        self.assertEqual(request.call_args.args[1]["endTime"], newer["items"][-1]["closeTime"])
        self.assertIsNone(cache.get(trading_data.series_key(snapshot(), "openInterest")))
        self.assertEqual(cache.get(trading_data.series_key(newer, "openInterest")), [])


@override_settings(USE_REDIS_CACHE=True)
class HistoryRevisionLifecycleTests(IsolatedMarketRedisMixin, TransactionTestCase):
    def setUp(self):
        cache.clear()
        service.persist([closed(), closed(symbol="ETHUSDT")])

    @staticmethod
    def key(symbol="BTCUSDT", boundary="latest", revision=None):
        revision = revision or cache.get(f"market:revision:{symbol}:1m", "initial")
        return f"market:history:v4:{symbol}:1m:{boundary}:{revision}"

    def test_commit_reclaims_old_latest_and_page_windows_only_for_changed_stream(self):
        latest = self.key()
        page = self.key(boundary=60000)
        other = self.key("ETHUSDT")
        service.warm_history("BTCUSDT", "1m")
        service.warm_history("BTCUSDT", "1m", before=60000)
        service.warm_history("ETHUSDT", "1m")
        bus.connection().set("qa:account-lease", "private-fixture")
        service.persist([closed(price="1.6")])
        self.assertIsNone(history_cache.get(latest))
        self.assertIsNone(history_cache.get(page))
        self.assertIsNotNone(history_cache.get(other))
        self.assertEqual(bus.connection().get("qa:account-lease"), b"private-fixture")
        self.assertEqual(bus.connection().zcard(cache.make_key(history_cache.INDEX)), 1)

    def test_rolled_back_write_keeps_previous_revision_and_window(self):
        key = self.key()
        rows = service.warm_history("BTCUSDT", "1m")
        with self.assertRaisesRegex(RuntimeError, "rollback"):
            with transaction.atomic():
                service.persist([closed(price="1.7")])
                raise RuntimeError("rollback")
        self.assertEqual(self.key(), key)
        self.assertEqual(history_cache.get(key), rows)

    def test_late_old_builder_returns_its_snapshot_but_cannot_refill_the_cache(self):
        entered, release = threading.Event(), threading.Event()
        builder_thread = []
        old_key = self.key()
        convert = service.from_model
        def paused(row):
            if not builder_thread:
                builder_thread.append(threading.get_ident())
            if threading.get_ident() == builder_thread[0]:
                entered.set()
                if not release.wait(3):
                    raise AssertionError("Builder was not released")
            return convert(row)
        with ThreadPoolExecutor(1) as pool:
            with patch.object(service, "from_model", side_effect=paused):
                reading = pool.submit(service.warm_history, "BTCUSDT", "1m")
                try:
                    self.assertTrue(entered.wait(2))
                    service.persist([closed(price="1.8")])
                    fresh = service.warm_history("BTCUSDT", "1m")
                finally:
                    release.set()
                old = reading.result(3)
        self.assertEqual(old[-1]["closePrice"], "1.500000000000000000")
        self.assertIsNone(history_cache.get(old_key))
        self.assertEqual(fresh[-1]["closePrice"], "1.800000000000000000")
        self.assertEqual(history_cache.get(self.key()), fresh)
        self.assertEqual(bus.connection().zcard(cache.make_key(history_cache.INDEX)), 1)

    @patch("market_stream.history_cache.MAX_WINDOWS", 2)
    @patch("common.binance.rate_limit_cooldown_remaining", return_value=0)
    @patch("market_stream.trading_data.public_request", return_value=[])
    def test_statistics_of_another_symbol_leave_a_full_foreground_lru_unchanged(self, request, _):
        stats = {**snapshot(), "symbol": "SOLUSDT"}
        trading_data.attach(stats, set(trading_data.SERIES))
        foreground = {}
        for symbol in ("BTCUSDT", "ETHUSDT"):
            foreground[self.key(symbol)] = service.warm_history(symbol, "1m")
        client = bus.connection()
        before = client.zrange(cache.make_key(history_cache.INDEX), 0, -1, withscores=True)
        with patch.object(repair, "notify_ready"):
            for _ in trading_data.SERIES:
                repair.run_next("statistics")
        self.assertEqual(request.call_count, 6)
        self.assertEqual(client.zrange(cache.make_key(history_cache.INDEX), 0, -1, withscores=True), before)
        for key, rows in foreground.items():
            self.assertEqual(history_cache.get(key), rows)

    def test_cache_connection_failure_still_returns_the_local_snapshot(self):
        from redis.exceptions import ConnectionError
        with patch.object(history_cache, "redis_client", side_effect=ConnectionError):
            rows = service.warm_history("BTCUSDT", "1m")
        self.assertEqual(rows[-1]["closePrice"], "1.500000000000000000")

    @patch("market_stream.history_cache.MAX_WINDOWS", 2)
    def test_revision_rotation_does_not_evict_another_hot_stream(self):
        other = self.key("ETHUSDT")
        service.warm_history("ETHUSDT", "1m")
        for index in range(5):
            service.persist([closed(price=str(1.1 + index / 10))])
            service.warm_history("BTCUSDT", "1m")
        self.assertIsNotNone(history_cache.get(other))
        self.assertEqual(bus.connection().zcard(cache.make_key(history_cache.INDEX)), 2)
