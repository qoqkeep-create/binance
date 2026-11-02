"""User-confirmed capital normalization and read-only funding reminders."""
from dataclasses import dataclass
from contextlib import contextmanager
from decimal import Decimal, ROUND_DOWN, ROUND_UP
from datetime import timedelta
import hashlib
import logging
import time
from typing import Optional
from uuid import uuid4

from django.conf import settings
from django.core.cache import cache
from django.core.mail import send_mail
from django.db import IntegrityError, transaction
from django.utils import timezone

from api_bindings.models import ApiBinding
from api_bindings.context import build_trading_account_identity
from api_bindings.services import (
    build_api_key_fingerprint,
    get_user_binance_credentials,
    get_user_binding_generation,
    scope_queryset_to_trading_account,
)
from common.binance import (
    ACCOUNT_TYPE_MASTER,
    ACCOUNT_TYPE_SUB,
    ACCOUNT_TYPE_UNKNOWN,
    CAPITAL_COLLECT_NETWORKS,
    BinanceApiError,
    BinanceFuturesClient,
    is_binance_preflight_rate_limit_error,
    is_binance_rate_limit_error,
)
from common.errors import safe_error_summary
from trading.locks import user_trading_activity_lock
from trading.models import CapitalSweep
from users.models import User

logger = logging.getLogger(__name__)

THRESHOLD_MULTIPLIER = Decimal("5")
REFILL_TRIGGER_MULTIPLIER = Decimal("1.5")
DUST_AMOUNT = Decimal("0.01")
# 低于该值的钱包余额视为已清空：不参与规划、不尝试划转（币安对小额划转有最小限额，
# 转它会制造新的失败循环），也不阻塞开仓。币安截断/手续费返还会留下这类残差。
WALLET_CLEAN_THRESHOLD = Decimal("1")
SPOT_REMINDER_THRESHOLD = Decimal("200")
REMINDER_INTERVAL_SECONDS = 30 * 60
UNCERTAIN_TRANSFER_RETRY_SECONDS = 15
TRANSFER_RECONCILIATION_WINDOW_SECONDS = 5 * 60
COMPLETED_SWEEP_GUARD_SECONDS = 5 * 60
WITHDRAW_HISTORY_VISIBILITY_GRACE_SECONDS = 5 * 60
ACCOUNT_TYPE_CACHE_TTL_SECONDS = 5 * 60
WALLET_VISIBILITY_GRACE_SECONDS = 60
WALLET_VISIBILITY_WAIT = "上一笔划转已确认，等待交易所更新钱包可用余额"
SWEEP_STAGES = (
    (CapitalSweep.STATUS_FUNDING_REFILL_PENDING, "funding_refill", "funding_to_futures"),
    (CapitalSweep.STATUS_SPOT_REFILL_PENDING, "spot_refill", "spot_to_futures"),
    (CapitalSweep.STATUS_FUTURES_PENDING, "futures", "futures_collect"),
    (CapitalSweep.STATUS_FUNDING_PENDING, "funding", "funding_collect"),
    (CapitalSweep.STATUS_SPOT_PENDING, "master", "transfer_amount"),
)
WITHDRAW_PENDING_STATUSES = {"0", "2", "4"}
WITHDRAW_FAILED_STATUSES = {"1", "3", "5"}
WITHDRAW_COMPLETED_STATUS = "6"
UNCERTAIN_WITHDRAW_ERROR_CODES = {"-1001", "-1003", "-1006", "-1007", "-1021", "-1022"}


def retention_threshold(user: User) -> Decimal:
    """Return the maximum permitted futures balance (5x stop-loss)."""
    return Decimal(user.stop_loss_amount or 0) * THRESHOLD_MULTIPLIER


def refill_trigger_threshold(user: User) -> Decimal:
    """Return the 1.5x stop-loss line used for opening and top-up reminders."""
    return Decimal(user.stop_loss_amount or 0) * REFILL_TRIGGER_MULTIPLIER


def required_futures_balance(user: User) -> Decimal:
    # Kept as the public compatibility name for the five-times target.
    return retention_threshold(user)


def _decimal(value) -> Decimal:
    return Decimal(str(value or "0"))


def _amount(value: Decimal) -> Decimal:
    return max(Decimal("0"), value).quantize(Decimal("0.01"), rounding=ROUND_DOWN)


def _amount_up(value: Decimal) -> Decimal:
    return max(Decimal("0"), value).quantize(Decimal("0.01"), rounding=ROUND_UP)


def _whole_amount_up(value: Decimal) -> Decimal:
    return max(Decimal("0"), value).quantize(Decimal("1"), rounding=ROUND_UP)


def _withdraw_amount_matches(actual, expected) -> bool:
    """提现历史金额容差：币安会按币种/网络精度截断提现金额（实测 USDT 截断到一位小数），
    严格相等会把已成功到账的内部转账误判为不匹配，造成流水永久卡死。"""
    return abs(_decimal(actual) - _decimal(expected)) <= Decimal("0.1")


def _withdraw_exception_is_deterministic(exc: Exception) -> bool:
    """判断提现请求是否被交易所明确拒绝，而不是响应丢失/网络未知。"""
    if not isinstance(exc, BinanceApiError):
        return False
    if exc.outcome_unknown:
        return False
    code = str(getattr(exc, "code", "") or "").strip()
    return bool(code) and code not in UNCERTAIN_WITHDRAW_ERROR_CODES


def _send_reminder(user: User, kind: str, subject: str, body: str, *, force: bool = False) -> bool:
    if not getattr(settings, "EMAIL_HOST", ""):
        logger.warning("capital reminder not sent: EMAIL_HOST missing user=%s kind=%s", user.id, kind)
        if force:
            raise ValueError("邮件服务未配置，请先配置 SMTP 邮件服务")
        return False
    key = f"capital:reminder:{user.id}:{kind}"
    if not force and not cache.add(key, "1", timeout=REMINDER_INTERVAL_SECONDS):
        return False
    try:
        send_mail(subject, body, None, [user.email], fail_silently=False)
        return True
    except Exception as exc:  # noqa: BLE001
        if not force:
            cache.delete(key)
        logger.error(
            "capital reminder failed user=%s kind=%s err=%s",
            user.id,
            kind,
            safe_error_summary(exc),
        )
        if force:
            raise ValueError("邮件发送失败，请检查 SMTP 配置后重试") from exc
        return False


@dataclass(frozen=True)
class ExchangeActivitySnapshot:
    positions: tuple[dict, ...]
    regular_orders: tuple[dict, ...]
    algo_orders: tuple[dict, ...]

    def flags(self) -> dict[str, bool]:
        return {
            "has_position": bool(self.positions),
            "has_regular_orders": bool(self.regular_orders),
            "has_algo_orders": bool(self.algo_orders),
        }


def load_exchange_activity(client: BinanceFuturesClient) -> ExchangeActivitySnapshot:
    """Load one coherent activity snapshot for an entry or capital decision."""
    return ExchangeActivitySnapshot(
        positions=tuple(client.get_positions("SWAP").get("data") or []),
        regular_orders=tuple(client.get_pending_orders("SWAP").get("data") or []),
        algo_orders=tuple(client.get_pending_algo_orders(inst_type="SWAP").get("data") or []),
    )


def _futures_balance(client: BinanceFuturesClient) -> tuple[Decimal, Decimal]:
    rows = client.get_balance("USDT", fresh=True).get("data") or []
    details = ((rows[0] or {}).get("details") or []) if rows else []
    if not details:
        raise ValueError("未获取到合约账户余额")
    row = details[0] or {}
    return _decimal(row.get("eq")), _decimal(row.get("availEq"))


def _sweeps_for_current_binding(user: User):
    fingerprint, binding_created_at = get_user_binding_generation(user)
    return scope_queryset_to_trading_account(
        CapitalSweep.objects.filter(user=user),
        api_key_fingerprint=fingerprint,
        binding_created_at=binding_created_at,
    )


def _pending_sweep(user: User):
    return _sweeps_for_current_binding(user).filter(
        active_slot=1,
        status__in=[
            CapitalSweep.STATUS_FUNDING_REFILL_PENDING,
            CapitalSweep.STATUS_SPOT_REFILL_PENDING,
            CapitalSweep.STATUS_FUTURES_PENDING,
            CapitalSweep.STATUS_FUNDING_PENDING,
            CapitalSweep.STATUS_SPOT_PENDING,
        ],
    ).first()


