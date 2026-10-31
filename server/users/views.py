import hashlib
import logging
import threading
import time

from django.conf import settings
from django.contrib.auth import password_validation
from django.contrib.auth.tokens import default_token_generator
from django.core.cache import cache
from django.core.exceptions import ValidationError as DjangoValidationError
from django.core.mail import send_mail
from django.db import IntegrityError, transaction
from django.utils.encoding import force_bytes, force_str
from django.utils.http import urlsafe_base64_decode, urlsafe_base64_encode
from django.utils import timezone
from rest_framework.permissions import AllowAny
from rest_framework.views import APIView
from rest_framework_simplejwt.exceptions import TokenError
from rest_framework_simplejwt.tokens import RefreshToken
from rest_framework_simplejwt.serializers import TokenRefreshSerializer

from common.errors import safe_error_summary
from common.response import fail, ok
from common.request import request_data_mapping
from users.models import SystemSetting, User
from users.serializers import (
    LoginSerializer,
    PasswordResetConfirmSerializer,
    PasswordResetRequestSerializer,
    RegisterSerializer,
)

# 管理员权限基于 User.is_admin 标志位（迁移 0006 种子初始管理员），不再硬编码邮箱


logger = logging.getLogger(__name__)
PASSWORD_RESET_RESPONSE = "如果该邮箱已注册，重置邮件会在几分钟内发送"
_LOCAL_AUTH_CACHE_LOCK = threading.Lock()
_LOCAL_AUTH_CACHE: dict[str, tuple[int, float]] = {}
_AUTH_CACHE_WARNING_TIMES: dict[str, float] = {}
_LOCAL_AUTH_CACHE_MAX_ENTRIES = 8192
_LOCAL_AUTH_CACHE_LIMITED_COUNT = 2**31 - 1
_LOCAL_AUTH_CACHE_OVERFLOW_UNTIL = 0.0


def _request_ip_hash(request) -> str:
    raw_ip = request.META.get("HTTP_X_REAL_IP") or request.META.get("REMOTE_ADDR") or "unknown"
    return hashlib.sha256(str(raw_ip).encode("utf-8")).hexdigest()[:24]


def _warn_auth_cache_unavailable(operation: str, exc: Exception) -> None:
    now = time.monotonic()
    with _LOCAL_AUTH_CACHE_LOCK:
        last_warning = _AUTH_CACHE_WARNING_TIMES.get(operation, 0.0)
        if now - last_warning < 60:
            return
        _AUTH_CACHE_WARNING_TIMES[operation] = now
    logger.warning(
        "auth_rate_limit_cache_unavailable operation=%s err=%s",
        operation,
        safe_error_summary(exc),
    )


def _local_auth_cache_get(key: str, *, include_overflow: bool = True) -> int:
    now = time.monotonic()
    with _LOCAL_AUTH_CACHE_LOCK:
        value, expires_at = _LOCAL_AUTH_CACHE.get(key, (0, 0.0))
        if expires_at <= now:
            _LOCAL_AUTH_CACHE.pop(key, None)
            return 1 if include_overflow and _LOCAL_AUTH_CACHE_OVERFLOW_UNTIL > now else 0
        return value


def _local_auth_cache_set(key: str, value: int, *, timeout: int) -> bool:
    global _LOCAL_AUTH_CACHE_OVERFLOW_UNTIL
    now = time.monotonic()
    with _LOCAL_AUTH_CACHE_LOCK:
        if key not in _LOCAL_AUTH_CACHE and len(_LOCAL_AUTH_CACHE) >= _LOCAL_AUTH_CACHE_MAX_ENTRIES:
            expired = [stored_key for stored_key, (_, expires_at) in _LOCAL_AUTH_CACHE.items() if expires_at <= now]
            for stored_key in expired:
                _LOCAL_AUTH_CACHE.pop(stored_key, None)
            if len(_LOCAL_AUTH_CACHE) >= _LOCAL_AUTH_CACHE_MAX_ENTRIES:
                _LOCAL_AUTH_CACHE_OVERFLOW_UNTIL = max(
                    _LOCAL_AUTH_CACHE_OVERFLOW_UNTIL,
                    now + max(int(timeout), 1),
                )
                return False
        _LOCAL_AUTH_CACHE[key] = (int(value), now + max(int(timeout), 1))
        return True


