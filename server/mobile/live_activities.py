"""Owner-scoped, read-only ActivityKit snapshots and independent APNs delivery.

This module never reconciles orders, executes trades, modifies protection, or
falls back to alert notifications/Echobell. Network calls happen outside locks.
"""
from __future__ import annotations

import hashlib
import logging
import math
import re
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone as dt_timezone
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP, localcontext
from pathlib import Path

from django.conf import settings
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.db import IntegrityError, transaction
from django.db.models import F, Q
from django.utils import timezone
from rest_framework import serializers
from rest_framework.views import APIView

from api_bindings.context import build_trading_account_identity
from api_bindings.models import ApiBinding
from common.binance import (BinanceCredentials, BinanceFuturesClient,
    is_binance_auth_or_permission_error, to_symbol)
from common.binance_rate_limit import RequestPriority
from common.response import fail, ok
from common.utils import aes_decrypt
from mobile.models import LiveActivityRegistration
from mobile.push import _provider_token
from trading.account_cache import position_cache_key

MAX_ACTIVITY_AGE = timedelta(hours=8)
MAX_FAILURES = 8
LEASE_SECONDS = 45
MAX_ROWS = 4
logger = logging.getLogger(__name__)


def _enabled():
    return bool(getattr(settings, 'LIVE_ACTIVITIES_ENABLED', False) and settings.APNS_ENABLED)


class RegistrationSerializer(serializers.Serializer):
    installationId = serializers.UUIDField()
    activityId = serializers.CharField(max_length=128)
    pushToken = serializers.RegexField(r'^(?:[a-fA-F0-9]{2}){16,256}$', max_length=512)
    environment = serializers.ChoiceField(choices=['sandbox', 'development', 'production'])
    bundleIdentifier = serializers.CharField(max_length=128)
    tradingMode = serializers.ChoiceField(choices=['ordinary', 'lead'])
    frequentUpdates = serializers.BooleanField(default=False)
    startedAt = serializers.FloatField(required=False, min_value=1)
    tokenUpdatedAt = serializers.FloatField(required=False, min_value=1)

    def validate_bundleIdentifier(self, value):
        if value != settings.APNS_BUNDLE_ID:
            raise serializers.ValidationError('应用标识不匹配')
        return value

    def validate_startedAt(self, value):
        if not math.isfinite(value) or value > 4102444800:
            raise serializers.ValidationError('实时活动开始时间无效')
        return value

    def validate_tokenUpdatedAt(self, value):
        return self.validate_startedAt(value)


class UnregisterSerializer(serializers.Serializer):
    installationId = serializers.UUIDField()
    activityId = serializers.CharField(max_length=128)


@dataclass(frozen=True)
class ReadOnlyAccount:
    binding_id: int
    fingerprint: str
    binding_created_at: datetime
    identity: str
    credentials: BinanceCredentials


def _read_account(user_id: int, mode: str) -> ReadOnlyAccount | None:
    """Read credentials without legacy rewrites or binding-health observers."""
    binding = ApiBinding.objects.filter(user_id=user_id, user__is_active=True,
        trading_mode=mode, status=1).first()
    if not binding:
        return None
    api_key = aes_decrypt(binding.api_key)
    fingerprint = hashlib.sha256(api_key.strip().encode()).hexdigest()
    stored = str(binding.api_key_fingerprint or '').strip().lower()
    if not api_key.strip() or (stored and stored != fingerprint) or (mode == 'lead' and not stored):
        return None
    credentials = BinanceCredentials(api_key=api_key, secret_key=aes_decrypt(binding.secret_key),
        passphrase=aes_decrypt(binding.passphrase), trading_mode=mode)
    return ReadOnlyAccount(binding.pk, fingerprint, binding.created_at,
        build_trading_account_identity(user_id=user_id, binding_id=binding.pk,
            api_key_fingerprint=fingerprint, trading_mode=mode), credentials)


def _same_binding(registration, account):
    return bool(account and account.binding_id == registration.binding_id_snapshot
        and account.fingerprint == registration.binding_fingerprint
        and account.binding_created_at == registration.binding_created_at)


