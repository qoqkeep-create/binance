"""
T027: 限价委托单状态同步服务
"""
from dataclasses import dataclass
from datetime import timedelta
from decimal import Decimal
import hashlib
import logging
import time
from typing import Any, Iterable, Optional, Tuple
from contextlib import contextmanager

from django.core.cache import cache
from django.db import connection, transaction
from django.db.models import F, Q
from django.utils import timezone

from api_bindings.context import build_trading_account_identity, record_belongs_to_trading_account
from common.trading_mode import TradingMode
from api_bindings.services import (
    get_user_binding_generation,
    get_user_binance_credentials,
    get_user_binance_credentials_for_generation,
)
from common.binance import (
    ALGO_VISIBILITY_ALLOW_DELAYED,
    ALGO_VISIBILITY_REQUIRE_VISIBLE,
    BinanceAlgoClient,
    BinanceApiError,
    BinanceFuturesClient,
    binance_get_instruments,
    detect_public_egress_ip,
    is_binance_rate_limit_error,
    quantize_down,
    standardize_trigger_order_request,
    to_inst_id,
    to_symbol,
)
from common.binance_rate_limit import RequestPriority
from common.errors import safe_error_summary
from positions.cleanup import (
    best_effort_cleanup_closed_order_exchange_artifacts,
    build_managed_algo_client_id,
    persist_closed_order_cleanup_result,
)
from positions.lifecycle import (
    build_close_anchor_from_trade_rows,
    fetch_order_trade_rows,
    persist_confirmed_close_transition,
)
from positions.notifications import (
    enqueue_open_notification,
    enqueue_reduction_notification,
    infer_exchange_close_notification,
)
from positions.models import (
    LimitOrder,
    Order,
    OrderStrategyLog,
    OrderStrategySnapshot,
    OrderStrategyTechnicalEvent,
    TradeNotificationEvent,
)
from positions.operation_logs import record_operation
from trading.execution import UNKNOWN, parse_entry_execution
from trading.account_cache import position_cache_key
from trading.locks import user_trading_activity_lock

logger = logging.getLogger(__name__)
POSITION_SIZE_TOLERANCE = Decimal("0.00000001")
STOP_LOSS_VISIBILITY_GRACE_SECONDS = 20
STOP_PROTECTION_ALERT_RETRY_COUNT = 3
STOP_PROTECTION_ALERT_AFTER_SECONDS = 30
STOP_PROTECTION_RETRY_DELAYS_SECONDS = (10, 10, 30, 60, 120, 300, 600)
TRANSIENT_BINANCE_READ_ERROR_CODES = frozenset({"-1000", "-1001", "-1006", "-1007"})


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


@dataclass(frozen=True)
class EntryRiskAdoption:
    order: Order
    created: bool
    size_changed: bool
    stop_loss_error: Optional[Exception]


@dataclass
class ProtectionAccountSnapshot:
    client: BinanceFuturesClient
    pos_mode: str
    positions: list[dict[str, Any]]
    algo_map: dict[str, dict[str, Any]]
    close_trade_rows: dict[int, list[dict[str, Any]]]


def _is_rate_limit_error_text(error: str) -> bool:
    text = str(error or "").lower()
    if not text:
        return False
    hints = (
        "too many requests",
        "requests per minute",
        "rate limit",
        "请求过于频繁",
    )
    return any(h in text for h in hints)


def _is_technical_failure_error_text(error: str) -> bool:
    text = str(error or "").lower()
    if not text:
        return False
    hints = (
        "timeout",
        "timed out",
        "network",
        "connection",
        "temporarily",
        "temporary",
        "unavailable",
        "failed to establish",
        "connection reset",
        "连接 ",
        "无效响应",
        "dns",
        "name resolution",
        "incorrect json data format",
        "50002",
        "internal server error",
        "system busy",
        "try again later",
    )
    return any(h in text for h in hints)


def _normalize_error_signature(error: str) -> str:
    text = str(error or "").strip().lower()
    if not text:
        return "unknown"
    return text[:255]


def _build_retry_context(
    *,
    order: Optional[Order] = None,
    user_id: Optional[int] = None,
    order_id: Optional[int] = None,
    symbol: str = "",
    inst_id: str = "",
    extra: Optional[dict[str, Any]] = None,
) -> dict[str, Any]:
    resolved_symbol = symbol
    if order is not None:
        resolved_symbol = resolved_symbol or str(order.symbol or "")
        if user_id is None:
            user_id = order.user_id
        if order_id is None:
            order_id = order.id
    resolved_inst_id = inst_id or (to_inst_id(resolved_symbol) if resolved_symbol else "")
    context = {
        "user_id": user_id or "",
        "order_id": order_id or "",
        "symbol": resolved_symbol,
        "inst_id": resolved_inst_id,
    }
    if extra:
        context.update(extra)
    return context


def _record_technical_strategy_event(
    order: Order,
    snapshot: OrderStrategySnapshot,
    desc: str,
    error: str,
) -> None:
    signature = _normalize_error_signature(error)
    sample = (str(error or "").strip() or None)
    now = timezone.now()
    updated = OrderStrategyTechnicalEvent.objects.filter(
        order=order,
        snapshot=snapshot,
        behavior_desc=desc,
        error_signature=signature,
    ).update(
        occurrence_count=F("occurrence_count") + 1,
        last_occurred_at=now,
        error_sample=sample,
    )
    if updated:
        return
    try:
        OrderStrategyTechnicalEvent.objects.create(
            order=order,
            snapshot=snapshot,
            behavior_desc=desc,
            error_signature=signature,
            error_sample=sample,
        )
    except Exception:
        # 并发下可能被唯一约束抢先写入，回退为一次增量更新
        OrderStrategyTechnicalEvent.objects.filter(
            order=order,
            snapshot=snapshot,
            behavior_desc=desc,
            error_signature=signature,
        ).update(
            occurrence_count=F("occurrence_count") + 1,
            last_occurred_at=now,
            error_sample=sample,
        )


def sync_limit_order_status(limit_order: LimitOrder) -> bool:
    """
    同步单个限价委托单的状态
    返回 True 表示有更新
    """
    current_fingerprint, binding_created_at = get_user_binding_generation(limit_order.user, trading_mode=limit_order.trading_mode)
    if not record_belongs_to_trading_account(
        record_fingerprint=limit_order.api_key_fingerprint,
        record_created_at=limit_order.created_at,
        account_fingerprint=current_fingerprint,
        binding_created_at=binding_created_at,
        record_mode=limit_order.trading_mode,
        account_mode=limit_order.trading_mode,
    ):
        return False
    account_identity = build_trading_account_identity(
        user_id=limit_order.user_id,
        api_key_fingerprint=current_fingerprint,
        trading_mode=limit_order.trading_mode,
    )
    with user_trading_activity_lock(account_identity) as locked:
        if not locked:
            return False
        credentials = _credentials_for_binding_generation(
            limit_order.user,
            api_key_fingerprint=current_fingerprint,
            binding_created_at=binding_created_at,
            trading_mode=limit_order.trading_mode,
        )
        if not credentials:
            return False
        limit_order.refresh_from_db(fields=["filled_size", "status", "order"])
        return _sync_limit_order_status_unlocked(limit_order, credentials=credentials)


def defer_incomplete_limit_execution(limit_order: LimitOrder, execution) -> bool:
    """Keep incomplete fill evidence pending, including across request retries."""
    if execution.filled_size < limit_order.filled_size:
        return True
    known_size = max(execution.filled_size, limit_order.filled_size)
    if execution.state != UNKNOWN and (execution.has_fill or known_size == 0):
        return False
    if known_size > limit_order.filled_size:
        limit_order.filled_size = known_size
        limit_order.save(update_fields=["filled_size", "updated_at"])
    return True


def _sync_limit_order_status_unlocked(
    limit_order: LimitOrder,
    *,
    credentials=None,
) -> bool:
    credentials = credentials or get_user_binance_credentials(limit_order.user, trading_mode=limit_order.trading_mode)
    if not credentials:
        return False

    try:
        client = BinanceFuturesClient(credentials)
        inst_id = to_inst_id(limit_order.symbol)

        payload = client.get_order(
            inst_id=inst_id,
            order_id=limit_order.binance_order_id,
            budget_priority=RequestPriority.BACKGROUND,
        )
        rows = payload.get("data") or []
        if not rows:
            return False

        order_data = rows[0]
        execution = parse_entry_execution(order_data, requested_size=limit_order.size)
        updated = False
        previous_fill_size = limit_order.filled_size
        if defer_incomplete_limit_execution(limit_order, execution):
            return limit_order.filled_size != previous_fill_size
        confirmed_fill_size = max(execution.filled_size, limit_order.filled_size)

        if execution.has_fill:
            adoption = adopt_entry_execution(
                user=limit_order.user,
                trading_mode=limit_order.trading_mode,
                client=client,
                binance_order_id=limit_order.binance_order_id,
                symbol=limit_order.symbol,
                side=limit_order.side,
                fill_size=confirmed_fill_size,
                average_price=execution.average_price,
                stop_loss_price=limit_order.stop_loss_price,
                stop_loss_amount=limit_order.stop_loss_amount,
                leverage=limit_order.leverage,
                api_key_fingerprint=limit_order.api_key_fingerprint,
                strategy_id=limit_order.strategy_id,
                strategy_name=limit_order.strategy_name,
                strategy_config=limit_order.strategy_config,
                limit_order=limit_order,
                source_label="限价成交",
            )
            updated = updated or adoption.created or adoption.size_changed
            if confirmed_fill_size != limit_order.filled_size:
                limit_order.filled_size = confirmed_fill_size
                updated = True

        if execution.state == "filled" and limit_order.status == LimitOrder.STATUS_PENDING:
            limit_order.status = LimitOrder.STATUS_FILLED
            updated = True
        elif execution.raw_state in {"canceled", "cancelled", "expired", "rejected"} and limit_order.status == LimitOrder.STATUS_PENDING:
            limit_order.status = LimitOrder.STATUS_CANCELLED
            updated = True

        if updated:
            limit_order.save(update_fields=["filled_size", "status", "order", "updated_at"])

        return updated
    except BinanceApiError as e:
        logger.warning("同步限价委托单失败 %s: %s", limit_order.id, safe_error_summary(e))
        if is_binance_rate_limit_error(e):
            raise
        return False
    except Exception as e:
        logger.error("同步限价委托单异常 %s: %s", limit_order.id, safe_error_summary(e))
        return False


