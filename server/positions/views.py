from common.trading_mode import TradingMode, request_trading_mode
from decimal import Decimal
from typing import Any, Optional
from datetime import datetime, timedelta, timezone as dt_timezone
import hashlib
import logging
import time

from django.core.cache import cache
from django.db import transaction
from django.db.models import Exists, F, OuterRef, Q, Window
from django.db.models.functions import Coalesce, RowNumber
from django.utils import timezone
from rest_framework.views import APIView

from api_bindings.services import (
    get_binding_api_key_fingerprint,
    get_user_binding,
    get_user_binding_generation,
    get_user_binance_credentials,
    get_user_binance_credentials_for_generation,
    get_user_api_key_fingerprint,
    get_user_trading_account,
    scope_queryset_to_trading_account,
)
from api_bindings.context import build_trading_account_identity, record_belongs_to_trading_account
from api_bindings.models import ApiBinding
from common.binance import (
    ALGO_VISIBILITY_ALLOW_DELAYED,
    ALGO_VISIBILITY_REQUIRE_VISIBLE,
    BinanceAlgoClient,
    BinanceApiError,
    BinanceFuturesClient,
    binance_get_cached_last_prices,
    binance_get_ticker,
    binance_get_instruments,
    is_binance_rate_limit_error,
    to_inst_id,
    to_symbol,
)
from common.binance_rate_limit import RequestPriority
from common.errors import safe_error_summary
from common.response import fail, ok
from common.request import request_data_mapping
from positions.cleanup import (
    best_effort_cleanup_closed_order_exchange_artifacts,
    cleanup_closed_order_exchange_artifacts,
    persist_closed_order_cleanup_result,
)
from positions.lifecycle import (
    fetch_close_anchor,
    fetch_order_trade_rows,
    persist_confirmed_close_transition,
    summarize_order_close_trades,
)
from positions.notifications import infer_exchange_close_notification
from positions.operation_logs import record_operation
from positions.models import (
    LimitOrder,
    Order,
    OrderStrategyLog,
    OrderStrategySnapshot,
    TradeNotificationEvent,
)
from positions.projection import project_position_financials, project_trigger_pnl
from trading.models import Strategy
from trading.account_cache import invalidate_position_caches, position_cache_key
from trading.services import (
    setup_strategy_take_profit_orders,
    _find_position_row,
    _load_pos_mode,
    _move_stop_loss,
    _resolve_pos_side_from_mode,
    load_shared_exchange_positions,
    load_shared_open_algo_rows,
)
from trading.locks import serialized_exchange_mutation, user_trading_activity_lock

logger = logging.getLogger(__name__)
TOTAL_FEE_RATE = Decimal("0.001")
POSITION_SIZE_TOLERANCE = Decimal("0.00000001")
HISTORY_DEFAULT_PAGE_SIZE = 20
HISTORY_MAX_PAGE_SIZE = 100
HISTORY_CLOSED_RECONCILIATION_BUDGET = 2
BINANCE_PRIVATE_HISTORY_RETENTION_DAYS = 89
SETTLEMENT_BILL_WINDOW_MS = 10 * 60 * 1000
POSITION_EXCHANGE_CACHE_TTL_SECONDS = 10
EXTERNAL_HISTORY_CACHE_TTL_SECONDS = 30
EXTERNAL_HISTORY_FETCH_LIMIT = 40
EXTERNAL_HISTORY_MATCH_WINDOW_SECONDS = 15 * 60
AUTO_CLOSE_MIN_ORDER_AGE_SECONDS = 20
AUTO_CLOSE_CONFIRMATION_GAP_SECONDS = 3
AUTO_CLOSE_CANDIDATE_TTL_SECONDS = 180
SUSPICIOUS_CLOSE_LOOKBACK_HOURS = 24
SUSPICIOUS_CLOSE_GRACE_SECONDS = 120
SUSPICIOUS_CLOSE_ALERT_TTL_SECONDS = 6 * 60 * 60
SUSPICIOUS_CLOSE_TRADE_WINDOW_BEFORE_SECONDS = 120
SUSPICIOUS_CLOSE_TRADE_WINDOW_AFTER_SECONDS = 180
CLOSED_ORDER_CLEANUP_LOOKBACK_HOURS = 72
MANUAL_CLOSE_CONFIRM_DELAYS_SECONDS = (0.0, 0.25, 0.75, 1.5)
TECHNICAL_FAILURE_HINTS = (
    "timeout", "timed out", "network", "connection", "temporarily", "temporary",
    "unavailable", "failed to establish", "connection reset", "dns", "name resolution",
    "incorrect json data format", "50002", "internal server error", "system busy", "try again later",
)
TECHNICAL_BEHAVIOR_HINTS = ("候选价无效", "预挂止盈单成功", "重建止损失败")


def _perf_ms(start: float) -> int:
    return int((time.perf_counter() - start) * 1000)


def _to_decimal(value) -> Decimal:
    try:
        return Decimal(str(value))
    except Exception:
        return Decimal("0")


def _has_decimal_fields(rows, field: str) -> bool:
    """A reported zero is available data; missing or malformed values are not."""
    if not rows:
        return False
    for row in rows:
        value = row.get(field)
        if value is None or value == "":
            return False
        try:
            if not Decimal(str(value)).is_finite():
                return False
        except Exception:
            return False
    return True


def _parse_positive_int(value, default: int, *, max_value: Optional[int] = None) -> int:
    try:
        parsed = int(str(value))
    except Exception:
        parsed = default
    if parsed <= 0:
        parsed = default
    if max_value is not None:
        parsed = min(parsed, max_value)
    return parsed


def _parse_iso_datetime(raw: Optional[str], *, end_of_day: bool = False):
    text = str(raw or "").strip()
    if not text:
        return None
    try:
        normalized = text.replace("Z", "+00:00")
        if len(normalized) == 10:
            suffix = "T23:59:59.999999+00:00" if end_of_day else "T00:00:00+00:00"
            normalized = f"{normalized}{suffix}"
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        return None
    if timezone.is_naive(parsed):
        return timezone.make_aware(parsed, dt_timezone.utc)
    return parsed.astimezone(dt_timezone.utc)


def _to_timestamp_ms(value) -> int:
    dt = value
    if dt is None:
        return 0
    if timezone.is_naive(dt):
        dt = timezone.make_aware(dt, dt_timezone.utc)
    return int(dt.timestamp() * 1000)


def _auto_close_candidate_cache_key(user_id: int, order_id: int) -> str:
    return f"position:auto-close:candidate:{user_id}:{order_id}"


def _clear_auto_close_candidate(user_id: int, order_id: int) -> None:
    cache.delete(_auto_close_candidate_cache_key(user_id, order_id))


def _account_identity(user_id: int, api_key_fingerprint: str = "", *, trading_mode=TradingMode.ORDINARY) -> str:
    return build_trading_account_identity(
        user_id=user_id,
        api_key_fingerprint=api_key_fingerprint,
        trading_mode=trading_mode,
    )


def _credentials_for_binding_generation(
    user,
    *,
    api_key_fingerprint: str,
    binding_created_at,
    trading_mode=TradingMode.ORDINARY,
):
    """Keep legacy no-binding callers while enforcing real binding generations."""
    if binding_created_at is None:
        return get_user_binance_credentials(user, trading_mode=trading_mode)
    return get_user_binance_credentials_for_generation(
        user,
        api_key_fingerprint=api_key_fingerprint,
        binding_created_at=binding_created_at,
        trading_mode=trading_mode,
    )


def _record_current_account_key(record, generation_cache: dict[tuple[int, str], tuple[str, Any]]):
    user_id = int(record.user_id)
    generation_key = (user_id, record.trading_mode)
    if generation_key not in generation_cache:
        generation_cache[generation_key] = get_user_binding_generation(record.user, trading_mode=record.trading_mode)
    fingerprint, binding_created_at = generation_cache[generation_key]
    if not record_belongs_to_trading_account(
        record_fingerprint=record.api_key_fingerprint,
        record_created_at=record.created_at,
        account_fingerprint=fingerprint,
        binding_created_at=binding_created_at,
        record_mode=record.trading_mode,
        account_mode=record.trading_mode,
    ):
        return None
    return user_id, fingerprint


def _maintenance_eligible_orders(queryset):
    """Exclude absent, disabled and obsolete bindings before the batch LIMIT."""
    bindings = ApiBinding.objects.filter(
        user_id=OuterRef("user_id"), trading_mode=OuterRef("trading_mode"), status=1,
    )
    fingerprinted_binding = bindings.filter(
        api_key_fingerprint=OuterRef("api_key_fingerprint"),
    ).exclude(api_key_fingerprint="").filter(api_key_fingerprint__isnull=False)
    legacy_binding = bindings.filter(created_at__lte=OuterRef("created_at"))
    return queryset.filter(
        Exists(fingerprinted_binding)
        | (
            (Q(api_key_fingerprint__isnull=True) | Q(api_key_fingerprint=""))
            & Q(trading_mode=TradingMode.ORDINARY)
            & Exists(legacy_binding)
        )
    )


def _invalidate_position_list_cache(user, api_key_fingerprint: str = "", *, trading_mode=TradingMode.ORDINARY) -> None:
    user_id = int(getattr(user, "id", user))
    fingerprint = api_key_fingerprint
    if not fingerprint and hasattr(user, "id"):
        fingerprint = get_user_api_key_fingerprint(user, trading_mode=trading_mode)
    invalidate_position_caches(
        _account_identity(user_id, fingerprint, trading_mode=trading_mode),
        legacy_user_id=user_id,
    )


def _confirm_auto_close_candidate(order: Order, *, user_id: int) -> tuple[bool, str]:
    now = timezone.now()
    if order.created_at:
        order_age = (now - order.created_at).total_seconds()
        if order_age < AUTO_CLOSE_MIN_ORDER_AGE_SECONDS:
            return False, "order_too_new"

    key = _auto_close_candidate_cache_key(user_id, order.id)
    first_seen_ts = cache.get(key)
    if first_seen_ts is None:
        cache.set(key, int(now.timestamp()), timeout=AUTO_CLOSE_CANDIDATE_TTL_SECONDS)
        return False, "first_miss"
    try:
        delta = int(now.timestamp()) - int(first_seen_ts)
    except Exception:
        cache.set(key, int(now.timestamp()), timeout=AUTO_CLOSE_CANDIDATE_TTL_SECONDS)
        return False, "candidate_reset"
    if delta < AUTO_CLOSE_CONFIRMATION_GAP_SECONDS:
        return False, "awaiting_confirm"
    return True, "confirmed"


def _sum_decimal_strings(values: list[Decimal]) -> Decimal:
    total = Decimal("0")
    for value in values:
        total += value
    return total


def _fee_cost(value) -> Decimal:
    fee = _to_decimal(value)
    return -abs(fee)


def _normalize_stored_fee(value) -> Decimal:
    fee = _to_decimal(value)
    if fee > 0:
        return -fee
    return fee


def _format_fixed_decimal(value: Decimal, places: str = "0.00000000") -> str:
    return format((value or Decimal("0")).quantize(Decimal(places)), "f")


def _negative_fee(value) -> Decimal:
    fee = _to_decimal(value)
    if fee == 0:
        return Decimal("0")
    return -abs(fee)


def _history_time_range_from_request(request):
    filter_type = request.query_params.get("filter", "all")
    start_time = _parse_iso_datetime(request.query_params.get("start_time"))
    end_time = _parse_iso_datetime(request.query_params.get("end_time"), end_of_day=True)
    if end_time and start_time and end_time < start_time:
        start_time, end_time = end_time, start_time
    if start_time or end_time:
        return start_time, end_time, filter_type

    now = timezone.now()
    if filter_type == "day":
        start_time = now - timedelta(days=1)
    elif filter_type == "three-days":
        start_time = now - timedelta(days=3)
    elif filter_type == "week":
        start_time = now - timedelta(days=7)
    return start_time, end_time, filter_type


def _empty_history_source_flags() -> dict[str, str]:
    return {
        "symbol": "local_order",
        "side": "local_order",
        "open_price": "local_order",
        "close_price": "local_order",
        "size": "local_order",
        "opened_at": "local_order",
        "closed_at": "local_order",
        "position_amount": "local_order",
        "pnl": "local_order",
        "realized_pnl": "local_order",
        "pnl_ratio": "local_order",
        "fee": "local_order",
        "funding_fee": "local_order",
        "leverage": "local_order",
    }


def _derive_local_realized_pnl(order: Order, close_price: Decimal) -> Decimal:
    if close_price <= 0 or not order.open_price or order.size <= 0:
        return Decimal("0")
    price_diff = close_price - order.open_price
    if order.side == 1:
        price_diff = -price_diff
    return price_diff * order.size


def _scoped_order_queryset(user, *, status: Optional[int] = None, trading_mode=TradingMode.ORDINARY):
    queryset = Order.objects.filter(user=user, trading_mode=trading_mode)
    if status is not None:
        queryset = queryset.filter(status=status)

    binding = get_user_binding(user, trading_mode=trading_mode)
    if not binding:
        return queryset
    try:
        api_key_fingerprint = get_binding_api_key_fingerprint(binding)
    except Exception:
        api_key_fingerprint = ""
    return scope_queryset_to_trading_account(
        queryset,
        api_key_fingerprint=api_key_fingerprint,
        binding_created_at=binding.created_at,
        trading_mode=trading_mode,
    )


def _manual_take_profit_pnl(order: Order, target_price: Optional[Decimal], position_scale: Decimal) -> Decimal:
    if not target_price or target_price <= 0 or position_scale <= 0:
        return Decimal("0")
    if order.side == 0:
        return (target_price - order.open_price) * position_scale
    return (order.open_price - target_price) * position_scale


def _take_profit_client_id(
    order: Order,
    kind: str,
    order_type: str,
    target_price: Decimal,
    size: Decimal,
) -> str:
    canonical_price = format(target_price.normalize(), "f")
    canonical_size = format(size.normalize(), "f")
    digest = hashlib.sha256(
        f"{order.id}:{kind}:{order_type}:{canonical_price}:{canonical_size}".encode()
    ).hexdigest()[:16]
    return f"tt{order.id}{kind}{digest}"[:36]


def _validate_take_profit_price(order: Order, target_price: Decimal, reference_price: Decimal) -> None:
    if target_price <= 0:
        raise BinanceApiError("止盈价格不合法")
    reference = reference_price if reference_price > 0 else order.open_price
    if order.side == 0 and target_price <= reference:
        raise BinanceApiError("多单止盈价必须高于参考价")
    if order.side == 1 and target_price >= reference:
        raise BinanceApiError("空单止盈价必须低于参考价")


def _matching_take_profit_algo(order: Order, rows: list[dict[str, Any]], pos_mode: str) -> Optional[dict[str, Any]]:
    inst_id = to_inst_id(order.symbol)
    close_side = "sell" if order.side == 0 else "buy"
    expected_pos_side = "long" if order.side == 0 else "short"
    current_size = abs(order.exchange_size or order.size or Decimal("0"))
    stored_ids = {str(item) for item in (order.strategy_tp_algo_ids or []) if item}
    manual_algo_id = str(order.manual_take_profit_algo_id or "").strip()
    if manual_algo_id:
        stored_ids.add(manual_algo_id)

    candidates: list[dict[str, Any]] = []
    for row in rows:
        algo_id = str((row or {}).get("algoId") or "").strip()
        algo_type = str((row or {}).get("algoType") or "").upper()
        if algo_type not in {"TAKE_PROFIT", "TAKE_PROFIT_MARKET"}:
            continue
        if str((row or {}).get("instId") or "") != inst_id:
            continue
        if str((row or {}).get("state") or "").lower() not in {"", "live"}:
            continue
        if str((row or {}).get("side") or "").lower() != close_side:
            continue
        if pos_mode == "long_short_mode" and str((row or {}).get("posSide") or "").lower() != expected_pos_side:
            continue
        if current_size > 0:
            algo_size = abs(_to_decimal((row or {}).get("sz") or "0"))
            if algo_size > 0 and abs(algo_size - current_size) > POSITION_SIZE_TOLERANCE:
                continue
        if algo_id and algo_id in stored_ids:
            return row
        candidates.append(row)

    if not candidates:
        return None
    candidates.sort(key=lambda item: abs(_to_decimal((item or {}).get("sz") or "0")), reverse=True)
    return candidates[0]


def _matching_stop_algo_price(algo_id: str, rows: list[dict[str, Any]]) -> Decimal:
    target_id = str(algo_id or "").strip()
    if not target_id:
        return Decimal("0")
    for row in rows:
        if str((row or {}).get("algoId") or "").strip() != target_id:
            continue
        return _to_decimal((row or {}).get("slTriggerPx") or "0")
    return Decimal("0")


def _estimated_stop_market_stop_price(order: Order, stop_price: Decimal) -> Decimal:
    return stop_price


