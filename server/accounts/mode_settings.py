"""Lead portfolio risk settings never overwrite ordinary account settings."""
from decimal import Decimal

from accounts.models import LeadTradingSettings
from accounts.services import MAX_STOP_LOSS_AMOUNT, MIN_STOP_LOSS_AMOUNT, validate_stop_loss_amount
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


def lead_stop_loss_state(user, *, amount=None):
    if amount is not None:
        amount = validate_stop_loss_amount(amount)
        LeadTradingSettings.objects.update_or_create(user=user, defaults={"stop_loss_amount": amount})
    else:
        amount = lead_stop_loss_amount(user)
    return {"current_amount": format(amount, "f"), "pending_amount": None,
            "pending_from_amount": None, "pending_effective_at": None, "countdown_seconds": 0,
            "balance": None, "total_balance": None,
            "minimum_amount": format(MIN_STOP_LOSS_AMOUNT, "f"),
            "maximum_amount": format(MAX_STOP_LOSS_AMOUNT, "f")}


def lead_account_info(user, *, fresh=False):
    balance, total = "--", "--"
    try:
        balance, total = lead_balance(user, fresh=fresh)
    except BinanceApiError:
        pass
    return {"balance": balance, "total_balance": total, "spot_balance": "--", "funding_balance": "--",
            "today_pnl": "--", "stop_loss_amount": format(lead_stop_loss_amount(user), "f"),
            "trading_mode": "lead"}