def _recent_completed_sweep(user: User):
    latest = _sweeps_for_current_binding(user).filter(operation="").order_by("-updated_at", "-id").first()
    if not latest or latest.status != CapitalSweep.STATUS_COMPLETED:
        return None
    if latest.updated_at < timezone.now() - timedelta(seconds=COMPLETED_SWEEP_GUARD_SECONDS):
        return None
    return latest


def _save_sweep(sweep: CapitalSweep, *fields: str) -> None:
    """流水状态变更统一入口：显式字段 + updated_at，避免各处手写 update_fields。"""
    sweep.save(update_fields=[*fields, "updated_at"])


def _pause_sweep(sweep: CapitalSweep, error: str) -> dict:
    """结果未知时停留当前步骤：只写错误文案，不改状态，等用户再次确认。"""
    sweep.error = error
    _save_sweep(sweep, "error")
    return _sweep_state(sweep)


def _advance_sweep(sweep: CapitalSweep, next_status: str, **fields) -> None:
    """对账/划转确认后推进到下一步，同时清空错误文案。"""
    for name, value in fields.items():
        setattr(sweep, name, value)
    sweep.status = next_status
    sweep.error = ""
    _save_sweep(sweep, *fields.keys(), "status", "error")


def _finish_sweep(sweep: CapitalSweep, status: str, error: str = "", **fields) -> None:
    for name, value in fields.items():
        setattr(sweep, name, value)
    sweep.status = status
    sweep.error = error
    _save_sweep(sweep, *fields.keys(), "status", "error")


def _complete_master_transfer(
    sweep: CapitalSweep,
    transaction_id: str,
    *,
    transfer_kind: str = "",
) -> None:
    fields = {"master_txn_id": str(transaction_id or "")}
    if transfer_kind:
        fields["master_transfer_kind"] = transfer_kind
    _finish_sweep(sweep, CapitalSweep.STATUS_COMPLETED, **fields)


def _apply_withdraw_history_result(
    sweep: CapitalSweep,
    *,
    history_id: str,
    history_state: str,
    history_detail: str,
    pending_prefix: str,
    failed_prefix: str,
) -> Optional[bool]:
    """Persist one reconciled withdrawal result; return None when history is absent."""
    if history_state in {"completed", "completed_onchain"} and history_id:
        transfer_kind = (
            CapitalSweep.MASTER_TRANSFER_INTERNAL
            if history_state == "completed"
            else CapitalSweep.MASTER_TRANSFER_ONCHAIN
        )
        _complete_master_transfer(sweep, history_id, transfer_kind=transfer_kind)
        return True
    if history_state == "failed":
        detail = safe_error_summary(history_detail, include_type=False)
        _finish_sweep(
            sweep,
            CapitalSweep.STATUS_FAILED,
            f"{failed_prefix}：{detail}。资金仍在现货，请确认目标地址和网络后重试",
        )
        return False
    if history_state == "pending":
        detail = safe_error_summary(history_detail, include_type=False)
        _pause_sweep(sweep, f"{pending_prefix}：{detail}")
        return False
    return None


def _sweep_state(sweep: CapitalSweep) -> dict:
    destination_address = str(getattr(sweep, "master_destination_address", "") or "").strip()
    destination_network = str(getattr(sweep, "master_destination_network", "") or "").strip().upper()
    return {
        "status": "collection_pending",
        "operation": sweep.operation,
        "reason": sweep.status,
        "target": format(sweep.target_balance, "f"),
        "transfer_amount": format(sweep.amount, "f"),
        "funding_to_futures": format(sweep.funding_refill_amount, "f"),
        "spot_to_futures": format(sweep.spot_refill_amount, "f"),
        "futures_collect": format(sweep.futures_amount, "f"),
        "funding_collect": format(sweep.funding_amount, "f"),
        "spot_collect": format(sweep.spot_amount, "f"),
        "collection_id": sweep.id,
        "collection_error": sweep.error,
        "collection_created_at": sweep.created_at.isoformat(),
        "completed_steps": _completed_steps(sweep),
        "transfer_path": "master_address" if destination_address else "sub_to_master",
        "destination_address": destination_address,
        "destination_network": destination_network,
        "settlement_method": sweep.master_transfer_kind,
    }


def _completed_steps(sweep: CapitalSweep) -> list[str]:
    return [
        direction for _status, prefix, direction in SWEEP_STAGES
        if (sweep.status == CapitalSweep.STATUS_COMPLETED if prefix == "master"
            else bool(getattr(sweep, f"{prefix}_tran_id")))
    ]


def _current_step_submitted(sweep: CapitalSweep) -> bool:
    return any(
        sweep.status == status and bool(getattr(sweep, f"{prefix}_attempted_at"))
        for status, prefix, _direction in SWEEP_STAGES
    )


def _completed_sweep_state(user: User, sweep: CapitalSweep) -> dict:
    maximum = retention_threshold(user)
    minimum = refill_trigger_threshold(user)
    destination_address = str(getattr(sweep, "master_destination_address", "") or "").strip()
    destination_network = str(getattr(sweep, "master_destination_network", "") or "").strip().upper()
    transfer_path = "internal_only"
    if sweep.amount >= DUST_AMOUNT:
        transfer_path = "master_address" if destination_address else "sub_to_master"
    return {
        "status": "ready",
        "reason": "normalization_completed",
        "operation": sweep.operation,
        "base_target": format(maximum, "f"),
        "minimum_open_balance": format(minimum, "f"),
        "maximum_futures_balance": format(maximum, "f"),
        "refill_trigger": format(minimum, "f"),
        "target": format(sweep.target_balance, "f"),
        "upper_limit": format(maximum, "f"),
        "transfer_amount": format(sweep.amount, "f"),
        "collection_total": format(sweep.amount, "f"),
        "funding_to_futures": format(sweep.funding_refill_amount, "f"),
        "spot_to_futures": format(sweep.spot_refill_amount, "f"),
        "futures_collect": format(sweep.futures_amount, "f"),
        "funding_collect": format(sweep.funding_amount, "f"),
        "spot_collect": format(sweep.spot_amount, "f"),
        "collection_id": sweep.id,
        "completed_steps": _completed_steps(sweep),
        "transfer_path": transfer_path,
        "destination_address": destination_address,
        "destination_network": destination_network,
        "settlement_method": sweep.master_transfer_kind,
    }


def _send_sweep_complete_reminder(
    user: User,
    sweep: CapitalSweep,
    *,
    destination_address: str = "",
    destination_network: str = "",
) -> None:
    completed_at = timezone.localtime(sweep.updated_at).strftime("%Y-%m-%d %H:%M:%S %Z")
    if destination_address:
        if sweep.master_transfer_kind == CapitalSweep.MASTER_TRANSFER_INTERNAL:
            destination_line = (
                f"资金路径：现货账户 -> 目标主账户 Spot 充值地址 {destination_address} "
                f"（网络 {destination_network}，Binance 提现历史确认为站内转账）"
            )
        else:
            destination_line = (
                f"资金路径：现货账户 -> 目标主账户 Spot 充值地址 {destination_address} "
                f"（网络 {destination_network}，Binance 提现历史显示为链上转出；到账和手续费请以目标账户为准）"
            )
    else:
        destination_line = "到账位置：所属主账户的现货账户"
    if destination_address:
        route_note = "主账户使用 Binance 提现 API，是否站内免手续费由 Binance 最终路由决定。"
    else:
        route_note = "子账户使用 Binance 子转主划转，不使用提现 API，也不经过外部链上地址。"
    _send_reminder(
        user,
        f"sweep_completed:{sweep.id}",
        f"【交易账户归集完成】{format(sweep.amount, 'f')} USDT 已转出",
        (
            "本次资金归集转出已完成。\n\n"
            f"归集总额：{format(sweep.amount, 'f')} USDT\n"
            f"合约账户转出：{format(sweep.futures_amount, 'f')} USDT\n"
            f"资金账户转出：{format(sweep.funding_amount, 'f')} USDT\n"
            f"原现货账户归集：{format(sweep.spot_amount, 'f')} USDT\n"
            f"合约账户保留目标：{format(sweep.target_balance, 'f')} USDT\n"
            f"{destination_line}\n"
            f"完成时间：{completed_at}\n"
            f"系统归集编号：{sweep.id}\n\n"
            f"说明：本次归集由用户在系统中确认发起。{route_note}"
            "如非本人操作，请立即检查账户登录记录和 API Key 权限。"
        ),
    )


