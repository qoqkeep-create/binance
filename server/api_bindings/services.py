import hashlib
import logging
from datetime import datetime, timedelta
from typing import Optional

from django.conf import settings
from django.db import IntegrityError, transaction
from django.db.models import Q
from django.utils import timezone

from api_bindings.context import TradingAccountContext, build_trading_account_identity
from api_bindings.exceptions import ApiBindingConflictError
from api_bindings.models import ApiBinding
from common.binance import BinanceApiError, BinanceCredentials
from common.utils import aes_decrypt_with_metadata, aes_encrypt
from common.trading_mode import TradingMode, normalize_trading_mode


logger = logging.getLogger(__name__)
AUTH_FAILURE_CODES = frozenset({"-1022", "-2014", "-2015", "50110", "50113", "50119"})
DUPLICATE_API_KEY_REASON = "检测到同一 Binance API Key 重复绑定，请解绑后使用唯一 API Key 重新绑定"


def is_deterministic_auth_error(error: Optional[Exception]) -> bool:
    return isinstance(error, BinanceApiError) and str(error.code or "").strip() in AUTH_FAILURE_CODES


def _auth_failure_reason(error: BinanceApiError) -> str:
    code = str(error.code or "").strip()
    if code in {"-1022", "50113", "50119"}:
        return "Binance API 签名校验持续失败，请重新检查 Secret Key"
    if code in {"-2014", "50110"}:
        return "Binance API Key 格式或状态持续无效，请重新绑定"
    return "Binance API 权限、密钥或 IP 白名单持续校验失败，请重新检查绑定"


def record_binding_exchange_result(binding_id: int, error: Optional[Exception]) -> bool:
    """Return True only when this result transitions the binding to disabled."""
    if error is not None and not is_deterministic_auth_error(error):
        return False

    with transaction.atomic():
        binding = ApiBinding.objects.select_for_update().filter(pk=binding_id).first()
        if not binding:
            return False
        if error is None:
            if binding.consecutive_auth_failures or binding.last_auth_failure_at or binding.status_reason:
                binding.consecutive_auth_failures = 0
                binding.last_auth_failure_at = None
                if binding.status == 1:
                    binding.status_reason = ""
                binding.save(
                    update_fields=[
                        "consecutive_auth_failures",
                        "last_auth_failure_at",
                        "status_reason",
                        "updated_at",
                    ]
                )
            return False

        now = timezone.now()
        window_seconds = max(int(getattr(settings, "BINANCE_AUTH_FAILURE_WINDOW_SECONDS", 21600)), 60)
        within_window = bool(
            binding.last_auth_failure_at
            and now - binding.last_auth_failure_at <= timedelta(seconds=window_seconds)
        )
        binding.consecutive_auth_failures = (
            binding.consecutive_auth_failures + 1 if within_window else 1
        )
        binding.last_auth_failure_at = now
        threshold = max(int(getattr(settings, "BINANCE_AUTH_FAILURE_THRESHOLD", 3)), 1)
        disabled = binding.status == 1 and binding.consecutive_auth_failures >= threshold
        update_fields = ["consecutive_auth_failures", "last_auth_failure_at", "updated_at"]
        if disabled:
            binding.status = 0
            binding.status_reason = _auth_failure_reason(error)
            update_fields.extend(["status", "status_reason"])
        binding.save(update_fields=update_fields)

    if disabled:
        logger.error(
            "binance_binding_disabled binding_id=%s user_id=%s auth_failure_count=%s code=%s",
            binding.id,
            binding.user_id,
            binding.consecutive_auth_failures,
            str(error.code or ""),
        )
    return disabled


def apply_manual_validation_result(binding: ApiBinding, error: Optional[Exception]) -> int:
    """Apply an explicit API-info validation without treating transient outages as invalid credentials."""
    if binding.status_reason == DUPLICATE_API_KEY_REASON:
        return 0
    if error is not None and not is_deterministic_auth_error(error):
        return int(binding.status)
    if error is None:
        ApiBinding.objects.filter(pk=binding.pk).update(
            status=1,
            consecutive_auth_failures=0,
            last_auth_failure_at=None,
            status_reason="",
            updated_at=timezone.now(),
        )
        return 1
    ApiBinding.objects.filter(pk=binding.pk).update(
        status=0,
        status_reason=_auth_failure_reason(error),
        updated_at=timezone.now(),
    )
    return 0


