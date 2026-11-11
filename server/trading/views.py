from common.trading_mode import TradingMode, request_trading_mode
from trading.adapters import trading_adapter
from datetime import timedelta
from decimal import Decimal, InvalidOperation
from functools import partial
import hmac
import json
import logging
import math
import os
import re
import time
from uuid import uuid4
from typing import Optional
from urllib import request

from django.conf import settings
from django.core.cache import cache
from django.db import IntegrityError, transaction
from django.utils import timezone
from rest_framework import serializers
from rest_framework.permissions import AllowAny
from rest_framework.views import APIView

from api_bindings.services import (
    get_user_binding,
    get_user_binance_credentials,
    get_user_api_key_fingerprint,
    get_user_trading_account,
    scope_queryset_to_trading_account,
)
from api_bindings.context import build_trading_account_identity
from common.binance import (
    BinanceApiError,
    BinanceFuturesClient,
    binance_get_candles,
    binance_get_historical_candles,
    binance_get_instruments,
    binance_get_cached_last_prices,
    binance_get_ticker,
    calc_contract_size,
    is_binance_auth_or_permission_error,
    is_binance_rate_limit_error,
    normalize_stop_trigger_price,
    normalize_limit_price,
    should_verify_cancel_result,
    standardize_open_order_request,
    to_inst_id,
    to_symbol,
)
from common.binance_rate_limit import RequestPriority
from common.errors import safe_error_summary
from common.response import fail, ok
from common.request import request_data_mapping
from positions.cleanup import (
    best_effort_cleanup_closed_order_exchange_artifacts,
    persist_closed_order_cleanup_result,
)
from positions.lifecycle import fetch_close_anchor, persist_confirmed_close_transition
from positions.models import Order, LimitOrder
from positions.notifications import (
    enqueue_open_notification,
    infer_exchange_close_notification,
)
from trading.models import Strategy, TradeOpenRequest, TradingViewMessage
from trading.account_cache import invalidate_position_caches
from trading.execution import PARTIALLY_FILLED, confirm_entry_execution, parse_entry_execution
from trading.entry_guard import entry_submission_guard
from trading.locks import serialized_exchange_mutation
from trading.market_snapshots import SnapshotBusy, fresh_snapshot
from trading.opening import (
    load_exchange_order_by_client_order_id as _load_exchange_order_by_client_order_id,
    require_exchange_order_row,
    submit_or_recover_exchange_order,
    validate_recovered_exchange_order,
)
from trading.open_requests import (
    OpenRequestPayloadConflict,
    attach_open_request_order,
    build_client_order_id as _idempotent_client_order_id,
    find_existing_order_by_open_request as _find_existing_order_by_open_request,
    get_open_request_execution_intent,
    mark_open_request_recovered,
    mark_open_request_failed,
    mark_open_request_submitted,
    record_open_request_execution_intent,
    record_open_request_error as _record_open_request_error,
    record_open_request_uncertain,
    resolve_open_request,
)
from trading.strategy_views import StrategySaveSerializer
from trading.services import (
    adopt_entry_execution,
    defer_incomplete_limit_execution,
    finalize_confirmed_emergency_close as _mark_order_closed_after_emergency,
)
from trading.constants import (
    ALLOWED_TRADING_SYMBOLS,
    MAX_CONCURRENT_POSITIONS,
    PINNED_TRADING_SYMBOLS,
)
from trading.balance_cap import (
    ExchangeActivitySnapshot,
    capital_shortfall_reminder_preview,
    capital_precheck,
    load_exchange_activity,
    normalize_capital,
    refresh_capital_precheck,
    send_capital_shortfall_reminder,
)

logger = logging.getLogger(__name__)
TV_MESSAGE_API_TOKEN = os.getenv("TV_MESSAGE_API_TOKEN", "").strip()
TV_MESSAGE_RETENTION_DAYS = 3
TOTAL_FEE_RATE = Decimal("0.001")
MARKET_KLINE_INTERVALS = {"1m", "3m", "5m", "15m", "30m", "1h", "2h", "4h", "1d"}


def _positive_env_int(name: str, default: int) -> int:
    try:
        return max(1, int(os.getenv(name, str(default))))
    except (TypeError, ValueError):
        logger.warning("invalid positive integer setting %s; using default=%s", name, default)
        return default


# K 线缓存预热：请求方只记录热点，scheduler 后台定期刷新缓存，
# 用户切换币种/周期时直接命中缓存，不再等待币安往返。
# 热点索引存放在缓存（生产为 Redis）中，供多个 web worker 与 scheduler 跨进程共享。
MARKET_KLINE_WARMUP_DEFAULT_INTERVAL = "15m"
MARKET_KLINE_HOT_TTL = 600
MARKET_KLINE_HOT_MAX = _positive_env_int("MARKET_KLINE_HOT_MAX", 200)
MARKET_KLINE_HOT_KEY = "trade:market-klines:hot-index"
MARKET_KLINE_CACHE_MIN_TTL = 10
MARKET_KLINE_WARM_BATCH_SIZE = _positive_env_int("MARKET_KLINE_WARM_BATCH_SIZE", 8)
MARKET_KLINE_INTERVAL_SECONDS = {
    "1m": 60,
    "3m": 180,
    "5m": 300,
    "15m": 900,
    "30m": 1800,
    "1h": 3600,
    "2h": 7200,
    "4h": 14400,
    "1d": 86400,
}
MARKET_KLINE_BOUNDARY_GRACE_SECONDS = 2
PUBLIC_MARKET_KLINE_LIMIT = 300
ORDER_RECOVERY_RETRY_DELAYS_SECONDS = (0.0, 0.15, 0.35, 0.75, 1.25)


def _market_kline_cache_key(symbol: str, interval: str, limit: int) -> str:
    return f"trade:market-klines:{symbol}:{interval}:{limit}"


def _market_kline_refresh_cadence(interval: str) -> int:
    """按周期决定后台刷新频率：短周期形成中的K线变化快，长周期无需频繁拉取。"""
    return {
        "1m": 2,
        "3m": 3,
        "5m": 5,
        "15m": 10,
        "30m": 20,
        "1h": 30,
        "2h": 60,
        "4h": 120,
        "1d": 300,
    }.get(interval, 30)


def _market_kline_cache_ttl(interval: str, *, now: Optional[float] = None) -> int:
    """Keep snapshots warm without carrying an unfinished candle across its close."""
    base_ttl = max(MARKET_KLINE_CACHE_MIN_TTL, _market_kline_refresh_cadence(interval) * 2)
    interval_seconds = MARKET_KLINE_INTERVAL_SECONDS.get(interval)
    if interval_seconds is None:
        return base_ttl
    current_time = time.time() if now is None else now
    seconds_to_boundary = interval_seconds - (current_time % interval_seconds)
    boundary_ttl = math.ceil(seconds_to_boundary) + MARKET_KLINE_BOUNDARY_GRACE_SECONDS
    return max(1, min(base_ttl, boundary_ttl))


def _market_kline_timestamp(entry: dict[str, float], field: str) -> float:
    try:
        return float(entry.get(field, 0.0))
    except (TypeError, ValueError):
        return 0.0


def _market_kline_hot_index_key(symbol: str, interval: str, limit: int) -> str:
    return f"{symbol}|{interval}|{limit}"


def _market_kline_read_hot() -> dict[str, dict[str, float]]:
    try:
        data = cache.get(MARKET_KLINE_HOT_KEY)
    except Exception:  # noqa: BLE001
        return {}
    if not isinstance(data, dict):
        return {}
    return {str(key): dict(entry) for key, entry in data.items() if isinstance(entry, dict)}


def _market_kline_write_hot(hot: dict[str, dict[str, float]]) -> None:
    try:
        cache.set(MARKET_KLINE_HOT_KEY, hot, timeout=MARKET_KLINE_HOT_TTL + 120)
    except Exception:  # noqa: BLE001
        logger.warning("write market klines hot index failed")


def _market_kline_mark_hot(symbol: str, interval: str, limit: int) -> None:
    now = time.time()
    hot = _market_kline_read_hot()
    for key, entry in list(hot.items()):
        if now - _market_kline_timestamp(entry, "seen") > MARKET_KLINE_HOT_TTL:
            hot.pop(key, None)
    entry = hot.setdefault(_market_kline_hot_index_key(symbol, interval, limit), {"warmed": 0.0})
    entry["seen"] = now
    while len(hot) > MARKET_KLINE_HOT_MAX:
        oldest = min(hot.items(), key=lambda item: _market_kline_timestamp(item[1], "seen"))[0]
        hot.pop(oldest, None)
    _market_kline_write_hot(hot)


def _market_kline_candle_valid(candle: object) -> bool:
    if not isinstance(candle, dict):
        return False
    try:
        timestamp_value = candle["t"]
        if isinstance(timestamp_value, bool) or not isinstance(timestamp_value, int):
            return False
        timestamp = timestamp_value
        open_price = Decimal(str(candle["o"]))
        high_price = Decimal(str(candle["h"]))
        low_price = Decimal(str(candle["l"]))
        close_price = Decimal(str(candle["c"]))
        volume = Decimal(str(candle["v"]))
    except (KeyError, TypeError, ValueError, InvalidOperation):
        return False
    prices = (open_price, high_price, low_price, close_price)
    return (
        timestamp > 0
        and all(value.is_finite() and value > 0 for value in prices)
        and volume.is_finite()
        and volume >= 0
        and high_price >= max(prices)
        and low_price <= min(prices)
    )


def _market_kline_snapshot_valid(cached: object, symbol: str, interval: str) -> bool:
    if not isinstance(cached, dict):
        return False
    candles = cached.get("candles")
    if not (
        cached.get("symbol") == symbol
        and cached.get("interval") == interval
        and isinstance(candles, list)
        and bool(candles)
        and all(_market_kline_candle_valid(candle) for candle in candles)
    ):
        return False
    timestamps = [candle["t"] for candle in candles]
    return all(left < right for left, right in zip(timestamps, timestamps[1:]))


def _market_kline_data(symbol: str, interval: str, rows: list[dict[str, str]]) -> dict:
    candles = [
        {
            "t": int(row["open_time"]) // 1000,
            "o": row["open"],
            "h": row["high"],
            "l": row["low"],
            "c": row["close"],
            "v": row["volume"],
        }
        for row in rows
    ]
    if not candles or not all(_market_kline_candle_valid(candle) for candle in candles):
        raise ValueError("invalid Kline response")
    return {"symbol": symbol, "interval": interval, "candles": candles}


def _market_kline_warm_entry(symbol: str, interval: str, limit: int) -> bool:
    try:
        rows = binance_get_historical_candles(to_inst_id(symbol), bar=interval, limit=limit)
        data = _market_kline_data(symbol, interval, rows)
        cache.set(
            _market_kline_cache_key(symbol, interval, limit),
            data,
            timeout=_market_kline_cache_ttl(interval),
        )
    except Exception:  # noqa: BLE001
        logger.warning("market klines warmup failed symbol=%s interval=%s", symbol, interval)
        return False
    return True


def warm_market_kline_caches() -> None:
    """scheduler 定时调用：常驻预热置顶币种默认周期，并续热最近被请求过的组合。"""
    now = time.time()
    hot = _market_kline_read_hot()
    for symbol in PINNED_TRADING_SYMBOLS:
        if symbol not in ALLOWED_TRADING_SYMBOLS:
            continue
        entry = hot.setdefault(
            _market_kline_hot_index_key(symbol, MARKET_KLINE_WARMUP_DEFAULT_INTERVAL, 300), {"warmed": 0.0}
        )
        entry["seen"] = now
    due = []
    for key, entry in list(hot.items()):
        parts = key.split("|")
        if len(parts) != 3:
            hot.pop(key, None)
            continue
        symbol, interval = parts[0], parts[1]
        try:
            limit = int(parts[2])
        except ValueError:
            hot.pop(key, None)
            continue
        if interval not in MARKET_KLINE_INTERVALS or symbol not in ALLOWED_TRADING_SYMBOLS:
            hot.pop(key, None)
            continue
        if now - _market_kline_timestamp(entry, "seen") > MARKET_KLINE_HOT_TTL:
            hot.pop(key, None)
            continue
        warmed_at = _market_kline_timestamp(entry, "warmed")
        if now - warmed_at < _market_kline_refresh_cadence(interval):
            continue
        due.append((warmed_at, key, symbol, interval, limit, entry))

    refreshed = 0
    for _, _, symbol, interval, limit, entry in sorted(due)[:MARKET_KLINE_WARM_BATCH_SIZE]:
        succeeded = _market_kline_warm_entry(symbol, interval, limit)
        entry["warmed"] = time.time()
        if succeeded:
            refreshed += 1

    # A web worker may mark another interval hot while this scheduler cycle is
    # fetching Binance. Merge its newer observation instead of overwriting the
    # whole shared index with the older snapshot read at the start of the cycle.
    latest_hot = _market_kline_read_hot()
    for key, latest_entry in latest_hot.items():
        parts = key.split("|")
        if len(parts) != 3 or parts[0] not in ALLOWED_TRADING_SYMBOLS or parts[1] not in MARKET_KLINE_INTERVALS:
            continue
        latest_seen = _market_kline_timestamp(latest_entry, "seen")
        if now - latest_seen > MARKET_KLINE_HOT_TTL:
            continue
        current = hot.setdefault(key, {"seen": latest_seen, "warmed": 0.0})
        current["seen"] = max(_market_kline_timestamp(current, "seen"), latest_seen)
        current["warmed"] = max(
            _market_kline_timestamp(current, "warmed"),
            _market_kline_timestamp(latest_entry, "warmed"),
        )
    while len(hot) > MARKET_KLINE_HOT_MAX:
        oldest = min(hot.items(), key=lambda item: _market_kline_timestamp(item[1], "seen"))[0]
        hot.pop(oldest, None)
    _market_kline_write_hot(hot)
    if refreshed:
        logger.info("market klines warmup refreshed=%s", refreshed)


def _market_klines_response(symbol: str, interval: str, limit: int, *, fresh: bool = False):
    if not symbol:
        return fail("symbol不能为空")
    if symbol not in ALLOWED_TRADING_SYMBOLS:
        return fail("不支持的交易对")
    if interval not in MARKET_KLINE_INTERVALS:
        return fail("不支持的K线周期")

    cache_key = _market_kline_cache_key(symbol, interval, limit)

    def fetch_snapshot():
        rows = binance_get_historical_candles(to_inst_id(symbol), bar=interval, limit=limit)
        return _market_kline_data(symbol, interval, rows)

    if fresh:
        try:
            data = fresh_snapshot(
                cache_key, fetch_snapshot,
                lambda value: _market_kline_snapshot_valid(value, symbol, interval),
            )
        except SnapshotBusy:
            response = fail("K线正在刷新，请稍后重试", code=503, status=503)
            response["Retry-After"] = "1"
            return response
        except Exception:  # noqa: BLE001
            logger.warning("fresh market snapshot failed symbol=%s interval=%s", symbol, interval)
            return fail("获取K线失败，请稍后重试", code=502, status=502)
        return ok(data=data)

    try:
        cached = cache.get(cache_key)
    except Exception:  # noqa: BLE001
        logger.warning("read market klines cache failed symbol=%s interval=%s", symbol, interval)
        cached = None
    if _market_kline_snapshot_valid(cached, symbol, interval):
        _market_kline_mark_hot(symbol, interval, limit)
        return ok(data=cached)
    if cached is not None:
        try:
            cache.delete(cache_key)
        except Exception:  # noqa: BLE001
            pass

    try:
        data = fetch_snapshot()
    except BinanceApiError as exc:
        return fail(safe_error_summary(exc, include_type=False), code=502, status=502)
    except ValueError:
        logger.warning("market klines returned invalid data symbol=%s interval=%s", symbol, interval)
        return fail("获取K线失败，请稍后重试", code=502, status=502)
    except Exception as exc:  # noqa: BLE001
        logger.error(
            "market klines fetch failed symbol=%s interval=%s err=%s",
            symbol,
            interval,
            safe_error_summary(exc),
        )
        return fail("获取K线失败，请稍后重试", code=502, status=502)

    try:
        cache.set(cache_key, data, timeout=_market_kline_cache_ttl(interval))
    except Exception:  # noqa: BLE001
        logger.warning("write market klines cache failed symbol=%s interval=%s", symbol, interval)
    _market_kline_mark_hot(symbol, interval, limit)
    return ok(data=data)