def account_type_for_client(client: BinanceFuturesClient) -> str:
    """Return a cached, conservative master/sub-account classification.

    A missing/invalid probe result is never converted into a real account type;
    callers that can move money must explicitly reject ``unknown``.
    """
    api_key = str(getattr(getattr(client, "credentials", None), "api_key", "") or "")
    digest = hashlib.sha256(api_key.encode()).hexdigest()[:16]
    cache_key = f"capital:account-type:{digest}"
    cached = cache.get(cache_key)
    if cached in {ACCOUNT_TYPE_MASTER, ACCOUNT_TYPE_SUB}:
        return str(cached)

    account_type = ACCOUNT_TYPE_UNKNOWN
    try:
        probe = getattr(client, "probe_account_type", None)
        probed = probe() if callable(probe) else ACCOUNT_TYPE_UNKNOWN
        if probed in {ACCOUNT_TYPE_MASTER, ACCOUNT_TYPE_SUB, ACCOUNT_TYPE_UNKNOWN}:
            account_type = str(probed)
    except Exception as exc:  # noqa: BLE001
        logger.warning("capital account-type detection failed err=%s", safe_error_summary(exc))
        if is_binance_rate_limit_error(exc):
            raise

    if account_type in {ACCOUNT_TYPE_MASTER, ACCOUNT_TYPE_SUB}:
        cache.set(cache_key, account_type, timeout=ACCOUNT_TYPE_CACHE_TTL_SECONDS)
    return account_type


def _is_master_account(client: BinanceFuturesClient) -> bool:
    """Compatibility predicate; unknown is deliberately not treated as master."""
    return account_type_for_client(client) == ACCOUNT_TYPE_MASTER


TRANSFER_OK_STATUSES = {"CONFIRMED", "SUCCESS", "COMPLETED"}


def _transfer_history_window(attempted_at, created_at) -> tuple[int, int]:
    submitted_at = attempted_at or created_at
    now = timezone.now()
    start_at = submitted_at - timedelta(seconds=1)
    end_at = min(
        now,
        submitted_at + timedelta(seconds=TRANSFER_RECONCILIATION_WINDOW_SECONDS),
    )
    if end_at < start_at:
        start_at = end_at
    start_ms = int(start_at.timestamp() * 1000)
    end_ms = int(end_at.timestamp() * 1000)
    return start_ms, end_ms


def _first_confirmed_transfer(
    rows,
    *,
    asset: str,
    expected_amount: Decimal,
    ok_statuses: set,
    amount_fields: tuple = ("amount",),
    type_field: str = "",
    type_value: str = "",
    counterparty: str = "",
    id_fields: tuple = ("tranId",),
    tolerance: Decimal = Decimal("0.00000001"),
) -> str:
    """通用站内划转对账：在各交易所历史接口字段名不统一的情况下，
    把币种/类型/金额/状态/对手方的判据集中在这一个函数里维护，
    调用方只声明差异。匹配到返回历史流水号，否则返回空串。
    """
    for row in rows:
        if str(row.get("asset") or "").upper() != asset:
            continue
        if type_field:
            actual_type = str(row.get(type_field) or "").strip()
            if not actual_type or actual_type != type_value:
                continue
        actual = next((row.get(field) for field in amount_fields if row.get(field) is not None), None)
        if actual is None or abs(_decimal(actual) - expected_amount) > tolerance:
            continue
        actual_status = str(row.get("status") or "").strip().upper()
        if not actual_status or actual_status not in ok_statuses:
            continue
        if counterparty:
            actual_counterparty = str(row.get("counterParty") or "").strip().lower()
            if not actual_counterparty or actual_counterparty != counterparty.lower():
                continue
        for id_field in id_fields:
            if row.get(id_field):
                return str(row[id_field])
        return "history-confirmed"
    return ""


def _matching_master_transfer(client: BinanceFuturesClient, sweep: CapitalSweep):
    start_ms, end_ms = _transfer_history_window(sweep.master_attempted_at, sweep.created_at)
    rows = client.get_sub_account_transfer_history(
        ccy=sweep.asset,
        start_time_ms=start_ms,
        end_time_ms=end_ms,
    )
    return _first_confirmed_transfer(
        rows,
        asset=sweep.asset,
        expected_amount=sweep.amount,
        ok_statuses=TRANSFER_OK_STATUSES,
        amount_fields=("qty", "amount"),
        counterparty="master",
        id_fields=("tranId", "txnId"),
    )


def _matching_spot_futures_transfer(
    client: BinanceFuturesClient,
    sweep: CapitalSweep,
    *,
    amount: Decimal,
    transfer_type: str,
    attempted_at,
):
    start_ms, end_ms = _transfer_history_window(attempted_at, sweep.created_at)
    rows = client.get_spot_futures_transfer_history(
        ccy=sweep.asset,
        start_time_ms=start_ms,
        end_time_ms=end_ms,
    )
    return _first_confirmed_transfer(
        rows,
        asset=sweep.asset,
        expected_amount=amount,
        ok_statuses=TRANSFER_OK_STATUSES,
        type_field="type",
        type_value=transfer_type,
    )


def _matching_spot_to_futures_transfer(client: BinanceFuturesClient, sweep: CapitalSweep):
    return _matching_spot_futures_transfer(
        client,
        sweep,
        amount=sweep.spot_refill_amount,
        transfer_type="1",
        attempted_at=sweep.spot_refill_attempted_at,
    )


def _matching_futures_to_spot_transfer(client: BinanceFuturesClient, sweep: CapitalSweep):
    return _matching_spot_futures_transfer(
        client,
        sweep,
        amount=sweep.futures_amount,
        transfer_type="2",
        attempted_at=sweep.futures_attempted_at,
    )


def _matching_funding_to_futures_transfer(client: BinanceFuturesClient, sweep: CapitalSweep):
    start_ms, end_ms = _transfer_history_window(
        sweep.funding_refill_attempted_at,
        sweep.created_at,
    )
    rows = client.get_universal_transfer_history(
        transfer_type="FUNDING_UMFUTURE",
        start_time_ms=start_ms,
        end_time_ms=end_ms,
    )
    return _first_confirmed_transfer(
        rows,
        asset=sweep.asset,
        expected_amount=sweep.funding_refill_amount,
        ok_statuses=TRANSFER_OK_STATUSES,
        type_field="type",
        type_value="FUNDING_UMFUTURE",
    )


def _matching_funding_to_spot_transfer(client: BinanceFuturesClient, sweep: CapitalSweep):
    start_ms, end_ms = _transfer_history_window(sweep.funding_attempted_at, sweep.created_at)
    rows = client.get_universal_transfer_history(
        transfer_type="FUNDING_MAIN",
        start_time_ms=start_ms,
        end_time_ms=end_ms,
    )
    return _first_confirmed_transfer(
        rows,
        asset=sweep.asset,
        expected_amount=sweep.funding_amount,
        ok_statuses=TRANSFER_OK_STATUSES,
        type_field="type",
        type_value="FUNDING_MAIN",
    )


def _matching_internal_transfer(client: BinanceFuturesClient, sweep: CapitalSweep):
    """按本次 withdrawOrderId 严格确认 Binance 提现状态。

    精确匹配且已完成的链上提现也是终态，绝不能误报为资金仍在现货并允许重提。
    """
    order_id = str(getattr(sweep, "master_withdraw_order_id", "") or "").strip()
    if not order_id:
        return "", "missing", "缺少本次归集的 withdrawOrderId"
    attempted_at = sweep.master_attempted_at or sweep.created_at
    start_ms = int((attempted_at - timedelta(seconds=5)).timestamp() * 1000)
    rows = client.get_withdraw_history(
        ccy=sweep.asset,
        withdraw_order_id=order_id,
        start_time_ms=start_ms,
    )
    for row in rows:
        if str(row.get("withdrawOrderId") or "").strip() != order_id:
            continue
        if str(row.get("coin") or "").upper() != sweep.asset:
            continue
        if not _withdraw_amount_matches(row.get("amount"), sweep.amount):
            continue
        expected_address = str(getattr(sweep, "master_destination_address", "") or "").strip()
        actual_address = str(row.get("address") or "").strip()
        if expected_address and actual_address and actual_address != expected_address:
            continue
        expected_network = str(getattr(sweep, "master_destination_network", "") or "").strip().upper()
        actual_network = str(row.get("network") or "").strip().upper()
        if expected_network and actual_network and actual_network != expected_network:
            continue

        status = str(row.get("status") or "").strip().upper()
        if status in {"PROCESSING", "PENDING", "AWAITING_APPROVAL"}:
            return "", "pending", str(row.get("info") or "提现申请处理中")
        if status in WITHDRAW_PENDING_STATUSES:
            return "", "pending", str(row.get("info") or "提现申请处理中")
        if status in WITHDRAW_FAILED_STATUSES:
            return "", "failed", str(row.get("info") or "交易所拒绝或取消了提现申请")
        if status != WITHDRAW_COMPLETED_STATUS and status not in {"COMPLETED", "SUCCESS"}:
            return "", "pending", str(row.get("info") or "提现状态尚未最终确认")

        transfer_type = str(row.get("transferType") or "").strip()
        txid = str(row.get("txId") or "").strip()
        is_internal = transfer_type == "1" or txid.startswith("INNER_WITHDRAW")
        history_id = str(row.get("id") or txid or "history-confirmed")
        if is_internal:
            return history_id, "completed", "Binance 提现历史确认为站内转账"
        return history_id, "completed_onchain", "Binance 提现历史显示为链上转出"
    if timezone.now() - attempted_at < timedelta(seconds=WITHDRAW_HISTORY_VISIBILITY_GRACE_SECONDS):
        return "", "pending", "提现历史可能尚未同步，请稍后重新确认"
    return "", "missing", "未查到本次提现流水，无法证明请求失败；系统不会自动重试"