def _local_auth_cache_increment(key: str, *, timeout: int) -> tuple[int, bool]:
    global _LOCAL_AUTH_CACHE_OVERFLOW_UNTIL
    now = time.monotonic()
    with _LOCAL_AUTH_CACHE_LOCK:
        current, expires_at = _LOCAL_AUTH_CACHE.get(key, (0, 0.0))
        if expires_at <= now:
            _LOCAL_AUTH_CACHE.pop(key, None)
            current = 0
            expires_at = now + max(int(timeout), 1)
        if key not in _LOCAL_AUTH_CACHE and len(_LOCAL_AUTH_CACHE) >= _LOCAL_AUTH_CACHE_MAX_ENTRIES:
            expired = [stored_key for stored_key, (_, expiry) in _LOCAL_AUTH_CACHE.items() if expiry <= now]
            for stored_key in expired:
                _LOCAL_AUTH_CACHE.pop(stored_key, None)
            if len(_LOCAL_AUTH_CACHE) >= _LOCAL_AUTH_CACHE_MAX_ENTRIES:
                _LOCAL_AUTH_CACHE_OVERFLOW_UNTIL = max(
                    _LOCAL_AUTH_CACHE_OVERFLOW_UNTIL,
                    now + max(int(timeout), 1),
                )
                return _LOCAL_AUTH_CACHE_LIMITED_COUNT, False
        count = current + 1
        _LOCAL_AUTH_CACHE[key] = (count, expires_at)
        return count, True


def _local_auth_cache_delete(key: str) -> None:
    with _LOCAL_AUTH_CACHE_LOCK:
        _LOCAL_AUTH_CACHE.pop(key, None)


def _clear_local_auth_cache_state() -> None:
    """Reset process-local fallback state for isolated tests."""
    global _LOCAL_AUTH_CACHE_OVERFLOW_UNTIL
    with _LOCAL_AUTH_CACHE_LOCK:
        _LOCAL_AUTH_CACHE.clear()
        _AUTH_CACHE_WARNING_TIMES.clear()
        _LOCAL_AUTH_CACHE_OVERFLOW_UNTIL = 0.0


def _auth_cache_get(key: str) -> int:
    try:
        value = int(cache.get(key) or 0)
    except Exception as exc:  # noqa: BLE001
        _warn_auth_cache_unavailable("get", exc)
        return _local_auth_cache_get(key)
    return max(value, _local_auth_cache_get(key, include_overflow=False))


def _auth_cache_set(key: str, value: int, *, timeout: int) -> None:
    _local_auth_cache_set(key, value, timeout=timeout)
    try:
        cache.set(key, value, timeout=timeout)
    except Exception as exc:  # noqa: BLE001
        _warn_auth_cache_unavailable("set", exc)
        return


def _auth_cache_delete(*keys: str) -> None:
    try:
        cache.delete_many(keys)
    except Exception as exc:  # noqa: BLE001
        _warn_auth_cache_unavailable("delete", exc)
    for key in keys:
        _local_auth_cache_delete(key)


def _increment_cache_counter(key: str, *, timeout: int) -> int:
    local_count, local_stored = _local_auth_cache_increment(key, timeout=timeout)
    try:
        if cache.add(key, 1, timeout=timeout):
            count = 1
        else:
            count = int(cache.incr(key))
    except Exception as exc:  # noqa: BLE001
        _warn_auth_cache_unavailable("increment", exc)
        return local_count if local_stored else _LOCAL_AUTH_CACHE_LIMITED_COUNT
    return max(count, local_count if local_stored else 0)


def _set_refresh_cookie(response, refresh_token: str):
    response.set_cookie(
        settings.AUTH_REFRESH_COOKIE_NAME,
        refresh_token,
        max_age=int(settings.SIMPLE_JWT["REFRESH_TOKEN_LIFETIME"].total_seconds()),
        httponly=True,
        secure=settings.AUTH_REFRESH_COOKIE_SECURE,
        samesite=settings.AUTH_REFRESH_COOKIE_SAMESITE,
        path=settings.AUTH_REFRESH_COOKIE_PATH,
    )
    return response


def _clear_refresh_cookie(response):
    response.delete_cookie(
        settings.AUTH_REFRESH_COOKIE_NAME,
        path=settings.AUTH_REFRESH_COOKIE_PATH,
        samesite=settings.AUTH_REFRESH_COOKIE_SAMESITE,
    )
    return response


def _password_reset_rate_allowed(request, email: str) -> bool:
    email_hash = hashlib.sha256(email.encode("utf-8")).hexdigest()[:24]
    ip_hash = _request_ip_hash(request)
    limits = (
        (f"auth:password-reset:email:{email_hash}", 5, 1800),
        (f"auth:password-reset:ip:{ip_hash}", 20, 3600),
    )
    allowed = True
    for key, limit, timeout in limits:
        count = _increment_cache_counter(key, timeout=timeout)
        if count > limit:
            allowed = False
    return allowed


def _registration_rate_allowed(request) -> bool:
    count = _increment_cache_counter(
        f"auth:register:ip:{_request_ip_hash(request)}",
        timeout=max(int(settings.AUTH_REGISTER_RATE_WINDOW_SECONDS), 60),
    )
    return count <= max(int(settings.AUTH_REGISTER_IP_MAX_ATTEMPTS), 1)