def _needs_legacy_settlement_refresh(order: Order) -> bool:
    if order.position_origin == Order.ORIGIN_EXTERNAL:
        return False
    if order.settlement_status != Order.SETTLEMENT_STATUS_SETTLED:
        return False

    lifecycle_end = order.closed_at or order.created_at
    if not lifecycle_end or lifecycle_end < timezone.now() - timedelta(
        days=BINANCE_PRIVATE_HISTORY_RETENTION_DAYS
    ):
        return False

    if (
        order.close_binance_order_id
        and order.exchange_size is not None
        and order.size
        and abs(_to_decimal(order.exchange_size) - abs(_to_decimal(order.size))) > POSITION_SIZE_TOLERANCE
    ):
        return True

    stored_fee = order.realized_fee
    stored_funding = order.realized_funding_fee
    if stored_fee is None and stored_funding is None:
        return True

    if stored_fee is not None and _to_decimal(stored_fee) > 0:
        return True

    normalized_fee = _normalize_stored_fee(stored_fee or Decimal("0"))
    normalized_funding = _to_decimal(stored_funding or Decimal("0"))
    local_realized_pnl = _to_decimal(order.realized_pnl if order.realized_pnl is not None else order.pnl or "0")
    local_total_pnl = _to_decimal(order.pnl or "0")
    if local_total_pnl == local_realized_pnl and (normalized_fee != 0 or normalized_funding != 0):
        return True

    return False


def _history_order_needs_exchange_refresh(order: Order) -> bool:
    if order.position_origin == Order.ORIGIN_EXTERNAL:
        return False
    if order.status == 0 or _needs_legacy_settlement_refresh(order):
        return True
    if order.settlement_status in {Order.SETTLEMENT_STATUS_SETTLED, Order.SETTLEMENT_STATUS_ESTIMATED}:
        return False
    return not order.settlement_next_retry_at or order.settlement_next_retry_at <= timezone.now()


def _external_history_order_needs_refresh(order: Order) -> bool:
    """Whether a closed manual position still lacks exchange settlement facts."""
    if order.position_origin != Order.ORIGIN_EXTERNAL or order.status != 1:
        return False
    return any(
        value is None
        for value in (
            order.close_price,
            order.pnl,
            order.realized_pnl,
            order.realized_fee,
            order.realized_funding_fee,
        )
    )


def _external_history_cache_key(user, trading_mode) -> str:
    try:
        fingerprint = get_user_api_key_fingerprint(user, trading_mode=trading_mode)
    except Exception:
        fingerprint = ""
    digest = hashlib.sha256(str(fingerprint or "").encode()).hexdigest()[:16]
    return f"position:external-history:v1:{getattr(user, 'id', 0)}:{trading_mode}:{digest}"


def _external_history_segment_time(segment: dict[str, Any]):
    try:
        timestamp = int(str(segment.get("uTime") or "0"))
    except (TypeError, ValueError):
        return None
    if timestamp <= 0:
        return None
    return datetime.fromtimestamp(timestamp / 1000, tz=dt_timezone.utc)


def _match_external_history_segment(
    order: Order,
    segments: list[dict[str, Any]],
    used_indexes: set[int],
) -> Optional[dict[str, Any]]:
    if not order.closed_at or not order.open_price or order.open_price <= 0 or order.size <= 0:
        return None
    expected_inst_id = to_inst_id(order.symbol)
    expected_direction = "long" if order.side == 0 else "short"
    candidates: list[tuple[tuple[float, Decimal, Decimal], int, dict[str, Any]]] = []
    for index, segment in enumerate(segments):
        if index in used_indexes or not isinstance(segment, dict):
            continue
        if str(segment.get("instId") or "") != expected_inst_id:
            continue
        if str(segment.get("direction") or "").lower() != expected_direction:
            continue
        closed_at = _external_history_segment_time(segment)
        if closed_at is None:
            continue
        time_delta = abs((closed_at - order.closed_at).total_seconds())
        if time_delta > EXTERNAL_HISTORY_MATCH_WINDOW_SECONDS:
            continue
        open_price = _to_decimal(segment.get("openAvgPx") or "0")
        close_price = _to_decimal(segment.get("closeAvgPx") or "0")
        close_size = abs(_to_decimal(segment.get("closeTotalPos") or "0"))
        if open_price <= 0 or close_price <= 0 or close_size <= 0:
            continue
        price_delta = abs(open_price - order.open_price) / order.open_price
        size_delta = abs(close_size - abs(order.size)) / abs(order.size)
        # The local snapshot is the only reliable identity for a manual order.
        # Require both price and quantity to remain close enough before using a
        # nearby exchange segment; an ambiguous segment stays explicitly unknown.
        if price_delta > Decimal("0.02") or size_delta > Decimal("0.25"):
            continue
        candidates.append(((time_delta, price_delta, size_delta), index, segment))
    if not candidates:
        return None
    candidates.sort(key=lambda item: item[0])
    # Two exchange segments with the same score do not identify one local
    # snapshot. Keep the financials unknown instead of attaching the wrong
    # close to a manual position.
    if len(candidates) > 1 and candidates[0][0] == candidates[1][0]:
        return None
    _score, index, segment = candidates[0]
    used_indexes.add(index)
    return segment


def _apply_external_history_segment(order: Order, segment: dict[str, Any]) -> bool:
    open_price = _to_decimal(segment.get("openAvgPx") or "0")
    close_price = _to_decimal(segment.get("closeAvgPx") or "0")
    close_size = abs(_to_decimal(segment.get("closeTotalPos") or "0"))
    if open_price <= 0 or close_price <= 0 or close_size <= 0:
        return False
    realized_pnl = _to_decimal(segment.get("realizedPnl") or segment.get("pnl") or "0")
    realized_fee = -abs(_to_decimal(segment.get("fee") or "0"))
    funding_fee = _to_decimal(segment.get("fundingFee") or "0")
    pnl = realized_pnl + realized_fee + funding_fee
    base_notional = open_price * close_size
    pnl_ratio = (pnl / base_notional) * Decimal("100") if base_notional > 0 else Decimal("0")
    order.close_price = close_price
    order.position_amount = close_size * close_price
    order.realized_pnl = realized_pnl
    order.realized_fee = realized_fee
    order.realized_funding_fee = funding_fee
    order.pnl = pnl
    order.pnl_ratio = pnl_ratio
    order.settlement_status = Order.SETTLEMENT_STATUS_ESTIMATED
    order.settlement_error = "已从币安成交历史核对；接管前的加仓、减仓可能未完全纳入"
    order.settled_at = timezone.now()
    order.settlement_retry_count = 0
    order.settlement_next_retry_at = None
    order.save(
        update_fields=[
            "close_price",
            "position_amount",
            "realized_pnl",
            "realized_fee",
            "realized_funding_fee",
            "pnl",
            "pnl_ratio",
            "settlement_status",
            "settlement_error",
            "settled_at",
            "settlement_retry_count",
            "settlement_next_retry_at",
        ]
    )
    return True


def _sync_external_closed_history(user, orders: list[Order], *, trading_mode=TradingMode.ORDINARY) -> int:
    """Fill missing manual-close facts from Binance's read-only position history."""
    candidates = [order for order in orders if _external_history_order_needs_refresh(order)]
    if not candidates:
        return 0
    credentials = get_user_binance_credentials(user, trading_mode=trading_mode)
    if not credentials:
        return 0

    cache_key = _external_history_cache_key(user, trading_mode)
    segments = cache.get(cache_key)
    if not isinstance(segments, list):
        try:
            payload = BinanceFuturesClient(credentials).get_positions_history(
                limit=EXTERNAL_HISTORY_FETCH_LIMIT,
            )
            rows = payload.get("data") if isinstance(payload, dict) else None
            segments = [row for row in rows or [] if isinstance(row, dict)]
            cache.set(cache_key, segments, timeout=EXTERNAL_HISTORY_CACHE_TTL_SECONDS)
        except BinanceApiError as exc:
            logger.warning(
                "external position history refresh failed user=%s err=%s",
                getattr(user, "id", None),
                safe_error_summary(exc),
            )
            cache.set(cache_key, [], timeout=10)
            return 0
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "external position history refresh unexpected user=%s err=%s",
                getattr(user, "id", None),
                safe_error_summary(exc),
            )
            cache.set(cache_key, [], timeout=10)
            return 0

    used_indexes: set[int] = set()
    synced = 0
    for order in sorted(candidates, key=lambda item: item.closed_at or timezone.now(), reverse=True):
        segment = _match_external_history_segment(order, segments, used_indexes)
        if segment and _apply_external_history_segment(order, segment):
            synced += 1
    return synced


def _load_history_exchange_rows(user, orders: list[Order], *, trading_mode=TradingMode.ORDINARY) -> dict[str, Any]:
    orders = [order for order in orders if order.position_origin != Order.ORIGIN_EXTERNAL]
    if not orders:
        return {
            "rows_by_order_id": {},
            "exchange_available": False,
        }

    credentials = get_user_binance_credentials(user, trading_mode=trading_mode)
    if not credentials:
        return {
            "rows_by_order_id": {},
            "exchange_available": False,
        }
    client = BinanceFuturesClient(credentials)
    rows_by_order_id: dict[int, dict[str, Any]] = {}
    exchange_available = False
    closed_reconciliations = 0

    for order in orders:
        if order.status == 0:
            try:
                rows = _fetch_order_exchange_financial_rows(order, client)
                rows_by_order_id[order.id] = rows
                exchange_available = exchange_available or bool(rows.get("trade_rows"))
            except BinanceApiError as exc:
                logger.warning(
                    "position_history open order exchange supplement failed user=%s order=%s err=%s",
                    getattr(user, "id", None),
                    order.id,
                    safe_error_summary(exc),
                )
                rows_by_order_id[order.id] = {
                    "trade_rows": [],
                    "bill_rows": [],
                }
                if is_binance_rate_limit_error(exc):
                    break
            continue

        refresh_settled_legacy = _needs_legacy_settlement_refresh(order)
        if not _history_order_needs_exchange_refresh(order):
            continue
        if closed_reconciliations >= HISTORY_CLOSED_RECONCILIATION_BUDGET:
            continue
        closed_reconciliations += 1
        try:
            rows = _fetch_order_exchange_financial_rows(order, client)
            reconciled = _reconcile_order_settlement(
                order=order,
                client=client,
                close_price=order.close_price or order.open_price,
                exchange_rows=rows,
                mark_failed=not refresh_settled_legacy,
            )
            if reconciled:
                rows_by_order_id[order.id] = rows
                order.refresh_from_db(
                    fields=[
                        "close_price",
                        "position_amount",
                        "realized_pnl",
                        "realized_fee",
                        "realized_funding_fee",
                        "pnl",
                        "pnl_ratio",
                        "settlement_status",
                        "settled_at",
                        "settlement_error",
                    ]
                )
                exchange_available = True
                continue
            if not refresh_settled_legacy:
                rows_by_order_id[order.id] = rows
                exchange_available = exchange_available or bool(rows_by_order_id[order.id].get("trade_rows"))
        except BinanceApiError as exc:
            logger.warning(
                "position_history exchange supplement failed user=%s order=%s err=%s",
                getattr(user, "id", None),
                order.id,
                safe_error_summary(exc),
            )
            if not refresh_settled_legacy:
                rows_by_order_id[order.id] = {
                    "trade_rows": [],
                    "bill_rows": [],
                }
            if is_binance_rate_limit_error(exc):
                break

    return {
        "rows_by_order_id": rows_by_order_id,
        "exchange_available": exchange_available,
    }


def _load_history_position_rows(user, orders: list[Order], *, trading_mode=TradingMode.ORDINARY) -> dict[tuple[str, str], dict[str, Any]]:
    if not any(order.status == 0 and order.position_origin != Order.ORIGIN_EXTERNAL for order in orders):
        return {}
    credentials = get_user_binance_credentials(user, trading_mode=trading_mode)
    if not credentials:
        return {}
    try:
        rows = load_shared_exchange_positions(
            BinanceFuturesClient(credentials),
            _account_identity(
                getattr(user, "id", 0),
                get_user_api_key_fingerprint(user, trading_mode=trading_mode),
                trading_mode=trading_mode,
            ),
            retry_label="position_history_load_positions",
        )
    except BinanceApiError as exc:
        logger.warning(
            "position_history current position supplement failed user=%s err=%s",
            getattr(user, "id", None),
            safe_error_summary(exc),
        )
        return {}
    return {
        _position_row_key(row): row
        for row in rows
        if str(row.get("instId") or "")
    }


def _mark_order_settlement_failed(order: Order, message: str) -> None:
    retry_count = int(order.settlement_retry_count or 0) + 1
    next_retry_at = _compute_settlement_next_retry_at(message=message, retry_count=retry_count)
    order.settlement_status = Order.SETTLEMENT_STATUS_FAILED
    order.settlement_error = safe_error_summary(message, include_type=False)
    order.settlement_retry_count = retry_count
    order.settlement_next_retry_at = next_retry_at
    order.save(
        update_fields=[
            "settlement_status",
            "settlement_error",
            "settlement_retry_count",
            "settlement_next_retry_at",
        ]
    )


def _suspicious_close_alert_cache_key(order: Order) -> str:
    closed_ms = _to_timestamp_ms(order.closed_at or order.created_at or timezone.now())
    return f"position:suspicious-close-alert:{order.id}:{closed_ms}"


def _has_nearby_close_trade(order: Order, client: BinanceFuturesClient) -> bool:
    closed_at = order.closed_at or timezone.now()
    start_ms = str(_to_timestamp_ms(closed_at - timedelta(seconds=SUSPICIOUS_CLOSE_TRADE_WINDOW_BEFORE_SECONDS)))
    end_ms = str(
        _to_timestamp_ms(
            min(
                closed_at + timedelta(seconds=SUSPICIOUS_CLOSE_TRADE_WINDOW_AFTER_SECONDS),
                timezone.now(),
            )
        )
    )
    inst_id = to_inst_id(order.symbol)
    close_side = "sell" if order.side == 0 else "buy"
    trade_rows = client.get_user_trades(
        inst_id=inst_id,
        limit=200,
        start_time=start_ms,
        end_time=end_ms,
    ).get("data") or []
    close_qty = Decimal("0")
    for row in trade_rows:
        if str(row.get("side") or "").lower() != close_side:
            continue
        row_qty = abs(_to_decimal(row.get("fillSz") or "0"))
        if row_qty <= 0:
            continue
        close_qty += row_qty
    return close_qty + POSITION_SIZE_TOLERANCE >= abs(order.size or Decimal("0"))


def audit_suspicious_closed_orders(limit: int = 50) -> int:
    """
    巡检“本地已平仓但缺少交易所平仓锚点”的异常单。
    仅记录高置信日志告警，不直接改动订单状态，避免误修复。
    """
    now = timezone.now()
    lookback_start = now - timedelta(hours=SUSPICIOUS_CLOSE_LOOKBACK_HOURS)
    grace_deadline = now - timedelta(seconds=SUSPICIOUS_CLOSE_GRACE_SECONDS)
    orders = list(
        _maintenance_eligible_orders(Order.objects.filter(
            status=1,
            close_binance_order_id="",
            closed_at__isnull=False,
            closed_at__gte=lookback_start,
            closed_at__lte=grace_deadline,
        ))
        .exclude(position_origin=Order.ORIGIN_EXTERNAL)
        .select_related("user")
        .order_by("-closed_at", "-id")[: max(1, int(limit))]
    )
    if not orders:
        return 0

    client_cache: dict[tuple[int, str], Optional[BinanceFuturesClient]] = {}
    generation_cache: dict[tuple[int, str], tuple[str, Any]] = {}
    alerts = 0
    for order in orders:
        account_key = _record_current_account_key(order, generation_cache)
        if account_key is None:
            continue
        alert_key = _suspicious_close_alert_cache_key(order)
        if cache.get(alert_key):
            continue

        user_id, fingerprint = account_key
        if account_key not in client_cache:
            credentials = _credentials_for_binding_generation(
                order.user,
                api_key_fingerprint=fingerprint,
                binding_created_at=generation_cache[(user_id, order.trading_mode)][1],
                trading_mode=order.trading_mode,
            )
            client_cache[account_key] = BinanceFuturesClient(credentials) if credentials else None
        client = client_cache.get(account_key)
        if client is None:
            continue

        try:
            has_nearby_close_trade = _has_nearby_close_trade(order, client)
        except BinanceApiError as exc:
            logger.warning(
                "suspicious_close_audit exchange failed user=%s order=%s symbol=%s err=%s",
                user_id,
                order.id,
                order.symbol,
                safe_error_summary(exc),
            )
            if is_binance_rate_limit_error(exc):
                break
            continue
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "suspicious_close_audit unexpected error user=%s order=%s symbol=%s err=%s",
                user_id,
                order.id,
                order.symbol,
                safe_error_summary(exc),
            )
            continue

        if has_nearby_close_trade:
            cache.set(alert_key, "1", timeout=SUSPICIOUS_CLOSE_ALERT_TTL_SECONDS)
            continue

        lifetime_seconds = None
        if order.closed_at and order.created_at:
            lifetime_seconds = max(0, int((order.closed_at - order.created_at).total_seconds()))
        logger.error(
            "suspicious_closed_order user=%s order=%s symbol=%s side=%s size=%s created_at=%s closed_at=%s lifetime_seconds=%s close_order_id_missing=1 close_trade_missing=1",
            user_id,
            order.id,
            order.symbol,
            order.side,
            format(order.size or Decimal("0"), "f"),
            order.created_at.isoformat() if order.created_at else None,
            order.closed_at.isoformat() if order.closed_at else None,
            lifetime_seconds,
        )
        cache.set(alert_key, "1", timeout=SUSPICIOUS_CLOSE_ALERT_TTL_SECONDS)
        alerts += 1
    return alerts


def _compute_settlement_next_retry_at(*, message: str, retry_count: int):
    text = str(message or "").lower()
    retry_count = max(1, int(retry_count or 1))
    if "未匹配到本次平仓成交明细" in text:
        delay_seconds = min(30 * (2 ** min(retry_count - 1, 6)), 30 * 60)
    elif _is_retryable_exchange_error(text) or _is_technical_failure_error_text(text):
        delay_seconds = min(45 * (2 ** min(retry_count - 1, 5)), 20 * 60)
    else:
        delay_seconds = min(15 * 60 * (2 ** min(retry_count - 1, 3)), 4 * 60 * 60)
    return timezone.now() + timedelta(seconds=delay_seconds)