class MarketKlinesView(APIView):
    """Authenticated compatibility endpoint for Kline snapshots."""

    def get(self, request):
        symbol = (request.query_params.get("symbol") or "").strip().upper()
        interval = (request.query_params.get("interval") or "1m").strip().lower()
        try:
            limit = int(request.query_params.get("limit") or PUBLIC_MARKET_KLINE_LIMIT)
        except (TypeError, ValueError):
            limit = PUBLIC_MARKET_KLINE_LIMIT
        return _market_klines_response(
            symbol, interval, min(max(limit, 2), 1000),
            fresh=request.query_params.get("fresh") == "1",
        )


class PublicMarketKlinesView(APIView):
    """Anonymous fixed-size snapshot containing public market data only."""

    authentication_classes = []
    permission_classes = [AllowAny]

    def get(self, request, symbol: str, interval: str):
        return _market_klines_response(
            str(symbol).strip().upper(),
            str(interval).strip().lower(),
            PUBLIC_MARKET_KLINE_LIMIT,
        )


class MarketPricesView(APIView):
    """公开最新价代理：仅调用币安合约公开行情接口，不使用用户 API Key。

    全市场最新价一次拉取后按请求币种过滤，快照经共享缓存（3 秒）复用，
    多客户端高频轮询与持仓列表等内部路径都不会放大对币安公开接口的调用频率。
    """

    def get(self, request):
        raw = str(request.query_params.get("symbols") or "").strip().upper()
        if raw:
            symbols = sorted({part.strip() for part in raw.split(",") if part.strip()})[:50]
        else:
            symbols = sorted(ALLOWED_TRADING_SYMBOLS)
        if not symbols:
            return fail("symbols不能为空")
        invalid = [symbol for symbol in symbols if symbol not in ALLOWED_TRADING_SYMBOLS]
        if invalid:
            return fail("不支持的交易对")

        try:
            all_prices = binance_get_cached_last_prices()
        except BinanceApiError as exc:
            return fail(safe_error_summary(exc, include_type=False))
        except Exception as exc:  # noqa: BLE001
            logger.error("market prices fetch failed err=%s", safe_error_summary(exc))
            return fail("获取最新价失败，请稍后重试")

        prices = {
            symbol: all_prices[to_inst_id(symbol)]
            for symbol in symbols
            if to_inst_id(symbol) in all_prices
        }
        return ok(data={"prices": prices})


def _apply_api_key_scope(queryset, *, api_key_fingerprint: str, binding_created_at=None, trading_mode=TradingMode.ORDINARY):
    return scope_queryset_to_trading_account(
        queryset,
        api_key_fingerprint=api_key_fingerprint,
        binding_created_at=binding_created_at,
        trading_mode=trading_mode,
    )


def _perf_ms(start: float) -> int:
    return int((time.perf_counter() - start) * 1000)


def _invalidate_position_list_cache(user, api_key_fingerprint: str = "", *, trading_mode=TradingMode.ORDINARY) -> None:
    user_id = int(getattr(user, "id", user))
    fingerprint = api_key_fingerprint
    if not fingerprint and hasattr(user, "id"):
        fingerprint = get_user_api_key_fingerprint(user, trading_mode=trading_mode)
    invalidate_position_caches(
        build_trading_account_identity(
            user_id=user_id,
            api_key_fingerprint=fingerprint,
            trading_mode=trading_mode,
        ),
        legacy_user_id=user_id,
    )


def _check_tv_message_token(request):
    if not TV_MESSAGE_API_TOKEN:
        logger.error("tradingview ingest refused because TV_MESSAGE_API_TOKEN is not configured")
        return fail("TradingView 消息入口未配置访问凭证", code=503, status=503)
    supplied = request.headers.get("x-tv-message-token", "").strip()
    if not hmac.compare_digest(supplied, TV_MESSAGE_API_TOKEN):
        return fail("无效的消息访问凭证", code=403, status=403)
    return None


def _trim_tradingview_messages():
    """仅按时间保留：删除超过保留期的消息。"""
    expired_before = timezone.now() - timedelta(days=TV_MESSAGE_RETENTION_DAYS)
    TradingViewMessage.objects.filter(received_at__lt=expired_before).delete()


def purge_expired_tradingview_messages():
    """定时任务入口：清理超过保留期的 TradingView 消息。"""
    _trim_tradingview_messages()


def _log_trade_submit_failure(action: str, request, error: Exception, **context):
    logger.warning(
        "trade submit failed action=%s user_id=%s context=%s err=%s",
        action,
        getattr(request.user, "id", None),
        context,
        safe_error_summary(error),
    )


def _estimate_total_fee(open_price: Decimal, size: Decimal, ct_val_raw) -> Decimal:
    try:
        ct_val = Decimal(str(ct_val_raw or "0"))
    except (InvalidOperation, TypeError, ValueError):
        ct_val = Decimal("0")
    if ct_val <= 0 or open_price <= 0 or size <= 0:
        return Decimal("0")
    return (size * open_price * ct_val * TOTAL_FEE_RATE).quantize(Decimal("0.00000001"))


def _exchange_has_symbol_position(pos_rows: list[dict], inst_id: str) -> bool:
    for row in pos_rows:
        if str(row.get("instId") or "") != inst_id:
            continue
        try:
            pos = abs(Decimal(str(row.get("pos") or "0")))
        except Exception:
            pos = Decimal("0")
        if pos > 0:
            return True
    return False


def _pending_order_increases_risk(row: dict) -> bool:
    if row.get("reduceOnly") is True:
        return False
    side = str(row.get("side") or "").strip().lower()
    position_side = str(row.get("positionSide") or "").strip().upper()
    if position_side == "LONG" and side == "sell":
        return False
    if position_side == "SHORT" and side == "buy":
        return False
    return True


def _set_opening_leverage(
    client: BinanceFuturesClient,
    *,
    inst_id: str,
    leverage: int,
    pos_side: Optional[str],
) -> None:
    try:
        client.set_leverage(inst_id=inst_id, leverage=leverage, pos_side=pos_side)
    except BinanceApiError as exc:
        message = str(exc).strip().lower()
        already_effective = str(exc.code or "").strip() == "-4028" and any(
            hint in message
            for hint in ("already exist", "already set", "not modified", "no need to change")
        )
        if not already_effective:
            raise


def _close_local_order_after_exchange_manual_close(order: Order, client: BinanceFuturesClient) -> bool:
    if order.position_origin == Order.ORIGIN_EXTERNAL:
        # External discovery owns its lifecycle and releases its active slot.
        return False
    consecutive_absent = 0
    for delay in (0.0, 0.25):
        if delay:
            time.sleep(delay)
        try:
            pos_rows = client.get_positions(
                "SWAP",
                to_inst_id(order.symbol),
                budget_priority=RequestPriority.CRITICAL,
            ).get("data") or []
        except Exception:  # noqa: BLE001
            return False
        if _exchange_has_symbol_position(pos_rows, to_inst_id(order.symbol)):
            return False
        consecutive_absent += 1
    if consecutive_absent < 2:
        return False

    anchor = fetch_close_anchor(order, client, end_at=timezone.now(), limit=200)
    if not anchor or not anchor.get("is_fully_closed"):
        return False

    close_notification = infer_exchange_close_notification(
        order,
        client,
        close_price=anchor["close_price"],
        close_order_id=anchor["close_binance_order_id"],
    )
    order.status = 1
    order.closed_at = anchor["closed_at"]
    order.close_price = anchor["close_price"]
    order.close_binance_order_id = anchor["close_binance_order_id"]
    order.settlement_status = Order.SETTLEMENT_STATUS_PENDING
    order.settled_at = None
    order.settlement_error = ""
    order.exchange_size = Decimal("0")
    order.has_manual_addition = False
    if not persist_confirmed_close_transition(
        order,
        notification=close_notification,
        update_fields=[
            "status",
            "closed_at",
            "close_price",
            "close_binance_order_id",
            "settlement_status",
            "settled_at",
            "settlement_error",
            "exchange_size",
            "has_manual_addition",
        ],
    ):
        return False
    cleanup_result = best_effort_cleanup_closed_order_exchange_artifacts(
        order,
        client,
        action_prefix="duplicate_check_cleanup",
    )
    persist_closed_order_cleanup_result(order, cleanup_result)
    _invalidate_position_list_cache(order.user, order.api_key_fingerprint or "", trading_mode=order.trading_mode)
    return True


def check_duplicate_order(
    user,
    symbol: str,
    client: Optional[BinanceFuturesClient] = None,
    *,
    api_key_fingerprint: str = "",
    binding_created_at=None,
    exchange_activity: Optional[ExchangeActivitySnapshot] = None,
    trading_mode=TradingMode.ORDINARY,
) -> Optional[str]:
    """
    T022: 检查同一交易对是否已有活跃订单
    返回错误信息，无冲突返回 None
    """
    inst_id = to_inst_id(symbol)
    normalized_symbol = to_symbol(inst_id)

    # 本地记录仅作为交易所不可用时的保守兜底；客户端可用时，容量判断必须
    # 以交易所真实持仓和增加风险的普通挂单为准，避免过期本地记录误伤开仓。
    open_positions = _apply_api_key_scope(
        Order.objects.filter(user=user, status=0),
        api_key_fingerprint=api_key_fingerprint,
        binding_created_at=binding_created_at,
        trading_mode=trading_mode,
    ).count()
    pending_limits = _apply_api_key_scope(
        LimitOrder.objects.filter(user=user, status=LimitOrder.STATUS_PENDING),
        api_key_fingerprint=api_key_fingerprint,
        binding_created_at=binding_created_at,
        trading_mode=trading_mode,
    ).count()
    local_slot_count = open_positions + pending_limits
    if client is None and local_slot_count >= MAX_CONCURRENT_POSITIONS:
        return (
            f"同时持仓上限为 {MAX_CONCURRENT_POSITIONS} 个（当前持仓 {open_positions} 个、"
            f"待成交限价单 {pending_limits} 个），请先平仓或撤单后再开新单"
        )

    # 检查是否有活跃持仓
    open_qs = _apply_api_key_scope(
        Order.objects.filter(
            user=user,
            symbol=normalized_symbol,
            status=0,  # 持仓中
        ),
        api_key_fingerprint=api_key_fingerprint,
        binding_created_at=binding_created_at,
        trading_mode=trading_mode,
    )
    has_position = open_qs.exists()
    exchange_has_position = False
    if client is not None:
        try:
            activity = exchange_activity or load_exchange_activity(client)
            pos_rows = activity.positions
            pending_exchange_orders = [
                row
                for row in activity.regular_orders
                if isinstance(row, dict) and _pending_order_increases_risk(row)
            ]
            exchange_slot_count = len(pos_rows) + len(pending_exchange_orders)
            if exchange_slot_count >= MAX_CONCURRENT_POSITIONS:
                return (
                    f"同时持仓上限为 {MAX_CONCURRENT_POSITIONS} 个（交易所当前持仓及普通挂单共 "
                    f"{exchange_slot_count} 个），请先平仓或撤单后再开新单"
                )
            exchange_has_position = _exchange_has_symbol_position(pos_rows, inst_id)
            if has_position and not exchange_has_position:
                closed_count = 0
                for order in open_qs.order_by("-id"):
                    try:
                        if _close_local_order_after_exchange_manual_close(order, client):
                            closed_count += 1
                    except BinanceApiError as exc:
                        logger.warning(
                            "duplicate-check auto-close stale local order failed user=%s order=%s symbol=%s err=%s",
                            getattr(user, "id", None),
                            order.id,
                            normalized_symbol,
                            safe_error_summary(exc),
                        )
                    except Exception as exc:  # noqa: BLE001
                        logger.warning(
                            "duplicate-check auto-close stale local order unexpected user=%s order=%s symbol=%s err=%s",
                            getattr(user, "id", None),
                            order.id,
                            normalized_symbol,
                            safe_error_summary(exc),
                        )
                has_position = open_qs.exists()
                if closed_count:
                    logger.info(
                        "duplicate-check auto-closed stale local orders user=%s symbol=%s count=%s",
                        getattr(user, "id", None),
                        normalized_symbol,
                        closed_count,
                    )
                elif has_position:
                    logger.warning(
                        "duplicate-check local-open-without-exchange-position user=%s symbol=%s keep_local_open=1",
                        getattr(user, "id", None),
                        normalized_symbol,
                    )
        except BinanceApiError as exc:
            # 对账失败时保持保守，避免放开重复下单风险。
            logger.warning(
                "duplicate-check reconcile failed user=%s symbol=%s err=%s",
                getattr(user, "id", None),
                normalized_symbol,
                safe_error_summary(exc),
            )
            return "暂时无法确认交易所持仓状态，请稍后重试，避免重复开仓风险"
    if has_position:
        return f"您在 {normalized_symbol} 已有持仓，同一交易对仅允许1个订单"
    if exchange_has_position:
        return f"检测到您在 Binance 的 {normalized_symbol} 已有持仓，请先平仓后再开新单"

    # 检查是否有待成交的限价委托
    has_pending_limit = _apply_api_key_scope(
        LimitOrder.objects.filter(
            user=user,
            symbol=normalized_symbol,
            status=LimitOrder.STATUS_PENDING,
        ),
        api_key_fingerprint=api_key_fingerprint,
        binding_created_at=binding_created_at,
        trading_mode=trading_mode,
    ).exists()
    if has_pending_limit:
        return f"您在 {normalized_symbol} 已有待成交委托，同一交易对仅允许1个订单"

    return None


def _entry_capital_error(
    user,
    client: BinanceFuturesClient,
    activity: ExchangeActivitySnapshot,
    *,
    purpose: str,
    trading_mode=TradingMode.ORDINARY,
) -> Optional[str]:
    precheck = capital_precheck if trading_mode == TradingMode.ORDINARY else trading_adapter(trading_mode).capital_precheck
    state = precheck(
        user,
        client,
        purpose=purpose,
        activity_snapshot=activity,
    )
    status_value = state.get("status")
    if status_value in {"ready", "not_required"}:
        return None
    if state.get("message"):
        return state["message"]
    if status_value == "shortfall":
        shortfall = state.get("remaining_after_transfer") or state.get("shortfall") or "--"
        return f"账户总资金低于开仓下限，至少还需补充 {shortfall} USDT，请先在“我的”页面处理"
    if status_value == "normalization_required":
        if state.get("reason") == "futures_above_maximum":
            return "合约余额超过保留上限，请先在“我的”页面归集余额后再开仓"
        return "合约余额低于开仓下限，请先在币安将可用资金补入合约账户后再开仓"
    return "暂时无法确认账户资金是否满足开仓条件，请稍后重试"


def _strategy_levels_to_snapshot_config(strategy: Strategy) -> list[dict]:
    return [
        {
            "profitRR": float(level.profit_rr),
            "reducePosition": float(level.reduce_position),
            "stopLossType": level.stop_loss_type,
            "stopLossRR": float(level.stop_loss_rr) if level.stop_loss_rr is not None else None,
            "stopLossAbsoluteRR": (
                float(level.stop_loss_absolute_rr)
                if level.stop_loss_absolute_rr is not None
                else None
            ),
        }
        for level in strategy.levels.all().order_by("sort_order", "id")
    ]


def _resolve_strategy_snapshot_payload(user, strategy_id) -> Optional[dict]:
    if strategy_id in (None, ""):
        return None

    try:
        normalized_strategy_id = int(strategy_id)
    except (TypeError, ValueError):
        raise BinanceApiError("策略不存在或已被删除，请重新选择止盈策略")

    strategy = (
        Strategy.objects
        .filter(id=normalized_strategy_id, user=user)
        .prefetch_related("levels")
        .first()
    )
    if not strategy:
        raise BinanceApiError("策略不存在或已被删除，请重新选择止盈策略")

    strategy_config = _strategy_levels_to_snapshot_config(strategy)
    if not strategy_config:
        raise BinanceApiError("策略没有有效层级，请重新选择止盈策略")

    serializer = StrategySaveSerializer(data={"name": strategy.name, "levels": strategy_config})
    if not serializer.is_valid():
        first_error = next(iter(serializer.errors.values()), None)
        if isinstance(first_error, list) and first_error:
            raise BinanceApiError(str(first_error[0]))
        raise BinanceApiError("策略配置无效，请重新选择止盈策略")

    return {
        "strategy_id": str(strategy.id),
        "strategy_name": strategy.name,
        "strategy_config": strategy_config,
    }


