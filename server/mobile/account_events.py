import hashlib
import json

from django.db import transaction
from api_bindings.models import ApiBinding
from mobile.models import AccountFact, AccountInbox, AccountOutbox

SUPPORTED = {"ACCOUNT_UPDATE", "ORDER_TRADE_UPDATE", "TRADE_LITE", "ALGO_UPDATE", "RECONCILE"}


def ingest(binding, event):
    if event.get("e") not in SUPPORTED:
        return False
    # listenKey expiry and unknown control messages never enter persistent payloads.
    encoded = json.dumps(event, sort_keys=True, separators=(",", ":"), allow_nan=False)
    key = hashlib.sha256(f"{binding.pk}:{binding.created_at.isoformat()}:{encoded}".encode()).hexdigest()
    _, created = AccountInbox.objects.get_or_create(event_key=key, defaults={
        "user_id": binding.user_id, "binding_id_snapshot": binding.pk, "trading_mode": binding.trading_mode,
        "event_time": int(event.get("T", event.get("E", 0))), "payload": event})
    return created


def fact_rows(event):
    kind = event["e"]
    if kind == "ACCOUNT_UPDATE":
        account = event.get("a", {})
        for row in account.get("B", []):
            yield "account", row["a"], row, "trading.account"
        for row in account.get("P", []):
            yield "position", f"{row['s']}:{row.get('ps', 'BOTH')}", row, "trading.position"
    elif kind in {"ORDER_TRADE_UPDATE", "ALGO_UPDATE", "RECONCILE"}:
        order = event.get("o", {})
        identity = f"{order.get('s', '')}:{order.get('i', order.get('aid', ''))}"
        yield "order", identity, order, "trading.order"
        if order.get("x") == "TRADE" and str(order.get("t", "0")) not in {"0", "-1"}:
            yield "fill", f"{order.get('s', '')}:{order['t']}", order, "trading.fill"
    elif kind == "TRADE_LITE":
        yield "fill", f"{event.get('s', '')}:{event.get('t', '')}", event, "trading.fill"


def reduce_pending(binding_id):
    changed = False
    for item in AccountInbox.objects.filter(binding_id_snapshot=binding_id, processed=False).order_by("id")[:100]:
        with transaction.atomic():
            item = AccountInbox.objects.select_for_update().get(pk=item.pk)
            if item.processed:
                continue
            binding = ApiBinding.objects.filter(pk=binding_id, user_id=item.user_id, status=1).first()
            if binding and item.created_at >= binding.created_at and item.trading_mode == binding.trading_mode:
                if item.payload.get("e") == "RECONCILE":
                    changed = True
                for kind, identity, payload, channel in fact_rows(item.payload):
                    fact, created = AccountFact.objects.select_for_update().get_or_create(
                        user_id=item.user_id, binding_id_snapshot=binding_id, trading_mode=item.trading_mode,
                        kind=kind, identity=identity, defaults={"event_time": item.event_time, "payload": payload})
                    if not created and fact.event_time > item.event_time:
                        continue
                    if not created:
                        fact.event_time, fact.payload = item.event_time, payload
                        fact.save(update_fields=["event_time", "payload"])
                    AccountOutbox.objects.create(user_id=item.user_id, trading_mode=item.trading_mode,
                        channel=channel, event_key=f"{binding_id}:{kind}:{identity}",
                        payload={"eventTime": item.event_time, "symbol": payload.get("s"), "fact": payload})
                    changed = True
            item.processed = True
            item.save(update_fields=["processed"])
    return changed


def reconcile_changed_account(binding_id):
    from api_bindings.services import get_user_trading_account
    from trading.account_cache import invalidate_position_caches
    from trading.services import sync_all_pending_limit_orders, reconcile_open_orders_protection
    binding = ApiBinding.objects.select_related("user").filter(pk=binding_id, status=1).first()
    if binding is None:
        return
    account = get_user_trading_account(binding.user, active_only=True, trading_mode=binding.trading_mode)
    if account is None:
        return
    invalidate_position_caches(account.identity)
    sync_all_pending_limit_orders(trading_mode=binding.trading_mode, user_id=binding.user_id)
    reconcile_open_orders_protection(trading_mode=binding.trading_mode, user_id=binding.user_id)
    invalidate_position_caches(account.identity)
    # A second committed hint makes clients refresh after the original services
    # have converged, even if they read immediately after the exchange event.
    if ApiBinding.objects.filter(pk=binding.pk, status=1, created_at=binding.created_at).exists():
        AccountOutbox.objects.create(user_id=binding.user_id, trading_mode=binding.trading_mode,
            channel="trading.account", event_key=f"{binding.pk}:reconciled",
            payload={"reconciled": True})