# 查不到平仓成交明细时重试到上限后按本地记录终结：成交明细接口只保留约 90 天，
# 无限重试只会反复消耗限频权重（曾累计 98 单各重试 5500+ 次拖垮服务器额度）。
SETTLEMENT_MAX_UNMATCHED_RETRIES = 24


def _settle_order_from_local_records(order: Order) -> None:
    close_price = order.close_price or order.open_price or Decimal("0")
    order.realized_pnl = _derive_local_realized_pnl(order, close_price)
    order.pnl = (order.realized_pnl or Decimal("0")) + _normalize_stored_fee(order.realized_fee)
    base_notional = order.open_price * order.size if order.open_price and order.size else Decimal("0")
    order.pnl_ratio = (order.pnl / base_notional) * Decimal("100") if base_notional > 0 else Decimal("0")
    if close_price > 0:
        order.close_price = close_price
    order.settlement_status = Order.SETTLEMENT_STATUS_ESTIMATED
    order.settled_at = timezone.now()
    order.settlement_error = "未查到交易所平仓明细，已按本地记录估算结算"
    order.settlement_retry_count = 0
    order.settlement_next_retry_at = None
    order.save(
        update_fields=[
            "close_price",
            "realized_pnl",
            "pnl",
            "pnl_ratio",
            "settlement_status",
            "settled_at",
            "settlement_error",
            "settlement_retry_count",
            "settlement_next_retry_at",
        ]
    )
def _has_partial_close_rows(order: Order, exchange_rows: dict[str, Any]) -> bool:
    if order.status != 0:
        return False
    rows = exchange_rows.get("rows_by_order_id", {}).get(order.id) or {}
    return bool(rows.get("trade_rows"))


def _trade_rows_avg_price(trade_rows: list[dict[str, Any]]) -> Decimal:
    total_qty = Decimal("0")
    total_notional = Decimal("0")
    for row in trade_rows:
        qty = abs(_to_decimal(row.get("fillSz") or "0"))
        price = _to_decimal(row.get("fillPx") or row.get("price") or "0")
        if qty <= 0 or price <= 0:
            continue
        total_qty += qty
        total_notional += qty * price
    if total_qty <= 0:
        return Decimal("0")
    return total_notional / total_qty


def _trade_rows_last_time(trade_rows: list[dict[str, Any]]):
    timestamps = [int(str(row.get("time") or "0") or "0") for row in trade_rows]
    timestamps = [ts for ts in timestamps if ts > 0]
    if not timestamps:
        return None
    return datetime.fromtimestamp(max(timestamps) / 1000, tz=dt_timezone.utc)


def _trade_rows_position_amount(trade_rows: list[dict[str, Any]]) -> Decimal:
    total = Decimal("0")
    for row in trade_rows:
        qty = abs(_to_decimal(row.get("fillSz") or "0"))
        price = _to_decimal(row.get("fillPx") or row.get("price") or "0")
        if qty <= 0 or price <= 0:
            continue
        total += qty * price
    return total


def _position_row_key(row: dict[str, Any]) -> tuple[str, str]:
    inst_id = str(row.get("instId") or "")
    pos_side = str(row.get("posSide") or "").lower()
    if pos_side not in {"long", "short"}:
        quantity = _to_decimal(row.get("pos") or "0")
        pos_side = "long" if quantity > 0 else "short" if quantity < 0 else ""
    return inst_id, pos_side


def _fetch_order_exchange_financial_rows(order: Order, client: BinanceFuturesClient) -> dict[str, Any]:
    inst_id = to_inst_id(order.symbol)
    close_base = order.closed_at or timezone.now()
    close_padding = timedelta(hours=6) if order.closed_at else timedelta(minutes=5)
    trade_rows = fetch_order_trade_rows(order, client, end_at=close_base, limit=1000)
    trade_start_ms = str(_to_timestamp_ms((order.created_at or timezone.now()) - timedelta(minutes=5)))
    trade_end_ms = str(_to_timestamp_ms(min(close_base + close_padding, timezone.now())))
    bill_start_ms = trade_start_ms
    bill_end_ms = trade_end_ms
    bill_payload = client.get_bills(begin=bill_start_ms, end=bill_end_ms, limit=1000)
    bill_rows = bill_payload.get("data") if isinstance(bill_payload, dict) else None
    if not isinstance(bill_rows, list):
        bill_rows = []

    lifecycle_summary = summarize_order_close_trades(order, trade_rows)
    matching_trades = lifecycle_summary["rows"]
    opening_trades = lifecycle_summary["opening_rows"]
    entry_order_id = str(order.binance_order_id or "").strip()
    entry_trades = [
        row for row in trade_rows
        if entry_order_id and str(row.get("ordId") or "") == entry_order_id
    ]

    if not matching_trades:
        return {
            "trade_rows": [],
            "entry_trade_rows": entry_trades,
            "opening_trade_rows": opening_trades,
            "bill_rows": [],
            "is_fully_closed": False,
        }

    entry_trade_times = [int(str(row.get("time") or "0") or "0") for row in entry_trades]
    close_trade_times = [int(str(row.get("time") or "0") or "0") for row in matching_trades]
    lifecycle_start = min(entry_trade_times) if entry_trade_times else int(trade_start_ms)
    lifecycle_end_candidates = [*close_trade_times, _to_timestamp_ms(order.closed_at)]
    lifecycle_end_candidates = [value for value in lifecycle_end_candidates if value > 0]
    lifecycle_end = max(lifecycle_end_candidates) if lifecycle_end_candidates else int(trade_end_ms)
    opening_trade_times = [int(str(row.get("time") or "0") or "0") for row in opening_trades]
    fee_trade_times = [*opening_trade_times, *close_trade_times]

    def is_fee_for_this_lifecycle(row_time: int) -> bool:
        return any(abs(row_time - trade_time) <= SETTLEMENT_BILL_WINDOW_MS for trade_time in fee_trade_times)

    matching_bills = [
        row for row in bill_rows
        if inst_id == str(row.get("instId") or "")
        and (
            (
                str(row.get("type") or "") == "COMMISSION"
                and (
                    is_fee_for_this_lifecycle(int(str(row.get("uTime") or "0") or "0"))
                    or (not entry_trades and lifecycle_start <= int(str(row.get("uTime") or "0") or "0") <= lifecycle_end)
                )
            )
            or (
                str(row.get("type") or "") == "FUNDING_FEE"
                and lifecycle_start <= int(str(row.get("uTime") or "0") or "0") <= lifecycle_end
            )
            or (
                str(row.get("type") or "") == "REALIZED_PNL"
                and any(abs(int(str(row.get("uTime") or "0") or "0") - trade_time) <= SETTLEMENT_BILL_WINDOW_MS for trade_time in close_trade_times)
            )
        )
    ]
    return {
        "trade_rows": matching_trades,
        "entry_trade_rows": entry_trades,
        "opening_trade_rows": opening_trades,
        "bill_rows": matching_bills,
        "is_fully_closed": bool(lifecycle_summary["is_fully_closed"]),
    }


def _reconcile_order_settlement(
    *,
    order: Order,
    client: BinanceFuturesClient,
    close_price: Decimal,
    exchange_rows: Optional[dict[str, Any]] = None,
    mark_failed: bool = True,
) -> bool:
    if order.position_origin == Order.ORIGIN_EXTERNAL:
        return False
    exchange_rows = exchange_rows or _fetch_order_exchange_financial_rows(order, client)
    matching_trades = exchange_rows["trade_rows"]
    entry_trades = exchange_rows.get("entry_trade_rows") or []
    opening_trades = exchange_rows.get("opening_trade_rows") or entry_trades
    matching_bills = exchange_rows["bill_rows"]

    if not matching_trades:
        if mark_failed:
            _mark_order_settlement_failed(order, "未匹配到本次平仓成交明细")
        return False
    if not bool(exchange_rows.get("is_fully_closed")):
        if mark_failed:
            _mark_order_settlement_failed(order, "平仓成交数量未完整覆盖本次持仓生命周期")
        return False

    has_trade_realized_pnl = _has_decimal_fields(matching_trades, "realizedPnl")
    has_trade_fee = _has_decimal_fields([*opening_trades, *matching_trades], "fee")
    trade_realized_pnl = _sum_decimal_strings([
        _to_decimal(row["realizedPnl"]) for row in matching_trades
    ]) if has_trade_realized_pnl else Decimal("0")
    trade_fee = _sum_decimal_strings([
        _fee_cost(row["fee"]) for row in [*opening_trades, *matching_trades]
    ]) if has_trade_fee else Decimal("0")
    bill_realized_pnl_rows = [_to_decimal(row.get("pnl") or "0") for row in matching_bills if str(row.get("type") or "") == "REALIZED_PNL"]
    bill_fee_rows = [_fee_cost(row.get("pnl") or "0") for row in matching_bills if str(row.get("type") or "") == "COMMISSION"]
    bill_funding_rows = [_to_decimal(row.get("pnl") or "0") for row in matching_bills if str(row.get("type") or "") == "FUNDING_FEE"]
    has_bill_realized_rows = bool(bill_realized_pnl_rows)
    exact_close_order_id = str(order.close_binance_order_id or "").strip()
    has_exact_trade_match = bool(
        exact_close_order_id
        and any(str(row.get("ordId") or "") == exact_close_order_id for row in matching_trades)
    )
    matched_trade_qty = _sum_decimal_strings([abs(_to_decimal(row.get("fillSz") or "0")) for row in matching_trades])
    has_qty_coverage = matched_trade_qty + POSITION_SIZE_TOLERANCE >= abs(order.size or Decimal("0"))
    settlement_estimates: list[str] = []
    entry_order_id = str(order.binance_order_id or "").strip()
    if entry_order_id and not entry_trades:
        settlement_estimates.append("未匹配开仓成交明细")
    if not exact_close_order_id:
        settlement_estimates.append("缺少精确平仓订单号")
    elif not has_exact_trade_match:
        settlement_estimates.append("未匹配精确平仓订单")
    if exact_close_order_id and any(
        str(row.get("ordId") or "") != exact_close_order_id for row in matching_trades
    ):
        settlement_estimates.append("包含按时间和数量补齐的成交")
    if not has_qty_coverage:
        settlement_estimates.append("成交数量未完整覆盖本地仓位")

    # 成交明细（userTrades）按订单号精确归属本单的手续费与已实现盈亏，
    # 优先采用；账单流水只能按时间窗口匹配，同币种相邻订单的成交间隔小于窗口时，
    # 会把邻单手续费误计入本单（曾导致手续费虚高、净盈利虚低），仅作兜底。
    settled_pnl = trade_realized_pnl if has_trade_realized_pnl else _sum_decimal_strings(bill_realized_pnl_rows)
    if not has_trade_realized_pnl and bill_realized_pnl_rows:
        settlement_estimates.append("已实现盈亏来自时间窗口账单")
    settled_fee = trade_fee if has_trade_fee else _sum_decimal_strings(bill_fee_rows)
    if not has_trade_fee and bill_fee_rows:
        settlement_estimates.append("手续费来自时间窗口账单")
    elif not has_trade_fee:
        settlement_estimates.append("成交明细缺少手续费")
    settled_funding_fee = _sum_decimal_strings(bill_funding_rows) if bill_funding_rows else Decimal("0")
    if bill_funding_rows:
        settlement_estimates.append("资金费来自持仓时间窗口")
    net_settled_pnl = settled_pnl + settled_fee + settled_funding_fee

    if not has_trade_realized_pnl and not has_bill_realized_rows:
        settlement_estimates.append("成交明细缺少已实现盈亏")
        derived_pnl = _derive_local_realized_pnl(order, close_price)
        if derived_pnl != 0:
            settled_pnl = derived_pnl
            net_settled_pnl = settled_pnl + settled_fee + settled_funding_fee
            settlement_estimates.append("已实现盈亏按本地价格推导")
        elif not has_exact_trade_match and not has_qty_coverage:
            if mark_failed:
                _mark_order_settlement_failed(order, "平仓结算数据暂不完整，等待交易所账单入账后重试")
            return False

    base_notional = order.open_price * order.size if order.open_price and order.size else Decimal("0")
    settled_ratio = (net_settled_pnl / base_notional) * Decimal("100") if base_notional > 0 else Decimal("0")
    settled_close_price = _trade_rows_avg_price(matching_trades)
    settled_position_amount = _trade_rows_position_amount(matching_trades)
    if settled_close_price <= 0:
        settled_close_price = close_price

    order.close_price = settled_close_price
    if settled_position_amount > 0:
        order.position_amount = settled_position_amount
    order.realized_pnl = settled_pnl
    order.realized_fee = settled_fee
    order.realized_funding_fee = settled_funding_fee
    order.pnl = net_settled_pnl
    order.pnl_ratio = settled_ratio
    order.settlement_status = (
        Order.SETTLEMENT_STATUS_ESTIMATED
        if settlement_estimates
        else Order.SETTLEMENT_STATUS_SETTLED
    )
    order.settled_at = timezone.now()
    order.settlement_error = "；".join(dict.fromkeys(settlement_estimates))[:500]
    order.settlement_retry_count = 0
    order.settlement_next_retry_at = None
    order.save(
        update_fields=[
            "close_price",
            "position_amount",
            "realized_pnl",
            "realized_fee",
            "realized_funding_fee",
            "pnl",
            "pnl_ratio",
            "settlement_status",
            "settled_at",
            "settlement_error",
            "settlement_retry_count",
            "settlement_next_retry_at",
        ]
    )
    return True


def reconcile_pending_order_settlements(limit: int = 2) -> int:
    now = timezone.now()
    orders = list(
        _maintenance_eligible_orders(Order.objects.filter(
            status=1,
            settlement_status__in=[
                Order.SETTLEMENT_STATUS_PENDING,
                Order.SETTLEMENT_STATUS_FAILED,
            ],
        ))
        .exclude(position_origin=Order.ORIGIN_EXTERNAL)
        .filter(Q(settlement_next_retry_at__isnull=True) | Q(settlement_next_retry_at__lte=now))
        .select_related("user")
        .order_by("-closed_at", "-id")[: max(1, int(limit))]
    )
    if not orders:
        return 0

    client_cache: dict[tuple[int, str], Optional[BinanceFuturesClient]] = {}
    generation_cache: dict[tuple[int, str], tuple[str, Any]] = {}
    repaired = 0
    for order in orders:
        account_key = _record_current_account_key(order, generation_cache)
        if account_key is None:
            continue
        user_id, fingerprint = account_key
        if account_key not in client_cache:
            credentials = _credentials_for_binding_generation(
                order.user,
                api_key_fingerprint=fingerprint,
                binding_created_at=generation_cache[(user_id, order.trading_mode)][1],
                trading_mode=order.trading_mode,
            )
            client_cache[account_key] = BinanceFuturesClient(credentials) if credentials else None
        client = client_cache.get(account_key)
        if client is None:
            continue
        if (
            "未匹配到本次平仓成交明细" in str(order.settlement_error or "")
            and int(order.settlement_retry_count or 0) >= SETTLEMENT_MAX_UNMATCHED_RETRIES
        ):
            try:
                _settle_order_from_local_records(order)
                repaired += 1
            except Exception as exc:  # noqa: BLE001
                _mark_order_settlement_failed(order, f"local settlement fallback failed: {exc}")
            continue
        try:
            if _reconcile_order_settlement(
                order=order,
                client=client,
                close_price=order.close_price or order.open_price,
            ):
                repaired += 1
        except BinanceApiError as exc:
            _mark_order_settlement_failed(order, str(exc))
            if is_binance_rate_limit_error(exc):
                break
        except Exception as exc:  # noqa: BLE001
            _mark_order_settlement_failed(order, f"settlement retry unexpected error: {exc}")
    return repaired