class LiveActivityRegisterView(APIView):
    def post(self, request):
        if not _enabled():
            return fail('实时活动暂未启用', code=503, status=503)
        form = RegistrationSerializer(data=request.data)
        form.is_valid(raise_exception=True)
        data = form.validated_data
        now = timezone.now()
        started_at = datetime.fromtimestamp(data.get('startedAt', int(now.timestamp())), tz=dt_timezone.utc)
        token_updated_at = datetime.fromtimestamp(data.get('tokenUpdatedAt', started_at.timestamp()), tz=dt_timezone.utc)
        if started_at > now + timedelta(seconds=60) or started_at + MAX_ACTIVITY_AGE <= now:
            return fail('实时活动时间已失效，请重新开启')
        if token_updated_at > now + timedelta(seconds=60):
            return fail('实时活动令牌时间无效，请重试')
        # Preserve fractional device time for ordering, but clock skew may not
        # extend the eight-hour TTL beyond the server's first registration.
        expires_at = min(started_at, now) + MAX_ACTIVITY_AGE
        try:
            account = _read_account(request.user.pk, data['tradingMode'])
        except Exception:
            return fail('无法读取当前 API 绑定，请检查后重试')
        if account is None:
            return fail('使用实时活动需先绑定当前模式的有效 API')
        token = data['pushToken'].lower()
        environment = 'sandbox' if data['environment'] == 'development' else data['environment']
        try:
            with transaction.atomic():
                # Serialize this user's first registration as well as refreshes.
                get_user_model().objects.select_for_update().get(pk=request.user.pk)
                item = LiveActivityRegistration.objects.select_for_update().filter(
                    installation_id=data['installationId']).first()
                if item is not None:
                    same_activity = item.activity_id == data['activityId']
                    if same_activity:
                        if item.user_id != request.user.pk or not item.active or item.end_requested \
                                or item.expires_at <= now or item.trading_mode != data['tradingMode'] \
                                or not _same_binding(item, account):
                            return fail('实时活动已失效，请重新开启', code=409, status=409)
                        started_at = item.activity_started_at
                        expires_at = item.expires_at
                        # Cancelling the old client request does not revoke an
                        # HTTP request that already reached the server.
                        if token_updated_at < item.token_updated_at or (token_updated_at == item.token_updated_at
                                and token != item.push_token):
                            return fail('较旧的实时活动令牌已忽略', code=409, status=409)
                    elif started_at <= item.activity_started_at:
                        return fail('较旧的实时活动已忽略，请重新开启', code=409, status=409)
                defaults = dict(user=request.user, activity_id=data['activityId'], push_token=token,
                    environment=environment, bundle_id=data['bundleIdentifier'], trading_mode=data['tradingMode'],
                    binding_id_snapshot=account.binding_id, binding_fingerprint=account.fingerprint,
                    binding_created_at=account.binding_created_at, activity_started_at=started_at,
                    token_updated_at=token_updated_at,
                    expires_at=expires_at, frequent_updates=data['frequentUpdates'],
                    active=True, end_requested=False, next_update_at=now, lease_until=None,
                    consecutive_failures=0, last_error='')
                if item is None:
                    item = LiveActivityRegistration.objects.create(installation_id=data['installationId'], **defaults)
                else:
                    if item.activity_id != data['activityId']:
                        defaults['last_timestamp'] = 0
                    for key, value in defaults.items():
                        setattr(item, key, value)
                    item.fence += 1
                    item.save()
        except IntegrityError:
            return fail('实时活动注册冲突，请重新开启', code=409, status=409)
        return ok({'expiresAt': int(item.expires_at.timestamp()),
            'updateInterval': 15 if item.frequent_updates else 60})


def request_end(*, user_id, installation_id, activity_id=None):
    query = LiveActivityRegistration.objects.filter(user_id=user_id, installation_id=installation_id)
    if activity_id is not None:
        query = query.filter(activity_id=activity_id)
    return query.filter(Q(active=True) | Q(end_requested=True)).update(active=False, end_requested=True,
        next_update_at=timezone.now(), lease_until=None, fence=F('fence') + 1, consecutive_failures=0)


class LiveActivityUnregisterView(APIView):
    def post(self, request):
        form = UnregisterSerializer(data=request.data)
        form.is_valid(raise_exception=True)
        data = form.validated_data
        request_end(user_id=request.user.pk, installation_id=data['installationId'], activity_id=data['activityId'])
        return ok({})


def _decimal(value):
    try:
        result = Decimal(str(value))
        return result if result.is_finite() and abs(result) < Decimal('1e30') else None
    except (InvalidOperation, TypeError, ValueError):
        return None


