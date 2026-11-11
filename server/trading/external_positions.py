"""Persistent protection for exchange positions with no Web entry owner.

All public mutation entry points require the existing account activity lock.
Exchange writes are journalled before submission; uncertain writes are queried,
never blindly replayed. This module deliberately does not reconstruct old fills.
"""

import hashlib
import logging
from decimal import Decimal, InvalidOperation, ROUND_CEILING, ROUND_FLOOR
from uuid import uuid4

from django.db.models import Exists, OuterRef, Q
from django.utils import timezone

from accounts.mode_settings import lead_stop_loss_amount
from accounts.services import touch_pending_stop_loss
from api_bindings.context import build_trading_account_identity
from api_bindings.models import ApiBinding
from api_bindings.services import (
    get_user_binding_generation,
    get_user_trading_account,
    scope_queryset_to_trading_account,
)
from common.binance import (
    BinanceAlgoClient,
    BinanceApiError,
    should_recover_write_by_client_id,
    to_inst_id,
    to_symbol,
)
from common.binance_rate_limit import RequestPriority
from common.errors import safe_error_summary
from common.trading_mode import TradingMode
from positions.lifecycle import persist_confirmed_close_transition
from positions.models import LimitOrder, Order, TradeNotificationEvent
from positions.notifications import (
    _CLOSE_CLASSIFICATION_EXPLICIT,
    _CLOSE_CLASSIFICATION_FALLBACK,
)
from positions.operation_logs import record_operation
from trading.account_cache import invalidate_position_caches
from trading.locks import distributed_cache_lock, user_trading_activity_lock
from trading.models import TradeOpenRequest
from trading.services import _get_instrument_trade_rules

logger = logging.getLogger(__name__)
LIVE = {"live", "partially_filled"}
TERMINAL = {"filled", "canceled", "cancelled", "expired", "rejected", "failed"}
ALGO_TERMINAL = TERMINAL | {"finished"}


def _log_number(value):
    if value is None:
        return "--"
    text = format(value, "f")
    return text.rstrip("0").rstrip(".") if "." in text else text


def finite_decimal(value):
    try:
        result = Decimal(str(value))
    except (InvalidOperation, ValueError, TypeError) as exc:
        raise ValueError("交易所数值缺失或无效") from exc
    if not result.is_finite():
        raise ValueError("交易所数值非有限值")
    return result


def positive(value):
    result = finite_decimal(value)
    if result <= 0:
        raise ValueError("交易所价格、数量或止损额度必须为正数")
    return result


def tighter_price(side, *prices):
    valid = [
        finite_decimal(p) for p in prices if p is not None and finite_decimal(p) > 0
    ]
    return (max(valid) if side == 0 else min(valid)) if valid else None


def amount_stop_price(side, entry, quantity, risk, tick):
    raw = positive(entry) + (-1 if side == 0 else 1) * positive(risk) / positive(
        quantity
    )
    # Zero/negative theoretical prices still need a valid protective trigger.
    return max(
        positive(tick),
        (raw / tick).to_integral_value(
            rounding=ROUND_CEILING if side == 0 else ROUND_FLOOR,
        )
        * tick,
    )


def _rows(payload):
    rows = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
        raise ValueError("交易所快照格式无效")
    return rows


def _position_key(row):
    qty = finite_decimal(row.get("pos"))
    if not qty:
        return None
    side = str(row.get("posSide") or "").lower()
    # Binance's normalized client response includes rawPositionSide. Keep the
    # read projection tolerant of older adapters and test fixtures that only
    # expose the normalized direction.
    raw_side = str(row.get("rawPositionSide") or ("LONG" if side == "long" else "SHORT")).upper()
    if side not in {"long", "short"} or raw_side not in {"BOTH", "LONG", "SHORT"}:
        raise ValueError("持仓方向或模式无效")
    if raw_side != "BOTH" and raw_side.lower() != side:
        raise ValueError("持仓方向不一致")
    return to_symbol(row["instId"]), 0 if side == "long" else 1


def _positions_from_rows(rows):
    result = {}
    for row in rows:
        key = _position_key(row)
        if key:
            if key in result:
                raise ValueError("交易所返回重复方向持仓")
            result[key] = row
    return result


def _positions(client, inst_id=None):
    return _positions_from_rows(_rows(
        client.get_positions("SWAP", inst_id, budget_priority=RequestPriority.CRITICAL)
    ))


def _target(order, client):
    return _positions(client, to_inst_id(order.symbol)).get((order.symbol, order.side))


def _invalidate(order):
    identity = build_trading_account_identity(
        user_id=order.user_id,
        api_key_fingerprint=order.api_key_fingerprint,
        trading_mode=order.trading_mode,
    )
    invalidate_position_caches(identity, legacy_user_id=order.user_id)