class RegisterView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        if not _registration_rate_allowed(request):
            return fail("注册请求过于频繁，请稍后再试", code=429, status=429)
        serializer = RegisterSerializer(data=request.data)
        if not serializer.is_valid():
            errors = serializer.errors
            first_key = next(iter(errors.keys()), None)
            if first_key and errors[first_key]:
                return fail(str(errors[first_key][0]))
            return fail("请求参数错误")

        try:
            serializer.save()
        except IntegrityError:
            # The database is the final arbiter when concurrent requests race the
            # serializer's friendly existence check.
            email = serializer.validated_data["email"]
            if User.objects.filter(email=email).exists():
                return fail("该邮箱已注册，请直接登录")
            raise
        return ok(message="注册成功")


class LoginView(APIView):
    permission_classes = [AllowAny]

    def _fail_key(self, email: str) -> str:
        digest = hashlib.sha256(email.encode("utf-8")).hexdigest()[:24]
        return f"auth:login:account-fail:{digest}"

    def _lock_key(self, email: str) -> str:
        digest = hashlib.sha256(email.encode("utf-8")).hexdigest()[:24]
        return f"auth:login:account-lock:{digest}"

    def _ip_fail_key(self, request) -> str:
        return f"auth:login:ip-fail:{_request_ip_hash(request)}"

    def _ip_lock_key(self, request) -> str:
        return f"auth:login:ip-lock:{_request_ip_hash(request)}"

    @staticmethod
    def _setting(name: str, default: int) -> int:
        try:
            return max(int(getattr(settings, name, default)), 1)
        except (TypeError, ValueError):
            return default

    def post(self, request):
        payload = request_data_mapping(request)
        if payload is None:
            return fail("请求参数必须是对象")
        email = (payload.get("email") or "").strip().lower()
        account_locked = bool(email and _auth_cache_get(self._lock_key(email)))
        ip_locked = bool(_auth_cache_get(self._ip_lock_key(request)))
        if account_locked or ip_locked:
            return fail("账号或密码错误次数过多，请3分钟后再试")

        serializer = LoginSerializer(data=payload, context={"request": request})
        if not serializer.is_valid():
            msg = "账号或密码错误"
            errors = serializer.errors
            first_key = next(iter(errors.keys()), None)
            if first_key and errors[first_key]:
                msg = str(errors[first_key][0])

            if msg == "账号或密码错误" and email:
                window = self._setting("AUTH_LOGIN_FAILURE_WINDOW_SECONDS", 3600)
                lock_seconds = self._setting("AUTH_LOGIN_LOCK_SECONDS", 180)
                account_count = _increment_cache_counter(
                    self._fail_key(email),
                    timeout=window,
                )
                ip_count = _increment_cache_counter(
                    self._ip_fail_key(request),
                    timeout=window,
                )
                should_lock_account = account_count >= self._setting(
                    "AUTH_LOGIN_ACCOUNT_MAX_FAILURES", 10
                )
                should_lock_ip = ip_count >= self._setting(
                    "AUTH_LOGIN_IP_MAX_FAILURES", 50
                )
                if should_lock_account:
                    _auth_cache_set(self._lock_key(email), 1, timeout=lock_seconds)
                if should_lock_ip:
                    _auth_cache_set(self._ip_lock_key(request), 1, timeout=lock_seconds)
                if should_lock_account or should_lock_ip:
                    return fail("账号或密码错误次数过多，请3分钟后再试")
            return fail(msg)

        _auth_cache_delete(self._fail_key(email), self._lock_key(email))
        user = serializer.validated_data["user"]
        refresh = RefreshToken.for_user(user)
        response = ok(
            message="登录成功",
            data={
                "token": str(refresh.access_token),
                "user_id": str(user.pk),
                "email": user.email,
                "preflight_completed_at": user.preflight_completed_at.isoformat() if user.preflight_completed_at else "",
            },
        )
        return _set_refresh_cookie(response, str(refresh))


class RefreshAccessTokenView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        payload = request_data_mapping(request)
        if payload is None:
            return fail("请求参数必须是对象")
        # Request-body fallback is temporary compatibility for sessions created
        # before refresh tokens moved to HttpOnly cookies.
        refresh_token = request.COOKIES.get(settings.AUTH_REFRESH_COOKIE_NAME) or payload.get("refresh_token")
        serializer = TokenRefreshSerializer(data={"refresh": refresh_token})
        try:
            is_valid = serializer.is_valid()
        except TokenError:
            is_valid = False
        if not is_valid:
            return _clear_refresh_cookie(fail("登录状态已过期，请重新登录", code=401, status=401))
        response = ok(data={"token": serializer.validated_data["access"]})
        next_refresh = serializer.validated_data.get("refresh") or refresh_token
        return _set_refresh_cookie(response, next_refresh)


