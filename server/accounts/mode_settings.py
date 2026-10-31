"""Lead portfolio risk settings never overwrite ordinary account settings."""
from decimal import Decimal

from accounts.models import LeadTradingSettings
from accounts.services import round_up_stop_loss
from api_bindings.services import get_user_binance_credentials
from common.binance import BinanceApiError, BinanceFuturesClient, get_usdt_equity_snapshot
from common.trading_mode import TradingMode


def lead_stop_loss_amount(user):
    amount = LeadTradingSettings.objects.filter(user=user).values_list("stop_loss_amount", flat=True).first()
    return amount if amount is not None else Decimal("0")


def lead_balance(user, *, fresh=False):
    credentials = get_user_binance_credentials(user, trading_mode=TradingMode.LEAD)
    if credentials is None:
        raise BinanceApiError("请先绑定带单组合 API")
    return get_usdt_equity_snapshot(BinanceFuturesClient(credentials), fresh=fresh)


def lead_stop_loss_state(user, *, percentage=None):
    _, total = lead_balance(user, fresh=percentage is not None)
    balance = Decimal(total)
    amount = lead_stop_loss_amount(user)
    if percentage is not None:
        if balance <= 0:
            raise BinanceApiError("带单组合暂无可用资产，请先在币安“我的带单”页面充值")
        amount = round_up_stop_loss(balance * Decimal(percentage) / 100)
        LeadTradingSettings.objects.update_or_create(user=user, defaults={"stop_loss_amount": amount})
    return {"current_amount": format(amount, "f"), "pending_amount": None,
            "pending_from_amount": None, "pending_effective_at": None, "countdown_seconds": 0,
            "balance": total, "total_balance": total}


def lead_account_info(user, *, fresh=False):
    balance, total = "--", "--"
    try:
        balance, total = lead_balance(user, fresh=fresh)
    except BinanceApiError:
        pass
    return {"balance": balance, "total_balance": total, "spot_balance": "--", "funding_balance": "--",
            "today_pnl": "--", "stop_loss_amount": format(lead_stop_loss_amount(user), "f"),
            "trading_mode": "lead"}
