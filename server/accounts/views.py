from common.trading_mode import TradingMode, request_trading_mode
import os
import logging
import hashlib
import re
import time
from decimal import Decimal
from typing import Optional
from urllib.parse import quote
from xml.sax.saxutils import escape

from rest_framework import serializers
from rest_framework.views import APIView

from accounts.services import (
    cancel_pending_stop_loss,
    get_stop_loss_state,
    get_user_trade_balance,
    touch_pending_stop_loss,
    update_stop_loss_amount,
)
from accounts.transfer_history import (
    get_cached_transfer_history,
    sync_transfer_history_for_user,
)
from api_bindings.models import ApiBinding
from api_bindings.services import get_user_binance_credentials
from common.binance import (
    CAPITAL_COLLECT_NETWORKS,
    BinanceApiError,
    BinanceFuturesClient,
    get_usdt_equity_snapshot,
    is_binance_auth_or_permission_error,
    is_binance_rate_limit_error,
)
from common.errors import safe_error_summary
from common.response import fail, ok
from common.request import request_data_mapping
from common.utils import mask_email
from trading.balance_cap import account_type_for_client
from trading.locks import serialized_exchange_mutation
from trading.models import CapitalSweep

logger = logging.getLogger(__name__)


class TransferHistoryQuerySerializer(serializers.Serializer):
    page = serializers.IntegerField(min_value=1, default=1)
    page_size = serializers.IntegerField(min_value=1, max_value=100, default=20)


def _avatar_palette(seed: str) -> tuple[str, str]:
    palettes = [
        ("#F0B90B", "#111827"),
        ("#F59E0B", "#111827"),
        ("#F97316", "#FFFFFF"),
        ("#8B5CF6", "#FFFFFF"),
        ("#3B82F6", "#FFFFFF"),
        ("#10B981", "#FFFFFF"),
    ]
    digest = hashlib.sha256(seed.encode("utf-8")).hexdigest()
    return palettes[int(digest[:2], 16) % len(palettes)]


def _build_avatar_data_url(label: str, seed: str) -> str:
    text = escape((label or "B").strip()[:1].upper() or "B")
    bg_color, text_color = _avatar_palette(seed or text)
    svg = (
        f"<svg xmlns='http://www.w3.org/2000/svg' width='160' height='160' viewBox='0 0 160 160'>"
        f"<rect width='160' height='160' rx='36' fill='{bg_color}'/>"
        f"<text x='50%' y='54%' dominant-baseline='middle' text-anchor='middle' "
        f"font-family='Arial, Helvetica, sans-serif' font-size='72' font-weight='700' fill='{text_color}'>{text}</text>"
        "</svg>"
    )
    return f"data:image/svg+xml;utf8,{quote(svg)}"


def _build_profile_payload(*, request, binding: Optional[ApiBinding], credentials, remote_profile: Optional[dict] = None, sync_error: str = ""):
    alias = (binding.alias if binding else "").strip() if binding else ""
    label = str((remote_profile or {}).get("label") or (binding.binance_label if binding else "") or "Binance Futures 实盘")
    uid = str((remote_profile or {}).get("uid") or (binding.binance_uid if binding else "") or "").strip()
    perm = str((remote_profile or {}).get("perm") or "")
    pos_mode = str((remote_profile or {}).get("posMode") or "")
    # The API key is intentionally never used as an account identifier or
    # avatar seed. UID is exchange-provided; the other fallbacks are local
    # identifiers and do not disclose credentials to the client.
    display_name = alias or uid or "Binance 账户"
    avatar_seed = uid or (f"binding:{binding.pk}" if binding else "") or request.user.email
    avatar_url = _build_avatar_data_url(display_name, avatar_seed)
    return {
        "bound": bool(binding),
        "display_name": display_name,
        "account_label": label,
        "permission": perm,
        "position_mode": pos_mode,
        "email_masked": mask_email(request.user.email),
        "avatar_url": avatar_url,
        "avatar_text": (display_name[:1] or "B").upper(),
        "sync_error": sync_error,
    }


def _perf_ms(start: float) -> int:
    return int((time.perf_counter() - start) * 1000)


def _single_line_log_value(value) -> str:
    """Keep client diagnostics bounded, redacted, and on one physical log line."""
    return safe_error_summary(value, include_type=False, limit=512)


