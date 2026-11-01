from __future__ import annotations

import hashlib
import logging
import threading
import time
from dataclasses import dataclass
from enum import Enum
from typing import Any, Mapping
from urllib.parse import urlparse

from django.conf import settings
from django.core.cache import cache

from common.errors import safe_error_summary

logger = logging.getLogger(__name__)


_LOCAL_COUNTER_LOCK = threading.Lock()
_LOCAL_COUNTERS: dict[str, tuple[int, float]] = {}
_CACHE_WARNING_TIMES: dict[str, float] = {}
_LOCAL_COUNTER_MAX_ENTRIES = 4096


class RequestPriority(str, Enum):
    BACKGROUND = "background"
    NORMAL = "normal"
    CRITICAL = "critical"


@dataclass(frozen=True)
class RequestBudgetSpec:
    scope: str
    priority: RequestPriority
    weight: int
    counts_as_order: bool
    account_weight: bool = False


class RequestBudgetExceeded(RuntimeError):
    def __init__(self, *, scope: str, priority: RequestPriority, retry_after: int):
        super().__init__(f"Binance request budget unavailable for {scope}/{priority.value}")
        self.scope = scope
        self.priority = priority
        self.retry_after = max(int(retry_after), 1)


_BACKGROUND_PATH_SUFFIXES = (
    "/allOrders",
    "/userTrades",
    "/income",
    "/capital/deposit/hisrec",
    "/capital/withdraw/history",
    "/pay/transactions",
    "/sub-account/transfer/subUserHistory",
)
_ORDER_PATH_SUFFIXES = ("/order", "/algoOrder", "/allOpenOrders")
_READ_ONLY_POST_PATHS = frozenset({
    "/sapi/v1/asset/get-funding-asset",
})
_EXACT_PATH_WEIGHTS = {
    "/api/v3/account": 20,
    "/fapi/v3/balance": 5,
    "/sapi/v1/pay/transactions": 3000,
}


def _positive_int_setting(name: str, default: int) -> int:
    try:
        value = int(getattr(settings, name, default))
    except (TypeError, ValueError):
        return default
    return value if value > 0 else default


def request_scope(base_url: str, path: str) -> str:
    if str(path or "").startswith("/sapi/"):
        return "sapi"
    hostname = str(urlparse(str(base_url or "")).hostname or "").lower()
    if hostname.startswith("api") or str(path or "").startswith("/api/"):
        return "spot"
    return "futures"


def _estimate_weight(path: str, query: Mapping[str, Any] | None) -> int:
    params = query or {}
    if path in _EXACT_PATH_WEIGHTS:
        return _EXACT_PATH_WEIGHTS[path]
    if path.endswith("/income"):
        return 30
    if path.endswith("/openOrders") and not params.get("symbol"):
        return 40
    if path.endswith("/ticker/24hr") and not params.get("symbol"):
        return 40
    if path.endswith("/positionRisk"):
        return 5
    if path.endswith(("/allOrders", "/userTrades")):
        return 5
    if path.endswith(("/capital/deposit/hisrec", "/capital/withdraw/history")):
        return 10
    if path.endswith(("/klines", "/markPriceKlines", "/continuousKlines")):
        try:
            limit = int(params.get("limit") or 500)
        except (TypeError, ValueError):
            limit = 500
        if limit < 100:
            return 1
        if limit < 500:
            return 2
        if limit <= 1000:
            return 5
        return 10
    return 1


def is_exchange_mutation(method: str, path: str) -> bool:
    """Classify API semantics instead of treating every Binance POST as a write."""
    normalized_method = str(method or "GET").upper()
    if normalized_method not in {"POST", "PUT", "DELETE"}:
        return False
    return str(path or "") not in _READ_ONLY_POST_PATHS


def classify_request(
    *,
    method: str,
    path: str,
    base_url: str,
    query: Mapping[str, Any] | None = None,
    priority: RequestPriority | str | None = None,
) -> RequestBudgetSpec:
    normalized_method = str(method or "GET").upper()
    is_write = is_exchange_mutation(normalized_method, path)
    if priority is None:
        resolved_priority = (
            RequestPriority.CRITICAL
            if is_write
            else RequestPriority.BACKGROUND
            if path.endswith(_BACKGROUND_PATH_SUFFIXES)
            else RequestPriority.NORMAL
        )
    else:
        resolved_priority = RequestPriority(priority)
    return RequestBudgetSpec(
        scope=request_scope(base_url, path),
        priority=resolved_priority,
        weight=_estimate_weight(path, query),
        counts_as_order=is_write and path.endswith(_ORDER_PATH_SUFFIXES),
        account_weight=path == "/sapi/v1/pay/transactions",
    )


def _weight_limit(scope: str) -> int:
    defaults = {"futures": 2400, "spot": 6000, "sapi": 12000}
    names = {
        "futures": "BINANCE_FUTURES_WEIGHT_LIMIT_PER_MINUTE",
        "spot": "BINANCE_SPOT_WEIGHT_LIMIT_PER_MINUTE",
        "sapi": "BINANCE_SAPI_WEIGHT_LIMIT_PER_MINUTE",
    }
    return _positive_int_setting(names.get(scope, names["futures"]), defaults.get(scope, 2400))


