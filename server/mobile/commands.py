"""Durable requests delegate to USDT services; no second order execution engine."""
import hashlib
import json
import threading
from contextlib import contextmanager
from decimal import Decimal, InvalidOperation
from uuid import uuid4

from django.conf import settings
from django.db import close_old_connections, transaction
from django.test import RequestFactory
from django.utils import timezone

from api_bindings.models import ApiBinding
from api_bindings.services import get_user_trading_account
from api_bindings.mode_middleware import LEAD_ENTRY_PATHS
from market_stream.bus import connection
from mobile.models import AccountOutbox, AccountWorkerState, TradingCommand

# Only these authenticated user operations may be queued. No arbitrary URL or callable.
ACTIONS = {
    "open": ("/v1/trade/open", "trading.views.TradeOpenView"),
    # Read-only reconciliation for a market/Maker entry whose write result
    # was lost. It may adopt an exchange-confirmed fill locally, but it never
    # submits another exchange order.
    "entry-status": ("/v1/trade/entry/status", "trading.views.EntryStatusView"),
    # Maker status/fallback are separate commands so the worker never blocks
    # while a post-only order waits on the book.
    "maker-status": ("/v1/trade/maker/status", "trading.views.MakerOpenStatusView"),
    "maker-fallback": ("/v1/trade/maker/fallback", "trading.views.MakerOpenFallbackView"),
    "limit-create": ("/v1/trade/limit-order/create", "trading.views.LimitOrderCreateView"),
    "limit-cancel": ("/v1/trade/limit-order/cancel", "trading.views.LimitOrderCancelView"),
    "limit-chase": ("/v1/trade/limit-order/chase", "trading.views.LimitOrderChaseView"),
    "position-close": ("/v1/position/close", "positions.views.PositionCloseView"),
    "take-profit": ("/v1/position/take-profit", "positions.views.ManualTakeProfitView"),
    "break-even": ("/v1/position/break-even-stop", "positions.views.BreakEvenStopView"),
    "strategy-cancel": ("/v1/strategy/cancel", "positions.views.StrategyCancelView"),
    "strategy-rebind": ("/v1/strategy/rebind", "positions.views.StrategyRebindView"),
}


def binding_for(user, mode):
    return ApiBinding.objects.filter(user=user, trading_mode=mode, status=1).first()


def check_rollout(mode, action):
    if mode == "lead" and ACTIONS[action][0] in LEAD_ENTRY_PATHS and not settings.LEAD_TRADING_ENABLED:
        raise ValueError("带单模式暂停新绑定和开仓，已有持仓仍可管理")


def submit(user, mode, action, payload, key):
    if action not in ACTIONS or mode not in {"ordinary", "lead"} or not isinstance(payload, dict):
        raise ValueError("交易命令不正确")
    if not isinstance(key, str) or not 1 <= len(key) <= 128:
        raise ValueError("需要有效的幂等键")
    check_rollout(mode, action)
    encoded = json.dumps({"mode": mode, "action": action, "payload": payload}, sort_keys=True, separators=(",", ":"), allow_nan=False)
    if len(encoded) > 16384:
        raise ValueError("交易命令过大")
    digest = hashlib.sha256(encoded.encode()).hexdigest()
    with transaction.atomic():
        # All submissions for this user serialize before checking the idempotency key.
        type(user).objects.select_for_update().get(pk=user.pk)
        previous = TradingCommand.objects.filter(user=user, idempotency_key=key).first()
        if previous:
            if previous.request_hash != digest:
                raise ValueError("同一幂等键不能用于不同请求")
            return previous
        binding = binding_for(user, mode)
        if binding is None:
            raise ValueError("请先绑定当前模式的交易所 API")
        # A Maker status read only reconciles an existing exchange order.  It
        # must remain executable while another command is UNKNOWN, and a
        # failed status read must not become a permanent new-entry lock.
        if action in {"open", "maker-fallback", "limit-create", "limit-chase"} and _has_unresolved_unknown_write(
                user, mode, binding.pk):
            raise ValueError("当前账户有结果未知的交易命令，请先核对订单，暂停新增风险")
        command_id = uuid4()
        body = dict(payload)
        if action in {"open", "limit-create", "limit-chase"}:
            body["client_request_id"] = str(command_id)
        return TradingCommand.objects.create(id=command_id, user=user,
            binding_id_snapshot=binding.pk, binding_fingerprint=binding.api_key_fingerprint or "",
            binding_created_at=binding.created_at, trading_mode=mode, idempotency_key=key,
            request_hash=digest, action=action, payload=body)