def _save_error(order, error, *, closing=False):
    order.stop_protection_status = (
        Order.STOP_PROTECTION_EMERGENCY if closing else Order.STOP_PROTECTION_PENDING
    )
    order.stop_protection_error = safe_error_summary(error)[:500]
    order.stop_protection_first_failed_at = (
        order.stop_protection_first_failed_at or timezone.now()
    )
    order.stop_protection_last_retry_at = timezone.now()
    order.stop_protection_retry_count += 1
    order.save(
        update_fields=[
            "stop_protection_status",
            "stop_protection_error",
            "stop_protection_first_failed_at",
            "stop_protection_last_retry_at",
            "stop_protection_retry_count",
        ]
    )
    close_request = order.external_close_request
    stop_request = order.external_stop_request
    if closing and close_request.get("status") in {"pending", "rejected"}:
        rejected = close_request["status"] == "rejected"
        record_operation(
            order,
            action="external_close",
            status="failed" if rejected else "pending",
            actor="user" if close_request.get("reason") == "manual" else "system",
            message=(
                "手动仓平仓请求被交易所拒绝，系统将继续核对仓位并保护"
                if rejected
                else "手动仓平仓结果待确认，系统正在按原请求核对，不重复提交"
            ),
        )
    elif stop_request.get("status") in {"pending", "rejected"}:
        rejected = stop_request["status"] == "rejected"
        record_operation(
            order,
            action="external_stop",
            status="failed" if rejected else "pending",
            message=(
                "手动仓止损挂单被交易所拒绝，系统将继续尝试保护"
                if rejected
                else "手动仓止损提交结果待确认，系统正在按原请求核对，不重复挂单"
            ),
        )
    else:
        record_operation(
            order,
            action="external_protection",
            status="failed",
            message=f"手动仓保护核对异常，系统将继续重试：{order.stop_protection_error}",
            event_key=(
                f"external-protection:{order.id}:"
                f"{order.stop_protection_first_failed_at.isoformat()}:failed"
            ),
        )


def _cleanup_closed(order, client):
    # Only IDs explicitly adopted by this lifecycle. Never cancel all account orders.
    journal = dict(order.external_stop_request)
    unresolved = journal.get("status") == "pending"
    if unresolved and journal.get("client_id"):
        try:
            rows = _rows(
                client.get_algo_order_by_client_id(
                    to_inst_id(order.symbol), journal["client_id"]
                )
            )
            if rows:
                journal["algo_id"] = str(rows[0]["algoId"])
                unresolved = False
        except Exception:
            pass
    ids = set(journal.get("retired_ids", [])) | {
        order.binance_stop_market_order_id,
        order.binance_stop_order_id,
        order.manual_take_profit_algo_id,
        journal.get("algo_id", ""),
    }
    remaining = []
    algo = BinanceAlgoClient(client)
    for algo_id in sorted(ids - {""}):
        try:
            algo.cancel_algo_confirmed(
                algo_id, to_inst_id(order.symbol), action="external_closed_cleanup"
            )
        except Exception:
            remaining.append(algo_id)
    journal["retired_ids"] = remaining
    journal["algo_id"] = ""
    journal["status"] = "pending" if unresolved else "closed"
    order.external_stop_request = journal
    order.binance_stop_market_order_id = ""
    order.binance_stop_order_id = ""
    order.manual_take_profit_algo_id = ""
    order.save(
        update_fields=[
            "external_stop_request",
            "binance_stop_market_order_id",
            "binance_stop_order_id",
            "manual_take_profit_algo_id",
        ]
    )
    if remaining or unresolved:
        record_operation(
            order,
            action="external_cleanup",
            status="failed" if remaining else "pending",
            message=(
                "手动仓已确认关闭，关联保护单尚未清理完成，系统将继续核对并清理"
            ),
        )
    elif ids - {""} or order.external_stop_request.get("client_id"):
        record_operation(
            order,
            action="external_cleanup",
            status="success",
            message="手动仓已关闭，关联保护单已清理完成",
            event_key=f"external-cleanup:{order.id}:confirmed",
        )


