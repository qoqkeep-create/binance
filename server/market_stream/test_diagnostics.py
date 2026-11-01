import json
from copy import deepcopy
from datetime import timedelta
from uuid import uuid4
from unittest.mock import patch

from django.core.cache import cache
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient
from users.models import User


class ChartLoadReportTests(TestCase):
    path = '/api/market/chart-load-reports'

    def setUp(self):
        cache.clear()
        self.client = APIClient()
        self.user = User.objects.create_user('chart-report@example.invalid', 'test-only-password')
        self.client.force_authenticate(self.user)
        self.payload = {'traceId': str(uuid4()), 'symbol': 'BTCUSDT', 'interval': '1h',
                        'appVersion': '1.0.1', 'appBuild': '15', 'platform': 'iosSimulator',
                        'startedAtMs': 1793520000000, 'completedAtMs': 1793520001000,
                        'durationMs': 1000.0, 'outcome': 'displayed', 'completionKind': 'gpu_completion_proxy',
                        'events': [{'stage': 'load_started', 'atMs': 1793520000000, 'elapsedMs': 0}],
                        'requests': [], 'truncated': False}

    def test_report_requires_authentication(self):
        self.client.force_authenticate(None)
        self.assertEqual(self.client.post(self.path, self.payload, format='json').status_code, 401)

    def test_saved_report_is_deduplicated_within_its_owner(self):
        from market_stream.models import ChartLoadReport
        for _ in range(2):
            self.assertEqual(self.client.post(self.path, self.payload, format='json').status_code, 200)
        self.assertEqual(ChartLoadReport.objects.count(), 1)
        saved = ChartLoadReport.objects.get()
        self.assertEqual(saved.user_id, self.user.id)
        self.assertEqual(saved.payload['completedAtMs'], 1793520001000)
        other = User.objects.create_user('other-chart@example.invalid', 'test-only-password')
        self.client.force_authenticate(other)
        self.assertEqual(self.client.post(self.path, self.payload, format='json').status_code, 200)
        self.assertEqual(ChartLoadReport.objects.count(), 2)

    def test_rejects_unknown_fields_even_inside_request_metrics(self):
        for location in ['root', 'event', 'request']:
            payload = deepcopy(self.payload)
            if location == 'root': payload['authorization'] = 'must-not-be-stored'
            elif location == 'event': payload['events'][0]['message'] = 'must-not-be-stored'
            else: payload['requests'] = [{'requestId': str(uuid4()), 'startedAtMs': 1,
                                         'result': 'error', 'url': 'must-not-be-stored'}]
            with self.subTest(location=location):
                self.assertEqual(self.client.post(self.path, payload, format='json').status_code, 400)

    def test_rejects_oversize_and_inconsistent_reports(self):
        payload = deepcopy(self.payload); payload['events'] *= 65
        self.assertEqual(self.client.post(self.path, payload, format='json').status_code, 400)
        payload = deepcopy(self.payload); payload['completedAtMs'] = None
        self.assertEqual(self.client.post(self.path, payload, format='json').status_code, 400)
        payload = deepcopy(self.payload); payload['durationMs'] = float('inf')
        self.assertEqual(self.client.post(self.path, json.dumps(payload), content_type='application/json').status_code, 400)

    def test_retention_only_deletes_bounded_diagnostic_rows(self):
        from market_stream.diagnostics import prune_reports
        from market_stream.models import ChartLoadReport
        self.client.post(self.path, self.payload, format='json')
        ChartLoadReport.objects.update(received_at=timezone.now() - timedelta(days=8))
        self.assertEqual(prune_reports(batch_size=1), 1)
        self.assertEqual(ChartLoadReport.objects.count(), 0)

    def test_network_stages_and_server_timestamps_are_saved(self):
        from market_stream.models import ChartLoadReport
        self.payload['requests'] = [{
            'requestId': str(uuid4()), 'startedAtMs': 1793520000000, 'completedAtMs': 1793520000900,
            'elapsedMs': 900, 'statusCode': 200, 'result': 'success', 'decodedBytes': 400000,
            'serverReceivedAtMs': 1793520000100, 'serverReadyAtMs': 1793520000120,
            'serverHistoryMs': 20, 'network': [{'protocol': 'h2', 'source': 'network', 'reused': True, 'proxy': False,
                'requestAtMs': 1793520000010, 'firstByteAtMs': 1793520000200,
                'responseEndAtMs': 1793520000850, 'ttfbMs': 190, 'transferMs': 650,
                'wireBytes': 66000, 'decodedBytes': 400000}]}]
        self.assertEqual(self.client.post(self.path, self.payload, format='json').status_code, 200)
        self.assertEqual(ChartLoadReport.objects.get().payload['requests'], self.payload['requests'])

    def test_duplicate_is_accepted_even_when_capacity_is_full_without_overwriting(self):
        from market_stream.models import ChartLoadReport
        self.client.post(self.path, self.payload, format='json')
        self.payload['durationMs'] = 20
        with patch('market_stream.diagnostics.ChartLoadReport.objects.count', return_value=5000):
            self.assertEqual(self.client.post(self.path, self.payload, format='json').status_code, 200)
            self.payload['traceId'] = str(uuid4())
            self.assertEqual(self.client.post(self.path, self.payload, format='json').status_code, 429)
        self.assertEqual(ChartLoadReport.objects.get().duration_ms, 1000)

    def test_actual_body_size_and_user_rate_limit_are_enforced(self):
        self.assertEqual(self.client.post(self.path, ' ' * 24577,
            content_type='application/json').status_code, 413)
        with patch('market_stream.diagnostics.ReportThrottle.rate', '1/hour'):
            cache.clear()
            self.assertEqual(self.client.post(self.path, self.payload, format='json').status_code, 200)
            self.assertEqual(self.client.post(self.path, self.payload, format='json').status_code, 429)

    def test_kline_headers_correlate_without_writing_report_rows(self):
        from market_stream.models import ChartLoadReport
        trace, child = str(uuid4()), str(uuid4())
        with patch('market_stream.views.service.symbols', return_value=['BTCUSDT']), \
             patch('market_stream.views.service.load_history', return_value={'items': []}), \
             patch('market_stream.views.trading_data.attach', side_effect=lambda data, _: data):
            response = self.client.get('/api/market/klines?symbol=BTCUSDT&interval=1h',
                HTTP_X_CHART_TRACE_ID=trace, HTTP_X_CHART_REQUEST_ID=child)
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response['X-Chart-Trace-ID'], trace)
            self.assertEqual(response['X-Chart-Request-ID'], child)
            self.assertGreaterEqual(int(response['X-Chart-Server-Ready-At']),
                                    int(response['X-Chart-Server-Received-At']))
            response = self.client.get('/api/market/klines?symbol=BTCUSDT',
                HTTP_X_CHART_TRACE_ID='not-a-uuid', HTTP_X_CHART_REQUEST_ID=child)
            self.assertNotIn('X-Chart-Trace-ID', response)
        self.assertEqual(ChartLoadReport.objects.count(), 0)