def _sync_entry_fee_for_order(order: Order, client: BinanceFuturesClient) -> bool:
    if order.position_origin == Order.ORIGIN_EXTERNAL:
        return False
    inst_id = to_inst_id(order.symbol)
    start_ms = str(_to_timestamp_ms((order.created_at or timezone.now()) - timedelta(minutes=10)))
    end_base = order.closed_at or timezone.now()
    end_ms = str(_to_timestamp_ms(min(end_base + timedelta(hours=6), timezone.now())))
    payload = client.get_user_trades(inst_id=inst_id, limit=1000, start_time=start_ms, end_time=end_ms)
    rows = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(rows, list):
        rows = []

    entry_order_id = str(order.binance_order_id or "").strip()
    matched_rows = [
        row for row in rows
        if isinstance(row, dict) and entry_order_id and str(row.get("ordId") or "").strip() == entry_order_id
    ]
    if not matched_rows or not _has_decimal_fields(matched_rows, "fee"):
        order.entry_fee_status = Order.ENTRY_FEE_STATUS_PENDING
        order.entry_fee_error = "开仓成交明细缺少手续费" if matched_rows else "暂未查到开仓成交明细"
        order.entry_fee_synced_at = timezone.now()
        order.save(update_fields=["entry_fee_status", "entry_fee_error", "entry_fee_synced_at"])
        return False

    fee = _sum_decimal_strings([_negative_fee(row.get("fee") or "0") for row in matched_rows])
    filled_qty = _sum_decimal_strings([abs(_to_decimal(row.get("fillSz") or "0")) for row in matched_rows])
    expected_qty = abs(_to_decimal(order.exchange_size or order.size or "0"))
    assets = sorted({str(row.get("feeCcy") or "").strip().upper() for row in matched_rows if str(row.get("feeCcy") or "").strip()})
    asset = assets[0] if len(assets) == 1 else ("MIXED" if assets else "")

    if expected_qty > 0 and filled_qty + POSITION_SIZE_TOLERANCE < expected_qty:
        order.entry_realized_fee = fee
        order.entry_fee_asset = asset
        order.entry_fee_status = Order.ENTRY_FEE_STATUS_PENDING
        order.entry_fee_error = f"开仓成交明细未完整，已匹配数量 {format(filled_qty, 'f')} / {format(expected_qty, 'f')}"
        order.entry_fee_synced_at = timezone.now()
        order.save(
            update_fields=[
                "entry_realized_fee",
                "entry_fee_asset",
                "entry_fee_status",
                "entry_fee_error",
                "entry_fee_synced_at",
            ]
        )
        return False

    order.entry_realized_fee = fee
    order.entry_fee_asset = asset
    order.entry_fee_status = Order.ENTRY_FEE_STATUS_CONFIRMED
    order.entry_fee_error = ""
    order.entry_fee_synced_at = timezone.now()
    order.save(
        update_fields=[
            "entry_realized_fee",
            "entry_fee_asset",
            "entry_fee_status",
            "entry_fee_error",
            "entry_fee_synced_at",
        ]
    )
    return True


def sync_pending_entry_fees(limit: int = 5) -> int:
    orders = list(
        _maintenance_eligible_orders(Order.objects.filter(status=0))
        .exclude(position_origin=Order.ORIGIN_EXTERNAL)
        .exclude(entry_fee_status=Order.ENTRY_FEE_STATUS_CONFIRMED)
        .select_related("user")
        .order_by("entry_fee_synced_at", "-created_at", "-id")[: max(1, int(limit))]
    )
    if not orders:
        return 0

    client_cache: dict[tuple[int, str], Optional[BinanceFuturesClient]] = {}
    generation_cache: dict[tuple[int, str], tuple[str, Any]] = {}
    synced = 0
    for order in orders:
        account_key = _record_current_account_key(order, generation_cache)
        if account_key is None:
            continue
        user_id, fingerprint = account_key
        if account_key not in client_cache:
            credentials = _credentials_for_binding_generation(
                order.user,
                api_key_fingerprint=fingerprint,
                binding_created_at=generation_cache[(user_id, order.trading_mode)][1],
                trading_mode=order.trading_mode,
            )
            client_cache[account_key] = BinanceFuturesClient(credentials) if credentials else None
        client = client_cache.get(account_key)
        if client is None:
            continue
        try:
            changed = _sync_entry_fee_for_order(order, client)
            _invalidate_position_list_cache(order.user, order.api_key_fingerprint or "", trading_mode=order.trading_mode)
            if changed:
                synced += 1
        except BinanceApiError as exc:
            order.entry_fee_status = Order.ENTRY_FEE_STATUS_FAILED
            order.entry_fee_error = safe_error_summary(exc, include_type=False)
            order.entry_fee_synced_at = timezone.now()
            order.save(update_fields=["entry_fee_status", "entry_fee_error", "entry_fee_synced_at"])
            _invalidate_position_list_cache(order.user, order.api_key_fingerprint or "", trading_mode=order.trading_mode)
            if is_binance_rate_limit_error(exc):
                break
        except Exception as exc:  # noqa: BLE001
            order.entry_fee_status = Order.ENTRY_FEE_STATUS_FAILED
            order.entry_fee_error = safe_error_summary(exc)
            order.entry_fee_synced_at = timezone.now()
            order.save(update_fields=["entry_fee_status", "entry_fee_error", "entry_fee_synced_at"])
            _invalidate_position_list_cache(order.user, order.api_key_fingerprint or "", trading_mode=order.trading_mode)
    return synced


def _build_order_history_financials(order: Order, exchange_rows: dict[str, Any]) -> dict[str, Any]:
    if order.position_origin == Order.ORIGIN_EXTERNAL:
        # The time of adoption is not the actual opening fill time. Never attach
        # adjacent exchange trades or bills to an unknown manual lifecycle.
        fee = _normalize_stored_fee(order.realized_fee or Decimal("0"))
        funding = order.realized_funding_fee or Decimal("0")
        realized = order.realized_pnl if order.realized_pnl is not None else order.pnl or Decimal("0")
        return {
            "pnl": order.pnl if order.pnl is not None else realized + fee + funding,
            "realized_pnl": realized,
            "fee": fee,
            "funding_fee": funding,
            "source_flags": {
                key: "local_estimated_order" for key in _empty_history_source_flags()
            },
        }
    rows = exchange_rows.get("rows_by_order_id", {}).get(order.id) or {}
    matching_trades = rows.get("trade_rows") or []
    entry_trades = rows.get("entry_trade_rows") or []
    opening_trades = rows.get("opening_trade_rows") or entry_trades
    matching_bills = rows.get("bill_rows") or []

    bill_pnl_rows = [_to_decimal(row.get("pnl") or "0") for row in matching_bills if str(row.get("type") or "") == "REALIZED_PNL"]
    bill_fee_rows = [_fee_cost(row.get("pnl") or "0") for row in matching_bills if str(row.get("type") or "") == "COMMISSION"]
    bill_funding_rows = [_to_decimal(row.get("pnl") or "0") for row in matching_bills if str(row.get("type") or "") == "FUNDING_FEE"]

    local_realized_pnl = order.realized_pnl if order.realized_pnl is not None else (order.pnl or Decimal("0"))
    local_fee = (
        _normalize_stored_fee(order.realized_fee)
        if order.realized_fee is not None
        else _fee_cost(order.estimated_total_fee or Decimal("0"))
    )
    funding_fee = order.realized_funding_fee or Decimal("0")
    expected_total_from_components = local_realized_pnl + local_fee + funding_fee
    local_total_pnl = order.pnl if order.pnl is not None else expected_total_from_components
    if order.settlement_status in {
        Order.SETTLEMENT_STATUS_SETTLED,
        Order.SETTLEMENT_STATUS_ESTIMATED,
    }:
        local_total_pnl = expected_total_from_components
    source_flags = _empty_history_source_flags()

    if order.settlement_status in {
        Order.SETTLEMENT_STATUS_SETTLED,
        Order.SETTLEMENT_STATUS_ESTIMATED,
    } and not (
        bill_pnl_rows or bill_fee_rows or bill_funding_rows or matching_trades
    ):
        source = (
            "local_estimated_order"
            if order.settlement_status == Order.SETTLEMENT_STATUS_ESTIMATED
            else "local_settled_order"
        )
        source_flags["pnl"] = source
        source_flags["realized_pnl"] = source
        source_flags["fee"] = source
        source_flags["funding_fee"] = source
        return {
            "pnl": local_total_pnl,
            "realized_pnl": local_realized_pnl,
            "fee": local_fee,
            "funding_fee": funding_fee,
            "source_flags": source_flags,
        }

    # 与结算同规则：成交明细按订单号精确归属，优先于时间窗口匹配的账单流水，
    # 避免同币种相邻订单的手续费/盈亏互相污染。
    if _has_decimal_fields(matching_trades, "realizedPnl"):
        realized_pnl = _sum_decimal_strings([_to_decimal(row["realizedPnl"]) for row in matching_trades])
        source_flags["pnl"] = "binance_trade"
        source_flags["realized_pnl"] = "binance_trade"
    elif bill_pnl_rows:
        realized_pnl = _sum_decimal_strings(bill_pnl_rows)
        source_flags["pnl"] = "binance_bill"
        source_flags["realized_pnl"] = "binance_bill"
    else:
        realized_pnl = local_realized_pnl

    if _has_decimal_fields([*opening_trades, *matching_trades], "fee"):
        fee = _sum_decimal_strings([_fee_cost(row["fee"]) for row in [*opening_trades, *matching_trades]])
        source_flags["fee"] = "binance_trade"
    elif bill_fee_rows:
        fee = _sum_decimal_strings(bill_fee_rows)
        source_flags["fee"] = "binance_bill"
    else:
        fee = local_fee

    if bill_funding_rows:
        funding_fee = _sum_decimal_strings(bill_funding_rows)
        source_flags["funding_fee"] = "binance_bill"
    else:
        source_flags["funding_fee"] = "local_order"

    total_pnl = realized_pnl + fee + funding_fee
    return {
        "pnl": total_pnl,
        "realized_pnl": realized_pnl,
        "fee": fee,
        "funding_fee": funding_fee,
        "source_flags": source_flags,
    }


def _serialize_history_order(
    order: Order,
    log_order_ids: set[int],
    exchange_rows: dict[str, Any],
    position_rows: Optional[dict[tuple[str, str], dict[str, Any]]] = None,
) -> dict[str, Any]:
    rows = exchange_rows.get("rows_by_order_id", {}).get(order.id) or {}
    matching_trades = rows.get("trade_rows") or []
    is_partial_history = bool(order.status == 0 and matching_trades)
    close_price = order.close_price if order.close_price is not None else order.open_price
    if is_partial_history:
        trade_avg_price = _trade_rows_avg_price(matching_trades)
        if trade_avg_price > 0:
            close_price = trade_avg_price
    position_amount = order.position_amount
    position_amount_source = "local_order"
    if is_partial_history:
        trade_position_amount = _trade_rows_position_amount(matching_trades)
        if trade_position_amount > 0:
            position_amount = trade_position_amount
            position_amount_source = "binance_trade"
    if position_amount is None and close_price is not None:
        position_amount = order.size * close_price
        position_amount_source = "local_order_derived"

    financials = _build_order_history_financials(order, exchange_rows)
    pnl = financials["pnl"]
    realized_pnl = financials["realized_pnl"]
    fee = financials["fee"]
    funding_fee = financials["funding_fee"]
    source_flags = financials["source_flags"]
    source_flags["position_amount"] = position_amount_source
    derived_local_pnl = _derive_local_realized_pnl(order, close_price or Decimal("0"))

    if (
        source_flags["realized_pnl"] == "local_order" and order.realized_pnl is None
        and realized_pnl == 0 and derived_local_pnl != 0
    ):
        realized_pnl = derived_local_pnl
        pnl = realized_pnl + fee + funding_fee
        source_flags["realized_pnl"] = "local_order_derived"
        source_flags["pnl"] = "local_order_derived"

    base_notional = order.open_price * order.size if order.open_price and order.size else Decimal("0")
    if source_flags["pnl"] != "local_order" and base_notional > 0:
        pnl_ratio = (pnl / base_notional) * Decimal("100")
        source_flags["pnl_ratio"] = "derived_from_pnl"
    else:
        pnl_ratio = order.pnl_ratio or Decimal("0")
        if pnl_ratio == 0 and pnl != 0 and base_notional > 0:
            pnl_ratio = (pnl / base_notional) * Decimal("100")
            source_flags["pnl_ratio"] = "derived_from_pnl"

    floating_pnl = None
    if is_partial_history and position_rows:
        pos_side = "long" if order.side == 0 else "short"
        current_position = position_rows.get((to_inst_id(order.symbol), pos_side))
        if current_position:
            floating_pnl = _to_decimal(current_position.get("upl") or "0")

    opened_at = order.created_at
    closed_at = order.closed_at or (_trade_rows_last_time(matching_trades) if is_partial_history else order.created_at)
    result = {
        "id": order.id,
        "position_origin": order.position_origin,
        "symbol": order.symbol,
        "side": order.side,
        "size": format(order.size, "f"),
        "open_price": format(order.open_price, "f"),
        "close_price": format(close_price or Decimal("0"), "f"),
        "pnl": _format_fixed_decimal(pnl),
        "realized_pnl": _format_fixed_decimal(realized_pnl),
        "pnl_ratio": _format_fixed_decimal(pnl_ratio, "0.0000"),
        "position_amount": format(position_amount or Decimal("0"), "f"),
        "leverage": int(order.leverage or 1),
        "fee": _format_fixed_decimal(fee),
        "funding_fee": _format_fixed_decimal(funding_fee),
        "floating_pnl": _format_fixed_decimal(floating_pnl) if floating_pnl is not None else None,
        "is_partial_history": is_partial_history,
        "settlement_status": (
            "estimated"
            if order.position_origin == Order.ORIGIN_EXTERNAL or order.settlement_status == Order.SETTLEMENT_STATUS_ESTIMATED
            else "confirmed"
            if order.settlement_status == Order.SETTLEMENT_STATUS_SETTLED
            else "failed"
            if order.settlement_status == Order.SETTLEMENT_STATUS_FAILED
            else "pending"
        ),
        "settlement_note": (
            "手动仓仅记录接管后的估算结果，历史成交、手续费与资金费可能不完整"
            if order.position_origin == Order.ORIGIN_EXTERNAL
            else order.settlement_error if order.settlement_status == Order.SETTLEMENT_STATUS_ESTIMATED else ""
        ),
        "stop_loss_amount": format(order.stop_loss_amount, "f"),
        "has_strategy_logs": order.id in log_order_ids,
        "opened_at": opened_at.isoformat() if opened_at else None,
        "closed_at": closed_at.isoformat() if closed_at else None,
        "created_at": opened_at.isoformat() if opened_at else None,
        "data_source_flags": source_flags,
    }
    if order.position_origin == Order.ORIGIN_EXTERNAL:
        # An estimated lifecycle can still contain unknown values. Preserve
        # absence instead of displaying an invented zero profit or commission.
        for field, stored in (
            ("pnl", order.pnl),
            ("realized_pnl", order.realized_pnl),
            ("pnl_ratio", order.pnl_ratio),
            ("close_price", order.close_price),
            ("fee", order.realized_fee),
            ("funding_fee", order.realized_funding_fee),
        ):
            if stored is None:
                result[field] = None
    return result


def _can_bind_strategy(order: Order, current_pos: Decimal) -> bool:
    if order.position_origin == Order.ORIGIN_EXTERNAL:
        return False
    if order.status != 0:
        return False
    if current_pos <= 0 or order.size <= 0:
        return False
    if order.strategy_status == Order.STRATEGY_STATUS_RUNNING:
        return False
    if order.strategy_tp_algo_ids or order.manual_take_profit_algo_id:
        return False
    return abs(current_pos - order.size) <= POSITION_SIZE_TOLERANCE


def _rollback_rebind_take_profit_orders(
    order: Order,
    client: BinanceFuturesClient,
    algo_ids: list[str],
) -> None:
    unresolved_ids: list[str] = []
    algo_client = BinanceAlgoClient(client, log=logger)
    inst_id = to_inst_id(order.symbol)
    for algo_id in dict.fromkeys(str(item or "").strip() for item in algo_ids):
        if not algo_id:
            continue
        try:
            algo_client.cancel_algo_confirmed(
                algo_id,
                inst_id,
                action="strategy_rebind_persistence_rollback",
            )
        except Exception as exc:  # noqa: BLE001
            unresolved_ids.append(algo_id)
            logger.warning(
                "strategy_rebind_rollback_unconfirmed user=%s order=%s algo=%s err=%s",
                order.user_id,
                order.id,
                algo_id,
                safe_error_summary(exc),
            )
    Order.objects.filter(id=order.id, status=0).update(
        strategy_status=Order.STRATEGY_STATUS_CANCELLED,
        strategy_tp_algo_ids=unresolved_ids,
    )


def _is_technical_failure_error_text(error: str) -> bool:
    text = str(error or "").lower()
    if not text:
        return False
    return any(h in text for h in TECHNICAL_FAILURE_HINTS)


def _visible_strategy_logs(queryset):
    technical_error = Q()
    for hint in TECHNICAL_FAILURE_HINTS:
        technical_error |= Q(error__icontains=hint)
    technical_behavior = Q()
    for hint in TECHNICAL_BEHAVIOR_HINTS:
        technical_behavior |= Q(behavior_desc__icontains=hint)
    return queryset.exclude(
        Q(result=OrderStrategyLog.RESULT_FAILED) & technical_error,
    ).exclude(technical_behavior)


def _latest_strategy_errors(order_ids: list[int]) -> dict[int, str]:
    """Read one relevant visible log per current snapshot in a single query."""
    summaries = dict.fromkeys(order_ids, "")
    if not order_ids:
        return summaries
    logs = _visible_strategy_logs(OrderStrategyLog.objects.filter(
        order_id__in=order_ids, snapshot_id=F("order__strategy_snapshot_id"),
        snapshot__order_id=F("order_id"), snapshot__user_id=F("order__user_id"),
    )).filter(
        Q(behavior_desc__in=["止损保护已恢复", "止损保护待恢复"])
        | ~Q(error="") | (Q(result=OrderStrategyLog.RESULT_FAILED) & ~Q(behavior_desc="")),
    ).annotate(latest_rank=Window(
        expression=RowNumber(), partition_by=[F("order_id")],
        order_by=[F("created_at").desc(), F("id").desc()],
    )).filter(latest_rank=1).values_list("order_id", "behavior_desc", "error")
    for order_id, desc, error in logs:
        if desc != "止损保护已恢复":
            summaries[order_id] = safe_error_summary(error or desc, include_type=False)
    return summaries


def _dedupe_strategy_logs(logs):
    """Collapse consecutive duplicates while retaining later state changes."""
    previous_key = None
    deduped = []
    for log in logs:
        key = (
            log.behavior_desc or "",
            log.result or "",
            log.error or "",
            str(log.trigger_r) if log.trigger_r is not None else "",
        )
        if key == previous_key:
            continue
        previous_key = key
        deduped.append(log)
    return deduped


