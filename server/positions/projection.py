from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from typing import Any


ZERO = Decimal("0")


def decimal_or_zero(value: Any) -> Decimal:
    try:
        return Decimal(str(value))
    except (InvalidOperation, TypeError, ValueError):
        return ZERO


@dataclass(frozen=True)
class PositionFinancialProjection:
    position_size: Decimal
    average_price: Decimal
    current_price: Decimal
    contract_value: Decimal
    position_scale: Decimal
    position_amount: Decimal
    unrealized_pnl: Decimal
    margin: Decimal
    pnl_ratio: Decimal
    leverage: int


def project_position_financials(
    *,
    row: dict[str, Any],
    side: int,
    fallback_open_price: Decimal,
    current_price: Decimal,
    stored_leverage: int | Decimal,
) -> PositionFinancialProjection:
    average_price = decimal_or_zero(row.get("avgPx") or fallback_open_price)
    position_size = abs(decimal_or_zero(row.get("pos") or "0"))
    contract_value = decimal_or_zero(row.get("ctVal") or "0")
    position_scale = position_size * (contract_value if contract_value > 0 else Decimal("1"))
    position_amount = (
        position_scale * current_price
        if position_scale > 0 and current_price > 0
        else abs(decimal_or_zero(row.get("notionalUsd") or "0"))
    )

    raw_unrealized_pnl = row.get("upl")
    has_exchange_pnl = raw_unrealized_pnl is not None and str(raw_unrealized_pnl).strip() != ""
    unrealized_pnl = decimal_or_zero(raw_unrealized_pnl) if has_exchange_pnl else ZERO
    if not has_exchange_pnl and position_scale > 0 and average_price > 0 and current_price > 0:
        price_delta = current_price - average_price if side == 0 else average_price - current_price
        unrealized_pnl = price_delta * position_scale

    exchange_leverage = decimal_or_zero(row.get("lever") or "0")
    leverage = int(max(exchange_leverage, decimal_or_zero(stored_leverage), Decimal("1")))
    exchange_margin = decimal_or_zero(row.get("margin") or "0")
    estimated_margin = position_amount / Decimal(leverage) if position_amount > 0 else ZERO
    margin = exchange_margin if exchange_margin > 0 else estimated_margin
    pnl_ratio = (unrealized_pnl / margin) * Decimal("100") if margin > 0 else ZERO

    return PositionFinancialProjection(
        position_size=position_size,
        average_price=average_price,
        current_price=current_price,
        contract_value=contract_value,
        position_scale=position_scale,
        position_amount=position_amount,
        unrealized_pnl=unrealized_pnl,
        margin=margin,
        pnl_ratio=pnl_ratio,
        leverage=leverage,
    )


def project_trigger_pnl(
    *,
    side: int,
    average_price: Decimal,
    trigger_price: Decimal,
    position_scale: Decimal,
) -> Decimal:
    if position_scale <= 0:
        return ZERO
    price_delta = trigger_price - average_price if side == 0 else average_price - trigger_price
    return price_delta * position_scale