def _validate_strategy_payload(strategy_id, strategy_name, strategy_config) -> Optional[str]:
    has_any_strategy = strategy_id is not None or strategy_name is not None or strategy_config is not None
    if not has_any_strategy:
        return None
    if not strategy_id:
        return "启用策略止盈时，strategy_id不能为空"
    return None


class TradeOpenSerializer(serializers.Serializer):
    leverage = serializers.IntegerField(required=False, min_value=1, max_value=1000)
    symbol = serializers.CharField(max_length=32)
    stop_loss_price = serializers.CharField(max_length=64)
    stop_loss_amount = serializers.CharField(max_length=64)
    include_fee = serializers.BooleanField()
    # Opaque legacy field: retain persisted request identity, never gate entry.
    ema_check_id = serializers.JSONField(required=False, allow_null=True)
    strategy_id = serializers.CharField(required=False, allow_blank=False, max_length=32)
    strategy_name = serializers.CharField(required=False, allow_blank=False, max_length=100)
    strategy_config = serializers.JSONField(required=False)
    client_request_id = serializers.UUIDField(required=False)
    # `maker` is deliberately opt-in; the legacy market path remains the
    # default until the caller explicitly selects post-only execution.
    execution_mode = serializers.ChoiceField(
        choices=["market", "maker"], required=False, default="market"
    )

    def validate_ema_check_id(self, value):
        # Preserve former CharField normalization for already persisted retries.
        if isinstance(value, (str, int, float)) and not isinstance(value, bool):
            return str(value).strip()
        return value

    def validate(self, attrs):
        err = _validate_strategy_payload(
            attrs.get("strategy_id"),
            attrs.get("strategy_name"),
            attrs.get("strategy_config"),
        )
        if err:
            raise serializers.ValidationError(err)
        return attrs


class CapitalNormalizeSerializer(serializers.Serializer):
    expected_status = serializers.ChoiceField(choices=["normalization_required", "collection_pending"])
    purpose = serializers.ChoiceField(choices=["entry", "manual_sweep"], default="entry")
    collection_id = serializers.IntegerField(min_value=1, required=False)
    expected_plan = serializers.CharField(max_length=64, required=False, default="", allow_blank=True)


class CapitalPrecheckSerializer(serializers.Serializer):
    purpose = serializers.ChoiceField(choices=["entry", "chase", "manual_sweep"], default="entry")


class CapitalPrecheckView(APIView):
    def post(self, request):
        serializer = CapitalPrecheckSerializer(data=request.data)
        if not serializer.is_valid():
            return fail("资金检查参数错误")
        credentials = get_user_binance_credentials(request.user, trading_mode=request_trading_mode(request))
        if not credentials:
            return fail("使用交易功能需先绑定 Binance Futures 实盘 API，是否立即前往绑定？")
        try:
            mode = request_trading_mode(request)
            precheck = capital_precheck if mode == TradingMode.ORDINARY else trading_adapter(mode).capital_precheck
            if mode == TradingMode.ORDINARY and serializer.validated_data["purpose"] == "manual_sweep":
                precheck = refresh_capital_precheck
            return ok(data=precheck(
                request.user,
                BinanceFuturesClient(credentials),
                purpose=serializer.validated_data["purpose"],
            ))
        except ValueError as exc:
            return fail(safe_error_summary(exc, include_type=False))
        except BinanceApiError as exc:
            return fail(safe_error_summary(exc, include_type=False))
        except Exception as exc:  # noqa: BLE001
            logger.error(
                "capital precheck failed user=%s err=%s",
                request.user.id,
                safe_error_summary(exc),
            )
            return fail("资金检查失败，请稍后重试")


class CapitalNormalizeView(APIView):
    def post(self, request):
        serializer = CapitalNormalizeSerializer(data=request.data)
        if not serializer.is_valid():
            return fail("资金规范化参数错误")
        credentials = get_user_binance_credentials(request.user, trading_mode=request_trading_mode(request))
        if not credentials:
            return fail("使用交易功能需先绑定 Binance Futures 实盘 API，是否立即前往绑定？")
        try:
            state = normalize_capital(
                request.user,
                BinanceFuturesClient(credentials),
                serializer.validated_data["expected_status"],
                purpose=serializer.validated_data["purpose"],
                collection_id=serializer.validated_data.get("collection_id"),
                expected_plan=serializer.validated_data["expected_plan"],
            )
            return ok(data=state, message="资金状态已重新检查")
        except ValueError as exc:
            return fail(safe_error_summary(exc, include_type=False))
        except BinanceApiError as exc:
            return fail(safe_error_summary(exc, include_type=False))
        except Exception as exc:  # noqa: BLE001
            logger.error(
                "capital normalization failed user=%s err=%s",
                request.user.id,
                safe_error_summary(exc),
            )
            return fail("资金规范化失败，请稍后重新检查")


class CapitalReminderView(APIView):
    def get(self, request):
        credentials = get_user_binance_credentials(request.user, trading_mode=request_trading_mode(request))
        if not credentials:
            return fail("使用交易功能需先绑定 Binance Futures 实盘 API，是否立即前往绑定？")
        try:
            return ok(data=capital_shortfall_reminder_preview(
                request.user, BinanceFuturesClient(credentials)
            ))
        except ValueError as exc:
            return fail(safe_error_summary(exc, include_type=False))
        except Exception as exc:  # noqa: BLE001
            logger.error(
                "capital reminder preview failed user=%s err=%s",
                request.user.id,
                safe_error_summary(exc),
            )
            return fail("补资提醒检查失败，请稍后重试")

    def post(self, request):
        credentials = get_user_binance_credentials(request.user, trading_mode=request_trading_mode(request))
        if not credentials:
            return fail("使用交易功能需先绑定 Binance Futures 实盘 API，是否立即前往绑定？")
        try:
            state = send_capital_shortfall_reminder(
                request.user, BinanceFuturesClient(credentials)
            )
            return ok(data=state, message="补资提醒已发送")
        except ValueError as exc:
            return fail(safe_error_summary(exc, include_type=False))
        except Exception as exc:  # noqa: BLE001
            logger.error(
                "capital reminder failed user=%s err=%s",
                request.user.id,
                safe_error_summary(exc),
            )
            return fail("补资提醒发送失败，请稍后重试")


