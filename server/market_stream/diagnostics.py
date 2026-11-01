"""Fixed-schema chart timing reports. No trading or synchronous outbound work."""
import json
import logging
import math
from datetime import timedelta
from uuid import UUID

from django.core.serializers.json import DjangoJSONEncoder
from django.utils import timezone
from rest_framework import serializers
from rest_framework.throttling import UserRateThrottle
from rest_framework.views import APIView

from common.response import ok, fail
from market_stream.core import INTERVAL_MS
from market_stream.models import ChartLoadReport

log = logging.getLogger(__name__)
MAX_BODY_BYTES = 24 * 1024
STAGES = ('load_started', 'request_started', 'request_adapted', 'response_received', 'decode_started',
          'decode_finished', 'request_cancelled', 'request_failed', 'auth_refresh_started', 'auth_refresh_finished',
          'snapshot_started', 'snapshot_installed', 'frame_ready', 'scene_started', 'scene_ready',
          'first_frame', 'socket_ready', 'epoch_changed', 'history_notice', 'recovery_requested',
          'load_cancelled', 'load_superseded', 'load_timeout')


class StrictSerializer(serializers.Serializer):
    def to_internal_value(self, data):
        if not isinstance(data, dict) or set(data) - set(self.fields):
            raise serializers.ValidationError({'non_field_errors': ['Unsupported diagnostic fields']})
        return super().to_internal_value(data)


class Milliseconds(serializers.FloatField):
    def __init__(self, **kwargs):
        # A suspended phone can resume its timeout much later than 40 seconds.
        super().__init__(min_value=0, max_value=7 * 24 * 60 * 60 * 1000, **kwargs)

    def to_internal_value(self, data):
        value = super().to_internal_value(data)
        if not math.isfinite(value):
            raise serializers.ValidationError('Invalid duration')
        return value


class NetworkMetricsSerializer(StrictSerializer):
    protocol = serializers.ChoiceField(choices=['h2', 'h3', 'http/1.1', 'http/1.0', 'unknown'])
    source = serializers.ChoiceField(choices=['network', 'localCache', 'serverPush', 'unknown'], required=False)
    reused = serializers.BooleanField()
    proxy = serializers.BooleanField()
    requestAtMs = serializers.IntegerField(min_value=0, required=False)
    firstByteAtMs = serializers.IntegerField(min_value=0, required=False)
    responseEndAtMs = serializers.IntegerField(min_value=0, required=False)
    dnsMs = Milliseconds(required=False)
    connectMs = Milliseconds(required=False)
    tlsMs = Milliseconds(required=False)
    ttfbMs = Milliseconds(required=False)
    transferMs = Milliseconds(required=False)
    totalMs = Milliseconds(required=False)
    wireBytes = serializers.IntegerField(min_value=0, max_value=10_000_000, required=False)
    decodedBytes = serializers.IntegerField(min_value=0, max_value=10_000_000, required=False)


class RequestTimingSerializer(StrictSerializer):
    requestId = serializers.UUIDField()
    startedAtMs = serializers.IntegerField(min_value=0)
    completedAtMs = serializers.IntegerField(min_value=0, required=False)
    elapsedMs = Milliseconds(required=False)
    statusCode = serializers.IntegerField(min_value=100, max_value=599, required=False)
    decodedBytes = serializers.IntegerField(min_value=0, max_value=10_000_000, required=False)
    serverReceivedAtMs = serializers.IntegerField(min_value=0, required=False)
    serverReadyAtMs = serializers.IntegerField(min_value=0, required=False)
    serverHistoryMs = Milliseconds(required=False)
    serverStatsMs = Milliseconds(required=False)
    errorCode = serializers.IntegerField(min_value=-100000, max_value=100000, required=False)
    result = serializers.ChoiceField(choices=['pending', 'success', 'cancelled', 'error'])
    network = NetworkMetricsSerializer(many=True, max_length=3)


class EventSerializer(StrictSerializer):
    stage = serializers.ChoiceField(choices=STAGES)
    atMs = serializers.IntegerField(min_value=0)
    elapsedMs = Milliseconds()
    requestId = serializers.UUIDField(required=False)
    value = serializers.IntegerField(min_value=0, max_value=10_000_000, required=False)


class ReportSerializer(StrictSerializer):
    traceId = serializers.UUIDField()
    symbol = serializers.RegexField(r'^[A-Z0-9]{2,32}$')
    interval = serializers.ChoiceField(choices=list(INTERVAL_MS))
    appVersion = serializers.RegexField(r'^[0-9.]{1,16}$')
    appBuild = serializers.RegexField(r'^[0-9]{1,10}$')
    platform = serializers.ChoiceField(choices=['iosDevice', 'iosSimulator'])
    startedAtMs = serializers.IntegerField(min_value=0)
    completedAtMs = serializers.IntegerField(min_value=0, required=False, allow_null=True)
    durationMs = Milliseconds()
    outcome = serializers.ChoiceField(choices=['displayed', 'cancelled', 'superseded', 'timeout'])
    completionKind = serializers.ChoiceField(choices=['presented', 'gpu_completion_proxy', 'none'])
    events = EventSerializer(many=True, max_length=64)
    requests = RequestTimingSerializer(many=True, max_length=8)
    truncated = serializers.BooleanField()

    def validate(self, attrs):
        if attrs['outcome'] == 'displayed' and (attrs.get('completedAtMs') is None or attrs['completionKind'] == 'none'):
            raise serializers.ValidationError('Displayed reports require a presentation timestamp')
        return attrs


class ReportThrottle(UserRateThrottle):
    scope = 'chart_load_reports'
    rate = '180/hour'


class ChartLoadReportsView(APIView):
    throttle_classes = [ReportThrottle]

    def post(self, request):
        # Check actual length too; Content-Length is not trusted.
        if len(request.body) > MAX_BODY_BYTES:
            return fail('Diagnostic report too large', status=413, code=413)
        serializer = ReportSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = json.loads(json.dumps(serializer.validated_data, cls=DjangoJSONEncoder))
        if ChartLoadReport.objects.filter(user=request.user, trace_id=data['traceId']).exists():
            return ok({'accepted': True})
        # Approximate hard storage guard. Maintenance frees oldest rows in small
        # batches; concurrent requests can exceed this only by active writers.
        if ChartLoadReport.objects.count() >= 5000:
            return fail('Diagnostic capacity reached', status=429, code=429)
        ChartLoadReport.objects.get_or_create(user=request.user, trace_id=data['traceId'], defaults={
            'app_build': data['appBuild'], 'symbol': data['symbol'], 'interval': data['interval'],
            'outcome': data['outcome'], 'duration_ms': data['durationMs'], 'payload': data})
        return ok({'accepted': True})


def correlation(request):
    try:
        return (str(UUID(request.headers.get('X-Chart-Trace-ID', ''))),
                str(UUID(request.headers.get('X-Chart-Request-ID', ''))))
    except (ValueError, AttributeError, TypeError):
        return None


def prune_reports(batch_size=500):
    expired = list(ChartLoadReport.objects.filter(received_at__lt=timezone.now() - timedelta(days=7))
                   .order_by('received_at').values_list('id', flat=True)[:batch_size])
    # Reserve space before capacity is reached, bounded per maintenance pass.
    if not expired and ChartLoadReport.objects.count() >= 4500:
        expired = list(ChartLoadReport.objects.order_by('received_at').values_list('id', flat=True)[:batch_size])
    if expired:
        ChartLoadReport.objects.filter(id__in=expired).delete()
    return len(expired)
