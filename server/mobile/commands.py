"""Durable requests delegate to USDT services; no second order execution engine."""
import hashlib
import json
import threading
from contextlib import contextmanager
from uuid import uuid4

from django.conf import settings
from django.db import close_old_connections, transaction
from django.test import RequestFactory
from django.utils import timezone

from api_bindings.models import ApiBinding
from api_bindings.mode_middleware import LEAD_ENTRY_PATHS
from market_stream.bus import connection
from mobile.models import AccountOutbox, AccountWorkerState, TradingCommand

# Only these authenticated user operations may be queued. No arbitrary URL or callable.
ACTIONS = {
    "open": ("/v1/trade/open", "trading.views.TradeOpenView"),
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
        if action in {"open", "maker-status", "maker-fallback", "limit-create", "limit-chase"} and TradingCommand.objects.filter(
                user=user, trading_mode=mode, binding_id_snapshot=binding.pk, status="UNKNOWN").exists():
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
    """Converge from persisted, exchange-confirmed USDT records; never retry a write."""
    from trading.models import TradeOpenRequest
    from positions.models import LimitOrder, Order
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
            result = {"code": 200, "message": "已根据持久化订单确认", "data": {"position_id": order.pk if order else None, "limit_order_id": limit_order.pk if limit_order else None}}
            TradingCommand.objects.filter(pk=command.pk, status="UNKNOWN").update(status="SUCCEEDED", result=result, updated_at=timezone.now())


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
                        "open", "maker-status", "maker-fallback", "limit-create", "limit-chase"
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
