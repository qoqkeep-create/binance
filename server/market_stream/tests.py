from django.test import SimpleTestCase
from market_stream.core import aggregate_complete, normalize_kline, number, rest_candle


class MarketCoreTests(SimpleTestCase):
    def minute(self, time):
        return {"symbol": "BTCUSDT", "interval": "1m", "openTime": time,
                "closeTime": time + 59999, "eventTime": time + 60000,
                "openPrice": "100.1", "highPrice": "102", "lowPrice": "99",
                "closePrice": "101", "volume": "0.1", "quoteVolume": "10.01", "closed": True}

    def test_complete_bucket_keeps_decimal_volume(self):
        rows = [self.minute(i * 60000) for i in range(5)]
        result = aggregate_complete(rows[::-1], "5m")
        self.assertEqual(result["volume"], "0.5")
        self.assertEqual(result["quoteVolume"], "50.05")
        self.assertEqual(result["closeTime"], 299999)

    def test_missing_duplicate_and_unclosed_minutes_are_not_completed(self):
        rows = [self.minute(i * 60000) for i in range(5)]
        self.assertIsNone(aggregate_complete(rows[:-1], "5m"))
        self.assertIsNone(aggregate_complete(rows + [rows[0]], "5m"))
        rows[2]["closed"] = False
        self.assertIsNone(aggregate_complete(rows, "5m"))

    def test_mid_bucket_does_not_fabricate_opening_minutes(self):
        self.assertIsNone(aggregate_complete([self.minute(i * 60000) for i in range(1, 6)], "5m"))

    def test_nonfinite_or_negative_prices_rejected(self):
        for value in ("NaN", "Infinity", "-1", None):
            with self.assertRaises(ValueError):
                number(value)

    def test_continuous_event_maps_contract_pair_and_exchange_time(self):
        event = {"ps": "BTCUSDT", "E": 1234, "k": {"i": "1m", "t": 0, "T": 59999,
                 "o": "1", "h": "2", "l": "1", "c": "2", "v": "3", "q": "5", "x": False}}
        result = normalize_kline(event)
        self.assertEqual(result["symbol"], "BTCUSDT")
        self.assertEqual(result["eventTime"], 1234)
        self.assertFalse(result["closed"])

    def test_rest_only_marks_elapsed_candles_closed(self):
        row = [0, "1", "2", "1", "2", "3", 59999, "5"]
        self.assertFalse(rest_candle("BTCUSDT", "1m", row, 1000)["closed"])
        self.assertTrue(rest_candle("BTCUSDT", "1m", row, 60000)["closed"])

from unittest.mock import patch
from django.test import TestCase
from django.core.cache import cache
from market_stream.models import MarketCandle
from market_stream import repair, service


class MarketHistoryTests(TestCase):
    def setUp(self):
        cache.clear()
        notice = patch("market_stream.repair.notify_ready")
        notice.start()
        self.addCleanup(notice.stop)

    def rows(self, count=5):
        return [[i*60000, "1", "2", "1", "1.5", "3", i*60000+59999, "4.5"] for i in range(count)]

    @patch("market_stream.service.time.time", return_value=600)
    @patch("market_stream.service.public_request")
    def test_stale_database_tail_is_repaired_even_when_page_is_full(self, request, _time):
        service.persist([rest_candle("BTCUSDT", "1m", row, 600000) for row in self.rows()])
        request.return_value = [[540000, "1", "2", "1", "1.5", "3", 599999, "4.5"]]
        result = service.load_history("BTCUSDT", "1m", 5)
        self.assertEqual(result["lastOpenTime"], 240000)
        self.assertTrue(result["historyPending"])
        request.assert_not_called()
        with self.captureOnCommitCallbacks(execute=True):
            self.assertTrue(repair.run_next())
        result = service.load_history("BTCUSDT", "1m", 5)
        self.assertEqual(result["lastOpenTime"], 540000)
        self.assertFalse(result["stale"])
        self.assertEqual(MarketCandle.objects.count(), 6)
        request.assert_called_once()

    @patch("market_stream.service.time.time", return_value=600)
    @patch("market_stream.service.public_request")
    def test_history_before_is_exclusive_and_does_not_include_live(self, request, _time):
        service.persist([rest_candle("BTCUSDT", "1m", row, 600000) for row in self.rows()])
        cache.set("market:live:BTCUSDT:1m", {"openTime": 600000}, 60)
        result = service.load_history("BTCUSDT", "1m", 2, before=180000)
        self.assertEqual([row["openTime"] for row in result["items"]], [60000, 120000])
        request.assert_not_called()

    def test_snapshot_revision_is_published_only_after_commit(self):
        with self.captureOnCommitCallbacks(execute=True) as callbacks:
            service.persist([rest_candle("BTCUSDT", "1m", self.rows(1)[0], 600000)])
            self.assertIsNone(cache.get("market:revision:BTCUSDT:1m"))
        self.assertEqual(len(callbacks), 1)
        self.assertIsNotNone(cache.get("market:revision:BTCUSDT:1m"))

    def test_duplicate_repair_updates_one_identity(self):
        row = rest_candle("BTCUSDT", "1m", self.rows(1)[0], 600000)
        service.persist([row]); service.persist([row])
        self.assertEqual(MarketCandle.objects.count(), 1)

    @patch("market_stream.service.public_request")
    def test_repair_finds_gap_older_than_latest_500_minutes(self, request):
        def row(at):
            return [at, "1", "2", "1", "1.5", "3", at+59999, "4.5"]
        now = 1000 * 60000
        service.persist([rest_candle("BTCUSDT", "1m", row(at*60000), now) for at in [1, 702, 999]])
        request.return_value = [row(at*60000) for at in range(2, 702)]
        self.assertEqual(service.repair_minute_gaps("BTCUSDT", now=now), 700)
        params = request.call_args.args[1]
        self.assertEqual(params["startTime"], 120000)
        self.assertEqual(params["endTime"], 702*60000-1)
        self.assertEqual(MarketCandle.objects.count(), 703)

    def test_retention_removes_only_expired_candles(self):
        day = 86400000
        rows = self.rows(2)
        service.persist([rest_candle("BTCUSDT", "1m", row, 10*day) for row in rows])
        service.persist([rest_candle("BTCUSDT", "1h", rows[0], 10*day)])
        service.prune_history(now=10*day, batch_size=1)
        self.assertFalse(MarketCandle.objects.filter(interval="1m").exists())
        self.assertTrue(MarketCandle.objects.filter(interval="1h").exists())


