from __future__ import annotations

import hashlib
import logging
import time
from dataclasses import dataclass
from typing import Optional
from uuid import uuid4

from django.db.models import Q

from api_bindings.services import get_user_api_key_fingerprint
from common.binance import to_inst_id, to_symbol
from common.errors import safe_error_summary
from positions.models import Order
from trading.models import TradeOpenRequest
from common.trading_mode import TradingMode


logger = logging.getLogger(__name__)
OPEN_REQUEST_EXECUTION_INTENT_KEY = "_execution_intent"


class OpenRequestPayloadConflict(ValueError):
    pass


@dataclass(frozen=True)
class OpenRequestResolution:
    request: TradeOpenRequest
    created: bool


def _request_identity_payload(payload: dict) -> dict:
    """Return only caller-controlled fields used to identify an idempotent request."""
    return {
        key: value
        for key, value in (payload if isinstance(payload, dict) else {}).items()
        if key != OPEN_REQUEST_EXECUTION_INTENT_KEY
    }


def build_client_order_id(prefix: str, account_identity: str | int, symbol: str, request_id) -> str:
    identity = str(account_identity)
    safe_prefix = "".join(ch for ch in str(prefix or "").lower() if ch.isalnum())[:8] or "order"
    seed = str(request_id) if request_id else f"{time.time_ns()}:{uuid4().hex}"
    compact = hashlib.sha256(f"{identity}:{symbol}:{seed}".encode()).hexdigest()[:24]
    return f"rt{safe_prefix}{compact}"


def resolve_open_request(
    *,
    user,
    symbol: str,
    client_request_id: str,
    client_order_id: str,
    request_payload: dict,
    conflict_message: str = "client_request_id 已用于不同的开仓参数",
    trading_mode=TradingMode.ORDINARY,
    api_key_fingerprint="",
) -> OpenRequestResolution:
    open_request, created = TradeOpenRequest.objects.get_or_create(
        user=user,
        trading_mode=trading_mode,
        client_order_id=client_order_id,
        defaults={
            "symbol": symbol,
            "client_request_id": client_request_id,
            "request_payload": request_payload,
            "api_key_fingerprint": api_key_fingerprint or get_user_api_key_fingerprint(user, trading_mode=trading_mode),
        },
    )
    stored = open_request.request_payload if isinstance(open_request.request_payload, dict) else {}
    if not created and _request_identity_payload(stored) != _request_identity_payload(request_payload):
        raise OpenRequestPayloadConflict(conflict_message)
    return OpenRequestResolution(request=open_request, created=created)


def open_request_payload_matches(open_request: TradeOpenRequest, expected_payload: dict) -> bool:
    stored = open_request.request_payload if isinstance(open_request.request_payload, dict) else {}
    return _request_identity_payload(stored) == _request_identity_payload(expected_payload)


def get_open_request_execution_intent(open_request: TradeOpenRequest) -> dict:
    payload = open_request.request_payload if isinstance(open_request.request_payload, dict) else {}
    intent = payload.get(OPEN_REQUEST_EXECUTION_INTENT_KEY)
    return dict(intent) if isinstance(intent, dict) else {}


def record_open_request_execution_intent(open_request: TradeOpenRequest, intent: dict) -> None:
    payload = dict(open_request.request_payload) if isinstance(open_request.request_payload, dict) else {}
    payload[OPEN_REQUEST_EXECUTION_INTENT_KEY] = dict(intent)
    open_request.request_payload = payload
    open_request.save(update_fields=["request_payload", "updated_at"])


def find_existing_order_by_open_request(open_request: TradeOpenRequest) -> Optional[Order]:
    if open_request.order_id:
        existing = Order.objects.filter(id=open_request.order_id, user=open_request.user, trading_mode=open_request.trading_mode).first()
        if existing:
            return existing
    if not open_request.binance_order_id:
        return None
    fingerprint = open_request.api_key_fingerprint or get_user_api_key_fingerprint(open_request.user, trading_mode=open_request.trading_mode)
    account_scope = Q(api_key_fingerprint=fingerprint) if fingerprint else (
        Q(api_key_fingerprint__isnull=True) | Q(api_key_fingerprint="")
    )
    existing = Order.objects.filter(
        account_scope,
        binance_order_id=open_request.binance_order_id,
        symbol=to_symbol(to_inst_id(open_request.symbol)),
        user=open_request.user,
        trading_mode=open_request.trading_mode,
    ).first()
    if existing:
        mark_open_request_submitted(open_request, order_id=existing.id)
    return existing


