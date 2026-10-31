from __future__ import annotations

from dataclasses import dataclass
import logging
import time
from typing import Any, Optional

from django.utils import timezone

from common.binance import (
    BinanceAlgoClient,
    BinanceApiError,
    BinanceFuturesClient,
    is_binance_rate_limit_error,
    to_inst_id,
)
from common.errors import safe_error_summary
from positions.models import LimitOrder, Order, OrderStrategySnapshot


logger = logging.getLogger(__name__)


def build_managed_algo_client_id(order: Order, kind: str, suffix: str = "") -> str:
    raw_suffix = "".join(ch for ch in str(suffix or "") if ch.isalnum())[:12]
    return f"tt{int(order.id or 0)}{kind}{raw_suffix}"[:36]


def _expected_algo_client_ids(
    order: Order,
    snapshot: Optional[OrderStrategySnapshot] = None,
) -> set[str]:
    expected = {build_managed_algo_client_id(order, "sl"), build_managed_algo_client_id(order, "slm")}
    current_snapshot = snapshot
    if current_snapshot is None and order.strategy_snapshot_id:
        current_snapshot = (
            OrderStrategySnapshot.objects.filter(id=order.strategy_snapshot_id, order=order).first()
        )
    levels = current_snapshot.strategy_config if current_snapshot and isinstance(current_snapshot.strategy_config, list) else []
    for idx, item in enumerate(levels, start=1):
        if not isinstance(item, dict):
            continue
        expected.add(build_managed_algo_client_id(order, "tp", str(idx)))
    expected.add(build_managed_algo_client_id(order, "mtp"))
    expected.add(build_managed_algo_client_id(order, "bet"))
    return {item for item in expected if item}


def _is_managed_algo_row(
    row: dict[str, Any],
    *,
    stored_algo_ids: set[str],
    client_id_prefixes: set[str],
) -> bool:
    algo_id = str((row or {}).get("algoId") or "").strip()
    client_algo_id = str((row or {}).get("clientAlgoId") or "").strip()
    return algo_id in stored_algo_ids or any(
        client_algo_id.startswith(prefix) for prefix in client_id_prefixes
    )


@dataclass
class ClosedOrderCleanupResult:
    stop_order_id: str
    stop_market_order_id: str
    take_profit_algo_ids: list[str]
    manual_take_profit_algo_id: str
    pending_limit_updates: list[LimitOrder]
    cancelled_algo_ids: list[str]
    cancelled_limit_order_ids: list[str]
    had_exchange_errors: bool

    @property
    def has_residual_exchange_orders(self) -> bool:
        if self.stop_order_id or self.stop_market_order_id:
            return True
        if self.take_profit_algo_ids or self.manual_take_profit_algo_id:
            return True
        return any(limit_order.status == LimitOrder.STATUS_PENDING for limit_order in self.pending_limit_updates)


def _load_open_algo_rows(
    client: BinanceFuturesClient,
    inst_id: str,
    *,
    action: str,
) -> tuple[list[dict[str, Any]], bool]:
    try:
        payload = client.get_pending_algo_orders(
            ord_type="conditional",
            inst_type="SWAP",
            inst_id=inst_id,
        )
        rows = payload.get("data") if isinstance(payload, dict) else None
        if not isinstance(rows, list):
            raise BinanceApiError("条件单挂单列表返回格式无效")
        return rows, True
    except Exception as exc:  # noqa: BLE001
        logger.warning(
            "closed_order_cleanup_algo_snapshot_failed action=%s inst_id=%s err=%s",
            action,
            inst_id,
            safe_error_summary(exc),
        )
        if is_binance_rate_limit_error(exc):
            raise
        return [], False


def _select_managed_algo_rows(
    rows: list[dict[str, Any]],
    *,
    stored_algo_ids: set[str],
    client_id_prefixes: set[str],
) -> list[dict[str, Any]]:
    return [
        row
        for row in rows
        if _is_managed_algo_row(
            row,
            stored_algo_ids=stored_algo_ids,
            client_id_prefixes=client_id_prefixes,
        )
    ]


