"""Explicit wallet actions, sharing the existing sweep lock and receipt journal."""
import hashlib
from decimal import Decimal

from trading import balance_cap as cap
from trading.models import CapitalSweep

WALLET_ACTIONS = ("to_spot", "funding_to_futures", "spot_to_futures", "transfer")


def _result(user, sweep):
    if sweep.status == CapitalSweep.STATUS_COMPLETED:
        state = cap._completed_sweep_state(user, sweep)
        state["message"] = "转账已完成" if sweep.operation == "transfer" else "划转已完成"
    elif sweep.status == CapitalSweep.STATUS_FAILED:
        state = {**cap._sweep_state(sweep), "status": "failed", "message": sweep.error}
    else:
        state = cap._sweep_state(sweep)
        state["message"] = sweep.error or "存在待确认资金操作，请先核对原流水"
    if sweep.operation == "transfer":
        state["account_type"] = "master" if sweep.master_destination_address else "sub"
    state["operation_amount"] = format(
        sweep.amount + sweep.futures_amount + sweep.funding_amount
        + sweep.funding_refill_amount + sweep.spot_refill_amount, "f")
    return state


def _plan(user, client, action):
    user.refresh_from_db(fields=["stop_loss_amount", "capital_collect_account", "capital_collect_network"])
    if action not in WALLET_ACTIONS:
        raise ValueError("不支持的资金操作")
    maximum = cap.retention_threshold(user)
    if maximum <= 0:
        raise ValueError("请先设置有效止损额")
    activity = cap.load_exchange_activity(client).flags()
    futures, available = cap._futures_balance(client)
    funding = cap._decimal(client.get_funding_usdt_free_balance("USDT", fresh=True))
    spot = cap._decimal(client.get_spot_usdt_free_balance("USDT", fresh=True))
    plan = dict.fromkeys(("funding_to_futures", "spot_to_futures", "futures_collect",
                          "funding_collect", "spot_collect", "collection_total"), Decimal("0"))
    if action == "to_spot":
        plan["futures_collect"] = cap._amount(futures - maximum)
        plan["funding_collect"] = cap._amount(cap._transferable_wallet_balance(funding))
    elif action in {"funding_to_futures", "spot_to_futures"}:
        source = funding if action == "funding_to_futures" else spot
        plan[action] = cap._amount(min(max(maximum - futures, Decimal("0")),
                                       cap._transferable_wallet_balance(source)))
    else:
        plan["collection_total"] = cap._amount(cap._transferable_wallet_balance(spot))
        plan["spot_collect"] = plan["collection_total"]
    plan["target_balance"] = futures - plan["futures_collect"] + plan["funding_to_futures"] + plan["spot_to_futures"]
    operation_amount = sum(plan[key] for key in ("funding_to_futures", "spot_to_futures",
                                               "futures_collect", "funding_collect", "collection_total"))
    state = {**cap._wallet_state(user, futures, available, funding, spot), **activity,
             **{key: format(value, "f") for key, value in plan.items()},
             "operation": action, "operation_amount": format(operation_amount, "f"),
             "transfer_amount": format(plan["collection_total"], "f"),
             "status": "normalization_required" if operation_amount >= cap.DUST_AMOUNT else "ready"}
    account_type = cap.ACCOUNT_TYPE_UNKNOWN
    if action == "transfer":
        account_type = cap.account_type_for_client(client)
        state.update(account_type=account_type,
                     destination_address=str(user.capital_collect_account or "") if account_type == cap.ACCOUNT_TYPE_MASTER else "",
                     destination_network=str(user.capital_collect_network or "") if account_type == cap.ACCOUNT_TYPE_MASTER else "",
                     transfer_path="master_address" if account_type == cap.ACCOUNT_TYPE_MASTER else "sub_to_master")
    reason = ""
    if activity["has_position"]:
        reason = "交易所当前有持仓，持仓期间不能划转或转出资金"
    elif activity["has_regular_orders"] or activity["has_algo_orders"]:
        reason = "交易所仍有挂单，请先处理挂单再操作资金"
    elif available < plan["futures_collect"]:
        reason = "合约可划转余额不足，请刷新后重试"
    elif action == "transfer" and account_type == cap.ACCOUNT_TYPE_UNKNOWN:
        reason = "暂时无法确认币安账户类型，请刷新后重试"
    elif action == "transfer" and account_type == cap.ACCOUNT_TYPE_MASTER and (
        not state["destination_address"] or state["destination_network"].upper() not in cap.CAPITAL_COLLECT_NETWORKS
    ):
        reason = "请先在资金归集页面添加收款账号"
    if reason:
        state.update(status="blocked", message=reason)
    values = [action, format(maximum.normalize(), "f"), format(futures.normalize(), "f"),
              *(format(value.normalize(), "f") for value in plan.values()),
              account_type, state.get("destination_address", ""), state.get("destination_network", "")]
    state["plan_token"] = hashlib.sha256("|".join(values).encode()).hexdigest()
    return state