def _reconcile_uncertain_sub_to_master(
    client: BinanceFuturesClient,
    sweep: CapitalSweep,
) -> bool:
    try:
        history_id = _matching_master_transfer(client, sweep)
    except Exception as exc:  # noqa: BLE001
        logger.warning(
            "capital sweep master retry uncertain sweep=%s user=%s err=%s",
            sweep.id,
            sweep.user_id,
            safe_error_summary(exc),
        )
    else:
        if history_id:
            _complete_master_transfer(sweep, history_id)
            return True
    _pause_sweep(
        sweep,
        "主账户归集结果待确认，系统不会自动重试以避免重复转账；请稍后重新确认",
    )
    return False


def _complete_spot_to_own_master(client: BinanceFuturesClient, sweep: CapitalSweep) -> bool:
    if sweep.master_attempted_at:
        try:
            history_id = _matching_master_transfer(client, sweep)
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "capital sweep history uncertain sweep=%s user=%s err=%s",
                sweep.id,
                sweep.user_id,
                safe_error_summary(exc),
            )
            _pause_sweep(sweep, "暂时无法查询主账户归集记录，请稍后重试")
            return False
        if history_id:
            _complete_master_transfer(sweep, history_id)
            return True
        # subToMaster 没有客户端幂等键。只要已经提交过请求且历史尚未
        # 证明失败，就不能根据余额或超时再次发起，否则会造成重复转账。
        _pause_sweep(
            sweep,
            "未查到主账户归集流水，系统不会自动重试以避免重复转账；请稍后重新确认",
        )
        return False

    sweep.master_attempted_at = timezone.now()
    sweep.error = "主账户归集请求已提交，等待交易所确认"
    _save_sweep(sweep, "master_attempted_at", "error")
    try:
        sweep.master_txn_id = client.transfer_spot_to_master(format(sweep.amount, "f"), ccy=sweep.asset)
    except BinanceApiError as exc:
        if is_binance_preflight_rate_limit_error(exc):
            sweep.master_attempted_at = None
            sweep.error = safe_error_summary(exc, include_type=False)
            _save_sweep(sweep, "master_attempted_at", "error")
            return False
        if not exc.outcome_unknown:
            logger.warning(
                "capital sweep to master rejected sweep=%s user=%s code=%s err=%s",
                sweep.id,
                sweep.user_id,
                exc.code,
                safe_error_summary(exc),
            )
            _finish_sweep(
                sweep,
                CapitalSweep.STATUS_FAILED,
                f"现货转主账户被 Binance 拒绝：{safe_error_summary(exc, include_type=False)}。请处理后重新检查",
            )
            return False
        logger.warning(
            "capital sweep to master uncertain sweep=%s user=%s err=%s",
            sweep.id,
            sweep.user_id,
            safe_error_summary(exc),
        )
        return _reconcile_uncertain_sub_to_master(client, sweep)
    except Exception as exc:  # noqa: BLE001
        logger.warning(
            "capital sweep to master uncertain sweep=%s user=%s err=%s",
            sweep.id,
            sweep.user_id,
            safe_error_summary(exc),
        )
        # 先查询唯一可用的子账户归集流水。该接口没有客户端幂等键，
        # 因此响应丢失时宁可保持 pending，也不能根据余额再次发起请求。
        return _reconcile_uncertain_sub_to_master(client, sweep)
    if not sweep.master_txn_id:
        return _reconcile_uncertain_sub_to_master(client, sweep)
    _complete_master_transfer(sweep, sweep.master_txn_id)
    return True


def _complete_spot_to_collect_account(
    client: BinanceFuturesClient,
    sweep: CapitalSweep,
    *,
    collect_address: str,
    collect_network: str,
) -> bool:
    """主账户归集末步：提现到目标主账户 Spot 充值地址。

    Binance 会在目标地址属于本平台账户且 Fast Withdraw 条件满足时内部记账，
    但公开 API 仍按提现申请处理，因此必须以提现历史的最终状态为准。
    """
    if sweep.master_attempted_at:
        return _reconcile_withdrawal(client, sweep)
    destination = str(getattr(sweep, "master_destination_address", "") or "").strip()
    network = str(getattr(sweep, "master_destination_network", "") or "").strip().upper()
    if not destination:
        destination = str(collect_address or "").strip()
    if not network:
        network = str(collect_network or "").strip().upper()
    if not destination or not network:
        # 配置中途被清除：终止本笔流水，下次确认时按最新余额重新规划，避免永久卡死
        _finish_sweep(
            sweep,
            CapitalSweep.STATUS_FAILED,
            "当前为币安主账户，请先配置目标主账户 Spot 充值地址和网络后再重新发起归集",
        )
        return False
    if network not in CAPITAL_COLLECT_NETWORKS:
        _finish_sweep(
            sweep,
            CapitalSweep.STATUS_FAILED,
            "当前资金归集仅支持 BSC（BEP20）、TRX（TRC20）和 ETH（ERC20）网络，请更新目标地址后重试",
        )
        return False

    if not sweep.master_destination_address or not sweep.master_destination_network:
        sweep.master_destination_address = destination
        sweep.master_destination_network = network

    if not sweep.master_withdraw_order_id:
        sweep.master_withdraw_order_id = f"tt{int(time.time() * 1000)}{uuid4().hex[:8]}"
    sweep.master_attempted_at = timezone.now()
    sweep.error = "Binance 提现申请已提交，等待提现历史最终确认"
    _save_sweep(
        sweep,
        "master_destination_address",
        "master_destination_network",
        "master_withdraw_order_id",
        "master_attempted_at",
        "error",
    )
    try:
        sweep.master_txn_id = client.withdraw_to_binance_address(
            format(sweep.amount, "f"),
            address=destination,
            network=network,
            withdraw_order_id=sweep.master_withdraw_order_id,
            ccy=sweep.asset,
        )
    except Exception as exc:  # noqa: BLE001
        failure_reason = safe_error_summary(exc, include_type=False)
        logger.warning(
            "capital internal withdrawal uncertain sweep=%s user=%s err=%s",
            sweep.id,
            sweep.user_id,
            safe_error_summary(exc),
        )
        if is_binance_preflight_rate_limit_error(exc):
            sweep.master_attempted_at = None
            sweep.error = failure_reason
            _save_sweep(sweep, "master_attempted_at", "error")
            return False
        if _withdraw_exception_is_deterministic(exc):
            # 交易所明确拒绝：资金未转出，直接终结流水，无需再查提现历史。
            _finish_sweep(
                sweep,
                CapitalSweep.STATUS_FAILED,
                f"主账户提现申请被 Binance 拒绝：{failure_reason}。资金仍在现货，请处理后重新检查",
            )
            return False
        return _reconcile_withdrawal(client, sweep)
    # 受理不等于到账；立即查一次精确历史，未完成则由同一流水继续查询。
    sweep.error = "提现申请已受理，等待 Binance 提现历史确认"
    _save_sweep(sweep, "master_txn_id", "error")
    return _reconcile_withdrawal(client, sweep)


def _reconcile_withdrawal(client: BinanceFuturesClient, sweep: CapitalSweep) -> bool:
    try:
        history_id, history_state, history_detail = _matching_internal_transfer(client, sweep)
    except Exception as exc:  # noqa: BLE001
        logger.warning("capital withdrawal history uncertain sweep=%s err=%s", sweep.id, safe_error_summary(exc))
        _pause_sweep(sweep, "暂时无法查询转出记录，保留原流水继续确认")
        return False
    reconciled = _apply_withdraw_history_result(
        sweep,
        history_id=history_id,
        history_state=history_state,
        history_detail=history_detail,
        pending_prefix="主账户归集结果正在确认",
        failed_prefix="主账户提现未完成",
    )
    if reconciled is not None:
        return reconciled
    _pause_sweep(sweep, "未查到本次提现流水，保留原流水继续查询，不会重复转账")
    return False