def _is_retryable_exchange_error(error_text: str) -> bool:
    # 限频/BAN 错误绝不重试：重试会放大请求量并延长封禁；只重试临时性技术故障
    return _is_technical_failure_error_text(str(error_text or "").lower())


def _load_positions_with_retry(client: BinanceFuturesClient):
    last_exc: BinanceApiError | None = None
    for idx, delay in enumerate((0.0, 0.4, 1.0)):
        if delay > 0:
            time.sleep(delay)
        try:
            payload = client.get_positions("SWAP")
            return payload.get("data") or []
        except BinanceApiError as exc:
            last_exc = exc
            if idx >= 2 or not _is_retryable_exchange_error(str(exc)):
                raise
    if last_exc:
        raise last_exc
    return []


def _load_public_last_price_map(inst_ids: set[str]) -> dict[str, Decimal]:
    """
    Fetch latest prices from the shared public price snapshot (3s cache),
    so position polling does not trigger extra full-market ticker requests.
    Keep price sourcing independent from private account endpoints.
    """
    if not inst_ids:
        return {}
    try:
        snapshot = binance_get_cached_last_prices()
    except Exception:
        snapshot = {}
    result: dict[str, Decimal] = {}
    for inst_id in inst_ids:
        last = _to_decimal(snapshot.get(inst_id) or "0")
        if last > 0:
            result[inst_id] = last
    missing = inst_ids - set(result)
    if not missing:
        return result

    # Fallback to per-symbol public ticker only for symbols absent from the snapshot.
    for inst_id in missing:
        try:
            ticker_rows = binance_get_ticker(inst_id).get("data") or []
            row = ticker_rows[0] if ticker_rows else {}
            last = _to_decimal(row.get("last") or "0")
            if last > 0:
                result[inst_id] = last
        except Exception:
            continue
    return result


def _snapshot_auto_close_anchor(order: Order, client: BinanceFuturesClient) -> Optional[dict[str, Any]]:
    return fetch_close_anchor(order, client, end_at=timezone.now(), limit=200)


def _auto_close_missing_exchange_order(
    order: Order,
    client: BinanceFuturesClient,
    *,
    user_id: int,
    source: str,
) -> bool:
    if order.position_origin == Order.ORIGIN_EXTERNAL:
        return False
    allow_auto_close, reason = _confirm_auto_close_candidate(order, user_id=user_id)
    if not allow_auto_close:
        logger.warning(
            "%s defer_auto_close user=%s symbol=%s order_id=%s reason=%s",
            source,
            user_id,
            order.symbol,
            order.id,
            reason,
        )
        return False

    try:
        anchor = _snapshot_auto_close_anchor(order, client)
    except Exception as exc:  # noqa: BLE001
        if is_binance_rate_limit_error(exc):
            raise
        anchor = None
    if not anchor:
        logger.warning(
            "%s missing_exchange_position_without_trade_evidence user=%s symbol=%s order_id=%s",
            source,
            user_id,
            order.symbol,
            order.id,
        )
        return False
    if not anchor.get("is_fully_closed"):
        logger.warning(
            "%s missing_exchange_position_with_partial_close_evidence user=%s symbol=%s order_id=%s close_qty=%s",
            source,
            user_id,
            order.symbol,
            order.id,
            format(anchor.get("close_qty") or Decimal("0"), "f"),
        )
        return False

    close_notification = infer_exchange_close_notification(
        order,
        client,
        close_price=anchor["close_price"],
        close_order_id=anchor["close_binance_order_id"],
    )
    order.status = 1
    order.closed_at = anchor["closed_at"]
    order.close_price = anchor["close_price"]
    order.close_binance_order_id = anchor["close_binance_order_id"]
    order.settlement_status = Order.SETTLEMENT_STATUS_PENDING
    order.settled_at = None
    order.settlement_error = ""
    order.exchange_size = Decimal("0")
    order.has_manual_addition = False
    if not persist_confirmed_close_transition(
        order,
        notification=close_notification,
        update_fields=[
            "status",
            "closed_at",
            "close_price",
            "close_binance_order_id",
            "settlement_status",
            "settled_at",
            "settlement_error",
            "exchange_size",
            "has_manual_addition",
        ],
    ):
        _clear_auto_close_candidate(user_id, order.id)
        return False

    cleanup_result = best_effort_cleanup_closed_order_exchange_artifacts(
        order,
        client,
        action_prefix=f"{source}_closed_order_cleanup",
    )
    persist_closed_order_cleanup_result(order, cleanup_result)
    _clear_auto_close_candidate(user_id, order.id)
    _invalidate_position_list_cache(order.user, order.api_key_fingerprint or "", trading_mode=order.trading_mode)
    return True


def _auto_close_missing_exchange_order_safely(
    order: Order,
    client: BinanceFuturesClient,
    *,
    account_identity: str,
    pos_mode: str,
    source: str,
) -> bool:
    """Reconfirm a missing position under the account mutation lock before cleanup."""
    if order.position_origin == Order.ORIGIN_EXTERNAL:
        return False
    with user_trading_activity_lock(account_identity) as account_locked:
        if not account_locked:
            return False
        current_order = (
            Order.objects.select_related("user")
            .filter(id=order.id, status=0)
            .first()
        )
        if current_order is None:
            return False
        try:
            payload = client.get_positions(
                "SWAP",
                to_inst_id(current_order.symbol),
                budget_priority=RequestPriority.CRITICAL,
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "%s fresh position confirmation failed user=%s order=%s err=%s",
                source,
                current_order.user_id,
                current_order.id,
                safe_error_summary(exc),
            )
            if is_binance_rate_limit_error(exc):
                raise
            return False
        current_rows = payload.get("data") or []
        if _find_position_row(current_order, current_rows, pos_mode):
            _clear_auto_close_candidate(current_order.user_id, current_order.id)
            return False
        return _auto_close_missing_exchange_order(
            current_order,
            client,
            user_id=current_order.user_id,
            source=source,
        )


def reconcile_stale_open_orders(limit: int = 100) -> int:
    orders = list(
        _maintenance_eligible_orders(Order.objects.filter(status=0))
        .exclude(position_origin=Order.ORIGIN_EXTERNAL)
        .select_related("user")
        .order_by("created_at", "id")[: max(1, int(limit))]
    )
    if not orders:
        return 0

    generation_cache: dict[tuple[int, str], tuple[str, Any]] = {}
    orders_by_account: dict[tuple[int, str], list[Order]] = {}
    for order in orders:
        account_key = _record_current_account_key(order, generation_cache)
        if account_key is None:
            continue
        orders_by_account.setdefault(account_key, []).append(order)

    repaired = 0

    for (user_id, fingerprint), account_orders in orders_by_account.items():
        account_identity = _account_identity(user_id, fingerprint, trading_mode=account_orders[0].trading_mode)
        with user_trading_activity_lock(account_identity) as account_locked:
            if not account_locked:
                logger.info(
                    "stale_open_orders skipped because mutation lock is busy user=%s",
                    user_id,
                )
                continue
            credentials = _credentials_for_binding_generation(
                account_orders[0].user,
                api_key_fingerprint=fingerprint,
                binding_created_at=generation_cache[(user_id, account_orders[0].trading_mode)][1],
                trading_mode=account_orders[0].trading_mode,
            )
            if not credentials:
                continue
            client = BinanceFuturesClient(credentials)
            try:
                positions = load_shared_exchange_positions(
                    client,
                    account_identity,
                    retry_label="stale_open_orders_load_positions",
                )
                pos_mode = _load_pos_mode(client)
            except BinanceApiError as exc:
                logger.warning(
                    "stale_open_orders skip account user=%s err=%s",
                    user_id,
                    safe_error_summary(exc),
                )
                if is_binance_rate_limit_error(exc):
                    break
                continue

            for stale_order in account_orders:
                order = (
                    Order.objects.select_related("user")
                    .filter(id=stale_order.id, status=0)
                    .first()
                )
                if order is None:
                    continue
                if _find_position_row(order, positions, pos_mode):
                    _clear_auto_close_candidate(user_id, order.id)
                    continue
                try:
                    if _auto_close_missing_exchange_order(
                        order,
                        client,
                        user_id=user_id,
                        source="stale_open_orders",
                    ):
                        repaired += 1
                except Exception as exc:  # noqa: BLE001
                    if is_binance_rate_limit_error(exc):
                        logger.warning(
                            "stale_open_orders rate limited user=%s order=%s err=%s",
                            user_id,
                            order.id,
                            safe_error_summary(exc),
                        )
                        return repaired
                    logger.error(
                        "stale_open_orders order failed user=%s order=%s err=%s",
                        user_id,
                        order.id,
                        safe_error_summary(exc),
                    )

    return repaired


def reconcile_closed_order_exchange_artifacts(limit: int = 100) -> int:
    cutoff = timezone.now() - timedelta(hours=CLOSED_ORDER_CLEANUP_LOOKBACK_HOURS)
    candidate_orders = list(
        _maintenance_eligible_orders(Order.objects.filter(status=1, closed_at__gte=cutoff))
        .alias(has_pending_limits=Exists(LimitOrder.objects.filter(
            order_id=OuterRef("id"), user_id=OuterRef("user_id"), status=LimitOrder.STATUS_PENDING,
        )))
        .filter(
            ~Q(binance_stop_order_id="") | ~Q(binance_stop_market_order_id="")
            | ~Q(strategy_tp_algo_ids=[]) | ~Q(manual_take_profit_algo_id="")
            | Q(has_pending_limits=True)
        )
        .exclude(position_origin=Order.ORIGIN_EXTERNAL)
        .select_related("user")
        .order_by("-closed_at", "-id")[: max(1, int(limit))]
    )
    if not candidate_orders:
        return 0

    orders_by_account: dict[tuple[int, str], list[Order]] = {}
    generation_cache: dict[tuple[int, str], tuple[str, Any]] = {}
    for order in candidate_orders:
        account_key = _record_current_account_key(order, generation_cache)
        if account_key is None:
            continue
        orders_by_account.setdefault(account_key, []).append(order)

    repaired = 0
    for (user_id, fingerprint), account_orders in orders_by_account.items():
        account_identity = _account_identity(user_id, fingerprint, trading_mode=account_orders[0].trading_mode)
        with user_trading_activity_lock(account_identity) as account_locked:
            if not account_locked:
                logger.info(
                    "closed_order_cleanup skipped because mutation lock is busy user=%s",
                    user_id,
                )
                continue
            credentials = _credentials_for_binding_generation(
                account_orders[0].user,
                api_key_fingerprint=fingerprint,
                binding_created_at=generation_cache[(user_id, account_orders[0].trading_mode)][1],
                trading_mode=account_orders[0].trading_mode,
            )
            if not credentials:
                continue
            client = BinanceFuturesClient(credentials)

            for stale_order in account_orders:
                order = Order.objects.filter(id=stale_order.id, status=1).first()
                if order is None:
                    continue
                has_pending_linked_limits = LimitOrder.objects.filter(
                    user_id=user_id,
                    order=order,
                    status=LimitOrder.STATUS_PENDING,
                ).exists()
                if not any((
                    order.binance_stop_order_id,
                    order.binance_stop_market_order_id,
                    order.strategy_tp_algo_ids,
                    order.manual_take_profit_algo_id,
                    has_pending_linked_limits,
                )):
                    continue

                try:
                    cleanup_result = cleanup_closed_order_exchange_artifacts(
                        order,
                        client,
                        action_prefix="closed_order_cleanup_reconcile",
                    )
                except Exception as exc:  # noqa: BLE001
                    if is_binance_rate_limit_error(exc):
                        logger.warning(
                            "closed_order_cleanup reconcile rate limited user=%s order=%s err=%s",
                            user_id,
                            order.id,
                            safe_error_summary(exc),
                        )
                        return repaired
                    logger.error(
                        "closed_order_cleanup reconcile failed user=%s order=%s err=%s",
                        user_id,
                        order.id,
                        safe_error_summary(exc),
                    )
                    continue
                update_fields: list[str] = []
                for field_name, next_value in (
                    ("binance_stop_order_id", cleanup_result.stop_order_id),
                    ("binance_stop_market_order_id", cleanup_result.stop_market_order_id),
                    ("strategy_tp_algo_ids", cleanup_result.take_profit_algo_ids),
                    ("manual_take_profit_algo_id", cleanup_result.manual_take_profit_algo_id),
                ):
                    if field_name == "strategy_tp_algo_ids":
                        current_value = list(getattr(order, field_name) or [])
                        normalized_value = list(next_value or [])
                    else:
                        current_value = str(getattr(order, field_name) or "").strip()
                        normalized_value = str(next_value or "").strip()
                    if current_value != normalized_value:
                        setattr(order, field_name, normalized_value)
                        update_fields.append(field_name)
                if "manual_take_profit_algo_id" in update_fields and not order.manual_take_profit_algo_id:
                    order.manual_take_profit_price = None
                    order.manual_take_profit_order_type = ""
                    update_fields.extend(["manual_take_profit_price", "manual_take_profit_order_type"])
                if update_fields:
                    order.save(update_fields=update_fields)
                    repaired += 1

    return repaired


def _exchange_position_row_map(rows: list[dict[str, Any]]) -> dict[tuple[str, str], dict[str, Any]]:
    return {
        _position_row_key(row): row
        for row in rows
        if isinstance(row, dict) and str(row.get("instId") or "")
        and abs(_to_decimal(row.get("pos") or "0")) > POSITION_SIZE_TOLERANCE
    }


def _position_opened_at(order: Order, row: dict[str, Any]):
    """Use the exchange position timestamp for read-time manual projections.

    An external/manual Order is created when the position is discovered, which
    can be several candles after the actual fill.  Binance's positionRisk
    ``updateTime`` is the only timestamp available in this read path and is
    preferable to the adoption time.  Web owned orders retain their durable
    local creation time because that is tied to the entry lifecycle.
    """
    if order.position_origin == Order.ORIGIN_EXTERNAL:
        raw_timestamp = row.get("updateTime")
        try:
            timestamp = int(str(raw_timestamp or "0"))
        except (TypeError, ValueError):
            timestamp = 0
        if timestamp > 0:
            try:
                return datetime.fromtimestamp(timestamp / 1000, tz=dt_timezone.utc)
            except (OverflowError, OSError, ValueError):
                pass
    return order.created_at


