import logging

from django.db import IntegrityError
from rest_framework.views import APIView

from api_bindings.models import ApiBinding
from api_bindings.serializers import ApiBindSerializer
from api_bindings.services import (
    apply_manual_validation_result,
    build_api_key_fingerprint,
    find_conflicting_binding,
    get_binding_api_key_fingerprint,
    get_binding_binance_credentials,
    get_user_trading_account_identity,
)
from common.binance import BinanceApiError, BinanceCredentials, BinanceFuturesClient, validate_binance_binding
from common.errors import safe_error_summary
from common.response import fail, ok
from common.utils import aes_encrypt
from common.trading_mode import TradingMode, request_trading_mode
from trading.locks import (
    api_binding_lifecycle_lock,
    api_binding_registration_lock,
    user_trading_activity_lock,
)
from trading.account_cache import invalidate_position_caches
from trading.models import CapitalSweep


logger = logging.getLogger(__name__)


def _unbind_blocker(user, binding: ApiBinding) -> str:
    if binding.trading_mode == TradingMode.ORDINARY and CapitalSweep.objects.filter(user=user, active_slot=1).exists():
        return "仍有未完成的资金归集，请确认归集结果后再解绑"

    credentials = get_binding_binance_credentials(binding)
    client = BinanceFuturesClient(credentials)
    if client.get_positions("SWAP").get("data") or []:
        return "交易所仍有真实持仓，请平仓并确认同步后再解绑"
    if client.get_pending_orders("SWAP").get("data") or []:
        return "交易所仍有未成交普通挂单，请处理后再解绑"
    if client.get_pending_algo_orders(inst_type="SWAP").get("data") or []:
        return "交易所仍有未成交条件单，请处理后再解绑"
    return ""


class ApiBindView(APIView):
    def post(self, request):
        serializer = ApiBindSerializer(data=request.data)
        if not serializer.is_valid():
            errors = serializer.errors
            first_key = next(iter(errors.keys()), None)
            if first_key and errors[first_key]:
                return fail(str(errors[first_key][0]))
            return fail("请求参数错误")

        mode = request_trading_mode(request)
        if ApiBinding.objects.filter(user=request.user, trading_mode=mode).exists():
            return fail("绑定失败，当前账号已绑定过Api，请先解除绑定后再重新绑定")

        data = serializer.validated_data
        fingerprint = build_api_key_fingerprint(data["api_key"])
        with api_binding_lifecycle_lock(request.user.id) as lifecycle_locked:
            if not lifecycle_locked:
                return fail("API 绑定正在变更，请稍后重试")
            with api_binding_registration_lock(fingerprint) as locked:
                if not locked:
                    return fail("该 API Key 正在绑定处理中，请稍后重试")
                if ApiBinding.objects.filter(user=request.user, trading_mode=mode).exists():
                    return fail("绑定失败，当前账号已绑定过Api，请先解除绑定后再重新绑定")
                conflict = find_conflicting_binding(
                    user=request.user,
                    api_key=data["api_key"],
                    trading_mode=mode,
                )
                if conflict:
                    return fail("绑定失败，该 API Key 已绑定到其他平台账号，请先解绑后再重试")

                try:
                    validation = validate_binance_binding(
                        BinanceCredentials(
                            api_key=data["api_key"],
                            secret_key=data["secret_key"],
                            passphrase=data["passphrase"],
                            trading_mode=mode,
                        )
                    )
                except BinanceApiError as exc:
                    return fail(safe_error_summary(exc, include_type=False))

                try:
                    ApiBinding.objects.create(
                        user=request.user,
                        trading_mode=mode,
                        api_key=aes_encrypt(data["api_key"]),
                        api_key_fingerprint=fingerprint,
                        secret_key=aes_encrypt(data["secret_key"]),
                        passphrase=aes_encrypt(data["passphrase"]),
                        binance_uid=str(validation.get("uid") or "").strip(),
                        binance_label=str(validation.get("label") or "").strip(),
                        alias=data["alias"],
                        status=1,
                    )
                except IntegrityError:
                    logger.warning("api binding insert conflict user=%s", request.user.id)
                    return fail("绑定失败，账号或 API Key 已被并发绑定，请刷新后重试")
        return ok(message="绑定成功")


class ApiInfoView(APIView):
    def get(self, request):
        binding = ApiBinding.objects.filter(user=request.user, trading_mode=request_trading_mode(request)).first()
        if not binding:
            return ok(data=None, message="未绑定API")

        status = binding.status
        if request.query_params.get("validate") == "1":
            credentials = get_binding_binance_credentials(binding)
            get_binding_api_key_fingerprint(binding, decrypted_api_key=credentials.api_key)

            validation_error = None
            try:
                validate_binance_binding(credentials)
            except BinanceApiError as exc:
                validation_error = exc
            status = apply_manual_validation_result(binding, validation_error)

        return ok(
            data={
                "alias": binding.alias,
                "status": status,
            }
        )


class ApiUnbindView(APIView):
    def post(self, request):
        with api_binding_lifecycle_lock(request.user.id) as lifecycle_locked:
            if not lifecycle_locked:
                return fail("API 绑定正在变更，请稍后重试")
            mode = request_trading_mode(request)
            account_identity = get_user_trading_account_identity(request.user, trading_mode=mode)
            with user_trading_activity_lock(account_identity) as locked:
                if not locked:
                    return fail("账户操作正在进行，请稍后再解绑")
                binding = ApiBinding.objects.filter(user=request.user, trading_mode=mode).first()
                if not binding:
                    return ok(message="解绑成功")
                try:
                    blocker = _unbind_blocker(request.user, binding)
                except Exception as exc:  # noqa: BLE001
                    logger.warning(
                        "api unbind snapshot failed user=%s err=%s",
                        request.user.id,
                        safe_error_summary(exc),
                    )
                    return fail("无法确认交易所持仓和挂单状态，暂不能解绑，请稍后重试")
                if blocker:
                    return fail(blocker)
                invalidate_position_caches(account_identity, legacy_user_id=request.user.id)
                binding.delete()
                return ok(message="解绑成功")