def _complete_spot_to_master(
    client: BinanceFuturesClient,
    sweep: CapitalSweep,
    *,
    collect_address: str = "",
    collect_network: str = "",
) -> tuple[bool, str, bool]:
    """归集末步分流：子账户→所属主账户现货；主账户→配置的归集账号。
    返回 (是否完成, 路径, 是否已终止流水需要重新规划)。"""
    # 已提交的路径由流水决定；配置清除或探测故障不能阻挡真实回执收敛。
    if sweep.master_attempted_at:
        account_type = ACCOUNT_TYPE_MASTER if sweep.master_withdraw_order_id else ACCOUNT_TYPE_SUB
    else:
        account_type = account_type_for_client(client)
    if account_type == ACCOUNT_TYPE_UNKNOWN:
        _pause_sweep(sweep, "无法确认 Binance 账户类型，归集已暂停，请稍后重新检查")
        return False, "unknown", False
    if account_type == ACCOUNT_TYPE_MASTER:
        completed = _complete_spot_to_collect_account(
            client,
            sweep,
            collect_address=collect_address,
            collect_network=collect_network,
        )
        # 流水已到终态（未配置归集账号、被交易所拒绝、历史明确失败等）时重新规划，
        # 直接给用户最新的可操作状态，避免停留在已无效的待确认页面。
        replan_required = not completed and sweep.status == CapitalSweep.STATUS_FAILED
        return completed, "master", replan_required
    completed = _complete_spot_to_own_master(client, sweep)
    return completed, "sub", not completed and sweep.status == CapitalSweep.STATUS_FAILED


def _wallets_clean(funding: Decimal, spot: Decimal) -> bool:
    """资金/现货账户残差低于清空阈值即视为已归集完毕。"""
    return funding < WALLET_CLEAN_THRESHOLD and spot < WALLET_CLEAN_THRESHOLD


def _transferable_wallet_balance(value: Decimal) -> Decimal:
    """Return the amount this wallet can actually contribute to a transfer plan."""
    return value if value >= WALLET_CLEAN_THRESHOLD else Decimal("0")


def _capital_plan(
    futures: Decimal,
    funding: Decimal,
    spot: Decimal,
    minimum: Decimal,
    maximum: Decimal,
) -> dict[str, Decimal]:
    # 残差钱包不参与规划：既不为它补合约，也不尝试转走它。
    funding = _transferable_wallet_balance(funding)
    spot = _transferable_wallet_balance(spot)
    # A confirmed normalization tries to bring the futures wallet up to the
    # retention cap (5x), while the entry gate remains the lower 1.5x line.
    # Keep both gaps explicit: a remaining gap to 5x is not an entry shortfall
    # when the futures balance is already at or above the opening minimum.
    # Round transfers down so a sub-cent balance gap never pushes the futures
    # wallet above the 5x retention cap.
    refill_required = _amount(maximum - futures) if futures < maximum else Decimal("0")
    funding_to_futures = _amount(min(refill_required, funding))
    refill_remaining = max(Decimal("0"), refill_required - funding_to_futures)
    spot_to_futures = _amount(min(refill_remaining, spot))
    refill_remaining = max(Decimal("0"), refill_remaining - spot_to_futures)

    minimum_refill_required = _amount_up(minimum - futures) if futures < minimum else Decimal("0")
    minimum_refill_remaining = max(
        Decimal("0"), minimum_refill_required - funding_to_futures - spot_to_futures
    )

    funding_collect = _amount(funding - funding_to_futures)
    spot_collect = _amount(spot - spot_to_futures)
    # Excess can only be transferred in cents. Rounding up would take more than
    # the confirmed excess and leave the futures wallet below its 5x target.
    futures_collect = _amount(futures - maximum) if futures > maximum else Decimal("0")
    collection_total = _amount(futures_collect + funding_collect + spot_collect)
    target_balance = futures + funding_to_futures + spot_to_futures - futures_collect
    return {
        "refill_required": refill_required,
        "funding_to_futures": funding_to_futures,
        "spot_to_futures": spot_to_futures,
        "refill_remaining": refill_remaining,
        "minimum_refill_required": minimum_refill_required,
        "minimum_refill_remaining": minimum_refill_remaining,
        "target_balance": target_balance,
        "futures_collect": futures_collect,
        "funding_collect": funding_collect,
        "spot_collect": spot_collect,
        "collection_total": collection_total,
    }


def _remaining_plan_matches(sweep: CapitalSweep, plan: dict) -> bool:
    """Only an unsubmitted remainder can be compared with fresh wallet balances."""
    directions = [direction for _status, _prefix, direction in SWEEP_STAGES]
    stage_index = next(i for i, stage in enumerate(SWEEP_STAGES) if stage[0] == sweep.status)
    frozen = _sweep_state(sweep)
    for i, direction in enumerate(directions):
        expected = _decimal(frozen[direction]) if i >= stage_index else Decimal("0")
        current = plan.get("collection_total" if direction == "transfer_amount" else direction)
        if abs(_decimal(current) - expected) >= DUST_AMOUNT:
            return False
    return True


def _wallet_visibility_grace(sweep: CapitalSweep) -> bool:
    # Use submission times, never updated_at: polling must not prolong the grace.
    return any(
        getattr(sweep, f"{prefix}_tran_id")
        and getattr(sweep, f"{prefix}_attempted_at")
        and timezone.now() - getattr(sweep, f"{prefix}_attempted_at") < timedelta(seconds=WALLET_VISIBILITY_GRACE_SECONDS)
        for _status, prefix, _direction in SWEEP_STAGES[:-1]
    )


def _replan_unsubmitted_sweep(sweep: CapitalSweep, before: dict) -> dict:
    _finish_sweep(sweep, CapitalSweep.STATUS_FAILED, "账户余额或止损设置变化，未提交的剩余步骤按最新余额重新规划")
    before.pop("pending_collection", None)
    return {**before, "plan_changed": True}


def _wallet_state(
    user: User,
    futures: Decimal,
    available: Decimal,
    funding: Decimal,
    spot: Decimal,
) -> dict:
    """预检与补资提醒共用的钱包状态基础字段，键名只在此处定义一份。"""
    maximum = retention_threshold(user)
    minimum = refill_trigger_threshold(user)
    usable_total = (
        futures
        + _transferable_wallet_balance(funding)
        + _transferable_wallet_balance(spot)
    )
    return {
        "base_target": format(maximum, "f"),
        "target": format(maximum, "f"),
        "minimum_open_balance": format(minimum, "f"),
        "maximum_futures_balance": format(maximum, "f"),
        "refill_trigger": format(minimum, "f"),
        "upper_limit": format(maximum, "f"),
        "futures_balance": format(futures, "f"),
        "futures_available": format(available, "f"),
        "funding_available": format(funding, "f"),
        "spot_available": format(spot, "f"),
        "account_total": format(futures + funding + spot, "f"),
        "usable_total": format(usable_total, "f"),
    }


def _shortfall_fields(
    *,
    plan: dict[str, Decimal],
    total: Decimal,
    usable_total: Decimal,
    maximum: Decimal,
) -> dict[str, str]:
    internal = plan["funding_to_futures"] + plan["spot_to_futures"]
    minimum_topup = _amount_up(plan["minimum_refill_remaining"])
    maximum_topup = _amount(maximum - total)
    return {
        "shortfall": format(minimum_topup, "f"),
        "internal_available": format(_amount(internal), "f"),
        "remaining_after_transfer": format(minimum_topup, "f"),
        "minimum_topup": format(minimum_topup, "f"),
        "maximum_topup": format(maximum_topup, "f"),
        "recommended_topup": format(_whole_amount_up(minimum_topup), "f"),
        "usable_total": format(usable_total, "f"),
    }


