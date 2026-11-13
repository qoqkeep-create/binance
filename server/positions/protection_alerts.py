"""Prompt user-visible feedback for protection states that cannot self-resolve.

Reliability may be segmented, but no segment may stall silently: when the
background reconciler cannot converge a protection state within its bounded
window, the configured alert channel notifies the user so they can decide,
instead of the system waiting forever without telling anyone.
"""
import logging

from django.conf import settings
from django.core.cache import cache

logger = logging.getLogger(__name__)
ALERT_COOLDOWN_SECONDS = 600
PROTECTION_FAILURE_ALERT_SECONDS = 120
UNADOPTED_POSITION_ALERT_SECONDS = 120
UNKNOWN_COMMAND_ALERT_SECONDS = 600


def _recipient_id():
    # The configured Echo channel belongs to ONE user, never all bound accounts.
    if not getattr(settings, "POSITION_PROFIT_CALL_ENABLED", False):
        return 0
    return max(0, int(getattr(settings, "POSITION_PROFIT_CALL_USER_ID", 0)))


def send_protection_alert(user_id, *, kind, title, body):
    """Best-effort channel alert with a per-kind cooldown; never raises."""
    if not user_id or user_id != _recipient_id():
        return False
    try:
        if not cache.add(f"protection-alert:{kind}:{user_id}", "1", timeout=ALERT_COOLDOWN_SECONDS):
            return False
    except Exception:  # noqa: BLE001
        return False
    try:
        from positions.profit_alerts import send_echobell

        send_echobell({"title": title, "body": body})
        logger.info("protection alert sent kind=%s user=%s", kind, user_id)
        return True
    except Exception as exc:  # noqa: BLE001
        logger.warning(
            "protection alert delivery failed kind=%s error_type=%s",
            kind, type(exc).__name__,
        )
        return False