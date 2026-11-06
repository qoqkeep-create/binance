"""Read-only position monitoring and isolated, at-most-once Echobell attempts."""
from __future__ import annotations

import json
import logging
import re
from collections import Counter
from datetime import timedelta
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from urllib import request
from urllib.parse import urlsplit

from django.conf import settings
from django.contrib.auth import get_user_model
from django.db import transaction
from django.utils import timezone

from api_bindings.context import record_belongs_to_trading_account
from api_bindings.services import get_user_trading_account, get_user_binding
from common.binance import to_inst_id
from common.binance_rate_limit import RequestPriority
from positions.models import Order, PositionProfitAlert, PositionProfitWatch
from trading.services import load_shared_exchange_positions

logger = logging.getLogger(__name__)
THRESHOLDS = tuple(Decimal(value) for value in ('1', '1.5', '2', '3', '4', '5', '6', '7', '8'))
CALL_INTERVAL_SECONDS = 60
UNKNOWN_AFTER_SECONDS = 30


def _decimal(value):
    try:
        result = Decimal(str(value))
        return result if result.is_finite() else None
    except (InvalidOperation, ValueError, TypeError):
        return None


def _recipient_id():
    if not getattr(settings, 'POSITION_PROFIT_CALL_ENABLED', False):
        return 0
    return max(0, int(getattr(settings, 'POSITION_PROFIT_CALL_USER_ID', 0)))


def _channel_url():
    url = str(getattr(settings, 'POSITION_PROFIT_CALL_URL', '') or '').strip()
    parsed = urlsplit(url)
    if (parsed.scheme != 'https' or parsed.netloc != 'hook.echobell.one'
            or not re.fullmatch(r'/t/[A-Za-z0-9_-]+', parsed.path)
            or parsed.query or parsed.fragment):
        raise ValueError('invalid Echobell channel configuration')
    return url


def _matching_row(order, rows):
    for row in rows:
        if not isinstance(row, dict) or row.get('instId') != to_inst_id(order.symbol):
            continue
        size = _decimal(row.get('pos'))
        if size is None or size == 0:
            continue
        side = str(row.get('posSide') or 'net').lower()
        if side == ('long' if order.side == 0 else 'short'):
            return row
        if side == 'net' and ((order.side == 0 and size > 0) or (order.side == 1 and size < 0)):
            return row
    return None


def load_live_profit_orders(*, fresh=False):
    """Return live PnL plus definitively absent/old-generation local IDs.

    Unavailable snapshots, invalid PnL and ambiguous duplicate local orders fail
    closed without cancelling queued work. No exchange/order mutations occur.
    """
    user_id = _recipient_id()
    live, invalid = {}, set()
    if not user_id:
        return live, invalid
    orders = list(Order.objects.select_related('user').filter(user_id=user_id, status=0))
    for mode in ('ordinary', 'lead'):
        candidates = [order for order in orders if order.trading_mode == mode]
        if not candidates:
            continue
        try:
            account = get_user_trading_account(candidates[0].user, active_only=True, trading_mode=mode)
            if not account:
                continue
            eligible = []
            for order in candidates:
                if record_belongs_to_trading_account(
                    record_fingerprint=order.api_key_fingerprint, record_created_at=order.created_at,
                    account_fingerprint=account.api_key_fingerprint, binding_created_at=account.binding_created_at,
                    record_mode=order.trading_mode, account_mode=account.trading_mode,
                ):
                    eligible.append(order)
                else:
                    invalid.add(order.pk)
            if not eligible:
                continue
            client = account.create_futures_client()
            if fresh:
                payload = client.get_positions('SWAP', budget_priority=RequestPriority.BACKGROUND)
                rows = payload.get('data') if isinstance(payload, dict) else None
            else:
                rows = load_shared_exchange_positions(client, account.identity, budget_priority=RequestPriority.BACKGROUND)
            if not isinstance(rows, list):
                continue
            counts = Counter((to_inst_id(order.symbol), order.side) for order in eligible)
            for order in eligible:
                if counts[(to_inst_id(order.symbol), order.side)] != 1:
                    continue
                row = _matching_row(order, rows)
                if row is None:
                    invalid.add(order.pk)
                    continue
                pnl = _decimal(row.get('rawUpl') if 'rawUpl' in row else row.get('upl'))
                # Avoid DECIMAL overflow on malformed upstream values.
                if pnl is not None and abs(pnl) < Decimal('1e20'):
                    live[order.pk] = (order, pnl)
        except Exception as exc:  # notification failures never reach protection jobs
            logger.warning('profit call snapshot unavailable user=%s mode=%s error_type=%s', user_id, mode, type(exc).__name__)
    return live, invalid


def observe_profit_alerts(live):
    user_id = _recipient_id()
    created = 0
    for order, pnl in live.values():
        risk = _decimal(order.stop_loss_amount)
        pnl = _decimal(pnl)
        if order.user_id != user_id or order.status != 0 or risk is None or risk <= 0 or pnl is None:
            continue
        watch, _ = PositionProfitWatch.objects.get_or_create(order=order, defaults={'risk_amount': risk})
        if watch.risk_amount <= 0:
            continue
        for threshold in THRESHOLDS:
            if pnl < watch.risk_amount * threshold:
                break
            _, was_created = PositionProfitAlert.objects.get_or_create(
                watch=watch, threshold=threshold, defaults={'observed_pnl': pnl},
            )
            created += int(was_created)
    return created


