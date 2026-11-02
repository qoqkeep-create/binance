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
    def test_signal_fans_out_once_with_independent_channels(self, echo, apns):
        event = enqueue_signal(self.message)
        enqueue_signal(self.message)
        self.assertEqual(NotificationDelivery.objects.count(),2)
        self.assertEqual(dispatch_notifications(),2)
        self.assertEqual(dispatch_notifications(),0)
        self.assertEqual(apns.call_count,1);self.assertEqual(echo.call_count,1)
        self.assertEqual(event.payload['route'],'strategy.signal')
        self.assertEqual(event.payload['direction'],'LONG')

    @patch('mobile.push.send_apns',side_effect=RuntimeError('redacted'))
    @patch('positions.profit_alerts.send_echobell')
    def test_apns_retries_without_resending_successful_echo(self, echo, apns):
        enqueue_signal(self.message)
        self.assertEqual(dispatch_notifications(),1)
        failed = NotificationDelivery.objects.get(status='failed')
        self.assertEqual(dispatch_notifications(),0)
        failed.retry_at=timezone.now()-timedelta(seconds=1);failed.save()
        apns.side_effect=None
        self.assertEqual(dispatch_notifications(),1)
        self.assertEqual(echo.call_count,1)

    @patch('mobile.push.send_apns')
    def test_reassigned_installation_cannot_receive_previous_users_queued_signal(self, apns):
        enqueue_signal(self.message)
        NotificationDelivery.objects.filter(target='echobell:signals').delete()
        self.device.user=self.other;self.device.save()
        self.assertEqual(dispatch_notifications(),0)
        apns.assert_not_called()
        self.assertEqual(NotificationDelivery.objects.get().status,'cancelled')

    @patch('positions.profit_alerts.send_echobell')
    def test_expired_echo_lease_is_not_replayed(self, echo):
        enqueue_signal(self.message)
        NotificationDelivery.objects.filter(device__isnull=False).delete()
        NotificationDelivery.objects.update(status='sending',attempts=1,lease_until=timezone.now()-timedelta(seconds=1))
        self.assertEqual(dispatch_notifications(),0)
        echo.assert_not_called()
        self.assertEqual(NotificationDelivery.objects.get().status,'unknown')

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
        self.assertEqual(NotificationDelivery.objects.get(target='echobell:signals').status,'unknown')
