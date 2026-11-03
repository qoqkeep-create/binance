from __future__ import annotations

import json
import logging
from datetime import timedelta
from typing import Any, Optional
from urllib import request
from urllib.parse import urlsplit

from django.conf import settings
from django.db import transaction
from django.db.models import Q
from django.utils import timezone

from common.ops_alerts import send_ops_alert_once
from common.errors import safe_error_summary
from positions.models import ExternalTradeSignalDelivery, Order, TradeNotificationEvent
from positions.notifications import prepare_trade_notification, trade_notification_payload


logger = logging.getLogger(__name__)

_TERMINAL_EVENT_TYPES = {
    TradeNotificationEvent.TYPE_STOP_LOSS,
    TradeNotificationEvent.TYPE_STRATEGY_TAKE_PROFIT,
    TradeNotificationEvent.TYPE_MANUAL_TAKE_PROFIT,
}
_TERMINAL_SETTLEMENT_STATUSES = {
    Order.SETTLEMENT_STATUS_SETTLED,
    Order.SETTLEMENT_STATUS_ESTIMATED,
}
DELIVERY_LEASE_SECONDS = 60
DELIVERY_MAX_ATTEMPTS = 8


class _NoRedirectHandler(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ARG002
        return None


def enqueue_external_trade_signal(
    event: TradeNotificationEvent,
) -> Optional[ExternalTradeSignalDelivery]:
    if not bool(getattr(settings, "EXTERNAL_TRADE_SIGNAL_ENABLED", False)):
        return None
    delivery, _ = ExternalTradeSignalDelivery.objects.get_or_create(
        event=event,
    )
    return delivery


def _backfill_missing_external_deliveries(limit: int) -> int:
    """Repair the event-to-channel handoff without coupling network delivery to trading."""
    event_ids = list(
        TradeNotificationEvent.objects.filter(
            context__external_delivery_required=True,
            external_signal_delivery__isnull=True,
        )
        .order_by("created_at", "id")
        .values_list("id", flat=True)[: max(1, int(limit))]
    )
    created = 0
    for event_id in event_ids:
        _, was_created = ExternalTradeSignalDelivery.objects.get_or_create(event_id=event_id)
        created += int(was_created)
    return created


def _wire_payload(delivery: ExternalTradeSignalDelivery) -> dict[str, Any]:
    return trade_notification_payload(delivery.event)


def send_external_trade_signal(payload: dict[str, Any]) -> dict[str, Any]:
    if not getattr(settings, "TRADE_NOTIFICATION_ENABLED", True):
        raise RuntimeError("trade notifications are disabled")
    url = str(getattr(settings, "EXTERNAL_TRADE_SIGNAL_URL", "") or "").strip()
    api_key = str(getattr(settings, "EXTERNAL_TRADE_SIGNAL_API_KEY", "") or "").strip()
    parsed = urlsplit(url)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
    ):
        raise RuntimeError("external trade signal URL must be a credential-free HTTPS URL")
    if not api_key:
        raise RuntimeError("external trade signal API key is not configured")

    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")
    req = request.Request(
        url=url,
        data=body,
        headers={"Content-Type": "application/json", "X-External-Message-Key": api_key},
        method="POST",
    )
    timeout = float(getattr(settings, "EXTERNAL_TRADE_SIGNAL_TIMEOUT_SECONDS", 5))
    opener = request.build_opener(_NoRedirectHandler())
    with opener.open(req, timeout=max(1.0, timeout)) as response:
        status = int(getattr(response, "status", response.getcode()))
        result = json.loads(response.read(64 * 1024).decode("utf-8") or "{}")
    if status != 202 or not isinstance(result, dict) or int(result.get("code") or 0) != 202:
        raise RuntimeError(f"external trade signal endpoint rejected the message with HTTP {status}")
    return result


def _claim_external_delivery(delivery_id: int, *, now) -> Optional[tuple[dict[str, Any], int, str, int]]:
    with transaction.atomic():
        delivery = (
            ExternalTradeSignalDelivery.objects.select_for_update()
            .select_related("event__order")
            .filter(id=delivery_id)
            .first()
        )
        if not delivery:
            return None
        retry_due = (
            delivery.status in {
                ExternalTradeSignalDelivery.STATUS_PENDING,
                ExternalTradeSignalDelivery.STATUS_FAILED,
            }
            and (delivery.next_retry_at is None or delivery.next_retry_at <= now)
        )
        lease_expired = (
            delivery.status == ExternalTradeSignalDelivery.STATUS_SENDING
            and delivery.lease_expires_at is not None
            and delivery.lease_expires_at <= now
        )
        if not retry_due and not lease_expired:
            return None
        if not prepare_trade_notification(delivery.event):
            return None
        delivery.attempt_count += 1
        delivery.status = ExternalTradeSignalDelivery.STATUS_SENDING
        delivery.lease_expires_at = now + timedelta(seconds=DELIVERY_LEASE_SECONDS)
        delivery.next_retry_at = None
        delivery.payload = _wire_payload(delivery)
        delivery.save(
            update_fields=[
                "payload",
                "attempt_count",
                "status",
                "lease_expires_at",
                "next_retry_at",
                "updated_at",
            ]
        )
        return delivery.payload, delivery.attempt_count, delivery.event.event_type, delivery.event_id