class LogoutView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        payload = request_data_mapping(request)
        if payload is None:
            return fail("请求参数必须是对象")
        refresh_token = request.COOKIES.get(settings.AUTH_REFRESH_COOKIE_NAME) or payload.get("refresh_token")
        if refresh_token:
            try:
                RefreshToken(refresh_token).blacklist()
            except TokenError:
                pass
        return _clear_refresh_cookie(ok(message="已退出登录"))


class PasswordResetRequestView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        serializer = PasswordResetRequestSerializer(data=request.data)
        if not serializer.is_valid():
            return fail("请输入有效的邮箱地址")
        email = serializer.validated_data["email"]
        if not _password_reset_rate_allowed(request, email):
            return fail("请求过于频繁，请稍后再试", code=429, status=429)

        user = User.objects.filter(email=email, is_active=True).first()
        if user:
            uid = urlsafe_base64_encode(force_bytes(user.pk))
            token = default_token_generator.make_token(user)
            reset_url = f"{settings.PUBLIC_APP_URL}/login?reset_uid={uid}&reset_token={token}"
            try:
                send_mail(
                    subject="RISKON 密码重置",
                    message=(
                        "你正在重置 RISKON 登录密码。\n\n"
                        f"请在 {settings.PASSWORD_RESET_TIMEOUT // 60} 分钟内打开以下链接完成重置：\n"
                        f"{reset_url}\n\n"
                        "如果不是你本人操作，请忽略此邮件。"
                    ),
                    from_email=settings.DEFAULT_FROM_EMAIL,
                    recipient_list=[user.email],
                    fail_silently=False,
                )
            except Exception as exc:  # noqa: BLE001
                logger.error(
                    "password_reset_email_failed user=%s err=%s",
                    user.pk,
                    safe_error_summary(exc),
                )
        return ok(message=PASSWORD_RESET_RESPONSE)


class PasswordResetConfirmView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        serializer = PasswordResetConfirmSerializer(data=request.data)
        if not serializer.is_valid():
            errors = serializer.errors
            first_key = next(iter(errors.keys()), None)
            message = str(errors[first_key][0]) if first_key and errors[first_key] else "请求参数错误"
            return fail(message)

        data = serializer.validated_data
        try:
            user_id = force_str(urlsafe_base64_decode(data["uid"]))
        except (TypeError, ValueError, OverflowError):
            return fail("重置链接无效或已过期，请重新申请")

        with transaction.atomic():
            user = User.objects.select_for_update().filter(pk=user_id, is_active=True).first()
            if not user or not default_token_generator.check_token(user, data["token"]):
                return fail("重置链接无效或已过期，请重新申请")
            try:
                password_validation.validate_password(data["new_password"], user=user)
            except DjangoValidationError:
                return fail("新密码过于简单，请使用至少8位且不易猜测的密码")
            user.set_password(data["new_password"])
            user.save(update_fields=["password", "updated_at"])
        return _clear_refresh_cookie(ok(message="密码已重置，请使用新密码登录"))


class PreflightStatusView(APIView):
    def get(self, request):
        user = request.user
        return ok(
            data={
                "preflight_completed_at": user.preflight_completed_at.isoformat() if user.preflight_completed_at else "",
            }
        )


class PreflightCompleteView(APIView):
    def post(self, request):
        user = request.user
        user.preflight_completed_at = timezone.now()
        user.save(update_fields=["preflight_completed_at"])
        return ok(
            message="校准完成",
            data={
                "preflight_completed_at": user.preflight_completed_at.isoformat() if user.preflight_completed_at else "",
            },
        )


class AdminSettingsView(APIView):
    """管理员设置：GET 允许匿名读取开放注册状态（注册页需展示提示）；
    仅带 is_admin 标志的账号可写，POST 修改开放注册开关"""

    permission_classes = [AllowAny]

    def _is_admin(self, request) -> bool:
        return bool(getattr(request.user, "is_admin", False))

    def get(self, request):
        is_admin = self._is_admin(request)
        return ok(
            data={
                "is_admin": is_admin,
                # 开关状态对所有人可见，供注册页展示“暂未开放注册”提示
                "open_registration": SystemSetting.is_open_registration(),
            }
        )

    def post(self, request):
        if not self._is_admin(request):
            return fail("无权操作", code=403, status=403)
        payload = request_data_mapping(request)
        if payload is None:
            return fail("请求参数必须是对象")
        enabled = payload.get("open_registration")
        if not isinstance(enabled, bool):
            return fail("open_registration 必须是布尔值")
        SystemSetting.set_open_registration(enabled)
        return ok(
            message="开放注册已开启" if enabled else "开放注册已关闭",
            data={"is_admin": True, "open_registration": enabled},
        )