def _serialize_open_position(
    *,
    order: Order,
    row: dict[str, Any],
    public_price_map: dict[str, Decimal],
    open_algo_rows: list[dict[str, Any]],
    pos_mode: str,
    snapshot_map: dict[int, OrderStrategySnapshot],
    latest_strategy_error: str = "",
) -> dict[str, Any]:
    inst_id = to_inst_id(order.symbol)
    mark_px = _to_decimal(row.get("markPx") or row.get("last") or order.open_price)
    current_px = public_price_map.get(inst_id) or mark_px
    pos = abs(_to_decimal(row.get("pos") or "0"))
    has_manual_addition = bool(order.size and pos > order.size + POSITION_SIZE_TOLERANCE)
    financials = project_position_financials(
        row=row,
        side=order.side,
        fallback_open_price=order.open_price,
        current_price=current_px,
        stored_leverage=order.leverage,
    )
    estimated_total_fee = order.estimated_total_fee
    if (
        estimated_total_fee is None
        and financials.contract_value > 0
        and order.open_price > 0
        and order.size > 0
    ):
        estimated_total_fee = (
            order.size * order.open_price * financials.contract_value * TOTAL_FEE_RATE
        )
        order.estimated_total_fee = estimated_total_fee
        order.save(update_fields=["estimated_total_fee"])

    stop_price = order.current_stop_price or order.stop_loss_price
    limit_stop_set = bool(str(order.binance_stop_order_id or "").strip())
    market_stop_set = bool(str(order.binance_stop_market_order_id or "").strip())
    limit_stop_price = (
        _matching_stop_algo_price(order.binance_stop_order_id, open_algo_rows)
        if limit_stop_set
        else Decimal("0")
    )
    if limit_stop_set and limit_stop_price <= 0:
        limit_stop_price = stop_price
    market_stop_price = (
        _matching_stop_algo_price(order.binance_stop_market_order_id, open_algo_rows)
        if market_stop_set
        else Decimal("0")
    )
    if market_stop_set and market_stop_price <= 0:
        market_stop_price = _estimated_stop_market_stop_price(order, stop_price)

    position_scale_for_stop = financials.position_scale
    if (
        position_scale_for_stop <= 0
        and financials.position_amount > 0
        and current_px > 0
    ):
        position_scale_for_stop = financials.position_amount / current_px
    stop_loss_pnl = project_trigger_pnl(
        side=order.side,
        average_price=financials.average_price,
        trigger_price=stop_price,
        position_scale=position_scale_for_stop,
    )
    manual_tp_price = order.manual_take_profit_price
    manual_tp_order_type = order.manual_take_profit_order_type or ""
    manual_tp_algo_id = str(order.manual_take_profit_algo_id or "").strip()
    matched_tp = _matching_take_profit_algo(order, open_algo_rows, pos_mode)
    if matched_tp:
        next_algo_id = str(matched_tp.get("algoId") or "").strip()
        next_price = _to_decimal(matched_tp.get("tpTriggerPx") or "0")
        next_order_type = (
            "limit"
            if str(matched_tp.get("algoType") or "").upper() == "TAKE_PROFIT"
            else "market"
        )
        if next_algo_id and next_price > 0:
            manual_tp_algo_id = next_algo_id
            manual_tp_price = next_price
            manual_tp_order_type = next_order_type
            updated_fields: list[str] = []
            for field_name, next_value in (
                ("manual_take_profit_algo_id", next_algo_id),
                ("manual_take_profit_price", next_price),
                ("manual_take_profit_order_type", next_order_type),
            ):
                if getattr(order, field_name) != next_value:
                    setattr(order, field_name, next_value)
                    updated_fields.append(field_name)
            if updated_fields:
                order.save(update_fields=updated_fields)

    snapshot = snapshot_map.get(order.strategy_snapshot_id) if order.strategy_snapshot_id else None
    opened_at = _position_opened_at(order, row)
    return {
        "id": order.id,
        "position_origin": order.position_origin,
        "symbol": order.symbol,
        "side": order.side,
        "size": format(order.size, "f"),
        "exchange_size": format(pos, "f"),
        "has_manual_addition": has_manual_addition,
        "position_amount": format(financials.position_amount, "f"),
        "pnl": format(financials.unrealized_pnl, "f"),
        "pnl_ratio": format(financials.pnl_ratio, "f"),
        "open_price": format(financials.average_price, "f"),
        "initial_stop_price": format(order.initial_stop_price or order.stop_loss_price, "f"),
        "current_price": format(current_px, "f"),
        "stop_loss_price": format(stop_price, "f"),
        "limit_stop_price": (
            format(limit_stop_price, "f") if limit_stop_set and limit_stop_price > 0 else ""
        ),
        "market_stop_price": (
            format(market_stop_price, "f") if market_stop_set and market_stop_price > 0 else ""
        ),
        "stop_protection_status": order.stop_protection_status,
        "stop_protection_error": order.stop_protection_error,
        "limit_stop_set": limit_stop_set,
        "market_stop_set": market_stop_set,
        "stop_loss_pnl": format(stop_loss_pnl, "f"),
        "manual_take_profit_set": bool(manual_tp_algo_id),
        "manual_take_profit_algo_id": manual_tp_algo_id,
        "manual_take_profit_price": format(manual_tp_price, "f") if manual_tp_price else "",
        "manual_take_profit_order_type": manual_tp_order_type,
        "manual_take_profit_pnl": format(
            _manual_take_profit_pnl(order, manual_tp_price, position_scale_for_stop),
            "f",
        ),
        "close_type": "",
        "stop_loss_amount": format(order.stop_loss_amount, "f"),
        "estimated_total_fee": format(estimated_total_fee or Decimal("0"), "f"),
        "entry_realized_fee": (
            _format_fixed_decimal(order.entry_realized_fee)
            if order.entry_realized_fee is not None
            else None
        ),
        "entry_fee_asset": order.entry_fee_asset or "",
        "entry_fee_status": order.entry_fee_status,
        "entry_fee_error": order.entry_fee_error,
        "leverage": str(financials.leverage),
        "strategy_status": order.strategy_status,
        "can_bind_strategy": _can_bind_strategy(order, pos),
        "strategy_snapshot_id": order.strategy_snapshot_id,
        "strategy_name": snapshot.strategy_name if snapshot else "",
        "strategy_config": snapshot.strategy_config if snapshot else None,
        "latest_strategy_error": latest_strategy_error,
        "opened_at": opened_at.isoformat() if opened_at else None,
        "created_at": order.created_at.isoformat() if order.created_at else None,
    }


class PositionListView(APIView):
    def get(self, request):
        total_started = time.perf_counter()
        credentials_started = time.perf_counter()
        credentials = get_user_binance_credentials(request.user, trading_mode=request_trading_mode(request))
        credentials_ms = _perf_ms(credentials_started)
        if not credentials:
            return fail("使用持仓功能需先绑定 Binance Futures 实盘 API，是否立即前往绑定？")

        account_identity = _account_identity(
            request.user.id,
            get_user_api_key_fingerprint(request.user, trading_mode=request_trading_mode(request)),
            trading_mode=request_trading_mode(request),
        )
        list_cache_key = position_cache_key("last_success", account_identity)
        exchange_cache_key = position_cache_key("exchange_rows", account_identity)
        db_started = time.perf_counter()
        orders = list(_scoped_order_queryset(request.user, trading_mode=request_trading_mode(request), status=0).order_by("-created_at"))
        db_ms = _perf_ms(db_started)
        latest_errors = _latest_strategy_errors([order.id for order in orders])
        client = BinanceFuturesClient(credentials)
        exchange_started = time.perf_counter()
        exchange_cache_hit = 0
        exchange_rows_from_cache = False
        rows = cache.get(exchange_cache_key)
        if isinstance(rows, list):
            exchange_cache_hit = 1
            exchange_rows_from_cache = True
        else:
            rows = None
        try:
            if rows is None:
                rows = _load_positions_with_retry(client)
                if isinstance(rows, list):
                    cache.set(exchange_cache_key, rows, timeout=POSITION_EXCHANGE_CACHE_TTL_SECONDS)
            exchange_ms = _perf_ms(exchange_started)
        except BinanceApiError as exc:
            exchange_ms = _perf_ms(exchange_started)
            if isinstance(rows, list):
                exchange_cache_hit = 1
            else:
                rows = cache.get(exchange_cache_key)
                if isinstance(rows, list):
                    exchange_cache_hit = 1
            cached_data = cache.get(list_cache_key)
            if isinstance(rows, list):
                logger.info(
                    "perf position_list user=%s total_ms=%s credentials_ms=%s exchange_ms=%s db_ms=0 assemble_ms=0 rows=%s orders=0 cache_hit=1 exchange_cache_hit=%s exchange_error=%s",
                    getattr(request.user, "id", None),
                    _perf_ms(total_started),
                    credentials_ms,
                    exchange_ms,
                    len(rows),
                    exchange_cache_hit,
                    str(exc),
                )
                # Continue with cached exchange rows and fresh public price.
            elif isinstance(cached_data, list):
                logger.info(
                    "perf position_list user=%s total_ms=%s credentials_ms=%s exchange_ms=%s db_ms=0 assemble_ms=0 rows=%s orders=0 cache_hit=1 exchange_cache_hit=%s exchange_error=%s",
                    getattr(request.user, "id", None),
                    _perf_ms(total_started),
                    credentials_ms,
                    exchange_ms,
                    len(cached_data),
                    exchange_cache_hit,
                    str(exc),
                )
                return ok(data=[
                    {**item, "latest_strategy_error": latest_errors.get(item.get("id"), "")}
                    for item in cached_data
                ])
            else:
                return fail(safe_error_summary(exc, include_type=False))
        if not isinstance(rows, list):
            rows = []

        # A manual Binance position used to stay invisible until the ten
        # second background scan created its local owner. Reuse this fresh
        # read and create only the local projection here; protection and
        # forced-close writes remain in the serialized background reconciler.
        if rows:
            try:
                account = get_user_trading_account(
                    request.user,
                    active_only=True,
                    trading_mode=request_trading_mode(request),
                )
                if account and account.generation == get_user_binding_generation(
                    request.user, trading_mode=request_trading_mode(request)
                ):
                    from trading.external_positions import adopt_external_position_snapshot

                    with user_trading_activity_lock(account.identity) as account_locked:
                        if account_locked:
                            adopt_external_position_snapshot(request.user, account, rows)
            except Exception as exc:  # noqa: BLE001
                # Discovery is an availability improvement. A malformed or
                # racing snapshot must not turn the ordinary position read
                # into a write-like error; the scheduler will retry safely.
                logger.warning(
                    "position_list external discovery user=%s failed: %s",
                    getattr(request.user, "id", None),
                    safe_error_summary(exc),
                )

        db_started = time.perf_counter()
        orders = list(_scoped_order_queryset(request.user, trading_mode=request_trading_mode(request), status=0).order_by("-created_at"))
        db_ms += _perf_ms(db_started)
        latest_errors = _latest_strategy_errors([order.id for order in orders])
        row_map = _exchange_position_row_map(rows)

        # If we only have cached exchange rows and miss local open symbols, do one fresh fetch
        # before running auto-close synchronization to avoid false instant close after new open.
        if exchange_rows_from_cache and orders:
            has_missing_symbol = any(
                (to_inst_id(order.symbol), "long" if order.side == 0 else "short") not in row_map
                for order in orders
            )
            if has_missing_symbol:
                try:
                    fresh_rows = _load_positions_with_retry(client)
                    if isinstance(fresh_rows, list):
                        rows = fresh_rows
                        cache.set(exchange_cache_key, rows, timeout=POSITION_EXCHANGE_CACHE_TTL_SECONDS)
                        exchange_rows_from_cache = False
                        exchange_cache_hit = 0
                        row_map = _exchange_position_row_map(rows)
                except BinanceApiError:
                    # Keep using cached rows, but do not auto-close based on potentially stale cache.
                    pass
        public_price_map = _load_public_last_price_map({to_inst_id(order.symbol) for order in orders})
        snapshot_ids = [o.strategy_snapshot_id for o in orders if o.strategy_snapshot_id]
        snapshot_map: dict[int, OrderStrategySnapshot] = {}
        if snapshot_ids:
            snapshots = OrderStrategySnapshot.objects.filter(id__in=snapshot_ids)
            snapshot_map = {s.id: s for s in snapshots}
        try:
            config_payload = client.get_account_config()
            config_rows = config_payload.get("data") or []
            pos_mode = str((config_rows[0] if config_rows else {}).get("posMode") or "long_short_mode")
        except BinanceApiError:
            pos_mode = "long_short_mode"
        try:
            open_algo_rows = load_shared_open_algo_rows(
                client,
                account_identity,
                {to_inst_id(order.symbol) for order in orders},
                retry_label="position_list_load_open_algo_orders",
            )
        except BinanceApiError:
            open_algo_rows = []
        assemble_started = time.perf_counter()
        result = []
        synced_closed_orders = 0
        for order in orders:
            inst_id = to_inst_id(order.symbol)
            row = row_map.get((inst_id, "long" if order.side == 0 else "short"))
            if row:
                _clear_auto_close_candidate(request.user.id, order.id)
            if not row:
                if order.position_origin == Order.ORIGIN_EXTERNAL:
                    # Manual lifecycles and residual protections are reconciled
                    # by the external-position service, not opening-fill guesses.
                    continue
                if exchange_rows_from_cache:
                    logger.warning(
                        "position_list skip_auto_close_on_cached_rows user=%s symbol=%s",
                        request.user.id,
                        order.symbol,
                    )
                    continue
                if _auto_close_missing_exchange_order_safely(
                    order,
                    client,
                    account_identity=account_identity,
                    pos_mode=pos_mode,
                    source="position_list",
                ):
                    synced_closed_orders += 1
                continue

            result.append(
                _serialize_open_position(
                    order=order,
                    row=row,
                    public_price_map=public_price_map,
                    open_algo_rows=open_algo_rows,
                    pos_mode=pos_mode,
                    snapshot_map=snapshot_map,
                    latest_strategy_error=latest_errors.get(order.id, ""),
                )
            )
        assemble_ms = _perf_ms(assemble_started)
        cache.set(list_cache_key, result, timeout=10)
        logger.info(
            "perf position_list user=%s total_ms=%s credentials_ms=%s exchange_ms=%s db_ms=%s assemble_ms=%s rows=%s orders=%s synced_closed=%s cache_hit=0 exchange_cache_hit=%s",
            getattr(request.user, "id", None),
            _perf_ms(total_started),
            credentials_ms,
            exchange_ms,
            db_ms,
            assemble_ms,
            len(result),
            len(orders),
            synced_closed_orders,
            exchange_cache_hit,
        )
        return ok(data=result)


def _confirm_manual_close(client: BinanceFuturesClient, order: Order, inst_id: str, pos_mode: str) -> bool:
    """Only report a manual close after the matching exchange position disappears."""
    last_error: Exception | None = None
    consecutive_absent = 0
    for delay in MANUAL_CLOSE_CONFIRM_DELAYS_SECONDS:
        if delay:
            time.sleep(delay)
        try:
            positions = client.get_positions(
                "SWAP",
                inst_id,
                budget_priority=RequestPriority.CRITICAL,
            ).get("data") or []
            row = _find_position_row(order, positions, pos_mode)
            if not row or abs(_to_decimal(row.get("pos") or "0")) <= POSITION_SIZE_TOLERANCE:
                consecutive_absent += 1
                if consecutive_absent >= 2:
                    return True
            else:
                consecutive_absent = 0
        except Exception as exc:  # noqa: BLE001
            last_error = exc
            consecutive_absent = 0
    logger.warning(
        "manual close not confirmed user=%s order_id=%s symbol=%s err=%s",
        order.user_id,
        order.id,
        order.symbol,
        last_error or "position still open",
    )
    return False


def _close_response_confirms_fill(payload: Optional[dict]) -> bool:
    rows = (payload or {}).get("data") or []
    if not rows or not isinstance(rows[0], dict):
        return False
    row = rows[0]
    return bool(str(row.get("ordId") or "").strip()) and str(
        row.get("state") or ""
    ).strip().lower() == "filled"


class PositionCloseView(APIView):
    @serialized_exchange_mutation
    def post(self, request):
        payload = request_data_mapping(request)
        if payload is None:
            return fail("请求参数必须是对象")
        position_id = payload.get("position_id")
        if not position_id:
            return fail("position_id不能为空")

        order = _scoped_order_queryset(request.user, trading_mode=request_trading_mode(request), status=0).filter(id=position_id).first()
        if not order:
            return fail("该订单已完成平仓，已同步最新状态")

        credentials = get_user_binance_credentials(request.user, trading_mode=request_trading_mode(request))
        if not credentials:
            return fail("使用持仓功能需先绑定 Binance Futures 实盘 API，是否立即前往绑定？")

        client = BinanceFuturesClient(credentials)
        inst_id = to_inst_id(order.symbol)

        try:
            pos_mode = _load_pos_mode(
                client,
                retry_label="manual_close_load_pos_mode",
                budget_priority=RequestPriority.CRITICAL,
            )
        except Exception:  # noqa: BLE001
            return fail("无法确认交易所持仓模式，请稍后重试")

        if order.position_origin == Order.ORIGIN_EXTERNAL:
            from trading.external_positions import close_external_position

            try:
                confirmed = close_external_position(order, client, pos_mode=pos_mode, reason="manual")
            except BinanceApiError as exc:
                return fail(safe_error_summary(exc, include_type=False))
            except Exception as exc:  # noqa: BLE001
                logger.warning(
                    "external_manual_close_failed user=%s order=%s err=%s",
                    request.user.id,
                    order.id,
                    safe_error_summary(exc),
                )
                return fail("手动仓平仓结果尚未确认，系统将继续核对，请刷新后查看")
            _invalidate_position_list_cache(request.user, order.api_key_fingerprint or "", trading_mode=order.trading_mode)
            if not confirmed:
                return fail("平仓请求已提交，但交易所尚未确认仓位归零，系统将继续核对")
            order.refresh_from_db()
            return ok(
                message="平仓成功",
                data={
                    "pnl": format(order.pnl, "f") if order.pnl is not None else None,
                    "pnl_ratio": format(order.pnl_ratio, "f") if order.pnl_ratio is not None else None,
                },
            )

        # T028: 平仓前获取当前持仓信息，用于记录平仓数据
        close_price = order.open_price
        position_amount = Decimal("0")
        pnl = Decimal("0")
        pnl_ratio = Decimal("0")
        position_known_absent = False

        try:
            # 获取当前持仓信息
            pos_payload = client.get_positions(
                "SWAP",
                inst_id,
                budget_priority=RequestPriority.CRITICAL,
            )
            pos_rows = pos_payload.get("data") or []
            pos_data = _find_position_row(order, pos_rows, pos_mode)
            if pos_data:
                close_price = _to_decimal(pos_data.get("markPx") or pos_data.get("last") or order.open_price)
                pos = abs(_to_decimal(pos_data.get("pos") or "0"))
                ct_val = _to_decimal(pos_data.get("ctVal") or "0")
                position_amount = pos * close_price * ct_val if ct_val > 0 else _to_decimal(pos_data.get("notionalUsd") or "0")
                pnl = _to_decimal(pos_data.get("upl") or "0")
                pnl_ratio = _to_decimal(pos_data.get("uplRatio") or "0") * Decimal("100")
            else:
                position_known_absent = _confirm_manual_close(client, order, inst_id, pos_mode)
        except Exception:  # noqa: BLE001
            pass

        close_payload = None
        if not position_known_absent:
            pos_side = None
            if pos_mode == "long_short_mode":
                pos_side = "long" if order.side == 0 else "short"
            record_operation(
                order, action="manual_close", actor="user", status="pending",
                message="用户发起立即平仓，等待交易所确认",
            )
            try:
                close_payload = client.close_position(
                    inst_id=inst_id, pos_side=pos_side,
                    expected_side="long" if order.side == 0 else "short",
                )
            except BinanceApiError as exc:
                if not exc.outcome_unknown:
                    record_operation(
                        order, action="manual_close", actor="user", status="failed",
                        message=f"立即平仓被拒绝：{safe_error_summary(exc, include_type=False)}",
                    )
                    return fail(safe_error_summary(exc, include_type=False))
                if not _confirm_manual_close(client, order, inst_id, pos_mode):
                    record_operation(
                        order, action="manual_close", actor="user", status="pending",
                        message=f"立即平仓结果待确认：{safe_error_summary(exc, include_type=False)}",
                    )
                    return fail(safe_error_summary(exc, include_type=False))
            except Exception as exc:
                if not _confirm_manual_close(client, order, inst_id, pos_mode):
                    record_operation(
                        order, action="manual_close", actor="user", status="pending",
                        message=f"立即平仓结果待确认：{safe_error_summary(exc, include_type=False)}",
                    )
                    return fail("平仓失败，请稍后重试")
            else:
                if not _close_response_confirms_fill(close_payload) and not _confirm_manual_close(
                    client,
                    order,
                    inst_id,
                    pos_mode,
                ):
                    return fail("平仓请求已提交，但交易所尚未确认仓位归零，请刷新后重试")

        close_rows = (close_payload or {}).get("data") or []
        close_binance_order_id = ""
        if close_rows:
            close_row = close_rows[0] or {}
            close_binance_order_id = str(close_row.get("ordId") or "").strip()
            response_close_price = _to_decimal(close_row.get("avgPx") or close_row.get("fillPx") or "0")
            if response_close_price > 0:
                close_price = response_close_price

        if pnl == 0:
            pnl = _derive_local_realized_pnl(order, close_price)
        if pnl_ratio == 0 and order.open_price and order.size:
            base_notional = order.open_price * order.size
            if base_notional > 0 and pnl != 0:
                pnl_ratio = (pnl / base_notional) * Decimal("100")

        # T028: 更新平仓数据
        order.status = 1
        order.closed_at = timezone.now()
        order.close_price = close_price
        order.position_amount = position_amount
        order.pnl = pnl
        order.pnl_ratio = pnl_ratio
        order.close_binance_order_id = close_binance_order_id
        order.realized_pnl = pnl
        order.realized_fee = None
        order.realized_funding_fee = None
        order.settlement_status = Order.SETTLEMENT_STATUS_PENDING
        order.settled_at = None
        order.settlement_error = ""
        order.settlement_retry_count = 0
        order.settlement_next_retry_at = None
        order.exchange_size = Decimal("0")
        order.has_manual_addition = False
        close_notification = {
            "event_type": TradeNotificationEvent.TYPE_MANUAL_TAKE_PROFIT,
            "trigger_price": close_price,
        }
        persisted = persist_confirmed_close_transition(
            order,
            notification=close_notification,
            update_fields=[
                "status",
                "closed_at",
                "close_price",
                "position_amount",
                "pnl",
                "pnl_ratio",
                "close_binance_order_id",
                "realized_pnl",
                "realized_fee",
                "realized_funding_fee",
                "settlement_status",
                "settled_at",
                "settlement_error",
                "settlement_retry_count",
                "settlement_next_retry_at",
                "exchange_size",
                "has_manual_addition",
            ],
        )
        if not persisted:
            _invalidate_position_list_cache(request.user, order.api_key_fingerprint or "", trading_mode=order.trading_mode)
            return ok(message="该订单已完成平仓，已同步最新状态")

        cleanup_result = best_effort_cleanup_closed_order_exchange_artifacts(
            order,
            client,
            action_prefix="manual_close_cleanup",
        )
        persist_closed_order_cleanup_result(order, cleanup_result)
        try:
            _reconcile_order_settlement(order=order, client=client, close_price=close_price)
        except BinanceApiError as exc:
            _mark_order_settlement_failed(order, str(exc))
        except Exception as exc:  # noqa: BLE001
            _mark_order_settlement_failed(order, f"settlement unexpected error: {exc}")
        _invalidate_position_list_cache(request.user, order.api_key_fingerprint or "", trading_mode=order.trading_mode)
        return ok(message="平仓成功", data={"pnl": format(pnl, "f"), "pnl_ratio": format(pnl_ratio, "f")})


