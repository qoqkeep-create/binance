"""Read-only projections of entry orders; never reconcile or submit exchange work."""

from datetime import datetime, timezone as dt_timezone
from decimal import Decimal, InvalidOperation

from django.db.models import CharField, Value
from rest_framework.views import APIView

from api_bindings.models import ApiBinding
from api_bindings.services import scope_queryset_to_trading_account
from common.response import fail, ok
from common.trading_mode import TradingMode, request_trading_mode
from mobile.models import AccountFact, TradingCommand
from positions.models import LimitOrder, Order
from trading.models import TradeOpenRequest
from trading.open_requests import get_open_request_execution_intent


def _decimal(value, *, positive=False):
    if isinstance(value, bool):
        return None
    try:
        number = Decimal(str(value))
    except (InvalidOperation, TypeError, ValueError):
        return None
    if not number.is_finite() or number < 0 or (positive and number == 0):
        return None
    return number


def _text(number):
    if number is None:
        return None
    value = format(number, "f")
    return value.rstrip("0").rstrip(".") if "." in value else value


def _amount(size, price):
    if size is None or price is None:
        return None
    return _text(size * price)


def _positive_int(value, default, maximum=None):
    try:
        value = int(str(value))
    except (TypeError, ValueError):
        return default
    if value <= 0:
        return default
    return min(value, maximum) if maximum else value


def _scoped(queryset, user, mode, binding):
    # Fingerprints identify a key, while the creation boundary excludes earlier
    # bindings of the same key. No credential helper is called by this GET.
    queryset = scope_queryset_to_trading_account(
        queryset.filter(user=user, created_at__gte=binding.created_at),
        api_key_fingerprint=binding.api_key_fingerprint or "",
        binding_created_at=binding.created_at,
        trading_mode=mode,
    )
    if mode == TradingMode.LEAD:
        queryset = queryset.exclude(api_key_fingerprint__isnull=True).exclude(api_key_fingerprint="")
    return queryset


def _base(record, kind, *, price, size, side, stop_price, stop_amount, leverage):
    key = f"{kind}:{record.pk}"
    return {
        "id": key, "record_key": key, "source_id": record.pk, "order_kind": kind,
        "client_request_id": "", "symbol": record.symbol, "base_asset": record.symbol.removesuffix("USDT"),
        "side": side, "limit_price": _text(price), "stop_loss_price": _text(stop_price),
        "stop_loss_amount": _text(stop_amount), "size": _text(size),
        "position_amount": _amount(size, price), "filled_size": None, "filled_amount": None,
        "average_price": None, "filled_at": None, "leverage": leverage,
        "status": 4, "status_text": "待核对", "position_id": None,
        "can_cancel": False, "can_chase": False,
        "created_at": record.created_at.isoformat(), "updated_at": record.updated_at.isoformat(),
    }


def _position(record, positions):
    order = positions.get(record.order_id)
    if order and order.symbol == record.symbol and order.binance_order_id == record.binance_order_id:
        return order
    return None


def _limit_row(record, positions):
    row = _base(record, "limit", price=_decimal(record.limit_price, positive=True),
                size=_decimal(record.size), side=record.side, stop_price=_decimal(record.stop_loss_price),
                stop_amount=_decimal(record.stop_loss_amount), leverage=record.leverage)
    filled = _decimal(record.filled_size)
    position = _position(record, positions)
    average = _decimal(position.open_price, positive=True) if position else None
    row.update(status=record.status, status_text=record.get_status_display(), filled_size=_text(filled),
               average_price=_text(average), filled_amount=_amount(filled, average),
               position_id=position.pk if position else None,
               can_cancel=record.status == LimitOrder.STATUS_PENDING and bool(record.binance_order_id),
               can_chase=record.can_chase and bool(record.binance_order_id))
    if filled == 0:
        row["filled_amount"] = "0"
    if record.status == LimitOrder.STATUS_PENDING and filled and filled > 0:
        row["status_text"] = "部分成交"
    return row


def _maker_fact(record, binding, candidates, original_id):
    boundary = max(record.created_at, binding.created_at).timestamp() * 1000
    for fact in candidates:
        payload = fact.payload if isinstance(fact.payload, dict) else {}
        exchange_id = str(payload.get("i") or "")
        if (fact.event_time < boundary or not exchange_id
                or str(payload.get("s") or "") != record.symbol
                or fact.identity != f"{record.symbol}:{exchange_id}"
                or str(payload.get("c") or "") != record.client_order_id
                or (original_id and exchange_id != original_id)):
            continue
        try:
            observed = datetime.fromtimestamp(fact.event_time / 1000, tz=dt_timezone.utc)
        except (ValueError, OverflowError, OSError):
            continue
        return {"time": observed, "state": str(payload.get("X") or "").upper(),
                "filled": _decimal(payload.get("z")), "average": _decimal(payload.get("ap"), positive=True),
                "original_id": exchange_id, "source": "fact"}
    return None


