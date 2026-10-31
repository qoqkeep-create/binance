from __future__ import annotations

from datetime import datetime, timedelta, timezone as dt_timezone
from decimal import Decimal
from typing import Any, Iterable, Optional

from django.db import transaction
from django.utils import timezone

from common.binance import BinanceFuturesClient, to_inst_id
from positions.models import Order
from positions.notifications import enqueue_close_notification

POSITION_SIZE_TOLERANCE = Decimal("0.00000001")


def persist_confirmed_close_transition(
    order: Order,
    *,
    notification: dict[str, Any],
    update_fields: Iterable[str],
) -> bool:
    """Atomically persist a confirmed close and its unique notification event."""
    fields = tuple(dict.fromkeys(str(field) for field in update_fields))
    with transaction.atomic():
        locked_order = (
            Order.objects.select_for_update()
            .filter(id=order.id, status=0)
            .first()
        )
        if locked_order is None:
            return False
        for field in fields:
            setattr(locked_order, field, getattr(order, field))
        locked_order.save(update_fields=list(fields))
        enqueue_close_notification(
            locked_order,
            **notification,
            persist_now=True,
        )

    for field in fields:
        setattr(order, field, getattr(locked_order, field))
    return True


def to_decimal(value) -> Decimal:
    try:
        return Decimal(str(value))
    except Exception:
        return Decimal("0")


def to_timestamp_ms(value) -> int:
    target = value or timezone.now()
    if timezone.is_naive(target):
        target = timezone.make_aware(target, timezone.get_current_timezone())
    return int(target.timestamp() * 1000)


def _row_time_ms(row: dict[str, Any]) -> int:
    return int(str(row.get("time") or "0") or "0")


def _row_qty(row: dict[str, Any]) -> Decimal:
    return abs(to_decimal(row.get("fillSz") or "0"))


def _lifecycle_close_trades(
    order: Order,
    trade_rows: list[dict[str, Any]],
    *,
    end_at=None,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], bool]:
    open_side = "buy" if order.side == 0 else "sell"
    close_side = "sell" if order.side == 0 else "buy"
    expected_position_side = "LONG" if order.side == 0 else "SHORT"
    created_ms = to_timestamp_ms(order.created_at or timezone.now())
    entry_order_id = str(order.binance_order_id or "").strip()
    entry_rows = [
        row
        for row in trade_rows
        if entry_order_id and str(row.get("ordId") or "").strip() == entry_order_id
    ]
    entry_times = [_row_time_ms(row) for row in entry_rows if _row_time_ms(row) > 0]
    lifecycle_start_ms = min(entry_times) if entry_times else created_ms - 5_000

    closed_base = end_at or order.closed_at or timezone.now()
    closed_padding = timedelta(hours=6) if order.closed_at else timedelta(minutes=5)
    lifecycle_end_ms = to_timestamp_ms(closed_base + closed_padding)
    relevant_rows = []
    for row in trade_rows:
        row_time = _row_time_ms(row)
        if not (lifecycle_start_ms <= row_time <= lifecycle_end_ms):
            continue
        raw_position_side = str(row.get("rawPositionSide") or "").strip().upper()
        if raw_position_side in {"LONG", "SHORT"} and raw_position_side != expected_position_side:
            continue
        relevant_rows.append(row)

    relevant_rows.sort(
        key=lambda row: (
            _row_time_ms(row),
            0 if entry_order_id and str(row.get("ordId") or "").strip() == entry_order_id else 1,
        )
    )
    opening_rows: list[dict[str, Any]] = []
    opened_quantity = Decimal("0") if entry_times else abs(order.size or Decimal("0"))
    known_open_quantity = (
        abs(order.exchange_size or Decimal("0"))
        if order.status == 0 and order.exchange_size is not None
        else Decimal("0")
    )
    closed_quantity = Decimal("0")
    close_rows: list[dict[str, Any]] = []
    for row in relevant_rows:
        quantity = _row_qty(row)
        if quantity <= 0:
            continue
        side = str(row.get("side") or "").strip().lower()
        if side == open_side:
            opening_rows.append(row)
            opened_quantity += quantity
            continue
        required_close_quantity = max(opened_quantity, known_open_quantity)
        if side != close_side or closed_quantity + POSITION_SIZE_TOLERANCE >= required_close_quantity:
            continue
        close_rows.append(row)
        closed_quantity += quantity
        if closed_quantity + POSITION_SIZE_TOLERANCE >= required_close_quantity:
            return opening_rows, close_rows, True
    return opening_rows, close_rows, False


