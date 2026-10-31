import time
from unittest.mock import patch

from django.core.cache import cache
from django.test import SimpleTestCase, override_settings

from trading.snapshot_prewarm import (
    SNAPSHOT_PREWARM_CADENCE_SECONDS,
    SNAPSHOT_PREWARM_MARKER_PREFIX,
    prewarm_public_snapshot_caches,
)


class SnapshotPrewarmTests(SimpleTestCase):
    def setUp(self):
        cache.clear()

    @staticmethod
    def _marker(symbol: str, interval: str) -> str:
        return f"{SNAPSHOT_PREWARM_MARKER_PREFIX}:{symbol}:{interval}"

    @override_settings(MARKET_SNAPSHOT_PREWARM_ENABLED=False, MARKET_SNAPSHOT_PREWARM_URL="https://example.test")
    @patch("trading.snapshot_prewarm.urlrequest.urlopen")
    def test_disabled_does_not_request(self, mock_urlopen):
        with patch("trading.snapshot_prewarm.PINNED_TRADING_SYMBOLS", ("BTCUSDT",)):
            result = prewarm_public_snapshot_caches()

        self.assertEqual(result, {"checked": 0, "warmed": 0, "failed": 0})
        mock_urlopen.assert_not_called()

    @override_settings(MARKET_SNAPSHOT_PREWARM_ENABLED=True, MARKET_SNAPSHOT_PREWARM_URL="https://example.test")
    @patch("trading.snapshot_prewarm.urlrequest.urlopen")
    def test_requests_every_interval_and_marks_attempt(self, mock_urlopen):
        with patch("trading.snapshot_prewarm.PINNED_TRADING_SYMBOLS", ("BTCUSDT",)):
            result = prewarm_public_snapshot_caches()

        self.assertEqual(result["warmed"], len(SNAPSHOT_PREWARM_CADENCE_SECONDS))
        self.assertEqual(mock_urlopen.call_count, len(SNAPSHOT_PREWARM_CADENCE_SECONDS))
        requested = {call.args[0] for call in mock_urlopen.call_args_list}
        self.assertIn("https://example.test/market-data/klines/BTCUSDT/3m.json", requested)
        self.assertIn("https://example.test/market-data/klines/BTCUSDT/1d.json", requested)
        self.assertIsNotNone(cache.get(self._marker("BTCUSDT", "3m")))

    @override_settings(MARKET_SNAPSHOT_PREWARM_ENABLED=True, MARKET_SNAPSHOT_PREWARM_URL="https://example.test")
    @patch("trading.snapshot_prewarm.urlrequest.urlopen")
    def test_recently_warmed_snapshot_is_skipped(self, mock_urlopen):
        cache.set(self._marker("BTCUSDT", "3m"), time.time())

        with patch("trading.snapshot_prewarm.PINNED_TRADING_SYMBOLS", ("BTCUSDT",)):
            prewarm_public_snapshot_caches()

        requested = {call.args[0] for call in mock_urlopen.call_args_list}
        self.assertNotIn("https://example.test/market-data/klines/BTCUSDT/3m.json", requested)
        self.assertIn("https://example.test/market-data/klines/BTCUSDT/15m.json", requested)

    @override_settings(MARKET_SNAPSHOT_PREWARM_ENABLED=True, MARKET_SNAPSHOT_PREWARM_URL="https://example.test")
    @patch("trading.snapshot_prewarm.urlrequest.urlopen", side_effect=OSError("boom"))
    def test_failure_is_counted_and_not_retried_each_cycle(self, mock_urlopen):
        with patch("trading.snapshot_prewarm.PINNED_TRADING_SYMBOLS", ("BTCUSDT",)):
            first = prewarm_public_snapshot_caches()
            second = prewarm_public_snapshot_caches()

        self.assertEqual(first["failed"], len(SNAPSHOT_PREWARM_CADENCE_SECONDS))
        self.assertEqual(second["checked"], 0)
        self.assertEqual(mock_urlopen.call_count, len(SNAPSHOT_PREWARM_CADENCE_SECONDS))
