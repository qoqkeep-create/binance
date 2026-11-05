"""Read-only Binance margin presentation, independent of trade reconciliation."""
from decimal import Decimal, InvalidOperation
import hashlib
import time

from django.core.cache import cache
from rest_framework.views import APIView

from api_bindings.services import get_user_binding_generation, get_user_trading_account
from common.binance import BinanceApiError
from common.errors import safe_error_summary
from common.response import fail, ok
from common.trading_mode import request_trading_mode


def number(row, key, *, nonnegative=False):
    try:
        value = row[key]
        if isinstance(value, bool):
            raise ValueError(key)
        result = Decimal(str(value))
        if not result.is_finite() or (nonnegative and result < 0):
            raise ValueError(key)
        return result
    except (KeyError, TypeError, InvalidOperation, ValueError) as exc:
        raise BinanceApiError("保证金数据不完整，请稍后重试") from exc


def amount(value):
    return format(value, "f")


def percent(numerator, denominator):
    return amount(numerator / denominator * 100) if denominator > 0 else None


def present_margin(config, account, *, observed_at):
    result = {"supported": False, "observed_at": observed_at, "max_age_seconds": 20,
              "currency": "USDT", "positions": [], "source": "/fapi/v2/account"}
    if type(config.get("multiAssetsMargin")) is not bool:
        raise BinanceApiError("无法确认保证金模式，请稍后重试")
    if config["multiAssetsMargin"]:
        return {**result, "reason": "多资产／组合保证金需在币安查看，本页暂不计算"}
    assets, positions = account.get("assets"), account.get("positions")
    if not isinstance(assets, list) or not isinstance(positions, list) or any(
        not isinstance(row, dict) for row in [*assets, *positions]
    ):
        raise BinanceApiError("保证金账户返回格式异常")
    usdt = [row for row in assets if row.get("asset") == "USDT"]
    if len(usdt) != 1:
        raise BinanceApiError("账户未返回唯一 USDT 保证金余额")
    detail = []
    identities = set()
    for row in positions:
        quantity = number(row, "positionAmt")
        order_margin = number(row, "openOrderInitialMargin", nonnegative=True)
        if quantity == 0 and order_margin == 0:
            continue
        symbol, side = row.get("symbol"), row.get("positionSide")
        if not isinstance(symbol, str) or not symbol.endswith("USDT"):
            return {**result, "reason": "账户存在其他结算资产的仓位或委托，请在币安查看保证金率"}
        if type(row.get("isolated")) is not bool:
            raise BinanceApiError("无法确认仓位保证金模式")
        if row["isolated"]:
            return {**result, "reason": "账户存在逐仓仓位或委托，各逐仓独立承担风险，请在币安查看"}
        if side not in ("BOTH", "LONG", "SHORT") or (symbol, side) in identities:
            raise BinanceApiError("仓位方向数据异常")
        identities.add((symbol, side))
        leverage = number(row, "leverage", nonnegative=True)
        if leverage <= 0 or leverage != leverage.to_integral_value():
            raise BinanceApiError("仓位杠杆数据异常")
        detail.append({"symbol": symbol, "side": ("long" if quantity > 0 else "short" if quantity < 0 else "none")
                       if side == "BOTH" else side.lower(), "quantity": amount(abs(quantity)),
                       "leverage": amount(leverage), "margin_type": "cross",
                       "position_initial_margin": amount(number(row, "positionInitialMargin", nonnegative=True)),
                       "open_order_initial_margin": amount(order_margin),
                       "maintenance_margin": amount(number(row, "maintMargin", nonnegative=True)),
                       "unrealized_profit": amount(number(row, "unrealizedProfit"))})
    asset = usdt[0]
    wallet = number(asset, "walletBalance")
    pnl = number(asset, "unrealizedProfit")
    equity = number(asset, "marginBalance")
    maintenance = number(asset, "maintMargin", nonnegative=True)
    initial = number(asset, "initialMargin", nonnegative=True)
    position_initial = number(asset, "positionInitialMargin", nonnegative=True)
    order_initial = number(asset, "openOrderInitialMargin", nonnegative=True)
    # A single-asset all-cross USDT pool is one liquidation unit. Do not deduct
    # initial margin from equity again, nor substitute availableBalance for it.
    tolerance = Decimal("0.000001")
    if (abs(wallet + pnl - equity) > tolerance
        or abs(position_initial + order_initial - initial) > tolerance
        or abs(sum((Decimal(p["maintenance_margin"]) for p in detail), Decimal(0)) - maintenance) > tolerance
        or abs(sum((Decimal(p["position_initial_margin"]) for p in detail), Decimal(0)) - position_initial) > tolerance
        or abs(sum((Decimal(p["open_order_initial_margin"]) for p in detail), Decimal(0)) - order_initial) > tolerance):
        raise BinanceApiError("保证金快照字段不一致，请稍后重试")
    ratio = percent(maintenance, equity)
    for position in detail:
        position["usage_percent"] = percent(Decimal(position["position_initial_margin"]), equity)
    return {**result, "supported": True, "reason": "", "margin_type": "cross",
            "wallet_balance": amount(wallet), "unrealized_profit": amount(pnl),
            "margin_balance": amount(equity), "maintenance_margin": amount(maintenance),
            "position_initial_margin": amount(position_initial), "open_order_initial_margin": amount(order_initial),
            "initial_margin": amount(initial), "available_balance": amount(number(asset, "availableBalance")),
            "margin_ratio_percent": ratio,
            "liquidation_reached": maintenance > 0 and (equity <= 0 or maintenance >= equity),
            "position_usage_percent": percent(position_initial, equity),
            "total_usage_percent": percent(initial, equity), "positions": detail}


class PositionMarginView(APIView):
    def get(self, request):
        mode = request_trading_mode(request)
        account = get_user_trading_account(request.user, active_only=True, trading_mode=mode)
        if not account:
            return fail("请先绑定 Binance API")
        identity = (f"{account.user_id}:{account.trading_mode}:{account.binding_id}:"
                    f"{account.api_key_fingerprint}:{account.binding_created_at}")
        key = "position:margin:v1:" + hashlib.sha256(identity.encode()).hexdigest()
        try:
            result = cache.get(key)
            if not isinstance(result, dict):
                started = time.time()
                config, snapshot = account.create_futures_client().get_margin_account_snapshot()
                result = present_margin(config, snapshot, observed_at=int(started * 1000))
                if time.time() - started > 20:
                    raise BinanceApiError("保证金快照读取超时，请稍后重试")
                cache.set(key, result, timeout=3)
            if get_user_binding_generation(request.user, trading_mode=mode) != account.generation:
                return fail("API 绑定已变更，请刷新", code=409, status=409)
            return ok(data=result)
        except BinanceApiError as exc:
            return fail(safe_error_summary(exc, include_type=False))
