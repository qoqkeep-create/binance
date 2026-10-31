from __future__ import annotations

import time
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from typing import Callable, Optional

from common.binance import (
    BinanceApiError,
    BinanceFuturesClient,
    is_binance_rate_limit_error,
    should_recover_write_by_client_id,
)
from trading.models import TradeOpenRequest
from trading.open_requests import mark_open_request_recovered, record_open_request_uncertain


ORDER_RECOVERY_RETRY_DELAYS_SECONDS = (0.0, 0.15, 0.35, 0.75, 1.25)


@dataclass(frozen=True)
class ExchangeOrderSubmission:
    payload: Optional[dict]
    uncertain_error: Optional[Exception] = None

    @property
    def confirmed(self) -> bool:
        return self.payload is not None


def _intent_decimal(value) -> Decimal:
    try:
        return Decimal(str(value))
    except (InvalidOperation, TypeError, ValueError):
        return Decimal("0")


def validate_recovered_exchange_order(
    row: dict,
    intent: dict,
    *,
    action_label: str,
    require_limit_price: bool = False,
) -> None:
    """Reject recovery when the exchange order differs from the persisted execution intent."""
    if not isinstance(row, dict) or not isinstance(intent, dict) or not intent:
        raise BinanceApiError(
            f"{action_label}原执行参数缺失，已停止自动接管",
            outcome_unknown=True,
        )

    expected_side = str(intent.get("open_side") or "").strip().lower()
    actual_side = str(row.get("side") or "").strip().lower()
    expected_size = _intent_decimal(intent.get("size"))
    actual_size = _intent_decimal(row.get("sz") or row.get("origQty"))
    mismatch = (
        expected_side not in {"buy", "sell"}
        or actual_side != expected_side
        or expected_size <= 0
        or actual_size <= 0
        or abs(actual_size - expected_size) > Decimal("0.00000001")
    )

    expected_pos_side = str(intent.get("pos_side") or "").strip().lower()
    actual_pos_side = str(row.get("posSide") or "").strip().lower()
    if expected_pos_side and actual_pos_side != expected_pos_side:
        mismatch = True

    if require_limit_price:
        expected_price = _intent_decimal(intent.get("entry_price"))
        actual_price = _intent_decimal(row.get("px") or row.get("limitPx") or row.get("avgPx"))
        if (
            expected_price <= 0
            or actual_price <= 0
            or abs(actual_price - expected_price) > Decimal("0.00000001")
        ):
            mismatch = True

    if mismatch:
        raise BinanceApiError(
            f"已提交{action_label}与原请求不一致，已停止自动接管",
            outcome_unknown=True,
        )


def require_exchange_order_row(payload: Optional[dict], *, action_label: str) -> dict:
    """Validate the common Binance order-write envelope and return its first row."""
    rows = (payload or {}).get("data") or []
    if not rows or not isinstance(rows[0], dict):
        raise BinanceApiError(
            f"{action_label}结果未确认，未获取到订单结果",
            outcome_unknown=True,
        )
    row = rows[0]
    if str(row.get("sCode") or "0") != "0":
        raise BinanceApiError(str(row.get("sMsg") or f"{action_label}失败"))
    if not str(row.get("ordId") or "").strip():
        raise BinanceApiError(
            f"{action_label}结果未确认，未获取到订单号",
            outcome_unknown=True,
        )
    return row


def load_exchange_order_by_client_order_id(
    client: BinanceFuturesClient,
    *,
    inst_id: str,
    client_order_id: str,
) -> Optional[dict]:
    if not client_order_id:
        return None
    for delay in ORDER_RECOVERY_RETRY_DELAYS_SECONDS:
        if delay:
            time.sleep(delay)
        try:
            payload = client.get_order(
                inst_id=inst_id,
                orig_client_order_id=client_order_id,
            )
            rows = payload.get("data") or []
        except BinanceApiError as exc:
            if is_binance_rate_limit_error(exc):
                return None
            continue
        except Exception:  # noqa: BLE001
            continue
        if rows and str(rows[0].get("ordId") or "").strip():
            return rows[0]
    return None


def submit_or_recover_exchange_order(
    *,
    client: BinanceFuturesClient,
    open_request: TradeOpenRequest,
    inst_id: str,
    client_order_id: str,
    submit: Callable[[], dict],
    recovered_row: Optional[dict] = None,
) -> ExchangeOrderSubmission:
    row = recovered_row
    if row is None:
        try:
            payload = submit()
            require_exchange_order_row(payload, action_label="下单")
            return ExchangeOrderSubmission(payload=payload)
        except Exception as exc:  # noqa: BLE001
            if not should_recover_write_by_client_id(exc):
                raise
            row = load_exchange_order_by_client_order_id(
                client,
                inst_id=inst_id,
                client_order_id=client_order_id,
            )
            if row is None:
                record_open_request_uncertain(open_request, exc)
                return ExchangeOrderSubmission(payload=None, uncertain_error=exc)
            mark_open_request_recovered(open_request, str(row.get("ordId") or ""))
            record_open_request_uncertain(open_request, exc)
            return ExchangeOrderSubmission(
                payload={"code": "0", "data": [row]},
                uncertain_error=exc,
            )

    mark_open_request_recovered(open_request, str(row.get("ordId") or ""))
    return ExchangeOrderSubmission(payload={"code": "0", "data": [row]})