def _priority_limit(scope: str, priority: RequestPriority, *, account_weight: bool = False) -> int:
    # Pay uses the independent SAPI UID allowance, not the shared IP allowance.
    hard_limit = 180000 if account_weight else _weight_limit(scope)
    ratios = {
        RequestPriority.BACKGROUND: float(getattr(settings, "BINANCE_BACKGROUND_WEIGHT_RATIO", 0.65)),
        RequestPriority.NORMAL: float(getattr(settings, "BINANCE_NORMAL_WEIGHT_RATIO", 0.85)),
        RequestPriority.CRITICAL: float(getattr(settings, "BINANCE_CRITICAL_WEIGHT_RATIO", 0.96)),
    }
    return max(int(hard_limit * min(max(ratios[priority], 0.1), 1.0)), 1)


def _window_key(kind: str, identity: str, window: int) -> str:
    return f"trade:binance:budget:{kind}:{identity}:{window}"


def _account_weight_identity(scope: str, account_api_key: str) -> str:
    fingerprint = hashlib.sha256(account_api_key.encode("utf-8")).hexdigest()[:24]
    return f"{scope}:pay:uid:{fingerprint}"


def _warn_cache_unavailable(operation: str, exc: Exception) -> None:
    now = time.monotonic()
    with _LOCAL_COUNTER_LOCK:
        last_warning = _CACHE_WARNING_TIMES.get(operation, 0.0)
        if now - last_warning < 60:
            return
        _CACHE_WARNING_TIMES[operation] = now
    logger.warning(
        "binance_budget_cache_unavailable operation=%s err=%s",
        operation,
        safe_error_summary(exc),
    )


def _reserve_local_counter(key: str, amount: int, limit: int, *, timeout: int) -> bool:
    now = time.monotonic()
    with _LOCAL_COUNTER_LOCK:
        if key not in _LOCAL_COUNTERS and len(_LOCAL_COUNTERS) >= _LOCAL_COUNTER_MAX_ENTRIES:
            expired = [stored_key for stored_key, (_, expires_at) in _LOCAL_COUNTERS.items() if expires_at <= now]
            for stored_key in expired:
                _LOCAL_COUNTERS.pop(stored_key, None)
            if len(_LOCAL_COUNTERS) >= _LOCAL_COUNTER_MAX_ENTRIES:
                return False
        current, expires_at = _LOCAL_COUNTERS.get(key, (0, 0.0))
        if expires_at <= now:
            current = 0
            expires_at = now + timeout
        if current + amount > limit:
            return False
        _LOCAL_COUNTERS[key] = (current + amount, expires_at)
        return True


def _release_local_counter(key: str, amount: int) -> None:
    now = time.monotonic()
    with _LOCAL_COUNTER_LOCK:
        current, expires_at = _LOCAL_COUNTERS.get(key, (0, 0.0))
        if current <= amount or expires_at <= now:
            _LOCAL_COUNTERS.pop(key, None)
            return
        _LOCAL_COUNTERS[key] = (current - amount, expires_at)


def _observe_local_counter(key: str, value: int, *, timeout: int) -> None:
    if value <= 0:
        return
    now = time.monotonic()
    with _LOCAL_COUNTER_LOCK:
        if key not in _LOCAL_COUNTERS and len(_LOCAL_COUNTERS) >= _LOCAL_COUNTER_MAX_ENTRIES:
            expired = [stored_key for stored_key, (_, expires_at) in _LOCAL_COUNTERS.items() if expires_at <= now]
            for stored_key in expired:
                _LOCAL_COUNTERS.pop(stored_key, None)
            if len(_LOCAL_COUNTERS) >= _LOCAL_COUNTER_MAX_ENTRIES:
                return
        current, expires_at = _LOCAL_COUNTERS.get(key, (0, 0.0))
        if expires_at <= now:
            current = 0
            expires_at = now + timeout
        _LOCAL_COUNTERS[key] = (max(current, value), expires_at)


def _clear_local_budget_state() -> None:
    """Reset process-local fallback state for isolated tests."""
    with _LOCAL_COUNTER_LOCK:
        _LOCAL_COUNTERS.clear()
        _CACHE_WARNING_TIMES.clear()


def _reserve_counter(key: str, amount: int, limit: int, *, timeout: int) -> str | None:
    if not _reserve_local_counter(key, amount, limit, timeout=timeout):
        return None
    try:
        if cache.add(key, amount, timeout=timeout):
            total = amount
        else:
            total = int(cache.incr(key, amount))
        if total <= limit:
            return "cache"
        try:
            cache.decr(key, amount)
        except Exception:  # noqa: BLE001
            pass
        _release_local_counter(key, amount)
        return None
    except Exception as exc:  # noqa: BLE001
        _warn_cache_unavailable("reserve", exc)
        return "local"