def adopt_entry_execution(
    *,
    user,
    client: BinanceFuturesClient,
    binance_order_id: str,
    symbol: str,
    side: int,
    fill_size: Decimal,
    average_price: Decimal,
    stop_loss_price: Decimal,
    stop_loss_amount: Decimal,
    leverage: int,
    api_key_fingerprint: str = "",
    strategy_id: str = "",
    strategy_name: str = "",
    strategy_config=None,
    limit_order: Optional[LimitOrder] = None,
    estimated_total_fee: Optional[Decimal] = None,
    pos_mode: str = "",
    source_label: str = "开仓",
    trading_mode=TradingMode.ORDINARY,
) -> EntryRiskAdoption:
    """Create or expand one local risk record from cumulative exchange fill facts."""
    if not binance_order_id or fill_size <= 0 or average_price <= 0:
        raise BinanceApiError("成交信息不完整，无法接管风险")

    has_strategy = bool(strategy_id and strategy_name and strategy_config is not None)
    normalized_symbol = to_symbol(to_inst_id(symbol))
    account_scope = Q(api_key_fingerprint=api_key_fingerprint) if api_key_fingerprint else (
        Q(api_key_fingerprint__isnull=True) | Q(api_key_fingerprint="")
    )
    created = False
    size_changed = False
    with transaction.atomic():
        order = (
            Order.objects.select_for_update()
            .filter(
                account_scope,
                user=user,
                trading_mode=trading_mode,
                symbol=normalized_symbol,
                binance_order_id=binance_order_id,
            )
            .first()
        )
        if order is None:
            order = Order.objects.create(
                user=user,
                trading_mode=trading_mode,
                api_key_fingerprint=api_key_fingerprint or None,
                binance_order_id=binance_order_id,
                stop_protection_status=Order.STOP_PROTECTION_PENDING,
                symbol=normalized_symbol,
                side=side,
                open_price=average_price,
                initial_stop_price=stop_loss_price,
                stop_loss_price=stop_loss_price,
                stop_loss_amount=stop_loss_amount,
                size=fill_size,
                exchange_size=fill_size,
                leverage=leverage,
                status=0,
                current_stop_price=stop_loss_price,
                estimated_total_fee=estimated_total_fee,
                strategy_status=Order.STRATEGY_STATUS_RUNNING if has_strategy else Order.STRATEGY_STATUS_UNBOUND,
            )
            created = True
            size_changed = True
        elif order.status != 0:
            raise BinanceApiError("成交订单已在本地关闭，拒绝重复接管")
        elif fill_size > order.size + POSITION_SIZE_TOLERANCE:
            order.size = fill_size
            order.exchange_size = fill_size
            order.open_price = average_price
            update_fields = ["size", "exchange_size", "open_price"]
            if estimated_total_fee is not None:
                order.estimated_total_fee = estimated_total_fee
                update_fields.append("estimated_total_fee")
            order.save(update_fields=update_fields)
            size_changed = True

        snapshot = None
        if has_strategy:
            snapshot = OrderStrategySnapshot.objects.filter(order=order).first()
            if snapshot is None:
                snapshot = OrderStrategySnapshot.objects.create(
                    order=order,
                    user=user,
                    strategy_id=str(strategy_id),
                    strategy_name=str(strategy_name),
                    strategy_config=strategy_config,
                )
                order.strategy_snapshot_id = snapshot.id
                order.save(update_fields=["strategy_snapshot_id"])
                OrderStrategyLog.objects.create(
                    order=order,
                    snapshot=snapshot,
                    behavior_desc=f"{source_label}绑定策略：{snapshot.strategy_name}",
                    result=OrderStrategyLog.RESULT_SUCCESS,
                )

        if limit_order is not None:
            limit_order.order = order
            limit_order.save(update_fields=["order", "updated_at"])

    effective_fill_size = order.size
    stop_loss_error: Optional[Exception] = None
    resolved_pos_mode = pos_mode
    try:
        if not resolved_pos_mode:
            resolved_pos_mode = _load_pos_mode(
                client,
                retry_label="entry_fill_load_pos_mode",
                retry_context=_build_retry_context(order=order),
            )
        _converge_stop_loss_order(
            client,
            order,
            exchange_size=effective_fill_size,
            stop_price=stop_loss_price,
            pos_mode=resolved_pos_mode,
            current_price=average_price,
            action="entry_fill_protection",
            retry_context=_build_retry_context(order=order),
        )
        _clear_stop_protection_failure(order)
    except Exception as exc:  # noqa: BLE001
        stop_loss_error = exc
        _record_stop_protection_retry_failure(order, str(exc))

    if limit_order is not None:
        limit_order.binance_stop_order_id = order.binance_stop_order_id
        limit_order.binance_stop_market_order_id = order.binance_stop_market_order_id
        limit_order.save(update_fields=["binance_stop_order_id", "binance_stop_market_order_id", "updated_at"])

    if snapshot and size_changed and resolved_pos_mode:
        try:
            _rebuild_take_profit_for_remaining_position(
                client,
                order,
                resolved_pos_mode,
                exchange_size=effective_fill_size,
            )
        except Exception as exc:  # noqa: BLE001
            # The strategy stays bound: the periodic strategy engine retries
            # take-profit placement. Silently dropping to manual management
            # would leave a mandatory-strategy position without its TP.
            _log_strategy(
                order,
                snapshot,
                "策略预挂止盈失败，策略保持运行，后台引擎将继续重试",
                OrderStrategyLog.RESULT_FAILED,
                str(exc),
            )

    if created:
        enqueue_open_notification(order)
        logger.info("%s创建持仓订单 order=%s exchange_order=%s", source_label, order.id, binance_order_id)
    return EntryRiskAdoption(
        order=order,
        created=created,
        size_changed=size_changed,
        stop_loss_error=stop_loss_error,
    )


def sync_all_pending_limit_orders(*, trading_mode=TradingMode.ORDINARY, user_id=None):
    """
    同步所有待成交的限价委托单状态
    供定时任务调用
    """
    cache_lock_key = "sync_limit_orders:lock"
    db_lock_key = "sync_limit_orders_db_lock"
    if user_id is not None:
        cache_lock_key += f":user:{int(user_id)}"
        db_lock_key += f"_u{int(user_id)}"
    if trading_mode == TradingMode.LEAD:
        cache_lock_key += ":lead"
        db_lock_key += "_lead"

    with _acquire_db_lock(db_lock_key) as db_locked:
        if not db_locked:
            return 0

        cache_locked = cache.add(cache_lock_key, "1", timeout=4)
        if not cache_locked:
            return 0

        try:
            pending_orders = LimitOrder.objects.filter(status=LimitOrder.STATUS_PENDING, trading_mode=trading_mode)
            if user_id is not None:
                pending_orders = pending_orders.filter(user_id=user_id)
            updated_count = 0

            for limit_order in pending_orders:
                try:
                    if sync_limit_order_status(limit_order):
                        updated_count += 1
                except Exception as exc:
                    if is_binance_rate_limit_error(exc):
                        logger.warning(
                            "限价委托单同步触发限频 order=%s err=%s",
                            limit_order.id,
                            safe_error_summary(exc),
                        )
                        if exc.account_rate_limited:
                            continue
                        break
                    logger.error(
                        "同步限价委托单异常 %s: %s",
                        limit_order.id,
                        safe_error_summary(exc),
                    )

            if updated_count > 0:
                logger.info(f"同步限价委托单完成，更新 {updated_count} 条")

            return updated_count
        finally:
            cache.delete(cache_lock_key)


def _retry_exchange_call(
    fn,
    *args,
    retry_label: str = "",
    retry_context: Optional[dict[str, Any]] = None,
    **kwargs,
):
    """Retry transient failures for idempotent exchange reads only."""
    last_error: Optional[Exception] = None
    interface_name = getattr(fn, "__name__", fn.__class__.__name__)
    action_name = retry_label or interface_name
    meta = retry_context or {}
    for idx, delay in enumerate((1, 2, 4), start=1):
        try:
            return fn(*args, **kwargs)
        except Exception as exc:  # noqa: BLE001
            last_error = exc
            if _is_rate_limit_error_text(str(exc)):
                observed_egress_ip = detect_public_egress_ip()
                logger.warning(
                    "exchange_rate_limit action=%s interface=%s attempt=%s final=True next_delay=0 user=%s order=%s symbol=%s inst_id=%s observed_egress_ip=%s err=%s",
                    action_name,
                    interface_name,
                    idx,
                    meta.get("user_id", ""),
                    meta.get("order_id", ""),
                    meta.get("symbol", ""),
                    meta.get("inst_id", ""),
                    observed_egress_ip,
                    safe_error_summary(exc),
                )
                # 限频/BAN 不重试：重试会放大请求量并延长封禁，直接快速失败
                break
            if (
                isinstance(exc, BinanceApiError)
                and not exc.outcome_unknown
                and str(exc.code or "").strip() not in TRANSIENT_BINANCE_READ_ERROR_CODES
                and not _is_technical_failure_error_text(str(exc))
            ):
                break
            if idx == 3:
                break
            time.sleep(delay)
    if last_error is None:
        raise RuntimeError("调用失败")
    raise last_error


def _resolve_pos_side_from_mode(side_code: int, pos_mode: str) -> Optional[str]:
    if pos_mode == "long_short_mode":
        return "long" if side_code == 0 else "short"
    return None


SHARED_POSITIONS_CACHE_TTL_SECONDS = 10
SHARED_OPEN_ALGO_CACHE_TTL_SECONDS = 10


def load_shared_exchange_positions(
    client: BinanceFuturesClient,
    account_identity: str | int,
    *,
    retry_label: str = "shared_load_positions",
    budget_priority: RequestPriority | str | None = None,
) -> list[dict[str, Any]]:
    """跨任务共享的交易所持仓快照（与持仓列表同一缓存 key，10 秒 TTL），
    避免策略引擎/订单保护/页面轮询在几秒内重复拉 positionRisk。"""
    key = position_cache_key("exchange_rows", account_identity)
    rows = cache.get(key)
    if isinstance(rows, list):
        return rows
    payload = _retry_exchange_call(
        client.get_positions,
        "SWAP",
        budget_priority=budget_priority,
        retry_label=retry_label,
        retry_context=_build_retry_context(),
    )
    rows = payload.get("data") or []
    if isinstance(rows, list):
        cache.set(key, rows, timeout=SHARED_POSITIONS_CACHE_TTL_SECONDS)
        return rows
    return []


def load_shared_open_algo_rows(
    client: BinanceFuturesClient,
    account_identity: str | int,
    inst_ids: Iterable[str],
    *,
    retry_label: str = "shared_load_open_algo_orders",
    budget_priority: RequestPriority | str | None = None,
) -> list[dict[str, Any]]:
    """按当前持仓币种共享条件单快照，避免调用高权重的全账户查询。"""
    symbols = sorted({to_inst_id(inst_id) for inst_id in inst_ids if str(inst_id or "").strip()})
    if not symbols:
        return []

    key = position_cache_key("open_algo_rows", account_identity)
    now = time.time()
    cached = cache.get(key)
    entries = cached.get("entries") if isinstance(cached, dict) else None
    if not isinstance(entries, dict):
        entries = {}

    result: list[dict[str, Any]] = []
    changed = False
    for inst_id in symbols:
        entry = entries.get(inst_id)
        loaded_at = entry.get("loaded_at") if isinstance(entry, dict) else None
        rows = entry.get("rows") if isinstance(entry, dict) else None
        try:
            cache_fresh = isinstance(rows, list) and now - float(loaded_at) < SHARED_OPEN_ALGO_CACHE_TTL_SECONDS
        except (TypeError, ValueError):
            cache_fresh = False

        if not cache_fresh:
            payload = _retry_exchange_call(
                client.get_pending_algo_orders,
                ord_type="conditional",
                inst_type="SWAP",
                inst_id=inst_id,
                budget_priority=budget_priority,
                retry_label=retry_label,
                retry_context=_build_retry_context(inst_id=inst_id),
            )
            rows = payload.get("data") if isinstance(payload, dict) else None
            if not isinstance(rows, list):
                raise BinanceApiError("条件单列表返回格式无效")
            entries[inst_id] = {"loaded_at": now, "rows": rows}
            changed = True

        result.extend(row for row in rows if isinstance(row, dict))

    if changed:
        cache.set(
            key,
            {"entries": entries},
            timeout=SHARED_OPEN_ALGO_CACHE_TTL_SECONDS,
        )
    return result


def _load_pos_mode(
    client: BinanceFuturesClient,
    *,
    retry_label: str = "",
    retry_context: Optional[dict[str, Any]] = None,
    budget_priority: RequestPriority | str | None = None,
) -> str:
    payload = _retry_exchange_call(
        client.get_account_config,
        budget_priority=budget_priority,
        retry_label=retry_label or "load_pos_mode",
        retry_context=retry_context,
    )
    rows = payload.get("data") or []
    return str((rows[0] if rows else {}).get("posMode") or "long_short_mode")


def _find_position_size(order: Order, positions: list[dict[str, Any]], pos_mode: str) -> Decimal:
    row = _find_position_row(order, positions, pos_mode)
    if not row:
        return Decimal("0")
    return abs(_parse_decimal(row.get("pos") or "0"))


def _find_position_row(order: Order, positions: list[dict[str, Any]], pos_mode: str) -> Optional[dict[str, Any]]:
    inst_id = to_inst_id(order.symbol)
    if pos_mode == "long_short_mode":
        target_pos_side = "long" if order.side == 0 else "short"
        for row in positions:
            if row.get("instId") != inst_id:
                continue
            if str(row.get("posSide") or "") != target_pos_side:
                continue
            return row
        return None

    for row in positions:
        if row.get("instId") != inst_id:
            continue
        pos_val = _parse_decimal(row.get("pos") or "0")
        if pos_val == 0:
            continue
        if order.side == 0 and pos_val > 0:
            return row
        if order.side == 1 and pos_val < 0:
            return row
    return None


def _build_algo_client_id(order: Order, kind: str, suffix: str = "") -> str:
    return build_managed_algo_client_id(order, kind, suffix)


STOP_LOSS_PROTECTION_PENDING_DESC = "止损保护待恢复"
STOP_LOSS_PROTECTION_RECOVERED_DESC = "止损保护已恢复"
MANUAL_TP_SL_MANAGEMENT_ERROR = "用户已取消自动止盈止损，改为手动管理"


