"""Authenticated installations and the App signal notification outbox."""
import time
import uuid
from datetime import timedelta
from pathlib import Path
from functools import lru_cache

import jwt
from django.conf import settings
from django.db import transaction
from django.db.models import Q
from django.utils import timezone
from rest_framework import serializers
from rest_framework.views import APIView

from common.response import ok
from mobile.models import NotificationDelivery, NotificationEvent, PushDevice


class DeviceSerializer(serializers.Serializer):
    installationId = serializers.UUIDField()
    deviceToken = serializers.RegexField(r'^[a-fA-F0-9]{64,256}$')
    environment = serializers.ChoiceField(choices=['development', 'production'])
    bundleIdentifier = serializers.CharField(max_length=128)

    def validate_bundleIdentifier(self, value):
        if value != settings.APNS_BUNDLE_ID:
            raise serializers.ValidationError('应用标识不匹配')
        return value


class PushRegisterView(APIView):
    def post(self, request):
        form = DeviceSerializer(data=request.data)
        form.is_valid(raise_exception=True)
        data = form.validated_data
        with transaction.atomic():
            # Retire a previous installation record for the same token; ownership
            # may only move through an authenticated registration on this device.
            PushDevice.objects.filter(token=data['deviceToken'].lower(), environment=data['environment'],
                bundle_id=data['bundleIdentifier']).exclude(installation_id=data['installationId']).delete()
            PushDevice.objects.update_or_create(installation_id=data['installationId'], defaults={
                'user': request.user, 'token': data['deviceToken'].lower(),
                'environment': data['environment'], 'bundle_id': data['bundleIdentifier'], 'active': True})
        return ok({})


class PushUnregisterView(APIView):
    def post(self, request):
        field = serializers.UUIDField()
        installation = field.run_validation(request.data.get('installationId'))
        PushDevice.objects.filter(user=request.user, installation_id=installation).update(active=False)
        return ok({})


def enqueue_signal(message):
    """Called in the signal transaction: retries never depend on scan cache state."""
    if message.source != 'internal':
        return None
    data = message.normalized_payload
    event_key = message.event_id
    signal_id = str(uuid.uuid5(uuid.NAMESPACE_URL, event_key))
    title = f"{data['symbol']} {'做多' if data['signal'] == 'BUY' else '做空'} · {data['interval']}"
    payload = {'aps': {'alert': {'title': title, 'body': data['comment']}, 'sound': 'default'},
        'route': 'strategy.signal', 'id': signal_id, 'symbol': data['symbol'],
        'interval': data['interval'], 'strategyName': data['strategy'],
        'direction': 'LONG' if data['signal'] == 'BUY' else 'SHORT',
        'triggerPrice': data['price'], 'triggeredAt': data['timestamp'] / 1000}
    event, _ = NotificationEvent.objects.get_or_create(event_key=event_key, defaults={'payload': payload})
    if settings.APNS_ENABLED:
        for device in PushDevice.objects.filter(active=True, user__is_active=True).iterator():
            NotificationDelivery.objects.get_or_create(event=event, target=f'apns:{device.pk}',
                defaults={'device': device, 'user_id_snapshot': device.user_id})
    return event


def enqueue_app_notification(*, event_key, payload, user_id):
    """Persist owner-scoped App delivery, without performing network I/O."""
    if not settings.APNS_ENABLED:
        raise RuntimeError('App notifications are disabled')
    with transaction.atomic():
        event, _ = NotificationEvent.objects.get_or_create(
            event_key=event_key, defaults={'payload': payload})
        for device in PushDevice.objects.filter(user_id=user_id, active=True,
                user__is_active=True, bundle_id=settings.APNS_BUNDLE_ID).iterator():
            NotificationDelivery.objects.get_or_create(event=event, target=f'apns:{device.pk}',
                defaults={'device': device, 'user_id_snapshot': user_id})
    return event


class PermanentPushError(Exception):
    pass


@lru_cache(maxsize=4)
def _provider_token(team, key_id, key_path, key_mtime, issued_bucket):
    return jwt.encode({'iss': team, 'iat': issued_bucket * 1200}, Path(key_path).read_bytes(),
        algorithm='ES256', headers={'kid': key_id})