def _cancel_inactive(invalid):
    pending = PositionProfitAlert.objects.filter(status='pending', watch__order__user_id=_recipient_id())
    pending.filter(watch__order__status=1).update(status='cancelled', last_error='position_closed')
    if invalid:
        pending.filter(watch__order_id__in=invalid).update(status='cancelled', last_error='position_absent_or_binding_changed')


def scan_profit_alerts():
    if not _recipient_id():
        return 0
    _channel_url()  # fail before creating work when configuration is invalid
    live, invalid = load_live_profit_orders()
    _cancel_inactive(invalid)
    return observe_profit_alerts(live)


def claim_profit_alert(alert_id, *, current_pnl=None):
    user_id = _recipient_id()
    if not user_id:
        return None
    with transaction.atomic():
        # Serialize channel cooldown across orders, modes and scheduler processes.
        get_user_model().objects.select_for_update().get(pk=user_id)
        alert = PositionProfitAlert.objects.select_related('watch__order').filter(
            pk=alert_id, status='pending', watch__order__user_id=user_id,
        ).first()
        if not alert:
            return None
        order = alert.watch.order
        if order.status != 0:
            PositionProfitAlert.objects.filter(pk=alert.pk, status='pending').update(status='cancelled', last_error='position_closed')
            return None
        binding = get_user_binding(order.user, active_only=True, trading_mode=order.trading_mode)
        if not binding:
            return None
        if not record_belongs_to_trading_account(
            record_fingerprint=order.api_key_fingerprint, record_created_at=order.created_at,
            account_fingerprint=binding.api_key_fingerprint, binding_created_at=binding.created_at,
            record_mode=order.trading_mode, account_mode=binding.trading_mode,
        ):
            PositionProfitAlert.objects.filter(pk=alert.pk, status='pending').update(
                status='cancelled', last_error='binding_changed')
            return None
        now = timezone.now()
        from positions.margin_alerts import channel_on_cooldown
        if channel_on_cooldown(user_id, now):
            return None
        pnl = _decimal(current_pnl if current_pnl is not None else alert.observed_pnl)
        risk = alert.watch.risk_amount
        if pnl is None or risk <= 0:
            return None
        base = re.sub(r'[-/]', '', order.symbol.upper()).removesuffix('SWAP').removesuffix('USDT').lower()
        ratio = (pnl / risk).quantize(Decimal('0.01'), rounding=ROUND_HALF_UP)
        label = format((ratio or Decimal('0')).normalize(), 'f')
        amount = format(pnl.quantize(Decimal('1'), rounding=ROUND_HALF_UP), 'f')
        text = f'{base} 合约，浮盈{label}R，{amount}u'
        payload = {'title': text, 'body': text}
        updated = PositionProfitAlert.objects.filter(pk=alert.pk, status='pending').update(
            status='sending', attempted_at=now, payload=payload,
        )
        return payload if updated else None


class EchobellRejected(Exception):
    pass


class _NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def send_echobell(payload):
    url = _channel_url()
    body = json.dumps(payload, ensure_ascii=False, allow_nan=False).encode('utf-8')
    req = request.Request(url, data=body, headers={'Content-Type': 'application/json'}, method='POST')
    opener = request.build_opener(_NoRedirect())
    with opener.open(req, timeout=5) as response:
        status = response.status
        result = json.loads(response.read(65536).decode('utf-8'))
    if status != 200 or not isinstance(result, dict) or result.get('success') is not True:
        raise EchobellRejected('Echobell rejected notification')
    if result.get('notificationTriggered') is False:
        raise EchobellRejected('Echobell rejected notification')


def dispatch_profit_alerts():
    user_id = _recipient_id()
    if not user_id:
        return 0
    _channel_url()
    now = timezone.now()
    PositionProfitAlert.objects.filter(status='sending', watch__order__user_id=user_id,
        attempted_at__lte=now-timedelta(seconds=UNKNOWN_AFTER_SECONDS)).update(
            status='unknown', last_error='interrupted_delivery_outcome_unknown')
    if not PositionProfitAlert.objects.filter(status='pending', watch__order__user_id=user_id).exists():
        return 0
    if PositionProfitAlert.objects.filter(watch__order__user_id=user_id,
            attempted_at__gt=now-timedelta(seconds=CALL_INTERVAL_SECONDS)).exists():
        return 0
    live, invalid = load_live_profit_orders(fresh=True)
    _cancel_inactive(invalid)
    alerts = list(PositionProfitAlert.objects.filter(status='pending', watch__order_id__in=live,
        watch__order__user_id=user_id).order_by('created_at', 'threshold', 'id').values_list('id', 'watch__order_id')[:20])
    for alert_id, order_id in alerts:
        payload = claim_profit_alert(alert_id, current_pnl=live[order_id][1])
        if payload is None:
            continue
        status, error = 'sent', ''
        try:
            send_echobell(payload)
        except EchobellRejected:
            status, error = 'failed', 'echobell_rejected'
        except Exception:
            # Never log exception text: network exceptions can contain the secret URL.
            status, error = 'unknown', 'delivery_outcome_unknown'
        PositionProfitAlert.objects.filter(pk=alert_id, status='sending').update(
            status=status, last_error=error, sent_at=timezone.now() if status == 'sent' else None,
        )
        log = logger.info if status == 'sent' else logger.warning
        log('profit call result alert=%s status=%s', alert_id, status)
        return int(status == 'sent')
    return 0