def find_external_projection_for_open_request(open_request: TradeOpenRequest) -> Optional[Order]:
    """Find a read-time external projection created after this request.

    A fresh position read may adopt the exchange position while a Maker request
    is still unresolved.  Once the Maker fill is confirmed, that projection is
    the same exposure and must be promoted in place instead of creating a
    second local owner.  The request creation boundary prevents an older,
    unrelated manual position from being claimed by a later request.
    """
    intent = get_open_request_execution_intent(open_request)
    try:
        side = int(intent.get("side_code"))
    except (TypeError, ValueError):
        return None
    if side not in (0, 1):
        return None
    symbol = to_symbol(to_inst_id(open_request.symbol))
    fingerprint = open_request.api_key_fingerprint or get_user_api_key_fingerprint(
        open_request.user, trading_mode=open_request.trading_mode
    )
    account_scope = Q(api_key_fingerprint=fingerprint) if fingerprint else (
        Q(api_key_fingerprint__isnull=True) | Q(api_key_fingerprint="")
    )
    return (
        Order.objects.filter(
            account_scope,
            user=open_request.user,
            trading_mode=open_request.trading_mode,
            position_origin=Order.ORIGIN_EXTERNAL,
            status=0,
            symbol=symbol,
            side=side,
            created_at__gte=open_request.created_at,
        )
        .order_by("created_at", "id")
        .first()
    )


def mark_open_request_recovered(open_request: TradeOpenRequest, exchange_order_id: str) -> None:
    open_request.status = TradeOpenRequest.STATUS_RECOVERED
    open_request.binance_order_id = str(exchange_order_id or "")
    open_request.error = ""
    open_request.save(update_fields=["status", "binance_order_id", "error", "updated_at"])


def mark_open_request_submitted(
    open_request: TradeOpenRequest,
    *,
    exchange_order_id: str = "",
    order_id: Optional[int] = None,
    preserve_recovered: bool = True,
) -> None:
    if exchange_order_id:
        open_request.binance_order_id = str(exchange_order_id)
    if order_id is not None:
        open_request.order_id = order_id
    if not preserve_recovered or open_request.status != TradeOpenRequest.STATUS_RECOVERED:
        open_request.status = TradeOpenRequest.STATUS_SUBMITTED
    open_request.error = ""
    update_fields = ["status", "binance_order_id", "error", "updated_at"]
    if order_id is not None:
        update_fields.append("order_id")
    open_request.save(update_fields=update_fields)


def attach_open_request_order(open_request: TradeOpenRequest, order_id: int) -> None:
    open_request.order_id = order_id
    open_request.error = ""
    open_request.save(update_fields=["order_id", "error", "updated_at"])


def record_open_request_uncertain(open_request: TradeOpenRequest, error: Exception | str) -> None:
    open_request.error = safe_error_summary(error, include_type=False)
    open_request.save(update_fields=["error", "updated_at"])


def mark_open_request_failed(open_request: TradeOpenRequest, error: Exception | str) -> None:
    """Close a request after the exchange has durably confirmed zero execution.

    ``record_open_request_error`` intentionally keeps any request with an
    exchange order id unresolved because a transport failure can hide a fill.
    A later read of the order is different: a terminal zero-fill state is
    definitive and must release the account's new-entry guard.
    """
    open_request.status = TradeOpenRequest.STATUS_FAILED
    open_request.error = safe_error_summary(error, include_type=False)
    open_request.save(update_fields=["status", "error", "updated_at"])


def record_open_request_error(open_request: Optional[TradeOpenRequest], error: Exception) -> bool:
    if not open_request:
        return False
    exchange_order_submitted = bool(str(open_request.binance_order_id or "").strip()) or bool(
        getattr(error, "outcome_unknown", False)
    )
    open_request.error = safe_error_summary(error, include_type=False)
    update_fields = ["error", "updated_at"]
    if not exchange_order_submitted:
        open_request.status = TradeOpenRequest.STATUS_FAILED
        update_fields.insert(0, "status")
    try:
        open_request.save(update_fields=update_fields)
    except Exception as persistence_exc:  # noqa: BLE001
        logger.error(
            "open_request_state_persistence_failed request_id=%s exchange_order_id=%s err=%s",
            open_request.id,
            open_request.binance_order_id,
            safe_error_summary(persistence_exc),
        )
    return exchange_order_submitted