def command_view(command):
    return {"id": str(command.pk), "status": command.status, "action": command.action,
            "tradingMode": command.trading_mode, "result": command.result,
            "createdAt": command.created_at.isoformat(), "updatedAt": command.updated_at.isoformat()}


@contextmanager
def account_lease(binding_id, *, ttl=30):
    client = connection()
    lease = client.lock(f"integrated:account-worker:{binding_id}", timeout=ttl, blocking_timeout=0, thread_local=False)
    if not lease.acquire(blocking=False):
        yield None
        return
    alive = threading.Event()
    alive.set()
    stop = threading.Event()

    def renew():
        while not stop.wait(ttl / 3):
            try:
                if not lease.extend(ttl, replace_ttl=True):
                    alive.clear()
                    return
            except Exception:
                alive.clear()
                return

    with transaction.atomic():
        state, _ = AccountWorkerState.objects.get_or_create(binding_id_snapshot=binding_id)
        state = AccountWorkerState.objects.select_for_update().get(pk=state.pk)
        state.fence += 1
        state.save(update_fields=["fence"])
    thread = threading.Thread(target=renew, daemon=True, name="account-lease-renewal")
    thread.start()
    try:
        yield (state.fence, alive)
    finally:
        stop.set()
        thread.join(timeout=2)
        try:
            lease.release()
        except Exception:
            pass


def invoke(command):
    from django.utils.module_loading import import_string
    path, name = ACTIONS[command.action]
    raw = RequestFactory().post(path, data=json.dumps(command.payload), content_type="application/json",
                                HTTP_X_TRADING_MODE=command.trading_mode)
    view = import_string(name)()
    request = view.initialize_request(raw)
    request.user = command.user
    # The public mobile endpoint already authenticated the user; internal dispatch preserves
    # the original view's validation, mode identity, decorators and business service.
    from trading.locks import api_binding_lifecycle_lock
    with api_binding_lifecycle_lock(command.user_id, reentrant=True) as locked:
        if not locked:
            from common.response import fail
            return fail("API 绑定正在变更，命令未执行", code=409, status=409)
        binding = binding_for(command.user, command.trading_mode)
        if not binding or binding.pk != command.binding_id_snapshot or binding.created_at != command.binding_created_at or (binding.api_key_fingerprint or "") != command.binding_fingerprint:
            from common.response import fail
            return fail("API 绑定已变更，命令未执行", code=409, status=409)
        return view.post(request)