def _release_counter(key: str, amount: int, *, backend: str) -> None:
    _release_local_counter(key, amount)
    if backend == "local":
        return
    try:
        cache.decr(key, amount)
    except Exception as exc:  # noqa: BLE001
        _warn_cache_unavailable("release", exc)


def reserve_request_budget(
    spec: RequestBudgetSpec,
    *,
    account_api_key: str = "",
    now: float | None = None,
    lead_trading: bool = False,
) -> None:
    current_time = float(now if now is not None else time.time())
    minute_window = int(current_time // 60)
    retry_after = 60 - int(current_time % 60)
    uses_account_weight = spec.account_weight and bool(account_api_key)
    weight_identity = (
        _account_weight_identity(spec.scope, account_api_key)
        if uses_account_weight
        else spec.scope
    )
    weight_key = _window_key("weight", weight_identity, minute_window)
    weight_backend = _reserve_counter(
        weight_key,
        spec.weight,
        _priority_limit(spec.scope, spec.priority, account_weight=uses_account_weight),
        timeout=120,
    )
    if weight_backend is None:
        raise RequestBudgetExceeded(
            scope=spec.scope,
            priority=spec.priority,
            retry_after=retry_after,
        )

    if not spec.counts_as_order or not account_api_key:
        return
    account_identity = hashlib.sha256(account_api_key.encode("utf-8")).hexdigest()[:24]
    short_backend = None
    short_key = _window_key("lead-orders", account_identity, int(current_time // 10))
    if lead_trading:
        short_backend = _reserve_counter(
            short_key,
            1,
            18 if spec.priority == RequestPriority.CRITICAL else 14,
            timeout=20,
        )
        if short_backend is None:
            _release_counter(weight_key, spec.weight, backend=weight_backend)
            raise RequestBudgetExceeded(scope="lead-orders", priority=spec.priority,
                                        retry_after=10 - int(current_time % 10))
    order_limit = _positive_int_setting("BINANCE_ORDER_LIMIT_PER_MINUTE", 1200)
    order_ratio = min(max(float(getattr(settings, "BINANCE_ORDER_LIMIT_RATIO", 0.95)), 0.1), 1.0)
    order_backend = _reserve_counter(
        _window_key("orders", account_identity, minute_window),
        1,
        max(int(order_limit * order_ratio), 1),
        timeout=120,
    )
    if order_backend is None:
        _release_counter(weight_key, spec.weight, backend=weight_backend)
        if short_backend is not None:
            _release_counter(short_key, 1, backend=short_backend)
        raise RequestBudgetExceeded(
            scope="orders",
            priority=RequestPriority.CRITICAL,
            retry_after=retry_after,
        )


def _header_int(headers: Mapping[str, Any], prefixes: tuple[str, ...]) -> int:
    result = 0
    for name, raw_value in headers.items():
        normalized_name = str(name).upper()
        if not any(normalized_name.startswith(prefix) for prefix in prefixes):
            continue
        try:
            result = max(result, int(raw_value))
        except (TypeError, ValueError):
            continue
    return result


def _observe_counter(key: str, value: int, *, timeout: int) -> None:
    if value <= 0:
        return
    _observe_local_counter(key, value, timeout=timeout)
    try:
        if cache.add(key, value, timeout=timeout):
            return
        current = int(cache.get(key) or 0)
        delta = value - current
        if delta > 0:
            # Atomic increments make the observation monotonic across workers. A
            # rare race can overestimate usage, which is safer than lowering it.
            cache.incr(key, delta)
    except Exception as exc:  # noqa: BLE001
        _warn_cache_unavailable("observe", exc)


def observe_response_headers(
    headers: Mapping[str, Any] | None,
    *,
    scope: str,
    account_api_key: str = "",
    now: float | None = None,
    lead_trading: bool = False,
    account_weight: bool = False,
) -> tuple[int, int]:
    normalized_headers = dict(headers or {})
    current_time = float(now if now is not None else time.time())
    minute_window = int(current_time // 60)
    used_weight = _header_int(
        normalized_headers,
        ("X-MBX-USED-WEIGHT", "X-SAPI-USED-IP-WEIGHT"),
    )
    order_count = _header_int(normalized_headers, ("X-MBX-ORDER-COUNT",))
    _observe_counter(_window_key("weight", scope, minute_window), used_weight, timeout=120)
    uid_weight = (
        _header_int(normalized_headers, ("X-SAPI-USED-UID-WEIGHT",))
        if account_weight else 0
    )
    if account_api_key and uid_weight > 0:
        _observe_counter(
            _window_key("weight", _account_weight_identity(scope, account_api_key), minute_window),
            uid_weight,
            timeout=120,
        )
    if account_api_key and order_count > 0:
        account_identity = hashlib.sha256(account_api_key.encode("utf-8")).hexdigest()[:24]
        _observe_counter(
            _window_key("orders", account_identity, minute_window),
            order_count,
            timeout=120,
        )
        if lead_trading:
            _observe_counter(
                _window_key("lead-orders", account_identity, int(current_time // 10)),
                _header_int(normalized_headers, ("X-MBX-ORDER-COUNT-10S",)),
                timeout=20,
            )
    return max(used_weight, uid_weight), order_count
