"""Read-only account risk monitoring, separate from HTTP and trade execution."""
import hashlib
import logging
import time
from datetime import datetime, timedelta, timezone as dt_timezone
from decimal import Decimal, ROUND_HALF_UP

from django.conf import settings
from django.contrib.auth import get_user_model
from django.db import transaction
from django.utils import timezone

from api_bindings.services import get_user_binding, get_user_trading_account
from positions.margin import present_margin
from positions.models import PositionMarginAlert, PositionMarginWatch, PositionProfitAlert
from positions.profit_alerts import (
    CALL_INTERVAL_SECONDS, UNKNOWN_AFTER_SECONDS, EchobellRejected, _channel_url, send_echobell,
)

logger = logging.getLogger(__name__)
THRESHOLD = Decimal("75")


def recipient_id():
    # The configured Echo channel belongs to ONE user, never all bound accounts.
    if not settings.POSITION_MARGIN_CALL_ENABLED:
        return 0
    return max(0, int(settings.POSITION_PROFIT_CALL_USER_ID))


def account_scope(account):
    identity = (f"{account.user_id}:{account.trading_mode}:{account.binding_id}:"
                f"{account.api_key_fingerprint}:{account.binding_created_at}")
    return hashlib.sha256(identity.encode()).hexdigest()


def channel_on_cooldown(user_id, now):
    since = now - timedelta(seconds=CALL_INTERVAL_SECONDS)
    return (PositionMarginAlert.objects.filter(watch__user_id=user_id, attempted_at__gt=since).exists()
            or PositionProfitAlert.objects.filter(watch__order__user_id=user_id, attempted_at__gt=since).exists())


def claim_margin_alert(user, account, snapshot):
    """Observe and claim atomically; caller performs network I/O after commit."""
    if user.pk != recipient_id() or account.user_id != user.pk or not snapshot.get("supported"):
        return None
    observed = datetime.fromtimestamp(snapshot["observed_at"] / 1000, dt_timezone.utc)
    if not 0 <= (timezone.now() - observed).total_seconds() <= 20:
        return None
    positions = [row for row in snapshot["positions"] if Decimal(row["quantity"]) != 0]
    ratio = snapshot.get("margin_ratio_percent")
    ratio = Decimal(ratio) if ratio is not None else None
    if ratio is not None and (not ratio.is_finite() or ratio < 0):
        return None
    above = bool(positions) and (snapshot.get("liquidation_reached") is True
                                or (ratio is not None and ratio > THRESHOLD))
    if positions and ratio is None and not snapshot.get("liquidation_reached"):
        return None
    with transaction.atomic():
        get_user_model().objects.select_for_update().get(pk=user.pk)
        binding = get_user_binding(user, active_only=True, trading_mode=account.trading_mode)
        if (not binding or binding.pk != account.binding_id
                or (binding.api_key_fingerprint, binding.created_at) != account.generation):
            return None
        watch, _ = PositionMarginWatch.objects.get_or_create(scope=account_scope(account), defaults={
            "user_id": user.pk, "trading_mode": account.trading_mode})
        if watch.observed_at and watch.observed_at >= observed:
            return None
        now = timezone.now()
        if above and not watch.above_threshold:
            symbols = sorted({row["symbol"] for row in positions})
            label = (format(ratio.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP), "f") + "%"
                     if ratio is not None else "已达强平线")
            mode = "带单" if account.trading_mode == "lead" else "合约"
            title = f"{mode}账户保证金率 {label}"
            body = f"{', '.join(symbols)}；账户全仓保证金率高于 75%，请及时查看风险。"
            PositionMarginAlert.objects.create(watch=watch, payload={"title": title, "body": body})
        watch.above_threshold = above
        watch.observed_at = observed
        watch.save(update_fields=["above_threshold", "observed_at"])
        if not above:
            watch.alerts.filter(status="pending").update(status="cancelled", last_error="risk_recovered")
            return None
        # Alerts from a retired binding never apply to a replacement binding.
        PositionMarginAlert.objects.filter(watch__user_id=user.pk,
            watch__trading_mode=account.trading_mode, status="pending").exclude(watch=watch).update(
                status="cancelled", last_error="binding_changed")
        if channel_on_cooldown(user.pk, now):
            return None
        alert = watch.alerts.filter(status="pending").order_by("created_at", "pk").first()
        if alert and PositionMarginAlert.objects.filter(pk=alert.pk, status="pending").update(
                status="sending", attempted_at=now):
            return alert.pk, alert.payload
    return None


def dispatch_margin_alerts():
    user_id = recipient_id()
    if not user_id:
        return 0
    _channel_url()
    user = get_user_model().objects.filter(pk=user_id, is_active=True).first()
    if not user:
        return 0
    PositionMarginAlert.objects.filter(watch__user_id=user_id, status="sending",
        attempted_at__lte=timezone.now() - timedelta(seconds=UNKNOWN_AFTER_SECONDS)).update(
            status="unknown", last_error="interrupted_delivery_outcome_unknown")
    sent = 0
    for mode in ("ordinary", "lead"):
        try:
            account = get_user_trading_account(user, active_only=True, trading_mode=mode)
            if not account:
                continue
            started = time.time()
            config, raw = account.create_futures_client().get_margin_account_snapshot()
            snapshot = present_margin(config, raw, observed_at=int(started * 1000))
            claimed = claim_margin_alert(user, account, snapshot)
        except Exception as exc:
            # No raw response, credentials, URL or network exception text in logs.
            logger.warning("margin call snapshot unavailable user=%s mode=%s error_type=%s",
                           user_id, mode, type(exc).__name__)
            continue
        if not claimed:
            continue
        alert_id, payload = claimed
        status, error = "sent", ""
        try:
            send_echobell(payload)
        except EchobellRejected:
            status, error = "failed", "echobell_rejected"
        except Exception:
            status, error = "unknown", "delivery_outcome_unknown"
        PositionMarginAlert.objects.filter(pk=alert_id, status="sending").update(
            status=status, last_error=error, sent_at=timezone.now() if status == "sent" else None)
        sent += int(status == "sent")
    return sent