def _sync_order_exchange_size(
    order: Order,
    exchange_size: Decimal,
    *,
    current_price: Optional[Decimal] = None,
) -> bool:
    normalized_size = exchange_size if exchange_size > 0 else Decimal("0")
    previous_size = abs(order.exchange_size if order.exchange_size is not None else order.size or Decimal("0"))
    has_manual_addition = bool(order.size and normalized_size > order.size + POSITION_SIZE_TOLERANCE)
    previous_exchange_size = order.exchange_size
    previous_manual_addition = order.has_manual_addition
    update_fields: list[str] = []
    if order.exchange_size != normalized_size:
        order.exchange_size = normalized_size
        update_fields.append("exchange_size")
    if bool(order.has_manual_addition) != has_manual_addition:
        order.has_manual_addition = has_manual_addition
        update_fields.append("has_manual_addition")
    if not update_fields:
        return False
    try:
        with transaction.atomic():
            order.save(update_fields=update_fields)
            if order.status == 0 and normalized_size + POSITION_SIZE_TOLERANCE < previous_size:
                enqueue_reduction_notification(
                    order,
                    previous_size=previous_size,
                    remaining_size=normalized_size,
                    execution_price=current_price,
                    persist_now=True,
                )
    except Exception:
        order.exchange_size = previous_exchange_size
        order.has_manual_addition = previous_manual_addition
        raise
    return True