def resolve_known_commands(binding_id):
    """Converge unknown open writes from local and exact exchange read facts.

    This function never submits, cancels, or modifies an exchange order.  A
    confirmed pending/filled/zero-fill terminal row resolves the transport
    uncertainty; a missing or malformed row stays UNKNOWN.
    """
    from trading.models import TradeOpenRequest
    from positions.models import LimitOrder, Order
    from common.binance import to_inst_id
    from trading.execution import parse_entry_execution
    from trading.open_requests import mark_open_request_completed, mark_open_request_failed

    def finish(command, status, data):
        message = data.pop("message", "已根据交易所事实核对")
        result = {"code": 200, "message": message, "data": data}
        TradingCommand.objects.filter(pk=command.pk, status="UNKNOWN").update(
            status=status, result=result, updated_at=timezone.now()
        )

    for command in TradingCommand.objects.filter(binding_id_snapshot=binding_id, status="UNKNOWN")[:100]:
        if command.action not in {"open", "limit-create", "limit-chase"}:
            continue
        request_id = f"chase:{command.payload.get('limit_order_id')}" if command.action == "limit-chase" else str(command.pk)
        record = TradeOpenRequest.objects.filter(user_id=command.user_id, trading_mode=command.trading_mode,
            api_key_fingerprint=command.binding_fingerprint, client_request_id=request_id,
            created_at__gte=command.binding_created_at).first()
        if record is None:
            continue
        order = Order.objects.filter(pk=record.order_id, user_id=command.user_id,
            trading_mode=command.trading_mode, api_key_fingerprint=command.binding_fingerprint).first() if record.order_id else None
        limit_order = LimitOrder.objects.filter(user_id=command.user_id, trading_mode=command.trading_mode,
            api_key_fingerprint=command.binding_fingerprint, binance_client_order_id=record.client_order_id,
            created_at__gte=command.binding_created_at).first() if command.action == "limit-create" else None
        if order or limit_order:
            finish(command, "SUCCEEDED", {
                "message": "已根据持久化订单确认",
                "position_id": order.pk if order else None,
                "limit_order_id": limit_order.pk if limit_order else None,
            })
            continue

        if record.status == TradeOpenRequest.STATUS_FAILED:
            finish(command, "FAILED", {"message": "开仓已确认失败", "state": "FAILED"})
            continue
        if record.status == TradeOpenRequest.STATUS_COMPLETED:
            finish(command, "SUCCEEDED", {"message": "开仓结果已确认", "state": "COMPLETED"})
            continue

        # A durable order id is the only safe exchange lookup key here.  A
        # missing id means the write may never have reached Binance, so it
        # remains a genuine unknown and continues to block new risk.
        exchange_order_id = str(record.binance_order_id or "").strip()
        if not exchange_order_id:
            continue
        try:
            account = get_user_trading_account(
                command.user, active_only=True, trading_mode=command.trading_mode
            )
            if not account or account.binding_id != binding_id:
                continue
            payload = account.create_futures_client().get_order(
                inst_id=to_inst_id(record.symbol), order_id=exchange_order_id
            )
            row = (payload.get("data") or [None])[0]
            if not isinstance(row, dict):
                continue
            intent = record.request_payload.get("_execution_intent", {}) if isinstance(record.request_payload, dict) else {}
            requested_size = None
            try:
                requested_size = Decimal(str(intent.get("size"))) if intent.get("size") else None
                if requested_size is not None and (not requested_size.is_finite() or requested_size <= 0):
                    requested_size = None
            except (InvalidOperation, TypeError, ValueError):
                requested_size = None
            execution = parse_entry_execution(row, requested_size=requested_size)
            raw_state = str(row.get("state") or "").strip().lower()
            terminal_states = {"canceled", "cancelled", "expired", "expired_in_match", "rejected", "failed", "filled"}
            if execution.has_fill:
                mark_open_request_completed(record, exchange_order_id=exchange_order_id)
                finish(command, "SUCCEEDED", {
                    "message": "已根据交易所成交事实确认",
                    "state": "FILLED" if execution.state == "filled" else "PARTIALLY_FILLED",
                    "maker_order_id": exchange_order_id,
                    "filled_size": format(execution.filled_size, "f"),
                    "average_price": format(execution.average_price, "f"),
                    "symbol": record.symbol,
                })
            elif raw_state in terminal_states and execution.state == "pending":
                mark_open_request_failed(record, f"exchange_{raw_state}")
                finish(command, "FAILED", {
                    "message": "已根据交易所终态确认未成交",
                    "state": "FAILED",
                    "maker_order_id": exchange_order_id,
                    "filled_size": "0",
                    "symbol": record.symbol,
                })
            elif execution.state == "pending":
                # A live Maker order is a normal queued request.  Resolving
                # the transport state makes it visible in the order list and
                # prevents an unrelated symbol from being blocked forever.
                pending_state = (
                    "PENDING_MAKER"
                    if str(intent.get("execution_mode") or "") == "maker"
                    else "PENDING_ENTRY"
                )
                finish(command, "SUCCEEDED", {
                    "message": "交易所已确认委托等待成交",
                    "state": pending_state,
                    "maker_order_id": exchange_order_id,
                    "filled_size": "0",
                    "symbol": record.symbol,
                    "client_request_id": record.client_request_id,
                })
        except Exception:
            # A read timeout, permission error, or malformed row is still an
            # unknown write.  Keep the guard until an exact exchange fact is
            # available; never guess a terminal state.
            continue