def _cancel_managed_algos(
    algo_client: BinanceAlgoClient,
    *,
    algo_ids: list[str],
    inst_id: str,
    action: str,
) -> tuple[list[str], bool]:
    cancelled: list[str] = []
    had_errors = False
    for algo_id in dict.fromkeys(algo_ids):
        if not algo_id:
            continue
        try:
            algo_client.cancel_algo_confirmed(
                algo_id=algo_id,
                inst_id=inst_id,
                action=action,
            )
            cancelled.append(algo_id)
        except Exception as exc:  # noqa: BLE001
            had_errors = True
            logger.warning(
                "closed_order_cleanup_algo_cancel_failed action=%s inst_id=%s algo_id=%s err=%s",
                action,
                inst_id,
                algo_id,
                safe_error_summary(exc),
            )
            if is_binance_rate_limit_error(exc):
                raise
    return cancelled, had_errors


def _load_pending_limit_rows(
    client: BinanceFuturesClient,
    inst_id: str,
    *,
    action: str,
) -> tuple[list[dict[str, Any]], bool]:
    try:
        payload = client.get_pending_orders("SWAP", inst_id=inst_id)
        rows = payload.get("data") if isinstance(payload, dict) else None
        if not isinstance(rows, list):
            raise BinanceApiError("普通挂单列表返回格式无效")
        return rows, True
    except Exception as exc:  # noqa: BLE001
        logger.warning(
            "closed_order_cleanup_limit_snapshot_failed action=%s inst_id=%s err=%s",
            action,
            inst_id,
            safe_error_summary(exc),
        )
        if is_binance_rate_limit_error(exc):
            raise
        return [], False


def _load_limit_order_row(
    client: BinanceFuturesClient,
    *,
    inst_id: str,
    limit_order: LimitOrder,
    require_terminal: bool,
) -> tuple[Optional[dict[str, Any]], bool]:
    terminal_states = {"canceled", "cancelled", "expired", "rejected", "filled"}
    last_row: Optional[dict[str, Any]] = None
    had_errors = False
    last_error: Optional[Exception] = None
    for delay in (0.0, 0.15, 0.35, 0.75, 1.25):
        if delay:
            time.sleep(delay)
        try:
            payload = client.get_order(
                inst_id=inst_id,
                order_id=str(limit_order.binance_order_id or ""),
            )
            rows = payload.get("data") if isinstance(payload, dict) else None
            if not isinstance(rows, list) or not rows or not isinstance(rows[0], dict):
                continue
            last_row = rows[0]
            state = str(last_row.get("state") or "").strip().lower()
            if not require_terminal or state in terminal_states:
                return last_row, had_errors
        except BinanceApiError as exc:
            code = str(exc.code or "").strip()
            message = str(exc).strip().lower()
            if code in {"-2011", "-2013"} or any(
                hint in message
                for hint in ("unknown order", "order does not exist", "order not found", "订单不存在")
            ):
                return {"state": "canceled"}, had_errors
            last_error = exc
            had_errors = True
            if is_binance_rate_limit_error(exc):
                raise
        except Exception as exc:  # noqa: BLE001
            last_error = exc
            had_errors = True
    if last_error:
        logger.warning(
            "closed_order_cleanup_limit_confirm_failed limit_order_id=%s inst_id=%s err=%s",
            limit_order.id,
            inst_id,
            last_error,
        )
    return last_row, had_errors


@dataclass(frozen=True)
class ResidualAlgoState:
    stop_order_id: str
    stop_market_order_id: str
    take_profit_algo_ids: list[str]
    manual_take_profit_algo_id: str


