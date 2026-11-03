import logging
import uuid
from datetime import timedelta
from unittest.mock import MagicMock, patch

from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from mobile.models import NotificationDelivery, NotificationEvent, PushDevice
from mobile.push import dispatch_notifications, enqueue_signal, send_apns
from trading.models import TradingViewMessage
from users.models import User


@override_settings(APNS_ENABLED=True, SIGNAL_ECHOBELL_ENABLED=True)
class PushNotificationTests(TestCase):
    def test_transport_logging_does_not_expose_apns_device_urls(self):
        with patch.object(logging.getLogger(), 'handle') as root_handler:
            for name in ['httpx', 'httpcore.http2']:
                logger = logging.getLogger(name)
                logger.info('POST /3/device/test-only-token')
                logger.warning('POST /3/device/test-only-token')
        root_handler.assert_not_called()

    def setUp(self):
        self.user = User.objects.create(email='push@example.invalid')
        self.other = User.objects.create(email='other@example.invalid')
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.device = PushDevice.objects.create(user=self.user, installation_id=uuid.uuid4(),
            token='a'*64, environment='production', bundle_id='com.waibao2025.trade.integrated')
        self.message = TradingViewMessage.objects.create(source='internal', event_id='trend:BTCUSDT:1h:1',
            normalized_payload={'symbol':'BTCUSDT','signal':'BUY','interval':'1h','strategy':'SuperTrend+EMA',
                'price':100,'timestamp':1000,'comment':'测试信号'})

    def test_authenticated_registration_and_scoped_unregistration(self):
        body = {'installationId':str(self.device.installation_id),'deviceToken':'b'*64,
            'environment':'production','bundleIdentifier':self.device.bundle_id}
        self.client.force_authenticate(None)
        self.assertEqual(self.client.post('/api/push/devices/register',body).status_code,401)
        self.client.force_authenticate(self.user)
        self.assertEqual(self.client.post('/api/push/devices/register',body).status_code,200)
        self.device.refresh_from_db();self.assertEqual(self.device.token,'b'*64)
        self.client.force_authenticate(self.other)
        self.client.post('/api/push/devices/unregister',{'installationId':body['installationId']})
        self.device.refresh_from_db();self.assertTrue(self.device.active)
        self.client.force_authenticate(self.user)
        self.client.post('/api/push/devices/unregister',{'installationId':body['installationId']})
        self.device.refresh_from_db();self.assertFalse(self.device.active)

    def test_foreign_bundle_and_bad_token_are_rejected(self):
        body = {'installationId':str(uuid.uuid4()),'deviceToken':'not-a-token',
            'environment':'production','bundleIdentifier':'unrelated.app'}
        self.assertEqual(self.client.post('/api/push/devices/register',body).status_code,400)
        self.assertEqual(PushDevice.objects.count(),1)

    def test_logout_retires_only_this_installation(self):
        self.client.post('/api/auth/logout',HTTP_X_PUSH_INSTALLATION_ID=str(self.device.installation_id))
        self.device.refresh_from_db(); self.assertFalse(self.device.active)

    @patch('mobile.push.send_apns')
    @patch('positions.profit_alerts.send_echobell')
    def test_signal_uses_only_app_notifications_even_with_legacy_echo_enabled(self, echo, apns):
        event = enqueue_signal(self.message)
        enqueue_signal(self.message)
        self.assertEqual(NotificationDelivery.objects.count(),1)
        self.assertEqual(dispatch_notifications(),1)
        self.assertEqual(dispatch_notifications(),0)
        self.assertEqual(apns.call_count,1);echo.assert_not_called()
        self.assertEqual(event.payload['route'],'strategy.signal')
        self.assertEqual(event.payload['direction'],'LONG')

    @patch('mobile.push.send_apns',side_effect=RuntimeError('redacted'))
    @patch('positions.profit_alerts.send_echobell')
    def test_apns_retries_without_ever_sending_echo(self, echo, apns):
        enqueue_signal(self.message)
        self.assertEqual(dispatch_notifications(),0)
        failed = NotificationDelivery.objects.get(status='failed')
        self.assertEqual(dispatch_notifications(),0)
        failed.retry_at=timezone.now()-timedelta(seconds=1);failed.save()
        apns.side_effect=None
        self.assertEqual(dispatch_notifications(),1)
        echo.assert_not_called()

    @patch('mobile.push.send_apns')
    def test_reassigned_installation_cannot_receive_previous_users_queued_signal(self, apns):
        enqueue_signal(self.message)
        NotificationDelivery.objects.filter(target='echobell:signals').delete()
        self.device.user=self.other;self.device.save()
        self.assertEqual(dispatch_notifications(),0)
        apns.assert_not_called()
        self.assertEqual(NotificationDelivery.objects.get().status,'cancelled')

    @patch('positions.profit_alerts.send_echobell')
    def test_legacy_echo_signal_records_are_cancelled_without_delivery(self, echo):
        event = enqueue_signal(self.message)
        NotificationDelivery.objects.filter(device__isnull=False).delete()
        for status, attempts in [('pending', 0), ('failed', 1), ('sending', 1), ('sending', 8)]:
            with self.subTest(status=status, attempts=attempts):
                item = NotificationDelivery.objects.create(event=event, target='echobell:signals',
                    status=status, attempts=attempts, lease_until=timezone.now()-timedelta(seconds=1))
                self.assertEqual(dispatch_notifications(), 0)
                item.refresh_from_db()
                self.assertEqual(item.status, 'cancelled')
                self.assertEqual(item.attempts, attempts)
                item.delete()
        echo.assert_not_called()

    @override_settings(APNS_ENABLED=False)
    def test_signals_are_saved_without_falling_back_to_echo_when_app_push_is_off(self):
        enqueue_signal(self.message)
        self.assertEqual(NotificationEvent.objects.count(), 1)
        self.assertFalse(NotificationDelivery.objects.exists())

    @patch('positions.profit_alerts.send_echobell')
    @patch('mobile.push.send_apns')
    def test_external_sources_cannot_enter_the_app_signal_outbox(self, apns, echo):
        for source in ['external', 'tradingview']:
            with self.subTest(source=source):
                self.message.source = source
                self.assertIsNone(enqueue_signal(self.message))
        self.assertFalse(NotificationEvent.objects.exists())
        self.assertFalse(NotificationDelivery.objects.exists())
        self.assertEqual(dispatch_notifications(), 0)
        apns.assert_not_called()
        echo.assert_not_called()

    @patch('positions.profit_alerts.send_echobell')
    @patch('mobile.push.send_apns')
    def test_legacy_external_app_notifications_are_cancelled_without_attempts(self, apns, echo):
        for payload in [
            {'route': 'reference.trade.notification'},
            {'route': 'strategy.signal', 'source': 'external'},
            {'source': 'tradingview'},
        ]:
            event = NotificationEvent.objects.create(event_key=str(uuid.uuid4()), payload=payload)
            for status, attempts in [('pending', 0), ('failed', 1), ('sending', 8)]:
                with self.subTest(payload=payload, status=status):
                    item = NotificationDelivery.objects.create(event=event, device=self.device,
                        user_id_snapshot=self.user.id, target=f'apns:{self.device.id}',
                        status=status, attempts=attempts, lease_until=timezone.now()-timedelta(seconds=1))
                    try:
                        self.assertEqual(dispatch_notifications(), 0)
                        item.refresh_from_db()
                        self.assertEqual(item.status, 'cancelled')
                        self.assertEqual(item.attempts, attempts)
                    finally:
                        item.delete()
            sent = NotificationDelivery.objects.create(event=event, device=self.device,
                user_id_snapshot=self.user.id, target=f'apns:{self.device.id}', status='sent', attempts=1)
            self.assertEqual(dispatch_notifications(), 0)
            sent.refresh_from_db()
            self.assertEqual(sent.status, 'sent')
        apns.assert_not_called()
        echo.assert_not_called()

    @patch('mobile.push.send_apns',side_effect=RuntimeError('no delivery'))
    @patch('positions.profit_alerts.send_echobell')
    def test_attempt_limit_is_terminal_and_errors_do_not_persist_sensitive_text(self, echo, apns):
        enqueue_signal(self.message)
        NotificationDelivery.objects.filter(device__isnull=False).update(attempts=7)
        dispatch_notifications()
        item=NotificationDelivery.objects.get(device=self.device)
        self.assertEqual(item.status,'exhausted');self.assertEqual(item.attempts,8)
        self.assertEqual(item.last_error,'RuntimeError')

    @patch('mobile.push.Path')
    @patch('mobile.push._provider_token',return_value='test-only-token')
    @patch('httpx.Client')
    def test_apns_uses_signed_topic_environment_http2_and_retires_invalid_token(self, http, token, path):
        response=MagicMock(status_code=410);response.json.return_value={'reason':'Unregistered'}
        http.return_value.__enter__.return_value.post.return_value=response
        from mobile.push import PermanentPushError
        with self.assertRaises(PermanentPushError):
            send_apns(self.device,{'aps':{'alert':'test'}},'test-event')
        kwargs=http.call_args.kwargs
        self.assertTrue(kwargs['http2']);self.assertFalse(kwargs['follow_redirects'])
        args=http.return_value.__enter__.return_value.post.call_args
        self.assertTrue(args.args[0].startswith('https://api.push.apple.com/3/device/'))
        self.assertEqual(args.kwargs['headers']['apns-topic'],self.device.bundle_id)
        self.device.refresh_from_db();self.assertFalse(self.device.active)

    @patch('mobile.push.send_apns')
    @patch('positions.profit_alerts.send_echobell')
    def test_interrupted_final_attempt_reaches_terminal_status_without_resending(self, echo, apns):
        enqueue_signal(self.message)
        NotificationDelivery.objects.update(status='sending', attempts=8,
            lease_until=timezone.now()-timedelta(seconds=1))
        self.assertEqual(dispatch_notifications(),0)
        apns.assert_not_called();echo.assert_not_called()
        self.assertEqual(NotificationDelivery.objects.get(device=self.device).status,'exhausted')
        self.assertFalse(NotificationDelivery.objects.filter(target='echobell:signals').exists())


