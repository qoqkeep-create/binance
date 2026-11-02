from unittest.mock import patch
from django.core.cache import cache
from django.test import TestCase, override_settings
from market_analysis.trend import TrendEvent, scan_trend_signals
from trading.models import TradingViewMessage
from rest_framework.test import APIClient
from users.models import User


@override_settings(MARKET_ANALYSIS_ALERT_URL='', MARKET_ANALYSIS_ALERT_TOKEN='')
class SignalNotificationIndependenceTests(TestCase):
    def setUp(self):
        cache.clear()

    @patch('market_analysis.trend.TREND_INTERVALS', ('1h',))
    @patch('market_analysis.trend.PINNED_TRADING_SYMBOLS', ('BTCUSDT',))
    @patch('market_analysis.trend.evaluate_trend')
    def test_signal_is_stored_without_legacy_notification_gateway(self, evaluate):
        evaluate.return_value = [TrendEvent('BTCUSDT', '1h', 'entry_ema55', 'long', 100, 1793577599999)]
        result = scan_trend_signals()
        self.assertEqual(result['alerted'], 1)
        self.assertEqual(TradingViewMessage.objects.filter(source='internal').count(), 1)
        scan_trend_signals()
        self.assertEqual(TradingViewMessage.objects.count(), 1)
        client = APIClient()
        client.force_authenticate(User.objects.create(email='signal-reader@example.invalid'))
        response = client.get('/v1/trade/tradingview/signals?source=internal')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data['data'][0]['symbol'], 'BTCUSDT')

    @patch('market_analysis.trend.TREND_INTERVALS', ('1h',))
    @patch('market_analysis.trend.PINNED_TRADING_SYMBOLS', ('BTCUSDT',))
    @patch('market_analysis.trend.evaluate_trend')
    def test_failed_persistence_does_not_mark_candle_and_can_retry(self, evaluate):
        evaluate.return_value = [TrendEvent('BTCUSDT', '1h', 'entry_ema55', 'long', 100, 1793577599999)]
        with patch('mobile.push.enqueue_signal', side_effect=RuntimeError('outbox unavailable')):
            self.assertEqual(scan_trend_signals()['failed'], 1)
        self.assertEqual(TradingViewMessage.objects.count(), 0)
        self.assertIsNone(cache.get('trend:last_close:BTCUSDT:1h'))
        self.assertEqual(scan_trend_signals()['alerted'], 1)
        self.assertEqual(TradingViewMessage.objects.count(), 1)