def _finalize_close(order, client, row=None):
    journal = dict(order.external_close_request)
    row = row or {}
    order.close_binance_order_id = str(
        row.get("ordId") or journal.get("order_id") or ""
    )
    try:
        order.close_price = positive(row.get("avgPx"))
    except ValueError:
        order.close_price = None
    # Past external additions, reductions and fees are unknown. Do not fabricate totals.
    order.pnl = None
    order.pnl_ratio = None
    order.settlement_status = Order.SETTLEMENT_STATUS_ESTIMATED
    order.settlement_error = "手动仓接管前成交及费用不完整，盈亏未核对"
    order.status = 1
    order.closed_at = timezone.now()
    order.exchange_size = Decimal("0")
    order.has_manual_addition = False
    order.external_active_key = None
    journal["status"] = "confirmed"
    order.external_close_request = journal
    event_type = (
        TradeNotificationEvent.TYPE_STOP_LOSS
        if journal.get("reason") in {"loss_exceeded", "stop_crossed"}
        else TradeNotificationEvent.TYPE_MANUAL_TAKE_PROFIT
    )
    fields = [
        "close_binance_order_id",
        "close_price",
        "pnl",
        "pnl_ratio",
        "settlement_status",
        "settlement_error",
        "status",
        "closed_at",
        "exchange_size",
        "has_manual_addition",
        "external_active_key",
        "external_close_request",
    ]
    transitioned = persist_confirmed_close_transition(
        order,
        notification={
            "event_type": event_type,
            "classification_confidence": (
                _CLOSE_CLASSIFICATION_EXPLICIT
                if journal.get("client_id")
                else _CLOSE_CLASSIFICATION_FALLBACK
            ),
        },
        update_fields=fields,
    )
    if transitioned:
        _invalidate(order)
        _cleanup_closed(order, client)
    return transitioned


def _valid_close_receipt(order, journal, row, pos_mode):
    expected = "long" if order.side == 0 else "short"
    if (
        row.get("instId") != to_inst_id(order.symbol)
        or row.get("clientOrderId") != journal["client_id"]
        or row.get("side") != ("sell" if order.side == 0 else "buy")
        or row.get("rawPositionSide")
        != (expected.upper() if pos_mode == "long_short_mode" else "BOTH")
    ):
        raise ValueError("平仓回执身份不匹配")
    if pos_mode == "net_mode" and row.get("reduceOnly") is not True:
        raise ValueError("平仓回执不是只减仓")
    return row


def close_external_position(order, client, pos_mode, reason="manual"):
    """Return True only for a confirmed, durably closed external lifecycle."""
    if order.position_origin != Order.ORIGIN_EXTERNAL or pos_mode not in {
        "net_mode",
        "long_short_mode",
    }:
        raise ValueError("无效的手动仓平仓上下文")
    order.refresh_from_db()
    if order.status == 1:
        return True
    try:
        journal = dict(order.external_close_request)
        position = _target(order, client)
        receipt = None
        if journal.get("status") == "rejected" and position is not None:
            if positive(position["avgPx"]) != positive(
                journal.get("entry_price")
            ) or abs(finite_decimal(position["pos"])) > positive(journal["quantity"]):
                journal["status"] = "superseded"
                order.external_close_request = journal
                order.save(update_fields=["external_close_request"])
                _save_error(order, "拒单后仓位已变化，旧平仓请求不续单；继续风险保护")
                return False
        if journal.get("status") == "pending":
            try:
                receipt_rows = _rows(
                    client.get_order(
                        to_inst_id(order.symbol),
                        orig_client_order_id=journal["client_id"],
                    )
                )
                if receipt_rows:
                    receipt = _valid_close_receipt(
                        order, journal, receipt_rows[0], pos_mode
                    )
            except BinanceApiError as exc:
                if str(exc.code) not in {"-2013", "-2011"}:
                    raise
            if (
                receipt
                and receipt.get("state") == "filled"
                and positive(receipt.get("fillSz")) >= positive(journal["quantity"])
            ):
                return _finalize_close(order, client, receipt)
            if position is None and _target(order, client) is None:
                return _finalize_close(order, client, receipt)
            if not receipt or receipt.get("state") not in TERMINAL:
                _save_error(order, "平仓结果未确认，按原请求核对中", closing=True)
                return False
            # A terminal partial fill is settled before a new attempt can be made.
            filled = max(finite_decimal(receipt.get("fillSz", "0")), Decimal("0"))
            remaining = max(positive(journal["quantity"]) - filled, Decimal("0"))
            if remaining == 0:
                return _finalize_close(order, client, receipt)
            if position is not None and (
                positive(position["avgPx"]) != positive(journal.get("entry_price"))
                or abs(finite_decimal(position["pos"])) > remaining
            ):
                # A changed position is not evidence that the old partial close should resume.
                journal["status"] = "superseded"
                order.external_close_request = journal
                order.save(update_fields=["external_close_request"])
                _save_error(
                    order, "仓位已变化，旧平仓请求已终止续单；按新鲜仓位继续保护"
                )
                return False
            journal = {
                "remaining_cap": str(remaining),
                "reason": journal.get("reason", reason),
            }
        if position is None:
            if _target(order, client) is None:
                return _finalize_close(order, client, receipt)
            return False
        quantity = abs(finite_decimal(position["pos"]))
        if journal.get("remaining_cap"):
            quantity = min(quantity, positive(journal["remaining_cap"]))
        journal = {
            "client_id": f"tt{order.id}ec{uuid4().hex[:18]}",
            "status": "pending",
            "quantity": str(quantity),
            "entry_price": str(positive(position["avgPx"])),
            "position_update_time": str(position.get("updateTime") or ""),
            "reason": journal.get("reason", reason)
            if journal.get("status") != "superseded"
            else reason,
            "submitted_at": timezone.now().isoformat(),
        }
        order.external_close_request = journal
        order.stop_protection_status = Order.STOP_PROTECTION_EMERGENCY
        order.save(update_fields=["external_close_request", "stop_protection_status"])
        close_reason = {
            "loss_exceeded": f"浮亏已超过止损额度 {_log_number(order.stop_loss_amount)} USDT",
            "stop_crossed": f"价格已触及止损保护价 {_log_number(order.current_stop_price)}",
            "manual": "用户点击立即平仓",
        }.get(journal["reason"], "手动仓需要平仓")
        record_operation(
            order,
            action="external_close_request",
            status="pending",
            actor="user" if journal["reason"] == "manual" else "system",
            message=f"{close_reason}，准备提交市价平仓，数量 {_log_number(quantity)}",
            event_key=f"external-close:{journal['client_id']}:requested",
        )
        try:
            rows = _rows(
                client.close_position(
                    to_inst_id(order.symbol),
                    pos_side=("long" if order.side == 0 else "short")
                    if pos_mode == "long_short_mode"
                    else None,
                    expected_side="long" if order.side == 0 else "short",
                    client_order_id=journal["client_id"],
                    max_quantity=quantity,
                )
            )
        except Exception as exc:
            if not should_recover_write_by_client_id(exc) and isinstance(
                exc, BinanceApiError
            ):
                journal["status"] = "rejected"
                order.external_close_request = journal
                order.save(update_fields=["external_close_request"])
            raise
        if rows:
            receipt = _valid_close_receipt(order, journal, rows[0], pos_mode)
            # Re-read after a short fill; a position may have changed before POST.
            if (
                receipt.get("state") == "filled"
                and positive(receipt.get("fillSz")) >= quantity
            ):
                return _finalize_close(order, client, receipt)
        if _target(order, client) is None and _target(order, client) is None:
            return _finalize_close(order, client, receipt)
        _save_error(order, "平仓请求已提交，成交结果待核对", closing=True)
    except Exception as exc:
        _save_error(order, exc, closing=True)
    return False