def send_apns(device, payload, event_id):
    import httpx
    token = _provider_token(settings.APNS_TEAM_ID, settings.APNS_KEY_ID, settings.APNS_KEY_PATH,
        Path(settings.APNS_KEY_PATH).stat().st_mtime_ns, int(time.time()) // 1200)
    host = 'api.push.apple.com' if device.environment == 'production' else 'api.sandbox.push.apple.com'
    headers = {'authorization': f'bearer {token}', 'apns-topic': device.bundle_id,
        'apns-push-type': 'alert', 'apns-priority': '10', 'apns-expiration': str(int(time.time()) + 3600),
        'apns-id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'{event_id}:{device.pk}'))}
    with httpx.Client(http2=True, timeout=10, follow_redirects=False, trust_env=False) as client:
        response = client.post(f'https://{host}/3/device/{device.token}', json=payload, headers=headers)
    if response.status_code == 200:
        return
    reason = response.json().get('reason', '')
    if response.status_code == 410 or reason in {'BadDeviceToken', 'DeviceTokenNotForTopic', 'Unregistered'}:
        PushDevice.objects.filter(pk=device.pk, token=device.token).update(active=False)
        raise PermanentPushError('invalid_device')
    raise RuntimeError(f'apns_http_{response.status_code}')


def _claim(delivery_id, now):
    with transaction.atomic():
        item = NotificationDelivery.objects.select_for_update().select_related('event', 'device').get(pk=delivery_id)
        due = item.status in {'pending', 'failed'} and (item.retry_at is None or item.retry_at <= now)
        expired = item.status == 'sending' and item.lease_until and item.lease_until <= now
        if not (due or expired):
            return None
        # Ordinary signals belong to the App. Retire queued legacy Echo records
        # even if an older environment still enables SIGNAL_ECHOBELL_ENABLED.
        payload = item.event.payload or {}
        external_source = str(payload.get('source') or '').strip().lower() in {'external', 'tradingview', 'tv'}
        if (not item.target.startswith('apns:')
                or payload.get('route') == 'reference.trade.notification' or external_source):
            item.status = 'cancelled'
            item.lease_until = None
            item.save(update_fields=['status', 'lease_until'])
            return None
        if (payload.get('route') == 'trade.notification'
                and not getattr(settings, 'TRADE_NOTIFICATION_ENABLED', True)):
            return None
        if item.attempts >= 8:
            if expired:
                item.status = 'exhausted'
                item.save(update_fields=['status'])
            return None
        if item.event.created_at < now - timedelta(hours=1):
            item.status = 'cancelled'; item.save(update_fields=['status']); return None
        if item.target.startswith('apns:'):
            if not settings.APNS_ENABLED:
                return None
            if not item.device.active or item.device.user_id != item.user_id_snapshot:
                item.status = 'cancelled'; item.save(update_fields=['status']); return None
        item.attempts += 1
        item.status = 'sending'; item.lease_until = now + timedelta(seconds=60)
        item.save(update_fields=['attempts', 'status', 'lease_until'])
        return item


def dispatch_notifications(limit=100):
    now = timezone.now()
    due = Q(status__in=['pending', 'failed']) & (Q(retry_at__isnull=True) | Q(retry_at__lte=now))
    due |= Q(status='sending', lease_until__lte=now)
    if not getattr(settings, 'TRADE_NOTIFICATION_ENABLED', True):
        # Paused trade entries must not fill the batch and starve live signals.
        due &= ~Q(event__payload__route='trade.notification') | Q(event__payload__route__isnull=True)
    ids = list(NotificationDelivery.objects.filter(due & (Q(attempts__lt=8) | Q(status="sending"))).order_by('id').values_list('id', flat=True)[:limit])
    sent = 0
    for delivery_id in ids:
        item = _claim(delivery_id, now)
        if item is None:
            continue
        status, error = 'sent', ''
        try:
            send_apns(item.device, item.event.payload, item.event.event_key)
        except PermanentPushError:
            status, error = 'cancelled', 'invalid_device'
        except Exception as exc:
            status = 'failed' if item.attempts < 8 else 'exhausted'
            error = type(exc).__name__[:80]  # Never persist URLs, credentials or raw error bodies.
        NotificationDelivery.objects.filter(pk=item.pk, status='sending', attempts=item.attempts).update(
            status=status, last_error=error, lease_until=None,
            retry_at=now + timedelta(seconds=min(3600, 5 * 2**item.attempts)) if status == 'failed' else None)
        sent += int(status == 'sent')
    return sent