def _classify_residual_algo(
    order: Order,
    row: dict[str, Any],
    *,
    stored_tp_ids: list[str],
) -> str:
    algo_id = str((row or {}).get("algoId") or "").strip()
    client_algo_id = str((row or {}).get("clientAlgoId") or "").strip()
    algo_type = str((row or {}).get("algoType") or "")
    if not algo_id:
        return ""
    if (
        algo_type == "STOP_MARKET"
        or algo_id == str(order.binance_stop_market_order_id or "").strip()
        or client_algo_id.startswith(build_managed_algo_client_id(order, "slm"))
    ):
        return "stop_market"
    if (
        algo_type == "STOP"
        or algo_id == str(order.binance_stop_order_id or "").strip()
        or client_algo_id.startswith(build_managed_algo_client_id(order, "sl"))
    ):
        return "stop"
    if (
        algo_id == str(order.manual_take_profit_algo_id or "").strip()
        or client_algo_id.startswith(build_managed_algo_client_id(order, "mtp"))
        or client_algo_id.startswith(build_managed_algo_client_id(order, "bet"))
    ):
        return "manual_take_profit"
    if (
        algo_id in stored_tp_ids
        or client_algo_id.startswith(build_managed_algo_client_id(order, "tp"))
    ) and algo_type in {"", "TAKE_PROFIT", "TAKE_PROFIT_MARKET"}:
        return "take_profit"
    return ""


def _should_preserve_stored_algo(
    algo_id: str,
    *,
    initial_algo_ids: set[str],
    remaining_algo_ids: set[str],
    cancelled_algo_ids: set[str],
    both_snapshots_known: bool,
) -> bool:
    if not algo_id or algo_id in remaining_algo_ids or algo_id in cancelled_algo_ids:
        return False
    return not (both_snapshots_known and algo_id not in initial_algo_ids)


def _resolve_residual_algo_state(
    order: Order,
    *,
    stored_tp_ids: list[str],
    initial_rows: list[dict[str, Any]],
    remaining_rows: list[dict[str, Any]],
    cancelled_algo_ids: list[str],
    initial_snapshot_known: bool,
    confirmation_snapshot_known: bool,
) -> ResidualAlgoState:
    stop_order_id = ""
    stop_market_order_id = ""
    manual_take_profit_algo_id = ""
    take_profit_algo_ids: list[str] = []
    for row in remaining_rows:
        algo_id = str((row or {}).get("algoId") or "").strip()
        kind = _classify_residual_algo(order, row, stored_tp_ids=stored_tp_ids)
        if kind == "stop_market":
            stop_market_order_id = algo_id
        elif kind == "stop":
            stop_order_id = algo_id
        elif kind == "manual_take_profit":
            manual_take_profit_algo_id = algo_id
        elif kind == "take_profit":
            take_profit_algo_ids.append(algo_id)

    initial_algo_ids = {
        str((row or {}).get("algoId") or "").strip()
        for row in initial_rows
        if str((row or {}).get("algoId") or "").strip()
    }
    remaining_algo_ids = {
        str((row or {}).get("algoId") or "").strip()
        for row in remaining_rows
        if str((row or {}).get("algoId") or "").strip()
    }

    def preserve_stored(algo_id: str) -> bool:
        return _should_preserve_stored_algo(
            algo_id,
            initial_algo_ids=initial_algo_ids,
            remaining_algo_ids=remaining_algo_ids,
            cancelled_algo_ids=set(cancelled_algo_ids),
            both_snapshots_known=initial_snapshot_known and confirmation_snapshot_known,
        )

    stored_stop_id = str(order.binance_stop_order_id or "").strip()
    stored_stop_market_id = str(order.binance_stop_market_order_id or "").strip()
    stored_manual_id = str(order.manual_take_profit_algo_id or "").strip()
    if not stop_order_id and preserve_stored(stored_stop_id):
        stop_order_id = stored_stop_id
    if not stop_market_order_id and preserve_stored(stored_stop_market_id):
        stop_market_order_id = stored_stop_market_id
    if not manual_take_profit_algo_id and preserve_stored(stored_manual_id):
        manual_take_profit_algo_id = stored_manual_id
    take_profit_algo_ids.extend(
        algo_id
        for algo_id in stored_tp_ids
        if algo_id not in take_profit_algo_ids and preserve_stored(algo_id)
    )
    return ResidualAlgoState(
        stop_order_id=stop_order_id,
        stop_market_order_id=stop_market_order_id,
        take_profit_algo_ids=take_profit_algo_ids,
        manual_take_profit_algo_id=manual_take_profit_algo_id,
    )