def _valid_stop(order, row, pos_mode):
    if (
        row.get("instId") != to_inst_id(order.symbol)
        or row.get("state") not in LIVE
        or row.get("algoType") not in {"STOP", "STOP_MARKET"}
        or row.get("side") != ("sell" if order.side == 0 else "buy")
    ):
        return False
    expected_raw = (
        ("LONG" if order.side == 0 else "SHORT")
        if pos_mode == "long_short_mode"
        else "BOTH"
    )
    if row.get("rawPositionSide") != expected_raw:
        return False
    if pos_mode == "net_mode" and not (
        row.get("reduceOnly") is True or row.get("closePosition") is True
    ):
        return False
    return positive(row.get("slTriggerPx")) > 0


def _full_stop(row, quantity):
    return row.get("closePosition") is True or finite_decimal(row.get("sz")) >= quantity


def _persist_floor(order, price, working_type):
    order.current_stop_price = price
    order.stop_loss_price = price
    if not order.initial_stop_price:
        order.initial_stop_price = price
    journal = dict(order.external_stop_request)
    journal["floor_working_type"] = working_type
    order.external_stop_request = journal
    order.save(
        update_fields=[
            "current_stop_price",
            "stop_loss_price",
            "initial_stop_price",
            "external_stop_request",
        ]
    )


def _needs_cleanup(queryset):
    return queryset.filter(position_origin=Order.ORIGIN_EXTERNAL, status=1).filter(
        Q(external_stop_request__retired_ids__0__isnull=False)
        | Q(external_stop_request__status="pending")
        | ~Q(binance_stop_market_order_id="")
        | ~Q(binance_stop_order_id="")
        | ~Q(manual_take_profit_algo_id="")
    )


def _previous_stop_identities(order):
    # A failed cleanup from an older lifecycle must never donate protection to a new one.
    ids, client_ids = set(), set()
    prior = _needs_cleanup(
        Order.objects.filter(
            user_id=order.user_id,
            trading_mode=order.trading_mode,
            api_key_fingerprint=order.api_key_fingerprint,
            symbol=order.symbol,
            side=order.side,
        )
    )
    for old in prior.only(
        "external_stop_request", "binance_stop_market_order_id", "binance_stop_order_id"
    ):
        journal = old.external_stop_request
        ids.update(journal.get("retired_ids", []))
        ids.update(
            [
                journal.get("algo_id"),
                old.binance_stop_market_order_id,
                old.binance_stop_order_id,
            ]
        )
        client_ids.add(journal.get("client_id"))
    return ids - {None, ""}, client_ids - {None, ""}