def _record_external_delivery_result(
    delivery_id: int,
    *,
    attempt_count: int,
    error: Optional[Exception] = None,
) -> tuple[bool, bool]:
    now = timezone.now()
    selector = ExternalTradeSignalDelivery.objects.filter(
        id=delivery_id,
        status=ExternalTradeSignalDelivery.STATUS_SENDING,
        attempt_count=attempt_count,
    )
    if error is None:
        updated = selector.update(
            status=ExternalTradeSignalDelivery.STATUS_SENT,
            sent_at=now,
            next_retry_at=None,
            lease_expires_at=None,
            last_error="",
            updated_at=now,
        )
        return bool(updated), False

    exhausted = attempt_count >= DELIVERY_MAX_ATTEMPTS
    retry_seconds = min(3600, 15 * (2 ** min(attempt_count - 1, 8)))
    updated = selector.update(
        status=(
            ExternalTradeSignalDelivery.STATUS_EXHAUSTED
            if exhausted
            else ExternalTradeSignalDelivery.STATUS_FAILED
        ),
        next_retry_at=None if exhausted else now + timedelta(seconds=retry_seconds),
        lease_expires_at=None,
        last_error=safe_error_summary(error),
        updated_at=now,
    )
    return False, bool(updated and exhausted)


def dispatch_pending_external_trade_signals(limit: int = 20) -> int:
    if not getattr(settings, "TRADE_NOTIFICATION_ENABLED", True):
        return 0
    if not bool(getattr(settings, "EXTERNAL_TRADE_SIGNAL_ENABLED", False)):
        return 0

    normalized_limit = max(1, int(limit))
    _backfill_missing_external_deliveries(normalized_limit)
    now = timezone.now()
    claimable = (
        Q(
            status__in=[
                ExternalTradeSignalDelivery.STATUS_PENDING,
                ExternalTradeSignalDelivery.STATUS_FAILED,
            ],
        )
        & (Q(next_retry_at__isnull=True) | Q(next_retry_at__lte=now))
    ) | Q(
        status=ExternalTradeSignalDelivery.STATUS_SENDING,
        lease_expires_at__lte=now,
    )
    delivery_ids = list(
        ExternalTradeSignalDelivery.objects.filter(claimable)
        .filter(
            ~Q(event__event_type__in=_TERMINAL_EVENT_TYPES)
            | ~Q(event__content="")
            | Q(
                event__order__status=1,
                event__order__settlement_status__in=_TERMINAL_SETTLEMENT_STATUSES,
            )
        )
        .order_by("created_at", "id")
        .values_list("id", flat=True)[:normalized_limit]
    )
    sent = 0
    for delivery_id in delivery_ids:
        claimed = _claim_external_delivery(delivery_id, now=now)
        if not claimed:
            continue
        payload, attempt_count, event_type, event_id = claimed
        try:
            send_external_trade_signal(payload)
        except Exception as exc:  # noqa: BLE001
            error_summary = safe_error_summary(exc)
            _, exhausted = _record_external_delivery_result(
                delivery_id,
                attempt_count=attempt_count,
                error=exc,
            )
            log = logger.critical if exhausted else logger.warning
            log(
                "external trade signal send failed delivery=%s event=%s type=%s attempt=%s exhausted=%s err=%s",
                delivery_id,
                event_id,
                event_type,
                attempt_count,
                int(exhausted),
                error_summary,
            )
            if exhausted:
                send_ops_alert_once(
                    key=f"external-trade-signal-exhausted:{delivery_id}",
                    title="外部交易通知投递耗尽",
                    text=f"投递 {delivery_id} / 事件 {event_id}（{event_type}）连续 {attempt_count} 次失败：{error_summary}",
                )
            continue
        delivered, _ = _record_external_delivery_result(delivery_id, attempt_count=attempt_count)
        if delivered:
            sent += 1
    return sent