def capital_precheck(
    user: User,
    client: BinanceFuturesClient,
    *,
    purpose: str = "entry",
    activity_snapshot: Optional[ExchangeActivitySnapshot] = None,
) -> dict:
    maximum = retention_threshold(user)
    minimum = refill_trigger_threshold(user)
    if maximum <= 0:
        raise ValueError("止损金额配置无效")
    activity = (activity_snapshot or load_exchange_activity(client)).flags()
    if activity["has_position"]:
        status = "not_required" if purpose in {"entry", "chase"} else "blocked"
        return {"status": status, "reason": "active_position", **activity}
    if purpose == "manual_sweep" and (activity["has_regular_orders"] or activity["has_algo_orders"]):
        return {"status": "blocked", "reason": "open_exchange_orders", **activity}
    # 开仓资格只看交易所实时状态。待确认流水仅作为账户页的数据源透出，
    # 不能阻塞交易，也不能在这个只读预检中被终结或改写。
    pending_sweep = _pending_sweep(user)
    has_foreign_pending_sweep = (
        pending_sweep is None
        and CapitalSweep.objects.filter(user=user, active_slot=1).exists()
    )
    if purpose == "manual_sweep" and has_foreign_pending_sweep:
        return {
            "status": "blocked",
            "reason": "capital_sweep_binding_mismatch",
            **activity,
        }

    futures, available = _futures_balance(client)
    funding = _decimal(client.get_funding_usdt_free_balance("USDT", fresh=True))
    spot = _decimal(client.get_spot_usdt_free_balance("USDT", fresh=True))
    total = futures + funding + spot
    usable_total = (
        futures
        + _transferable_wallet_balance(funding)
        + _transferable_wallet_balance(spot)
    )
    plan = _capital_plan(futures, funding, spot, minimum, maximum)
    base = {
        **_wallet_state(user, futures, available, funding, spot),
        **{key: format(value, "f") for key, value in plan.items()},
        **activity,
    }
    # Compare the plan the user saw with the locked pre-submit plan. The token
    # is only a change detector; all executable amounts still come from Binance.
    plan_values = [minimum, maximum, *(plan[key] for key in (
        "funding_to_futures", "spot_to_futures", "futures_collect", "funding_collect", "collection_total",
    ))]
    base["plan_token"] = hashlib.sha256("|".join([
        *(format(value.normalize(), "f") for value in plan_values),
        str(getattr(user, "capital_collect_account", "") or ""),
        str(getattr(user, "capital_collect_network", "") or ""),
    ]).encode()).hexdigest()
    if pending_sweep:
        # 仅作为账户页归集确认弹窗的数据源透出，不参与开仓判定。
        base["pending_collection"] = _sweep_state(pending_sweep)
    recent_sweep = _recent_completed_sweep(user) if purpose == "manual_sweep" else None
    if recent_sweep and _wallets_clean(funding, spot) and minimum <= futures <= maximum:
        return {
            **_completed_sweep_state(user, recent_sweep),
            **activity,
        }
    if plan["minimum_refill_remaining"] >= DUST_AMOUNT:
        shortfall_fields = _shortfall_fields(
            plan=plan,
            total=total,
            usable_total=usable_total,
            maximum=maximum,
        )
        if purpose == "manual_sweep" and (
            plan["funding_to_futures"] + plan["spot_to_futures"] >= DUST_AMOUNT
        ):
            return {
                **base,
                **shortfall_fields,
                "status": "normalization_required",
                "reason": "partial_refill_available",
                "transfer_amount": format(plan["collection_total"], "f"),
            }
        return {
            **base,
            **shortfall_fields,
            "status": "shortfall",
        }

    futures_needs_adjustment = (
        futures < minimum or plan["futures_collect"] >= DUST_AMOUNT
    )
    has_refillable_wallet_balance = (
        plan["funding_to_futures"] + plan["spot_to_futures"] >= DUST_AMOUNT
    )
    has_collectible_wallet_balance = plan["collection_total"] >= DUST_AMOUNT
    if futures_needs_adjustment or (
        purpose == "manual_sweep"
        and (has_refillable_wallet_balance or has_collectible_wallet_balance)
    ):
        if futures < minimum:
            reason = "futures_below_open_minimum"
        elif plan["futures_collect"] >= DUST_AMOUNT:
            reason = "futures_above_maximum"
        elif has_refillable_wallet_balance:
            reason = "futures_refill_available"
        else:
            reason = "collectible_wallet_balance"
        return {
            **base,
            "status": "normalization_required",
            "reason": reason,
            "transfer_amount": format(plan["collection_total"], "f"),
        }
    return {**base, "status": "ready"}


def _continue_transfer_step(
    sweep: CapitalSweep,
    *,
    status: str,
    amount_field: str,
    attempted_field: str,
    transaction_field: str,
    next_status: str,
    label: str,
    history_lookup,
    submit,
    allow_submit: bool = True,
) -> Optional[dict]:
    if sweep.status != status:
        return None
    amount = _decimal(getattr(sweep, amount_field))
    if amount < DUST_AMOUNT:
        _advance_sweep(sweep, next_status)
        return None

    attempted_at = getattr(sweep, attempted_field)
    if attempted_at:
        try:
            transaction_id = history_lookup()
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "capital transfer history uncertain sweep=%s user=%s step=%s err=%s",
                sweep.id,
                sweep.user_id,
                status,
                safe_error_summary(exc),
            )
            return _pause_sweep(sweep, f"暂时无法查询{label}流水，请稍后重新确认")
        if transaction_id:
            _advance_sweep(sweep, next_status, **{transaction_field: transaction_id})
            return None
        if timezone.now() - attempted_at >= timedelta(seconds=UNCERTAIN_TRANSFER_RETRY_SECONDS):
            return _pause_sweep(
                sweep,
                f"交易所未查到{label}流水，系统不会自动重试以避免重复划转；请稍后重新确认",
            )
        return _sweep_state(sweep)

    if not allow_submit:
        return _sweep_state(sweep)
    setattr(sweep, attempted_field, timezone.now())
    sweep.error = f"{label}请求已提交，等待交易所确认"
    _save_sweep(sweep, attempted_field, "error")
    try:
        transaction_id = str(submit() or "")
    except BinanceApiError as exc:
        if is_binance_preflight_rate_limit_error(exc):
            setattr(sweep, attempted_field, None)
            sweep.error = safe_error_summary(exc, include_type=False)
            _save_sweep(sweep, attempted_field, "error")
            return _sweep_state(sweep)
        if not exc.outcome_unknown:
            logger.warning(
                "capital transfer rejected sweep=%s user=%s step=%s code=%s err=%s",
                sweep.id,
                sweep.user_id,
                status,
                exc.code,
                safe_error_summary(exc),
            )
            _finish_sweep(
                sweep,
                CapitalSweep.STATUS_FAILED,
                f"{label}被 Binance 拒绝：{safe_error_summary(exc, include_type=False)}。请处理后重新检查",
            )
            return _sweep_state(sweep)
        logger.warning(
            "capital transfer uncertain sweep=%s user=%s step=%s err=%s",
            sweep.id,
            sweep.user_id,
            status,
            safe_error_summary(exc),
        )
        return _pause_sweep(sweep, f"{label}结果待确认，请稍后重新确认")
    except Exception as exc:  # noqa: BLE001
        logger.warning(
            "capital transfer uncertain sweep=%s user=%s step=%s err=%s",
            sweep.id,
            sweep.user_id,
            status,
            safe_error_summary(exc),
        )
        return _pause_sweep(sweep, f"{label}结果待确认，请稍后重新确认")
    if not transaction_id:
        return _pause_sweep(sweep, f"{label}未返回流水号，保留原请求继续确认")
    _advance_sweep(sweep, next_status, **{transaction_field: transaction_id})
    return None