def _protect(order, client, pos_mode, position, *, closing=False):
    previous_journal = dict(order.external_stop_request)
    previous_price = order.current_stop_price
    previous_algo_id = str(order.binance_stop_market_order_id or "")
    previous_failure = order.stop_protection_first_failed_at
    terminal_stop = previous_journal.get("status") == "terminal"
    submitted_stop = False
    quantity = abs(finite_decimal(position["pos"]))
    entry = positive(position["avgPx"])
    tick = positive(_get_instrument_trade_rules(to_inst_id(order.symbol))["tickSz"])
    price = amount_stop_price(
        order.side,
        entry,
        quantity * positive(position.get("ctVal", "1")),
        order.stop_loss_amount,
        tick,
    )
    budget_price = price
    price = tighter_price(order.side, price, order.current_stop_price)
    working_type = (
        order.external_stop_request.get("floor_working_type", "CONTRACT_PRICE")
        if order.current_stop_price and price == order.current_stop_price
        else "CONTRACT_PRICE"
    )
    # The saved floor keeps its trigger reference across restarts and cancellations.
    ticker = _rows(client.get_ticker(to_inst_id(order.symbol)))
    last = positive(ticker[0]["last"])
    saved_type = order.external_stop_request.get("floor_working_type", "CONTRACT_PRICE")
    reference = positive(position.get("markPx")) if saved_type == "MARK_PRICE" else last
    if order.current_stop_price and not closing:
        if (
            reference <= order.current_stop_price
            if order.side == 0
            else reference >= order.current_stop_price
        ):
            close_external_position(order, client, pos_mode, reason="stop_crossed")
            return
    previous_ids, previous_clients = _previous_stop_identities(order)
    candidates = [
        row
        for row in _rows(
            client.get_pending_algo_orders(
                inst_id=to_inst_id(order.symbol),
                budget_priority=RequestPriority.CRITICAL,
            )
        )
        if row.get("algoId") not in previous_ids
        and row.get("clientAlgoId") not in previous_clients
        and _valid_stop(order, row, pos_mode)
    ]
    journal = dict(order.external_stop_request)
    tracked_id = str(journal.get("algo_id") or "")
    if (
        journal.get("status") == "live"
        and tracked_id
        and not any(str(r["algoId"]) == tracked_id for r in candidates)
    ):
        detail = _rows(
            client.get_pending_algo_orders(
                inst_id=to_inst_id(order.symbol),
                algo_id=tracked_id,
                budget_priority=RequestPriority.CRITICAL,
            )
        )
        tracked = next((r for r in detail if str(r.get("algoId")) == tracked_id), None)
        if tracked is None:
            raise ValueError("原止损状态未确认，继续核对，避免重复挂单")
        if tracked.get("state") in ALGO_TERMINAL:
            # Explicit cancellation allows immediate replacement, without an unknown-write retry.
            journal["status"] = "terminal"
            order.external_stop_request = journal
            order.save(update_fields=["external_stop_request"])
            terminal_stop = True
            record_operation(
                order,
                action="external_stop_missing",
                status="info",
                message="检测到原手动仓止损已结束或被取消，系统将恢复止损保护",
                event_key=f"external-stop:{tracked_id}:terminal",
                dedupe=False,
            )
        elif _valid_stop(order, tracked, pos_mode):
            candidates.append(tracked)
        else:
            raise ValueError("原止损正在触发或状态未确认")
    full = [row for row in candidates if _full_stop(row, quantity)]
    previous_protection_price = previous_price or tighter_price(
        order.side, *(row["slTriggerPx"] for row in full)
    )
    # Select a price and its corresponding reference together; never relabel MARK as CONTRACT.
    for row in full:
        trigger = positive(row["slTriggerPx"])
        if tighter_price(order.side, price, trigger) != price or (
            trigger == price == budget_price and not order.current_stop_price
        ):
            price, working_type = trigger, row.get("workingType")
    if working_type not in {"CONTRACT_PRICE", "MARK_PRICE"}:
        raise ValueError("无法确认止损触发参考价类型")
    _persist_floor(order, price, working_type)
    reference = (
        positive(position.get("markPx")) if working_type == "MARK_PRICE" else last
    )
    if reference <= price if order.side == 0 else reference >= price:
        if not closing:
            close_external_position(order, client, pos_mode, reason="stop_crossed")
        return
    journal = dict(order.external_stop_request)
    if journal.get("status") == "pending":
        recovered = next(
            (
                row
                for row in candidates
                if row.get("clientAlgoId") == journal["client_id"]
            ),
            None,
        )
        if not recovered:
            recovered_rows = _rows(
                client.get_algo_order_by_client_id(
                    to_inst_id(order.symbol), journal["client_id"]
                )
            )
            recovered = recovered_rows[0] if recovered_rows else None
        if not recovered:
            raise ValueError("止损提交结果待确认")
        if recovered.get("state") in ALGO_TERMINAL:
            journal["status"] = "terminal"
            order.external_stop_request = journal
            order.save(update_fields=["external_stop_request"])
            # Reconcile fresh position after terminal protection, never reuse stale quantity.
            return
        if not _valid_stop(order, recovered, pos_mode):
            raise ValueError("止损恢复身份不匹配")
        if recovered not in candidates:
            candidates.append(recovered)
            if _full_stop(recovered, quantity):
                full.append(recovered)
    chosen = next(
        (
            row
            for row in full
            if row["algoType"] == "STOP_MARKET"
            and positive(row["slTriggerPx"]) == price
            and row.get("workingType") == working_type
            and row.get("priceProtect") is not True
        ),
        None,
    )
    if not chosen:
        # A live but outdated recovered request can be safely replaced; its ID stays tracked.
        retired = set(journal.get("retired_ids", []))
        if journal.get("algo_id"):
            retired.add(journal["algo_id"])
        if journal.get("status") == "pending":
            retired.add(str(recovered["algoId"]))
        journal = {
            "client_id": f"tt{order.id}es{uuid4().hex[:18]}",
            "status": "pending",
            "price": str(price),
            "quantity": str(quantity),
            "retired_ids": sorted(retired),
            "floor_working_type": working_type,
            "submitted_at": timezone.now().isoformat(),
        }
        order.external_stop_request = journal
        order.save(update_fields=["external_stop_request"])
        submitted_stop = True
        try:
            # One POST; journal owns delayed visibility and unknown-write recovery.
            response = _rows(
                client.place_stop_market_order(
                    to_inst_id(order.symbol),
                    side="sell" if order.side == 0 else "buy",
                    size=str(quantity),
                    trigger_price=str(price),
                    pos_side=("long" if order.side == 0 else "short")
                    if pos_mode == "long_short_mode"
                    else None,
                    client_algo_id=journal["client_id"],
                    working_type=working_type,
                )
            )
            if response:
                journal["algo_id"] = str(response[0]["algoId"])
                order.external_stop_request = journal
                order.save(update_fields=["external_stop_request"])
        except Exception as exc:
            if not should_recover_write_by_client_id(exc) and isinstance(
                exc, BinanceApiError
            ):
                journal["status"] = "rejected"
                order.external_stop_request = journal
                order.save(update_fields=["external_stop_request"])
            raise
        rows = _rows(
            client.get_algo_order_by_client_id(
                to_inst_id(order.symbol), journal["client_id"]
            )
        )
        chosen = rows[0] if rows else None
        if (
            not chosen
            or not _valid_stop(order, chosen, pos_mode)
            or not _full_stop(chosen, quantity)
            or positive(chosen["slTriggerPx"]) != price
            or chosen["algoType"] != "STOP_MARKET"
            or chosen.get("workingType") != working_type
            or chosen.get("priceProtect") is True
            or chosen.get("clientAlgoId") != journal["client_id"]
        ):
            raise ValueError("新止损尚未确认有效，保留原保护")
    # Confirmed protection is durable before any superseded order is canceled.
    journal.update(
        status="live",
        algo_id=str(chosen["algoId"]),
        client_id=str(chosen.get("clientAlgoId") or ""),
    )
    retired = set(journal.get("retired_ids", []))
    retired.update(
        str(row["algoId"])
        for row in full
        if str(row["algoId"]) != str(chosen["algoId"])
    )
    retired.discard(str(chosen["algoId"]))
    journal["retired_ids"] = sorted(retired)
    order.external_stop_request = journal
    order.binance_stop_market_order_id = str(chosen["algoId"])
    order.stop_loss_order_created_at = timezone.now()
    if not closing:
        order.stop_protection_status = Order.STOP_PROTECTION_COMPLETE
        order.stop_protection_error = ""
        order.stop_protection_retry_count = 0
        order.stop_protection_first_failed_at = None
    order.save(
        update_fields=[
            "external_stop_request",
            "binance_stop_market_order_id",
            "stop_loss_order_created_at",
            "stop_protection_status",
            "stop_protection_error",
            "stop_protection_retry_count",
            "stop_protection_first_failed_at",
        ]
    )
    stop_changed = (
        previous_algo_id != str(chosen["algoId"])
        or previous_price != price
        or previous_journal.get("status") != "live"
    )
    if stop_changed:
        price_label = _log_number(price)
        if previous_protection_price and previous_protection_price != price:
            description = f"手动仓止损已收紧：{_log_number(previous_protection_price)} → {price_label}"
        elif terminal_stop:
            description = f"手动仓止损已恢复，触发价 {price_label}"
        elif previous_journal.get("status") == "pending" and not submitted_stop:
            description = f"止损提交结果已核对，手动仓止损已确认有效，触发价 {price_label}"
        elif submitted_stop:
            description = f"手动仓止损已设置，触发价 {price_label}"
        else:
            description = f"已纳管已有手动仓止损，触发价 {price_label}"
        reference_name = "标记价格" if working_type == "MARK_PRICE" else "合约最新价"
        record_operation(
            order,
            action="external_stop",
            status="success",
            message=(
                f"{description}；按{reference_name}触发，覆盖数量 {_log_number(quantity)}，"
                f"止损额度 {_log_number(order.stop_loss_amount)} USDT"
            ),
            event_key=(
                f"external-stop:{order.id}:{chosen['algoId']}:"
                f"{price_label}:{working_type}:confirmed"
            ),
            dedupe=False,
        )
    if previous_failure and not closing and not stop_changed:
        record_operation(
            order,
            action="external_protection",
            status="success",
            message=f"手动仓保护异常已恢复，已确认全仓止损有效，触发价 {_log_number(price)}",
            event_key=(
                f"external-protection:{order.id}:{previous_failure.isoformat()}:recovered"
            ),
            dedupe=False,
        )
    algo = BinanceAlgoClient(client)
    for algo_id in list(journal["retired_ids"]):
        # Never retire a now-stricter partial manual stop or an unrelated order.
        row = next((r for r in candidates if str(r["algoId"]) == algo_id), None)
        if (
            row
            and tighter_price(order.side, price, positive(row["slTriggerPx"])) != price
        ):
            continue
        try:
            algo.cancel_algo_confirmed(
                algo_id, to_inst_id(order.symbol), action="external_replace_stop"
            )
        except Exception:
            record_operation(
                order,
                action="external_stop_cancel",
                status="failed",
                message="新手动仓止损已生效，旧止损清理失败，系统将继续重试",
                event_key=f"external-stop:{order.id}:{algo_id}:cancel-failed",
            )
            continue
        journal["retired_ids"].remove(algo_id)
        record_operation(
            order,
            action="external_stop_cancel",
            status="success",
            message="新手动仓止损已生效，旧止损已清理",
            event_key=f"external-stop:{order.id}:{algo_id}:cancel-confirmed",
            dedupe=False,
        )
    order.external_stop_request = journal
    order.save(update_fields=["external_stop_request"])
    _invalidate(order)