def _pending_state(user, client):
    sweep = cap._pending_sweep(user)
    if sweep and cap._current_step_submitted(sweep):
        cap._continue_pending_sweep(user, client, sweep, "manual_sweep", allow_submit=False)
    if sweep and sweep.active_slot:
        return _result(user, sweep)
    if CapitalSweep.objects.filter(user=user, active_slot=1).exists():
        return {"status": "blocked", "message": "存在其他 API 绑定的未确认资金流水，请先核对"}
    return None


def wallet_precheck(user, client, *, action):
    with cap._capital_activity_lock(user, client):
        pending = _pending_state(user, client)
        return pending or _plan(user, client, action)


def execute_wallet_operation(user, client, *, action, request_id, expected_plan="", collection_id=None):
    if action not in WALLET_ACTIONS:
        raise ValueError("不支持的资金操作")
    with cap._capital_activity_lock(user, client) as fingerprint:
        # Replay uses the original journal even if balances/settings have since changed.
        sweep = cap._sweeps_for_current_binding(user).filter(request_id=request_id).first()
        if collection_id is not None:
            identified = cap._sweeps_for_current_binding(user).filter(pk=collection_id).first()
            if not identified or identified.operation != action:
                raise ValueError("资金流水不属于当前账户或操作")
            if sweep and sweep.pk != identified.pk:
                raise ValueError("请求编号与资金流水不一致")
            sweep = identified
        if sweep:
            if sweep.operation != action:
                raise ValueError("请求编号已用于其他资金操作")
            if sweep.status in {CapitalSweep.STATUS_COMPLETED, CapitalSweep.STATUS_FAILED}:
                return _result(user, sweep)
            if cap._current_step_submitted(sweep):
                cap._continue_pending_sweep(user, client, sweep, "manual_sweep", allow_submit=False)
                # A query never submits a subsequent step in the same request.
                return _result(user, sweep)
        else:
            pending = _pending_state(user, client)
            if pending:
                return pending
        plan = _plan(user, client, action)
        if plan["status"] == "blocked":
            return plan
        if sweep:
            if not cap._remaining_plan_matches(sweep, plan):
                if cap._wallet_visibility_grace(sweep):
                    return {**_result(user, sweep), "message": cap.WALLET_VISIBILITY_WAIT}
                cap._finish_sweep(sweep, CapitalSweep.STATUS_FAILED, "余额或配置已变化，请重新核对金额")
                return {**plan, "plan_changed": True}
        else:
            if expected_plan != plan["plan_token"]:
                return {**plan, "plan_changed": True}
            if plan["status"] != "normalization_required":
                return plan
            sweep = cap._create_capital_sweep(
                user, plan, account_type=plan.get("account_type", cap.ACCOUNT_TYPE_UNKNOWN),
                api_key_fingerprint=fingerprint, operation=action, request_id=request_id)
        def validate_step(current):
            fresh = _plan(user, client, action)
            destination_changed = action == "transfer" and (
                fresh.get("destination_address", "") != current.master_destination_address
                or fresh.get("destination_network", "").upper() != current.master_destination_network.upper())
            if fresh["status"] == "blocked":
                return cap._pause_sweep(current, fresh["message"])
            if destination_changed or not cap._remaining_plan_matches(current, fresh):
                if cap._wallet_visibility_grace(current):
                    return cap._pause_sweep(current, cap.WALLET_VISIBILITY_WAIT)
                cap._finish_sweep(current, CapitalSweep.STATUS_FAILED, "余额或收款设置已变化，请重新核对")
                return _result(user, current)
            return None
        cap._continue_pending_sweep(user, client, sweep, "manual_sweep", before_submit=validate_step)
        return _result(user, sweep)