def profit_text(value):
    amount = _decimal(value)
    if amount is None:
        return '--'
    if amount == 0:
        return '0 U'
    with localcontext() as context:
        context.prec = 50
        # Repeat after rounding so a carry uses the destination magnitude's rule.
        for _ in range(3):
            absolute = abs(amount)
            places = 2 if absolute >= 100 else 3 if absolute >= 1 else 3 - absolute.adjusted()
            rounded = amount.quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_UP)
            if abs(rounded).adjusted() == absolute.adjusted():
                amount = rounded
                break
            amount = rounded
    text = format(amount, 'f').rstrip('0').rstrip('.') if '.' in format(amount, 'f') else format(amount, 'f')
    return ('+' if amount > 0 else '') + text + ' U'


def position_state(rows, *, updated_at):
    if not isinstance(rows, list):
        raise ValueError('invalid position snapshot')
    positions = []
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError('invalid position row')
        size = _decimal(row.get('pos'))
        if size is None:
            raise ValueError('invalid position quantity')
        if size == 0:
            continue
        symbol = to_symbol(str(row.get('instId') or ''))
        if not re.fullmatch(r'[A-Z0-9]{1,24}USDT', symbol):
            continue
        side = str(row.get('posSide') or 'net').lower()
        if side not in {'short', 'long', 'net'}:
            raise ValueError('invalid position side')
        short = side == 'short' or (side == 'net' and size < 0)
        positions.append({'id': symbol + (':short' if short else ':long'), 'symbol': symbol,
            'isShort': short, 'profit': profit_text(row.get('rawUpl') if 'rawUpl' in row else row.get('upl'))})
    positions.sort(key=lambda row: (row['symbol'], row['isShort']))
    return {'positions': positions[:MAX_ROWS], 'totalCount': len(positions),
        'updatedAt': int(updated_at.timestamp()), 'status': '' if positions else '暂无持仓'}


def _load_state(account, now):
    """Only a cached snapshot or the exchange GET positionRisk endpoint is used."""
    key = position_cache_key('exchange_rows', account.identity)
    rows = cache.get(key)
    if isinstance(rows, list):
        # The shared exchange cache has a maximum ten-second TTL, no timestamp.
        return position_state(rows, updated_at=now - timedelta(seconds=10))
    client = BinanceFuturesClient(account.credentials)
    payload = client.get_positions('SWAP', budget_priority=RequestPriority.BACKGROUND)
    rows = payload.get('data') if isinstance(payload, dict) else None
    state = position_state(rows, updated_at=timezone.now())
    cache.set(key, rows, timeout=10)
    return state


def _claim(registration_id, now):
    with transaction.atomic():
        item = LiveActivityRegistration.objects.select_for_update().select_related('user').get(pk=registration_id)
        if not (item.active or item.end_requested) or item.next_update_at > now \
                or (item.lease_until and item.lease_until > now):
            return None
        if item.expires_at <= now or not item.user.is_active:
            item.active = False
            item.end_requested = True
        item.fence += 1
        item.lease_until = now + timedelta(seconds=LEASE_SECONDS)
        item.last_timestamp = max(int(now.timestamp()), item.last_timestamp + 1)
        item.save(update_fields=['active', 'end_requested', 'fence', 'lease_until', 'last_timestamp'])
        return item


class LiveActivityPushError(Exception):
    def __init__(self, code, *, permanent=False, retry_after=0):
        super().__init__(code)
        self.code = code
        self.permanent = permanent
        self.retry_after = retry_after