def reconcile_external_order(order, client, pos_mode, position):
    try:
        closing = order.external_close_request.get("status") in {"pending", "rejected"}
        if closing or position is None:
            if close_external_position(order, client, pos_mode):
                return
            position = _target(order, client)
            if position is None:
                return
        quantity, entry = (
            abs(finite_decimal(position["pos"])),
            positive(position["avgPx"]),
        )
        order.exchange_size, order.open_price = quantity, entry
        order.position_amount = quantity * entry
        order.save(update_fields=["exchange_size", "open_price", "position_amount"])
        if order.stop_loss_amount <= 0:
            risk = _risk_amount(order.user, order.trading_mode)
            order.stop_loss_amount = positive(risk)
            order.save(update_fields=["stop_loss_amount"])
        # Missing/malformed PnL must never be normalized to zero.
        floating_loss = max(-finite_decimal(position.get("rawUpl")), Decimal("0"))
        if floating_loss > order.stop_loss_amount and not closing:
            if close_external_position(order, client, pos_mode, reason="loss_exceeded"):
                return
            closing = True
            position = _target(order, client)
            if position is None:
                return
        _protect(order, client, pos_mode, position, closing=closing)
    except Exception as exc:
        _save_error(
            order,
            exc,
            closing=order.external_close_request.get("status")
            in {"pending", "rejected"},
        )