def _maker_receipts(record, binding, commands):
    result = []
    for command in commands:
        payload = command.payload if isinstance(command.payload, dict) else {}
        response = command.result if isinstance(command.result, dict) else {}
        data = response.get("data") if isinstance(response.get("data"), dict) else {}
        if (str(payload.get("client_request_id") or "") != record.client_request_id
                or command.created_at < binding.created_at
                or (command.action != "open" and command.created_at < record.created_at)
                or command.updated_at < record.created_at or response.get("code") != 200
                or (data.get("symbol") and data["symbol"] != record.symbol)
                or (data.get("client_request_id") and str(data["client_request_id"]) != record.client_request_id)):
            continue
        state = data.get("state")
        if state == "PENDING_MAKER" and command.action in {"open", "maker-status"}:
            if command.action == "open" and str(command.pk) != record.client_request_id:
                continue
            exchange_id = str(data.get("maker_order_id") or "")
            if not exchange_id:
                continue
        elif (state == "CANCELLED" and command.action == "maker-fallback"
              and payload.get("cancel_only") is True and _decimal(data.get("filled_size")) is not None):
            exchange_id = ""
        else:
            # SUCCEEDED confirms execution of the HTTP command, and an adopted
            # position may still represent only a partial fill.
            continue
        result.append({"time": command.updated_at, "state": state,
                       "filled": _decimal(data.get("filled_size")), "average": None,
                       "original_id": exchange_id, "source": command.action})
    return result


def _maker_row(record, binding, facts, commands, positions):
    intent = get_open_request_execution_intent(record)
    size = _decimal(intent.get("size"), positive=True)
    row = _base(record, "maker", price=_decimal(intent.get("maker_price"), positive=True), size=size,
                side=intent.get("side_code") if intent.get("side_code") in (0, 1) else None,
                stop_price=_decimal(intent.get("stop_loss_price")),
                stop_amount=_decimal(intent.get("stop_loss_amount")), leverage=intent.get("leverage"))
    row["client_request_id"] = record.client_request_id
    has_fallback = bool(intent.get("fallback_client_order_id"))
    receipts = _maker_receipts(record, binding, commands)
    original_id = record.binance_order_id if not has_fallback else ""
    initial = next((r for r in receipts if r["source"] == "open" and r["original_id"]), None)
    if initial:
        if original_id and original_id != initial["original_id"]:
            receipts = []
        else:
            original_id = initial["original_id"]
    fact = _maker_fact(record, binding, facts, original_id)
    if fact:
        original_id = fact["original_id"]
    receipts = [r for r in receipts if not r["original_id"] or r["original_id"] == original_id]
    position = _position(record, positions)
    if position and (has_fallback or not original_id or position.side != row["side"]
                     or not binding.api_key_fingerprint
                     or record.api_key_fingerprint != binding.api_key_fingerprint
                     or position.api_key_fingerprint != binding.api_key_fingerprint):
        # A fallback can replace both binance_order_id and order_id with the
        # remainder's identity. Never count that as execution of this Maker.
        position = None
    if position:
        row["position_id"] = position.pk
    candidates = receipts + ([fact] if fact else [])
    terminal_states = {"FILLED", "CANCELED", "CANCELLED", "EXPIRED", "EXPIRED_IN_MATCH", "REJECTED"}
    terminal = [c for c in candidates if c["state"] in terminal_states]
    # An exchange order cannot become live after a terminal fact. Command
    # persistence can lag behind the snapshot returned by Binance.
    latest = max(terminal or candidates, key=lambda c: c["time"], default=None)
    position_size = _decimal(position.size, positive=True) if position else None
    position_average = _decimal(position.open_price, positive=True) if position else None
    confirmed_size = _decimal(intent.get("maker_filled_size")) if has_fallback else position_size
    quantities = [c["filled"] for c in candidates if c["filled"] is not None]
    if confirmed_size is not None:
        quantities.append(confirmed_size)
    # Cumulative fills cannot shrink when a delayed response is persisted. An
    # average is usable only for the exact cumulative quantity it describes.
    filled = max(quantities, default=None)
    priced = [c for c in candidates if c["filled"] == filled and c["average"] is not None]
    average = max(priced, key=lambda c: c["time"])["average"] if priced else None
    if average is None and position_size == filled:
        average = position_average
    row.update(filled_size=_text(filled), average_price=_text(average), filled_amount=_amount(filled, average))
    if filled == 0:
        row["filled_amount"] = "0"
    if latest:
        row["updated_at"] = max(record.updated_at, latest["time"]).isoformat()
    if (not has_fallback and position_size == size and size is not None and position_average is not None
            and (not latest or latest["state"] not in terminal_states)):
        row.update(status=1, status_text="已成交", filled_size=_text(size),
                   average_price=_text(position_average), filled_amount=_amount(size, position_average))
        return row
    if not latest:
        if record.status == TradeOpenRequest.STATUS_FAILED and not record.binance_order_id:
            row["status_text"] = "已拒绝"
        return row
    state = latest["state"]
    if filled is None or size is None or filled > size:
        if state == "PENDING_MAKER" and latest["filled"] is None and not has_fallback:
            row.update(status=0, status_text="待成交")
        return row
    if state == "FILLED" and filled == size:
        row.update(status=1, status_text="已成交",
                   filled_at=latest["time"].isoformat())
    elif state == "PARTIALLY_FILLED" and 0 < filled < size:
        row.update(status=0, status_text="部分成交")
    elif state == "NEW" and filled == 0:
        row.update(status=0, status_text="待成交")
    elif state == "PENDING_MAKER" and not has_fallback and filled < size:
        row.update(status=0, status_text="部分成交" if filled > 0 else "待成交")
    elif state in {"CANCELED", "CANCELLED", "EXPIRED", "EXPIRED_IN_MATCH"}:
        expired = state.startswith("EXPIRED")
        row.update(status=3 if expired else 2, status_text="已过期" if expired else "已撤销")
    elif state == "REJECTED":
        row["status_text"] = "已拒绝"
    row["can_cancel"] = (row["status"] == 0 and latest["source"] == "fact"
                         and record.trading_mode == TradingMode.ORDINARY and not has_fallback
                         and bool(record.binance_order_id) and record.binance_order_id == original_id
                         and bool(binding.api_key_fingerprint)
                         and record.api_key_fingerprint == binding.api_key_fingerprint)
    return row