def _cancel_running_strategy_on_manual_take_profit(order: Order, client, user) -> bool:
    """手动止盈覆盖自动止盈：撤销运行中策略的止盈挂单并冻结策略，已设止损保持不动。

    返回是否实际取消了运行中的策略。
    """
    if order.strategy_status != Order.STRATEGY_STATUS_RUNNING:
        return False
    inst_id = to_inst_id(order.symbol)
    algo_client = BinanceAlgoClient(client, log=logger)
    tp_algo_ids = order.strategy_tp_algo_ids or []
    if isinstance(tp_algo_ids, list):
        for algo_id in tp_algo_ids:
            if not algo_id:
                continue
            algo_client.cancel_algo_confirmed(
                str(algo_id),
                inst_id,
                action="cancel_strategy_take_profit_by_manual_tp",
            )
    order.strategy_status = Order.STRATEGY_STATUS_CANCELLED
    order.strategy_tp_algo_ids = []
    order.save(update_fields=["strategy_status", "strategy_tp_algo_ids"])
    snapshot = None
    if order.strategy_snapshot_id:
        snapshot = OrderStrategySnapshot.objects.filter(
            id=order.strategy_snapshot_id,
            order_id=order.id,
            user=user,
        ).first()
    if snapshot:
        OrderStrategyLog.objects.create(
            order=order,
            snapshot=snapshot,
            behavior_desc="用户手动设置止盈，自动止盈策略已取消，止损保持当前设置",
            result=OrderStrategyLog.RESULT_SUCCESS,
        )
    return True


class BreakEvenStopView(APIView):
    @serialized_exchange_mutation
    def post(self, request):
        payload = request_data_mapping(request)
        if payload is None:
            return fail("请求参数必须是对象")
        position_id = payload.get("position_id")
        mode = str(payload.get("mode") or "").strip()
        if not position_id:
            return fail("position_id不能为空")
        if mode not in {"with_fee", "without_fee"}:
            return fail("保本方式不合法")

        order = _scoped_order_queryset(request.user, trading_mode=request_trading_mode(request), status=0).filter(id=position_id).first()
        if not order:
            return fail("该订单已完成平仓，已同步最新状态")
        if order.position_origin == Order.ORIGIN_EXTERNAL:
            return fail("手动仓由强制止损保护管理，暂不支持保本操作")
        if order.strategy_status == Order.STRATEGY_STATUS_RUNNING and order.strategy_snapshot_id:
            return fail("已绑定止盈策略，保本入口不可用；止盈策略不可手动取消")

        credentials = get_user_binance_credentials(request.user, trading_mode=request_trading_mode(request))
        if not credentials:
            return fail("使用持仓功能需先绑定 Binance Futures 实盘 API，是否立即前往绑定？")

        client = BinanceFuturesClient(credentials)
        inst_id = to_inst_id(order.symbol)
        try:
            pos_mode = _load_pos_mode(
                client,
                retry_label="break_even_stop_load_pos_mode",
                budget_priority=RequestPriority.CRITICAL,
            )
            pos_rows = client.get_positions(
                "SWAP",
                inst_id,
                budget_priority=RequestPriority.CRITICAL,
            ).get("data") or []
            row = _find_position_row(order, pos_rows, pos_mode)
            if not row:
                return fail("未找到交易所持仓，请刷新后重试")

            current_price = _to_decimal(row.get("markPx") or row.get("last") or row.get("avgPx") or order.open_price)
            avg_price = _to_decimal(row.get("avgPx") or order.open_price)
            pos = abs(_to_decimal(row.get("pos") or "0"))
            ct_val = _to_decimal(row.get("ctVal") or "0")
            position_scale = pos * (ct_val if ct_val > 0 else Decimal("1"))
            if avg_price <= 0 or current_price <= 0 or position_scale <= 0:
                return fail("当前持仓数据无效，请刷新后重试")

            raw_upl = row.get("upl")
            has_exchange_upl = raw_upl is not None and str(raw_upl).strip() != ""
            floating_pnl = _to_decimal(raw_upl or "0") if has_exchange_upl else Decimal("0")
            if not has_exchange_upl:
                floating_pnl = (
                    (current_price - avg_price) * position_scale
                    if order.side == 0
                    else (avg_price - current_price) * position_scale
                )
            total_fee = abs(_to_decimal(order.estimated_total_fee or "0"))
            if total_fee <= 0:
                total_fee = avg_price * position_scale * TOTAL_FEE_RATE

            if floating_pnl <= 0:
                # 浮亏保本：无法把止损移到开仓价（会立即触发），
                # 改为挂一个回到开仓价（±手续费价位）自动平仓的止盈单，收益目标为 0。
                target_tp = avg_price
                if mode == "with_fee" and total_fee > 0:
                    fee_price_delta = total_fee / position_scale
                    target_tp = avg_price + fee_price_delta if order.side == 0 else avg_price - fee_price_delta
                algo_client = BinanceAlgoClient(client, log=logger)
                existing_algo_id = str(order.manual_take_profit_algo_id or "").strip()
                pos_side = _resolve_pos_side_from_mode(order.side, pos_mode)
                close_side = "sell" if order.side == 0 else "buy"
                has_existing_take_profit = bool(existing_algo_id or (order.strategy_tp_algo_ids or []))
                algo_id = algo_client.create_take_profit(
                    inst_id=inst_id,
                    side=close_side,
                    size=format(pos, "f"),
                    trigger_price=format(target_tp, "f"),
                    pos_side=pos_side,
                    order_type="market",
                    client_algo_id=_take_profit_client_id(
                        order,
                        "bet",
                        "market",
                        target_tp,
                        pos,
                    ),
                    visibility_mode=(
                        ALGO_VISIBILITY_REQUIRE_VISIBLE
                        if has_existing_take_profit
                        else ALGO_VISIBILITY_ALLOW_DELAYED
                    ),
                    action="break_even_take_profit",
                )
                try:
                    _cancel_running_strategy_on_manual_take_profit(
                        order,
                        client,
                        request.user,
                    )
                    if existing_algo_id and existing_algo_id != algo_id:
                        algo_client.cancel_algo_confirmed(
                            existing_algo_id,
                            inst_id,
                            action="replace_break_even_take_profit",
                        )
                except Exception:
                    try:
                        algo_client.cancel_algo_confirmed(
                            algo_id,
                            inst_id,
                            action="rollback_break_even_take_profit",
                        )
                    except Exception as rollback_exc:  # noqa: BLE001
                        logger.error(
                            "break even take profit rollback failed user=%s order=%s algo=%s err=%s",
                            getattr(request.user, "id", None),
                            position_id,
                            algo_id,
                            safe_error_summary(rollback_exc),
                        )
                    raise
                order.manual_take_profit_algo_id = algo_id
                order.manual_take_profit_price = target_tp
                order.manual_take_profit_order_type = "market"
                order.save(update_fields=[
                    "manual_take_profit_algo_id",
                    "manual_take_profit_price",
                    "manual_take_profit_order_type",
                ])
                record_operation(
                    order, action="break_even", actor="user", status="success",
                    message=f"保本止盈挂单已受理：触发价 {target_tp:f}",
                )
                # 手动保本止盈同样覆盖自动止盈策略，止损保持不动
                _invalidate_position_list_cache(request.user, order.api_key_fingerprint or "", trading_mode=order.trading_mode)
                return ok(
                    message="保本止盈已挂单",
                    data={
                        "type": "take_profit",
                        "take_profit_price": format(target_tp, "f"),
                        "mode": mode,
                        "estimated_total_fee": format(total_fee, "f"),
                    },
                )

            if mode == "with_fee" and floating_pnl <= total_fee:
                return fail("当前浮盈不足以覆盖总手续费，不能设置含手续费保本")

            target_stop = avg_price
            if mode == "with_fee" and total_fee > 0:
                fee_price_delta = total_fee / position_scale
                target_stop = avg_price + fee_price_delta if order.side == 0 else avg_price - fee_price_delta

            moved = _move_stop_loss(
                client,
                order,
                target_stop,
                current_price,
                pos_mode=pos_mode,
                positions=pos_rows,
            )
            if not moved:
                return fail("当前止损已高于或等于目标保本位，无需调整")

            _invalidate_position_list_cache(request.user, order.api_key_fingerprint or "", trading_mode=order.trading_mode)
            order.refresh_from_db(fields=["stop_loss_price", "current_stop_price"])
            record_operation(
                order, action="break_even", actor="user", status="success",
                message=f"保本止损调整已提交：触发价 {order.current_stop_price or order.stop_loss_price:f}",
            )
            return ok(
                message="保本损已设置",
                data={
                    "type": "stop",
                    "stop_loss_price": format(order.current_stop_price or order.stop_loss_price, "f"),
                    "mode": mode,
                    "estimated_total_fee": format(total_fee, "f"),
                },
            )
        except BinanceApiError as exc:
            logger.warning(
                "break_even_stop failed user=%s order=%s symbol=%s mode=%s err=%s",
                getattr(request.user, "id", None),
                order.id,
                order.symbol,
                mode,
                safe_error_summary(exc),
            )
            pending = exc.outcome_unknown or exc.code == "ALGO_VISIBILITY_TIMEOUT"
            record_operation(
                order, action="break_even", actor="user",
                status="pending" if pending else "failed",
                message=("保本操作结果待核对：" if pending else "保本操作未完成：")
                + safe_error_summary(exc, include_type=False),
            )
            return fail(safe_error_summary(exc, include_type=False))


class ManualTakeProfitView(APIView):
    @serialized_exchange_mutation
    def post(self, request):
        payload = request_data_mapping(request)
        if payload is None:
            return fail("请求参数必须是对象")
        position_id = payload.get("position_id")
        raw_price = payload.get("take_profit_price")
        order_type = str(payload.get("order_type") or "market").strip().lower()
        if not position_id:
            return fail("position_id不能为空")
        if order_type not in {"market", "limit"}:
            return fail("止盈类型仅支持市价或限价")

        target_price = _to_decimal(raw_price)
        if target_price <= 0:
            return fail("请输入有效止盈价格")

        order = _scoped_order_queryset(request.user, trading_mode=request_trading_mode(request), status=0).filter(id=position_id).first()
        if not order:
            return fail("订单不存在或已平仓")
        if order.strategy_status == Order.STRATEGY_STATUS_RUNNING and order.strategy_snapshot_id:
            return fail("已绑定止盈策略，不可切换手动止盈；止盈策略不可手动取消")

        credentials = get_user_binance_credentials(request.user, trading_mode=request_trading_mode(request))
        if not credentials:
            return fail("请先绑定API")

        try:
            client = BinanceFuturesClient(credentials)
            inst_id = to_inst_id(order.symbol)
            positions = _load_positions_with_retry(client)
            pos_mode = _load_pos_mode(client)
            pos_side = _resolve_pos_side_from_mode(order.side, pos_mode)
            pos_row = _find_position_row(order, positions, pos_mode)
            if not pos_row:
                return fail("未查询到当前持仓，无法设置止盈")
            current_size = abs(_to_decimal(pos_row.get("pos") or "0"))
            if current_size <= 0:
                return fail("当前持仓数量为0，无法设置止盈")
            reference_price = _to_decimal(pos_row.get("markPx") or pos_row.get("last") or order.open_price)
            _validate_take_profit_price(order, target_price, reference_price)

            algo_client = BinanceAlgoClient(client, log=logger)
            existing_algo_id = str(order.manual_take_profit_algo_id or "").strip()
            has_existing_take_profit = bool(existing_algo_id or (order.strategy_tp_algo_ids or []))
            close_side = "sell" if order.side == 0 else "buy"
            algo_id = algo_client.create_take_profit(
                inst_id=inst_id,
                side=close_side,
                size=format(current_size, "f"),
                trigger_price=format(target_price, "f"),
                pos_side=pos_side,
                order_type=order_type,
                client_algo_id=_take_profit_client_id(
                    order,
                    "mtp",
                    order_type,
                    target_price,
                    current_size,
                ),
                visibility_mode=(
                    ALGO_VISIBILITY_REQUIRE_VISIBLE
                    if has_existing_take_profit
                    else ALGO_VISIBILITY_ALLOW_DELAYED
                ),
                action="manual_take_profit",
            )
            try:
                strategy_cancelled = _cancel_running_strategy_on_manual_take_profit(
                    order,
                    client,
                    request.user,
                )
                if existing_algo_id and existing_algo_id != algo_id:
                    algo_client.cancel_algo_confirmed(
                        existing_algo_id,
                        inst_id,
                        action="replace_manual_take_profit",
                    )
            except Exception:
                try:
                    algo_client.cancel_algo_confirmed(
                        algo_id,
                        inst_id,
                        action="rollback_manual_take_profit",
                    )
                except Exception as rollback_exc:  # noqa: BLE001
                    logger.error(
                        "manual take profit rollback failed user=%s order=%s algo=%s err=%s",
                        getattr(request.user, "id", None),
                        position_id,
                        algo_id,
                        safe_error_summary(rollback_exc),
                    )
                raise
        except BinanceApiError as exc:
            if exc.code == "ALGO_VISIBILITY_TIMEOUT" and (
                order.manual_take_profit_algo_id or order.strategy_tp_algo_ids
            ):
                record_operation(
                    order, action="manual_take_profit", actor="user", status="pending",
                    message="新止盈单状态待核对，原有止盈保护已保留",
                )
                previous_price = format(order.manual_take_profit_price, "f") if order.manual_take_profit_price else ""
                return fail(
                    f"新止盈单确认超时，原止盈价 {previous_price} 已保留，请稍后重试"
                    if previous_price
                    else "新止盈单确认超时，原有止盈保护已保留，请稍后重试"
                )
            pending = exc.outcome_unknown or exc.code == "ALGO_VISIBILITY_TIMEOUT"
            record_operation(
                order, action="manual_take_profit", actor="user",
                status="pending" if pending else "failed",
                message=("止盈设置结果待核对：" if pending else "设置止盈未完成：")
                + safe_error_summary(exc, include_type=False),
            )
            return fail(safe_error_summary(exc, include_type=False))
        except Exception as exc:  # noqa: BLE001
            logger.error(
                "manual take profit set failed user=%s order=%s err=%s",
                getattr(request.user, "id", None),
                position_id,
                safe_error_summary(exc),
            )
            record_operation(
                order, action="manual_take_profit", actor="user", status="pending",
                message=f"止盈设置未完成，需核对结果：{safe_error_summary(exc, include_type=False)}",
            )
            return fail("设置止盈失败，请稍后重试")

        order.manual_take_profit_algo_id = algo_id
        order.manual_take_profit_price = target_price
        order.manual_take_profit_order_type = order_type
        order.save(update_fields=[
            "manual_take_profit_algo_id",
            "manual_take_profit_price",
            "manual_take_profit_order_type",
        ])
        record_operation(
            order, action="manual_take_profit", actor="user", status="success",
            message=f"手动{'市价' if order_type == 'market' else '限价'}止盈挂单已受理：触发价 {target_price:f}",
        )
        # 手动止盈覆盖自动止盈策略：撤销策略挂单并冻结策略，已设止损不动
        _invalidate_position_list_cache(request.user, order.api_key_fingerprint or "", trading_mode=order.trading_mode)
        return ok(
            message="止盈已设置" + ("，自动止盈策略已取消" if strategy_cancelled else ""),
            data={
                "algo_id": algo_id,
                "take_profit_price": format(target_price, "f"),
                "order_type": order_type,
                "strategy_cancelled": strategy_cancelled,
            },
        )

    @serialized_exchange_mutation
    def delete(self, request):
        payload = request_data_mapping(request)
        if payload is None:
            return fail("请求参数必须是对象")
        position_id = payload.get("position_id")
        if not position_id:
            return fail("position_id不能为空")
        order = _scoped_order_queryset(request.user, trading_mode=request_trading_mode(request), status=0).filter(id=position_id).first()
        if not order:
            return fail("订单不存在或已平仓")

        algo_id = str(order.manual_take_profit_algo_id or "").strip()
        if algo_id:
            credentials = get_user_binance_credentials(request.user, trading_mode=request_trading_mode(request))
            if not credentials:
                return fail("取消止盈前请先恢复 API 连接")
            try:
                algo_client = BinanceAlgoClient(BinanceFuturesClient(credentials), log=logger)
                algo_client.cancel_algo_confirmed(
                    algo_id,
                    to_inst_id(order.symbol),
                    action="cancel_manual_take_profit",
                )
            except BinanceApiError as exc:
                record_operation(
                    order, action="manual_take_profit", actor="user",
                    status="pending" if exc.outcome_unknown else "failed",
                    message=f"止盈取消未完成：{safe_error_summary(exc, include_type=False)}",
                )
                return fail(safe_error_summary(exc, include_type=False))
            except Exception as exc:  # noqa: BLE001
                logger.error(
                    "manual take profit cancel failed user=%s order=%s err=%s",
                    getattr(request.user, "id", None),
                    position_id,
                    safe_error_summary(exc),
                )
                record_operation(
                    order, action="manual_take_profit", actor="user", status="pending",
                    message=f"止盈取消结果待确认：{safe_error_summary(exc, include_type=False)}",
                )
                return fail("取消止盈失败，请稍后重试")

        order.manual_take_profit_algo_id = ""
        order.manual_take_profit_price = None
        order.manual_take_profit_order_type = ""
        order.save(update_fields=[
            "manual_take_profit_algo_id",
            "manual_take_profit_price",
            "manual_take_profit_order_type",
        ])
        if algo_id:
            record_operation(
                order, action="manual_take_profit", actor="user", status="success",
                message="手动止盈单已确认取消",
            )
        _invalidate_position_list_cache(request.user, order.api_key_fingerprint or "", trading_mode=order.trading_mode)
        return ok(message="止盈已取消")


