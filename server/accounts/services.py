from decimal import Decimal, ROUND_CEILING
from typing import Optional

from django.db import transaction
from django.utils import timezone

from api_bindings.services import get_user_binance_credentials
from common.binance import BinanceApiError, BinanceFuturesClient, get_usdt_total_equity


def round_up_stop_loss(value: Decimal) -> Decimal:
    if value < Decimal("20"):
        step = Decimal("1")
    elif value < Decimal("100"):
        step = Decimal("5")
    else:
        step = Decimal("10")
    quotient = (value / step).to_integral_value(rounding=ROUND_CEILING)
    return max(step, quotient * step)


def touch_pending_stop_loss(user) -> bool:
    # 调高冷却已暂时停用。若数据库里还留有旧版本生成的待生效记录，
    # 下一次读取/更新时也立即落地，避免测试继续被旧倒计时阻塞。
    if not user.pending_stop_loss_amount:
        return False

    user.stop_loss_amount = user.pending_stop_loss_amount
    user.pending_stop_loss_amount = None
    user.pending_stop_loss_from = None
    user.pending_stop_loss_effective_at = None
    user.save(
        update_fields=[
            "stop_loss_amount",
            "pending_stop_loss_amount",
            "pending_stop_loss_from",
            "pending_stop_loss_effective_at",
            "updated_at",
        ]
    )
    return True


def get_user_trade_balance(user) -> Decimal:
    """Return the user's total USDT assets across futures, funding and spot.

    The historical function name is kept for API/test compatibility.  It no
    longer means futures *available* balance: stop-loss percentages must remain
    configurable when funds have not yet been moved into the futures wallet.
    """
    credentials = get_user_binance_credentials(user)
    if not credentials:
        raise BinanceApiError("请先绑定API后再设置止损金额")
    client = BinanceFuturesClient(credentials)
    futures_total = Decimal(get_usdt_total_equity(client))
    spot_total = Decimal(str(client.get_spot_usdt_balance("USDT", fresh=True) or "0"))
    funding_total = Decimal(str(client.get_funding_usdt_balance("USDT", fresh=True) or "0"))
    total = futures_total + spot_total + funding_total
    if total <= 0:
        raise BinanceApiError("未读取到账户总资产，暂时无法设置止损金额")
    return total


def get_stop_loss_state(user, balance: Optional[Decimal] = None) -> dict:
    touch_pending_stop_loss(user)

    countdown_seconds = 0
    pending_effective_at = None
    pending_amount = None
    pending_from = None
    if user.pending_stop_loss_amount and user.pending_stop_loss_effective_at:
        delta = user.pending_stop_loss_effective_at - timezone.now()
        countdown_seconds = max(int(delta.total_seconds()), 0)
        pending_effective_at = user.pending_stop_loss_effective_at.isoformat()
        pending_amount = format(user.pending_stop_loss_amount, "f")
        pending_from = format(user.pending_stop_loss_from or user.stop_loss_amount, "f")

    return {
        "current_amount": format(user.stop_loss_amount, "f"),
        "pending_amount": pending_amount,
        "pending_from_amount": pending_from,
        "pending_effective_at": pending_effective_at,
        "countdown_seconds": countdown_seconds,
        "balance": format(balance, "f") if balance is not None else None,
        # Explicit name for new clients; ``balance`` remains for compatibility
        # with older web builds and now carries the same total-asset value.
        "total_balance": format(balance, "f") if balance is not None else None,
    }


@transaction.atomic
def update_stop_loss_by_percentage(user, percentage: int, balance: Decimal) -> tuple[str, dict]:
    user = type(user).objects.select_for_update().get(pk=user.pk)
    touch_pending_stop_loss(user)

    target_amount = round_up_stop_loss((balance * Decimal(percentage)) / Decimal("100"))
    current_amount = user.stop_loss_amount
    if target_amount == current_amount:
        return "当前止损金额未变化", get_stop_loss_state(user, balance=balance)

    # 测试阶段暂时取消调高止损额的冷却时间。无论调高还是调低，
    # 确认后都立即生效，并清理历史待生效记录，避免旧记录继续阻塞测试。
    user.stop_loss_amount = target_amount
    user.pending_stop_loss_amount = None
    user.pending_stop_loss_from = None
    user.pending_stop_loss_effective_at = None
    user.save(
        update_fields=[
            "stop_loss_amount",
            "pending_stop_loss_amount",
            "pending_stop_loss_from",
            "pending_stop_loss_effective_at",
            "updated_at",
        ]
    )
    return "止损金额已立即生效", get_stop_loss_state(user, balance=balance)


@transaction.atomic
def cancel_pending_stop_loss(user) -> dict:
    user = type(user).objects.select_for_update().get(pk=user.pk)
    user.pending_stop_loss_amount = None
    user.pending_stop_loss_from = None
    user.pending_stop_loss_effective_at = None
    user.save(
        update_fields=[
            "pending_stop_loss_amount",
            "pending_stop_loss_from",
            "pending_stop_loss_effective_at",
            "updated_at",
        ]
    )
    return get_stop_loss_state(user)