class OrderListView(APIView):
    """One paginated local view of limit and Maker orders, including terminal records."""

    def get(self, request):
        mode = request_trading_mode(request)
        binding = ApiBinding.objects.filter(user=request.user, trading_mode=mode, status=1).first()
        if binding is None:
            return fail("请先绑定 Binance API")
        page = _positive_int(request.query_params.get("page"), 1)
        page_size = _positive_int(request.query_params.get("page_size"), 20, 100)
        offset = (page - 1) * page_size
        limits = _scoped(LimitOrder.objects.all(), request.user, mode, binding)
        makers = _scoped(TradeOpenRequest.objects.filter(
            request_payload___execution_intent__execution_mode="maker"), request.user, mode, binding)
        total = limits.count() + makers.count()
        anchors = limits.order_by().annotate(order_kind=Value("limit", output_field=CharField())).values(
            "id", "created_at", "order_kind").union(
                makers.order_by().annotate(order_kind=Value("maker", output_field=CharField())).values(
                    "id", "created_at", "order_kind"), all=True,
            ).order_by("-created_at", "-id", "order_kind")[offset:offset + page_size]
        anchors = list(anchors)
        limit_rows = {r.pk: r for r in limits.filter(pk__in=[r["id"] for r in anchors if r["order_kind"] == "limit"])}
        maker_rows = {r.pk: r for r in makers.filter(pk__in=[r["id"] for r in anchors if r["order_kind"] == "maker"])}
        records = [*limit_rows.values(), *maker_rows.values()]
        positions = {r.pk: r for r in _scoped(Order.objects.filter(
            pk__in=[r.order_id for r in records if r.order_id]), request.user, mode, binding)}
        facts = list(AccountFact.objects.filter(
            user=request.user, trading_mode=mode, binding_id_snapshot=binding.pk, kind="order",
            payload__c__in=[r.client_order_id for r in maker_rows.values()],
        ).order_by("-event_time", "-id")) if maker_rows else []
        commands = list(TradingCommand.objects.filter(
            user=request.user, trading_mode=mode, binding_id_snapshot=binding.pk,
            binding_fingerprint=binding.api_key_fingerprint or "", binding_created_at=binding.created_at,
            status="SUCCEEDED", action__in=["open", "maker-status", "maker-fallback"],
            payload__client_request_id__in=[r.client_request_id for r in maker_rows.values()],
        ).order_by("-updated_at", "-id")) if maker_rows else []
        items = [(_limit_row(limit_rows[a["id"]], positions) if a["order_kind"] == "limit" else
                  _maker_row(maker_rows[a["id"]], binding, facts, commands, positions)) for a in anchors]
        return ok(data={"items": items, "pagination": {
            "page": page, "page_size": page_size, "total": total,
            "has_next": offset + page_size < total, "has_previous": page > 1,
        }})