class StopLossUpdateSerializer(serializers.Serializer):
    amount = serializers.DecimalField(
        max_digits=20, decimal_places=2, min_value=Decimal("50"), max_value=Decimal("200"),
        error_messages={"min_value": "止损金额须在 50～200 USDT 之间", "max_value": "止损金额须在 50～200 USDT 之间"},
    )

    def to_internal_value(self, data):
        if isinstance(data, dict) and "percentage" in data:
            raise serializers.ValidationError({"amount": ["止损设置已改为固定金额，请更新客户端并提交 50～200 USDT 的 amount"]})
        return super().to_internal_value(data)


class ClientLayoutLogSerializer(serializers.Serializer):
    reason = serializers.CharField(required=False, allow_blank=True, max_length=64)
    path = serializers.CharField(required=False, allow_blank=True, max_length=256)
    standalone = serializers.BooleanField(required=False)
    user_agent = serializers.CharField(required=False, allow_blank=True, max_length=512)
    metrics = serializers.JSONField(required=False)


class AccountInfoView(APIView):
    def get(self, request):
        if request_trading_mode(request) == TradingMode.LEAD:
            from accounts.mode_settings import lead_account_info
            return ok(data=lead_account_info(request.user, fresh=request.query_params.get("fresh") == "1"))
        total_started = time.perf_counter()
        touch_pending_stop_loss(request.user)
        credentials = get_user_binance_credentials(request.user, trading_mode=request_trading_mode(request))
        if not credentials:
            return ok(
                data={
                    "email_masked": mask_email(request.user.email),
                    "balance": "--",
                    "total_balance": "--",
                    "spot_balance": "--",
                    "funding_balance": "--",
                    "today_pnl": "--",
                    "stop_loss_amount": format(request.user.stop_loss_amount, "f"),
                }
            )

        balance = "--"
        futures_total = "--"
        total_balance = "--"
        today_pnl = "--"
        spot_balance = "--"
        funding_balance = "--"
        exchange_started = time.perf_counter()
        client = BinanceFuturesClient(credentials)
        fresh = str(request.query_params.get("fresh") or "").strip().lower() in {"1", "true", "yes"}
        stop_wallet_queries = False
        try:
            balance, futures_total = get_usdt_equity_snapshot(client, fresh=fresh)
        except BinanceApiError as exc:
            stop_wallet_queries = (
                is_binance_rate_limit_error(exc)
                or is_binance_auth_or_permission_error(exc)
            )
        # 三个钱包分别读取；任一钱包失败都不覆盖其余已成功的余额。
        if not stop_wallet_queries:
            try:
                spot_balance = client.get_spot_usdt_balance(fresh=fresh)
            except BinanceApiError as exc:
                spot_balance = "--"
                stop_wallet_queries = (
                    is_binance_rate_limit_error(exc)
                    or is_binance_auth_or_permission_error(exc)
                )
        if not stop_wallet_queries:
            try:
                funding_balance = client.get_funding_usdt_balance(fresh=fresh)
            except BinanceApiError:
                funding_balance = "--"
        if futures_total != "--" and spot_balance != "--" and funding_balance != "--":
            try:
                client_futures = Decimal(str(futures_total))
                client_spot = Decimal(str(spot_balance))
                client_funding = Decimal(str(funding_balance))
                total_balance = format(client_futures + client_spot + client_funding, "f")
            except (BinanceApiError, ArithmeticError, TypeError, ValueError):
                total_balance = "--"
        exchange_ms = _perf_ms(exchange_started)
        logger.info(
            "perf account_info user=%s total_ms=%s exchange_ms=%s has_credentials=1",
            getattr(request.user, "id", None),
            _perf_ms(total_started),
            exchange_ms,
        )

        return ok(
            data={
                "email_masked": mask_email(request.user.email),
                "balance": balance,
                "total_balance": total_balance,
                "spot_balance": spot_balance,
                "funding_balance": funding_balance,
                "today_pnl": today_pnl,
                "stop_loss_amount": format(request.user.stop_loss_amount, "f"),
                "pending_capital_collection": CapitalSweep.objects.filter(user=request.user, active_slot=1).exists(),
            }
        )