class BindingHealthObserver:
    def __init__(self, binding: ApiBinding):
        self.binding_id = int(binding.id)
        self.has_failures = bool(binding.consecutive_auth_failures)

    def __call__(self, error: Optional[Exception]) -> None:
        if error is None and not self.has_failures:
            return
        if error is not None and not is_deterministic_auth_error(error):
            return
        record_binding_exchange_result(self.binding_id, error)
        self.has_failures = error is not None


def get_user_binding(user, *, active_only: bool = False, trading_mode=TradingMode.ORDINARY) -> Optional[ApiBinding]:
    queryset = ApiBinding.objects.filter(user=user, trading_mode=normalize_trading_mode(trading_mode))
    if active_only:
        queryset = queryset.filter(status=1)
    return queryset.first()


def decrypt_binding_fields(binding: ApiBinding, *field_names: str) -> dict[str, str]:
    values: dict[str, str] = {}
    legacy_values: dict[str, str] = {}
    originals: dict[str, str] = {}
    for field_name in field_names:
        encrypted = str(getattr(binding, field_name) or "")
        plaintext, is_legacy = aes_decrypt_with_metadata(encrypted)
        values[field_name] = plaintext
        if is_legacy:
            originals[field_name] = encrypted
            legacy_values[field_name] = aes_encrypt(plaintext)

    if legacy_values:
        filters = {field_name: originals[field_name] for field_name in legacy_values}
        ApiBinding.objects.filter(pk=binding.pk, **filters).update(
            **legacy_values,
            updated_at=timezone.now(),
        )
        for field_name, encrypted in legacy_values.items():
            setattr(binding, field_name, encrypted)
    return values


def get_binding_binance_credentials(binding: ApiBinding) -> BinanceCredentials:
    values = decrypt_binding_fields(binding, "api_key", "secret_key", "passphrase")
    return BinanceCredentials(
        api_key=values["api_key"],
        secret_key=values["secret_key"],
        passphrase=values["passphrase"],
        result_observer=BindingHealthObserver(binding),
        trading_mode=binding.trading_mode,
    )


def get_binding_api_key_fingerprint(
    binding: ApiBinding,
    *,
    decrypted_api_key: str = "",
) -> str:
    """Resolve and lazily persist the stable fingerprint for a legacy binding."""
    stored = str(binding.api_key_fingerprint or "").strip().lower()
    if stored:
        return stored
    api_key = decrypted_api_key
    if not api_key:
        api_key = decrypt_binding_fields(binding, "api_key")["api_key"]
    fingerprint = build_api_key_fingerprint(api_key)
    if not fingerprint:
        return ""
    try:
        with transaction.atomic():
            updated = ApiBinding.objects.filter(pk=binding.pk).filter(
                Q(api_key_fingerprint="") | Q(api_key_fingerprint__isnull=True)
            ).update(api_key_fingerprint=fingerprint)
    except IntegrityError as exc:
        ApiBinding.objects.filter(pk=binding.pk).update(
            status=0,
            status_reason=DUPLICATE_API_KEY_REASON,
            updated_at=timezone.now(),
        )
        binding.status = 0
        binding.status_reason = DUPLICATE_API_KEY_REASON
        logger.error(
            "duplicate legacy api key binding disabled binding_id=%s user_id=%s fingerprint=%s",
            binding.id,
            binding.user_id,
            fingerprint[:12],
        )
        raise ApiBindingConflictError(DUPLICATE_API_KEY_REASON) from exc
    if updated:
        binding.api_key_fingerprint = fingerprint
        return fingerprint
    return str(
        ApiBinding.objects.filter(pk=binding.pk).values_list("api_key_fingerprint", flat=True).first()
        or fingerprint
    ).strip().lower()


def get_user_binding_generation(user, *, trading_mode=TradingMode.ORDINARY) -> tuple[str, Optional[datetime]]:
    """Return the current key fingerprint and its immutable creation boundary."""
    binding = get_user_binding(user, trading_mode=trading_mode)
    if not binding:
        return "", None
    try:
        fingerprint = get_binding_api_key_fingerprint(binding)
    except ApiBindingConflictError:
        raise
    except Exception:  # Credential reads fail closed later when a client is requested.
        fingerprint = ""
    return fingerprint, binding.created_at


def scope_queryset_to_trading_account(
    queryset,
    *,
    api_key_fingerprint: str,
    binding_created_at=None,
    trading_mode=None,
):
    """Scope fingerprinted and legacy records to one immutable binding generation."""
    fingerprint = str(api_key_fingerprint or "").strip().lower()
    if trading_mode is not None:
        queryset = queryset.filter(trading_mode=normalize_trading_mode(trading_mode))
    if not fingerprint and binding_created_at is None:
        return queryset

    scope = Q(api_key_fingerprint=fingerprint) if fingerprint else Q(pk__in=[])
    if binding_created_at is not None:
        legacy = Q(api_key_fingerprint__isnull=True) | Q(api_key_fingerprint="")
        scope |= legacy & Q(created_at__gte=binding_created_at)
    return queryset.filter(scope)