def send_live_activity(item, payload):
    import httpx
    token = _provider_token(settings.APNS_TEAM_ID, settings.APNS_KEY_ID, settings.APNS_KEY_PATH,
        Path(settings.APNS_KEY_PATH).stat().st_mtime_ns, int(time.time()) // 1200)
    host = 'api.push.apple.com' if item.environment == 'production' else 'api.sandbox.push.apple.com'
    headers = {'authorization': f'bearer {token}', 'apns-topic': item.bundle_id + '.push-type.liveactivity',
        'apns-push-type': 'liveactivity', 'apns-priority': '5',
        'apns-collapse-id': hashlib.sha256(item.activity_id.encode()).hexdigest(),
        'apns-expiration': str(int(time.time()) + (3600 if payload['aps']['event'] == 'end' else 90)),
        'apns-id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'live:{item.pk}:{item.fence}:{item.last_timestamp}'))}
    with httpx.Client(http2=True, timeout=10, follow_redirects=False, trust_env=False) as client:
        response = client.post(f'https://{host}/3/device/{item.push_token}', json=payload, headers=headers)
    if response.status_code == 200:
        return
    try:
        reason = response.json().get('reason', '')
    except (ValueError, AttributeError):
        reason = ''
    if response.status_code == 410 or reason in {'BadDeviceToken', 'DeviceTokenNotForTopic', 'Unregistered'}:
        raise LiveActivityPushError('invalid_activity_token', permanent=True)
    retry_after = 0
    if response.status_code == 429:
        try:
            retry_after = min(3600, max(15, int(response.headers.get('retry-after', '60'))))
        except (TypeError, ValueError):
            retry_after = 60
    raise LiveActivityPushError(f'apns_http_{response.status_code}', retry_after=retry_after)


def _finish(item, *, ended, error=None):
    now = timezone.now()
    updates = {'lease_until': None}
    if error is not None:
        failures = item.consecutive_failures + 1
        terminal = failures >= MAX_FAILURES or (isinstance(error, LiveActivityPushError) and error.permanent)
        delay = max(min(300, 5 * 2 ** min(failures, MAX_FAILURES)), getattr(error, 'retry_after', 0))
        updates.update(consecutive_failures=failures,
            last_error=error.code if isinstance(error, LiveActivityPushError) else type(error).__name__[:80],
            next_update_at=now + timedelta(seconds=delay))
        if terminal:
            updates.update(active=False, end_requested=False)
    else:
        updates.update(consecutive_failures=0, last_error='',
            next_update_at=now + timedelta(seconds=15 if item.frequent_updates else 60))
        if ended:
            updates.update(active=False, end_requested=False)
    # Token changes, logout and unregister fence late network results.
    return LiveActivityRegistration.objects.filter(pk=item.pk, fence=item.fence,
        push_token=item.push_token, activity_id=item.activity_id).update(**updates)


def dispatch_live_activities(limit=20):
    if not _enabled():
        return 0
    now = timezone.now()
    ids = list(LiveActivityRegistration.objects.filter(Q(active=True) | Q(end_requested=True),
        next_update_at__lte=now).filter(Q(lease_until__isnull=True) | Q(lease_until__lte=now))
        .order_by('next_update_at', 'id').values_list('id', flat=True)[:max(1, min(100, int(limit)))])
    snapshots = {}
    sent = 0
    for registration_id in ids:
        item = _claim(registration_id, timezone.now())
        if item is None:
            continue
        ended = item.end_requested or not item.active
        state = {'positions': [], 'totalCount': 0, 'updatedAt': item.last_timestamp, 'status': '已停止'}
        try:
            if not ended:
                try:
                    account = _read_account(item.user_id, item.trading_mode)
                except Exception:
                    account = None
                if not _same_binding(item, account):
                    ended = True
                else:
                    key = (item.user_id, item.trading_mode, account.binding_id, account.fingerprint,
                        account.binding_created_at)
                    if key not in snapshots:
                        try:
                            snapshots[key] = _load_state(account, timezone.now())
                        except Exception as error:
                            # Missing exchange capability ends the activity without
                            # writing binding health or invoking trading workers.
                            snapshots[key] = None if is_binance_auth_or_permission_error(error) else {
                                'positions': [], 'totalCount': 0, 'updatedAt': 0, 'status': '更新延迟'}
                            logger.warning('live activity snapshot unavailable error_type=%s', type(error).__name__)
                    state = snapshots[key]
                    # Rebinding or logout during the GET must not publish its old data.
                    try:
                        current_account = _read_account(item.user_id, item.trading_mode)
                    except Exception:
                        current_account = None
                    if state is None or not _same_binding(item, current_account):
                        ended = True
            if ended:
                state = {'positions': [], 'totalCount': 0, 'updatedAt': item.last_timestamp, 'status': '已停止'}
            if not LiveActivityRegistration.objects.filter(pk=item.pk, fence=item.fence,
                    push_token=item.push_token, activity_id=item.activity_id).exists():
                continue
            # Error states already carry updatedAt=0, which the widget renders
            # unavailable. Keep the APNs stale date valid rather than year 1970.
            stale_date = (state['updatedAt'] if state['updatedAt'] > 0 else int(timezone.now().timestamp())) + 90
            payload = {'aps': {'timestamp': item.last_timestamp, 'event': 'end' if ended else 'update',
                'content-state': state, 'stale-date': stale_date}}
            if ended:
                payload['aps']['dismissal-date'] = item.last_timestamp
            send_live_activity(item, payload)
        except Exception as error:
            _finish(item, ended=ended, error=error)
        else:
            _finish(item, ended=ended)
            sent += 1
    return sent