class AccountProfileView(APIView):
    def get(self, request):
        binding = ApiBinding.objects.filter(user=request.user, trading_mode=request_trading_mode(request)).first()
        credentials = get_user_binance_credentials(request.user, trading_mode=request_trading_mode(request))
        if not binding or not credentials:
            return ok(data=_build_profile_payload(request=request, binding=binding, credentials=credentials))

        try:
            client = BinanceFuturesClient(credentials)
            payload = client.get_account_config()
            rows = payload.get("data") or []
            remote_profile = rows[0] if rows else {}
            if binding.binance_uid != str(remote_profile.get("uid") or "").strip():
                binding.binance_uid = str(remote_profile.get("uid") or "").strip()
                binding.save(update_fields=["binance_uid", "updated_at"])
            if binding.binance_label != str(remote_profile.get("label") or "").strip():
                binding.binance_label = str(remote_profile.get("label") or "").strip()
                binding.save(update_fields=["binance_label", "updated_at"])
            return ok(data=_build_profile_payload(
                request=request,
                binding=binding,
                credentials=credentials,
                remote_profile=remote_profile,
            ))
        except BinanceApiError as exc:
            return ok(
                data=_build_profile_payload(
                    request=request,
                    binding=binding,
                    credentials=credentials,
                    sync_error=safe_error_summary(exc, include_type=False),
                )
            )


class TransferHistoryView(APIView):
    def get(self, request):
        query = TransferHistoryQuerySerializer(data=request.query_params)
        if not query.is_valid():
            return fail("分页参数无效")
        try:
            return ok(
                data=get_cached_transfer_history(
                    request.user,
                    page=query.validated_data["page"],
                    page_size=query.validated_data["page_size"],
                )
            )
        except BinanceApiError as exc:
            return fail(safe_error_summary(exc, include_type=False))
        except Exception as exc:  # noqa: BLE001
            logger.error(
                "transfer_history_failed user=%s err=%s",
                getattr(request.user, "id", None),
                safe_error_summary(exc),
            )
            return fail("获取转账历史失败，请稍后重试")


class TransferHistorySyncView(APIView):
    def post(self, request):
        try:
            sync_transfer_history_for_user(request.user)
            return ok(
                data=get_cached_transfer_history(request.user, page=1, page_size=20),
                message="转账历史已同步",
            )
        except BinanceApiError as exc:
            return fail(safe_error_summary(exc, include_type=False))
        except Exception as exc:  # noqa: BLE001
            logger.error(
                "transfer_history_manual_sync_failed user=%s err=%s",
                getattr(request.user, "id", None),
                safe_error_summary(exc),
            )
            return fail("同步转账历史失败，请稍后重试")


class StopLossSettingView(APIView):
    def get(self, request):
        try:
            if request_trading_mode(request) == TradingMode.LEAD:
                from accounts.mode_settings import lead_stop_loss_state
                return ok(data=lead_stop_loss_state(request.user))
            state = get_stop_loss_state(request.user)
            return ok(data=state)
        except BinanceApiError as exc:
            return fail(safe_error_summary(exc, include_type=False))
        except Exception:
            return fail("获取止损设置失败，请稍后重试")

    @serialized_exchange_mutation
    def post(self, request):
        serializer = StopLossUpdateSerializer(data=request.data)
        if not serializer.is_valid():
            errors = serializer.errors
            first_key = next(iter(errors.keys()), None)
            if first_key and errors[first_key]:
                return fail(str(errors[first_key][0]))
            return fail("请求参数错误")

        try:
            if request_trading_mode(request) == TradingMode.LEAD:
                from accounts.mode_settings import lead_stop_loss_state
                return ok(data=lead_stop_loss_state(request.user, amount=serializer.validated_data["amount"]), message="带单止损金额已立即生效")
            message, state = update_stop_loss_amount(
                request.user,
                amount=serializer.validated_data["amount"],
            )
            return ok(message=message, data=state)
        except BinanceApiError as exc:
            return fail(safe_error_summary(exc, include_type=False))
        except Exception:
            return fail("更新止损设置失败，请稍后重试")


class StopLossCancelView(APIView):
    def post(self, request):
        try:
            if request_trading_mode(request) == TradingMode.LEAD:
                from accounts.mode_settings import lead_stop_loss_state
                return ok(data=lead_stop_loss_state(request.user))
            state = cancel_pending_stop_loss(request.user)
            return ok(message="已取消待生效止损调整", data=state)
        except Exception:
            return fail("取消失败，请稍后重试")