def _has_unresolved_unknown_write(user, mode, binding_id):
    """Return whether an UNKNOWN command still represents unresolved risk."""
    from trading.models import TradeOpenRequest
    for command in TradingCommand.objects.filter(
        user=user, trading_mode=mode, binding_id_snapshot=binding_id, status="UNKNOWN"
    ).exclude(action__in={"maker-status", "entry-status"}):
        if command.action != "open":
            return True
        request = TradeOpenRequest.objects.filter(
            user_id=user.pk,
            trading_mode=mode,
            api_key_fingerprint=command.binding_fingerprint,
            client_request_id=str(command.pk),
            created_at__gte=command.binding_created_at,
        ).first()
        if not request or request.status not in {
            TradeOpenRequest.STATUS_FAILED,
            TradeOpenRequest.STATUS_COMPLETED,
        }:
            return True
    return False


def execute_account(binding_id):
    close_old_connections()
    try:
        with account_lease(binding_id) as held:
            if held is None:
                return
            fence, alive = held
            from mobile.account_events import reduce_pending, reconcile_changed_account
            if reduce_pending(binding_id) and alive.is_set():
                reconcile_changed_account(binding_id)
            # An interrupted mutation is never automatically re-submitted. Original
            # open requests can be resolved by the existing clientOrderId recovery path.
            TradingCommand.objects.filter(binding_id_snapshot=binding_id, status="RUNNING").update(status="UNKNOWN")
            resolve_known_commands(binding_id)
            for _ in range(10):
                if not alive.is_set():
                    return
                pending = TradingCommand.objects.filter(binding_id_snapshot=binding_id, status="PENDING")
                if TradingCommand.objects.filter(binding_id_snapshot=binding_id, status="UNKNOWN").exists():
                    pending = pending.exclude(action__in=[
                        "open", "maker-fallback", "limit-create", "limit-chase"
                    ])
                command = pending.select_related("user").order_by("created_at").first()
                if command is None:
                    return
                binding = binding_for(command.user, command.trading_mode)
                valid = binding and binding.pk == binding_id and binding.created_at == command.binding_created_at and (binding.api_key_fingerprint or "") == command.binding_fingerprint
                try:
                    check_rollout(command.trading_mode, command.action)
                    if not valid:
                        raise ValueError("API 绑定已变更，命令未执行")
                except ValueError as exc:
                    command.status, command.result = "FAILED", {"code": 409, "message": str(exc)}
                    command.save(update_fields=["status", "result", "updated_at"])
                    continue
                command.status, command.fence = "RUNNING", fence
                command.save(update_fields=["status", "fence", "updated_at"])
                try:
                    response = invoke(command)
                    result = json.loads(json.dumps(response.data, default=str))
                    status = "SUCCEEDED" if response.status_code < 400 and result.get("code") == 200 else "FAILED"
                    if status == "FAILED" and command.action in {
                        "open", "maker-fallback", "limit-create", "limit-chase"
                    }:
                        from trading.models import TradeOpenRequest
                        unresolved = TradeOpenRequest.objects.filter(user=command.user,
                            trading_mode=command.trading_mode, client_request_id=str(command.pk),
                            status__in=["pending", "submitted", "recovered"], order_id__isnull=True).exists()
                        if unresolved:
                            status = "UNKNOWN"
                except Exception:
                    # The exchange may have accepted a write before the process failed.
                    result, status = {"message": "执行结果待核对，请查看订单状态，勿重复提交"}, "UNKNOWN"
                if not alive.is_set():
                    return
                with transaction.atomic():
                    state = AccountWorkerState.objects.select_for_update().get(binding_id_snapshot=binding_id)
                    if state.fence != fence:
                        return
                    TradingCommand.objects.filter(pk=command.pk, fence=fence, status="RUNNING").update(status=status, result=result, updated_at=timezone.now())
                    AccountOutbox.objects.create(user=command.user, trading_mode=command.trading_mode,
                        channel="trading.order", event_key=str(command.pk), payload={"commandId": str(command.pk), "status": status})
    finally:
        close_old_connections()
