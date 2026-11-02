"""HTTP boundary for ordinary-mode wallet previews and explicit execution."""
from rest_framework import serializers
from rest_framework.views import APIView

from api_bindings.services import get_user_binance_credentials
from common.binance import BinanceFuturesClient, BinanceApiError
from common.errors import safe_error_summary
from common.response import fail, ok
from common.trading_mode import TradingMode, request_trading_mode
from trading.capital_wallet import WALLET_ACTIONS, execute_wallet_operation, wallet_precheck


class WalletPreviewSerializer(serializers.Serializer):
    action = serializers.ChoiceField(choices=WALLET_ACTIONS)


class WalletExecuteSerializer(WalletPreviewSerializer):
    request_id = serializers.UUIDField()
    expected_plan = serializers.CharField(max_length=64, allow_blank=True, default="")
    collection_id = serializers.IntegerField(min_value=1, required=False)


class CapitalWalletView(APIView):
    execute = False

    def post(self, request):
        if request_trading_mode(request) != TradingMode.ORDINARY:
            return fail("带单模式暂不支持此功能")
        serializer = (WalletExecuteSerializer if self.execute else WalletPreviewSerializer)(data=request.data)
        if not serializer.is_valid():
            return fail("资金操作参数错误")
        credentials = get_user_binance_credentials(request.user, trading_mode=TradingMode.ORDINARY)
        if not credentials:
            return fail("请先绑定 Binance API")
        try:
            operation = execute_wallet_operation if self.execute else wallet_precheck
            return ok(data=operation(request.user, BinanceFuturesClient(credentials), **serializer.validated_data))
        except (ValueError, BinanceApiError) as exc:
            return fail(safe_error_summary(exc, include_type=False))
        except Exception:
            return fail("暂时无法确认资金状态，请刷新核对原操作")
