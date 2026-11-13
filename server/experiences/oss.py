"""Small, dependency-free Aliyun OSS signed PUT URL helper.

The API never receives image bytes or exposes an AccessKey secret.  It only
creates a short-lived URL for a browser upload, after which the experience
record stores the configured public/CDN URL.
"""

import base64
import hashlib
import hmac
import mimetypes
import re
import uuid
from datetime import datetime, timezone
from urllib.parse import quote, urlencode, urlsplit

from django.conf import settings


class OSSConfigurationError(ValueError):
    """Raised when OSS is disabled or has an invalid endpoint."""


def is_configured() -> bool:
    return all(
        (
            settings.OSS_ENDPOINT,
            settings.OSS_BUCKET,
            settings.OSS_ACCESS_KEY_ID,
            settings.OSS_ACCESS_KEY_SECRET,
        )
    )


def _endpoint_parts() -> tuple[str, str]:
    raw = settings.OSS_ENDPOINT
    parsed = urlsplit(raw if "://" in raw else f"https://{raw}")
    if parsed.scheme not in {"http", "https"} or not parsed.netloc or parsed.path not in {"", "/"}:
        raise OSSConfigurationError("OSS_ENDPOINT 必须是 https://oss-cn-xxx.aliyuncs.com")
    return parsed.scheme, parsed.netloc


def _object_key(user_id: int, content_type: str) -> str:
    prefix = re.sub(r"[^A-Za-z0-9/_-]+", "-", settings.OSS_KEY_PREFIX).strip("/")
    extension = mimetypes.guess_extension(content_type) or ""
    if extension == ".jpe":
        extension = ".jpg"
    return f"{prefix}/{user_id}/{uuid.uuid4().hex}{extension}"


def _canonical_resource(key: str) -> str:
    return f"/{settings.OSS_BUCKET}/{quote(key, safe='/~')}"


def _public_url(scheme: str, host: str, key: str) -> str:
    base = settings.OSS_PUBLIC_BASE_URL or f"{scheme}://{settings.OSS_BUCKET}.{host}"
    return f"{base.rstrip('/')}/{quote(key, safe='/~')}"


def create_presigned_put(*, user_id: int, content_type: str, size: int) -> dict:
    if not is_configured():
        raise OSSConfigurationError("OSS 尚未配置，请先设置 OSS_ENDPOINT、OSS_BUCKET 和受限 RAM 凭证")
    if not content_type.startswith("image/"):
        raise ValueError("只支持图片文件")
    if size <= 0 or size > settings.OSS_MAX_IMAGE_BYTES:
        raise ValueError(f"单张图片不能超过 {settings.OSS_MAX_IMAGE_BYTES // (1024 * 1024)} MB")

    scheme, host = _endpoint_parts()
    key = _object_key(user_id, content_type)
    expires = int(datetime.now(tz=timezone.utc).timestamp()) + settings.OSS_SIGNED_URL_TTL
    resource = _canonical_resource(key)
    string_to_sign = "\n".join(("PUT", "", content_type, str(expires), "", resource))
    signature = base64.b64encode(
        hmac.new(
            settings.OSS_ACCESS_KEY_SECRET.encode("utf-8"),
            string_to_sign.encode("utf-8"),
            hashlib.sha1,
        ).digest()
    ).decode("ascii")
    query = urlencode(
        {
            "OSSAccessKeyId": settings.OSS_ACCESS_KEY_ID,
            "Expires": expires,
            "Signature": signature,
        }
    )
    upload_url = f"{scheme}://{settings.OSS_BUCKET}.{host}/{quote(key, safe='/~')}?{query}"
    return {
        "url": upload_url,
        "method": "PUT",
        "headers": {"Content-Type": content_type},
        "public_url": _public_url(scheme, host, key),
        "object_key": key,
        "expires_at": expires,
        "max_bytes": settings.OSS_MAX_IMAGE_BYTES,
    }
