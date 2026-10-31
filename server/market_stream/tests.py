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
from market_stream import service


class MarketHistoryTests(TestCase):
    def setUp(self):
        cache.clear()

    def rows(self, count=5):
        return [[i*60000, "1", "2", "1", "1.5", "3", i*60000+59999, "4.5"] for i in range(count)]

    @patch("market_stream.service.time.time", return_value=600)
    @patch("market_stream.service.public_request")
    def test_stale_database_tail_is_repaired_even_when_page_is_full(self, request, _time):
        service.persist([rest_candle("BTCUSDT", "1m", row, 600000) for row in self.rows()])
        request.return_value = [[540000, "1", "2", "1", "1.5", "3", 599999, "4.5"]]
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