@dataclass(frozen=True)
class LimitCleanupState:
    updated_orders: list[LimitOrder]
    cancelled_order_ids: list[str]
    had_exchange_errors: bool


def _cleanup_pending_limit_orders(
    client: BinanceFuturesClient,
    *,
    inst_id: str,
    pending_orders: list[LimitOrder],
    pending_snapshot_known: bool,
    live_order_ids: set[str],
    live_client_ids: set[str],
) -> LimitCleanupState:
    terminal_cancel_states = {"canceled", "cancelled", "expired", "rejected"}
    live_states = {"live", "new", "open", "pending", "partially_filled"}
    updated_at = timezone.now()
    updates: list[LimitOrder] = []
    cancelled_order_ids: list[str] = []
    had_exchange_errors = False

    for limit_order in pending_orders:
        order_id = str(limit_order.binance_order_id or "").strip()
        client_order_id = str(limit_order.binance_client_order_id or "").strip()
        is_live = pending_snapshot_known and (
            (order_id and order_id in live_order_ids)
            or (client_order_id and client_order_id in live_client_ids)
        )
        terminal_row: Optional[dict[str, Any]] = None
        if not is_live:
            current_row, lookup_had_errors = _load_limit_order_row(
                client,
                inst_id=inst_id,
                limit_order=limit_order,
                require_terminal=False,
            )
            had_exchange_errors = had_exchange_errors or lookup_had_errors
            current_state = str((current_row or {}).get("state") or "").strip().lower()
            if current_state in terminal_cancel_states or current_state == "filled":
                terminal_row = current_row
            elif current_state in live_states:
                is_live = True

        if is_live:
            try:
                cancel_payload = client.cancel_order(inst_id=inst_id, order_id=order_id)
                cancel_rows = cancel_payload.get("data") if isinstance(cancel_payload, dict) else None
                cancel_row = cancel_rows[0] if isinstance(cancel_rows, list) and cancel_rows else None
                cancel_state = str((cancel_row or {}).get("state") or "").strip().lower()
                if cancel_state in terminal_cancel_states or cancel_state == "filled":
                    terminal_row = cancel_row
            except Exception as exc:  # noqa: BLE001
                had_exchange_errors = True
                logger.warning(
                    "closed_order_cleanup_limit_cancel_failed limit_order_id=%s inst_id=%s err=%s",
                    limit_order.id,
                    inst_id,
                    safe_error_summary(exc),
                )
                if is_binance_rate_limit_error(exc):
                    raise
            if terminal_row is None:
                terminal_row, lookup_had_errors = _load_limit_order_row(
                    client,
                    inst_id=inst_id,
                    limit_order=limit_order,
                    require_terminal=True,
                )
                had_exchange_errors = had_exchange_errors or lookup_had_errors

        terminal_state = str((terminal_row or {}).get("state") or "").strip().lower()
        if terminal_state == "filled":
            next_status = LimitOrder.STATUS_FILLED
        elif terminal_state in terminal_cancel_states:
            next_status = LimitOrder.STATUS_CANCELLED
            cancelled_order_ids.append(order_id)
        else:
            next_status = LimitOrder.STATUS_PENDING
            had_exchange_errors = had_exchange_errors or is_live or not pending_snapshot_known
        if limit_order.status != next_status:
            limit_order.status = next_status
            limit_order.updated_at = updated_at
            updates.append(limit_order)

    if updates:
        LimitOrder.objects.bulk_update(updates, ["status", "updated_at"])
    return LimitCleanupState(
        updated_orders=pending_orders,
        cancelled_order_ids=cancelled_order_ids,
        had_exchange_errors=had_exchange_errors,
    )


