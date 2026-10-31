from __future__ import annotations

import hashlib
import json
import logging
from urllib import request

from django.conf import settings
from django.core.cache import cache

from common.errors import safe_error_summary


logger = logging.getLogger(__name__)


def send_ops_alert_once(*, key: str, title: str, text: str, cooldown_seconds: int = 1800) -> bool:
    url = str(getattr(settings, "OPS_ALERT_URL", "") or "").strip()
    token = str(getattr(settings, "OPS_ALERT_TOKEN", "") or "").strip()
    if not url or not token:
        logger.error("ops alert channel is not configured title=%s", title)
        return False

    digest = hashlib.sha256(str(key).encode("utf-8")).hexdigest()
    cache_key = f"ops-alert:{digest}"
    if not cache.add(cache_key, "1", timeout=max(60, int(cooldown_seconds))):
        return False

    body = json.dumps(
        {"token": token, "title": str(title)[:100], "text": str(text)[:1000]},
        ensure_ascii=False,
    ).encode("utf-8")
    req = request.Request(url, data=body, headers={"Content-Type": "application/json"}, method="POST")
    try:
        timeout = max(1.0, float(getattr(settings, "OPS_ALERT_TIMEOUT_SECONDS", 5)))
        with request.urlopen(req, timeout=timeout) as response:
            payload = json.loads(response.read(64 * 1024).decode("utf-8") or "{}")
        if not isinstance(payload, dict) or not payload.get("ok"):
            raise RuntimeError("ops alert endpoint rejected the message")
        return True
    except Exception as exc:  # noqa: BLE001
        try:
            cache.delete(cache_key)
        except Exception as cache_exc:  # noqa: BLE001
            logger.warning(
                "ops alert cooldown release failed title=%s err=%s",
                title,
                safe_error_summary(cache_exc),
            )
        logger.error("ops alert send failed title=%s err=%s", title, safe_error_summary(exc))
        return False