def _risk_amount(user, mode):
    if mode == TradingMode.LEAD:
        return finite_decimal(lead_stop_loss_amount(user))
    touch_pending_stop_loss(user)
    return finite_decimal(user.stop_loss_amount)


def _scoped(model, user, account):
    return scope_queryset_to_trading_account(
        model.objects.filter(user=user),
        api_key_fingerprint=account.api_key_fingerprint,
        binding_created_at=account.binding_created_at,
        trading_mode=account.trading_mode,
    )


def _adopt_external_positions(user, account, positions, *, allow_unresolved_requests=False):
    """Create local owners for exchange positions without exchange writes."""
    local = list(_scoped(Order, user, account).filter(status=0))
    owned = {(o.symbol, o.side) for o in local}
    blocked_symbols = set(
        _scoped(LimitOrder, user, account)
        .filter(status=LimitOrder.STATUS_PENDING)
        .values_list("symbol", flat=True)
    )
    blocked_symbols.update(
        _scoped(TradeOpenRequest, user, account)
        .filter(order_id__isnull=True)
        .exclude(status=TradeOpenRequest.STATUS_FAILED)
        .annotate(
            has_web_owner=Exists(
                _scoped(Order, user, account)
                .filter(
                    position_origin=Order.ORIGIN_WEB,
                    symbol=OuterRef("symbol"),
                    binance_order_id=OuterRef("binance_order_id"),
                )
                .exclude(binance_order_id="")
            ),
            has_unfilled_terminal_limit=Exists(
                _scoped(LimitOrder, user, account).filter(
                    symbol=OuterRef("symbol"),
                    binance_order_id=OuterRef("binance_order_id"),
                    status__in=[LimitOrder.STATUS_CANCELLED, LimitOrder.STATUS_EXPIRED],
                    filled_size=0,
                ).exclude(binance_order_id="")
            ),
        )
        # A durable Web owner or confirmed zero-fill cancellation resolves the
        # request's ownership. Unknown writes and unadopted fills stay blocked.
        .filter(has_web_owner=False, has_unfilled_terminal_limit=False)
        .values_list("symbol", flat=True)
    )
    for key, position in positions.items():
        symbol, side = key
        # A read of the exchange snapshot must still expose a real position
        # when an older open request is unresolved. The request remains a
        # durable risk guard for new entries; the external owner lets the
        # position page and background protection see the actual exposure.
        if key in owned or (symbol in blocked_symbols and not allow_unresolved_requests):
            continue
        quantity, entry = (
            abs(finite_decimal(position["pos"])),
            positive(position["avgPx"]),
        )
        slot = hashlib.sha256(
            f"{user.id}:{account.identity}:{symbol}:{side}".encode()
        ).hexdigest()
        risk = max(_risk_amount(user, account.trading_mode), Decimal("0"))
        order, created = Order.objects.get_or_create(
            external_active_key=slot,
            defaults={
                "user": user,
                "trading_mode": account.trading_mode,
                "api_key_fingerprint": account.api_key_fingerprint,
                "position_origin": Order.ORIGIN_EXTERNAL,
                "binance_order_id": None,
                "symbol": symbol,
                "side": side,
                "open_price": entry,
                "size": quantity,
                "exchange_size": quantity,
                "position_amount": quantity * entry,
                "leverage": max(1, int(finite_decimal(position.get("lever", "1")))),
                "stop_loss_price": Decimal("0"),
                "stop_loss_amount": risk,
                "stop_protection_status": Order.STOP_PROTECTION_PENDING,
                "entry_fee_status": Order.ENTRY_FEE_STATUS_ESTIMATED,
                "settlement_status": Order.SETTLEMENT_STATUS_ESTIMATED,
            },
        )
        local.append(order)
        if created:
            record_operation(
                order,
                action="external_adopt",
                status="info",
                message=(
                    f"发现并纳管手动仓，数量 {_log_number(quantity)}，均价 {_log_number(entry)}，"
                    f"止损额度 {_log_number(risk)} USDT"
                ),
                event_key=f"external-adopt:{order.id}",
            )
            _invalidate(order)
    return local