def cleanup_closed_order_exchange_artifacts(
    order: Order,
    client: BinanceFuturesClient,
    *,
    snapshot: Optional[OrderStrategySnapshot] = None,
    action_prefix: str = "cleanup_closed_order",
) -> ClosedOrderCleanupResult:
    inst_id = to_inst_id(order.symbol)
    algo_client = BinanceAlgoClient(client)
    expected_client_ids = _expected_algo_client_ids(order, snapshot=snapshot)
    client_id_prefixes = {
        build_managed_algo_client_id(order, "sl"),
        build_managed_algo_client_id(order, "tp"),
        build_managed_algo_client_id(order, "mtp"),
        build_managed_algo_client_id(order, "bet"),
        *expected_client_ids,
    }
    stored_tp_ids = [str(item) for item in (order.strategy_tp_algo_ids or []) if item]
    stored_algo_ids = {
        str(order.binance_stop_order_id or "").strip(),
        str(order.binance_stop_market_order_id or "").strip(),
        str(order.manual_take_profit_algo_id or "").strip(),
        *stored_tp_ids,
    }
    stored_algo_ids.discard("")

    had_exchange_errors = False
    cancelled_algo_ids: list[str] = []
    open_algo_rows, open_algo_known = _load_open_algo_rows(
        client,
        inst_id,
        action=f"{action_prefix}_initial_snapshot",
    )
    had_exchange_errors = not open_algo_known
    managed_algo_rows = _select_managed_algo_rows(
        open_algo_rows,
        stored_algo_ids=stored_algo_ids,
        client_id_prefixes=client_id_prefixes,
    )

    managed_algo_ids = [
        str((row or {}).get("algoId") or "").strip()
        for row in managed_algo_rows
        if str((row or {}).get("algoId") or "").strip()
    ]
    cancelled_algo_ids, cancel_had_errors = _cancel_managed_algos(
        algo_client,
        algo_ids=[*stored_algo_ids, *managed_algo_ids],
        inst_id=inst_id,
        action=f"{action_prefix}_algo",
    )
    had_exchange_errors = had_exchange_errors or cancel_had_errors

    pending_limit_rows, pending_limit_known = _load_pending_limit_rows(
        client,
        inst_id,
        action=f"{action_prefix}_limit_snapshot",
    )
    had_exchange_errors = had_exchange_errors or not pending_limit_known

    live_limit_rows = [
        row for row in pending_limit_rows
        if str((row or {}).get("instId") or "") == inst_id
    ]
    live_limit_order_ids = {str((row or {}).get("ordId") or "").strip() for row in live_limit_rows}
    live_limit_client_ids = {
        str((row or {}).get("clientOrderId") or "").strip()
        for row in live_limit_rows
        if (row or {}).get("clientOrderId")
    }

    pending_limit_orders = LimitOrder.objects.filter(
        user=order.user,
        order=order,
        status=LimitOrder.STATUS_PENDING,
    )
    if order.api_key_fingerprint:
        pending_limit_orders = pending_limit_orders.filter(api_key_fingerprint=order.api_key_fingerprint)
    pending_limit_orders = list(pending_limit_orders)

    refreshed_algo_rows, refreshed_algo_known = _load_open_algo_rows(
        client,
        inst_id,
        action=f"{action_prefix}_confirm_snapshot",
    )
    if not refreshed_algo_known:
        refreshed_algo_rows = list(open_algo_rows) if open_algo_known else []
        had_exchange_errors = True
    remaining_algo_rows = _select_managed_algo_rows(
        [
            row
            for row in refreshed_algo_rows
            if refreshed_algo_known
            or str((row or {}).get("algoId") or "").strip() not in cancelled_algo_ids
        ],
        stored_algo_ids=stored_algo_ids,
        client_id_prefixes=client_id_prefixes,
    )

    algo_state = _resolve_residual_algo_state(
        order,
        stored_tp_ids=stored_tp_ids,
        initial_rows=managed_algo_rows,
        remaining_rows=remaining_algo_rows,
        cancelled_algo_ids=cancelled_algo_ids,
        initial_snapshot_known=open_algo_known,
        confirmation_snapshot_known=refreshed_algo_known,
    )
    limit_state = _cleanup_pending_limit_orders(
        client,
        inst_id=inst_id,
        pending_orders=pending_limit_orders,
        pending_snapshot_known=pending_limit_known,
        live_order_ids=live_limit_order_ids,
        live_client_ids=live_limit_client_ids,
    )
    had_exchange_errors = had_exchange_errors or limit_state.had_exchange_errors

    return ClosedOrderCleanupResult(
        stop_order_id=algo_state.stop_order_id,
        stop_market_order_id=algo_state.stop_market_order_id,
        take_profit_algo_ids=algo_state.take_profit_algo_ids,
        manual_take_profit_algo_id=algo_state.manual_take_profit_algo_id,
        pending_limit_updates=limit_state.updated_orders,
        cancelled_algo_ids=cancelled_algo_ids,
        cancelled_limit_order_ids=limit_state.cancelled_order_ids,
        had_exchange_errors=had_exchange_errors,
    )


