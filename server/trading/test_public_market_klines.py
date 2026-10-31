import time
from unittest.mock import patch

from django.core.cache import cache
from django.contrib.auth import get_user_model
from rest_framework.test import APITestCase

from trading.constants import ALLOWED_TRADING_SYMBOLS
from trading.views import (
    MARKET_KLINE_HOT_KEY,
    MARKET_KLINE_HOT_TTL,
    _market_kline_cache_ttl,
    _market_kline_read_hot,
    _market_kline_refresh_cadence,
    warm_market_kline_caches,
)


class PublicMarketKlinesApiTests(APITestCase):
    def setUp(self):
        cache.clear()

    @staticmethod
    def _row():
        return {
            "open_time": 1_700_000_000_000,
            "open": "100",
            "high": "110",
            "low": "90",
            "close": "105",
            "volume": "12",
        }

    @patch("trading.views.binance_get_historical_candles")
    def test_public_snapshot_is_anonymous_and_uses_fixed_limit(self, mock_candles):
        mock_candles.return_value = [self._row()]

        response = self.client.get(
            "/v1/trade/market/klines-public/BTCUSDT/15m",
            {"limit": 1000},
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["data"]["symbol"], "BTCUSDT")
        self.assertEqual(response.data["data"]["interval"], "15m")
        self.assertEqual(len(response.data["data"]["candles"]), 1)
        mock_candles.assert_called_once()
        self.assertEqual(mock_candles.call_args.kwargs["bar"], "15m")
        self.assertEqual(mock_candles.call_args.kwargs["limit"], 300)

    @patch("trading.views.binance_get_historical_candles")
    def test_public_snapshot_rejects_unknown_symbol_and_interval(self, mock_candles):
        unknown_symbol = self.client.get("/v1/trade/market/klines-public/UNKNOWNUSDT/15m")
        unknown_interval = self.client.get("/v1/trade/market/klines-public/BTCUSDT/7m")

        self.assertEqual(unknown_symbol.status_code, 400)
        self.assertEqual(unknown_interval.status_code, 400)
        mock_candles.assert_not_called()

    def test_existing_market_snapshot_stays_authenticated(self):
        response = self.client.get(
            "/v1/trade/market/klines",
            {"symbol": "BTCUSDT", "interval": "15m", "limit": 300},
        )

        self.assertEqual(response.status_code, 401)

    def test_cache_lifetime_covers_background_refresh_cadence(self):
        for interval in ("3m", "15m", "1h", "4h", "1d"):
            self.assertGreater(
                _market_kline_cache_ttl(interval, now=0),
                _market_kline_refresh_cadence(interval),
            )

    def test_cache_expires_just_after_candle_boundary(self):
        self.assertEqual(_market_kline_cache_ttl("15m", now=899), 3)
        self.assertEqual(_market_kline_cache_ttl("15m", now=900), 20)

    @patch("trading.views.PINNED_TRADING_SYMBOLS", ())
    @patch("trading.views.MARKET_KLINE_WARM_BATCH_SIZE", 2)
    @patch("trading.views._market_kline_warm_entry", return_value=True)
    def test_background_warmup_limits_each_batch(self, mock_warm):
        now = time.time()
        symbols = sorted(ALLOWED_TRADING_SYMBOLS)[:3]
        cache.set(
            MARKET_KLINE_HOT_KEY,
            {
                f"{symbol}|15m|300": {"seen": now, "warmed": 0.0}
                for symbol in symbols
            },
        )

        warm_market_kline_caches()

        self.assertEqual(mock_warm.call_count, 2)

    @patch("trading.views.PINNED_TRADING_SYMBOLS", ())
    @patch("trading.views._market_kline_warm_entry", return_value=True)
    def test_background_warmup_removes_expired_entries(self, mock_warm):
        expired = time.time() - MARKET_KLINE_HOT_TTL - 1
        cache.set(
            MARKET_KLINE_HOT_KEY,
            {"BTCUSDT|15m|300": {"seen": expired, "warmed": 0.0}},
        )

        warm_market_kline_caches()

        self.assertEqual(_market_kline_read_hot(), {})
        mock_warm.assert_not_called()

    @patch("trading.views.PINNED_TRADING_SYMBOLS", ())
    def test_background_warmup_preserves_hot_entry_added_during_fetch(self):
        now = time.time()
        cache.set(
            MARKET_KLINE_HOT_KEY,
            {"BTCUSDT|15m|300": {"seen": now, "warmed": 0.0}},
        )

        def add_concurrent_entry(*_args):
            current = cache.get(MARKET_KLINE_HOT_KEY)
            current["ETHUSDT|1h|300"] = {"seen": time.time(), "warmed": 0.0}
            cache.set(MARKET_KLINE_HOT_KEY, current)
            return True

        with patch("trading.views._market_kline_warm_entry", side_effect=add_concurrent_entry):
            warm_market_kline_caches()

        self.assertIn("ETHUSDT|1h|300", _market_kline_read_hot())

    @patch("trading.views.binance_get_historical_candles", return_value=[])
    def test_empty_upstream_snapshot_is_a_gateway_error(self, _mock_candles):
        response = self.client.get("/v1/trade/market/klines-public/BTCUSDT/15m")

        self.assertEqual(response.status_code, 502)
        self.assertEqual(response.data["code"], 502)

    @patch("trading.views.binance_get_historical_candles", return_value=[])
    def test_invalid_cached_snapshot_is_not_returned_as_success(self, _mock_candles):
        cache.set(
            "trade:market-klines:BTCUSDT:15m:300",
            {"symbol": "BTCUSDT", "interval": "15m", "candles": []},
        )

        response = self.client.get("/v1/trade/market/klines-public/BTCUSDT/15m")

        self.assertEqual(response.status_code, 502)

    @patch("trading.views.binance_get_historical_candles", return_value=[])
    def test_malformed_cached_candle_is_not_returned_as_success(self, _mock_candles):
        cache.set(
            "trade:market-klines:BTCUSDT:15m:300",
            {"symbol": "BTCUSDT", "interval": "15m", "candles": [{"t": 1}]},
        )

        response = self.client.get("/v1/trade/market/klines-public/BTCUSDT/15m")

        self.assertEqual(response.status_code, 502)

    def _fresh(self, interval="1h"):
        self.client.force_authenticate(user=get_user_model()())
        return self.client.get("/v1/trade/market/klines", {
            "symbol": "BTCUSDT", "interval": interval, "fresh": "1", "limit": 300,
        })

    @patch("trading.views.binance_get_historical_candles")
    def test_fresh_snapshot_does_not_reuse_long_background_cache(self, mock_candles):
        mock_candles.return_value = [self._row()]
        self.client.get("/v1/trade/market/klines-public/BTCUSDT/1h")
        mock_candles.return_value = [{**self._row(), "close": "109", "volume": "20"}]
        first = self._fresh()
        second = self._fresh()
        self.assertEqual(first.data["data"]["candles"][0]["c"], "109")
        self.assertEqual(second.data, first.data)
        self.assertEqual(mock_candles.call_count, 2)

    @patch("trading.views.binance_get_historical_candles")
    def test_fresh_cache_uses_two_second_ttl_and_interval_specific_keys(self, mock_candles):
        mock_candles.return_value = [self._row()]
        with patch("trading.market_snapshots.cache.set", wraps=cache.set) as cache_set:
            self._fresh("1h")
            self._fresh("15m")
        writes = [call for call in cache_set.call_args_list if str(call.args[0]).endswith(":fresh")]
        self.assertEqual(len(writes), 2)
        self.assertTrue(all(call.kwargs["timeout"] == 2 for call in writes))
        cache.delete("trade:market-klines:BTCUSDT:1h:300:fresh")
        self._fresh("1h")
        self.assertEqual(mock_candles.call_count, 3)

    @patch("trading.views.binance_get_historical_candles")
    def test_fresh_upstream_failure_does_not_return_stale_success(self, mock_candles):
        mock_candles.return_value = [self._row()]
        self.client.get("/v1/trade/market/klines-public/BTCUSDT/1h")
        mock_candles.return_value = []
        self.assertEqual(self._fresh().status_code, 502)
        self.assertIsNone(cache.get("trade:market-klines:BTCUSDT:1h:300:fresh:lock"))

    @patch("trading.views.binance_get_historical_candles")
    def test_public_caller_cannot_bypass_cache_with_fresh_parameter(self, mock_candles):
        mock_candles.return_value = [self._row()]
        url = "/v1/trade/market/klines-public/BTCUSDT/1h"
        self.client.get(url)
        self.client.get(url, {"fresh": "1"})
        mock_candles.assert_called_once()

    @patch("trading.market_snapshots.time.sleep")
    @patch("trading.views.binance_get_historical_candles")
    def test_fresh_inflight_request_has_bounded_wait_without_duplicate_fetch(self, mock_candles, _sleep):
        cache.set("trade:market-klines:BTCUSDT:1h:300:fresh:lock", "another-worker", 60)
        self.assertEqual(self._fresh().status_code, 503)
        mock_candles.assert_not_called()
        self.assertEqual(cache.get("trade:market-klines:BTCUSDT:1h:300:fresh:lock"), "another-worker")

    @patch("trading.views.binance_get_historical_candles")
    def test_fresh_waiter_reuses_completed_request(self, mock_candles):
        key = "trade:market-klines:BTCUSDT:1h:300:fresh"
        cache.set(f"{key}:lock", "another-worker", 60)
        data = {"symbol": "BTCUSDT", "interval": "1h", "candles": [{
            "t": 1_700_000_000, "o": "100", "h": "110", "l": "90", "c": "105", "v": "12",
        }]}
        with patch("trading.market_snapshots.time.sleep", side_effect=lambda _: cache.set(key, data, 2)):
            response = self._fresh()
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["data"], data)
        mock_candles.assert_not_called()
