from __future__ import annotations

import re


_URL_PATTERN = re.compile(r"\b(?:https?|wss?)://[^\s<>]+", re.IGNORECASE)
_AUTHORIZATION_PATTERN = re.compile(
    r"(?i)\b(authorization|proxy[-_ ]?authorization)[\"']?\s*[:=]\s*[\"']?"
    r"(?:(?:bearer|basic)\s+)?[^\"'\s,;}\]]+"
)
_SENSITIVE_VALUE_PATTERN = re.compile(
    r"(?i)\b(x[-_ ]?mbx[-_ ]?api[-_ ]?key|api[-_ ]?key|access[-_ ]?key|"
    r"secret(?:[-_ ]?key)?|signature|token|password|passphrase)"
    r"[\"']?\s*[:=]\s*[\"']?[^\"'\s,;&}\]]+"
)
_BEARER_PATTERN = re.compile(r"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]+")


def safe_error_summary(
    error: BaseException | str,
    *,
    limit: int = 500,
    include_type: bool = True,
) -> str:
    """Return a bounded diagnostic message without endpoint or credential material."""
    error_type = error.__class__.__name__ if isinstance(error, BaseException) else "Error"
    message = " ".join(str(error or "").split())
    message = _URL_PATTERN.sub("[redacted-url]", message)
    message = _AUTHORIZATION_PATTERN.sub(
        lambda match: f"{match.group(1)}=[redacted]",
        message,
    )
    message = _SENSITIVE_VALUE_PATTERN.sub(
        lambda match: f"{match.group(1)}=[redacted]",
        message,
    )
    message = _BEARER_PATTERN.sub(lambda match: f"{match.group(1)} [redacted]", message)
    summary = f"{error_type}: {message}" if include_type and message else (message or error_type)
    return summary[: max(1, int(limit))]
