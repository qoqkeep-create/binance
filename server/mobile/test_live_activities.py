import hashlib
import tempfile
import uuid
from datetime import timedelta
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from django.core.cache import cache
from django.test import SimpleTestCase, TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from api_bindings.models import ApiBinding
from common.binance import BinanceApiError
from common.utils import aes_encrypt
from mobile import live_activities as live
from mobile.models import LiveActivityRegistration, NotificationEvent, PushDevice
from users.models import User


@override_settings(APNS_ENABLED=True, LIVE_ACTIVITIES_ENABLED=True)
class LiveActivityTests(TestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create(email='live@example.invalid')
        self.other = User.objects.create(email='live-other@example.invalid')
        self.binding = self.make_binding(self.user, 'ordinary', 'live-test-key')
        self.installation = uuid.uuid4()
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.body = {'installationId': str(self.installation), 'activityId': 'activity-one',
            'pushToken': 'a' * 64, 'environment': 'production', 'bundleIdentifier': 'com.waibao2025.trade.integrated',
            'tradingMode': 'ordinary', 'frequentUpdates': True, 'startedAt': timezone.now().timestamp()}
        self.body['tokenUpdatedAt'] = self.body['startedAt']
        self.state = {'positions': [{'id': 'BTCUSDT:long', 'symbol': 'BTCUSDT', 'isShort': False,
            'profit': '+12.34 U'}], 'totalCount': 1, 'updatedAt': int(timezone.now().timestamp()), 'status': ''}
        self.transport = patch.object(live, 'send_live_activity').start()
        self.addCleanup(patch.stopall)

    def make_binding(self, user, mode, key):
        return ApiBinding.objects.create(user=user, trading_mode=mode, alias='test only',
            api_key=aes_encrypt(key), secret_key=aes_encrypt('test-only-secret'), passphrase=aes_encrypt(''),
            api_key_fingerprint=hashlib.sha256(key.encode()).hexdigest())

    def register(self, **changes):
        return self.client.post('/api/push/live-activities/register', {**self.body, **changes}, format='json')

    def dispatch(self):
        with patch.object(live, '_load_state', return_value=self.state) as fetch:
            result = live.dispatch_live_activities()
        return result, fetch

    def test_authenticated_registration_has_separate_token_and_binding_identity(self):
        self.client.force_authenticate(None)
        self.assertEqual(self.register().status_code, 401)
        self.client.force_authenticate(self.user)
        self.assertEqual(self.register(environment='development').status_code, 200)
        item = LiveActivityRegistration.objects.get()
        self.assertEqual(item.environment, 'sandbox')
        self.assertEqual(item.user, self.user)
        self.assertEqual(item.binding_id_snapshot, self.binding.pk)
        self.assertEqual(item.binding_fingerprint, self.binding.api_key_fingerprint)
        self.assertEqual(item.binding_created_at, self.binding.created_at)
        self.assertFalse(PushDevice.objects.exists())
        self.assertFalse(NotificationEvent.objects.exists())

    def test_malformed_tokens_bundle_mode_and_start_time_are_rejected(self):
        for body in ({'pushToken': 'a' * 65}, {'pushToken': 'z' * 64}, {'pushToken': 'a' * 514},
                     {'bundleIdentifier': 'other.app'}, {'tradingMode': 'unknown'},
                     {'startedAt': timezone.now().timestamp() + 120}, {'startedAt': 1},
                     {'startedAt': 'nan'}, {'tokenUpdatedAt': 'nan'},
                     {'tokenUpdatedAt': timezone.now().timestamp() + 120}):
            with self.subTest(body=body):
                self.assertEqual(self.register(**body).status_code, 400)
        self.assertFalse(LiveActivityRegistration.objects.exists())

    def test_binding_is_required_and_registration_never_calls_exchange(self):
        with patch.object(live.BinanceFuturesClient, 'get_positions', side_effect=AssertionError('network')):
            self.assertEqual(self.register().status_code, 200)
            self.binding.status = 0
            self.binding.save(update_fields=['status'])
            self.assertEqual(self.register(activityId='new').status_code, 400)

    def test_token_rotation_is_fenced_and_does_not_extend_ttl(self):
        self.register()
        initial = LiveActivityRegistration.objects.get()
        self.assertEqual(self.register(pushToken='b' * 64, startedAt=self.body['startedAt'] + 1,
            tokenUpdatedAt=self.body['tokenUpdatedAt'] + 0.1, frequentUpdates=False).status_code, 200)
        item = LiveActivityRegistration.objects.get()
        self.assertEqual(item.pk, initial.pk)
        self.assertEqual(item.push_token, 'b' * 64)
        self.assertEqual(item.expires_at, initial.expires_at)
        self.assertEqual(item.activity_started_at, initial.activity_started_at)
        self.assertGreater(item.fence, initial.fence)
        self.assertFalse(item.frequent_updates)

    def test_out_of_order_token_registration_cannot_overwrite_new_token(self):
        self.register()
        self.assertEqual(self.register(pushToken='b' * 64,
            tokenUpdatedAt=self.body['tokenUpdatedAt'] + 0.2).status_code, 200)
        original = LiveActivityRegistration.objects.get()
        self.assertEqual(self.register(pushToken='b' * 64,
            tokenUpdatedAt=self.body['tokenUpdatedAt'] + 0.2).status_code, 200)
        self.assertEqual(LiveActivityRegistration.objects.get().expires_at, original.expires_at)
        for changes in ({'pushToken': 'a' * 64}, {'pushToken': 'c' * 64,
                'tokenUpdatedAt': self.body['tokenUpdatedAt'] + 0.2}):
            self.assertEqual(self.register(**changes).status_code, 409)
        self.assertEqual(LiveActivityRegistration.objects.get().push_token, 'b' * 64)

    def test_fractional_restart_orders_requests_within_same_second(self):
        stamp = int(timezone.now().timestamp()) - 1
        self.register(startedAt=stamp + 0.1)
        self.assertEqual(self.register(activityId='activity-new', startedAt=stamp + 0.2).status_code, 200)
        self.assertEqual(self.register(activityId='activity-old', startedAt=stamp + 0.15).status_code, 409)
        self.assertEqual(LiveActivityRegistration.objects.get().activity_id, 'activity-new')

    def test_future_clock_skew_never_extends_eight_hour_ttl(self):
        before = timezone.now()
        self.assertEqual(self.register(startedAt=(before + timedelta(seconds=20)).timestamp()).status_code, 200)
        item = LiveActivityRegistration.objects.get()
        self.assertGreater(item.activity_started_at, before)
        self.assertLess(item.expires_at, before + timedelta(hours=8, seconds=1))

    def test_duplicate_activity_token_does_not_reassign_other_installation(self):
        self.register()
        self.make_binding(self.other, 'ordinary', 'other-test-key')
        self.client.force_authenticate(self.other)
        self.assertEqual(self.register(installationId=str(uuid.uuid4())).status_code, 409)
        self.assertEqual(LiveActivityRegistration.objects.get().user_id, self.user.pk)

    def test_installation_owner_change_cannot_reuse_old_activity_or_inflight_snapshot(self):
        self.register()
        old = live._claim(LiveActivityRegistration.objects.get().pk, timezone.now())
        self.make_binding(self.other, 'ordinary', 'other-test-key')
        self.client.force_authenticate(self.other)
        self.assertEqual(self.register(pushToken='b' * 64).status_code, 409)
        self.assertEqual(self.register(activityId='new-owner-activity', pushToken='b' * 64,
            startedAt=self.body['startedAt'] + 0.25).status_code, 200)
        self.assertEqual(live._finish(old, ended=True), 0)
        item = LiveActivityRegistration.objects.get()
        self.assertEqual(item.user_id, self.other.pk)
        self.assertTrue(item.active)
        self.assertEqual(item.push_token, 'b' * 64)
        self.client.force_authenticate(self.user)
        self.client.post('/api/push/live-activities/unregister',
            {'installationId': str(self.installation), 'activityId': 'new-owner-activity'})
        item.refresh_from_db()
        self.assertTrue(item.active)

    def test_scoped_unregister_and_logout_queue_end_without_network(self):
        self.register()
        self.client.force_authenticate(self.other)
        self.client.post('/api/push/live-activities/unregister',
            {'installationId': str(self.installation), 'activityId': 'activity-one'})
        self.assertTrue(LiveActivityRegistration.objects.get().active)
        self.client.force_authenticate(self.user)
        self.client.post('/api/push/live-activities/unregister',
            {'installationId': str(self.installation), 'activityId': 'activity-older'})
        self.assertTrue(LiveActivityRegistration.objects.get().active)
        self.client.post('/api/auth/logout', HTTP_X_PUSH_INSTALLATION_ID=str(self.installation))
        item = LiveActivityRegistration.objects.get()
        self.assertFalse(item.active)
        self.assertTrue(item.end_requested)
        self.transport.assert_not_called()
        self.assertEqual(self.register().status_code, 409, 'An ended activity cannot be silently restarted')

    def test_delayed_unregister_cannot_end_new_activity(self):
        stamp = timezone.now().timestamp() - 2
        self.register(startedAt=stamp)
        self.register(activityId='activity-new', startedAt=stamp + 0.5)
        self.client.post('/api/push/live-activities/unregister',
            {'installationId': str(self.installation), 'activityId': 'activity-one'})
        self.assertTrue(LiveActivityRegistration.objects.get().active)

    def test_dispatch_sends_silent_content_state_without_an_alert_or_echo_event(self):
        self.register()
        result, fetch = self.dispatch()
        self.assertEqual(result, 1)
        self.assertEqual(fetch.call_count, 1)
        item, payload = self.transport.call_args.args
        self.assertEqual(item.user_id, self.user.pk)
        self.assertEqual(payload['aps']['event'], 'update')
        self.assertEqual(payload['aps']['content-state'], self.state)
        self.assertEqual(payload['aps']['stale-date'], self.state['updatedAt'] + 90)
        self.assertNotIn('alert', payload['aps'])
        self.assertNotIn('sound', payload['aps'])
        self.assertFalse(NotificationEvent.objects.exists())
        self.assertFalse(PushDevice.objects.exists())

    def test_frequent_and_standard_update_intervals_are_respected(self):
        for frequent, minimum in ((True, 15), (False, 60)):
            with self.subTest(frequent=frequent):
                LiveActivityRegistration.objects.all().delete()
                self.register(frequentUpdates=frequent)
                before = timezone.now()
                self.dispatch()
                item = LiveActivityRegistration.objects.get()
                self.assertGreaterEqual(item.next_update_at, before + timedelta(seconds=minimum))
                self.transport.reset_mock()
                self.assertEqual(self.dispatch()[0], 0)
                self.transport.assert_not_called()

    def test_two_installations_share_only_same_owner_mode_snapshot(self):
        self.register()
        self.register(installationId=str(uuid.uuid4()), activityId='activity-two', pushToken='b' * 64)
        self.make_binding(self.user, 'lead', 'lead-test-key')
        self.register(installationId=str(uuid.uuid4()), activityId='activity-lead', pushToken='c' * 64,
            tradingMode='lead')
        result, fetch = self.dispatch()
        self.assertEqual(result, 3)
        self.assertEqual(fetch.call_count, 2)
        self.assertEqual({call.args[0].trading_mode for call in self.transport.call_args_list}, {'ordinary', 'lead'})

    def test_binding_disable_rebind_and_user_disable_end_with_no_account_data(self):
        for change in ('binding_disabled', 'binding_deleted', 'generation', 'inactive_user'):
            with self.subTest(change=change):
                LiveActivityRegistration.objects.all().delete()
                ApiBinding.objects.filter(pk=self.binding.pk).update(status=1)
                User.objects.filter(pk=self.user.pk).update(is_active=True)
                if change == 'binding_deleted':
                    binding_copy = self.make_binding(self.other, 'ordinary', 'temporary-key')
                self.register()
                if change == 'binding_disabled':
                    ApiBinding.objects.filter(pk=self.binding.pk).update(status=0)
                elif change == 'binding_deleted':
                    ApiBinding.objects.filter(pk=self.binding.pk).delete()
                elif change == 'generation':
                    ApiBinding.objects.filter(pk=self.binding.pk).update(created_at=timezone.now() + timedelta(seconds=1))
                else:
                    User.objects.filter(pk=self.user.pk).update(is_active=False)
                self.transport.reset_mock()
                self.dispatch()
                self.assertEqual(self.transport.call_args.args[1]['aps']['event'], 'end')
                self.assertEqual(self.transport.call_args.args[1]['aps']['content-state']['positions'], [])
                item = LiveActivityRegistration.objects.get()
                self.assertFalse(item.active)
                self.assertFalse(item.end_requested)
                # Restore fixture identity for the remaining subcases.
                if change == 'binding_deleted':
                    binding_copy.delete()
                    self.binding = self.make_binding(self.user, 'ordinary', 'live-test-key')

    def test_expiry_sends_end_once_and_does_not_restart(self):
        self.register()
        LiveActivityRegistration.objects.update(expires_at=timezone.now() - timedelta(seconds=1))
        self.dispatch()
        aps = self.transport.call_args.args[1]['aps']
        self.assertEqual(aps['event'], 'end')
        self.assertEqual(aps['dismissal-date'], aps['timestamp'])
        self.transport.reset_mock()
        self.assertEqual(self.dispatch()[0], 0)
        self.transport.assert_not_called()

    def test_fetch_failure_sends_explicit_stale_empty_state(self):
        self.register()
        before = int(timezone.now().timestamp())
        with patch.object(live, '_load_state', side_effect=RuntimeError('do not persist this text')):
            self.assertEqual(live.dispatch_live_activities(), 1)
        aps = self.transport.call_args.args[1]['aps']
        self.assertEqual(aps['content-state'], {'positions': [], 'totalCount': 0, 'updatedAt': 0, 'status': '更新延迟'})
        self.assertGreaterEqual(aps['stale-date'], before + 90)

    def test_lost_exchange_capability_ends_all_owner_mode_cards_without_binding_writes(self):
        self.register()
        self.register(installationId=str(uuid.uuid4()), activityId='activity-two', pushToken='b' * 64)
        before = list(ApiBinding.objects.filter(pk=self.binding.pk).values())
        with patch.object(live, '_load_state', side_effect=BinanceApiError('fixture auth error', code='-2015')) as get:
            self.assertEqual(live.dispatch_live_activities(), 2)
        self.assertEqual(get.call_count, 1)
        for call in self.transport.call_args_list:
            aps = call.args[1]['aps']
            self.assertEqual(aps['event'], 'end')
            self.assertEqual(aps['content-state']['positions'], [])
        self.assertEqual(list(ApiBinding.objects.filter(pk=self.binding.pk).values()), before)
        self.assertFalse(LiveActivityRegistration.objects.filter(active=True).exists())

    def test_account_read_failure_after_snapshot_does_not_publish_old_money(self):
        self.register()
        account = live._read_account(self.user.pk, 'ordinary')
        with patch.object(live, '_read_account', side_effect=[account, RuntimeError('fixture')]):
            self.assertEqual(self.dispatch()[0], 1)
        self.assertEqual(self.transport.call_args.args[1]['aps']['event'], 'end')
        self.assertEqual(self.transport.call_args.args[1]['aps']['content-state']['positions'], [])

    def test_rebind_while_fetching_sends_only_end_not_old_money(self):
        self.register()
        def fetched(*_args):
            ApiBinding.objects.filter(pk=self.binding.pk).update(status=0)
            return self.state
        with patch.object(live, '_load_state', side_effect=fetched):
            self.assertEqual(live.dispatch_live_activities(), 1)
        self.assertEqual(self.transport.call_args.args[1]['aps']['event'], 'end')
        self.assertEqual(self.transport.call_args.args[1]['aps']['content-state']['positions'], [])

    def test_unregister_while_fetching_fences_old_money_then_delivers_end(self):
        self.register()
        def fetched(*_args):
            live.request_end(user_id=self.user.pk, installation_id=self.installation)
            return self.state
        with patch.object(live, '_load_state', side_effect=fetched):
            self.assertEqual(live.dispatch_live_activities(), 0)
        self.transport.assert_not_called()
        self.assertEqual(self.dispatch()[0], 1)
        self.assertEqual(self.transport.call_args.args[1]['aps']['event'], 'end')

    def test_claim_lease_monotonic_timestamp_and_late_result_fence(self):
        self.register()
        now = timezone.now()
        item = LiveActivityRegistration.objects.get()
        first = live._claim(item.pk, now)
        self.assertIsNotNone(first)
        self.assertIsNone(live._claim(item.pk, now))
        LiveActivityRegistration.objects.filter(pk=item.pk).update(lease_until=now - timedelta(seconds=1))
        second = live._claim(item.pk, now)
        self.assertGreater(second.fence, first.fence)
        self.assertEqual(second.last_timestamp, first.last_timestamp + 1)
        self.assertEqual(live._finish(first, ended=True), 0)
        item.refresh_from_db()
        self.assertTrue(item.active)
        self.assertEqual(item.lease_until, second.lease_until)

    def test_429_respects_retry_after_and_invalid_token_is_terminal(self):
        self.register()
        self.transport.side_effect = live.LiveActivityPushError('apns_http_429', retry_after=120)
        before = timezone.now()
        self.assertEqual(self.dispatch()[0], 0)
        item = LiveActivityRegistration.objects.get()
        self.assertEqual(item.consecutive_failures, 1)
        self.assertGreaterEqual(item.next_update_at, before + timedelta(seconds=120))
        LiveActivityRegistration.objects.update(next_update_at=before)
        self.transport.side_effect = live.LiveActivityPushError('invalid_activity_token', permanent=True)
        self.dispatch()
        item.refresh_from_db()
        self.assertFalse(item.active)
        self.assertFalse(item.end_requested)

    def test_failure_limit_is_bounded_and_raw_error_text_is_never_persisted(self):
        self.register()
        self.transport.side_effect = RuntimeError('test-only sensitive URL must not be persisted')
        for _ in range(live.MAX_FAILURES):
            LiveActivityRegistration.objects.update(next_update_at=timezone.now())
            self.dispatch()
        item = LiveActivityRegistration.objects.get()
        self.assertEqual(item.consecutive_failures, live.MAX_FAILURES)
        self.assertFalse(item.active)
        self.assertEqual(item.last_error, 'RuntimeError')
        self.assertEqual(self.dispatch()[0], 0)

    def test_read_only_loader_uses_shared_cache_or_exact_background_get(self):
        account = live._read_account(self.user.pk, 'ordinary')
        self.assertIsNone(account.credentials.result_observer)
        before = list(ApiBinding.objects.filter(pk=self.binding.pk).values())
        row = {'instId': 'BTC-USDT-SWAP', 'pos': '1', 'posSide': 'long', 'rawUpl': '12.3456'}
        with patch.object(live.BinanceFuturesClient, 'get_positions', return_value={'data': [row]}) as get:
            state = live._load_state(account, timezone.now())
            self.assertEqual(state['positions'][0]['profit'], '+12.346 U')
            get.assert_called_once_with('SWAP', budget_priority=live.RequestPriority.BACKGROUND)
            get.reset_mock()
            live._load_state(account, timezone.now())
            get.assert_not_called()
        self.assertEqual(list(ApiBinding.objects.filter(pk=self.binding.pk).values()), before)


class LiveActivityPureTests(SimpleTestCase):
    @override_settings(APNS_ENABLED=True, LIVE_ACTIVITIES_ENABLED=False)
    def test_feature_off_does_not_query_or_send(self):
        with patch.object(live.LiveActivityRegistration.objects, 'filter', side_effect=AssertionError('database')):
            self.assertEqual(live.dispatch_live_activities(), 0)

    def test_decimal_profit_formatting_handles_carries_tiny_values_and_missing_data(self):
        for value, expected in [('123.456', '+123.46 U'), ('1.23456', '+1.235 U'),
                ('0.000123456', '+0.0001235 U'), ('-0.000000012345', '-0.00000001235 U'),
                ('99.9999', '+100 U'), ('0.999999', '+1 U'), ('0', '0 U'), ('-0', '0 U'),
                ('NaN', '--'), ('Infinity', '--'), (None, '--')]:
            with self.subTest(value=value):
                self.assertEqual(live.profit_text(value), expected)

    def test_snapshot_bounds_rows_and_keeps_stable_direction_identity(self):
        rows = [{'instId': f'{symbol}-USDT-SWAP', 'pos': '-1', 'posSide': 'net', 'rawUpl': '-1.2'}
            for symbol in ('BTC', 'ETH', 'SOL', 'XRP', 'BNB')]
        state = live.position_state(rows, updated_at=timezone.now())
        self.assertEqual(state['totalCount'], 5)
        self.assertEqual(len(state['positions']), 4)
        self.assertTrue(all(item['isShort'] for item in state['positions']))
        self.assertTrue(all(item['id'].endswith(':short') for item in state['positions']))
        self.assertEqual(live.position_state([], updated_at=timezone.now())['status'], '暂无持仓')
        self.assertEqual(live.position_state([{'instId': 'BTC-USDT-SWAP', 'pos': '1', 'rawUpl': None}],
            updated_at=timezone.now())['positions'][0]['profit'], '--')
        for rows in (None, [{}], [None]):
            with self.assertRaises(ValueError):
                live.position_state(rows, updated_at=timezone.now())

    @override_settings(APNS_TEAM_ID='test-team', APNS_KEY_ID='test-key')
    def test_transport_is_http2_low_priority_liveactivity_topic_and_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture.p8'
            path.write_text('not a real key')
            for environment, host in [('production', 'api.push.apple.com'), ('sandbox', 'api.sandbox.push.apple.com')]:
                item = SimpleNamespace(pk=1, fence=2, last_timestamp=3, activity_id='test-activity',
                    bundle_id='com.example.test', push_token='a' * 64, environment=environment)
                payload = {'aps': {'timestamp': 3, 'event': 'update', 'content-state': {}}}
                with override_settings(APNS_KEY_PATH=str(path)), patch.object(live, '_provider_token', return_value='test-jwt'), \
                        patch('httpx.Client') as factory:
                    response = Mock(status_code=200)
                    client = factory.return_value.__enter__.return_value
                    client.post.return_value = response
                    live.send_live_activity(item, payload)
                    factory.assert_called_once_with(http2=True, timeout=10, follow_redirects=False, trust_env=False)
                    self.assertEqual(client.post.call_args.args[0], f'https://{host}/3/device/' + 'a' * 64)
                    headers = client.post.call_args.kwargs['headers']
                    self.assertEqual(headers['apns-push-type'], 'liveactivity')
                    self.assertEqual(headers['apns-topic'], 'com.example.test.push-type.liveactivity')
                    self.assertEqual(headers['apns-priority'], '5')
                    self.assertEqual(client.post.call_args.kwargs['json'], payload)

    def test_transport_bounds_retry_after_and_retires_only_permanent_tokens(self):
        item = SimpleNamespace(pk=1, fence=2, last_timestamp=3, activity_id='fixture',
            bundle_id='com.example.test', push_token='a' * 64, environment='production')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture.p8'
            path.write_text('not a real key')
            for status, reason, retry_header, permanent, retry_after in (
                (410, '', '', True, 0), (400, 'DeviceTokenNotForTopic', '', True, 0),
                (429, '', '999999', False, 3600), (429, '', 'invalid', False, 60),
                (429, '', '0', False, 15), (503, '', '', False, 0)):
                with self.subTest(status=status, retry=retry_header), override_settings(APNS_KEY_PATH=str(path)), \
                        patch.object(live, '_provider_token', return_value='fixture'), patch('httpx.Client') as factory:
                    response = Mock(status_code=status, headers={'retry-after': retry_header})
                    response.json.return_value = {'reason': reason}
                    factory.return_value.__enter__.return_value.post.return_value = response
                    with self.assertRaises(live.LiveActivityPushError) as raised:
                        live.send_live_activity(item, {'aps': {'event': 'update'}})
                    self.assertEqual(raised.exception.permanent, permanent)
                    self.assertEqual(raised.exception.retry_after, retry_after)

    def test_scheduler_job_is_independent_and_always_cleans_database_connections(self):
        from trading import scheduler
        for failure in (False, True):
            with self.subTest(failure=failure), patch('trading.scheduler.close_old_connections') as cleanup, \
                    patch.object(live, 'dispatch_live_activities') as dispatch:
                if failure:
                    dispatch.side_effect = RuntimeError('fixture')
                scheduler._dispatch_live_activities_job()
                dispatch.assert_called_once_with()
                self.assertEqual(cleanup.call_count, 2)

    def test_scheduler_feature_flag_only_adds_its_independent_job(self):
        from trading import scheduler
        scheduled = {}
        for enabled in (False, True):
            with override_settings(LIVE_ACTIVITIES_ENABLED=enabled), patch.object(scheduler, '_scheduler', None), \
                    patch.object(scheduler, 'ThreadPoolExecutor'), patch.object(scheduler, '_scheduler_heartbeat_job'), \
                    patch.object(scheduler, 'BackgroundScheduler', return_value=Mock()) as factory:
                scheduler.start_scheduler()
                scheduled[enabled] = {call.kwargs['id'] for call in factory.return_value.add_job.call_args_list}
        self.assertEqual(scheduled[True] - scheduled[False], {'dispatch_live_activities'})
        self.assertEqual(scheduled[False] - scheduled[True], set())