def get_user_trading_account(user, *, active_only: bool = False, trading_mode=TradingMode.ORDINARY) -> Optional[TradingAccountContext]:
    binding = get_user_binding(user, active_only=active_only, trading_mode=trading_mode)
    if not binding:
        return None
    credentials = get_binding_binance_credentials(binding)
    fingerprint = get_binding_api_key_fingerprint(
        binding,
        decrypted_api_key=credentials.api_key,
    )
    return TradingAccountContext(
        user_id=int(user.id),
        binding_id=int(binding.id),
        api_key_fingerprint=fingerprint,
        alias=str(binding.alias or ""),
        binding_created_at=binding.created_at,
        credentials=credentials,
        trading_mode=binding.trading_mode,
    )


def get_user_binance_credentials(user, *, trading_mode=TradingMode.ORDINARY) -> Optional[BinanceCredentials]:
    account = get_user_trading_account(user, active_only=True, trading_mode=trading_mode)
    return account.credentials if account else None


def get_user_binance_credentials_for_generation(
    user,
    *,
    api_key_fingerprint: str,
    binding_created_at: Optional[datetime],
    trading_mode=TradingMode.ORDINARY,
) -> Optional[BinanceCredentials]:
    """Load credentials only if the current binding is still the expected generation."""
    if binding_created_at is None:
        # Compatibility for tests and pre-fingerprint installations without a binding row.
        return get_user_binance_credentials(user, trading_mode=trading_mode)
    binding = get_user_binding(user, active_only=True, trading_mode=trading_mode)
    if not binding or binding.created_at != binding_created_at:
        return None
    try:
        fingerprint = get_binding_api_key_fingerprint(binding)
    except ApiBindingConflictError:
        raise
    except Exception:
        return None
    if fingerprint != str(api_key_fingerprint or "").strip().lower():
        return None
    return get_binding_binance_credentials(binding)


def build_api_key_fingerprint(api_key: str) -> str:
    text = str(api_key or "").strip()
    if not text:
        return ""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def get_user_api_key_fingerprint(user, *, trading_mode=TradingMode.ORDINARY) -> str:
    binding = get_user_binding(user, trading_mode=trading_mode)
    if not binding:
        return ""
    try:
        return get_binding_api_key_fingerprint(binding)
    except ApiBindingConflictError:
        raise
    except Exception:
        return ""


def get_user_trading_account_identity(user, *, trading_mode=TradingMode.ORDINARY) -> str:
    """Resolve the stable, non-secret identity shared by exchange mutation locks."""
    binding = get_user_binding(user, trading_mode=trading_mode)
    fingerprint = ""
    if binding:
        try:
            fingerprint = get_binding_api_key_fingerprint(binding)
        except ApiBindingConflictError:
            raise
        except Exception:
            fingerprint = ""
    return build_trading_account_identity(
        user_id=int(user.id),
        binding_id=getattr(binding, "id", None),
        api_key_fingerprint=fingerprint,
        trading_mode=trading_mode,
    )


def find_conflicting_binding(*, user, api_key: str, trading_mode=TradingMode.ORDINARY) -> Optional[ApiBinding]:
    """
    查找是否已有其他用户绑定了同一把 API Key。

    Binance Futures 的 accountAlias 只是账户别名，不是稳定的账户唯一 ID，
    不能用来判断「同一个 Binance 账户」。这里仅用 API Key 指纹判断重复绑定；
    对尚未回填指纹的旧数据，再兜底比对解密后的 api_key。
    """
    existing = ApiBinding.objects.exclude(user=user, trading_mode=trading_mode)
    fingerprint = build_api_key_fingerprint(api_key)
    if fingerprint:
        matched = existing.filter(api_key_fingerprint=fingerprint).first()
        if matched:
            return matched

    legacy = Q(api_key_fingerprint="") | Q(api_key_fingerprint__isnull=True)
    for binding in existing.filter(legacy).iterator():
        try:
            if get_binding_api_key_fingerprint(binding) == fingerprint:
                return binding
        except Exception:
            logger.warning(
                "api_binding_legacy_fingerprint_unreadable binding_id=%s user_id=%s",
                binding.id,
                binding.user_id,
            )
            continue
    return None