class CapitalCollectAccountView(APIView):
    """资金归集目标：主账户归集时使用目标主账户的 Spot 充值地址和网络。

    ``capital_collect_account`` 保留为请求/数据库字段名以兼容既有客户端，
    但其值不再接受邮箱或 UID；它代表充值地址。提现接口只能安全地以地址+
    网络提交，不能依赖未公开的 email/binanceId 参数。
    """

    @staticmethod
    def _valid_address(value: str) -> bool:
        if not value or len(value) > 128 or "@" in value or value.isdigit():
            return False
        # 地址可能包含大小写、数字和少量链特有字符，但不能包含空白或控制字符。
        return value.isascii() and all(char.isprintable() and not char.isspace() for char in value)

    @staticmethod
    def _account_type(credentials) -> str:
        """与归集分流同一口径的主/子判定；未绑定或探测失败保持 unknown。"""
        if not credentials:
            return "unknown"
        try:
            return account_type_for_client(BinanceFuturesClient(credentials))
        except Exception:  # noqa: BLE001
            return "unknown"

    def get(self, request):
        credentials = get_user_binance_credentials(request.user, trading_mode=request_trading_mode(request))
        address = str(getattr(request.user, "capital_collect_account", "") or "")
        network = str(getattr(request.user, "capital_collect_network", "") or "")
        return ok(data={
            "capital_collect_account": address,
            "capital_collect_address": address,
            "capital_collect_network": network,
            "capital_collect_network_supported": network.strip().upper() in CAPITAL_COLLECT_NETWORKS,
            "account_type": self._account_type(credentials),
        })

    def post(self, request):
        payload = request_data_mapping(request)
        if payload is None:
            return fail("请求参数必须是对象")
        raw_address = payload.get("capital_collect_address")
        if raw_address is None:
            raw_address = payload.get("capital_collect_account")
        raw_address_text = str(raw_address or "")
        raw_network_text = str(payload.get("capital_collect_network") or "")
        if raw_address_text and raw_address_text != raw_address_text.strip():
            return fail("目标 Spot 充值地址不能包含首尾空格")
        if raw_network_text and raw_network_text != raw_network_text.strip():
            return fail("目标网络不能包含首尾空格")
        address = raw_address_text.strip()
        network = raw_network_text.strip().upper()

        # 空地址+空网络表示清除配置；只填其中一项属于配置错误，不能静默清除另一项。
        if not address and not network:
            pass
        elif not address or not network:
            return fail("请同时填写目标主账户 Spot 充值地址和网络，或同时清空")
        elif not self._valid_address(address):
            return fail("目标 Spot 充值地址格式不正确；不支持邮箱或 UID")
        elif network not in CAPITAL_COLLECT_NETWORKS:
            return fail("当前资金归集仅支持 BSC（BEP20）、TRX（TRC20）和 ETH（ERC20）网络")

        request.user.capital_collect_account = address
        request.user.capital_collect_network = network
        request.user.save(update_fields=["capital_collect_account", "capital_collect_network", "updated_at"])
        logger.info(
            "capital_collect_account_updated user=%s configured=%s network=%s",
            getattr(request.user, "id", None),
            bool(address and network),
            network or "-",
        )
        return ok(
            message="资金归集目标已保存" if address else "资金归集目标已清除",
            data={
                "capital_collect_account": address,
                "capital_collect_address": address,
                "capital_collect_network": network,
                "capital_collect_network_supported": network in CAPITAL_COLLECT_NETWORKS,
                "account_type": self._account_type(get_user_binance_credentials(request.user, trading_mode=request_trading_mode(request))),
            },
        )


class VersionInfoView(APIView):
    def get(self, request):
        total_started = time.perf_counter()
        env_version = os.getenv("APP_VERSION", "").strip()
        match = re.search(r"([0-9a-fA-F]{7,12})", env_version)
        version_text = match.group(1).lower() if match else "unknown"

        logger.info(
            "perf version_info user=%s total_ms=%s source=%s",
            getattr(request.user, "id", None),
            _perf_ms(total_started),
            "env" if match else "fallback",
        )
        from django.conf import settings
        return ok(data={
            "version": version_text,
            "lead_trading_enabled": settings.LEAD_TRADING_ENABLED,
            "lead_trading_bound": ApiBinding.objects.filter(user=request.user, trading_mode=TradingMode.LEAD).exists(),
        })


class ClientLayoutLogView(APIView):
    def post(self, request):
        serializer = ClientLayoutLogSerializer(data=request.data)
        if not serializer.is_valid():
            return fail("请求参数错误")

        payload = serializer.validated_data
        logger.info(
            "client-layout-log user=%s path=%s reason=%s standalone=%s metrics=%s ua=%s",
            getattr(request.user, "id", None),
            _single_line_log_value(payload.get("path", "")),
            _single_line_log_value(payload.get("reason", "")),
            payload.get("standalone"),
            _single_line_log_value(payload.get("metrics", {})),
            _single_line_log_value(payload.get("user_agent", "")),
        )
        return ok(data={"logged": True})