def best_effort_cleanup_closed_order_exchange_artifacts(
    order: Order,
    client: BinanceFuturesClient,
    *,
    snapshot: Optional[OrderStrategySnapshot] = None,
    action_prefix: str = "cleanup_closed_order",
) -> ClosedOrderCleanupResult:
    """Keep a confirmed close terminal even when artifact cleanup crashes unexpectedly."""
    try:
        return cleanup_closed_order_exchange_artifacts(
            order,
            client,
            snapshot=snapshot,
            action_prefix=action_prefix,
        )
    except Exception as exc:  # noqa: BLE001
        log = logger.warning if is_binance_rate_limit_error(exc) else logger.error
        log(
            "closed_order_cleanup_unexpected_failure action=%s order_id=%s inst_id=%s err=%s",
            action_prefix,
            order.id,
            to_inst_id(order.symbol),
            safe_error_summary(exc),
        )
        return ClosedOrderCleanupResult(
            stop_order_id=str(order.binance_stop_order_id or "").strip(),
            stop_market_order_id=str(order.binance_stop_market_order_id or "").strip(),
            take_profit_algo_ids=[
                str(algo_id)
                for algo_id in (order.strategy_tp_algo_ids or [])
                if str(algo_id).strip()
            ],
            manual_take_profit_algo_id=str(order.manual_take_profit_algo_id or "").strip(),
            pending_limit_updates=[],
            cancelled_algo_ids=[],
            cancelled_limit_order_ids=[],
            had_exchange_errors=True,
        )


def persist_closed_order_cleanup_result(
    order: Order,
    result: ClosedOrderCleanupResult,
) -> bool:
    """Persist residual exchange artifact identities without reopening an order."""
    values = {
        "binance_stop_order_id": result.stop_order_id,
        "binance_stop_market_order_id": result.stop_market_order_id,
        "strategy_tp_algo_ids": result.take_profit_algo_ids,
        "manual_take_profit_algo_id": result.manual_take_profit_algo_id,
    }
    if not result.manual_take_profit_algo_id:
        values.update(
            manual_take_profit_price=None,
            manual_take_profit_order_type="",
        )
    updated = Order.objects.filter(id=order.id, status=1).update(**values)
    if not updated:
        return False
    for field, value in values.items():
        setattr(order, field, value)
    return True
