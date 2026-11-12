from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
import time
from typing import Callable, Iterable, Optional

from common.binance import is_binance_rate_limit_error


FILLED = "filled"
PARTIALLY_FILLED = "partially_filled"
PENDING = "pending"
UNKNOWN = "unknown"

_KNOWN_UNFILLED_STATES = {
    "canceled",
    "cancelled",
    "expired",
    "live",
    "new",
    "open",
    "pending",
    "rejected",
}
_SIZE_TOLERANCE = Decimal("0.00000001")


def _decimal(raw) -> Optional[Decimal]:
    try:
        value = Decimal(str(raw))
    except (InvalidOperation, TypeError, ValueError):
        return None
    return value if value.is_finite() and value >= 0 else None


@dataclass(frozen=True)
class EntryExecution:
    state: str
    order_id: str = ""
    filled_size: Decimal = Decimal("0")
    average_price: Decimal = Decimal("0")
    raw_state: str = ""

    @property
    def has_fill(self) -> bool:
        return self.state in {FILLED, PARTIALLY_FILLED}


def parse_entry_execution(row: Optional[dict], *, requested_size: Optional[Decimal] = None) -> EntryExecution:
    if not isinstance(row, dict):
        return EntryExecution(state=UNKNOWN)

    raw_state = str(row.get("state") or "").strip().lower()
    order_id = str(row.get("ordId") or "").strip()
    raw_sizes = [
        row[key] for key in ("fillSz", "accFillSz")
        if row.get(key) not in (None, "")
    ]
    reported_sizes = [_decimal(raw) for raw in raw_sizes]
    filled_size = max((size for size in reported_sizes if size is not None), default=Decimal("0"))
    average_price = _decimal(row.get("avgPx")) or Decimal("0")
    facts = {
        "order_id": order_id, "filled_size": filled_size,
        "average_price": average_price, "raw_state": raw_state,
    }
    # A live post-only order can omit executedQty/avgPrice.  That is a normal
    # waiting state; terminal rows still require an explicit quantity.
    if not reported_sizes:
        if raw_state in {"live", "new", "open", "pending"}:
            return EntryExecution(state=PENDING, **facts)
        return EntryExecution(state=UNKNOWN, **facts)
    if None in reported_sizes:
        return EntryExecution(state=UNKNOWN, **facts)
    if filled_size > 0 and average_price <= 0:
        return EntryExecution(state=UNKNOWN, **facts)

    if filled_size > 0:
        fully_filled = raw_state == FILLED
        if requested_size is not None and requested_size > 0:
            fully_filled = fully_filled or filled_size + _SIZE_TOLERANCE >= requested_size
        return EntryExecution(
            state=FILLED if fully_filled else PARTIALLY_FILLED,
            **facts,
        )

    if raw_state in _KNOWN_UNFILLED_STATES:
        return EntryExecution(state=PENDING, **facts)
    return EntryExecution(state=UNKNOWN, **facts)


def confirm_entry_execution(
    client,
    *,
    inst_id: str,
    requested_size: Decimal,
    order_id: str = "",
    client_order_id: str = "",
    initial_row: Optional[dict] = None,
    retry_delays: Iterable[float] = (0, 1, 1, 2, 2, 2),
    on_incomplete_fill: Optional[Callable[[EntryExecution], object]] = None,
) -> EntryExecution:
    """Return only exchange-confirmed fill facts; never infer a fill from the requested size."""
    best = parse_entry_execution(initial_row, requested_size=requested_size)
    if on_incomplete_fill and best.filled_size > 0 and not best.has_fill:
        on_incomplete_fill(best)
    if best.has_fill:
        return best

    for delay in retry_delays:
        if delay > 0:
            time.sleep(delay)
        try:
            payload = client.get_order(
                inst_id=inst_id,
                **(
                    {"order_id": order_id}
                    if order_id
                    else {"orig_client_order_id": client_order_id}
                ),
            )
        except Exception as exc:  # noqa: BLE001
            if is_binance_rate_limit_error(exc):
                raise
            continue
        rows = payload.get("data") or []
        if not rows:
            continue
        current = parse_entry_execution(rows[0], requested_size=requested_size)
        if current.filled_size < best.filled_size:
            continue
        if on_incomplete_fill and current.filled_size > 0 and not current.has_fill:
            on_incomplete_fill(current)
        if current.has_fill:
            return current
        if current.state == PENDING or current.filled_size > 0:
            best = current
    return best
