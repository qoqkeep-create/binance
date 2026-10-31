"""Mode-specific capabilities; order execution and protection stay shared."""
from decimal import Decimal, ROUND_CEILING

from django.core.cache import cache

from common.binance import BinanceApiError, get_usdt_equity_snapshot, to_symbol
from common.trading_mode import TradingMode, normalize_trading_mode


class OrdinaryTradingAdapter:
    def validate_entry(self, client, symbol):
        return None

    def filter_symbols(self, client, symbols):
        return symbols

    def capital_precheck(self, user, client, **kwargs):
        from trading.balance_cap import capital_precheck
        return capital_precheck(user, client, **kwargs)


class LeadTradingAdapter:
    def validate_binding(self, client, *, config=None):
        if not client.get_lead_trader_status():
            raise BinanceApiError("该 API 未通过带单员身份校验，请使用带单组合页面创建的 API")
        config = config if config is not None else client.get_account_config(fresh=True)["data"][0]
        if config.get("canTrade") is not True:
            raise BinanceApiError("未确认带单 API 的合约交易权限，请检查权限及 IP 白名单")
        if config.get("multiAssetsMargin") is not False:
            raise BinanceApiError("带单模式仅支持 USDT 单资产保证金，请检查带单组合设置")

    def _symbols(self, client):
        import hashlib
        digest = hashlib.sha256(client.credentials.api_key.encode()).hexdigest()
        key = f"trade:lead:symbols:{digest}"
        symbols = cache.get(key)
        if symbols is None:
            symbols = client.get_lead_symbols()
            cache.set(key, symbols, timeout=60)
        return set(symbols)

    def validate_entry(self, client, symbol):
        if to_symbol(symbol) not in self._symbols(client):
            raise BinanceApiError("该交易对不在当前带单组合的 USDT 交易白名单中")

    def filter_symbols(self, client, symbols):
        allowed = self._symbols(client)
        return [symbol for symbol in symbols if to_symbol(symbol) in allowed]

    def capital_precheck(self, user, client, *, purpose="entry", activity_snapshot=None):
        from accounts.mode_settings import lead_stop_loss_amount
        from trading.balance_cap import load_exchange_activity
        amount = lead_stop_loss_amount(user)
        if amount <= 0:
            raise BinanceApiError("请先在“我的”中设置带单止损额度")
        activity = activity_snapshot or load_exchange_activity(client)
        if activity.positions:
            return {"status": "not_required", "reason": "has_positions"}
        _, total = get_usdt_equity_snapshot(client, fresh=True)
        balance = Decimal(total)
        lower, upper = amount * Decimal("1.5"), amount * Decimal("5")
        if lower <= balance <= upper:
            return {"status": "ready", "trading_mode": "lead"}
        shortfall = max(lower - balance, Decimal("0")).to_integral_value(rounding=ROUND_CEILING)
        excess = max(balance - upper, Decimal("0"))
        message = (
            f"带单组合资金不足，至少需补充 {shortfall} USDT，请在币安“我的带单”页面划入"
            if balance < lower else
            f"带单组合余额超过 5 倍止损额，请在币安“我的带单”页面转出 {excess:f} USDT 后再开仓"
        )
        return {"status": "shortfall" if balance < lower else "normalization_required",
                "trading_mode": "lead", "message": message, "shortfall": str(shortfall),
                "reason": "futures_below_minimum" if balance < lower else "futures_above_maximum"}


def trading_adapter(mode=TradingMode.ORDINARY):
    return LeadTradingAdapter() if normalize_trading_mode(mode) == TradingMode.LEAD else OrdinaryTradingAdapter()
