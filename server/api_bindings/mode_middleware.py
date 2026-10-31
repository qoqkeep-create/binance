from django.conf import settings
from django.http import JsonResponse

from common.trading_mode import TradingMode, request_trading_mode


# Explicit first-phase surface. Unsupported account/transfer endpoints must
# reject a lead request, never execute against the user's ordinary binding.
LEAD_PATHS = frozenset({
    "/v1/api/bind", "/v1/api/info", "/v1/api/unbind",
    "/v1/account/info", "/v1/account/profile", "/v1/account/stop-loss",
    "/v1/account/stop-loss/cancel", "/v1/account/version",
    "/v1/account/client-layout-log",
    "/v1/account/operation-logs",
    "/v1/trade/symbols", "/v1/trade/symbol/info", "/v1/trade/ema-check",
    "/v1/trade/market/klines", "/v1/trade/market/prices",
    "/v1/trade/open", "/v1/trade/open-position", "/v1/trade/capital/precheck",
    "/v1/trade/limit-order/create", "/v1/trade/limit-order/list",
    "/v1/trade/limit-order/cancel", "/v1/trade/limit-order/chase",
    "/v1/position/list", "/v1/position/history", "/v1/position/close",
    "/v1/position/break-even-stop", "/v1/position/take-profit",
    "/v1/strategy/list", "/v1/strategy/cancel", "/v1/strategy/rebind", "/v1/strategy/log",
    "/v1/strategy/save", "/v1/strategy/delete", "/v1/strategy/set-active",
})

# Disabling rollout stops new risk, while existing portfolios remain manageable.
LEAD_ENTRY_PATHS = frozenset({
    "/v1/api/bind", "/v1/trade/open", "/v1/trade/open-position",
    "/v1/trade/limit-order/create", "/v1/trade/limit-order/chase",
})


class TradingModeMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        if not request.path.startswith(("/v1/", "/api/")):
            return self.get_response(request)
        try:
            mode = request_trading_mode(request)
            if mode == TradingMode.LEAD and request.path.startswith("/v1/") and not request.path.startswith("/v1/auth/"):
                if not getattr(settings, "LEAD_TRADING_ENABLED", False) and request.path.rstrip("/") in LEAD_ENTRY_PATHS:
                    raise ValueError("带单模式暂停新绑定和开仓，已有持仓仍可管理")
                if request.path.rstrip("/") not in LEAD_PATHS:
                    raise ValueError("带单模式暂不支持此功能")
        except ValueError as exc:
            return JsonResponse({"code": 400, "message": str(exc), "data": None}, status=400)
        return self.get_response(request)