def _scan_account(user, account):
    client = account.create_futures_client()
    config = _rows(client.get_account_config())
    mode = config[0].get("posMode") if config else None
    if mode not in {"net_mode", "long_short_mode"}:
        raise ValueError("无法确认账户持仓模式")
    positions = _positions(client)
    local = _adopt_external_positions(user, account, positions)
    for order in local:
        if order.position_origin == Order.ORIGIN_EXTERNAL:
            reconcile_external_order(
                order, client, mode, positions.get((order.symbol, order.side))
            )
    # Failed cleanup stays tracked even after the lifecycle releases its unique slot.
    for order in _needs_cleanup(_scoped(Order, user, account))[:20]:
        _cleanup_closed(order, client)


def adopt_external_position_snapshot(user, account, rows):
    """Adopt a fresh position response for a read path without protection writes.

    The position endpoint already fetched this snapshot.  Reusing it removes
    the old ten second visibility gap while leaving stop placement and forced
    closes to the serialized background reconciler.
    """
    positions = _positions_from_rows(_rows({"data": rows}))
    return _adopt_external_positions(
        user,
        account,
        positions,
        allow_unresolved_requests=True,
    )


def reconcile_external_positions(*, trading_mode=TradingMode.ORDINARY):
    processed = 0
    with distributed_cache_lock(
        f"external-position-scan:{trading_mode}", timeout=120
    ) as locked:
        if not locked:
            return 0
        for binding in ApiBinding.objects.filter(
            status=1, trading_mode=trading_mode
        ).select_related("user"):
            try:
                account = get_user_trading_account(
                    binding.user, active_only=True, trading_mode=trading_mode
                )
                if account is None:
                    continue
                with user_trading_activity_lock(account.identity) as account_locked:
                    if (
                        not account_locked
                        or get_user_binding_generation(
                            binding.user, trading_mode=trading_mode
                        )
                        != account.generation
                    ):
                        continue
                    _scan_account(binding.user, account)
                    processed += 1
            except Exception as exc:
                logger.warning(
                    "external position scan user=%s mode=%s failed: %s",
                    binding.user_id,
                    trading_mode,
                    safe_error_summary(exc),
                )
    return processed