def _continue_pending_sweep(
    user: User, client: BinanceFuturesClient, sweep: CapitalSweep, purpose: str,
    *, allow_submit: bool = True, before_submit=None,
) -> dict:
    steps = [
        {
            "status": CapitalSweep.STATUS_FUNDING_REFILL_PENDING,
            "amount_field": "funding_refill_amount",
            "attempted_field": "funding_refill_attempted_at",
            "transaction_field": "funding_refill_tran_id",
            "next_status": CapitalSweep.STATUS_SPOT_REFILL_PENDING,
            "label": "资金转合约",
            "history_lookup": lambda: _matching_funding_to_futures_transfer(client, sweep),
            "submit": lambda: client.transfer_from_funding(
                format(sweep.funding_refill_amount, "f")
            ),
        },
        {
            "status": CapitalSweep.STATUS_SPOT_REFILL_PENDING,
            "amount_field": "spot_refill_amount",
            "attempted_field": "spot_refill_attempted_at",
            "transaction_field": "spot_refill_tran_id",
            "next_status": CapitalSweep.STATUS_FUTURES_PENDING,
            "label": "现货转合约",
            "history_lookup": lambda: _matching_spot_to_futures_transfer(client, sweep),
            "submit": lambda: client.transfer_between_spot_and_futures(
                format(sweep.spot_refill_amount, "f"), to_futures=True
            ),
        },
        {
            "status": CapitalSweep.STATUS_FUTURES_PENDING,
            "amount_field": "futures_amount",
            "attempted_field": "futures_attempted_at",
            "transaction_field": "futures_tran_id",
            "next_status": CapitalSweep.STATUS_FUNDING_PENDING,
            "label": "合约转现货",
            "history_lookup": lambda: _matching_futures_to_spot_transfer(client, sweep),
            "submit": lambda: client.transfer_between_spot_and_futures(
                format(sweep.futures_amount, "f"), to_futures=False
            ),
        },
        {
            "status": CapitalSweep.STATUS_FUNDING_PENDING,
            "amount_field": "funding_amount",
            "attempted_field": "funding_attempted_at",
            "transaction_field": "funding_tran_id",
            "next_status": CapitalSweep.STATUS_SPOT_PENDING,
            "label": "资金转现货",
            "history_lookup": lambda: _matching_funding_to_spot_transfer(client, sweep),
            "submit": lambda: client.transfer_funding_to_spot(
                format(sweep.funding_amount, "f"), ccy=sweep.asset
            ),
        },
    ]
    for step in steps:
        if (before_submit and allow_submit and sweep.status == step["status"]
                and getattr(sweep, step["amount_field"]) >= DUST_AMOUNT
                and not getattr(sweep, step["attempted_field"])):
            paused = before_submit(sweep)
            if paused is not None:
                return paused
        paused = _continue_transfer_step(sweep, **step, allow_submit=allow_submit)
        if paused is not None:
            if sweep.status == CapitalSweep.STATUS_FAILED:
                return capital_precheck(user, client, purpose=purpose)
            return paused

    if sweep.amount < DUST_AMOUNT:
        _finish_sweep(sweep, CapitalSweep.STATUS_COMPLETED)
        completed = _completed_sweep_state(user, sweep)
        if allow_submit and not sweep.operation and sweep.target_balance < refill_trigger_threshold(user):
            shortfall = capital_shortfall_reminder_preview(user, client)
            return {**completed, **shortfall, "reason": "normalization_completed"}
        return completed

    if not sweep.master_attempted_at:
        if before_submit and allow_submit:
            paused = before_submit(sweep)
            if paused is not None:
                return paused
        if not allow_submit:
            return _sweep_state(sweep)
        # A confirmed inbound transfer can precede visibility in the Spot wallet.
        # Wait before the first irreversible outward request instead of eliciting
        # a deterministic insufficient-balance rejection and requiring a new sweep.
        if _wallet_visibility_grace(sweep):
            try:
                spot = _decimal(client.get_spot_usdt_free_balance(sweep.asset, fresh=True))
            except Exception as exc:  # noqa: BLE001
                logger.warning("capital spot visibility uncertain sweep=%s err=%s", sweep.id, safe_error_summary(exc))
                return _pause_sweep(sweep, "等待确认现货可用余额，尚未提交转出")
            if spot < sweep.amount:
                return _pause_sweep(sweep, WALLET_VISIBILITY_WAIT)
    completed, transfer_path, replan_required = _complete_spot_to_master(
        client,
        sweep,
        collect_address=getattr(user, "capital_collect_account", ""),
        collect_network=getattr(user, "capital_collect_network", ""),
    )
    if not completed:
        if replan_required:
            return capital_precheck(user, client, purpose=purpose)
        return _sweep_state(sweep)
    destination_address = str(getattr(sweep, "master_destination_address", "") or "").strip() if transfer_path == "master" else ""
    destination_network = str(getattr(sweep, "master_destination_network", "") or "").strip() if transfer_path == "master" else ""
    _send_sweep_complete_reminder(
        user,
        sweep,
        destination_address=destination_address,
        destination_network=destination_network,
    )
    return _completed_sweep_state(user, sweep)


def _create_capital_sweep(
    user: User,
    plan: dict,
    *,
    account_type: str,
    api_key_fingerprint: str,
    operation: str = "",
    request_id=None,
) -> CapitalSweep:
    status = CapitalSweep.STATUS_FUNDING_REFILL_PENDING
    try:
        with transaction.atomic():
            User.objects.select_for_update().only("id").get(pk=user.pk)
            if CapitalSweep.objects.filter(user=user, active_slot=1).exists():
                raise ValueError("存在未完结的资金流水，请先完成确认")
            return CapitalSweep.objects.create(
                user=user,
                api_key_fingerprint=api_key_fingerprint,
                operation=operation,
                request_id=request_id,
                active_slot=1,
                amount=_decimal(plan["collection_total"]),
                target_balance=_decimal(plan["target_balance"]),
                funding_refill_amount=_decimal(plan["funding_to_futures"]),
                spot_refill_amount=_decimal(plan["spot_to_futures"]),
                futures_amount=_decimal(plan["futures_collect"]),
                funding_amount=_decimal(plan["funding_collect"]),
                spot_amount=_decimal(plan["spot_collect"]),
                status=status,
                master_destination_address=(
                    str(getattr(user, "capital_collect_account", "") or "").strip()
                    if account_type == ACCOUNT_TYPE_MASTER
                    else ""
                ),
                master_destination_network=(
                    str(getattr(user, "capital_collect_network", "") or "").strip().upper()
                    if account_type == ACCOUNT_TYPE_MASTER
                    else ""
                ),
            )
    except IntegrityError as exc:
        raise ValueError("存在未完结的资金流水，请先完成确认") from exc


@contextmanager
def _capital_activity_lock(user: User, client: BinanceFuturesClient):
    api_key_fingerprint, binding_created_at = get_user_binding_generation(user)
    client_api_key = str(getattr(getattr(client, "credentials", None), "api_key", "") or "")
    if (
        not api_key_fingerprint
        or build_api_key_fingerprint(client_api_key) != api_key_fingerprint
    ):
        raise ValueError("无法确认当前 API 绑定身份，请重新校验 API 后再归集")
    account_identity = build_trading_account_identity(
        user_id=user.id,
        api_key_fingerprint=api_key_fingerprint,
    )
    with user_trading_activity_lock(account_identity) as locked:
        if not locked:
            raise ValueError("资金或交易请求正在处理中，请稍后重试")
        if get_user_binding_generation(user) != (api_key_fingerprint, binding_created_at):
            raise ValueError("API 绑定已发生变化，请刷新后重新检查资金")
        yield api_key_fingerprint


def refresh_capital_precheck(user: User, client: BinanceFuturesClient, *, purpose: str = "manual_sweep") -> dict:
    """Manual panel refresh: settle submitted receipts, never submit a transfer."""
    with _capital_activity_lock(user, client):
        sweep = _pending_sweep(user)
        if sweep and sweep.operation:
            return capital_precheck(user, client, purpose=purpose)
        if sweep and _current_step_submitted(sweep):
            _continue_pending_sweep(user, client, sweep, purpose, allow_submit=False)
        before = capital_precheck(user, client, purpose=purpose)
        if (
            sweep and sweep.status not in {CapitalSweep.STATUS_COMPLETED, CapitalSweep.STATUS_FAILED}
            and not _current_step_submitted(sweep) and not _wallet_visibility_grace(sweep)
            and before["status"] not in {"not_required", "blocked"}
            and not _remaining_plan_matches(sweep, before)
        ):
            return _replan_unsubmitted_sweep(sweep, before)
        return before