class PositionHistoryView(APIView):
    """展示已入库仓位历史；手动仓仅提供明确标注的估算结果。"""

    def get(self, request):
        total_started = time.perf_counter()
        local_snapshot = request.query_params.get("snapshot") == "local"
        page = _parse_positive_int(
            request.query_params.get("page"),
            1,
        )
        page_size = _parse_positive_int(
            request.query_params.get("page_size"),
            HISTORY_DEFAULT_PAGE_SIZE,
            max_value=HISTORY_MAX_PAGE_SIZE,
        )
        start_time, end_time, filter_type = _history_time_range_from_request(request)

        db_started = time.perf_counter()
        closed_queryset = _scoped_order_queryset(request.user, trading_mode=request_trading_mode(request), status=1).annotate(
            history_closed_at=Coalesce("closed_at", "created_at")
        )
        if start_time:
            closed_queryset = closed_queryset.filter(history_closed_at__gte=start_time)
        if end_time:
            closed_queryset = closed_queryset.filter(history_closed_at__lte=end_time)
        open_queryset = _scoped_order_queryset(
            request.user, trading_mode=request_trading_mode(request), status=0,
        ).exclude(position_origin=Order.ORIGIN_EXTERNAL)
        offset = (page - 1) * page_size
        closed_count = closed_queryset.count()
        first_open_order = open_queryset.first()
        db_ms = _perf_ms(db_started)

        assemble_started = time.perf_counter()
        exchange_started = time.perf_counter()
        position_rows = _load_history_position_rows(
            request.user, [first_open_order], trading_mode=request_trading_mode(request),
        ) if first_open_order and not local_snapshot else {}
        # Persisted reductions remain discoverable even if the current exchange
        # position is absent. Legacy rows without evidence are probed only for
        # directions that are actually active, rather than all stale local rows.
        reduction_evidence = (
            Q(exchange_size__gte=0, exchange_size__lt=F("size"))
            | Q(has_reduction=True)
        )
        for inst_id, side in position_rows:
            reduction_evidence |= Q(
                symbol=to_symbol(inst_id),
                side=0 if side == "long" else 1,
            )
        active_candidates = list(open_queryset.alias(
            has_reduction=Exists(TradeNotificationEvent.objects.filter(
                order_id=OuterRef("id"), event_type=TradeNotificationEvent.TYPE_REDUCTION,
            )),
        ).filter(reduction_evidence).order_by("-created_at", "-id")) if first_open_order and not local_snapshot else []
        active_exchange_rows = _load_history_exchange_rows(
            request.user, active_candidates, trading_mode=request_trading_mode(request),
        ) if active_candidates else {}
        exchange_ms = _perf_ms(exchange_started)
        active_history = []
        for order in active_candidates:
            if not _has_partial_close_rows(order, active_exchange_rows):
                continue
            trades = active_exchange_rows.get("rows_by_order_id", {}).get(order.id, {}).get("trade_rows", [])
            history_closed_at = order.closed_at or _trade_rows_last_time(trades)
            if start_time and (not history_closed_at or history_closed_at < start_time):
                continue
            if end_time and (not history_closed_at or history_closed_at > end_time):
                continue
            active_history.append((history_closed_at, order))

        # An active projection can displace at most one closed row. Fetch only
        # the closed window needed to merge this page, then supplement its rows.
        window_start = max(0, offset - len(active_history))
        db_started = time.perf_counter()
        closed_window = list(closed_queryset.order_by("-history_closed_at", "-id")[
            window_start:offset + page_size
        ])
        db_ms += _perf_ms(db_started)
        history_window = [(order.history_closed_at, order) for order in closed_window]
        history_window.extend(active_history)
        history_window.sort(key=lambda item: (
            item[0] or datetime.min.replace(tzinfo=dt_timezone.utc), item[1].id,
        ), reverse=True)
        visible_orders = [order for _, order in history_window[
            offset - window_start:offset - window_start + page_size
        ]]
        exchange_started = time.perf_counter()
        closed_exchange_rows = _load_history_exchange_rows(
            request.user, [order for order in visible_orders if order.status == 1],
            trading_mode=request_trading_mode(request),
        ) if not local_snapshot and any(order.status == 1 for order in visible_orders) else {}
        if not local_snapshot:
            _sync_external_closed_history(
                request.user,
                [order for order in visible_orders if order.status == 1],
                trading_mode=request_trading_mode(request),
            )
        exchange_ms += _perf_ms(exchange_started)
        exchange_rows = {
            "rows_by_order_id": {
                **active_exchange_rows.get("rows_by_order_id", {}),
                **closed_exchange_rows.get("rows_by_order_id", {}),
            },
            "exchange_available": bool(
                active_exchange_rows.get("exchange_available") or closed_exchange_rows.get("exchange_available")
            ),
        }
        log_order_ids = set(OrderStrategyLog.objects.filter(
            order_id__in=[order.id for order in visible_orders],
        ).values_list("order_id", flat=True).distinct()) if visible_orders else set()
        visible_result = [
            _serialize_history_order(order, log_order_ids, exchange_rows, position_rows)
            for order in visible_orders
        ]
        total_count = closed_count + len(active_history)

        logger.info(
            "perf position_history user=%s total_ms=%s exchange_ms=%s ctval_ms=0 db_ms=%s assemble_ms=%s rows=%s total=%s page=%s page_size=%s filter=%s start=%s end=%s exchange_available=%s local_snapshot=%s",
            getattr(request.user, "id", None),
            _perf_ms(total_started),
            exchange_ms,
            db_ms,
            _perf_ms(assemble_started),
            len(visible_result),
            total_count,
            page,
            page_size,
            filter_type,
            start_time.isoformat() if start_time else "",
            end_time.isoformat() if end_time else "",
            int(bool(exchange_rows.get("exchange_available"))),
            int(local_snapshot),
        )

        return ok(
            data={
                "items": visible_result,
                # A local first read never contacts Binance or changes settlement.
                # The normal read still discovers partial closes and reconciles fees.
                "exchange_refresh_required": local_snapshot and (
                    first_open_order is not None
                    or any(_history_order_needs_exchange_refresh(order) for order in visible_orders)
                    or any(_external_history_order_needs_refresh(order) for order in visible_orders)
                ),
                "pagination": {
                    "page": page,
                    "page_size": page_size,
                    "total": total_count,
                    "has_next": offset + page_size < total_count,
                    "has_previous": page > 1,
                },
                "filters": {
                    "filter": filter_type,
                    "start_time": start_time.isoformat() if start_time else None,
                    "end_time": end_time.isoformat() if end_time else None,
                },
            }
        )


class StrategyCancelView(APIView):
    """开仓必须绑定止盈策略，且策略不可手动取消；保留路由仅用于明确拒绝旧客户端。"""

    def post(self, request):
        return fail("止盈策略不可手动取消；如需调整请使用换绑策略，平仓时系统会自动清理止盈单")


class StrategyRebindView(APIView):
    """为健康持仓重新绑定自动止盈策略"""

    @serialized_exchange_mutation
    def post(self, request):
        payload = request_data_mapping(request)
        if payload is None:
            return fail("请求参数必须是对象")
        position_id = payload.get("position_id")
        strategy_id = payload.get("strategy_id")
        if not position_id:
            return fail("position_id不能为空")
        if not strategy_id:
            return fail("strategy_id不能为空")

        order = _scoped_order_queryset(request.user, trading_mode=request_trading_mode(request), status=0).filter(id=position_id).first()
        if not order:
            return fail("订单不存在或已平仓")
        if order.position_origin == Order.ORIGIN_EXTERNAL:
            return fail("手动仓采用强制止损保护，暂不支持绑定自动止盈策略")

        strategy = Strategy.objects.filter(id=strategy_id, user=request.user).prefetch_related("levels").first()
        if not strategy:
            return fail("策略不存在")

        credentials = get_user_binance_credentials(request.user, trading_mode=request_trading_mode(request))
        if not credentials:
            return fail("使用持仓功能需先绑定 Binance Futures 实盘 API，是否立即前往绑定？")

        client = BinanceFuturesClient(credentials)
        inst_id = to_inst_id(order.symbol)
        try:
            pos_payload = client.get_positions(
                "SWAP",
                inst_id,
                budget_priority=RequestPriority.CRITICAL,
            )
        except BinanceApiError as exc:
            return fail(safe_error_summary(exc, include_type=False))

        pos_rows = pos_payload.get("data") or []
        try:
            pos_mode = _load_pos_mode(
                client,
                retry_label="strategy_rebind_load_pos_mode",
                budget_priority=RequestPriority.CRITICAL,
            )
        except BinanceApiError as exc:
            return fail(safe_error_summary(exc, include_type=False))
        current_row = _find_position_row(order, pos_rows, pos_mode)
        if not current_row:
            return fail("该订单已完成平仓，已同步最新状态")

        current_pos = abs(_to_decimal(current_row.get("pos") or "0"))
        if not _can_bind_strategy(order, current_pos):
            return fail("该订单无法添加止盈策略")

        strategy_config = [
            {
                "profitRR": float(level.profit_rr),
                "reducePosition": float(level.reduce_position),
                "stopLossType": level.stop_loss_type,
                "stopLossRR": float(level.stop_loss_rr) if level.stop_loss_rr is not None else None,
                "stopLossAbsoluteRR": float(level.stop_loss_absolute_rr) if level.stop_loss_absolute_rr is not None else None,
            }
            for level in strategy.levels.all().order_by("sort_order", "id")
        ]
        if not strategy_config:
            return fail("策略为空，无法绑定")

        snapshot = None
        algo_ids: list[str] = []
        try:
            pos_side = _resolve_pos_side_from_mode(order.side, pos_mode)

            snapshot = OrderStrategySnapshot.objects.create(
                order=order,
                user=request.user,
                strategy_id=str(strategy.id),
                strategy_name=str(strategy.name),
                strategy_config=strategy_config,
            )
            algo_ids = setup_strategy_take_profit_orders(order, snapshot, client, pos_side)
        except BinanceApiError as exc:
            if snapshot is not None:
                snapshot.delete()
            return fail(safe_error_summary(exc, include_type=False))
        except Exception:
            if snapshot is not None:
                snapshot.delete()
            return fail("添加止盈策略失败，请稍后重试")

        try:
            with transaction.atomic():
                current_order = Order.objects.select_for_update().get(id=order.id, status=0)
                if not _can_bind_strategy(current_order, current_pos):
                    raise ValueError("该订单状态已变化，无法添加止盈策略")
                current_order.strategy_snapshot_id = snapshot.id
                current_order.strategy_status = Order.STRATEGY_STATUS_RUNNING
                current_order.strategy_tp_algo_ids = algo_ids
                current_order.save(
                    update_fields=[
                        "strategy_snapshot_id",
                        "strategy_status",
                        "strategy_tp_algo_ids",
                    ]
                )
                OrderStrategyLog.objects.create(
                    order=current_order,
                    snapshot=snapshot,
                    behavior_desc=f"持仓重新绑定策略：{snapshot.strategy_name}",
                    result=OrderStrategyLog.RESULT_SUCCESS,
                )
        except Exception as exc:  # noqa: BLE001
            _rollback_rebind_take_profit_orders(order, client, algo_ids)
            snapshot.delete()
            logger.warning(
                "strategy_rebind_persistence_failed user=%s order=%s err=%s",
                request.user.id,
                order.id,
                safe_error_summary(exc),
            )
            return fail(
                str(exc)
                if isinstance(exc, ValueError)
                else "添加止盈策略失败，请稍后重试"
            )
        return ok(message="已添加自动止盈策略")


class StrategyLogView(APIView):
    """查询订单策略执行日志"""

    def get(self, request):
        position_id = request.query_params.get("position_id")
        if not position_id:
            return fail("position_id不能为空")

        order = _scoped_order_queryset(request.user, trading_mode=request_trading_mode(request)).filter(id=position_id).first()
        if not order:
            return fail("订单不存在")
        if not order.strategy_snapshot_id:
            return ok(
                data={
                    "strategy_name": "",
                    "strategy_config": [],
                    "logs": [],
                }
            )

        snapshot = OrderStrategySnapshot.objects.filter(
            id=order.strategy_snapshot_id,
            order_id=order.id,
            user=request.user,
        ).first()

        logs = _visible_strategy_logs(OrderStrategyLog.objects.filter(
            order_id=order.id,
            snapshot_id=order.strategy_snapshot_id,
        )).order_by("created_at", "id")
        logs = _dedupe_strategy_logs(logs)

        data = [
            {
                "id": log.id,
                "behavior_desc": log.behavior_desc,
                "trigger_r": format(log.trigger_r, "f") if log.trigger_r is not None else None,
                "result": log.result,
                "error": log.error or "",
                "created_at": log.created_at.isoformat(),
            }
            for log in logs
        ]
        return ok(
            data={
                "strategy_name": snapshot.strategy_name if snapshot else "",
                "strategy_config": snapshot.strategy_config if snapshot and isinstance(snapshot.strategy_config, list) else [],
                "logs": data,
            }
        )


def _get_ct_val_map(rows: list) -> dict[str, Decimal]:
    """获取所有涉及交易对的合约面值 (ctVal)"""
    inst_ids = set()
    for row in rows:
        inst_id = str(row.get("instId") or "")
        if inst_id:
            inst_ids.add(inst_id)

    if not inst_ids:
        return {}

    ct_val_map: dict[str, Decimal] = {}
    try:
        payload = binance_get_instruments(inst_type="SWAP")
        instruments = payload.get("data") or []
        for inst in instruments:
            inst_id = str(inst.get("instId") or "")
            if inst_id in inst_ids:
                ct_val = _to_decimal(inst.get("ctVal") or "1")
                ct_val_map[inst_id] = ct_val
    except Exception:
        pass

    return ct_val_map