class BackgroundRepairTests(TestCase):
    def setUp(self):
        cache.clear()
        notice = patch("market_stream.repair.notify_ready")
        notice.start()
        self.addCleanup(notice.stop)

    @patch("market_stream.service.public_request", side_effect=AssertionError("HTTP must not call Binance"))
    def test_empty_read_is_immediate_and_coalesces_repair(self, request):
        from market_stream.models import MarketHistoryTask
        for _ in range(3):
            result = service.load_history("BTCUSDT", "1h", 1500)
            self.assertEqual(result["items"], [])
            self.assertTrue(result["historyPending"])
        self.assertEqual(MarketHistoryTask.objects.count(), 1)
        request.assert_not_called()

    @patch("market_stream.service.public_request", side_effect=TimeoutError)
    def test_failure_retries_with_backoff_and_expired_lease_recovers(self, request):
        task = repair.schedule("BTCUSDT", "1h")
        self.assertTrue(repair.run_next())
        task.refresh_from_db()
        self.assertEqual(task.attempts, 1)
        self.assertEqual(task.lease_until, 0)
        self.assertFalse(repair.run_next())
        task.due_at = 0
        task.lease_until = 1  # Previous process died after claiming it.
        task.save()
        self.assertTrue(repair.run_next())
        self.assertEqual(request.call_count, 2)

    @patch("market_stream.service.public_request", side_effect=TimeoutError)
    def test_page_polling_does_not_reset_retry_backoff(self, request):
        import time
        task = repair.schedule("BTCUSDT", "1h")
        task.completed_at = time.time() - 100
        task.save()
        repair.run_next()
        task.refresh_from_db()
        due = task.due_at
        service.load_history("BTCUSDT", "1h", 1500)
        task.refresh_from_db()
        self.assertEqual(task.due_at, due)
        self.assertFalse(repair.run_next())

    @patch("market_stream.service.public_request")
    def test_pagination_stops_at_retention_without_exchange_request(self, request):
        repair.schedule("BTCUSDT", "1m", before=1)
        repair.run_next()
        request.assert_not_called()

    @patch("market_stream.service.time.time", return_value=600)
    @patch("market_stream.service.public_request")
    def test_background_repairs_five_minute_internal_gap(self, request, _):
        from market_stream.models import MarketHistoryTask
        def row(at):
            return [at, "1", "2", "1", "1.5", "3", at+299999, "4.5"]
        # A full local tail does not hide an older internal gap.
        service.persist([rest_candle("BTCUSDT", "5m", row(at), 600000) for at in [-300000, 300000]])
        task = repair.schedule("BTCUSDT", "5m", kind="maintenance")
        request.return_value = [row(0)]
        repair.run_next()
        self.assertEqual(request.call_args.args[1]["startTime"], 0)
        self.assertEqual(request.call_args.args[1]["endTime"], 299999)
        self.assertEqual(MarketCandle.objects.count(), 3)

    def test_every_supported_interval_repairs_its_own_gap(self):
        from market_stream.core import INTERVAL_MS
        from market_stream.models import MarketHistoryTask
        for interval, width in INTERVAL_MS.items():
            with self.subTest(interval=interval):
                now = width * 10
                def row(at):
                    return [at, "1", "2", "1", "1.5", "3", at+width-1, "4.5"]
                service.persist([rest_candle("BTCUSDT", interval, row(width*i), now) for i in [7, 9]])
                task = MarketHistoryTask(symbol="BTCUSDT", interval=interval, kind="maintenance")
                with patch("market_stream.service.time.time", return_value=now/1000), patch(
                        "market_stream.service.public_request", return_value=[row(width*8)]) as request:
                    repair.repair_history(task)
                self.assertEqual(request.call_args.args[1]["startTime"], width*8)
                self.assertEqual(request.call_args.args[1]["endTime"], width*9-1)
                self.assertEqual(MarketCandle.objects.filter(interval=interval).count(), 3)

    @patch("market_stream.service.time.time", return_value=600)
    @patch("market_stream.service.public_request", return_value=[])
    def test_new_listing_boundary_does_not_spin_or_wait_forever(self, request, _):
        repair.schedule("NEWUSDT", "1d")
        repair.run_next()
        result = service.load_history("NEWUSDT", "1d", 1500)
        self.assertFalse(result["historyPending"])
        self.assertFalse(result["hasMoreHistory"])
        self.assertFalse(repair.run_next())

    @patch("market_stream.service.time.time", return_value=600)
    @patch("market_stream.service.public_request")
    def test_pagination_fetches_before_exclusive_boundary(self, request, _):
        request.return_value = [[60000, "1", "2", "1", "1.5", "3", 119999, "4.5"]]
        result = service.load_history("BTCUSDT", "1m", 1500, before=120000)
        self.assertTrue(result["historyPending"])
        with self.captureOnCommitCallbacks(execute=True):
            repair.run_next()
        self.assertEqual(request.call_args.args[1]["endTime"], 119999)
        result = service.load_history("BTCUSDT", "1m", 1500, before=120000)
        self.assertEqual([row["openTime"] for row in result["items"]], [60000])
        self.assertFalse(result["historyPending"])

    def test_seed_covers_every_interval_and_removes_delisted_jobs(self):
        from market_stream.models import MarketHistoryTask
        repair.seed(["BTCUSDT", "ETHUSDT"])
        repair.seed(["BTCUSDT"])
        self.assertEqual(set(MarketHistoryTask.objects.values_list("interval", flat=True)), {"1m", "5m", "15m", "1h", "4h", "1d"})
        self.assertEqual(MarketHistoryTask.objects.count(), 6)

    @patch("market_stream.trading_data.public_request", side_effect=AssertionError("statistics must not block HTTP"))
    def test_statistics_are_cached_or_queued_without_network(self, request):
        from market_stream import trading_data
        candle = rest_candle("BTCUSDT", "1h", [0, "1", "2", "1", "1.5", "3", 3599999, "4.5"], 3600000)
        snapshot = {"symbol": "BTCUSDT", "interval": "1h", "items": [candle]}
        first = trading_data.attach(snapshot, {"openInterest"})
        self.assertTrue(first["statisticsPending"])
        request.assert_not_called()
        cache.set(trading_data.series_key(snapshot, "openInterest"), [{"timestamp": 0, "sumOpenInterest": "42"}], 30)
        ready = trading_data.attach(snapshot, {"openInterest"})
        self.assertFalse(ready["statisticsPending"])
        self.assertEqual(ready["items"][0]["tradingData"]["openInterest"], 42)
        self.assertNotIn("tradingData", snapshot["items"][0])


class FastHistoryApiTests(TestCase):
    def setUp(self):
        from users.models import User
        from rest_framework.test import APIClient
        cache.clear()
        self.client = APIClient()
        self.client.force_authenticate(User.objects.create_user("history-qa@example.invalid", "test-only-password"))

    @patch("market_stream.service.public_request", side_effect=AssertionError("No exchange I/O in HTTP"))
    def test_api_warms_asynchronously_and_reports_timing(self, request):
        cache.set("market:universe", ["BTCUSDT"])
        response = self.client.get("/api/market/klines", {"symbol": "BTCUSDT", "interval": "1h", "limit": 1500})
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.data["data"]["historyPending"])
        self.assertIn("history;dur=", response["Server-Timing"])
        request.assert_not_called()

    @patch("market_stream.service.public_request", side_effect=AssertionError("No exchange I/O in HTTP"))
    def test_cold_universe_returns_retryable_status_without_exchange(self, request):
        response = self.client.get("/api/market/klines", {"symbol": "BTCUSDT"})
        self.assertEqual(response.status_code, 503)
        request.assert_not_called()