def normalize_capital(
    user: User,
    client: BinanceFuturesClient,
    expected_status: str,
    *,
    purpose: str = "entry",
    collection_id: Optional[int] = None,
    expected_plan: str = "",
) -> dict:
    with _capital_activity_lock(user, client) as api_key_fingerprint:
        sweep = None
        if collection_id is not None:
            if expected_status != "collection_pending":
                raise ValueError("归集编号仅用于继续确认原流水")
            sweep = _sweeps_for_current_binding(user).filter(pk=collection_id).first()
            if not sweep:
                raise ValueError("归集流水不属于当前 API 账户，请重新检查")
            if sweep.status == CapitalSweep.STATUS_COMPLETED:
                return _completed_sweep_state(user, sweep)
            if sweep.status == CapitalSweep.STATUS_FAILED:
                return capital_precheck(user, client, purpose=purpose)
        elif expected_status == "collection_pending":
            sweep = _pending_sweep(user)
        pending = sweep or _pending_sweep(user)
        if pending and pending.operation:
            raise ValueError("请在划转 / 转账面板核对该笔资金操作")
        # Receipt queries don't depend on present-day balances or positions.
        # They cannot submit the next step, even when the receipt is confirmed.
        if sweep and _current_step_submitted(sweep):
            result = _continue_pending_sweep(user, client, sweep, purpose, allow_submit=False)
            if sweep.status in {CapitalSweep.STATUS_COMPLETED, CapitalSweep.STATUS_FAILED} or _current_step_submitted(sweep):
                return result
        before = capital_precheck(user, client, purpose=purpose)
        if before["status"] in {"not_required", "blocked"}:
            return before
        if expected_status == "collection_pending":
            if not sweep:
                raise ValueError("待归集流水不存在，请重新检查")
            if not _remaining_plan_matches(sweep, before):
                if _wallet_visibility_grace(sweep):
                    return _pause_sweep(sweep, WALLET_VISIBILITY_WAIT)
                return _replan_unsubmitted_sweep(sweep, before)
            if _decimal(before.get("futures_available")) < _decimal(before.get("futures_collect")):
                raise ValueError("合约可用余额不足以归集全部超额资金，请检查账户占用")
            return _continue_pending_sweep(user, client, sweep, purpose)
        if expected_plan and expected_plan != before.get("plan_token"):
            return {**before, "plan_changed": True}
        if expected_status != "normalization_required" or before["status"] != expected_status:
            raise ValueError("账户资金状态已变化，请重新检查")
        if _pending_sweep(user):
            raise ValueError("存在未完结的归集流水，请先完成确认")
        collection_total = _decimal(before.get("collection_total"))
        account_type = ACCOUNT_TYPE_UNKNOWN
        if collection_total >= DUST_AMOUNT:
            account_type = account_type_for_client(client)
            if account_type == ACCOUNT_TYPE_UNKNOWN:
                raise ValueError("无法确认 Binance 账户类型，请稍后重新检查")
            if account_type == ACCOUNT_TYPE_MASTER:
                collect_address = str(getattr(user, "capital_collect_account", "") or "").strip()
                collect_network = str(getattr(user, "capital_collect_network", "") or "").strip().upper()
                if not collect_address or collect_network not in CAPITAL_COLLECT_NETWORKS:
                    raise ValueError(
                        "当前为币安主账户，请先在“我的”页面配置目标主账户的充值网络和地址后再归集"
                    )
        if _decimal(before.get("futures_available")) < _decimal(before.get("futures_collect")):
            raise ValueError("合约可用余额不足以归集全部超额资金，请检查账户占用")
        sweep = _create_capital_sweep(
            user,
            before,
            account_type=account_type,
            api_key_fingerprint=api_key_fingerprint,
        )
        return _continue_pending_sweep(user, client, sweep, purpose)


def capital_shortfall_reminder_preview(user: User, client: BinanceFuturesClient) -> dict:
    maximum = retention_threshold(user)
    minimum = refill_trigger_threshold(user)
    if maximum <= 0:
        raise ValueError("止损金额配置无效")
    futures, available = _futures_balance(client)
    funding = _decimal(client.get_funding_usdt_free_balance("USDT", fresh=True))
    spot = _decimal(client.get_spot_usdt_free_balance("USDT", fresh=True))
    total = futures + funding + spot
    usable_total = (
        futures
        + _transferable_wallet_balance(funding)
        + _transferable_wallet_balance(spot)
    )
    plan = _capital_plan(futures, funding, spot, minimum, maximum)
    shortfall_fields = _shortfall_fields(
        plan=plan,
        total=total,
        usable_total=usable_total,
        maximum=maximum,
    )
    recommended = _decimal(shortfall_fields["recommended_topup"])
    state = {
        "status": (
            "shortfall"
            if plan["minimum_refill_remaining"] >= DUST_AMOUNT
            else "ready"
        ),
        **_wallet_state(user, futures, available, funding, spot),
        **shortfall_fields,
    }
    if state["status"] != "shortfall":
        return state
    binding = ApiBinding.objects.filter(user=user, trading_mode="ordinary").first()
    account_name = (
        getattr(binding, "binance_label", "")
        or getattr(binding, "alias", "")
        or f"用户 {user.id} 的交易账户"
    )
    state["email_subject"] = f"【交易账户补资提醒】请转入 {format(recommended, 'f')} USDT"
    state["email_body"] = (
        f"交易账户：{account_name}\n"
        f"当前账户总余额：{format(total, 'f')} USDT\n"
        f"开仓最低要求：{format(minimum, 'f')} USDT（止损额的 1.5 倍）\n"
        f"至少需要补充：{shortfall_fields['minimum_topup']} USDT\n"
        f"最多可补充：{shortfall_fields['maximum_topup']} USDT（补至止损额的 5 倍）\n"
        f"建议向该交易账户的资金账户转入：{format(recommended, 'f')} USDT。\n"
        "建议金额已向上取整，确保到账后达到开仓最低线；补资金额不要超过最多可补充金额。"
    )
    return state


def send_capital_shortfall_reminder(user: User, client: BinanceFuturesClient) -> dict:
    state = capital_shortfall_reminder_preview(user, client)
    if state.get("status") != "shortfall":
        raise ValueError("账户资金状态已变化，请重新检查")
    recommended = _decimal(state.get("recommended_topup"))
    if recommended < Decimal("1"):
        raise ValueError("补资建议金额无效，请重新检查")
    sent = _send_reminder(
        user,
        "refill_needed",
        state["email_subject"],
        state["email_body"],
        force=True,
    )
    return {**state, "reminder_sent": sent}


def run_capital_reminder_cycle() -> int:
    """Read-only reminder cycle; this function never transfers funds."""
    processed = 0
    seen_users: set[int] = set()
    for binding in ApiBinding.objects.filter(status=1, trading_mode="ordinary").select_related("user").order_by("-updated_at"):
        user = binding.user
        if not user or user.id in seen_users or not user.email:
            continue
        seen_users.add(user.id)
        credentials = get_user_binance_credentials(user)
        if not credentials:
            continue
        try:
            client = BinanceFuturesClient(credentials)
            state = capital_precheck(user, client, purpose="manual_sweep")
            if state.get("status") == "blocked":
                processed += 1
                continue
            if state.get("pending_collection"):
                _send_reminder(
                    user,
                    "sweep_pending",
                    "【交易账户归集待确认】请复核资金流水",
                    "超额资金归集结果尚未确认，请在下次开仓前通过资金确认页面重新核验。",
                )
            if (
                _decimal(state.get("minimum_refill_remaining")) >= DUST_AMOUNT
                and _decimal(state["recommended_topup"]) >= Decimal("1")
            ):
                _send_reminder(
                    user,
                    "refill_needed",
                    "【交易账户补资提醒】交易账户资金不足",
                    (
                        f"交易账户距离开仓下限仍差 {state['remaining_after_transfer']} USDT。"
                        f"请向该交易账户资金账户转入 {state['recommended_topup']} USDT；"
                        "该建议金额已向上取整。"
                    ),
                )
            collectible = _decimal(state.get("collection_total"))
            if not state.get("pending_collection") and collectible > SPOT_REMINDER_THRESHOLD:
                account_type = account_type_for_client(client)
                if account_type == ACCOUNT_TYPE_MASTER:
                    collect_configured = bool(
                        str(getattr(user, "capital_collect_account", "") or "").strip()
                        and str(getattr(user, "capital_collect_network", "") or "").strip().upper()
                        in CAPITAL_COLLECT_NETWORKS
                    )
                    _send_reminder(
                        user,
                        "sweep_to_master",
                        "【交易账户归集提醒】现货超额资金待归集",
                        (
                            "请先在“我的”页面配置资金归集账号。"
                            if not collect_configured
                            else f"当前约 {collectible} U 可归集，将在用户确认后按目标地址发起 Binance 内部到账申请。"
                        ),
                    )
                elif account_type == ACCOUNT_TYPE_SUB:
                    _send_reminder(
                        user,
                        "sweep_to_master",
                        "【交易账户归集提醒】子账户资金待转出",
                        f"子账户当前约有 {collectible} U 可归集，请在“我的”页面确认转回所属主账户。",
                    )
                else:
                    logger.warning("capital spot reminder skipped: account type unknown user=%s", user.id)
            processed += 1
        except Exception as exc:  # noqa: BLE001
            if is_binance_rate_limit_error(exc):
                logger.warning(
                    "capital reminder cycle rate limited user=%s err=%s",
                    user.id,
                    safe_error_summary(exc),
                )
                break
            logger.error(
                "capital reminder cycle failed user=%s err=%s",
                user.id,
                safe_error_summary(exc),
            )
    return processed