class TradingViewMessageIngestSerializer(serializers.Serializer):
    raw_payload = serializers.JSONField()
    normalized_payload = serializers.JSONField()
    downstream_wecom_ok = serializers.BooleanField(default=False)
    downstream_telegram_ok = serializers.BooleanField(default=False)
    downstream_error = serializers.CharField(
        required=False,
        allow_blank=True,
        default="",
        max_length=1000,
    )

    def validate(self, attrs):
        encoded = json.dumps(attrs, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        if len(encoded) > 64 * 1024:
            raise serializers.ValidationError("消息内容不能超过 64 KB")
        return attrs


class TradingViewMessageAckSerializer(serializers.Serializer):
    ids = serializers.ListField(
        child=serializers.IntegerField(min_value=1),
        allow_empty=False,
        max_length=100,
    )


def _to_decimal(raw: str, name: str) -> Decimal:
    try:
        value = Decimal(str(raw))
    except (InvalidOperation, TypeError, ValueError):
        raise BinanceApiError(f"{name}格式错误")
    if value <= 0:
        raise BinanceApiError(f"{name}必须大于0")
    return value


def _extract_instrument(inst_id: str) -> dict:
    payload = binance_get_instruments(inst_type="SWAP", inst_id=inst_id)
    rows = payload.get("data") or []
    if not rows:
        raise BinanceApiError("未找到该交易对")
    return rows[0]


def _extract_ticker(inst_id: str) -> dict:
    payload = binance_get_ticker(inst_id)
    rows = payload.get("data") or []
    if not rows:
        raise BinanceApiError("未获取到交易对行情")
    return rows[0]


def _extract_book_ticker(client: BinanceFuturesClient, inst_id: str) -> dict:
    """Read the public best bid/ask immediately before a Maker submission."""
    payload = client.get_book_ticker(inst_id)
    rows = payload.get("data") or []
    if not rows:
        raise BinanceApiError("未获取到交易对盘口")
    return rows[0]


def _maker_entry_price(client, inst_id: str, instrument: dict, side: str) -> tuple[Decimal, Decimal]:
    """Return (post-only price, reference market price) from the live book.

    GTX rejects an order that would immediately take liquidity.  Moving one
    tick away from the best quote keeps the order on the maker side; a GTX
    rejection is still surfaced to the caller and is never silently retried.
    """
    book = _extract_book_ticker(client, inst_id)
    tick = _to_decimal(str(instrument.get("tickSz") or instrument.get("tickSize") or "0"), "价格精度")
    if tick <= 0:
        raise BinanceApiError("未获取到交易所价格精度")
    bid = _to_decimal(str(book.get("bidPx") or "0"), "盘口买价")
    ask = _to_decimal(str(book.get("askPx") or "0"), "盘口卖价")
    if bid <= 0 or ask <= 0:
        raise BinanceApiError("盘口价格暂不可用")
    if side == "buy":
        reference, raw = ask, bid - tick
    else:
        reference, raw = bid, ask + tick
    price = normalize_limit_price(raw, instrument, side)
    if price <= 0:
        raise BinanceApiError("Maker价格暂不可用")
    return price, reference


def _resolve_pos_side(
    client: BinanceFuturesClient,
    side_code: int,
    *,
    budget_priority: RequestPriority | str | None = None,
) -> Optional[str]:
    config_payload = client.get_account_config(budget_priority=budget_priority)
    config_rows = config_payload.get("data") or []
    pos_mode = str((config_rows[0] if config_rows else {}).get("posMode") or "long_short_mode")
    if pos_mode == "long_short_mode":
        return "long" if side_code == 0 else "short"
    return None


def _resolve_max_leverage(client: BinanceFuturesClient, inst_id: str, instrument: dict) -> int:
    try:
        payload = client.get_leverage_bracket(inst_id)
        rows = payload.get("data") or []
        if rows:
            value = int(float((rows[0] or {}).get("maxLever") or 1))
            if value > 0:
                return value
    except Exception as exc:
        if is_binance_rate_limit_error(exc) or is_binance_auth_or_permission_error(exc):
            raise
        pass
    fallback = int(float(instrument.get("lever") or instrument.get("maxLever") or 1))
    return fallback if fallback > 0 else 1


def _safe_request_payload_for_open(data: dict, *, client_order_id: str) -> dict:
    return {
        **({"leverage": data["leverage"]} if data.get("leverage") is not None else {}),
        "symbol": str(data.get("symbol") or ""),
        "stop_loss_price": str(data.get("stop_loss_price") or ""),
        "stop_loss_amount": str(data.get("stop_loss_amount") or ""),
        "include_fee": bool(data.get("include_fee")),
        "ema_check_id": str(data.get("ema_check_id") or ""),
        "strategy_id": str(data.get("strategy_id") or ""),
        "strategy_name": str(data.get("strategy_name") or ""),
        "strategy_config": data.get("strategy_config"),
        "client_order_id": client_order_id,
        "execution_mode": str(data.get("execution_mode") or "market"),
    }


def _safe_request_payload_for_limit(data: dict, *, client_order_id: str) -> dict:
    return {
        **({"leverage": data["leverage"]} if data.get("leverage") is not None else {}),
        "symbol": str(data.get("symbol") or ""),
        "limit_price": str(data.get("limit_price") or ""),
        "stop_loss_price": str(data.get("stop_loss_price") or ""),
        "stop_loss_amount": str(data.get("stop_loss_amount") or ""),
        "strategy_id": str(data.get("strategy_id") or ""),
        "strategy_name": str(data.get("strategy_name") or ""),
        "strategy_config": data.get("strategy_config"),
        "client_order_id": client_order_id,
    }


def _safe_request_payload_for_chase(limit_order: LimitOrder, *, client_order_id: str) -> dict:
    return {
        "limit_order_id": limit_order.id,
        "source_order_id": limit_order.binance_order_id,
        "symbol": limit_order.symbol,
        "stop_loss_price": str(limit_order.stop_loss_price),
        "stop_loss_amount": str(limit_order.stop_loss_amount),
        "strategy_id": limit_order.strategy_id,
        "client_order_id": client_order_id,
    }


def _adopt_confirmed_limit_fill(
    *,
    request_user,
    client: BinanceFuturesClient,
    limit_order: LimitOrder,
    execution,
    api_key_fingerprint: str,
):
    if defer_incomplete_limit_execution(limit_order, execution):
        raise BinanceApiError("限价委托成交信息尚未确认，等待完整成交快照")
    confirmed_fill_size = max(execution.filled_size, limit_order.filled_size)
    adoption = adopt_entry_execution(
        user=request_user,
        trading_mode=limit_order.trading_mode,
        client=client,
        binance_order_id=limit_order.binance_order_id,
        symbol=limit_order.symbol,
        side=limit_order.side,
        fill_size=confirmed_fill_size,
        average_price=execution.average_price,
        stop_loss_price=limit_order.stop_loss_price,
        stop_loss_amount=limit_order.stop_loss_amount,
        leverage=limit_order.leverage,
        api_key_fingerprint=api_key_fingerprint,
        strategy_id=limit_order.strategy_id,
        strategy_name=limit_order.strategy_name,
        strategy_config=limit_order.strategy_config,
        limit_order=limit_order,
        source_label="限价成交",
    )
    limit_order.filled_size = confirmed_fill_size
    limit_order.order = adoption.order
    if execution.state == "filled":
        limit_order.status = LimitOrder.STATUS_FILLED
    limit_order.save(update_fields=["filled_size", "order", "status", "updated_at"])
    return adoption


def _ensure_available_margin(client: BinanceFuturesClient, *, size: str, entry_price: Decimal, instrument: dict, leverage: int) -> None:
    ct_val = Decimal(str(instrument.get("ctVal") or "1"))
    notional = Decimal(str(size)) * ct_val * entry_price
    required = (notional / Decimal(max(1, leverage))) * Decimal("1.05")
    rows = client.get_balance("USDT").get("data") or []
    available = Decimal("0")
    if not isinstance(rows, list):
        logger.warning("margin preflight returned malformed response; skip order=%s", type(rows).__name__)
        return
    if rows:
        available = Decimal(str(((rows[0].get("details") or [{}])[0]).get("availEq") or "0"))
    if available < required:
        raise BinanceApiError(f"可用保证金不足：需要约 {required:.2f} USDT，当前可用 {available:.2f} USDT")


def _ensure_notional_within_cap(
    client: BinanceFuturesClient, *, inst_id: str, size, entry_price: Decimal, instrument: dict
) -> None:
    """开仓前预检名义价值是否超过币安该交易对的持仓上限（杠杆档位 notionalCap），
    提前给出可操作的中文提示，避免把交易所英文报错直接抛给用户"""
    try:
        notional = Decimal(str(size)) * Decimal(str(instrument.get("ctVal") or "1")) * entry_price
    except Exception:
        return
    try:
        rows = client.get_leverage_bracket(inst_id).get("data") or []
    except Exception as exc:
        if is_binance_rate_limit_error(exc) or is_binance_auth_or_permission_error(exc):
            raise
        rows = []
    if not rows:
        return
    try:
        cap = Decimal(str((rows[0] or {}).get("notionalCap") or "0"))
    except (InvalidOperation, TypeError, ValueError):
        logger.warning("leverage bracket returned invalid notional cap; skip preflight inst_id=%s", inst_id)
        return
    if cap > 0 and notional > cap:
        raise BinanceApiError(
            f"开仓被拒绝：本单名义价值约 {notional:.0f} USDT，"
            f"超过币安该交易对最大持仓上限 {cap:.0f} USDT。"
            "请减小止损额或放宽止损价后重试"
        )


def _translate_exchange_message(message: str) -> str:
    """将常见币安英文报错翻译为可操作的中文提示"""
    text = safe_error_summary(message, include_type=False)
    if "Exceeded the maximum allowable position" in text:
        return "持仓数量超过币安该交易对当前杠杆下的最大持仓限制，请减小止损额或放宽止损价后重试"
    return text


def _is_stop_price_crossed(side_code: int, stop_loss_price: Decimal, current_price: Decimal) -> bool:
    if current_price <= 0:
        return False
    if side_code == 0:  # long
        return current_price <= stop_loss_price
    return current_price >= stop_loss_price  # short


def _should_emergency_close_after_stop_loss_fail(
    inst_id: str,
    side_code: int,
    stop_loss_price: Decimal,
    error: Exception,
) -> bool:
    current_price = Decimal("0")
    try:
        ticker = _extract_ticker(inst_id)
        current_price = _to_decimal(str(ticker.get("last") or "0"), "行情价格")
    except Exception:
        return False
    if _is_stop_price_crossed(side_code, stop_loss_price, current_price):
        return True
    # Trigger-price invalid without crossing confirmation is not enough to auto-close.
    return False


def _has_unresolved_stop_protection(
    user,
    *,
    api_key_fingerprint: str,
    binding_created_at=None,
    trading_mode=TradingMode.ORDINARY,
) -> bool:
    queryset = Order.objects.filter(
        user=user,
        status=0,
        stop_protection_status__in=[
            Order.STOP_PROTECTION_PENDING,
            Order.STOP_PROTECTION_ALERTED,
            Order.STOP_PROTECTION_EMERGENCY,
        ],
    )
    return _apply_api_key_scope(
        queryset,
        api_key_fingerprint=api_key_fingerprint,
        binding_created_at=binding_created_at,
        trading_mode=trading_mode,
    ).exists()


def _decimal_or_zero(raw) -> Decimal:
    try:
        return Decimal(str(raw))
    except (InvalidOperation, TypeError, ValueError):
        return Decimal("0")


def _emergency_close_position(
    client: BinanceFuturesClient,
    inst_id: str,
    side_code: int,
) -> tuple[bool, Optional[dict]]:
    close_error = None
    close_payload = None
    try:
        pos_side = _resolve_pos_side(
            client,
            side_code,
            budget_priority=RequestPriority.CRITICAL,
        )
        close_payload = client.close_position(
            inst_id=inst_id,
            pos_side=pos_side,
            expected_side="long" if side_code == 0 else "short",
        )
    except Exception as exc:  # noqa: BLE001
        close_error = exc

    try:
        expected_side = "long" if side_code == 0 else "short"
        consecutive_absent = 0
        for wait_sec in (0, 0.5, 1):
            if wait_sec:
                time.sleep(wait_sec)
            rows = client.get_positions(
                "SWAP",
                inst_id,
                budget_priority=RequestPriority.CRITICAL,
            ).get("data") or []
            still_open = any(
                str((row or {}).get("instId") or "") == inst_id
                and str((row or {}).get("posSide") or "") == expected_side
                and abs(_decimal_or_zero((row or {}).get("pos") or "0")) > 0
                for row in rows
            )
            if not still_open:
                consecutive_absent += 1
                if consecutive_absent >= 2:
                    return True, close_payload
            else:
                consecutive_absent = 0
        logger.error(
            "emergency close not confirmed inst_id=%s side=%s err=%s",
            inst_id,
            expected_side,
            safe_error_summary(close_error or "position still open", include_type=False),
        )
        return False, close_payload
    except Exception as exc:
        logger.error(
            "emergency close failed inst_id=%s side_code=%s err=%s",
            inst_id,
            side_code,
            safe_error_summary(exc),
        )
        return False, close_payload


def _resolve_entry_stop_protection(
    *,
    order: Order,
    client: BinanceFuturesClient,
    inst_id: str,
    side_code: int,
    stop_loss_price: Decimal,
    stop_loss_error: Optional[Exception],
    action_label: str,
    pending_message: str,
) -> tuple[str, Optional[str]]:
    """Return the success message and an optional terminal response error."""
    if order.binance_stop_market_order_id:
        return pending_message, None
    if stop_loss_error is not None and _should_emergency_close_after_stop_loss_fail(
        inst_id=inst_id,
        side_code=side_code,
        stop_loss_price=stop_loss_price,
        error=stop_loss_error,
    ):
        close_confirmed, close_payload = _emergency_close_position(client, inst_id, side_code)
        if close_confirmed:
            _mark_order_closed_after_emergency(order, client, close_payload=close_payload)
            return pending_message, (
                f"{action_label}后止损未成功挂单且价格已触及止损区间，"
                "系统已自动平仓保护，请稍后重试"
            )
        order.stop_protection_status = Order.STOP_PROTECTION_EMERGENCY
        order.stop_protection_error = "止损触价且紧急平仓未确认，请立即手动处理仓位"
        order.save(update_fields=["stop_protection_status", "stop_protection_error"])
        return pending_message, (
            f"{action_label}后止损未成功挂单且价格已触及止损区间，"
            "紧急平仓失败，请立即手动处理仓位"
        )
    return pending_message, None


class SymbolListView(APIView):
    CACHE_KEY = "trade:symbols:top100"
    CACHE_TTL = 60

    def _load_market_cap_rank(self) -> dict[str, int]:
        cache_key = "trade:market-cap-rank:cg"
        cached = cache.get(cache_key)
        if cached is not None:
            return cached

        rank_map: dict[str, int] = {}
        url = (
            "https://api.coingecko.com/api/v3/coins/markets?"
            "vs_currency=usd&order=market_cap_desc&per_page=250&page=1&sparkline=false"
        )
        req = request.Request(url=url, headers={"User-Agent": "riskon-server/1.0"}, method="GET")
        try:
            with request.urlopen(req, timeout=8) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
                for idx, item in enumerate(payload):
                    symbol = str(item.get("symbol") or "").upper()
                    if symbol and symbol not in rank_map:
                        rank_map[symbol] = idx + 1
        except Exception:
            rank_map = {}

        cache.set(cache_key, rank_map, timeout=300)
        return rank_map

    def get(self, request):
        mode = request_trading_mode(request)
        if mode == TradingMode.LEAD:
            credentials = get_user_binance_credentials(request.user, trading_mode=mode)
            if not credentials:
                return ok(data=[])
            try:
                return ok(data=trading_adapter(mode).filter_symbols(BinanceFuturesClient(credentials), list(ALLOWED_TRADING_SYMBOLS)))
            except BinanceApiError as exc:
                return fail(safe_error_summary(exc, include_type=False))
        total_started = time.perf_counter()
        cached = cache.get(self.CACHE_KEY)
        if cached is not None:
            logger.info(
                "perf trade_symbols user=%s total_ms=%s cache_hit=1 count=%s",
                getattr(request.user, "id", None),
                _perf_ms(total_started),
                len(cached),
            )
            return ok(data=cached)

        exchange_ms = 0
        rank_ms = 0
        symbols = list(ALLOWED_TRADING_SYMBOLS)

        cache.set(self.CACHE_KEY, symbols, timeout=self.CACHE_TTL)
        logger.info(
            "perf trade_symbols user=%s total_ms=%s exchange_ms=%s rank_ms=%s cache_hit=0 count=%s",
            getattr(request.user, "id", None),
            _perf_ms(total_started),
            exchange_ms,
            rank_ms,
            len(symbols),
        )
        return ok(data=symbols)


class SymbolInfoView(APIView):
    CACHE_TTL = 1

    def get(self, request):
        total_started = time.perf_counter()
        symbol = request.query_params.get("symbol")
        if not symbol:
            return fail("symbol不能为空")

        cache_key = f"trade:symbol-info:{symbol}"
        cached = cache.get(cache_key)
        if cached is not None:
            logger.info(
                "perf symbol_info user=%s total_ms=%s cache_hit=1 symbol=%s",
                getattr(request.user, "id", None),
                _perf_ms(total_started),
                symbol,
            )
            return ok(data=cached)

        exchange_started = time.perf_counter()
        try:
            inst_id = to_inst_id(symbol)
            ticker = _extract_ticker(inst_id)
            instrument = _extract_instrument(inst_id)
            max_leverage = int(float(instrument.get("lever") or instrument.get("maxLever") or 1))
            data = {
                "symbol": to_symbol(inst_id),
                "current_price": str(ticker.get("last") or "0"),
                "max_leverage": max_leverage,
            }
        except BinanceApiError as exc:
            return fail(safe_error_summary(exc, include_type=False))
        except Exception:
            return fail("获取交易对信息失败，请稍后重试")

        cache.set(cache_key, data, timeout=self.CACHE_TTL)
        logger.info(
            "perf symbol_info user=%s total_ms=%s exchange_ms=%s cache_hit=0 symbol=%s",
            getattr(request.user, "id", None),
            _perf_ms(total_started),
            _perf_ms(exchange_started),
            symbol,
        )
        return ok(data=data)


class TradeOpenView(APIView):
    def post(self, request):
        data = None
        normalized_symbol = None
        stop_loss_price = None
        stop_loss_amount = None
        entry_price = None
        open_side = None
        size = None
        execution_mode = "market"
        maker_price = None
        maker_market_price = None
        open_request = None
        account = get_user_trading_account(request.user, active_only=True, trading_mode=request_trading_mode(request))
        if not account:
            return fail("使用交易功能需先绑定 Binance Futures 实盘 API，是否立即前往绑定？")
        api_key_fingerprint = account.api_key_fingerprint
        binding_created_at = account.binding_created_at

        serializer = TradeOpenSerializer(data=request.data)
        if not serializer.is_valid():
            errors = serializer.errors
            first_key = next(iter(errors.keys()), None)
            if first_key and errors[first_key]:
                return fail(str(errors[first_key][0]))
            return fail("请求参数错误")

        data = serializer.validated_data
        execution_mode = str(data.get("execution_mode") or "market")
        try:
            inst_id = to_inst_id(data["symbol"])
            normalized_symbol = to_symbol(inst_id)

            with entry_submission_guard(
                request.user,
                account,
                action="open",
                symbol=normalized_symbol,
            ) as guard:
                if not guard.allowed:
                    return fail(guard.error)
                if _has_unresolved_stop_protection(
                    request.user,
                    api_key_fingerprint=api_key_fingerprint,
                    binding_created_at=binding_created_at,
                    trading_mode=request_trading_mode(request),
                ):
                    return fail("已有持仓的止损保护正在恢复，请等待保护完成后再开仓")

                raw_client_request_id = str(data.get("client_request_id") or uuid4())
                client_order_id = _idempotent_client_order_id(
                    "mo", account.identity, normalized_symbol, raw_client_request_id
                )
                expected_request_payload = _safe_request_payload_for_open(data, client_order_id=client_order_id)
                try:
                    request_resolution = resolve_open_request(
                        user=request.user,
                        trading_mode=request_trading_mode(request),
                        symbol=normalized_symbol,
                        client_request_id=raw_client_request_id,
                        client_order_id=client_order_id,
                        request_payload=expected_request_payload,
                        api_key_fingerprint=api_key_fingerprint,
                    )
                except OpenRequestPayloadConflict as exc:
                    return fail(safe_error_summary(exc, include_type=False), code=409, status=409)
                open_request = request_resolution.request
                created_open_request = request_resolution.created
                existing_order = _find_existing_order_by_open_request(open_request)
                if existing_order:
                    enqueue_open_notification(existing_order)
                    return ok(message="开仓请求已处理", data={"position_id": existing_order.id})

                client = BinanceFuturesClient(account.credentials)
                recovered_open_row = None
                if not created_open_request:
                    recovered_open_row = _load_exchange_order_by_client_order_id(
                        client,
                        inst_id=inst_id,
                        client_order_id=client_order_id,
                    )
                    if recovered_open_row:
                        mark_open_request_recovered(
                            open_request,
                            str(recovered_open_row.get("ordId") or ""),
                        )
                if not recovered_open_row:
                    activity = load_exchange_activity(client)
                    # T022: 多单限制校验
                    dup_error = check_duplicate_order(
                        request.user,
                        data["symbol"],
                        client=client,
                        api_key_fingerprint=api_key_fingerprint,
                        binding_created_at=binding_created_at,
                        trading_mode=request_trading_mode(request),
                        exchange_activity=activity,
                    )
                    if dup_error:
                        return fail(dup_error)
                    capital_error = _entry_capital_error(
                        request.user,
                        client,
                        activity,
                        purpose="entry",
                        trading_mode=request_trading_mode(request),
                    )
                    if capital_error:
                        return fail(capital_error)

                instrument = _extract_instrument(inst_id)
                raw_stop_loss_price = _to_decimal(data["stop_loss_price"], "止损价")
                stop_loss_amount = _to_decimal(data["stop_loss_amount"], "止损金额")
                try:
                    strategy_payload = _resolve_strategy_snapshot_payload(request.user, data.get("strategy_id"))
                except BinanceApiError as exc:
                    if not recovered_open_row:
                        raise
                    logger.warning(
                        "recover open request without strategy user=%s symbol=%s client_order_id=%s err=%s",
                        request.user.id,
                        normalized_symbol,
                        client_order_id,
                        safe_error_summary(exc),
                    )
                    strategy_payload = None

                if recovered_open_row:
                    recovered_side = str(recovered_open_row.get("side") or "").strip().lower()
                    recovered_size = _decimal_or_zero(recovered_open_row.get("sz") or "0")
                    if recovered_side not in {"buy", "sell"} or recovered_size <= 0:
                        raise BinanceApiError(
                            "已提交开仓订单的方向或数量无法确认，请稍后重试",
                            outcome_unknown=True,
                        )

                    execution_intent = get_open_request_execution_intent(open_request)
                    intended_side = str(execution_intent.get("open_side") or "").strip().lower()
                    intended_size = _decimal_or_zero(execution_intent.get("size") or "0")
                    if execution_intent and (
                        intended_side != recovered_side
                        or intended_size <= 0
                        or abs(intended_size - recovered_size) > Decimal("0.00000001")
                    ):
                        raise BinanceApiError(
                            "已提交开仓订单与原请求不一致，已停止自动接管",
                            outcome_unknown=True,
                        )

                    entry_price = _decimal_or_zero(recovered_open_row.get("avgPx") or "0")
                    if execution_intent:
                        open_side = intended_side
                        side_code = int(execution_intent["side_code"])
                        size = str(execution_intent["size"])
                        stop_loss_price = _to_decimal(
                            execution_intent["stop_loss_price"],
                            "止损价",
                        )
                        max_leverage = int(execution_intent["leverage"])
                        use_pos_side = str(execution_intent.get("pos_side") or "").strip() or None
                    else:
                        open_side = recovered_side
                        side_code = 0 if recovered_side == "buy" else 1
                        size = format(recovered_size, "f")
                        stop_loss_price = normalize_stop_trigger_price(
                            raw_stop_loss_price,
                            instrument,
                            "long" if side_code == 0 else "short",
                        )
                        max_leverage = _resolve_max_leverage(client, inst_id, instrument)
                        use_pos_side = None
                else:
                    ticker = _extract_ticker(inst_id)
                    entry_price = _to_decimal(str(ticker.get("last") or "0"), "行情价格")
                    if entry_price == raw_stop_loss_price:
                        raise BinanceApiError("止损价不能等于当前价格")
                    standardized_open = standardize_open_order_request(
                        entry_price=entry_price,
                        stop_loss_price=raw_stop_loss_price,
                        stop_loss_amount=stop_loss_amount,
                        instrument=instrument,
                        order_type="market",
                    )
                    stop_loss_price = standardized_open["stop_loss_price"]
                    open_side = standardized_open["open_side"]
                    side_code = standardized_open["side_code"]
                    size = standardized_open["size"]

                    if execution_mode == "maker":
                        # Price Maker from the live best quote, then move one
                        # tick away so GTX remains post-only.  The reference
                        # quote is displayed to the user but never used as a
                        # substitute for an exchange-confirmed fill.
                        maker_price, maker_market_price = _maker_entry_price(
                            client, inst_id, instrument, open_side
                        )

                    if data["include_fee"]:
                        effective_ratio = abs(entry_price - stop_loss_price) / entry_price + Decimal("0.001")
                        size = calc_contract_size(
                            entry_price=str(entry_price),
                            notional_usdt=str(stop_loss_amount / effective_ratio),
                            ct_val=str(instrument.get("ctVal") or "0"),
                            lot_sz=str(instrument.get("marketLotSz") or instrument.get("lotSz") or "1"),
                            min_sz=str(instrument.get("marketMinSz") or instrument.get("minSz") or "0"),
                            min_notional=str(instrument.get("minNotional") or "0"),
                        )

                    if data.get("leverage") is None:
                        _ensure_notional_within_cap(
                            client, inst_id=inst_id, size=size, entry_price=entry_price, instrument=instrument
                        )
                    use_pos_side = _resolve_pos_side(client, side_code)
                    if data.get("leverage") is not None:
                        from trading.leverage_views import opening_leverage
                        max_leverage = opening_leverage(client, inst_id, data['leverage'],
                            size=size, entry_price=entry_price, instrument=instrument)
                    else:
                        max_leverage = _resolve_max_leverage(client, inst_id, instrument)
                    _ensure_available_margin(client, size=size, entry_price=entry_price, instrument=instrument, leverage=max_leverage)

                    _set_opening_leverage(
                        client,
                        inst_id=inst_id,
                        leverage=max_leverage,
                        pos_side=use_pos_side,
                    )
                    record_open_request_execution_intent(
                        open_request,
                        {
                            "entry_price": format(entry_price, "f"),
                            "stop_loss_price": format(stop_loss_price, "f"),
                            "stop_loss_amount": format(stop_loss_amount, "f"),
                            "open_side": open_side,
                            "side_code": side_code,
                            "size": str(size),
                            "leverage": max_leverage,
                            "pos_side": use_pos_side or "",
                            "execution_mode": execution_mode,
                            "maker_price": format(maker_price, "f") if maker_price is not None else "",
                            "maker_market_price": format(maker_market_price, "f") if maker_market_price is not None else "",
                            # Freeze the strategy snapshot so later status or
                            # fallback calls cannot silently change risk rules.
                            "strategy_id": str(strategy_payload["strategy_id"] if strategy_payload else ""),
                            "strategy_name": str(strategy_payload["strategy_name"] if strategy_payload else ""),
                            "strategy_config": strategy_payload["strategy_config"] if strategy_payload else None,
                        },
                    )

                is_maker = execution_mode == "maker" or get_open_request_execution_intent(open_request).get("execution_mode") == "maker"
                persisted_intent = get_open_request_execution_intent(open_request)
                if is_maker and maker_price is None:
                    maker_price = _to_decimal(persisted_intent.get("maker_price"), "Maker价格")
                    maker_market_price = _to_decimal(persisted_intent.get("maker_market_price"), "市价")
                submission = submit_or_recover_exchange_order(
                    client=client,
                    open_request=open_request,
                    inst_id=inst_id,
                    client_order_id=client_order_id,
                    recovered_row=recovered_open_row,
                    submit=(
                        (lambda: client.place_limit_order(
                            inst_id=inst_id,
                            side=open_side,
                            size=size,
                            price=str(maker_price),
                            pos_side=use_pos_side,
                            new_client_order_id=client_order_id,
                            # GTX means post-only.  A -5022 rejection is
                            # explicit failure; do not convert it to market.
                            time_in_force="GTX",
                        ))
                        if is_maker
                        else (lambda: client.place_market_order(
                            inst_id=inst_id,
                            side=open_side,
                            size=size,
                            pos_side=use_pos_side,
                            new_client_order_id=client_order_id,
                        ))
                    ),
                )
                if not submission.confirmed:
                    return fail(
                        "开仓提交结果未确认；请保留当前页面并重试，系统会按原请求恢复",
                        code=409,
                        status=409,
                    )
                requested_size = _to_decimal(size, "开仓数量")
                open_row = require_exchange_order_row(submission.payload, action_label="开仓")
                binance_order_id = str(open_row["ordId"])
                duplicate_order = Order.objects.filter(
                    api_key_fingerprint=api_key_fingerprint,
                    binance_order_id=binance_order_id,
                    symbol=to_symbol(inst_id),
                    user=request.user,
                    trading_mode=request_trading_mode(request),
                ).first()
                if duplicate_order:
                    mark_open_request_submitted(
                        open_request,
                        exchange_order_id=binance_order_id,
                        order_id=duplicate_order.id,
                        preserve_recovered=False,
                    )
                    enqueue_open_notification(duplicate_order)
                    return ok(message="开仓请求已处理", data={"position_id": duplicate_order.id})
                mark_open_request_submitted(open_request, exchange_order_id=binance_order_id)
                execution = confirm_entry_execution(
                    client,
                    inst_id=inst_id,
                    order_id=binance_order_id,
                    requested_size=requested_size,
                    initial_row=open_row,
                    retry_delays=() if is_maker else (0, 1, 1, 2, 2, 2),
                )
                if not execution.has_fill:
                    if is_maker and execution.state == "pending":
                        # NEW/LIVE is a valid Maker waiting state, not a
                        # failed open.  The mobile client polls maker-status.
                        record_open_request_uncertain(
                            open_request,
                            f"maker_pending:{execution.raw_state}",
                        )
                        return ok(
                            message="Maker订单等待成交",
                            data={
                                "state": "PENDING_MAKER",
                                "maker_order_id": binance_order_id,
                                "maker_price": format(maker_price or 0, "f"),
                                "market_price": format(maker_market_price or entry_price, "f"),
                                "symbol": normalized_symbol,
                                "client_request_id": str(open_request.client_request_id),
                            },
                        )
                    record_open_request_uncertain(
                        open_request,
                        f"exchange_execution_{execution.state}:{execution.raw_state}",
                    )
                    return fail(
                        "开仓请求已提交，但交易所尚未确认成交；请保留当前页面并重试，系统会按原请求恢复",
                        code=409,
                        status=409,
                    )
                confirmed_size = execution.filled_size
                confirmed_avg_px = execution.average_price
                is_partial_fill = execution.state == PARTIALLY_FILLED

                strategy_id = strategy_payload["strategy_id"] if strategy_payload else None
                strategy_name = strategy_payload["strategy_name"] if strategy_payload else None
                strategy_config = strategy_payload["strategy_config"] if strategy_payload else None
                adoption = adopt_entry_execution(
                    user=request.user,
                    trading_mode=request_trading_mode(request),
                    client=client,
                    binance_order_id=binance_order_id,
                    symbol=normalized_symbol,
                    side=side_code,
                    fill_size=confirmed_size,
                    average_price=confirmed_avg_px,
                    stop_loss_price=stop_loss_price,
                    stop_loss_amount=stop_loss_amount,
                    leverage=max_leverage,
                    api_key_fingerprint=api_key_fingerprint or None,
                    strategy_id=str(strategy_id or ""),
                    strategy_name=str(strategy_name or ""),
                    strategy_config=strategy_config,
                    estimated_total_fee=_estimate_total_fee(confirmed_avg_px, confirmed_size, instrument.get("ctVal")),
                    pos_mode="long_short_mode" if use_pos_side else "net_mode",
                    source_label="开仓",
                )
                order = adoption.order
                stop_loss_error = adoption.stop_loss_error
                stop_market_order_id = order.binance_stop_market_order_id
                attach_open_request_order(open_request, order.id)

                message = "开仓成功"
                if is_partial_fill:
                    message = "开仓部分成交，已按实际成交仓位挂止损"
                if not stop_market_order_id:
                    message, protection_error = _resolve_entry_stop_protection(
                        order=order,
                        client=client,
                        inst_id=inst_id,
                        side_code=side_code,
                        stop_loss_price=stop_loss_price,
                        stop_loss_error=stop_loss_error,
                        action_label="开仓",
                        pending_message="开仓已成交，止损保护正在后台重试；恢复前不可继续开仓",
                    )
                    if protection_error:
                        return fail(protection_error)
                elif order.strategy_snapshot_id and order.strategy_status == Order.STRATEGY_STATUS_CANCELLED:
                    message = "开仓成功，但策略止盈预挂失败，已转为手动止盈"
                _invalidate_position_list_cache(request.user, api_key_fingerprint, trading_mode=request_trading_mode(request))
                return ok(
                    message=message,
                    data={"position_id": order.id, "stop_protection_status": order.stop_protection_status},
                )
        except BinanceApiError as exc:
            exchange_order_submitted = _record_open_request_error(open_request, exc)
            _log_trade_submit_failure(
                "market-open",
                request,
                exc,
                symbol=normalized_symbol or ((data or {}).get("symbol") if isinstance(data, dict) else None),
                stop_loss_price=str(stop_loss_price) if stop_loss_price is not None else None,
                stop_loss_amount=str(stop_loss_amount) if stop_loss_amount is not None else None,
                entry_price=str(entry_price) if entry_price is not None else None,
                open_side=open_side,
                requested_size=size,
                include_fee=(data or {}).get("include_fee") if isinstance(data, dict) else None,
            )
            if exchange_order_submitted:
                return fail(
                    "开仓已提交，但本地状态尚未确认；请保留当前页面并重试，系统会按原请求恢复",
                    code=409,
                    status=409,
                )
            return fail(_translate_exchange_message(str(exc)))
        except Exception as exc:
            exchange_order_submitted = _record_open_request_error(open_request, exc)
            _log_trade_submit_failure(
                "market-open",
                request,
                exc,
                symbol=normalized_symbol or (data or {}).get("symbol"),
                stop_loss_price=str(stop_loss_price) if stop_loss_price is not None else None,
                stop_loss_amount=str(stop_loss_amount) if stop_loss_amount is not None else None,
                entry_price=str(entry_price) if entry_price is not None else None,
                open_side=open_side,
                requested_size=size,
                include_fee=(data or {}).get("include_fee"),
            )
            if exchange_order_submitted:
                return fail(
                    "开仓已提交，但本地状态尚未确认；请保留当前页面并重试，系统会按原请求恢复",
                    code=409,
                    status=409,
                )
            return fail("开仓失败，请稍后重试")


def _maker_request_for_user(request, client_request_id):
    """Resolve a Maker request inside the authenticated account scope."""
    mode = request_trading_mode(request)
    row = TradeOpenRequest.objects.filter(
        user=request.user,
        trading_mode=mode,
        client_request_id=str(client_request_id or ""),
    ).first()
    if row is None:
        raise BinanceApiError("Maker订单不存在")
    account = get_user_trading_account(request.user, active_only=True, trading_mode=mode)
    if not account or row.api_key_fingerprint != account.api_key_fingerprint:
        raise BinanceApiError("API绑定已变化，拒绝操作原Maker订单")
    intent = get_open_request_execution_intent(row)
    if intent.get("execution_mode") != "maker":
        raise BinanceApiError("该开仓请求不是Maker订单")
    return account, row, intent


def _adopt_maker_fill(request, account, open_request, intent, client, execution, *, instrument=None):
    """Adopt confirmed Maker fills and install the same stop protection path."""
    if not execution.has_fill:
        return None
    mode = request_trading_mode(request)
    symbol = to_symbol(open_request.symbol)
    inst_id = to_inst_id(symbol)
    instrument = instrument or _extract_instrument(inst_id)
    side_code = int(intent["side_code"])
    stop_loss_price = _to_decimal(intent["stop_loss_price"], "止损价")
    stop_loss_amount = _to_decimal(intent["stop_loss_amount"], "止损金额")
    strategy_id = str(intent.get("strategy_id") or "")
    strategy_name = str(intent.get("strategy_name") or "")
    strategy_config = intent.get("strategy_config")
    adoption = adopt_entry_execution(
        user=request.user,
        trading_mode=mode,
        client=client,
        binance_order_id=execution.order_id or open_request.binance_order_id,
        symbol=symbol,
        side=side_code,
        fill_size=execution.filled_size,
        average_price=execution.average_price,
        stop_loss_price=stop_loss_price,
        stop_loss_amount=stop_loss_amount,
        leverage=int(intent["leverage"]),
        api_key_fingerprint=account.api_key_fingerprint,
        strategy_id=strategy_id,
        strategy_name=strategy_name,
        strategy_config=strategy_config,
        estimated_total_fee=_estimate_total_fee(execution.average_price, execution.filled_size, instrument.get("ctVal")),
        pos_mode="long_short_mode" if intent.get("pos_side") else "net_mode",
        source_label="Maker开仓",
    )
    order = adoption.order
    attach_open_request_order(open_request, order.id)
    stop_market_order_id = order.binance_stop_market_order_id
    if not stop_market_order_id:
        _, protection_error = _resolve_entry_stop_protection(
            order=order,
            client=client,
            inst_id=inst_id,
            side_code=side_code,
            stop_loss_price=stop_loss_price,
            stop_loss_error=adoption.stop_loss_error,
            action_label="Maker开仓",
            pending_message="Maker已成交，止损保护正在后台重试；恢复前不可继续开仓",
        )
        if protection_error:
            raise BinanceApiError(protection_error)
    _invalidate_position_list_cache(request.user, account.api_key_fingerprint, trading_mode=mode)
    return order


class MakerOpenStatusView(APIView):
    """Poll one persisted GTX order; this endpoint never submits a new order."""

    def post(self, request):
        try:
            account, open_request, intent = _maker_request_for_user(
                request, request.data.get("client_request_id")
            )
            existing_order = _find_existing_order_by_open_request(open_request)
            if existing_order:
                return ok(message="开仓成功", data={"state": "SUCCEEDED", "position_id": existing_order.id})
            client = BinanceFuturesClient(account.credentials)
            inst_id = to_inst_id(open_request.symbol)
            row = client.get_order(inst_id=inst_id, order_id=open_request.binance_order_id).get("data", [])
            exchange_row = row[0] if row else {}
            raw_state = str(exchange_row.get("state") or "").strip().lower()
            execution = confirm_entry_execution(
                client,
                inst_id=inst_id,
                order_id=open_request.binance_order_id,
                requested_size=_to_decimal(intent["size"], "开仓数量"),
                initial_row=exchange_row,
                retry_delays=(),
            )
            terminal_states = {"canceled", "cancelled", "expired", "expired_in_match", "rejected", "failed"}
            if raw_state in terminal_states and execution.state == "pending" and execution.filled_size <= 0:
                # The exchange has conclusively ended the Maker order without
                # a fill.  Keep the receipt visible, but release the durable
                # open request so the next entry is not blocked forever.
                mark_open_request_failed(open_request, f"maker_{raw_state}")
                state = "EXPIRED" if raw_state in {"expired", "expired_in_match"} else (
                    "REJECTED" if raw_state in {"rejected", "failed"} else "CANCELLED"
                )
                return ok(message="Maker订单已结束", data={
                    "state": state,
                    "maker_order_id": open_request.binance_order_id,
                    "filled_size": "0",
                    "symbol": open_request.symbol,
                })
            if execution.has_fill and raw_state in terminal_states:
                order = _adopt_maker_fill(request, account, open_request, intent, client, execution)
                return ok(message="开仓成功", data={"state": "SUCCEEDED", "position_id": order.id})
            if execution.has_fill and execution.state == "filled":
                order = _adopt_maker_fill(request, account, open_request, intent, client, execution)
                return ok(message="开仓成功", data={"state": "SUCCEEDED", "position_id": order.id})
            if execution.state == "pending" or execution.filled_size > 0:
                return ok(message="Maker订单等待成交", data={
                    "state": "PENDING_MAKER",
                    "maker_order_id": open_request.binance_order_id,
                    "maker_price": intent.get("maker_price", ""),
                    "market_price": intent.get("maker_market_price", ""),
                    "filled_size": format(execution.filled_size, "f"),
                    "symbol": open_request.symbol,
                })
            return fail("Maker订单已结束，请重新开仓")
        except BinanceApiError as exc:
            if getattr(exc, "outcome_unknown", False):
                # Let the durable command worker mark this UNKNOWN.  A retry
                # must first reconcile the exchange order; it must not be
                # converted to a normal FAILED response.
                raise
            return fail(_translate_exchange_message(str(exc)), code=409, status=409)
        except Exception as exc:  # noqa: BLE001
            logger.exception("maker status failed")
            return fail("Maker订单状态暂时无法确认，请稍后重试", code=409, status=409)


class MakerOpenFallbackView(APIView):
    """Cancel the live GTX order, then market-fill only the confirmed remainder."""

    def post(self, request):
        try:
            account, open_request, intent = _maker_request_for_user(
                request, request.data.get("client_request_id")
            )
            client = BinanceFuturesClient(account.credentials)
            inst_id = to_inst_id(open_request.symbol)
            requested_size = _to_decimal(intent["size"], "开仓数量")
            current_payload = client.get_order(inst_id=inst_id, order_id=open_request.binance_order_id)
            current_row = (current_payload.get("data") or [{}])[0]
            current = parse_entry_execution(current_row, requested_size=requested_size)
            current_raw_state = str(current_row.get("state") or "").strip().lower()
            terminal_states = {"canceled", "cancelled", "expired", "expired_in_match", "rejected", "failed"}
            if current.state == "filled":
                order = _adopt_maker_fill(request, account, open_request, intent, client, current)
                return ok(message="开仓成功", data={"state": "SUCCEEDED", "position_id": order.id})

            # Cancel first and confirm the exchange response.  An unknown
            # cancellation must stop here; sending market after it could
            # double the position if the GTX order was accepted in flight.
            # If the first read already proves a terminal state, do not send
            # a redundant cancel request that Binance may reject as "not
            # found"; the terminal row is the cancellation receipt.
            if current_raw_state in terminal_states:
                if current.state not in {"pending", "partially_filled", "filled"}:
                    raise BinanceApiError("Maker终态数量未确认", outcome_unknown=True)
                cancel_row = current_row
            else:
                cancel_payload = client.cancel_order(inst_id=inst_id, order_id=open_request.binance_order_id)
                cancel_row = (cancel_payload.get("data") or [{}])[0]
            canceled = parse_entry_execution(cancel_row, requested_size=requested_size)
            raw_state = str(cancel_row.get("state") or "").lower()
            if raw_state not in {"canceled", "cancelled", "expired", "expired_in_match", "rejected", "failed"}:
                raise BinanceApiError("Maker撤单结果未确认，已停止市价切换", outcome_unknown=True)
            if not canceled.has_fill and canceled.state != "pending":
                raise BinanceApiError("Maker撤单成交数量未确认，已停止市价切换", outcome_unknown=True)

            filled = canceled.filled_size
            if filled > 0:
                # Persist any partial fill before adding the remainder.  The
                # market fallback below uses a separate client order id.
                _adopt_maker_fill(request, account, open_request, intent, client, canceled)
            if request.data.get("cancel_only"):
                if filled <= 0:
                    mark_open_request_failed(open_request, f"maker_{raw_state}")
                return ok(message="Maker订单已取消", data={
                    "state": "EXPIRED" if raw_state in {"expired", "expired_in_match"}
                    else "REJECTED" if raw_state in {"rejected", "failed"} else "CANCELLED",
                    "filled_size": format(filled, "f"),
                    "maker_order_id": open_request.binance_order_id,
                    "symbol": open_request.symbol,
                })
            remaining = requested_size - filled
            if remaining <= 0:
                order = _find_existing_order_by_open_request(open_request)
                return ok(message="开仓成功", data={"state": "SUCCEEDED", "position_id": order.id if order else None})

            fallback_id = str(intent.get("fallback_client_order_id") or "")
            if not fallback_id:
                fallback_id = _idempotent_client_order_id("mf", account.identity, to_symbol(inst_id), open_request.client_request_id + ":fallback")
                intent["fallback_client_order_id"] = fallback_id
                intent["maker_filled_size"] = format(filled, "f")
                record_open_request_execution_intent(open_request, intent)
            submission = submit_or_recover_exchange_order(
                client=client,
                open_request=open_request,
                inst_id=inst_id,
                client_order_id=fallback_id,
                submit=lambda: client.place_market_order(
                    inst_id=inst_id,
                    side=str(intent["open_side"]),
                    size=format(remaining, "f"),
                    pos_side=str(intent.get("pos_side") or "") or None,
                    new_client_order_id=fallback_id,
                ),
            )
            if not submission.confirmed:
                return fail("市价切换提交结果未确认，请保留页面并重试", code=409, status=409)
            fallback_row = require_exchange_order_row(submission.payload, action_label="市价开仓")
            fallback_execution = confirm_entry_execution(
                client,
                inst_id=inst_id,
                order_id=str(fallback_row["ordId"]),
                requested_size=remaining,
                initial_row=fallback_row,
            )
            if not fallback_execution.has_fill:
                raise BinanceApiError("市价切换尚未确认成交", outcome_unknown=True)
            order = _adopt_maker_fill(request, account, open_request, intent, client, fallback_execution)
            return ok(message="开仓成功", data={"state": "SUCCEEDED", "position_id": order.id})
        except BinanceApiError as exc:
            if getattr(exc, "outcome_unknown", False):
                raise
            return fail(_translate_exchange_message(str(exc)), code=409, status=409)
        except Exception:  # noqa: BLE001
            logger.exception("maker fallback failed")
            return fail("市价切换失败，请核对订单状态后重试", code=409, status=409)


# ============ T023-T026: 限价委托相关接口 ============

class LimitOrderCreateSerializer(serializers.Serializer):
    leverage = serializers.IntegerField(required=False, min_value=1, max_value=1000)
    symbol = serializers.CharField(max_length=32)
    limit_price = serializers.CharField(max_length=64)
    stop_loss_price = serializers.CharField(max_length=64)
    stop_loss_amount = serializers.CharField(max_length=64)
    strategy_id = serializers.CharField(required=False, allow_blank=False, max_length=32)
    strategy_name = serializers.CharField(required=False, allow_blank=False, max_length=100)
    strategy_config = serializers.JSONField(required=False)
    client_request_id = serializers.UUIDField(required=False)

    def validate(self, attrs):
        err = _validate_strategy_payload(
            attrs.get("strategy_id"),
            attrs.get("strategy_name"),
            attrs.get("strategy_config"),
        )
        if err:
            raise serializers.ValidationError(err)
        return attrs


class LimitOrderCreateView(APIView):
    """T023: 限价委托开仓接口"""

    def post(self, request):
        data = None
        normalized_symbol = None
        limit_price = None
        stop_loss_price = None
        stop_loss_amount = None
        current_price = None
        open_side = None
        size = None
        open_request = None
        account = get_user_trading_account(request.user, active_only=True, trading_mode=request_trading_mode(request))
        if not account:
            return fail("使用交易功能需先绑定 Binance Futures 实盘 API，是否立即前往绑定？")
        api_key_fingerprint = account.api_key_fingerprint
        binding_created_at = account.binding_created_at

        serializer = LimitOrderCreateSerializer(data=request.data)
        if not serializer.is_valid():
            errors = serializer.errors
            first_key = next(iter(errors.keys()), None)
            if first_key and errors[first_key]:
                return fail(str(errors[first_key][0]))
            return fail("请求参数错误")

        data = serializer.validated_data
        try:
            inst_id = to_inst_id(data["symbol"])
            normalized_symbol = to_symbol(inst_id)

            with entry_submission_guard(
                request.user,
                account,
                action="limit-create",
                symbol=normalized_symbol,
            ) as guard:
                if not guard.allowed:
                    return fail(guard.error)
                if _has_unresolved_stop_protection(
                    request.user,
                    api_key_fingerprint=api_key_fingerprint,
                    binding_created_at=binding_created_at,
                    trading_mode=request_trading_mode(request),
                ):
                    return fail("已有持仓的止损保护正在恢复，请等待保护完成后再挂入场单")

                raw_client_request_id = str(data.get("client_request_id") or uuid4())
                new_client_order_id = _idempotent_client_order_id(
                    "lo", account.identity, normalized_symbol, raw_client_request_id
                )
                expected_request_payload = _safe_request_payload_for_limit(
                    data, client_order_id=new_client_order_id
                )
                try:
                    request_resolution = resolve_open_request(
                        user=request.user,
                        trading_mode=request_trading_mode(request),
                        symbol=normalized_symbol,
                        client_request_id=raw_client_request_id,
                        client_order_id=new_client_order_id,
                        request_payload=expected_request_payload,
                        conflict_message="client_request_id 已用于不同的限价参数",
                    )
                except OpenRequestPayloadConflict as exc:
                    return fail(safe_error_summary(exc, include_type=False), code=409, status=409)
                open_request = request_resolution.request
                created_open_request = request_resolution.created
                existing_limit_order = LimitOrder.objects.filter(
                    user=request.user,
                    trading_mode=request_trading_mode(request),
                    binance_client_order_id=new_client_order_id,
                ).first()
                if existing_limit_order:
                    return ok(message="限价委托请求已处理", data={"limit_order_id": existing_limit_order.id})

                client = BinanceFuturesClient(account.credentials)
                recovered_limit_row = None
                if not created_open_request:
                    recovered_limit_row = _load_exchange_order_by_client_order_id(
                        client,
                        inst_id=inst_id,
                        client_order_id=new_client_order_id,
                    )
                if not recovered_limit_row:
                    activity = load_exchange_activity(client)
                    dup_error = check_duplicate_order(
                        request.user,
                        data["symbol"],
                        client=client,
                        api_key_fingerprint=api_key_fingerprint,
                        binding_created_at=binding_created_at,
                        trading_mode=request_trading_mode(request),
                        exchange_activity=activity,
                    )
                    if dup_error:
                        return fail(dup_error)
                    capital_error = _entry_capital_error(
                        request.user,
                        client,
                        activity,
                        purpose="entry",
                        trading_mode=request_trading_mode(request),
                    )
                    if capital_error:
                        return fail(capital_error)

                raw_limit_price = _to_decimal(data["limit_price"], "限价")
                raw_stop_loss_price = _to_decimal(data["stop_loss_price"], "止损价")
                stop_loss_amount = _to_decimal(data["stop_loss_amount"], "止损金额")
                try:
                    strategy_payload = _resolve_strategy_snapshot_payload(request.user, data.get("strategy_id"))
                except BinanceApiError:
                    if not recovered_limit_row:
                        raise
                    strategy_payload = None

                execution_intent = get_open_request_execution_intent(open_request)
                if recovered_limit_row:
                    validate_recovered_exchange_order(
                        recovered_limit_row,
                        execution_intent,
                        action_label="限价委托",
                        require_limit_price=True,
                    )
                    limit_price = _to_decimal(execution_intent.get("entry_price"), "原限价")
                    stop_loss_price = _to_decimal(execution_intent.get("stop_loss_price"), "原止损价")
                    open_side = str(execution_intent.get("open_side") or "").strip().lower()
                    side_code = int(execution_intent.get("side_code"))
                    size = str(execution_intent.get("size") or "")
                    max_leverage = int(execution_intent.get("leverage") or 1)
                    use_pos_side = str(execution_intent.get("pos_side") or "").strip() or None
                else:
                    instrument = _extract_instrument(inst_id)
                    ticker = _extract_ticker(inst_id)
                    current_price = _to_decimal(str(ticker.get("last") or "0"), "行情价格")
                    standardized_open = standardize_open_order_request(
                        entry_price=raw_limit_price,
                        stop_loss_price=raw_stop_loss_price,
                        stop_loss_amount=stop_loss_amount,
                        instrument=instrument,
                        order_type="limit",
                    )
                    open_side = standardized_open["open_side"]
                    limit_price = standardized_open["entry_price"]
                    stop_loss_price = standardized_open["stop_loss_price"]
                    side_code = standardized_open["side_code"]
                    size = standardized_open["size"]

                    if side_code == 0 and limit_price > current_price:
                        return fail("限价需小于等于当前市价，请调整后重新输入")
                    if side_code == 1 and limit_price < current_price:
                        return fail("限价需大于等于当前市价，请调整后重新输入")

                    if data.get("leverage") is None:
                        _ensure_notional_within_cap(
                            client, inst_id=inst_id, size=size, entry_price=limit_price, instrument=instrument
                        )
                    use_pos_side = _resolve_pos_side(client, side_code)
                    if data.get("leverage") is not None:
                        from trading.leverage_views import opening_leverage
                        max_leverage = opening_leverage(client, inst_id, data['leverage'],
                            size=size, entry_price=limit_price, instrument=instrument)
                    else:
                        max_leverage = _resolve_max_leverage(client, inst_id, instrument)
                    _ensure_available_margin(
                        client, size=size, entry_price=limit_price, instrument=instrument, leverage=max_leverage
                    )
                    _set_opening_leverage(
                        client,
                        inst_id=inst_id,
                        leverage=max_leverage,
                        pos_side=use_pos_side,
                    )
                    record_open_request_execution_intent(
                        open_request,
                        {
                            "entry_price": format(limit_price, "f"),
                            "stop_loss_price": format(stop_loss_price, "f"),
                            "open_side": open_side,
                            "side_code": side_code,
                            "size": str(size),
                            "leverage": max_leverage,
                            "pos_side": use_pos_side or "",
                        },
                    )

                submission = submit_or_recover_exchange_order(
                    client=client,
                    open_request=open_request,
                    inst_id=inst_id,
                    client_order_id=new_client_order_id,
                    recovered_row=recovered_limit_row,
                    submit=lambda: client.place_limit_order(
                            inst_id=inst_id,
                            side=open_side,
                            size=size,
                            price=str(limit_price),
                            pos_side=use_pos_side,
                            new_client_order_id=new_client_order_id,
                    ),
                )
                if not submission.confirmed:
                    return fail(
                        "限价委托提交结果未确认；请保留当前页面并重试，系统会按原请求恢复",
                        code=409,
                        status=409,
                    )
                order_row = require_exchange_order_row(
                    submission.payload,
                    action_label="限价委托",
                )
                if submission.uncertain_error is not None:
                    validate_recovered_exchange_order(
                        order_row,
                        get_open_request_execution_intent(open_request),
                        action_label="限价委托",
                        require_limit_price=True,
                    )
                binance_order_id = str(order_row["ordId"])
                mark_open_request_submitted(open_request, exchange_order_id=binance_order_id)

                # 保存限价委托记录
                limit_order = LimitOrder.objects.create(
                    user=request.user,
                    trading_mode=request_trading_mode(request),
                    api_key_fingerprint=api_key_fingerprint or None,
                    binance_order_id=binance_order_id,
                    binance_client_order_id=new_client_order_id,
                    symbol=to_symbol(inst_id),
                    side=side_code,
                    limit_price=limit_price,
                    stop_loss_price=stop_loss_price,
                    stop_loss_amount=stop_loss_amount,
                    size=Decimal(size),
                    filled_size=Decimal("0"),
                    leverage=max_leverage,
                    strategy_id=str(strategy_payload["strategy_id"]) if strategy_payload else "",
                    strategy_name=str(strategy_payload["strategy_name"]) if strategy_payload else "",
                    strategy_config=strategy_payload["strategy_config"] if strategy_payload else None,
                    status=LimitOrder.STATUS_PENDING,
                )

                immediate_execution = confirm_entry_execution(
                    client,
                    inst_id=inst_id,
                    order_id=binance_order_id,
                    requested_size=Decimal(size),
                    initial_row=order_row,
                    retry_delays=(0,),
                    on_incomplete_fill=partial(defer_incomplete_limit_execution, limit_order),
                )
                defer_incomplete_limit_execution(limit_order, immediate_execution)
                if immediate_execution.has_fill:
                    adoption = adopt_entry_execution(
                        user=request.user,
                        trading_mode=request_trading_mode(request),
                        client=client,
                        binance_order_id=binance_order_id,
                        symbol=normalized_symbol,
                        side=side_code,
                        fill_size=immediate_execution.filled_size,
                        average_price=immediate_execution.average_price,
                        stop_loss_price=stop_loss_price,
                        stop_loss_amount=stop_loss_amount,
                        leverage=max_leverage,
                        api_key_fingerprint=api_key_fingerprint,
                        strategy_id=str(strategy_payload["strategy_id"]) if strategy_payload else "",
                        strategy_name=str(strategy_payload["strategy_name"]) if strategy_payload else "",
                        strategy_config=strategy_payload["strategy_config"] if strategy_payload else None,
                        limit_order=limit_order,
                        pos_mode="long_short_mode" if use_pos_side else "net_mode",
                        source_label="限价成交",
                    )
                    limit_order.filled_size = immediate_execution.filled_size
                    limit_order.order = adoption.order
                    if immediate_execution.state == "filled":
                        limit_order.status = LimitOrder.STATUS_FILLED
                    limit_order.save(update_fields=["filled_size", "order", "status", "updated_at"])

                return ok(message="限价委托提交成功", data={"limit_order_id": limit_order.id})
        except BinanceApiError as exc:
            exchange_order_submitted = _record_open_request_error(open_request, exc)
            _log_trade_submit_failure(
                "limit-create",
                request,
                exc,
                symbol=normalized_symbol or ((data or {}).get("symbol") if isinstance(data, dict) else None),
                limit_price=str(limit_price) if limit_price is not None else None,
                stop_loss_price=str(stop_loss_price) if stop_loss_price is not None else None,
                stop_loss_amount=str(stop_loss_amount) if stop_loss_amount is not None else None,
                current_price=str(current_price) if current_price is not None else None,
                open_side=open_side,
                requested_size=size,
            )
            if exchange_order_submitted:
                return fail(
                    "限价委托已提交，但本地状态尚未确认；请保留当前页面并重试，系统会按原请求恢复",
                    code=409,
                    status=409,
                )
            return fail(_translate_exchange_message(str(exc)))
        except Exception as exc:
            exchange_order_submitted = _record_open_request_error(open_request, exc)
            _log_trade_submit_failure(
                "limit-create",
                request,
                exc,
                symbol=normalized_symbol or (data or {}).get("symbol"),
                limit_price=str(limit_price) if limit_price is not None else None,
                stop_loss_price=str(stop_loss_price) if stop_loss_price is not None else None,
                stop_loss_amount=str(stop_loss_amount) if stop_loss_amount is not None else None,
                current_price=str(current_price) if current_price is not None else None,
                open_side=open_side,
                requested_size=size,
            )
            if exchange_order_submitted:
                return fail(
                    "限价委托已提交，但本地状态尚未确认；请保留当前页面并重试，系统会按原请求恢复",
                    code=409,
                    status=409,
                )
            return fail("限价委托失败，请稍后重试")


class LimitOrderListView(APIView):
    """T024: 限价委托列表接口"""

    def get(self, request):
        total_started = time.perf_counter()
        credentials = get_user_binance_credentials(request.user, trading_mode=request_trading_mode(request))
        if not credentials:
            return fail("使用交易功能需先绑定 Binance Futures 实盘 API，是否立即前往绑定？")
        binding = get_user_binding(request.user, trading_mode=request_trading_mode(request))
        api_key_fingerprint = get_user_api_key_fingerprint(request.user, trading_mode=request_trading_mode(request))
        binding_created_at = getattr(binding, "created_at", None)

        db_started = time.perf_counter()
        limit_orders = _apply_api_key_scope(
            LimitOrder.objects.filter(
                user=request.user,
                status=LimitOrder.STATUS_PENDING,
            ),
            api_key_fingerprint=api_key_fingerprint,
            binding_created_at=binding_created_at,
            trading_mode=request_trading_mode(request),
        ).order_by("-created_at")
        db_ms = _perf_ms(db_started)

        # 获取所有涉及交易对的合约面值
        symbols = set(lo.symbol for lo in limit_orders)
        ctval_started = time.perf_counter()
        ct_val_map = self._get_ct_val_map(symbols)
        ctval_ms = _perf_ms(ctval_started)

        assemble_started = time.perf_counter()
        result = []
        for lo in limit_orders:
            inst_id = to_inst_id(lo.symbol)
            ct_val = ct_val_map.get(inst_id, Decimal("1"))
            # 仓位金额 = 张数 × 限价 × 合约面值
            position_amount = lo.size * lo.limit_price * ct_val
            filled_amount = lo.filled_size * lo.limit_price * ct_val

            result.append({
                "id": lo.id,
                "symbol": lo.symbol,
                "side": lo.side,
                "limit_price": format(lo.limit_price, "f"),
                "stop_loss_price": format(lo.stop_loss_price, "f"),
                "stop_loss_amount": format(lo.stop_loss_amount, "f"),
                "size": format(lo.size, "f"),
                "filled_size": format(lo.filled_size, "f"),
                "position_amount": format(position_amount, "f"),
                "filled_amount": format(filled_amount, "f"),
                "leverage": lo.leverage,
                "status": lo.status,
                "status_text": lo.get_status_display(),
                "can_chase": lo.can_chase,
                "created_at": lo.created_at.isoformat(),
            })
        logger.info(
            "perf limit_order_list user=%s total_ms=%s db_ms=%s ctval_ms=%s assemble_ms=%s rows=%s",
            getattr(request.user, "id", None),
            _perf_ms(total_started),
            db_ms,
            ctval_ms,
            _perf_ms(assemble_started),
            len(result),
        )
        return ok(data=result)

    def _get_ct_val_map(self, symbols: set) -> dict[str, Decimal]:
        """获取交易对的合约面值"""
        if not symbols:
            return {}

        inst_ids = set(to_inst_id(s) for s in symbols)
        ct_val_map: dict[str, Decimal] = {}
        try:
            payload = binance_get_instruments(inst_type="SWAP")
            instruments = payload.get("data") or []
            for inst in instruments:
                inst_id = str(inst.get("instId") or "")
                if inst_id in inst_ids:
                    ct_val = Decimal(str(inst.get("ctVal") or "1"))
                    ct_val_map[inst_id] = ct_val
        except Exception:
            pass
        return ct_val_map


class LimitOrderCancelView(APIView):
    """T025: 撤销限价委托单接口"""

    @serialized_exchange_mutation
    def post(self, request):
        payload = request_data_mapping(request)
        if payload is None:
            return fail("请求参数必须是对象")
        limit_order_id = payload.get("limit_order_id")
        if not limit_order_id:
            return fail("limit_order_id不能为空")

        binding = get_user_binding(request.user, trading_mode=request_trading_mode(request))
        api_key_fingerprint = get_user_api_key_fingerprint(request.user, trading_mode=request_trading_mode(request))
        binding_created_at = getattr(binding, "created_at", None)
        limit_order = _apply_api_key_scope(
            LimitOrder.objects.filter(
                id=limit_order_id,
                user=request.user,
                status=LimitOrder.STATUS_PENDING,
            ),
            api_key_fingerprint=api_key_fingerprint,
            binding_created_at=binding_created_at,
            trading_mode=request_trading_mode(request),
        ).first()
        if not limit_order:
            return fail("该委托单不存在或已无法撤销")

        credentials = get_user_binance_credentials(request.user, trading_mode=request_trading_mode(request))
        if not credentials:
            return fail("使用交易功能需先绑定 Binance Futures 实盘 API，是否立即前往绑定？")

        client = BinanceFuturesClient(credentials)
        inst_id = to_inst_id(limit_order.symbol)
        cancel_error = None
        cancel_execution = None
        cancel_row = None
        try:
            cancel_payload = client.cancel_order(inst_id=inst_id, order_id=limit_order.binance_order_id)
            cancel_rows = cancel_payload.get("data") or []
            if cancel_rows:
                cancel_row = cancel_rows[0]
                cancel_execution = confirm_entry_execution(
                    client,
                    inst_id=inst_id,
                    order_id=limit_order.binance_order_id,
                    requested_size=limit_order.size,
                    initial_row=cancel_row,
                    retry_delays=(),
                    on_incomplete_fill=partial(defer_incomplete_limit_execution, limit_order),
                )
        except Exception as exc:  # noqa: BLE001
            if not should_verify_cancel_result(exc):
                if isinstance(exc, BinanceApiError):
                    return fail(f"撤单失败：{safe_error_summary(exc, include_type=False)}")
                return fail("撤单失败，请稍后重试")
            cancel_error = exc

        terminal_cancel_states = {"canceled", "cancelled", "expired", "rejected"}
        cancel_is_terminal = bool(
            cancel_execution
            and not defer_incomplete_limit_execution(limit_order, cancel_execution)
            and (
                cancel_execution.raw_state in terminal_cancel_states
                or cancel_execution.state == "filled"
            )
        )
        if not cancel_is_terminal:
            try:
                cancel_execution = confirm_entry_execution(
                    client,
                    inst_id=inst_id,
                    order_id=limit_order.binance_order_id,
                    requested_size=limit_order.size,
                    initial_row=cancel_row,
                    retry_delays=ORDER_RECOVERY_RETRY_DELAYS_SECONDS,
                    on_incomplete_fill=partial(defer_incomplete_limit_execution, limit_order),
                )
            except BinanceApiError as exc:
                if is_binance_rate_limit_error(exc):
                    return fail("撤单状态查验遇到请求限制，本地委托保持待确认，请稍后重试")
                raise
            cancel_is_terminal = (
                not defer_incomplete_limit_execution(limit_order, cancel_execution)
                and (
                    cancel_execution.raw_state in terminal_cancel_states
                    or cancel_execution.state == "filled"
                )
            )
            if not cancel_is_terminal:
                if cancel_execution.has_fill and not defer_incomplete_limit_execution(limit_order, cancel_execution):
                    _adopt_confirmed_limit_fill(
                        request_user=request.user,
                        client=client,
                        limit_order=limit_order,
                        execution=cancel_execution,
                        api_key_fingerprint=api_key_fingerprint,
                    )
                    return fail("撤单期间委托发生部分成交，系统已接管实际仓位；剩余委托状态尚未确认")
                if isinstance(cancel_error, BinanceApiError):
                    return fail(f"撤单失败：{cancel_error}")
                return fail("撤单请求已提交，但交易所尚未确认撤销，请稍后重试")

        had_fill = bool(cancel_execution and cancel_execution.has_fill)
        if had_fill:
            _adopt_confirmed_limit_fill(
                request_user=request.user,
                client=client,
                limit_order=limit_order,
                execution=cancel_execution,
                api_key_fingerprint=api_key_fingerprint,
            )
        limit_order.status = (
            LimitOrder.STATUS_FILLED
            if cancel_execution and cancel_execution.state == "filled"
            else LimitOrder.STATUS_CANCELLED
        )
        limit_order.save(update_fields=["status", "updated_at"])
        return ok(message="撤单成功，已接管成交部分" if had_fill else "撤单成功")


class LimitOrderChaseView(APIView):
    """T026: 追单接口 - 撤销原限价委托 + 市价开仓"""

    def post(self, request):
        payload = request_data_mapping(request)
        if payload is None:
            return fail("请求参数必须是对象")
        limit_order_id = payload.get("limit_order_id")
        if not limit_order_id:
            return fail("limit_order_id不能为空")

        account = get_user_trading_account(request.user, active_only=True, trading_mode=request_trading_mode(request))
        if not account:
            return fail("使用交易功能需先绑定 Binance Futures 实盘 API，是否立即前往绑定？")
        api_key_fingerprint = account.api_key_fingerprint
        binding_created_at = account.binding_created_at
        limit_order = _apply_api_key_scope(
            LimitOrder.objects.filter(
                id=limit_order_id,
                user=request.user,
                trading_mode=request_trading_mode(request),
            ),
            api_key_fingerprint=api_key_fingerprint,
            binding_created_at=binding_created_at,
            trading_mode=request_trading_mode(request),
        ).first()
        if not limit_order:
            return fail("该委托单不存在或已无法追单")

        open_request = None
        try:
            client = BinanceFuturesClient(account.credentials)
            inst_id = to_inst_id(limit_order.symbol)
            normalized_symbol = to_symbol(inst_id)
            chase_request_id = f"chase:{limit_order.id}"
            chase_client_order_id = _idempotent_client_order_id(
                "mc", account.identity, normalized_symbol, chase_request_id
            )

            with entry_submission_guard(
                request.user,
                account,
                action="limit-chase",
                symbol=normalized_symbol,
            ) as guard:
                if not guard.allowed:
                    return fail(guard.error)
                limit_order.refresh_from_db(fields=["filled_size", "status", "order"])
                expected_request_payload = _safe_request_payload_for_chase(
                    limit_order, client_order_id=chase_client_order_id
                )
                existing_request = TradeOpenRequest.objects.filter(
                    user=request.user,
                    trading_mode=request_trading_mode(request),
                    client_order_id=chase_client_order_id,
                ).first()
                if limit_order.status != LimitOrder.STATUS_PENDING and existing_request is None:
                    return fail("该委托单已无法追单")
                try:
                    request_resolution = resolve_open_request(
                        user=request.user,
                        trading_mode=request_trading_mode(request),
                        symbol=normalized_symbol,
                        client_request_id=chase_request_id,
                        client_order_id=chase_client_order_id,
                        request_payload=expected_request_payload,
                        conflict_message="追单请求参数与原请求不一致",
                    )
                except OpenRequestPayloadConflict as exc:
                    return fail(safe_error_summary(exc, include_type=False), code=409, status=409)
                open_request = request_resolution.request
                created_open_request = request_resolution.created

                if limit_order.order_id:
                    existing_order = Order.objects.filter(id=limit_order.order_id, user=request.user, trading_mode=request_trading_mode(request)).first()
                    if existing_order and existing_order.binance_order_id != limit_order.binance_order_id:
                        return ok(message="追单请求已处理", data={"position_id": existing_order.id})
                if _has_unresolved_stop_protection(
                    request.user,
                    api_key_fingerprint=api_key_fingerprint,
                    binding_created_at=binding_created_at,
                    trading_mode=request_trading_mode(request),
                ):
                    return fail("已有持仓的止损保护正在恢复，请等待保护完成后再追单")

                recovered_chase_row = None
                if not created_open_request:
                    recovered_chase_row = _load_exchange_order_by_client_order_id(
                        client,
                        inst_id=inst_id,
                        client_order_id=chase_client_order_id,
                    )

                if recovered_chase_row is None:
                    activity = load_exchange_activity(client)
                    capital_error = _entry_capital_error(
                        request.user,
                        client,
                        activity,
                        purpose="chase",
                        trading_mode=request_trading_mode(request),
                    )
                    if capital_error:
                        return fail(capital_error)
                    original_execution = confirm_entry_execution(
                        client,
                        inst_id=inst_id,
                        order_id=limit_order.binance_order_id,
                        requested_size=limit_order.size,
                        retry_delays=(),
                        on_incomplete_fill=partial(defer_incomplete_limit_execution, limit_order),
                    )
                    if original_execution.state == "unknown":
                        original_execution = confirm_entry_execution(
                            client,
                            inst_id=inst_id,
                            order_id=limit_order.binance_order_id,
                            requested_size=limit_order.size,
                            retry_delays=ORDER_RECOVERY_RETRY_DELAYS_SECONDS,
                            on_incomplete_fill=partial(defer_incomplete_limit_execution, limit_order),
                        )
                    if defer_incomplete_limit_execution(limit_order, original_execution):
                        raise BinanceApiError("原限价委托成交信息尚未确认，无法安全追单")
                    if original_execution.has_fill:
                        _adopt_confirmed_limit_fill(
                            request_user=request.user,
                            client=client,
                            limit_order=limit_order,
                            execution=original_execution,
                            api_key_fingerprint=api_key_fingerprint,
                        )
                        return fail("原限价委托已成交，系统已按实际成交仓位接管，未执行追单")

                    cancel_confirmed = original_execution.raw_state in {
                        "canceled",
                        "cancelled",
                        "expired",
                        "rejected",
                    }
                    if not cancel_confirmed:
                        cancel_error = None
                        cancel_row = None
                        try:
                            cancel_payload = client.cancel_order(
                                inst_id=inst_id,
                                order_id=limit_order.binance_order_id,
                            )
                            cancel_rows = cancel_payload.get("data") or []
                            if cancel_rows:
                                cancel_row = cancel_rows[0]
                                original_execution = confirm_entry_execution(
                                    client,
                                    inst_id=inst_id,
                                    order_id=limit_order.binance_order_id,
                                    requested_size=limit_order.size,
                                    initial_row=cancel_row,
                                    retry_delays=(),
                                    on_incomplete_fill=partial(defer_incomplete_limit_execution, limit_order),
                                )
                        except Exception as exc:  # noqa: BLE001
                            if not should_verify_cancel_result(exc):
                                raise
                            cancel_error = exc
                            logger.warning(
                                "chase cancel response uncertain user=%s limit_order=%s err=%s",
                                request.user.id,
                                limit_order.id,
                                safe_error_summary(exc),
                            )
                        cancel_confirmed = not defer_incomplete_limit_execution(limit_order, original_execution) and original_execution.raw_state in {
                            "canceled",
                            "cancelled",
                            "expired",
                            "rejected",
                        }
                        if not cancel_confirmed and not original_execution.has_fill:
                            original_execution = confirm_entry_execution(
                                client,
                                inst_id=inst_id,
                                order_id=limit_order.binance_order_id,
                                requested_size=limit_order.size,
                                initial_row=cancel_row,
                                retry_delays=(0, 0.2, 0.5, 1),
                                on_incomplete_fill=partial(defer_incomplete_limit_execution, limit_order),
                            )
                        if original_execution.has_fill:
                            _adopt_confirmed_limit_fill(
                                request_user=request.user,
                                client=client,
                                limit_order=limit_order,
                                execution=original_execution,
                                api_key_fingerprint=api_key_fingerprint,
                            )
                            return fail("撤单期间原委托发生成交，系统已接管实际仓位，未执行追单")
                        cancel_confirmed = not defer_incomplete_limit_execution(limit_order, original_execution) and original_execution.raw_state in {
                            "canceled",
                            "cancelled",
                            "expired",
                            "rejected",
                        }
                        if not cancel_confirmed and cancel_error is not None:
                            raise cancel_error
                    if not cancel_confirmed:
                        return fail("尚未确认原限价委托撤销，未执行市价追单，请稍后重试")

                    limit_order.status = LimitOrder.STATUS_CANCELLED
                    limit_order.save(update_fields=["status", "updated_at"])
                    dup_error = check_duplicate_order(
                        request.user,
                        limit_order.symbol,
                        client=client,
                        api_key_fingerprint=api_key_fingerprint,
                        binding_created_at=binding_created_at,
                        trading_mode=request_trading_mode(request),
                    )
                    if dup_error:
                        return fail(dup_error)

                instrument = _extract_instrument(inst_id)
                execution_intent = get_open_request_execution_intent(open_request)
                if recovered_chase_row is not None:
                    validate_recovered_exchange_order(
                        recovered_chase_row,
                        execution_intent,
                        action_label="市价追单",
                    )
                    entry_price = _to_decimal(execution_intent.get("entry_price"), "原追单价格")
                    open_side = str(execution_intent.get("open_side") or "").strip().lower()
                    size = str(execution_intent.get("size") or "")
                    pos_mode = str(execution_intent.get("pos_mode") or "long_short_mode")
                    use_pos_side = str(execution_intent.get("pos_side") or "").strip() or None
                else:
                    ticker = _extract_ticker(inst_id)
                    entry_price = _to_decimal(str(ticker.get("last") or "0"), "行情价格")
                    standardized_open = standardize_open_order_request(
                        entry_price=entry_price,
                        stop_loss_price=limit_order.stop_loss_price,
                        stop_loss_amount=limit_order.stop_loss_amount,
                        instrument=instrument,
                        order_type="market",
                    )
                    open_side = standardized_open["open_side"]
                    size = standardized_open["size"]
                    config_payload = client.get_account_config()
                    config_rows = config_payload.get("data") or []
                    pos_mode = str((config_rows[0] if config_rows else {}).get("posMode") or "long_short_mode")
                    use_pos_side = standardized_open["position_side"] if pos_mode == "long_short_mode" else None
                    record_open_request_execution_intent(
                        open_request,
                        {
                            "entry_price": format(entry_price, "f"),
                            "open_side": open_side,
                            "side_code": limit_order.side,
                            "size": str(size),
                            "pos_mode": pos_mode,
                            "pos_side": use_pos_side or "",
                        },
                    )

                submission = submit_or_recover_exchange_order(
                    client=client,
                    open_request=open_request,
                    inst_id=inst_id,
                    client_order_id=chase_client_order_id,
                    recovered_row=recovered_chase_row,
                    submit=lambda: client.place_market_order(
                            inst_id=inst_id,
                            side=open_side,
                            size=size,
                            pos_side=use_pos_side,
                            new_client_order_id=chase_client_order_id,
                    ),
                )
                if not submission.confirmed:
                    return fail(
                        "市价追单提交结果未确认；请稍后重试，系统会按原请求恢复",
                        code=409,
                        status=409,
                    )
                open_row = require_exchange_order_row(
                    submission.payload,
                    action_label="追单开仓",
                )
                if submission.uncertain_error is not None:
                    validate_recovered_exchange_order(
                        open_row,
                        get_open_request_execution_intent(open_request),
                        action_label="市价追单",
                    )
                binance_order_id = str(open_row["ordId"])
                mark_open_request_submitted(open_request, exchange_order_id=binance_order_id)

                execution = confirm_entry_execution(
                    client,
                    inst_id=inst_id,
                    order_id=binance_order_id,
                    requested_size=Decimal(size),
                    initial_row=open_row,
                )
                if not execution.has_fill:
                    record_open_request_uncertain(
                        open_request,
                        f"exchange_execution_{execution.state}:{execution.raw_state}",
                    )
                    return fail(
                        "市价追单已提交，但交易所尚未确认成交；请稍后重试，系统会按原请求恢复",
                        code=409,
                        status=409,
                    )

                adoption = adopt_entry_execution(
                    user=request.user,
                    trading_mode=request_trading_mode(request),
                    client=client,
                    binance_order_id=binance_order_id,
                    symbol=normalized_symbol,
                    side=limit_order.side,
                    fill_size=execution.filled_size,
                    average_price=execution.average_price,
                    stop_loss_price=limit_order.stop_loss_price,
                    stop_loss_amount=limit_order.stop_loss_amount,
                    leverage=limit_order.leverage,
                    api_key_fingerprint=api_key_fingerprint,
                    strategy_id=limit_order.strategy_id,
                    strategy_name=limit_order.strategy_name,
                    strategy_config=limit_order.strategy_config,
                    limit_order=limit_order,
                    estimated_total_fee=_estimate_total_fee(
                        execution.average_price, execution.filled_size, instrument.get("ctVal")
                    ),
                    pos_mode=pos_mode,
                    source_label="限价追单开仓",
                )
                order = adoption.order
                stop_loss_error = adoption.stop_loss_error
                stop_market_order_id = order.binance_stop_market_order_id
                attach_open_request_order(open_request, order.id)

                message = "追单成功"
                if execution.state == PARTIALLY_FILLED:
                    message = "追单部分成交，已按实际成交仓位挂止损"
                if not stop_market_order_id:
                    logger.warning(
                        "chase stop-loss create failed; background reconcile scheduled user=%s symbol=%s err=%s",
                        request.user.id,
                        normalized_symbol,
                        stop_loss_error,
                    )
                    message, protection_error = _resolve_entry_stop_protection(
                        order=order,
                        client=client,
                        inst_id=inst_id,
                        side_code=limit_order.side,
                        stop_loss_price=limit_order.stop_loss_price,
                        stop_loss_error=stop_loss_error,
                        action_label="追单开仓",
                        pending_message="追单已成交，止损保护正在后台重试；恢复前不可继续开仓",
                    )
                    if protection_error:
                        return fail(protection_error)
                elif order.strategy_snapshot_id and order.strategy_status == Order.STRATEGY_STATUS_CANCELLED:
                    message = "追单成功，但策略止盈预挂失败，已转为手动止盈"
                _invalidate_position_list_cache(request.user, api_key_fingerprint, trading_mode=request_trading_mode(request))
                return ok(
                    message=message,
                    data={"position_id": order.id, "stop_protection_status": order.stop_protection_status},
                )
        except BinanceApiError as exc:
            exchange_order_submitted = _record_open_request_error(open_request, exc)
            if exchange_order_submitted:
                return fail(
                    "市价追单已提交，但本地状态尚未确认；请稍后重试，系统会按原请求恢复",
                    code=409,
                    status=409,
                )
            return fail(safe_error_summary(exc, include_type=False))
        except Exception as exc:
            exchange_order_submitted = _record_open_request_error(open_request, exc)
            logger.error(
                "limit chase failed user=%s limit_order=%s err=%s",
                request.user.id,
                limit_order.id,
                safe_error_summary(exc),
            )
            if exchange_order_submitted:
                return fail(
                    "市价追单已提交，但本地状态尚未确认；请稍后重试，系统会按原请求恢复",
                    code=409,
                    status=409,
                )
            return fail("追单失败，请稍后重试")


class TradingViewMessageIngestView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        token_error = _check_tv_message_token(request)
        if token_error:
            return token_error

        if not settings.EXTERNAL_SIGNAL_INGEST_ENABLED:
            return fail("外部信号接收已暂停", code=503, status=503)

        serializer = TradingViewMessageIngestSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        normalized_payload = dict(serializer.validated_data.get("normalized_payload") or {})
        raw_source = str(normalized_payload.get("source") or "").strip().lower()
        if raw_source == TradingViewMessage.SOURCE_INTERNAL:
            source = TradingViewMessage.SOURCE_INTERNAL
        elif raw_source in {"tv", TradingViewMessage.SOURCE_TRADINGVIEW}:
            source = TradingViewMessage.SOURCE_TRADINGVIEW
        else:
            source = TradingViewMessage.SOURCE_EXTERNAL
        normalized_payload["source"] = source
        event_id = str(normalized_payload.get("event_id") or "").strip()[:191]
        normalized_payload["event_id"] = event_id
        message_data = dict(serializer.validated_data)
        message_data["normalized_payload"] = normalized_payload

        created = True
        if event_id:
            try:
                with transaction.atomic():
                    message, created = TradingViewMessage.objects.get_or_create(
                        source=source,
                        event_id=event_id,
                        defaults=message_data,
                    )
            except IntegrityError:
                message = TradingViewMessage.objects.get(source=source, event_id=event_id)
                created = False
        else:
            with transaction.atomic():
                message = TradingViewMessage.objects.create(
                    source=source,
                    event_id=None,
                    **message_data,
                )

        if not created:
            update_fields = []
            if serializer.validated_data.get("downstream_wecom_ok") and not message.downstream_wecom_ok:
                message.downstream_wecom_ok = True
                update_fields.append("downstream_wecom_ok")
            if serializer.validated_data.get("downstream_telegram_ok") and not message.downstream_telegram_ok:
                message.downstream_telegram_ok = True
                update_fields.append("downstream_telegram_ok")
            downstream_error = safe_error_summary(
                serializer.validated_data.get("downstream_error") or "",
                include_type=False,
                limit=1000,
            )
            if downstream_error and not message.downstream_wecom_ok:
                message.downstream_error = downstream_error
                update_fields.append("downstream_error")
            elif message.downstream_wecom_ok and message.downstream_error:
                message.downstream_error = ""
                update_fields.append("downstream_error")
            if update_fields:
                message.save(update_fields=update_fields)
        else:
            _trim_tradingview_messages()

        return ok(
            {
                "id": message.id,
                "received_at": message.received_at,
                "status": message.qoderwork_status,
                "duplicate": not created,
            }
        )


class TradingViewPendingMessagesView(APIView):
    permission_classes = [AllowAny]

    def get(self, request):
        token_error = _check_tv_message_token(request)
        if token_error:
            return token_error

        try:
            limit = min(max(int(request.query_params.get("limit", "20")), 1), 100)
        except (TypeError, ValueError):
            limit = 20

        rows = list(
            TradingViewMessage.objects.filter(qoderwork_status=TradingViewMessage.STATUS_PENDING)
            .order_by("received_at", "id")[:limit]
        )
        return ok(
            [
                {
                    "id": row.id,
                    "source": row.source,
                    "received_at": row.received_at,
                    "raw_payload": row.raw_payload,
                    "normalized_payload": row.normalized_payload,
                    "downstream_wecom_ok": row.downstream_wecom_ok,
                    "downstream_telegram_ok": row.downstream_telegram_ok,
                    "downstream_error": row.downstream_error,
                }
                for row in rows
            ]
        )


# 与 webhook 归一化逻辑一致，兼容交易所前缀、合约后缀和常见分隔符。
_SYMBOL_IN_TEXT_RE = re.compile(
    r"(?<![A-Z0-9])(?:[A-Z]{2,15}:)?([A-Z0-9]{2,12})[\s/_-]?USDT(?:\.[A-Z0-9]+)?(?![A-Z0-9])",
    re.IGNORECASE,
)


def _extract_symbol_from_text(*texts):
    for text in texts:
        if not text:
            continue
        match = _SYMBOL_IN_TEXT_RE.search(str(text).upper())
        if match:
            return f"{match.group(1).upper()}USDT"
    return None


class TradingViewSignalListView(APIView):
    """信号列表（JWT 认证）：支持按外部或内部来源筛选。"""

    def get(self, request):
        try:
            # 保留期 3 天全量返回（当前量级约百条），避免外部通知被自有扫描信号挤出默认窗口
            limit = min(max(int(request.query_params.get("limit", "500")), 1), 500)
        except (TypeError, ValueError):
            limit = 500

        source_filter = str(request.query_params.get("source") or "").strip().lower()
        if source_filter not in (
            "",
            TradingViewMessage.SOURCE_EXTERNAL,
            TradingViewMessage.SOURCE_INTERNAL,
            TradingViewMessage.SOURCE_TRADINGVIEW,
        ):
            return fail("source 只支持 external、internal 或 tradingview")

        queryset = TradingViewMessage.objects.filter(
            received_at__gte=timezone.now() - timedelta(days=TV_MESSAGE_RETENTION_DAYS)
        )
        if source_filter:
            queryset = queryset.filter(source=source_filter)

        rows = queryset.order_by("-received_at", "-id")[:limit]
        items = []
        for row in rows:
            normalized = row.normalized_payload or {}
            symbol = normalized.get("symbol")
            if str(symbol or "").upper() in ("", "UNKNOWN"):
                symbol = _extract_symbol_from_text(normalized.get("comment"), normalized.get("title")) or symbol
            symbol = str(symbol or "Unknown")
            signal = str(normalized.get("signal") or "").upper()
            # 历史数据无方向字段时从正文推断（做多/做空），与 webhook 归一化一致
            if signal not in ("BUY", "SELL"):
                comment = str(normalized.get("comment") or "")
                if "做多" in comment or "LONG" in comment.upper():
                    signal = "BUY"
                elif "做空" in comment or "SHORT" in comment.upper():
                    signal = "SELL"
            if signal == "BUY":
                direction = "LONG"
            elif signal == "SELL":
                direction = "SHORT"
            else:
                direction = "INFO"
            items.append(
                {
                    "id": row.id,
                    "source": row.source,
                    "symbol": symbol,
                    "signal": signal,
                    "direction": direction,
                    "strategy": normalized.get("strategy") or "Unknown",
                    "title": normalized.get("title") or "",
                    "price_display": normalized.get("price_display") or "",
                    "interval": normalized.get("interval") or "",
                    "comment": normalized.get("comment") or "",
                    "signal_time": normalized.get("time") or "",
                    "received_at": row.received_at,
                    # 自有扫描附加字段
                    "score": normalized.get("score"),
                    "final_action": normalized.get("final_action") or "",
                    "entry_condition": normalized.get("entry_condition") or "",
                    "risk_points": normalized.get("risk_points") or [],
                    "provider": normalized.get("provider") or "",
                    "event_id": normalized.get("event_id") or "",
                    "indicators": normalized.get("indicators") or [],
                }
            )
        return ok(items)


class TradingViewAckMessagesView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        token_error = _check_tv_message_token(request)
        if token_error:
            return token_error

        serializer = TradingViewMessageAckSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        ids = serializer.validated_data["ids"]
        acked_at = timezone.now()
        updated = TradingViewMessage.objects.filter(id__in=ids).exclude(
            qoderwork_status=TradingViewMessage.STATUS_ACKED
        ).update(qoderwork_status=TradingViewMessage.STATUS_ACKED, acked_at=acked_at)
        return ok({"acked_count": updated, "ids": ids})