def finalize_confirmed_emergency_close(
    order: Order,
    client: BinanceFuturesClient,
    *,
    close_payload: Optional[dict] = None,
    trigger_price: Optional[Decimal] = None,
) -> None:
    """Persist the local terminal state after the exchange confirms no position."""
    order.status = 1
    order.closed_at = timezone.now()
    order.stop_protection_status = Order.STOP_PROTECTION_EMERGENCY
    order.stop_protection_error = "止损保护缺失且价格已触及止损，交易所已确认仓位平清"
    close_rows = (close_payload or {}).get("data") or []
    if close_rows and isinstance(close_rows[0], dict):
        close_row = close_rows[0]
        order.close_binance_order_id = str(close_row.get("ordId") or "").strip()
        close_price = _parse_decimal(close_row.get("avgPx") or close_row.get("fillPx") or "0")
        if close_price > 0:
            order.close_price = close_price
    order.settlement_status = Order.SETTLEMENT_STATUS_PENDING
    order.settled_at = None
    order.settlement_error = ""
    order.settlement_retry_count = 0
    order.settlement_next_retry_at = None
    order.exchange_size = Decimal("0")
    order.has_manual_addition = False
    persisted = persist_confirmed_close_transition(
        order,
        notification={
            "event_type": TradeNotificationEvent.TYPE_STOP_LOSS,
            "trigger_price": trigger_price or order.current_stop_price or order.stop_loss_price,
        },
        update_fields=[
            "status",
            "closed_at",
            "stop_protection_status",
            "stop_protection_error",
            "close_binance_order_id",
            "close_price",
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
        return
    cleanup_result = best_effort_cleanup_closed_order_exchange_artifacts(
        order,
        client,
        action_prefix="emergency_close_cleanup",
    )
    persist_closed_order_cleanup_result(order, cleanup_result)


def _load_order_close_trade_rows(
    client: BinanceFuturesClient,
    order: Order,
    *,
    trade_cache: Optional[dict[int, list[dict[str, Any]]]] = None,
) -> list[dict[str, Any]]:
    if trade_cache is not None and order.id in trade_cache:
        return trade_cache[order.id]

    rows = fetch_order_trade_rows(order, client, end_at=timezone.now(), limit=1000)
    if not isinstance(rows, list):
        rows = []
    if trade_cache is not None:
        trade_cache[order.id] = rows
    return rows


# "仓位是否已被交易所侧抵消"检测只是兜底：平仓回执/陈旧订单修正等主路径会先行更新状态。
# 它触发的 userTrades 拉取权重很高，每单限频到最多 30 秒一次，避免限频。
FULLY_OFFSET_CHECK_INTERVAL_SECONDS = 30


def _fully_offset_check_due(order: Order) -> bool:
    key = f"order:fully_offset_check:{order.id}"
    if cache.get(key):
        return False
    cache.set(key, "1", timeout=FULLY_OFFSET_CHECK_INTERVAL_SECONDS)
    return True


def _close_fully_offset_order(
    order: Order,
    client: BinanceFuturesClient,
    *,
    source: str,
    trade_cache: Optional[dict[int, list[dict[str, Any]]]] = None,
) -> bool:
    if not _fully_offset_check_due(order):
        return False
    trade_rows = _load_order_close_trade_rows(client, order, trade_cache=trade_cache)
    anchor = build_close_anchor_from_trade_rows(order, trade_rows)
    if not anchor or not anchor.get("is_fully_closed"):
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
        return False
    cleanup_result = best_effort_cleanup_closed_order_exchange_artifacts(
        order,
        client,
        action_prefix=f"{source}_fully_offset_cleanup",
    )
    persist_closed_order_cleanup_result(order, cleanup_result)
    logger.info(
        "%s auto_closed_fully_offset_order user=%s order=%s symbol=%s close_order=%s",
        source,
        order.user_id,
        order.id,
        order.symbol,
        order.close_binance_order_id,
    )
    return True


def _place_stop_market_verified(
    client: BinanceFuturesClient,
    inst_id: str,
    close_side: str,
    size: Decimal,
    trigger_price: Decimal,
    pos_side: Optional[str],
    order: Optional[Order] = None,
    retry_context: Optional[dict[str, Any]] = None,
    retry_label: str = "",
    client_id_suffix: str = "",
    visibility_mode: str = ALGO_VISIBILITY_ALLOW_DELAYED,
) -> str:
    algo_client = BinanceAlgoClient(client, log=logger)
    return algo_client.create_stop_market(
        inst_id=inst_id,
        side=close_side,
        size=format(size, "f"),
        trigger_price=format(trigger_price, "f"),
        pos_side=pos_side,
        client_algo_id=_build_algo_client_id(order, "slm", client_id_suffix) if order else None,
        visibility_mode=visibility_mode,
        action=retry_label or "rebuild_stop_market_stop_loss",
    )


def _place_stop_loss_protection_verified(
    client: BinanceFuturesClient,
    inst_id: str,
    close_side: str,
    size: Decimal,
    stop_loss_price: Decimal,
    pos_side: Optional[str],
    order: Optional[Order] = None,
    retry_context: Optional[dict[str, Any]] = None,
    retry_label: str = "",
    entry_price: Optional[Decimal] = None,
    client_id_suffix: str = "",
    visibility_mode: str = ALGO_VISIBILITY_ALLOW_DELAYED,
) -> tuple[str, str]:
    """Create the single protective STOP_MARKET order."""
    market_id = _place_stop_market_verified(
        client, inst_id, close_side, size, stop_loss_price, pos_side,
        order=order, retry_context=retry_context,
        retry_label=retry_label or "create_stop_market_stop_loss",
        client_id_suffix=client_id_suffix,
        visibility_mode=visibility_mode,
    )
    return "", market_id


def _stop_loss_algo_candidates(
    algo_rows: list[dict[str, Any]],
    *,
    inst_id: str,
    close_side: str,
    pos_side: Optional[str],
) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for row in algo_rows:
        if not isinstance(row, dict):
            continue
        if str(row.get("state") or "live") != "live":
            continue
        if str(row.get("algoType") or "") not in {"STOP", "STOP_MARKET"}:
            continue
        if str(row.get("instId") or "") != inst_id:
            continue
        if str(row.get("side") or "").lower() != str(close_side or "").lower():
            continue
        if pos_side and str(row.get("posSide") or "").lower() != str(pos_side).lower():
            continue
        result.append(row)
    return result


def _stop_loss_algo_matches(row: dict[str, Any], *, stop_price: Decimal, size: Decimal) -> bool:
    algo_size = abs(_parse_decimal(row.get("sz") or "0"))
    algo_stop = _parse_decimal(row.get("slTriggerPx") or "0")
    size_ok = abs(algo_size - size) <= POSITION_SIZE_TOLERANCE
    price_ok = algo_stop > 0 and abs(algo_stop - stop_price) <= POSITION_SIZE_TOLERANCE
    return size_ok and price_ok


def _cancel_stop_loss_candidates(
    client: BinanceFuturesClient,
    *,
    inst_id: str,
    candidates: list[dict[str, Any]],
    keep_algo_id: str = "",
    action: str,
) -> None:
    if not candidates:
        return
    algo_client = BinanceAlgoClient(client, log=logger)
    for row in candidates:
        algo_id = str(row.get("algoId") or "")
        if not algo_id or algo_id == keep_algo_id:
            continue
        try:
            algo_client.cancel_algo_confirmed(algo_id=algo_id, inst_id=inst_id, action=action)
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "cancel duplicate stop-loss failed algo_id=%s inst_id=%s err=%s",
                algo_id,
                inst_id,
                safe_error_summary(exc),
            )


def _cancel_algo_ids_once(
    client: BinanceFuturesClient,
    *,
    inst_id: str,
    algo_ids: list[str],
    action: str,
) -> list[str]:
    if not algo_ids:
        return []
    algo_client = BinanceAlgoClient(client, log=logger)
    unresolved: list[str] = []
    for algo_id in algo_ids:
        current_id = str(algo_id or "")
        if not current_id:
            continue
        try:
            algo_client.cancel_algo_confirmed(algo_id=current_id, inst_id=inst_id, action=action)
        except Exception as exc:  # noqa: BLE001
            unresolved.append(current_id)
            logger.warning(
                "cancel algo failed algo_id=%s inst_id=%s action=%s err=%s",
                current_id,
                inst_id,
                action,
                safe_error_summary(exc),
            )
    return unresolved


def _load_open_algo_rows(
    client: BinanceFuturesClient,
    inst_id: str,
    *,
    retry_label: str = "",
    retry_context: Optional[dict[str, Any]] = None,
) -> list[dict[str, Any]]:
    return (
        _retry_exchange_call(
            client.get_pending_algo_orders,
            ord_type="conditional",
            inst_type="SWAP",
            inst_id=inst_id,
            budget_priority=RequestPriority.CRITICAL,
            retry_label=retry_label or "load_open_algo_orders",
            retry_context=retry_context,
        ).get("data")
        or []
    )


def _normalize_stop_loss_request(
    *,
    order: Order,
    inst_id: str,
    stop_price: Decimal,
    size: Decimal,
    current_price: Decimal,
) -> dict[str, Decimal]:
    rules = _get_instrument_trade_rules(inst_id)
    standardized = standardize_trigger_order_request(
        trigger_price=stop_price,
        quantity=size,
        instrument={
            "tickSz": format(rules["tickSz"], "f"),
            "marketLotSz": format(rules["marketLotSz"] if rules["marketLotSz"] > 0 else size, "f"),
            "marketMinSz": format(rules["marketMinSz"], "f"),
            "minNotional": "0",
            "triggerProtect": "0",
        },
        trigger_kind="stop_loss",
        position_side="long" if order.side == 0 else "short",
        reference_price=current_price if current_price > 0 else None,
    )
    return {
        "stop_price": standardized["trigger_price"],
        "size": standardized["quantity"],
    }


def _converge_stop_loss_order(
    client: BinanceFuturesClient,
    order: Order,
    *,
    exchange_size: Decimal,
    stop_price: Decimal,
    pos_mode: str,
    current_price: Decimal,
    algo_rows: Optional[list[dict[str, Any]]] = None,
    action: str = "converge_stop_loss",
    retry_context: Optional[dict[str, Any]] = None,
) -> bool:
    if exchange_size <= 0 or stop_price <= 0:
        return False
    inst_id = to_inst_id(order.symbol)
    close_side = "sell" if order.side == 0 else "buy"
    pos_side = _resolve_pos_side_from_mode(order.side, pos_mode)
    current_id = str(order.binance_stop_order_id or "")
    current_market_id = str(order.binance_stop_market_order_id or "")
    if (
        action == "rebuild_stop_loss"
        and current_market_id
        and order.stop_loss_order_created_at
        and abs(exchange_size - order.size) <= POSITION_SIZE_TOLERANCE
    ):
        age_seconds = (timezone.now() - order.stop_loss_order_created_at).total_seconds()
        if age_seconds < STOP_LOSS_VISIBILITY_GRACE_SECONDS:
            logger.info(
                "%s defer stop-loss rebuild during visibility grace order=%s symbol=%s algo_id=%s age_seconds=%s",
                action,
                order.id,
                order.symbol,
                current_id,
                int(age_seconds),
            )
            return False
    normalized = _normalize_stop_loss_request(
        order=order,
        inst_id=inst_id,
        stop_price=stop_price,
        size=exchange_size,
        current_price=current_price,
    )
    target_stop = normalized["stop_price"]
    target_size = normalized["size"]
    if target_size <= 0:
        return False

    open_algos = algo_rows if algo_rows is not None else _load_open_algo_rows(
        client,
        inst_id,
        retry_label=f"{action}_load_open_algo_orders",
        retry_context=retry_context,
    )
    candidates = _stop_loss_algo_candidates(
        open_algos,
        inst_id=inst_id,
        close_side=close_side,
        pos_side=pos_side,
    )
    primary_candidates = [row for row in candidates if str(row.get("algoType") or "") == "STOP"]
    market_candidates = [row for row in candidates if str(row.get("algoType") or "") == "STOP_MARKET"]
    correct_market = [row for row in market_candidates if _stop_loss_algo_matches(row, stop_price=target_stop, size=target_size)]
    keep_market = next((row for row in correct_market if str(row.get("algoId") or "") == current_market_id), None) or (correct_market[0] if correct_market else None)

    changed = False
    update_fields: list[str] = []
    if keep_market:
        keep_market_id = str(keep_market.get("algoId") or "")
        _cancel_stop_loss_candidates(
            client,
            inst_id=inst_id,
            candidates=primary_candidates,
            action=f"{action}_cancel_limit_stop",
        )
        _cancel_stop_loss_candidates(
            client,
            inst_id=inst_id,
            candidates=market_candidates,
            keep_algo_id=keep_market_id,
            action=f"{action}_cancel_duplicate_market_stop",
        )
        if current_id:
            order.binance_stop_order_id = ""
            update_fields.append("binance_stop_order_id")
            changed = True
        if keep_market_id and keep_market_id != current_market_id:
            order.binance_stop_market_order_id = keep_market_id
            order.stop_loss_order_created_at = timezone.now()
            update_fields.extend(["binance_stop_market_order_id", "stop_loss_order_created_at"])
            changed = True
        if order.current_stop_price != target_stop or order.stop_loss_price != target_stop:
            order.current_stop_price = target_stop
            order.stop_loss_price = target_stop
            update_fields.extend(["current_stop_price", "stop_loss_price"])
            changed = True
        if update_fields:
            order.save(update_fields=list(dict.fromkeys(update_fields)))
        return changed

    # A stale stop still protects the position. Create and verify the replacement
    # before cancelling it so a failed replacement never opens a protection gap.
    replacement_key = f"{format(target_stop, 'f')}:{format(target_size, 'f')}"
    replacement_suffix = f"r{hashlib.sha256(replacement_key.encode()).hexdigest()[:8]}"
    algo_id, market_algo_id = _place_stop_loss_protection_verified(
        client=client,
        inst_id=inst_id,
        close_side=close_side,
        size=target_size,
        stop_loss_price=target_stop,
        pos_side=pos_side,
        order=order,
        retry_context=retry_context,
        retry_label=f"{action}_create_stop_loss",
        client_id_suffix=replacement_suffix,
        visibility_mode=ALGO_VISIBILITY_REQUIRE_VISIBLE if candidates else ALGO_VISIBILITY_ALLOW_DELAYED,
    )
    order.binance_stop_order_id = algo_id
    order.binance_stop_market_order_id = market_algo_id
    order.stop_loss_order_created_at = timezone.now() if market_algo_id else None
    order.current_stop_price = target_stop
    order.stop_loss_price = target_stop
    order.save(
        update_fields=[
            "binance_stop_order_id",
            "binance_stop_market_order_id",
            "stop_loss_order_created_at",
            "current_stop_price",
            "stop_loss_price",
        ]
    )
    _cancel_stop_loss_candidates(
        client,
        inst_id=inst_id,
        candidates=candidates,
        keep_algo_id=market_algo_id or algo_id,
        action=f"{action}_cancel_stale",
    )
    if action != "strategy_move_stop_loss":
        record_operation(
            order,
            action="stop_protection",
            status="success" if candidates else "pending",
            message=(
                f"已确认替换止损保护：触发价 {target_stop.normalize():f}，数量 {target_size.normalize():f}"
                if candidates
                else f"止损挂单已受理，等待保护核对：触发价 {target_stop.normalize():f}，数量 {target_size.normalize():f}"
            ),
        )
    return True


def _take_profit_algo_candidates(
    algo_rows: list[dict[str, Any]],
    *,
    inst_id: str,
    close_side: str,
    pos_side: Optional[str],
) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for row in algo_rows:
        if not isinstance(row, dict):
            continue
        if str(row.get("state") or "live") != "live":
            continue
        if str(row.get("algoType") or "") != "TAKE_PROFIT_MARKET":
            continue
        if str(row.get("instId") or "") != inst_id:
            continue
        if str(row.get("side") or "").lower() != str(close_side or "").lower():
            continue
        if pos_side and str(row.get("posSide") or "").lower() != str(pos_side).lower():
            continue
        result.append(row)
    return result


def _take_profit_algo_matches(row: dict[str, Any], *, trigger_price: Decimal, size: Decimal) -> bool:
    algo_size = abs(_parse_decimal(row.get("sz") or "0"))
    algo_trigger = _parse_decimal(row.get("tpTriggerPx") or "0")
    size_ok = abs(algo_size - size) <= POSITION_SIZE_TOLERANCE
    price_ok = algo_trigger > 0 and abs(algo_trigger - trigger_price) <= POSITION_SIZE_TOLERANCE
    return size_ok and price_ok


def _build_take_profit_targets(order: Order, snapshot: OrderStrategySnapshot) -> list[dict[str, Any]]:
    levels = _get_strategy_levels(snapshot)
    if not levels:
        return []
    inst_id = to_inst_id(order.symbol)
    rules = _get_instrument_trade_rules(inst_id)
    market_lot_sz = rules["marketLotSz"] if rules["marketLotSz"] > 0 else rules["lotSz"]
    market_min_sz = rules["marketMinSz"] if rules["marketMinSz"] > 0 else rules["minSz"]
    targets: list[dict[str, Any]] = []

    for level_idx, level in enumerate(levels, start=1):
        reduce_pct = level["reduce_position"]
        trigger_rr = level["profit_rr"]
        if reduce_pct <= 0 or trigger_rr <= 0:
            continue
        reduce_size = (order.size * reduce_pct / Decimal("100")).quantize(Decimal("0.00000001"))
        if market_lot_sz > 0:
            reduce_size = quantize_down(reduce_size, market_lot_sz)
        if reduce_size <= 0 or (market_min_sz > 0 and reduce_size < market_min_sz):
            continue
        standardized_trigger = standardize_trigger_order_request(
            trigger_price=_calc_take_profit_trigger_price(order, trigger_rr),
            quantity=reduce_size,
            instrument={
                "tickSz": format(rules["tickSz"], "f"),
                "marketLotSz": format(market_lot_sz, "f"),
                "marketMinSz": format(market_min_sz, "f"),
                "minNotional": "0",
                "triggerProtect": "0",
            },
            trigger_kind="take_profit",
            position_side="long" if order.side == 0 else "short",
            reference_price=order.open_price,
        )
        targets.append(
            {
                "level_idx": level_idx,
                "trigger_rr": trigger_rr,
                "size": standardized_trigger["quantity"],
                "trigger_price": standardized_trigger["trigger_price"],
            }
        )
    return targets


@contextmanager
def _acquire_db_lock(lock_name: str):
    """
    使用数据库级强锁兜底，避免本地内存缓存场景下多进程重复执行。
    - MySQL: GET_LOCK / RELEASE_LOCK
    - 其他数据库: 视为无强锁（兼容本地测试）
    """
    locked = False
    try:
        if connection.vendor == "mysql":
            with connection.cursor() as cursor:
                cursor.execute("SELECT GET_LOCK(%s, 0)", [lock_name])
                row = cursor.fetchone()
                locked = bool(row and row[0] == 1)
        else:
            locked = True
        yield locked
    finally:
        if locked and connection.vendor == "mysql":
            try:
                with connection.cursor() as cursor:
                    cursor.execute("SELECT RELEASE_LOCK(%s)", [lock_name])
            except Exception:
                pass


def _parse_decimal(value: Any) -> Decimal:
    try:
        return Decimal(str(value))
    except Exception:
        return Decimal("0")


def _get_instrument_trade_rules(inst_id: str) -> dict[str, Decimal]:
    """
    获取 Binance 合约交易规则。
    失败时返回 0 值，由调用方降级处理。
    """
    cache_key = f"trade:inst_rules:{inst_id}"
    cached = cache.get(cache_key)
    if isinstance(cached, dict):
        return {
            "lotSz": _parse_decimal(cached.get("lotSz")),
            "minSz": _parse_decimal(cached.get("minSz")),
            "marketLotSz": _parse_decimal(cached.get("marketLotSz")),
            "marketMinSz": _parse_decimal(cached.get("marketMinSz")),
            "tickSz": _parse_decimal(cached.get("tickSz")),
        }

    try:
        payload = binance_get_instruments(inst_type="SWAP", inst_id=inst_id)
        rows = payload.get("data") or []
        row = rows[0] if rows else {}
        rules = {
            "lotSz": _parse_decimal(row.get("lotSz") or "0"),
            "minSz": _parse_decimal(row.get("minSz") or "0"),
            "marketLotSz": _parse_decimal(row.get("marketLotSz") or row.get("lotSz") or "0"),
            "marketMinSz": _parse_decimal(row.get("marketMinSz") or row.get("minSz") or "0"),
            "tickSz": _parse_decimal(row.get("tickSz") or "0"),
        }
        cache.set(
            cache_key,
            {key: format(value, "f") for key, value in rules.items()},
            timeout=300,
        )
        return rules
    except Exception:
        return {
            "lotSz": Decimal("0"),
            "minSz": Decimal("0"),
            "marketLotSz": Decimal("0"),
            "marketMinSz": Decimal("0"),
            "tickSz": Decimal("0"),
        }


def _get_strategy_levels(snapshot: OrderStrategySnapshot) -> list[dict[str, Any]]:
    raw = snapshot.strategy_config
    if not isinstance(raw, list):
        return []
    levels: list[dict[str, Any]] = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        level = {
            "profit_rr": _parse_decimal(item.get("profitRR", 0)),
            "reduce_position": _parse_decimal(item.get("reducePosition", 0)),
            "stop_loss_type": str(item.get("stopLossType") or "none"),
            "stop_loss_rr": _parse_decimal(item.get("stopLossRR", 0)),
            "stop_loss_absolute_rr": _parse_decimal(item.get("stopLossAbsoluteRR", 0)),
        }
        if level["profit_rr"] <= 0:
            continue
        levels.append(level)
    levels.sort(key=lambda x: x["profit_rr"])
    return levels


def _calc_take_profit_trigger_price(order: Order, profit_rr: Decimal) -> Decimal:
    initial_stop = order.initial_stop_price or order.stop_loss_price
    base_r = abs(order.open_price - initial_stop)
    if base_r <= 0:
        return order.open_price
    if order.side == 0:
        return order.open_price + profit_rr * base_r
    return order.open_price - profit_rr * base_r


def _get_current_extreme(
    client: BinanceFuturesClient,
    symbol: str,
    side: int,
    *,
    retry_label: str = "",
    retry_context: Optional[dict[str, Any]] = None,
) -> tuple[Decimal, Decimal]:
    inst_id = to_inst_id(symbol)
    payload = _retry_exchange_call(
        client.get_mark_price_candles,
        inst_id,
        "1m",
        1,
        retry_label=retry_label or "load_mark_price_candles",
        retry_context=retry_context,
    )
    rows = payload.get("data") or []
    if not rows:
        raise BinanceApiError("未获取到K线数据")
    # Legacy candle shape: [ts, open, high, low, close, ...]
    row = rows[0]
    high = _parse_decimal(row[2] if len(row) > 2 else "0")
    low = _parse_decimal(row[3] if len(row) > 3 else "0")
    close = _parse_decimal(row[4] if len(row) > 4 else "0")
    return (high if side == 0 else low), close


def _calc_trigger_price(order: Order, profit_rr: Decimal) -> Decimal:
    initial_stop = order.initial_stop_price or order.stop_loss_price
    base_r = abs(order.open_price - initial_stop)
    if base_r <= 0:
        return order.open_price
    if order.side == 0:
        return order.open_price + profit_rr * base_r
    return order.open_price - profit_rr * base_r


def _calc_candidate_stop(order: Order, extreme_price: Decimal, move_rr: Decimal) -> Decimal:
    initial_stop = order.initial_stop_price or order.stop_loss_price
    current_stop = order.current_stop_price or order.stop_loss_price
    base_r = abs(order.open_price - initial_stop)
    if base_r <= 0:
        return current_stop or order.stop_loss_price
    if order.side == 0:
        return extreme_price - move_rr * base_r
    return extreme_price + move_rr * base_r


def _calc_absolute_stop(order: Order, absolute_rr: Decimal) -> Decimal:
    initial_stop = order.initial_stop_price or order.stop_loss_price
    base_r = abs(order.open_price - initial_stop)
    if base_r <= 0:
        return order.current_stop_price or order.stop_loss_price
    if order.side == 0:
        return order.open_price + absolute_rr * base_r
    return order.open_price - absolute_rr * base_r


def _select_next_level(snapshot: OrderStrategySnapshot) -> Optional[Tuple[int, dict[str, Any], bool, bool]]:
    levels = _get_strategy_levels(snapshot)
    if not levels:
        return None
    for idx, level in enumerate(levels, start=1):
        trigger_rr = level["profit_rr"]
        level_logs = OrderStrategyLog.objects.filter(
            snapshot=snapshot,
            trigger_r=trigger_rr,
        )
        # 减仓改为开仓时预挂，这里不再依赖减仓执行日志推进层级
        reduce_done = True
        move_required = (
            (level["stop_loss_type"] == "fixedRR" and level["stop_loss_rr"] > 0)
            or (level["stop_loss_type"] == "absoluteRR" and level["stop_loss_absolute_rr"] > Decimal("-1"))
        )
        move_done = level_logs.filter(
            result=OrderStrategyLog.RESULT_SUCCESS,
            behavior_desc__startswith=f"L{idx} 止损移动到",
        ).exists()

        if not reduce_done or (move_required and not move_done):
            return idx, level, reduce_done, move_done
    return None


def _latest_completed_fixed_rr_level(snapshot: OrderStrategySnapshot) -> Optional[Tuple[int, dict[str, Any]]]:
    trailing_level: Optional[Tuple[int, dict[str, Any]]] = None
    for idx, level in enumerate(_get_strategy_levels(snapshot), start=1):
        if level["stop_loss_type"] != "fixedRR" or level["stop_loss_rr"] <= 0:
            continue
        trigger_rr = level["profit_rr"]
        reached = OrderStrategyLog.objects.filter(
            snapshot=snapshot,
            trigger_r=trigger_rr,
            result=OrderStrategyLog.RESULT_SUCCESS,
            behavior_desc__startswith=f"L{idx} 达到",
        ).exists()
        moved = OrderStrategyLog.objects.filter(
            snapshot=snapshot,
            trigger_r=trigger_rr,
            result=OrderStrategyLog.RESULT_SUCCESS,
            behavior_desc__startswith=f"L{idx} 止损移动到",
        ).exists()
        if reached and moved:
            trailing_level = (idx, level)
    return trailing_level


def _log_strategy(
    order: Order,
    snapshot: OrderStrategySnapshot,
    desc: str,
    result: str,
    error: str = "",
    trigger_r: Optional[Decimal] = None,
):
    if result == OrderStrategyLog.RESULT_FAILED and _is_technical_failure_error_text(error):
        _record_technical_strategy_event(order, snapshot, desc, error)
        logger.warning(
            "skip technical strategy log order=%s snapshot=%s desc=%s err=%s",
            order.id,
            snapshot.id,
            desc,
            safe_error_summary(error, include_type=False),
        )
        return
    normalized_error = safe_error_summary(error, include_type=False) if error else ""
    latest = (
        OrderStrategyLog.objects.filter(order=order, snapshot=snapshot)
        .order_by("-created_at")
        .first()
    )
    if (
        latest
        and latest.behavior_desc == desc
        and latest.result == result
        and (latest.error or "") == normalized_error
        and latest.trigger_r == trigger_r
    ):
        return
    OrderStrategyLog.objects.create(
        order=order,
        snapshot=snapshot,
        behavior_desc=desc,
        trigger_r=trigger_r,
        result=result,
        error=normalized_error or None,
    )


def _latest_stop_loss_protection_log(order: Order, snapshot: OrderStrategySnapshot) -> Optional[OrderStrategyLog]:
    return (
        OrderStrategyLog.objects.filter(
            order=order,
            snapshot=snapshot,
            behavior_desc__in=[STOP_LOSS_PROTECTION_PENDING_DESC, STOP_LOSS_PROTECTION_RECOVERED_DESC],
        )
        .order_by("-created_at")
        .first()
    )


def _mark_stop_loss_protection_pending(
    order: Order,
    snapshot: Optional[OrderStrategySnapshot],
    error: str,
) -> None:
    if snapshot is None:
        return
    normalized_error = safe_error_summary(error, include_type=False) if error else ""
    latest = _latest_stop_loss_protection_log(order, snapshot)
    if (
        latest
        and latest.behavior_desc == STOP_LOSS_PROTECTION_PENDING_DESC
        and (latest.error or "") == normalized_error
        and latest.result == OrderStrategyLog.RESULT_FAILED
    ):
        return
    OrderStrategyLog.objects.create(
        order=order,
        snapshot=snapshot,
        behavior_desc=STOP_LOSS_PROTECTION_PENDING_DESC,
        result=OrderStrategyLog.RESULT_FAILED,
        error=normalized_error or None,
    )


def _mark_stop_loss_protection_recovered(order: Order, snapshot: Optional[OrderStrategySnapshot]) -> None:
    if snapshot is None:
        return
    latest = _latest_stop_loss_protection_log(order, snapshot)
    if latest is None or latest.behavior_desc != STOP_LOSS_PROTECTION_PENDING_DESC:
        return
    OrderStrategyLog.objects.create(
        order=order,
        snapshot=snapshot,
        behavior_desc=STOP_LOSS_PROTECTION_RECOVERED_DESC,
        result=OrderStrategyLog.RESULT_SUCCESS,
    )


def _record_stop_protection_retry_failure(order: Order, error: str) -> None:
    now = timezone.now()
    first_failed_at = order.stop_protection_first_failed_at or now
    retry_count = int(order.stop_protection_retry_count or 0) + 1
    elapsed = (now - first_failed_at).total_seconds()
    alerted = retry_count >= STOP_PROTECTION_ALERT_RETRY_COUNT or elapsed >= STOP_PROTECTION_ALERT_AFTER_SECONDS
    order.stop_protection_first_failed_at = first_failed_at
    order.stop_protection_retry_count = retry_count
    order.stop_protection_last_retry_at = now
    order.stop_protection_status = Order.STOP_PROTECTION_ALERTED if alerted else Order.STOP_PROTECTION_PENDING
    safe_error = safe_error_summary(error, include_type=False)
    order.stop_protection_error = safe_error
    if alerted and order.stop_protection_alerted_at is None:
        order.stop_protection_alerted_at = now
        logger.error(
            "stop protection remains unavailable order=%s user=%s symbol=%s retries=%s elapsed=%ss err=%s",
            order.id,
            order.user_id,
            order.symbol,
            retry_count,
            int(elapsed),
            safe_error,
        )
    order.save(
        update_fields=[
            "stop_protection_first_failed_at",
            "stop_protection_retry_count",
            "stop_protection_last_retry_at",
            "stop_protection_status",
            "stop_protection_error",
            "stop_protection_alerted_at",
        ]
    )
    record_operation(
        order,
        action="stop_protection",
        status="pending",
        message=f"止损保护待恢复，系统将继续核对和重试：{safe_error}",
    )


def _stop_protection_retry_due(order: Order, *, now=None) -> bool:
    last_retry_at = order.stop_protection_last_retry_at
    retry_count = int(order.stop_protection_retry_count or 0)
    if retry_count <= 0 or last_retry_at is None:
        return True
    index = min(retry_count - 1, len(STOP_PROTECTION_RETRY_DELAYS_SECONDS) - 1)
    delay = STOP_PROTECTION_RETRY_DELAYS_SECONDS[index]
    return (now or timezone.now()) >= last_retry_at + timedelta(seconds=delay)


def _clear_stop_protection_failure(order: Order) -> None:
    order.stop_protection_status = Order.STOP_PROTECTION_COMPLETE
    order.stop_protection_error = ""
    order.stop_protection_first_failed_at = None
    order.stop_protection_retry_count = 0
    order.stop_protection_last_retry_at = None
    order.stop_protection_alerted_at = None
    order.save(
        update_fields=[
            "stop_protection_status",
            "stop_protection_error",
            "stop_protection_first_failed_at",
            "stop_protection_retry_count",
            "stop_protection_last_retry_at",
            "stop_protection_alerted_at",
        ]
    )


def setup_strategy_take_profit_orders(
    order: Order,
    snapshot: OrderStrategySnapshot,
    client: BinanceFuturesClient,
    pos_side: Optional[str],
) -> list[str]:
    levels = _get_strategy_levels(snapshot)
    inst_id = to_inst_id(order.symbol)
    close_side = "sell" if order.side == 0 else "buy"
    algo_ids: list[str] = []
    algo_client = BinanceAlgoClient(client, log=logger)
    rules = _get_instrument_trade_rules(inst_id)
    market_lot_sz = rules["marketLotSz"] if rules["marketLotSz"] > 0 else rules["lotSz"]
    market_min_sz = rules["marketMinSz"] if rules["marketMinSz"] > 0 else rules["minSz"]
    for idx, level in enumerate(levels, start=1):
        reduce_pct = level["reduce_position"]
        trigger_rr = level["profit_rr"]
        if reduce_pct <= 0 or trigger_rr <= 0:
            continue

        reduce_size = (order.size * reduce_pct / Decimal("100")).quantize(Decimal("0.00000001"))
        if market_lot_sz > 0:
            reduce_size = quantize_down(reduce_size, market_lot_sz)
        if reduce_size <= 0:
            _log_strategy(
                order,
                snapshot,
                f"L{idx} 预挂止盈跳过（减仓数量取整后为0）",
                OrderStrategyLog.RESULT_SKIPPED,
                trigger_r=trigger_rr,
            )
            continue
        if market_min_sz > 0 and reduce_size < market_min_sz:
            _log_strategy(
                order,
                snapshot,
                f"L{idx} 预挂止盈跳过（数量 {format(reduce_size, 'f')} 小于最小下单量 {format(market_min_sz, 'f')}）",
                OrderStrategyLog.RESULT_SKIPPED,
                trigger_r=trigger_rr,
            )
            continue

        standardized_trigger = standardize_trigger_order_request(
            trigger_price=_calc_take_profit_trigger_price(order, trigger_rr),
            quantity=reduce_size,
            instrument={
                "tickSz": format(rules["tickSz"], "f"),
                "marketLotSz": format(market_lot_sz, "f"),
                "marketMinSz": format(market_min_sz, "f"),
                "minNotional": "0",
                "triggerProtect": "0",
            },
            trigger_kind="take_profit",
            position_side="long" if order.side == 0 else "short",
            reference_price=order.open_price,
        )
        trigger_price = standardized_trigger["trigger_price"]
        try:
            client_id_key = f"{idx}:{format(trigger_price, 'f')}:{format(reduce_size, 'f')}"
            client_id_suffix = f"{idx}{hashlib.sha256(client_id_key.encode()).hexdigest()[:8]}"
            algo_id = algo_client.create_take_profit(
                inst_id=inst_id,
                side=close_side,
                size=format(reduce_size, "f"),
                trigger_price=format(trigger_price, "f"),
                pos_side=pos_side,
                client_algo_id=_build_algo_client_id(order, "tp", client_id_suffix),
                action=f"setup_take_profit_L{idx}",
            )
            if not algo_id:
                raise BinanceApiError("预挂止盈单失败")
            algo_ids.append(algo_id)
            # 预挂成功只记录技术动作，不代表该层已触发执行。
            _log_strategy(
                order,
                snapshot,
                f"预挂止盈单成功：目标 {format(trigger_rr, 'f')}R，减仓 {format(reduce_pct, 'f')}%",
                OrderStrategyLog.RESULT_SUCCESS,
            )
        except Exception:
            unresolved_ids = _cancel_algo_ids_once(
                client,
                inst_id=inst_id,
                algo_ids=algo_ids,
                action="setup_take_profit_rollback",
            )
            if unresolved_ids:
                order.strategy_tp_algo_ids = list(dict.fromkeys([
                    *(order.strategy_tp_algo_ids or []),
                    *unresolved_ids,
                ]))
                order.save(update_fields=["strategy_tp_algo_ids"])
            raise

    return algo_ids


def _rebuild_stop_loss_for_remaining_position(
    client: BinanceFuturesClient,
    order: Order,
    exchange_size: Decimal,
    pos_mode: str,
    current_price: Decimal = Decimal("0"),
    algo_rows: Optional[list[dict[str, Any]]] = None,
) -> bool:
    stop_price = order.current_stop_price or order.stop_loss_price
    if exchange_size <= 0 or not stop_price or stop_price <= 0:
        return False
    retry_context = _build_retry_context(order=order)
    return _converge_stop_loss_order(
        client,
        order,
        exchange_size=exchange_size,
        stop_price=stop_price,
        pos_mode=pos_mode,
        current_price=current_price,
        algo_rows=algo_rows,
        action="rebuild_stop_loss",
        retry_context=retry_context,
    )


def _rebuild_take_profit_for_remaining_position(
    client: BinanceFuturesClient,
    order: Order,
    pos_mode: str,
    exchange_size: Optional[Decimal] = None,
    algo_rows: Optional[list[dict[str, Any]]] = None,
) -> bool:
    if not order.strategy_snapshot_id or order.strategy_status != Order.STRATEGY_STATUS_RUNNING:
        return False
    snapshot = OrderStrategySnapshot.objects.filter(id=order.strategy_snapshot_id, order=order).first()
    if not snapshot:
        return False
    retry_context = _build_retry_context(order=order)
    if exchange_size is None:
        positions = (
            _retry_exchange_call(
                client.get_positions,
                "SWAP",
                to_inst_id(order.symbol),
                retry_label="rebuild_take_profit_load_positions",
                retry_context=retry_context,
            ).get("data")
            or []
        )
        exchange_size = _find_position_size(order, positions, pos_mode)
    if exchange_size <= 0:
        return False

    inst_id = to_inst_id(order.symbol)
    close_side = "sell" if order.side == 0 else "buy"
    pos_side = _resolve_pos_side_from_mode(order.side, pos_mode)
    open_algos = algo_rows if algo_rows is not None else _load_open_algo_rows(
        client,
        inst_id,
        retry_label="rebuild_take_profit_load_open_algo_orders",
        retry_context=retry_context,
    )
    candidates = _take_profit_algo_candidates(
        open_algos,
        inst_id=inst_id,
        close_side=close_side,
        pos_side=pos_side,
    )
    stored_ids = [str(item) for item in (order.strategy_tp_algo_ids or []) if item]
    active_ids = {str(row.get("algoId") or "") for row in candidates if row.get("algoId")}
    targets = _build_take_profit_targets(order, snapshot)
    algo_client = BinanceAlgoClient(client, log=logger)

    keep_ids: list[str] = []
    created_ids: list[str] = []
    unresolved_cancel_ids: list[str] = []
    used_candidate_ids: set[str] = set()
    changed = False
    remaining_cap = exchange_size
    reduced_unmanaged_size = max((order.size or Decimal("0")) - exchange_size, Decimal("0"))

    for target_idx, target in enumerate(targets):
        target_size: Decimal = target["size"]
        target_price: Decimal = target["trigger_price"]
        level_idx: int = target["level_idx"]
        stored_id = stored_ids[target_idx] if target_idx < len(stored_ids) else ""
        target_kept_live = False

        if target_size > remaining_cap + POSITION_SIZE_TOLERANCE:
            logger.warning(
                "skip take-profit target beyond exchange position order=%s symbol=%s level=%s target_size=%s remaining=%s",
                order.id,
                order.symbol,
                level_idx,
                format(target_size, "f"),
                format(remaining_cap, "f"),
            )
            changed = True
            continue

        matches = [
            row for row in candidates
            if str(row.get("algoId") or "") not in used_candidate_ids
            and _take_profit_algo_matches(row, trigger_price=target_price, size=target_size)
        ]
        keep = next((row for row in matches if str(row.get("algoId") or "") == stored_id), None)
        if keep is None and matches:
            keep = matches[0]

        if keep:
            keep_id = str(keep.get("algoId") or "")
            keep_ids.append(keep_id)
            used_candidate_ids.add(keep_id)
            target_kept_live = True
            duplicate_ids = [
                str(row.get("algoId") or "")
                for row in matches
                if str(row.get("algoId") or "") and str(row.get("algoId") or "") != keep_id
            ]
            if duplicate_ids:
                unresolved_cancel_ids.extend(
                    _cancel_algo_ids_once(
                        client,
                        inst_id=inst_id,
                        algo_ids=duplicate_ids,
                        action="rebuild_take_profit_cancel_duplicate",
                    )
                )
                changed = True
        elif target_size <= reduced_unmanaged_size + POSITION_SIZE_TOLERANCE:
            reduced_unmanaged_size = max(reduced_unmanaged_size - target_size, Decimal("0"))
            changed = True
        else:
            replacing_active_orders = bool(active_ids)
            replacement_key = f"{level_idx}:{format(target_price, 'f')}:{format(target_size, 'f')}"
            replacement_hash = hashlib.sha256(replacement_key.encode()).hexdigest()[:8]
            client_id_suffix = f"{level_idx}{replacement_hash}"
            try:
                algo_id = algo_client.create_take_profit(
                    inst_id=inst_id,
                    side=close_side,
                    size=format(target_size, "f"),
                    trigger_price=format(target_price, "f"),
                    pos_side=pos_side,
                    client_algo_id=_build_algo_client_id(order, "tp", client_id_suffix),
                    visibility_mode=(
                        ALGO_VISIBILITY_REQUIRE_VISIBLE
                        if replacing_active_orders
                        else ALGO_VISIBILITY_ALLOW_DELAYED
                    ),
                    action=f"rebuild_take_profit_L{level_idx}",
                )
            except Exception:
                unresolved_ids = _cancel_algo_ids_once(
                    client,
                    inst_id=inst_id,
                    algo_ids=created_ids,
                    action="rebuild_take_profit_rollback",
                )
                if unresolved_ids:
                    order.strategy_tp_algo_ids = list(dict.fromkeys([
                        *stored_ids,
                        *unresolved_ids,
                    ]))
                    order.save(update_fields=["strategy_tp_algo_ids"])
                raise
            if algo_id and algo_id not in keep_ids:
                keep_ids.append(algo_id)
                created_ids.append(algo_id)
            changed = True
            target_kept_live = True

        if target_kept_live:
            remaining_cap -= target_size

    stale_stored_ids = [algo_id for algo_id in stored_ids if algo_id and algo_id not in keep_ids and algo_id in active_ids]
    if stale_stored_ids:
        unresolved_cancel_ids.extend(
            _cancel_algo_ids_once(
                client,
                inst_id=inst_id,
                algo_ids=stale_stored_ids,
                action="rebuild_take_profit_cancel_stale",
            )
        )
        changed = True

    tracked_ids = list(dict.fromkeys([*keep_ids, *unresolved_cancel_ids]))
    if tracked_ids != stored_ids:
        order.strategy_tp_algo_ids = tracked_ids
        order.save(update_fields=["strategy_tp_algo_ids"])
        changed = True
    return changed


def _move_stop_loss(
    client: BinanceFuturesClient,
    order: Order,
    candidate: Decimal,
    current_price: Decimal,
    *,
    pos_mode: Optional[str] = None,
    positions: Optional[list[dict[str, Any]]] = None,
) -> bool:
    current_stop = order.current_stop_price or order.stop_loss_price
    if not current_stop or current_stop <= 0:
        return False
    inst_id = to_inst_id(order.symbol)
    retry_context = _build_retry_context(order=order, inst_id=inst_id)
    resolved_pos_mode = pos_mode or _load_pos_mode(
        client,
        retry_label="strategy_move_stop_loss_load_pos_mode",
        retry_context=retry_context,
    )
    resolved_positions = positions
    if resolved_positions is None:
        resolved_positions = (
            _retry_exchange_call(
                client.get_positions,
                "SWAP",
                inst_id,
                retry_label="strategy_move_stop_loss_load_positions",
                retry_context=retry_context,
            ).get("data")
            or []
        )
    exchange_size = _find_position_size(order, resolved_positions, resolved_pos_mode)
    if exchange_size <= 0:
        return False
    normalized = _normalize_stop_loss_request(
        order=order,
        inst_id=inst_id,
        stop_price=candidate,
        size=exchange_size,
        current_price=current_price,
    )
    normalized_candidate = normalized["stop_price"]
    rules = _get_instrument_trade_rules(inst_id)
    min_stop_step = rules["tickSz"] if rules["tickSz"] > 0 else POSITION_SIZE_TOLERANCE
    normalized_current_stop = current_stop
    if current_stop and current_stop > 0:
        normalized_current_stop = _normalize_stop_loss_request(
            order=order,
            inst_id=inst_id,
            stop_price=current_stop,
            size=exchange_size,
            current_price=current_price,
        )["stop_price"]
    if order.side == 0:
        if (
            normalized_candidate <= normalized_current_stop
            or normalized_candidate >= current_price
            or normalized_candidate - normalized_current_stop < min_stop_step
        ):
            return False
    else:
        if (
            normalized_candidate >= normalized_current_stop
            or normalized_candidate <= current_price
            or normalized_current_stop - normalized_candidate < min_stop_step
        ):
            return False

    return _converge_stop_loss_order(
        client,
        order,
        exchange_size=exchange_size,
        stop_price=normalized_candidate,
        pos_mode=resolved_pos_mode,
        current_price=current_price,
        action="strategy_move_stop_loss",
        retry_context=retry_context,
    )


def _attempt_strategy_stop_move(
    client: BinanceFuturesClient,
    order: Order,
    snapshot: OrderStrategySnapshot,
    level_idx: int,
    level: dict[str, Any],
    extreme_price: Decimal,
    current_price: Decimal,
    *,
    pos_mode: Optional[str] = None,
    positions: Optional[list[dict[str, Any]]] = None,
) -> None:
    trigger_rr = level["profit_rr"]
    current_stop = order.current_stop_price or order.stop_loss_price
    initial_stop = order.initial_stop_price or order.stop_loss_price
    base_r = abs(order.open_price - initial_stop)
    if base_r <= 0:
        _log_strategy(
            order,
            snapshot,
            f"L{level_idx} 止损移动跳过（基准R无效）",
            OrderStrategyLog.RESULT_SKIPPED,
            trigger_r=trigger_rr,
        )
        return
    current_rr = (
        (current_price - order.open_price) / base_r
        if order.side == 0
        else (order.open_price - current_price) / base_r
    )
    if level["stop_loss_type"] == "fixedRR":
        move_rr = level["stop_loss_rr"]
        if move_rr <= 0:
            return
        if current_rr < move_rr:
            _log_strategy(
                order,
                snapshot,
                f"L{level_idx} 止损移动跳过（当前R不足）",
                OrderStrategyLog.RESULT_SKIPPED,
                trigger_r=trigger_rr,
            )
            return
        candidate = _calc_candidate_stop(order, extreme_price, move_rr)
    else:
        absolute_rr = level["stop_loss_absolute_rr"]
        if absolute_rr <= Decimal("-1"):
            return
        candidate = _calc_absolute_stop(order, absolute_rr)
    try:
        moved = _move_stop_loss(
            client,
            order,
            candidate,
            current_price,
            pos_mode=pos_mode,
            positions=positions,
        )
        if moved:
            _log_strategy(
                order,
                snapshot,
                f"L{level_idx} 止损移动到 {format(candidate, 'f')}",
                OrderStrategyLog.RESULT_SUCCESS,
                trigger_r=trigger_rr,
            )
        else:
            # 当前止损已等于或优于本层目标价时，视为本层移动已完成：
            # 写入用户可见日志并推进层级，避免日志停留在“L? 达到”没有任何后续说明。
            existing_stop = order.current_stop_price or order.stop_loss_price
            already_protected = bool(existing_stop) and existing_stop > 0 and (
                (order.side == 0 and existing_stop >= candidate)
                or (order.side == 1 and existing_stop <= candidate)
            )
            if already_protected:
                _log_strategy(
                    order,
                    snapshot,
                    f"L{level_idx} 止损移动到 {format(existing_stop, 'f')}（当前止损已优于目标 {format(candidate, 'f')}，无需再移）",
                    OrderStrategyLog.RESULT_SUCCESS,
                    trigger_r=trigger_rr,
                )
            else:
                # 技术性跳过（例如未创新高导致候选价不优）不写用户日志，避免刷屏。
                logger.info(
                    "strategy skip candidate invalid order=%s level=%s trigger_r=%s candidate=%s current_stop=%s current_price=%s",
                    order.id,
                    level_idx,
                    trigger_rr,
                    candidate,
                    current_stop,
                    current_price,
                )
    except Exception as exc:  # noqa: BLE001
        _log_strategy(
            order,
            snapshot,
            f"L{level_idx} 止损移动失败",
            OrderStrategyLog.RESULT_FAILED,
            str(exc),
            trigger_r=trigger_rr,
        )
        if is_binance_rate_limit_error(exc):
            raise


def _process_single_strategy_order(order: Order, exchange_context: Optional[dict[str, Any]] = None) -> None:
    snapshot = OrderStrategySnapshot.objects.filter(id=order.strategy_snapshot_id, order=order).first()
    if not snapshot:
        return

    next_level = _select_next_level(snapshot)
    client: Optional[BinanceFuturesClient] = None
    pos_mode: Optional[str] = None
    positions: Optional[list[dict[str, Any]]] = None
    if exchange_context is not None:
        client = exchange_context.get("client")
        pos_mode = exchange_context.get("pos_mode")
        positions = exchange_context.get("positions")
    if client is None:
        credentials = get_user_binance_credentials(order.user, trading_mode=order.trading_mode)
        if not credentials:
            _log_strategy(order, snapshot, "策略执行失败：用户未绑定API", OrderStrategyLog.RESULT_FAILED, "missing credentials")
            return
        client = BinanceFuturesClient(credentials)

    try:
        retry_context = _build_retry_context(order=order)
        minute_extreme_price, current_price = _get_current_extreme(
            client,
            order.symbol,
            order.side,
            retry_label="strategy_engine_load_mark_price_candles",
            retry_context=retry_context,
        )
        # 动态移动止损必须基于“持仓以来的单向极值”，避免回落后候选价倒退导致无法执行。
        prev_extreme = order.last_extreme_price or Decimal("0")
        if order.side == 0:
            extreme_price = max(prev_extreme, minute_extreme_price) if prev_extreme > 0 else minute_extreme_price
        else:
            extreme_price = min(prev_extreme, minute_extreme_price) if prev_extreme > 0 else minute_extreme_price
        order.last_extreme_price = extreme_price
        order.save(update_fields=["last_extreme_price"])

        def trail_completed_fixed_rr_level() -> None:
            trailing = _latest_completed_fixed_rr_level(snapshot)
            if not trailing:
                return
            trailing_idx, trailing_level = trailing
            _attempt_strategy_stop_move(
                client,
                order,
                snapshot,
                trailing_idx,
                trailing_level,
                extreme_price,
                current_price,
                pos_mode=pos_mode,
                positions=positions,
            )

        if not next_level:
            trail_completed_fixed_rr_level()
            return

        level_idx, level, _, move_done = next_level
        trigger_rr = level["profit_rr"]
        trigger_price = _calc_trigger_price(order, trigger_rr)
        triggered = extreme_price >= trigger_price if order.side == 0 else extreme_price <= trigger_price
        if not triggered:
            trail_completed_fixed_rr_level()
            return

        # 仅在真实触达触发价后，记录该层进入执行（避免把预挂成功误当作层级执行）。
        reached_logged = OrderStrategyLog.objects.filter(
            snapshot=snapshot,
            result=OrderStrategyLog.RESULT_SUCCESS,
            behavior_desc__startswith=f"L{level_idx} 达到",
            trigger_r=trigger_rr,
        ).exists()
        if not reached_logged:
            reduce_pct = level.get("reduce_position", Decimal("0"))
            if reduce_pct > 0:
                _log_strategy(
                    order,
                    snapshot,
                    f"L{level_idx} 达到 {format(trigger_rr, 'f')}R，触发减仓条件 {format(reduce_pct, 'f')}%",
                    OrderStrategyLog.RESULT_SUCCESS,
                    trigger_r=trigger_rr,
                )
            else:
                _log_strategy(
                    order,
                    snapshot,
                    f"L{level_idx} 达到 {format(trigger_rr, 'f')}R",
                    OrderStrategyLog.RESULT_SUCCESS,
                    trigger_r=trigger_rr,
                )

        if level["stop_loss_type"] in ("fixedRR", "absoluteRR") and not move_done:
            _attempt_strategy_stop_move(
                client,
                order,
                snapshot,
                level_idx,
                level,
                extreme_price,
                current_price,
                pos_mode=pos_mode,
                positions=positions,
            )
    except Exception as exc:  # noqa: BLE001
        _log_strategy(order, snapshot, "策略执行异常", OrderStrategyLog.RESULT_FAILED, str(exc))
        if is_binance_rate_limit_error(exc):
            raise


def run_strategy_engine(*, trading_mode=TradingMode.ORDINARY):
    """
    每10秒执行一次：
    - 加分布式锁，避免重复运行
    - 仅处理 strategy_status=运行中 且未平仓订单
    """
    cache_lock_key = "strategy_engine:lock"
    db_lock_key = "strategy_engine_db_lock"
    if trading_mode == TradingMode.LEAD:
        cache_lock_key += ":lead"
        db_lock_key += "_lead"

    with _acquire_db_lock(db_lock_key) as db_locked:
        if not db_locked:
            return 0

        cache_locked = cache.add(cache_lock_key, "1", timeout=9)
        if not cache_locked:
            return 0

        processed = 0
        try:
            orders = list(
                Order.objects.select_related("user").filter(
                    trading_mode=trading_mode,
                    status=0,
                    strategy_status=Order.STRATEGY_STATUS_RUNNING,
                    strategy_snapshot_id__isnull=False,
                ).exclude(position_origin=Order.ORIGIN_EXTERNAL)
            )
            generations_by_user: dict[tuple[int, str], tuple[str, Any]] = {}
            orders_by_account: dict[tuple[int, str], list[Order]] = {}
            for order in orders:
                user_id = int(order.user_id)
                if (user_id, order.trading_mode) not in generations_by_user:
                    generations_by_user[(user_id, order.trading_mode)] = get_user_binding_generation(order.user, trading_mode=order.trading_mode)
                fingerprint, binding_created_at = generations_by_user[(user_id, order.trading_mode)]
                if not record_belongs_to_trading_account(
                    record_fingerprint=order.api_key_fingerprint,
                    record_created_at=order.created_at,
                    account_fingerprint=fingerprint,
                    binding_created_at=binding_created_at,
                    record_mode=order.trading_mode,
                    account_mode=order.trading_mode,
                ):
                    continue
                orders_by_account.setdefault((user_id, fingerprint), []).append(order)

            for (user_id, fingerprint), account_orders in orders_by_account.items():
                account_identity = build_trading_account_identity(
                    user_id=user_id,
                    api_key_fingerprint=fingerprint,
                    trading_mode=account_orders[0].trading_mode,
                )
                with user_trading_activity_lock(account_identity) as account_locked:
                    if not account_locked:
                        logger.info(
                            "strategy account skipped because mutation lock is busy user=%s",
                            user_id,
                        )
                        continue
                    try:
                        creds = _credentials_for_binding_generation(
                            account_orders[0].user,
                            api_key_fingerprint=fingerprint,
                            binding_created_at=generations_by_user[(user_id, account_orders[0].trading_mode)][1],
                            trading_mode=account_orders[0].trading_mode,
                        )
                        if not creds:
                            continue
                        client = BinanceFuturesClient(creds)
                        retry_context = _build_retry_context(user_id=user_id)
                        exchange_context = {
                            "client": client,
                            "pos_mode": _load_pos_mode(
                                client,
                                retry_label="strategy_engine_load_pos_mode",
                                retry_context=retry_context,
                            ),
                            "positions": load_shared_exchange_positions(
                                client,
                                account_identity,
                                retry_label="strategy_engine_load_positions",
                            ),
                            "close_trade_rows": {},
                        }
                    except Exception as exc:  # noqa: BLE001
                        logger.warning(
                            "strategy account snapshot unavailable user=%s err=%s",
                            user_id,
                            safe_error_summary(exc),
                        )
                        if is_binance_rate_limit_error(exc) and not exc.account_rate_limited:
                            return processed
                        continue

                    for stale_order in account_orders:
                        order = (
                            Order.objects.select_related("user")
                            .filter(
                                id=stale_order.id,
                                status=0,
                                strategy_status=Order.STRATEGY_STATUS_RUNNING,
                                strategy_snapshot_id__isnull=False,
                            )
                            .first()
                        )
                        if order is None:
                            continue
                        try:
                            with transaction.atomic():
                                pos_mode = str(exchange_context.get("pos_mode") or "long_short_mode")
                                pos_rows = exchange_context.get("positions") or []
                                exchange_size = _find_position_size(order, pos_rows, pos_mode)
                                if exchange_size > 0 and _close_fully_offset_order(
                                    order,
                                    client,
                                    source="strategy_engine",
                                    trade_cache=exchange_context.get("close_trade_rows"),
                                ):
                                    continue
                                _process_single_strategy_order(
                                    order,
                                    exchange_context=exchange_context,
                                )
                            processed += 1
                        except Exception as exc:  # noqa: BLE001
                            if is_binance_rate_limit_error(exc):
                                logger.warning(
                                    "策略任务触发限频 order=%s err=%s",
                                    order.id,
                                    safe_error_summary(exc),
                                )
                                if exc.account_rate_limited:
                                    break
                                return processed
                            logger.error(
                                "策略任务处理失败 order=%s err=%s",
                                order.id,
                                safe_error_summary(exc),
                            )
            return processed
        finally:
            cache.delete(cache_lock_key)


def _uses_manual_protection_management(order: Order) -> bool:
    return bool(
        order.strategy_status == Order.STRATEGY_STATUS_CANCELLED
        and not order.binance_stop_order_id
        and not order.binance_stop_market_order_id
        and str(order.stop_protection_error or "") == MANUAL_TP_SL_MANAGEMENT_ERROR
    )


def _group_protection_orders(
    orders: list[Order],
) -> tuple[
    list[tuple[Order, tuple[int, str]]],
    dict[tuple[int, str], set[str]],
    dict[tuple[int, str], Any],
]:
    generations_by_user: dict[tuple[int, str], tuple[str, Any]] = {}
    eligible_orders: list[tuple[Order, tuple[int, str]]] = []
    symbols_by_account: dict[tuple[int, str], set[str]] = {}
    binding_created_at_by_account: dict[tuple[int, str], Any] = {}
    for order in orders:
        if _uses_manual_protection_management(order):
            continue
        user_id = int(order.user_id)
        if (user_id, order.trading_mode) not in generations_by_user:
            generations_by_user[(user_id, order.trading_mode)] = get_user_binding_generation(order.user, trading_mode=order.trading_mode)
        current_fingerprint, binding_created_at = generations_by_user[(user_id, order.trading_mode)]
        if not record_belongs_to_trading_account(
            record_fingerprint=order.api_key_fingerprint,
            record_created_at=order.created_at,
            account_fingerprint=current_fingerprint,
            binding_created_at=binding_created_at,
            record_mode=order.trading_mode,
            account_mode=order.trading_mode,
        ):
            logger.info(
                "skip protection reconcile for stale api key order=%s user=%s symbol=%s",
                order.id,
                order.user_id,
                order.symbol,
            )
            continue
        account_key = (user_id, current_fingerprint)
        eligible_orders.append((order, account_key))
        symbols_by_account.setdefault(account_key, set()).add(to_inst_id(order.symbol))
        binding_created_at_by_account[account_key] = binding_created_at
    return eligible_orders, symbols_by_account, binding_created_at_by_account


def _load_protection_account_snapshot(
    order: Order,
    inst_ids: set[str],
    account_identity: str,
    *,
    api_key_fingerprint: str,
    binding_created_at,
) -> Optional[ProtectionAccountSnapshot]:
    credentials = _credentials_for_binding_generation(
        order.user,
        api_key_fingerprint=api_key_fingerprint,
        binding_created_at=binding_created_at,
        trading_mode=order.trading_mode,
    )
    if not credentials:
        return None
    client = BinanceFuturesClient(credentials)
    retry_context = _build_retry_context(user_id=order.user_id)
    pos_mode = _load_pos_mode(
        client,
        retry_label="reconcile_open_orders_load_pos_mode",
        retry_context=retry_context,
        budget_priority=RequestPriority.CRITICAL,
    )
    positions = load_shared_exchange_positions(
        client,
        account_identity,
        retry_label="reconcile_open_orders_load_positions",
        budget_priority=RequestPriority.CRITICAL,
    )
    algo_rows = load_shared_open_algo_rows(
        client,
        account_identity,
        inst_ids or {to_inst_id(order.symbol)},
        retry_label="reconcile_open_orders_load_open_algo_orders",
        budget_priority=RequestPriority.CRITICAL,
    )
    return ProtectionAccountSnapshot(
        client=client,
        pos_mode=pos_mode,
        positions=positions,
        algo_map={
            str((row or {}).get("algoId") or ""): row
            for row in algo_rows
            if (row or {}).get("algoId")
        },
        close_trade_rows={},
    )


def _cancel_disabled_strategy_take_profit(
    order: Order,
    snapshot: ProtectionAccountSnapshot,
) -> int:
    if order.strategy_status != Order.STRATEGY_STATUS_CANCELLED or not order.strategy_tp_algo_ids:
        return 0
    residual_ids = _cancel_algo_ids_once(
        snapshot.client,
        inst_id=to_inst_id(order.symbol),
        algo_ids=[str(item) for item in order.strategy_tp_algo_ids if item],
        action="reconcile_cancelled_strategy_take_profit",
    )
    if residual_ids == list(order.strategy_tp_algo_ids or []):
        return 0
    order.strategy_tp_algo_ids = residual_ids
    order.save(update_fields=["strategy_tp_algo_ids"])
    return 1


def _protection_is_complete(
    *,
    order: Order,
    snapshot: ProtectionAccountSnapshot,
    stop_candidates: list[dict[str, Any]],
    stop_price: Decimal,
    exchange_size: Decimal,
    current_price: Decimal,
) -> bool:
    if not order.binance_stop_market_order_id:
        return False
    visible_row = snapshot.algo_map.get(str(order.binance_stop_market_order_id))
    if visible_row:
        normalized_stop = _normalize_stop_loss_request(
            order=order,
            inst_id=to_inst_id(order.symbol),
            stop_price=stop_price,
            size=exchange_size,
            current_price=current_price,
        )
        return bool(
            visible_row in stop_candidates
            and str(visible_row.get("algoType") or "") == "STOP_MARKET"
            and _stop_loss_algo_matches(
                visible_row,
                stop_price=normalized_stop["stop_price"],
                size=normalized_stop["size"],
            )
        )
    return bool(
        order.stop_loss_order_created_at
        and (timezone.now() - order.stop_loss_order_created_at).total_seconds()
        < STOP_LOSS_VISIBILITY_GRACE_SECONDS
    )


def _stop_price_crossed(order: Order, current_price: Decimal, stop_price: Decimal) -> bool:
    return bool(
        (order.side == 0 and current_price > 0 and current_price <= stop_price)
        or (order.side == 1 and current_price > 0 and current_price >= stop_price)
    )


def _emergency_close_unprotected_position(
    order: Order,
    snapshot: ProtectionAccountSnapshot,
    stop_price: Decimal,
) -> int:
    close_error: Optional[Exception] = None
    close_payload: Optional[dict] = None
    record_operation(
        order,
        action="emergency_close",
        status="pending",
        message=f"止损保护不完整且价格已触及止损价 {stop_price.normalize():f}，系统开始市价平仓",
    )
    try:
        close_side = _resolve_pos_side_from_mode(order.side, snapshot.pos_mode)
        close_payload = snapshot.client.close_position(
            inst_id=to_inst_id(order.symbol),
            pos_side=close_side,
            expected_side="long" if order.side == 0 else "short",
        )
    except Exception as exc:  # noqa: BLE001
        close_error = exc

    try:
        consecutive_absent = 0
        for delay in (0.0, 0.25, 0.75, 1.5):
            if delay:
                time.sleep(delay)
            payload = snapshot.client.get_positions(
                "SWAP",
                to_inst_id(order.symbol),
                budget_priority=RequestPriority.CRITICAL,
            )
            rows = payload.get("data") or []
            if _find_position_size(order, rows, snapshot.pos_mode) <= POSITION_SIZE_TOLERANCE:
                consecutive_absent += 1
                if consecutive_absent >= 2:
                    break
            else:
                consecutive_absent = 0
        if consecutive_absent < 2:
            if close_error:
                raise close_error
            raise BinanceApiError("紧急平仓已提交，但交易所仍返回未平仓仓位")
        finalize_confirmed_emergency_close(
            order,
            snapshot.client,
            close_payload=close_payload,
            trigger_price=stop_price,
        )
        return 1
    except Exception as exc:  # noqa: BLE001
        order.stop_protection_status = Order.STOP_PROTECTION_EMERGENCY
        order.stop_protection_error = (
            "止损保护未完整，触价市价平仓失败："
            f"{safe_error_summary(exc, include_type=False)}"
        )[:500]
        order.save(update_fields=["stop_protection_status", "stop_protection_error"])
        definitive_rejection = isinstance(close_error, BinanceApiError) and not close_error.outcome_unknown
        record_operation(
            order,
            action="emergency_close",
            status="failed" if definitive_rejection else "pending",
            message=("紧急平仓被拒绝：" if definitive_rejection else "紧急平仓结果待确认：")
            + safe_error_summary(exc, include_type=False),
        )
        if is_binance_rate_limit_error(exc):
            raise
        return 0


def _reconcile_stop_loss_protection(
    *,
    order: Order,
    snapshot: ProtectionAccountSnapshot,
    strategy_snapshot: Optional[OrderStrategySnapshot],
    exchange_size: Decimal,
    current_price: Decimal,
    stop_price: Decimal,
) -> tuple[int, bool]:
    algo_rows = list(snapshot.algo_map.values())
    stop_candidates = _stop_loss_algo_candidates(
        algo_rows,
        inst_id=to_inst_id(order.symbol),
        close_side="sell" if order.side == 0 else "buy",
        pos_side=_resolve_pos_side_from_mode(order.side, snapshot.pos_mode),
    )
    protection_complete = _protection_is_complete(
        order=order,
        snapshot=snapshot,
        stop_candidates=stop_candidates,
        stop_price=stop_price,
        exchange_size=exchange_size,
        current_price=current_price,
    )
    if not protection_complete and _stop_price_crossed(order, current_price, stop_price):
        return _emergency_close_unprotected_position(order, snapshot, stop_price), True

    repaired = 0
    if protection_complete:
        # The visibility grace also counts as complete for retry scheduling;
        # only a matching visible order confirms protection for the user log.
        if snapshot.algo_map.get(str(order.binance_stop_market_order_id)):
            record_operation(
                order,
                action="stop_protection",
                status="success",
                message=f"已核对止损保护：触发价 {stop_price.normalize():f}，持仓数量 {exchange_size.normalize():f}",
            )
        if order.binance_stop_order_id or len(stop_candidates) > 1:
            try:
                if _rebuild_stop_loss_for_remaining_position(
                    snapshot.client,
                    order,
                    exchange_size,
                    snapshot.pos_mode,
                    current_price=current_price,
                    algo_rows=algo_rows,
                ):
                    repaired += 1
            except Exception as exc:  # noqa: BLE001
                logger.warning(
                    "stop-loss normalization failed while primary protection remains active "
                    "order=%s symbol=%s err=%s",
                    order.id,
                    order.symbol,
                    safe_error_summary(exc),
                )
                if is_binance_rate_limit_error(exc):
                    raise
        if order.stop_protection_status != Order.STOP_PROTECTION_COMPLETE:
            _clear_stop_protection_failure(order)
            _mark_stop_loss_protection_recovered(order, strategy_snapshot)
        return repaired, False

    if not _stop_protection_retry_due(order):
        return repaired, False
    try:
        if _rebuild_stop_loss_for_remaining_position(
            snapshot.client,
            order,
            exchange_size,
            snapshot.pos_mode,
            current_price=current_price,
            algo_rows=algo_rows,
        ):
            repaired += 1
        if order.binance_stop_market_order_id:
            _clear_stop_protection_failure(order)
            _mark_stop_loss_protection_recovered(order, strategy_snapshot)
    except Exception as exc:  # noqa: BLE001
        logger.warning(
            "rebuild stop-loss failed order=%s symbol=%s err=%s",
            order.id,
            order.symbol,
            safe_error_summary(exc),
        )
        _mark_stop_loss_protection_pending(order, strategy_snapshot, str(exc))
        _record_stop_protection_retry_failure(order, str(exc))
        if is_binance_rate_limit_error(exc):
            raise
    return repaired, False


def _reconcile_single_order_protection(
    order: Order,
    snapshot: ProtectionAccountSnapshot,
) -> int:
    repaired = _cancel_disabled_strategy_take_profit(order, snapshot)
    pos_row = _find_position_row(order, snapshot.positions, snapshot.pos_mode)
    exchange_size = _find_position_size(order, snapshot.positions, snapshot.pos_mode)
    if exchange_size <= 0:
        return repaired
    if _close_fully_offset_order(
        order,
        snapshot.client,
        source="reconcile_open_orders",
        trade_cache=snapshot.close_trade_rows,
    ):
        return repaired + 1

    current_price = _parse_decimal(
        (pos_row or {}).get("last") or (pos_row or {}).get("markPx") or "0"
    )
    _sync_order_exchange_size(order, exchange_size, current_price=current_price)
    if abs(exchange_size - order.size) > POSITION_SIZE_TOLERANCE:
        logger.info(
            "reconcile stop-loss with exchange position order=%s symbol=%s initial_size=%s exchange_size=%s",
            order.id,
            order.symbol,
            format(order.size, "f"),
            format(exchange_size, "f"),
        )

    stop_price = order.current_stop_price or order.stop_loss_price
    if not stop_price or stop_price <= 0:
        return repaired
    strategy_snapshot = None
    if order.strategy_snapshot_id:
        strategy_snapshot = OrderStrategySnapshot.objects.filter(
            id=order.strategy_snapshot_id,
            order=order,
        ).first()
    stop_repairs, emergency_handled = _reconcile_stop_loss_protection(
        order=order,
        snapshot=snapshot,
        strategy_snapshot=strategy_snapshot,
        exchange_size=exchange_size,
        current_price=current_price,
        stop_price=stop_price,
    )
    repaired += stop_repairs
    if emergency_handled:
        return repaired
    try:
        if _rebuild_take_profit_for_remaining_position(
            snapshot.client,
            order,
            snapshot.pos_mode,
            exchange_size=exchange_size,
            algo_rows=list(snapshot.algo_map.values()),
        ):
            repaired += 1
    except Exception as exc:  # noqa: BLE001
        logger.warning(
            "rebuild take-profit failed order=%s symbol=%s err=%s",
            order.id,
            order.symbol,
            safe_error_summary(exc),
        )
        if is_binance_rate_limit_error(exc):
            raise
    return repaired


def reconcile_open_orders_protection(*, trading_mode=TradingMode.ORDINARY, user_id=None) -> int:
    """
    每10秒对账：
    - 对齐 DB 订单 size 与交易所实时持仓
    - 仓位缩小时，自动重建剩余仓位的止损/止盈保护
    """
    cache_lock_key = "order_protection_reconcile:lock"
    db_lock_key = "order_protection_reconcile_db_lock"
    if user_id is not None:
        cache_lock_key += f":user:{int(user_id)}"
        db_lock_key += f"_u{int(user_id)}"
    if trading_mode == TradingMode.LEAD:
        cache_lock_key += ":lead"
        db_lock_key += "_lead"

    with _acquire_db_lock(db_lock_key) as db_locked:
        if not db_locked:
            return 0

        cache_locked = cache.add(cache_lock_key, "1", timeout=25)
        if not cache_locked:
            return 0

        repaired = 0
        try:
            orders = list(
                Order.objects.select_related("user")
                .filter(status=0, trading_mode=trading_mode, **({"user_id": user_id} if user_id is not None else {}))
                .exclude(position_origin=Order.ORIGIN_EXTERNAL)
                .order_by("-id")
            )
            orders.sort(key=lambda order: (1 if order.binance_stop_order_id else 0, -int(order.id or 0)))
            if not orders:
                return 0
            (
                eligible_orders,
                symbols_by_account,
                binding_created_at_by_account,
            ) = _group_protection_orders(orders)
            orders_by_account: dict[tuple[int, str], list[Order]] = {}
            for order, account_key in eligible_orders:
                orders_by_account.setdefault(account_key, []).append(order)

            for account_key, account_orders in orders_by_account.items():
                user_id, fingerprint = account_key
                account_identity = build_trading_account_identity(
                    user_id=user_id,
                    api_key_fingerprint=fingerprint,
                    trading_mode=account_orders[0].trading_mode,
                )
                with user_trading_activity_lock(account_identity) as account_locked:
                    if not account_locked:
                        logger.info(
                            "protection account reconcile skipped because mutation lock is busy user=%s",
                            user_id,
                        )
                        continue
                    try:
                        snapshot = _load_protection_account_snapshot(
                            account_orders[0],
                            symbols_by_account.get(account_key) or set(),
                            account_identity,
                            api_key_fingerprint=fingerprint,
                            binding_created_at=binding_created_at_by_account.get(account_key),
                        )
                    except Exception as exc:  # noqa: BLE001
                        logger.warning(
                            "protection account snapshot unavailable user=%s err=%s",
                            user_id,
                            safe_error_summary(exc),
                        )
                        if is_binance_rate_limit_error(exc) and not exc.account_rate_limited:
                            return repaired
                        continue
                    if snapshot is None:
                        continue
                    for order in account_orders:
                        try:
                            repaired += _reconcile_single_order_protection(order, snapshot)
                        except Exception as exc:  # noqa: BLE001
                            if is_binance_rate_limit_error(exc):
                                logger.warning(
                                    "protection order reconcile rate limited user=%s order=%s symbol=%s err=%s",
                                    order.user_id,
                                    order.id,
                                    order.symbol,
                                    safe_error_summary(exc),
                                )
                                if exc.account_rate_limited:
                                    break
                                return repaired
                            logger.error(
                                "protection order reconcile failed user=%s order=%s symbol=%s err=%s",
                                order.user_id,
                                order.id,
                                order.symbol,
                                safe_error_summary(exc),
                            )
            return repaired
        finally:
            cache.delete(cache_lock_key)