@override_settings(APNS_ENABLED=True, TRADE_NOTIFICATION_ENABLED=True,
    EXTERNAL_TRADE_SIGNAL_ENABLED=False,
    TRADE_NOTIFICATION_URL='https://hook.echobell.one/t/test-only-legacy',
    TRADE_NOTIFICATION_TOKEN='test-only-token')
class TradeNotificationAppRoutingTests(TestCase):
    def setUp(self):
        from positions.models import Order
        self.user = User.objects.create(email='trade-push@example.invalid')
        self.other = User.objects.create(email='unrelated-push@example.invalid')
        self.device = PushDevice.objects.create(user=self.user, installation_id=uuid.uuid4(),
            token='c'*64, environment='production', bundle_id='com.waibao2025.trade.integrated')
        PushDevice.objects.create(user=self.other, installation_id=uuid.uuid4(),
            token='d'*64, environment='production', bundle_id='com.waibao2025.trade.integrated')
        PushDevice.objects.create(user=self.user, installation_id=uuid.uuid4(),
            token='e'*64, environment='production', bundle_id='com.waibao2025.trade.integrated', active=False)
        PushDevice.objects.create(user=self.user, installation_id=uuid.uuid4(),
            token='f'*64, environment='production', bundle_id='unrelated.old.app')
        self.order = Order.objects.create(user=self.user, symbol='BTCUSDT', side=0,
            open_price=100, stop_loss_price=90, stop_loss_amount=10, size=1, leverage=10)

    def _enqueue(self):
        from positions.notifications import enqueue_open_notification
        with self.captureOnCommitCallbacks(execute=True):
            enqueue_open_notification(self.order)

    @patch('urllib.request.urlopen')
    @patch('positions.profit_alerts.send_echobell')
    @patch('mobile.push.send_apns')
    def test_trade_event_enters_only_owners_app_outbox_and_dispatches_once(self, apns, echo, http):
        from positions.notifications import dispatch_pending_trade_notifications, enqueue_open_notification
        from positions.models import TradeNotificationEvent
        self._enqueue()
        self.assertEqual(dispatch_pending_trade_notifications(), 1)
        self.assertEqual(dispatch_pending_trade_notifications(), 0)
        event = TradeNotificationEvent.objects.get()
        item = NotificationDelivery.objects.get()
        self.assertEqual(item.device, self.device)
        self.assertEqual(item.user_id_snapshot, self.user.id)
        self.assertEqual(item.event.payload['route'], 'trade.notification')
        self.assertEqual(item.event.payload['aps']['alert'], {'title': event.title, 'body': event.content})
        self.assertEqual(item.event.payload['orderId'], self.order.id)
        self.assertEqual(item.event.payload['tradingMode'], self.order.trading_mode)
        self.assertEqual(dispatch_notifications(), 1)
        apns.assert_called_once()
        echo.assert_not_called()
        http.assert_not_called()

    @override_settings(TRADE_NOTIFICATION_ENABLED=False)
    def test_paused_trade_notifications_keep_source_event_without_app_delivery(self):
        from positions.notifications import dispatch_pending_trade_notifications, enqueue_open_notification
        from positions.models import TradeNotificationEvent
        self._enqueue()
        self.assertEqual(dispatch_pending_trade_notifications(), 0)
        event = TradeNotificationEvent.objects.get()
        self.assertEqual(event.status, 'pending')
        self.assertEqual(event.attempt_count, 0)
        self.assertFalse(NotificationEvent.objects.exists())

    @patch('mobile.push.send_apns')
    def test_existing_trade_app_queue_pauses_without_attempts_and_resumes_once(self, apns):
        from positions.notifications import dispatch_pending_trade_notifications
        PushDevice.objects.exclude(pk=self.device.id).update(active=False)
        self._enqueue()
        self.assertEqual(dispatch_pending_trade_notifications(), 1)
        item = NotificationDelivery.objects.get()
        with override_settings(TRADE_NOTIFICATION_ENABLED=False):
            for status, attempts in [('pending', 0), ('failed', 3), ('sending', 3)]:
                with self.subTest(status=status):
                    item.status = status
                    item.attempts = attempts
                    item.retry_at = timezone.now() - timedelta(seconds=1)
                    item.lease_until = timezone.now() - timedelta(seconds=1) if status == 'sending' else None
                    item.save()
                    before = (item.status, item.attempts, item.retry_at, item.lease_until)
                    self.assertEqual(dispatch_notifications(), 0)
                    item.refresh_from_db()
                    self.assertEqual((item.status, item.attempts, item.retry_at, item.lease_until), before)
            apns.assert_not_called()
            # Even an older paused trade row must not occupy the signal batch.
            signal = TradingViewMessage.objects.create(source='internal', event_id='trend:new-signal',
                normalized_payload={'symbol': 'BTCUSDT', 'signal': 'BUY', 'interval': '1h',
                    'strategy': 'SuperTrend+EMA', 'price': 100, 'timestamp': 1000, 'comment': 'test'})
            enqueue_signal(signal)
            self.assertEqual(dispatch_notifications(limit=1), 1)
            self.assertEqual(apns.call_args.args[1]['route'], 'strategy.signal')
            item.refresh_from_db()
            self.assertEqual(item.attempts, 3)
        self.assertEqual(dispatch_notifications(), 1)
        self.assertEqual(dispatch_notifications(), 0)
        self.assertEqual(apns.call_count, 2)

    @override_settings(APNS_ENABLED=False)
    def test_disabled_app_push_does_not_consume_source_attempts_or_fallback(self):
        from positions.notifications import dispatch_pending_trade_notifications, enqueue_open_notification
        from positions.models import TradeNotificationEvent
        self._enqueue()
        self.assertEqual(dispatch_pending_trade_notifications(), 0)
        event = TradeNotificationEvent.objects.get()
        self.assertEqual(event.status, 'pending')
        self.assertEqual(event.attempt_count, 0)
        self.assertFalse(NotificationEvent.objects.exists())
