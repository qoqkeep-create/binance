import json
from datetime import timedelta
from decimal import Decimal
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from django.test import TestCase, override_settings
from positions.models import Order, PositionProfitAlert, PositionProfitWatch
from positions.profit_alerts import (THRESHOLDS, claim_profit_alert, dispatch_profit_alerts,
    observe_profit_alerts, send_echobell, scan_profit_alerts, load_live_profit_orders)
from users.models import User
from api_bindings.models import ApiBinding


@override_settings(POSITION_PROFIT_CALL_ENABLED=True,
    POSITION_PROFIT_CALL_URL='https://hook.echobell.one/t/test-channel-token')
class ProfitAlertTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(email='profit@example.com', password='test-only')
        self.config = override_settings(POSITION_PROFIT_CALL_USER_ID=self.user.pk)
        self.config.enable()
        self.addCleanup(self.config.disable)
        self.order = self.make_order()
        self.binding = ApiBinding.objects.create(user=self.user, api_key='test-only', secret_key='test-only',
            passphrase='', alias='test', api_key_fingerprint='current-key')

    def make_order(self, **kwargs):
        fields = dict(user=self.user, symbol='BTCUSDT', side=0, size=1, open_price=100,
            initial_stop_price=90, stop_loss_price=90, stop_loss_amount=10,
            leverage=10, api_key_fingerprint='current-key')
        fields.update(kwargs)
        return Order.objects.create(**fields)

    def live(self, pnl='10', order=None):
        order = order or self.order
        return {order.pk: (order, Decimal(pnl))}

    def test_all_thresholds_and_persistent_deduplication(self):
        observe_profit_alerts(self.live('80'))
        self.assertEqual(list(PositionProfitAlert.objects.order_by('threshold').values_list('threshold', flat=True)), list(THRESHOLDS))
        observe_profit_alerts(self.live('0'))
        observe_profit_alerts(self.live('90'))
        self.assertEqual(PositionProfitAlert.objects.count(), 9)
        second = self.make_order(binance_order_id='new-order')
        observe_profit_alerts(self.live('10', second))
        self.assertEqual(PositionProfitAlert.objects.count(), 10)

    def test_crossing_and_risk_frozen_after_stop_moves(self):
        observe_profit_alerts(self.live('9.99'))
        self.assertEqual(PositionProfitAlert.objects.count(), 0)
        self.order.stop_loss_amount = Decimal('1')
        self.order.current_stop_price = Decimal('110')
        self.order.save()
        observe_profit_alerts(self.live('15.01'))
        self.assertEqual(PositionProfitAlert.objects.count(), 2)
        self.assertEqual(PositionProfitWatch.objects.get().risk_amount, 10)

    def test_invalid_pnl_risk_and_other_users(self):
        for bad in ('NaN', 'Infinity', '-Infinity'):
            observe_profit_alerts(self.live(bad))
        self.order.stop_loss_amount = 0
        observe_profit_alerts(self.live('100'))
        self.order.stop_loss_amount = 10
        self.order.user = User.objects.create_user(email='other@example.com', password='test-only')
        observe_profit_alerts(self.live('100'))
        self.assertEqual(PositionProfitAlert.objects.count(), 0)

    def test_only_remaining_unrealized_profit_after_partial_reduction(self):
        self.order.size = Decimal('0.5')
        self.order.realized_pnl = Decimal('500')
        observe_profit_alerts(self.live('8'))
        self.assertEqual(PositionProfitAlert.objects.count(), 0)

    @patch('positions.profit_alerts.load_live_profit_orders')
    @patch('positions.profit_alerts.send_echobell')
    def test_cooldown_and_concise_payload(self, send, load):
        observe_profit_alerts(self.live('30'))
        load.return_value = (self.live('5.5'), set())
        self.assertEqual(dispatch_profit_alerts(), 1)
        self.assertEqual(dispatch_profit_alerts(), 0)
        self.assertEqual(send.call_count, 1)
        payload = send.call_args.args[0]
        self.assertEqual(payload, {'title': 'btc 合约，浮盈0.55R，6u', 'body': 'btc 合约，浮盈0.55R，6u'})
        load.assert_called_with(fresh=True)
        alert = PositionProfitAlert.objects.get(status='sent')
        alert.attempted_at -= timedelta(seconds=61)
        alert.save()
        self.assertEqual(dispatch_profit_alerts(), 1)

    @patch('positions.profit_alerts.load_live_profit_orders')
    @patch('positions.profit_alerts.send_echobell')
    def test_closed_or_missing_exchange_position_cancel(self, send, load):
        observe_profit_alerts(self.live('20'))
        load.return_value = ({}, {self.order.pk})
        dispatch_profit_alerts()
        send.assert_not_called()
        self.assertEqual(PositionProfitAlert.objects.filter(status='cancelled').count(), 3)

    @patch('positions.profit_alerts.load_live_profit_orders')
    @patch('positions.profit_alerts.send_echobell', side_effect=TimeoutError('secret-url-must-not-leak'))
    def test_unknown_never_retries_or_stores_exception(self, send, load):
        observe_profit_alerts(self.live())
        load.return_value = (self.live(), set())
        dispatch_profit_alerts()
        dispatch_profit_alerts()
        alert = PositionProfitAlert.objects.get()
        self.assertEqual(alert.status, 'unknown')
        self.assertNotIn('secret', alert.last_error)
        self.assertEqual(send.call_count, 1)

    def test_interrupted_sending_never_reclaimed(self):
        observe_profit_alerts(self.live())
        alert = PositionProfitAlert.objects.get()
        self.assertIsNotNone(claim_profit_alert(alert.pk))
        alert.refresh_from_db()
        alert.attempted_at -= timedelta(seconds=61)
        alert.save()
        with patch('positions.profit_alerts.load_live_profit_orders', return_value=(self.live(), set())):
            with patch('positions.profit_alerts.send_echobell') as send:
                dispatch_profit_alerts()
        alert.refresh_from_db()
        self.assertEqual(alert.status, 'unknown')
        send.assert_not_called()

    def test_closed_between_snapshot_and_claim(self):
        observe_profit_alerts(self.live())
        self.order.status = 1
        self.order.save()
        self.assertIsNone(claim_profit_alert(PositionProfitAlert.objects.get().pk))

    @override_settings(POSITION_PROFIT_CALL_ENABLED=False)
    def test_disabled_does_not_access_exchange(self):
        with patch('positions.profit_alerts.load_live_profit_orders') as load:
            self.assertEqual(scan_profit_alerts(), 0)
            self.assertEqual(dispatch_profit_alerts(), 0)
        load.assert_not_called()

    @patch('positions.profit_alerts.get_user_trading_account')
    def test_modes_sides_key_isolation_and_missing_data(self, get_account):
        short = self.make_order(symbol='ETHUSDT', side=1, trading_mode='lead')
        stale = self.make_order(symbol='SOLUSDT', api_key_fingerprint='old-key')
        external = self.make_order(symbol='XRPUSDT', position_origin=Order.ORIGIN_EXTERNAL)
        def account(user, **kwargs):
            return SimpleNamespace(user_id=user.pk, api_key_fingerprint='current-key', binding_created_at=None,
                trading_mode=kwargs['trading_mode'], identity='test-account', create_futures_client=lambda: MagicMock())
        get_account.side_effect = account
        rows = [dict(instId='BTC-USDT-SWAP', pos='1', posSide='long', upl='10'),
            dict(instId='ETH-USDT-SWAP', pos='-2', posSide='net', upl='20'),
            dict(instId='XRP-USDT-SWAP', pos='1', posSide='long', upl='NaN')]
        with patch('positions.profit_alerts.load_shared_exchange_positions', return_value=rows):
            live, invalid = load_live_profit_orders()
        self.assertEqual(set(live), {self.order.pk, short.pk})
        self.assertIn(stale.pk, invalid)
        self.assertNotIn(external.pk, invalid)

    @patch('positions.profit_alerts.get_user_trading_account', side_effect=RuntimeError('unavailable'))
    def test_exchange_failure_retains_queue(self, _):
        observe_profit_alerts(self.live())
        self.assertEqual(dispatch_profit_alerts(), 0)
        self.assertEqual(PositionProfitAlert.objects.get().status, 'pending')

    @patch('positions.profit_alerts.request.build_opener')
    def test_sender_checks_success_and_unicode(self, build):
        response = MagicMock(status=200)
        response.read.return_value = b'{"success": true}'
        build.return_value.open.return_value.__enter__.return_value = response
        send_echobell({'title': 'BTC合约 盈利达到 1R', 'body': '多单'})
        req = build.return_value.open.call_args.args[0]
        self.assertEqual(req.method, 'POST')
        self.assertEqual(json.loads(req.data)['body'], '多单')
        response.read.return_value = b'{"success": false}'
        with self.assertRaisesRegex(Exception, 'rejected'):
            send_echobell({'title': 'test'})
        response.read.return_value = b'{"success": true,"notificationTriggered":false}'
        with self.assertRaisesRegex(Exception, 'rejected'):
            send_echobell({'title': 'test'})

    def test_url_restricted_and_error_has_no_token(self):
        for url in ('http://hook.echobell.one/t/secret', 'https://other.example/t/secret',
            'https://hook.echobell.one/d/secret', 'https://hook.echobell.one/t/secret?q=x'):
            with override_settings(POSITION_PROFIT_CALL_URL=url):
                with self.assertRaisesRegex(ValueError, 'configuration'):
                    send_echobell({})

    def test_key_changed_after_snapshot_cancels_before_send(self):
        observe_profit_alerts(self.live())
        self.binding.api_key_fingerprint = 'new-key'
        self.binding.save()
        self.assertIsNone(claim_profit_alert(PositionProfitAlert.objects.get().pk))
        self.assertEqual(PositionProfitAlert.objects.get().status, 'cancelled')

    @patch('positions.profit_alerts.get_user_trading_account')
    def test_raw_invalid_pnl_does_not_use_display_fallback(self, account):
        account.return_value = SimpleNamespace(api_key_fingerprint='current-key', binding_created_at=None,
            trading_mode='ordinary', identity='test', create_futures_client=lambda: MagicMock())
        rows = [dict(instId='BTC-USDT-SWAP', pos='1', posSide='long', upl='100', rawUpl='NaN')]
        with patch('positions.profit_alerts.load_shared_exchange_positions', return_value=rows):
            live, invalid = load_live_profit_orders()
        self.assertEqual(live, {})
        self.assertNotIn(self.order.pk, invalid)

    @patch('positions.profit_alerts.get_user_trading_account')
    def test_fresh_verification_bypasses_cache_and_closed_short_is_absent(self, account):
        client = MagicMock()
        client.get_positions.return_value = {'data': [dict(instId='BTC-USDT-SWAP', pos='-1', posSide='net', upl='10')]}
        account.return_value = SimpleNamespace(api_key_fingerprint='current-key', binding_created_at=None,
            trading_mode='ordinary', identity='test', create_futures_client=lambda: client)
        with patch('positions.profit_alerts.load_shared_exchange_positions') as shared:
            live, invalid = load_live_profit_orders(fresh=True)
        shared.assert_not_called()
        client.get_positions.assert_called_once()
        self.assertEqual(live, {})
        self.assertIn(self.order.pk, invalid)
