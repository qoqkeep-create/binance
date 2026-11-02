"""Read account-specific leverage tiers without changing leverage or orders."""
from decimal import Decimal, InvalidOperation

from django.core.cache import cache
from rest_framework.views import APIView

from api_bindings.services import get_user_trading_account
from common.binance import BinanceApiError, to_inst_id, to_symbol
from common.errors import safe_error_summary
from common.response import fail, ok
from common.trading_mode import request_trading_mode


def _tiers(payload, inst_id):
    caps = {}
    if not isinstance(payload, dict):
        return []
    for row in payload.get("data") or []:
        if not isinstance(row, dict) or row.get("instId") != inst_id:
            continue
        for item in row.get("brackets") or []:
            if not isinstance(item, dict):
                continue
            try:
                leverage = Decimal(str(item.get("initialLeverage")))
                cap = Decimal(str(item.get("notionalCap")))
                if (not leverage.is_finite() or not cap.is_finite() or cap <= 0
                        or leverage < 1 or leverage != leverage.to_integral_value()):
                    continue
            except (InvalidOperation, ValueError, TypeError):
                continue
            value = int(leverage)
            caps[value] = max(cap, caps.get(value, Decimal(0)))
    return [{"leverage": leverage, "max_notional": format(caps[leverage], "f")}
            for leverage in sorted(caps, reverse=True)]


def opening_leverage(client, inst_id, requested, *, size, entry_price, instrument):
    """Validate an explicit choice before any exchange mutation; never resize silently."""
    tiers = _tiers(client.get_leverage_bracket(inst_id), inst_id)
    if requested not in {row['leverage'] for row in tiers}:
        raise BinanceApiError('所选杠杆档位已变化，请刷新后重新选择')
    cap = max(Decimal(row['max_notional']) for row in tiers if row['leverage'] >= requested)
    notional = Decimal(str(size)) * Decimal(str(instrument.get('ctVal') or '1')) * entry_price
    if notional > cap:
        raise BinanceApiError('本单金额超过所选杠杆可开上限，请调整止损金额或止损价')
    return requested


def available_capacity(client, tiers):
    payload = client.get_balance('USDT', fresh=True)
    try:
        available = Decimal(str(payload['data'][0]['details'][0]['availEq']))
        if not available.is_finite() or available < 0:
            raise ValueError
    except (KeyError, IndexError, TypeError, InvalidOperation, ValueError):
        raise BinanceApiError('暂时无法取得可用保证金，请稍后重试') from None
    options = [{**row, 'max_open_amount': format(min(Decimal(row['max_notional']),
        available * row['leverage']), 'f')} for row in tiers]
    return sorted(options, key=lambda row: (-Decimal(row['max_open_amount']), row['leverage']))[:3]


class LeverageBracketsView(APIView):
    def get(self, request):
        symbol = str(request.query_params.get("symbol") or "").strip().upper()
        if not symbol.endswith("USDT") or not symbol.isalnum() or len(symbol) > 40:
            return fail("请选择有效的 USDT 交易对")
        mode = request_trading_mode(request)
        account = get_user_trading_account(request.user, active_only=True, trading_mode=mode)
        if account is None:
            return fail("请先绑定 Binance API 后查看杠杆档位")
        generation = account.binding_created_at.isoformat() if account.binding_created_at else "legacy"
        key = f"trade:leverage-tiers:v2:{account.user_id}:{account.cache_namespace}:{generation}:{symbol}"
        cached = cache.get(key)

        try:
            inst_id = to_inst_id(symbol)
            client = account.create_futures_client()
            if cached is not None:
                tiers = cached
            else:
                tiers = _tiers(client.get_leverage_bracket(inst_id), inst_id)
            options = available_capacity(client, tiers)
            if not tiers:
                return fail("暂时无法取得杠杆档位，请稍后重试")
        except BinanceApiError as exc:
            return fail(safe_error_summary(exc, include_type=False))
        current = get_user_trading_account(request.user, active_only=True, trading_mode=mode)
        if current is None or current.binding_id != account.binding_id or current.generation != account.generation:
            return fail("账户绑定已变化，请重新读取杠杆档位", code=409, status=409)
        data = {"symbol": to_symbol(inst_id), "brackets": options}
        cache.set(key, tiers, timeout=300)
        return ok(data)