def select_order_lifecycle_close_trades(
    order: Order,
    trade_rows: list[dict[str, Any]],
    *,
    end_at=None,
) -> list[dict[str, Any]]:
    _opening_rows, rows, _is_fully_closed = _lifecycle_close_trades(
        order,
        trade_rows,
        end_at=end_at,
    )
    return rows


def summarize_order_close_trades(order: Order, trade_rows: list[dict[str, Any]]) -> dict[str, Any]:
    opening_rows, close_rows, is_fully_closed = _lifecycle_close_trades(order, trade_rows)
    total_close_qty = Decimal("0")
    for row in close_rows:
        total_close_qty += _row_qty(row)
    exact_order_id = str(order.close_binance_order_id or "").strip()
    exact_rows = [row for row in close_rows if str(row.get("ordId") or "") == exact_order_id] if exact_order_id else []
    latest_close_row = (
        max(exact_rows, key=_row_time_ms)
        if exact_rows
        else (max(close_rows, key=_row_time_ms) if close_rows else None)
    )
    return {
        "opening_rows": opening_rows,
        "rows": close_rows,
        "close_qty": total_close_qty,
        "is_fully_closed": is_fully_closed,
        "latest_close_row": latest_close_row,
    }


def fetch_order_trade_rows(
    order: Order,
    client: BinanceFuturesClient,
    *,
    end_at=None,
    limit: int = 1000,
) -> list[dict[str, Any]]:
    inst_id = to_inst_id(order.symbol)
    # The local Order record is written immediately after the exchange fill; include
    # a small lead-in so the opening fill (and its commission) is never excluded.
    trade_start_ms = str(to_timestamp_ms((order.created_at or timezone.now()) - timedelta(minutes=5)))
    close_base = end_at or order.closed_at or timezone.now()
    close_padding = timedelta(hours=6) if order.closed_at else timedelta(minutes=5)
    trade_end_ms = str(to_timestamp_ms(min(close_base + close_padding, timezone.now())))
    payload = client.get_user_trades(
        inst_id=inst_id,
        limit=limit,
        start_time=trade_start_ms,
        end_time=trade_end_ms,
    )
    rows = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(rows, list):
        return []
    return [row for row in rows if isinstance(row, dict)]


def build_close_anchor_from_trade_rows(order: Order, trade_rows: list[dict[str, Any]]) -> Optional[dict[str, Any]]:
    summary = summarize_order_close_trades(order, trade_rows)
    row = summary.get("latest_close_row")
    if not row:
        return None

    close_ts = int(str(row.get("time") or "0") or "0")
    close_dt = datetime.fromtimestamp(close_ts / 1000, tz=dt_timezone.utc) if close_ts > 0 else timezone.now()
    if order.created_at and close_dt < order.created_at - timedelta(seconds=5):
        return None

    close_price = to_decimal(row.get("fillPx") or row.get("price") or "0")
    close_binance_order_id = str(row.get("ordId") or "").strip()
    if close_price <= 0 or not close_binance_order_id:
        return None
    return {
        "close_price": close_price,
        "close_binance_order_id": close_binance_order_id,
        "closed_at": close_dt,
        "is_fully_closed": bool(summary.get("is_fully_closed")),
        "close_qty": summary.get("close_qty") or Decimal("0"),
        "trade_rows": summary.get("rows") or [],
    }


def fetch_close_anchor(order: Order, client: BinanceFuturesClient, *, end_at=None, limit: int = 1000) -> Optional[dict[str, Any]]:
    trade_rows = fetch_order_trade_rows(order, client, end_at=end_at, limit=limit)
    return build_close_anchor_from_trade_rows(order, trade_rows)
