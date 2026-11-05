import hashlib
import hmac
import json
import logging
import os
import re
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime
from decimal import Decimal, InvalidOperation, ROUND_DOWN, ROUND_UP
from typing import Any, Callable, Optional
from urllib import error, parse, request

from django.conf import settings

from common.binance_rate_limit import (
    RequestBudgetExceeded,
    RequestPriority,
    classify_request,
    is_exchange_mutation,
    observe_response_headers,
    request_scope,
    reserve_request_budget,
)
from common.errors import safe_error_summary

try:
    import requests  # type: ignore
except Exception:  # pragma: no cover
    requests = None

logger = logging.getLogger(__name__)
ALGO_VISIBILITY_ALLOW_DELAYED = "allow_delayed"
ALGO_VISIBILITY_REQUIRE_VISIBLE = "require_visible"
ALGO_VISIBILITY_RETRY_DELAYS_SECONDS = (0.15, 0.35, 0.75, 1.25)
UNKNOWN_WRITE_RESULT_CODES = frozenset({"-1000", "-1006", "-1007"})
ALGO_CLIENT_ID_DUPLICATE_CODE = "-20132"
CANCEL_ALREADY_ABSENT_CODES = frozenset({"-2011", "-2013"})
PUBLIC_EGRESS_IP_CACHE_TTL_SECONDS = 600
_PUBLIC_EGRESS_IP_CACHE: dict[str, Any] = {"value": "", "expires_at": 0.0}


class BinanceApiError(Exception):
    def __init__(
        self,
        message: str,
        code: Optional[str] = None,
        *,
        outcome_unknown: bool = False,
        account_rate_limited: bool = False,
    ):
        super().__init__(message)
        self.code = code
        self.outcome_unknown = outcome_unknown
        self.account_rate_limited = account_rate_limited or str(code) == "-1015"


def should_recover_write_by_client_id(error: Exception) -> bool:
    """Whether a failed write may already exist and is safe to recover by id."""
    if not isinstance(error, BinanceApiError):
        return isinstance(error, (ConnectionError, TimeoutError))
    if error.outcome_unknown:
        return True
    code = str(error.code or "").strip()
    message = str(error).strip().lower()
    return code == ALGO_CLIENT_ID_DUPLICATE_CODE or (
        "duplicate" in message and ("client" in message or "order" in message)
    )


def should_verify_cancel_result(error: Exception) -> bool:
    if not isinstance(error, BinanceApiError):
        return isinstance(error, (ConnectionError, TimeoutError))
    if error.outcome_unknown:
        return True
    code = str(error.code or "").strip()
    message = str(error).strip().lower()
    return code in CANCEL_ALREADY_ABSENT_CODES or any(
        hint in message
        for hint in ("unknown order", "order does not exist", "order not found", "订单不存在")
    )


ACCOUNT_TYPE_MASTER = "master"
ACCOUNT_TYPE_SUB = "sub"
ACCOUNT_TYPE_UNKNOWN = "unknown"
# Keep the network codes aligned with Binance's capital API. The UI supplies
# the corresponding chain labels (BSC/BEP20, TRX/TRC20, ETH/ERC20).
CAPITAL_COLLECT_NETWORKS = frozenset({"BSC", "TRX", "ETH"})


def is_sub_account_only_error(error: Exception) -> bool:
    """Match Binance's observed role-specific response without trusting the code alone."""
    if not isinstance(error, BinanceApiError) or str(error.code or "").strip() != "-12022":
        return False
    message = str(error).strip().lower()
    return "sub account only" in message or "sub-account only" in message


@dataclass
class BinanceCredentials:
    api_key: str = field(repr=False)
    secret_key: str = field(repr=False)
    passphrase: str = field(default="", repr=False)
    result_observer: Optional[Callable[[Optional[Exception]], None]] = field(
        default=None,
        repr=False,
        compare=False,
    )
    trading_mode: str = "ordinary"


@dataclass(frozen=True)
class _HttpResponseData:
    status_code: int
    payload_text: str
    headers: Any = None


_private_session_state = threading.local()


def _build_requests_session(*, pool_connections: int, pool_maxsize: int):
    session = requests.Session()
    try:
        from requests.adapters import HTTPAdapter

        adapter = HTTPAdapter(pool_connections=pool_connections, pool_maxsize=pool_maxsize)
        session.mount("https://", adapter)
        session.mount("http://", adapter)
    except Exception:  # noqa: BLE001
        pass
    return session


def _get_private_session() -> Optional[Any]:
    """Reuse TCP/TLS connections without sharing mutable sessions across threads."""
    if requests is None:
        return None
    session = getattr(_private_session_state, "session", None)
    if session is None:
        session = _build_requests_session(pool_connections=4, pool_maxsize=8)
        _private_session_state.session = session
    return session


def _perform_http_request(
    *,
    method: str,
    url: str,
    headers: dict[str, str],
    timeout: float,
    outcome_unknown_on_failure: bool,
) -> _HttpResponseData:
    """Send one HTTP request without interpreting Binance's JSON contract."""
    session = _get_private_session()
    if session is not None:
        try:
            response = session.request(
                method=method,
                url=url,
                headers=headers,
                timeout=timeout,
            )
        except Exception as exc:  # noqa: BLE001
            raise BinanceApiError(
                f"连接 {_environment_label()} 失败，请稍后重试",
                outcome_unknown=outcome_unknown_on_failure,
            ) from exc
        return _HttpResponseData(
            status_code=int(getattr(response, "status_code", 500)),
            payload_text=response.text or "",
            headers=getattr(response, "headers", None),
        )

    req = request.Request(url=url, headers=headers, method=method)
    try:
        with request.urlopen(req, timeout=timeout) as response:
            return _HttpResponseData(
                status_code=int(getattr(response, "status", 200)),
                payload_text=response.read().decode("utf-8"),
                headers=getattr(response, "headers", None),
            )
    except error.HTTPError as http_error:
        return _HttpResponseData(
            status_code=int(getattr(http_error, "code", 500)),
            payload_text=http_error.read().decode("utf-8", errors="ignore"),
            headers=getattr(http_error, "headers", None),
        )
    except Exception as exc:  # noqa: BLE001
        raise BinanceApiError(
            f"连接 {_environment_label()} 失败，请稍后重试",
            outcome_unknown=outcome_unknown_on_failure,
        ) from exc


def _d(value: Any) -> Decimal:
    try:
        return Decimal(str(value))
    except (InvalidOperation, TypeError, ValueError):
        return Decimal("0")


def _fmt(value: Any) -> str:
    return format(_d(value), "f")


def _require_balance_rows(value: Any, *, source: str) -> list[dict[str, Any]]:
    if not isinstance(value, list) or any(not isinstance(row, dict) for row in value):
        raise BinanceApiError(f"{source}余额返回格式异常，请稍后重试")
    return value


def quantize_down(value: Decimal, step: Decimal) -> Decimal:
    if step <= 0:
        return value
    return (value / step).quantize(Decimal("1"), rounding=ROUND_DOWN) * step


def _qs(query: Optional[dict[str, Any]]) -> str:
    return parse.urlencode(query or {}, doseq=True)


def _is_rate_limit_error(code: Optional[str], message: str, *, status_code: int = 0) -> bool:
    text = str(message or "").strip().lower()
    normalized_code = str(code or "").strip()
    if status_code in (418, 429):
        return True
    if normalized_code in {
        "-1003",
        "-1015",
        "429",
        "418",
        "50115",
        "LOCAL_RATE_BUDGET",
        "LOCAL_RATE_COOLDOWN",
    }:
        return True
    hints = (
        "too many requests",
        "requests per minute",
        "rate limit",
        "请求过于频繁",
    )
    return any(hint in text for hint in hints)


def is_binance_rate_limit_error(error: Exception) -> bool:
    """Return whether an exchange exception represents Binance throttling."""
    return isinstance(error, BinanceApiError) and _is_rate_limit_error(
        error.code,
        str(error),
    )


def is_binance_preflight_rate_limit_error(error: Exception) -> bool:
    """Return whether throttling happened before any HTTP request was sent."""
    return isinstance(error, BinanceApiError) and str(error.code or "").strip() in {
        "LOCAL_RATE_BUDGET",
        "LOCAL_RATE_COOLDOWN",
    }


def is_binance_auth_or_permission_error(error: Exception) -> bool:
    """Return whether retrying another private endpoint cannot fix the failure."""
    if not isinstance(error, BinanceApiError):
        return False
    code = str(error.code or "").strip()
    if code in {"401", "403", "-1002", "-1022", "-2014", "-2015", "50110", "50113", "50119"}:
        return True
    message = str(error).strip().lower()
    return any(
        hint in message
        for hint in (
            "api key",
            "signature",
            "permission",
            "unauthorized",
            "not authorized",
            "ip whitelist",
            "ip 白名单",
            "签名",
            "权限",
        )
    )


RATE_LIMIT_COOLDOWN_CACHE_KEY = "trade:binance:rate-limit-cooldown-until"
RATE_LIMIT_DEFAULT_COOLDOWN_SECONDS = 30.0
_BAN_UNTIL_PATTERN = re.compile(r"banned until (\d{10,})", re.IGNORECASE)


def _shared_cache_backend():
    try:
        from django.core.cache import cache

        return cache
    except Exception:  # noqa: BLE001
        return None


def _rate_limit_cooldown_cache_key(scope: str) -> str:
    normalized_scope = str(scope or "futures").strip().lower()
    if normalized_scope not in {"futures", "spot", "sapi"} and not re.fullmatch(r"(?:futures|spot|sapi):orders:[a-f0-9]{24}", normalized_scope):
        normalized_scope = "futures"
    return f"{RATE_LIMIT_COOLDOWN_CACHE_KEY}:{normalized_scope}"


def rate_limit_cooldown_remaining(scope: str = "futures") -> float:
    """Return the shared cooldown for one Binance API scope."""
    backend = _shared_cache_backend()
    if backend is None:
        return 0.0
    try:
        until = backend.get(_rate_limit_cooldown_cache_key(scope))
    except Exception:  # noqa: BLE001
        return 0.0
    try:
        remaining = float(until or 0) - time.time()
    except (TypeError, ValueError):
        return 0.0
    return remaining if remaining > 0 else 0.0


def mark_rate_limit_cooldown(message: str = "", headers=None, *, scope: str = "futures") -> None:
    """收到限频/BAN 响应后记录冷却截止时间：优先解析 'banned until'，取不到则用默认冷却熬过限频窗口。"""
    cooldown = float(RATE_LIMIT_DEFAULT_COOLDOWN_SECONDS)
    match = _BAN_UNTIL_PATTERN.search(str(message or ""))
    if match:
        try:
            cooldown = max(cooldown, int(match.group(1)) / 1000.0 - time.time())
        except ValueError:
            pass
    try:
        normalized_headers = {
            str(key).strip().lower(): value for key, value in dict(headers or {}).items()
        }
        retry_after = float(normalized_headers.get("retry-after") or 0)
        cooldown = max(cooldown, retry_after)
    except (TypeError, ValueError):
        pass
    backend = _shared_cache_backend()
    if backend is None:
        return
    until = time.time() + max(cooldown, 1.0)
    cache_key = _rate_limit_cooldown_cache_key(scope)
    try:
        existing = float(backend.get(cache_key) or 0)
        if existing > until:
            until = existing
        backend.set(cache_key, until, timeout=int(until - time.time()) + 120)
    except Exception:  # noqa: BLE001
        return
    logger.warning(
        "binance_rate_limit_cooldown activated scope=%s seconds=%s",
        scope,
        int(until - time.time()),
    )


def clear_rate_limit_cooldown(scope: Optional[str] = None) -> None:
    backend = _shared_cache_backend()
    if backend is None:
        return
    try:
        if scope is None:
            backend.delete_many(
                [
                    RATE_LIMIT_COOLDOWN_CACHE_KEY,
                    *(
                        _rate_limit_cooldown_cache_key(candidate)
                        for candidate in ("futures", "spot", "sapi")
                    ),
                ]
            )
        else:
            backend.delete(_rate_limit_cooldown_cache_key(scope))
    except Exception:  # noqa: BLE001
        pass


def _raise_if_rate_limit_cooldown(scope: str = "futures", *, account_rate_limited: bool = False) -> None:
    remaining = rate_limit_cooldown_remaining(scope)
    if remaining > 0:
        raise BinanceApiError(
            f"币安限频保护中，已自动暂停请求，约 {max(int(remaining), 1)} 秒后恢复，请稍后再试",
            code="LOCAL_RATE_COOLDOWN",
            account_rate_limited=account_rate_limited,
        )


def _http_rate_limit_message(payload_text: str, status_code: int) -> str:
    """Extract a bounded Binance message without requiring a valid JSON body."""
    try:
        payload = json.loads(payload_text)
    except (TypeError, ValueError):
        payload = None
    if isinstance(payload, dict):
        message = str(payload.get("msg") or "").strip()
        if message:
            return message[:500]
    return f"Binance 请求过于频繁 (http: {status_code})"


# 出站流量观测：按分钟窗口统计本进程对币安的请求数与接口分布，
# 用于定位限频来源（多进程部署时每个进程各自输出一行）。
_OUTBOUND_METRICS: dict = {"window": int(time.time() // 60), "count": 0, "paths": {}, "peak_weight": 0}


def _track_binance_outbound(path: str) -> None:
    try:
        now_window = int(time.time() // 60)
        metrics = _OUTBOUND_METRICS
        if metrics["window"] != now_window:
            if metrics["count"]:
                top = sorted(metrics["paths"].items(), key=lambda item: item[1], reverse=True)[:15]
                logger.info(
                    "binance_outbound_minute pid=%s count=%s peak_used_weight=%s top=%s",
                    os.getpid(),
                    metrics["count"],
                    metrics["peak_weight"],
                    ", ".join(f"{p}:{n}" for p, n in top),
                )
            metrics["window"] = now_window
            metrics["count"] = 0
            metrics["paths"] = {}
            metrics["peak_weight"] = 0
        metrics["count"] += 1
        metrics["paths"][path] = metrics["paths"].get(path, 0) + 1
    except Exception:  # noqa: BLE001
        pass


def _record_binance_used_weight(
    headers,
    *,
    scope: str = "futures",
    account_api_key: str = "",
    lead_trading: bool = False,
    account_weight: bool = False,
) -> None:
    try:
        weight, _order_count = observe_response_headers(
            headers,
            scope=scope,
            account_api_key=account_api_key,
            lead_trading=lead_trading,
            account_weight=account_weight,
        )
        if weight:
            _OUTBOUND_METRICS["peak_weight"] = max(_OUTBOUND_METRICS["peak_weight"], weight)
    except Exception:  # noqa: BLE001
        pass


ACCOUNT_CONFIG_CACHE_TTL_SECONDS = 600
FUTURES_BALANCE_CACHE_TTL_SECONDS = 15
MARKET_PRICES_CACHE_KEY = "trade:market-prices:all"
MARKET_PRICES_CACHE_TTL_SECONDS = 3


def _account_config_cache_key(api_key: str) -> str:
    digest = hashlib.sha256(str(api_key or "").encode("utf-8")).hexdigest()[:16]
    return f"trade:binance:account-config:{digest}"


def clear_account_config_cache(api_key: str) -> None:
    backend = _shared_cache_backend()
    if backend is None:
        return
    try:
        backend.delete(_account_config_cache_key(api_key))
    except Exception:  # noqa: BLE001
        pass


def binance_get_cached_last_prices() -> dict[str, str]:
    """全市场最新价快照（instId->last），跨进程共享缓存，避免高频轮询重复拉全量行情。"""
    backend = _shared_cache_backend()
    if backend is not None:
        try:
            cached = backend.get(MARKET_PRICES_CACHE_KEY)
        except Exception:  # noqa: BLE001
            cached = None
        if isinstance(cached, dict) and cached:
            return cached
    payload = binance_get_last_prices()
    rows = payload.get("data") or []
    prices = {str(row.get("instId") or ""): str(row.get("last") or "") for row in rows if row.get("last")}
    if backend is not None and prices:
        try:
            backend.set(MARKET_PRICES_CACHE_KEY, prices, timeout=MARKET_PRICES_CACHE_TTL_SECONDS)
        except Exception:  # noqa: BLE001
            pass
    return prices


def _safe_query_for_log(query: Optional[dict[str, Any]]) -> dict[str, Any]:
    allowed_keys = {
        "algoId",
        "clientAlgoId",
        "orderId",
        "origClientOrderId",
        "symbol",
    }
    return {
        key: value
        for key, value in dict(query or {}).items()
        if key in allowed_keys
    }


def _extract_ip_from_text(text: str) -> str:
    match = re.search(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", str(text or ""))
    return match.group(0) if match else ""


def detect_public_egress_ip(force_refresh: bool = False) -> str:
    now = time.time()
    if not force_refresh and _PUBLIC_EGRESS_IP_CACHE["value"] and now < float(_PUBLIC_EGRESS_IP_CACHE["expires_at"] or 0):
        return str(_PUBLIC_EGRESS_IP_CACHE["value"] or "")

    try:
        with request.urlopen("https://api.ipify.org", timeout=2.5) as resp:
            value = resp.read().decode("utf-8").strip()
    except Exception:  # noqa: BLE001
        value = ""

    _PUBLIC_EGRESS_IP_CACHE["value"] = value
    _PUBLIC_EGRESS_IP_CACHE["expires_at"] = now + PUBLIC_EGRESS_IP_CACHE_TTL_SECONDS
    return value


def _ok(rows: list[dict[str, Any]]) -> dict[str, Any]:
    return {"code": "0", "data": rows}


def _interval(bar: str) -> str:
    return {"1H": "1h", "4H": "4h", "1D": "1d"}.get((bar or "").upper(), bar or "1m")


def _base_url() -> str:
    value = getattr(settings, "BINANCE_FUTURES_BASE_URL", "https://fapi.binance.com").rstrip("/")
    return value or "https://fapi.binance.com"


def _spot_base_url() -> str:
    value = str(getattr(settings, "BINANCE_SPOT_BASE_URL", "") or "").rstrip("/")
    if not value:
        # 未显式配置时跟随合约环境：测试网用现货测试网域名
        value = "https://testnet.binance.vision" if "testnet" in _base_url() else "https://api.binance.com"
    return value


def _timeout_seconds() -> float:
    return float(getattr(settings, "BINANCE_TIMEOUT_SECONDS", 10))


def _recv_window() -> int:
    return int(getattr(settings, "BINANCE_RECV_WINDOW", 5000))


def _default_max_leverage() -> int:
    return int(getattr(settings, "BINANCE_DEFAULT_MAX_LEVERAGE", 125))


def _environment_label() -> str:
    return "Binance Futures 实盘"


def quantize_up(value: Decimal, step: Decimal) -> Decimal:
    if step <= 0:
        return value
    ratio = value / step
    whole = ratio.quantize(Decimal("1"), rounding=ROUND_UP)
    return whole * step


def quantize_price(value: Decimal, tick: Decimal) -> Decimal:
    if tick <= 0:
        return value
    return quantize_down(value, tick)


def _quantize_price_with_rounding(value: Decimal, tick: Decimal, *, round_up: bool) -> Decimal:
    if tick <= 0:
        return value
    return quantize_up(value, tick) if round_up else quantize_down(value, tick)


def _extract_filter(filters: list[dict[str, Any]], filter_type: str) -> dict[str, Any]:
    for item in filters:
        if str(item.get("filterType") or "") == filter_type:
            return item
    return {}


def _exchange_symbol(raw: str) -> str:
    value = (raw or "").strip().upper()
    if not value:
        raise BinanceApiError("交易对不能为空")
    if value.endswith("X100"):
        value = value[:-4]
    if value.endswith("-USDT-SWAP"):
        return value.replace("-", "").replace("SWAP", "")
    if value.endswith("USDT"):
        return value
    if "-" in value:
        parts = [part for part in value.split("-") if part]
        if len(parts) >= 2 and parts[1] == "USDT":
            return f"{parts[0]}USDT"
    raise BinanceApiError("交易对格式错误，仅支持 U 本位 USDT 永续")


def to_inst_id(symbol: str) -> str:
    exchange_symbol = _exchange_symbol(symbol)
    base = exchange_symbol[:-4]
    return f"{base}-USDT-SWAP"


def to_symbol(inst_id: str) -> str:
    return _exchange_symbol(inst_id)


def _legacy_pos_mode(is_dual_side: bool) -> str:
    return "long_short_mode" if is_dual_side else "net_mode"


def _legacy_order_state(status: str) -> str:
    text = str(status or "").upper()
    mapping = {
        "NEW": "live",
        "PARTIALLY_FILLED": "partially_filled",
        "FILLED": "filled",
        "CANCELED": "canceled",
        "EXPIRED": "canceled",
        "REJECTED": "canceled",
    }
    return mapping.get(text, text.lower() or "live")


def _legacy_pos_side(position_side: str, qty: Decimal) -> str:
    raw = str(position_side or "").upper()
    if raw == "LONG":
        return "long"
    if raw == "SHORT":
        return "short"
    return "long" if qty >= 0 else "short"


def _normalize_public_instrument(row: dict[str, Any]) -> dict[str, Any]:
    filters = row.get("filters") or []
    price_filter = _extract_filter(filters, "PRICE_FILTER")
    lot_filter = _extract_filter(filters, "LOT_SIZE")
    market_lot_filter = _extract_filter(filters, "MARKET_LOT_SIZE")
    notional_filter = _extract_filter(filters, "MIN_NOTIONAL") or _extract_filter(filters, "NOTIONAL")
    step_size = str(lot_filter.get("stepSize") or "0.001")
    min_qty = str(lot_filter.get("minQty") or step_size or "0.001")
    market_step_size = str(market_lot_filter.get("stepSize") or step_size or "0.001")
    market_min_qty = str(market_lot_filter.get("minQty") or min_qty or market_step_size or "0.001")
    tick_size = str(price_filter.get("tickSize") or "0.01")
    min_notional = str(
        notional_filter.get("notional")
        or notional_filter.get("minNotional")
        or row.get("notional")
        or "0"
    )
    symbol = str(row.get("symbol") or "")
    return {
        "instId": to_inst_id(symbol),
        "instType": "SWAP",
        "ctVal": "1",
        "lotSz": step_size,
        "minSz": min_qty,
        "marketLotSz": market_step_size,
        "marketMinSz": market_min_qty,
        "tickSz": tick_size,
        "minNotional": min_notional,
        "triggerProtect": str(row.get("triggerProtect") or "0"),
        "lever": str(_default_max_leverage()),
        "maxLever": str(_default_max_leverage()),
        "baseCcy": str(row.get("baseAsset") or ""),
        "quoteCcy": str(row.get("quoteAsset") or ""),
    }


def get_symbol_rules(instrument: dict[str, Any], order_type: str = "limit") -> dict[str, Decimal]:
    normalized_type = str(order_type or "limit").lower()
    qty_step = _d(instrument.get("lotSz") or "0")
    qty_min = _d(instrument.get("minSz") or "0")
    if normalized_type in {"market", "stop_market", "take_profit_market"}:
        qty_step = _d(instrument.get("marketLotSz") or instrument.get("lotSz") or "0")
        qty_min = _d(instrument.get("marketMinSz") or instrument.get("minSz") or "0")
    return {
        "qty_step": qty_step,
        "qty_min": qty_min,
        "tick_size": _d(instrument.get("tickSz") or "0"),
        "min_notional": _d(instrument.get("minNotional") or "0"),
        "trigger_protect": _d(instrument.get("triggerProtect") or "0"),
    }


def normalize_quantity(quantity: Decimal, instrument: dict[str, Any], order_type: str = "limit") -> Decimal:
    rules = get_symbol_rules(instrument, order_type)
    normalized = quantize_down(quantity, rules["qty_step"])
    if normalized <= 0:
        raise BinanceApiError("当前参数下可下单数量为 0，请调整仓位参数")
    if rules["qty_min"] > 0 and normalized < rules["qty_min"]:
        raise BinanceApiError(f"下单数量低于币安最小数量限制 {format(rules['qty_min'], 'f')}")
    return normalized


def normalize_limit_price(price: Decimal, instrument: dict[str, Any], side: str) -> Decimal:
    normalized = _quantize_price_with_rounding(
        price,
        get_symbol_rules(instrument)["tick_size"],
        round_up=str(side or "").lower() == "sell",
    )
    if normalized <= 0:
        raise BinanceApiError("价格不合法")
    return normalized


def normalize_stop_trigger_price(price: Decimal, instrument: dict[str, Any], position_side: str) -> Decimal:
    normalized = _quantize_price_with_rounding(
        price,
        get_symbol_rules(instrument)["tick_size"],
        round_up=str(position_side or "").lower() == "short",
    )
    if normalized <= 0:
        raise BinanceApiError("价格不合法")
    return normalized


def normalize_take_profit_trigger_price(price: Decimal, instrument: dict[str, Any], position_side: str) -> Decimal:
    normalized = _quantize_price_with_rounding(
        price,
        get_symbol_rules(instrument)["tick_size"],
        round_up=str(position_side or "").lower() == "long",
    )
    if normalized <= 0:
        raise BinanceApiError("价格不合法")
    return normalized


def validate_min_notional(price: Decimal, quantity: Decimal, instrument: dict[str, Any]) -> None:
    rules = get_symbol_rules(instrument)
    min_notional = rules["min_notional"]
    if min_notional <= 0:
        return
    order_notional = price * quantity
    if order_notional < min_notional:
        raise BinanceApiError(
            f"下单金额低于币安最小名义价值限制 {format(min_notional, 'f')} USDT，请提高止损金额或调整价格"
        )


def resolve_order_direction(entry_price: Decimal, stop_loss_price: Decimal) -> dict[str, Any]:
    if entry_price <= 0 or stop_loss_price <= 0:
        raise BinanceApiError("价格不合法")
    if entry_price == stop_loss_price:
        raise BinanceApiError("止损参数不合法")
    is_long = stop_loss_price < entry_price
    return {
        "is_long": is_long,
        "side_code": 0 if is_long else 1,
        "open_side": "buy" if is_long else "sell",
        "close_side": "sell" if is_long else "buy",
        "position_side": "long" if is_long else "short",
    }


def validate_trigger_relation(
    trigger_price: Decimal,
    reference_price: Decimal,
    position_side: str,
    trigger_kind: str,
) -> None:
    if trigger_price <= 0 or reference_price <= 0:
        raise BinanceApiError("价格不合法")
    pos_side = str(position_side or "").lower()
    trigger_name = "止损" if trigger_kind == "stop_loss" else "止盈"
    if pos_side == "long":
        if trigger_kind == "stop_loss" and trigger_price >= reference_price:
            raise BinanceApiError(f"多单{trigger_name}价必须低于参考价")
        if trigger_kind == "take_profit" and trigger_price <= reference_price:
            raise BinanceApiError(f"多单{trigger_name}价必须高于参考价")
    elif pos_side == "short":
        if trigger_kind == "stop_loss" and trigger_price <= reference_price:
            raise BinanceApiError(f"空单{trigger_name}价必须高于参考价")
        if trigger_kind == "take_profit" and trigger_price >= reference_price:
            raise BinanceApiError(f"空单{trigger_name}价必须低于参考价")


def standardize_trigger_order_request(
    *,
    trigger_price: Decimal,
    quantity: Decimal,
    instrument: dict[str, Any],
    trigger_kind: str,
    position_side: str,
    reference_price: Optional[Decimal] = None,
) -> dict[str, Any]:
    normalized_kind = str(trigger_kind or "").lower()
    if normalized_kind not in {"stop_loss", "take_profit"}:
        raise BinanceApiError("不支持的触发单类型")
    order_type = "stop_market" if normalized_kind == "stop_loss" else "take_profit_market"
    normalized_quantity = normalize_quantity(quantity, instrument, order_type)
    if normalized_kind == "stop_loss":
        normalized_trigger = normalize_stop_trigger_price(trigger_price, instrument, position_side)
    else:
        normalized_trigger = normalize_take_profit_trigger_price(trigger_price, instrument, position_side)
    if reference_price is not None and reference_price > 0:
        validate_trigger_relation(normalized_trigger, reference_price, position_side, normalized_kind)
    rules = get_symbol_rules(instrument, order_type)
    return {
        "quantity": normalized_quantity,
        "trigger_price": normalized_trigger,
        "trigger_protect": rules["trigger_protect"],
        "working_type": "MARK_PRICE",
        "price_protect": "TRUE",
    }


def standardize_open_order_request(
    *,
    entry_price: Decimal,
    stop_loss_price: Decimal,
    stop_loss_amount: Decimal,
    instrument: dict[str, Any],
    order_type: str,
) -> dict[str, Any]:
    normalized_order_type = str(order_type or "market").lower()
    if normalized_order_type not in {"market", "limit"}:
        raise BinanceApiError("不支持的开仓订单类型")
    direction = resolve_order_direction(entry_price, stop_loss_price)
    normalized_entry_price = entry_price
    if normalized_order_type == "limit":
        normalized_entry_price = normalize_limit_price(entry_price, instrument, direction["open_side"])
    normalized_stop_price = normalize_stop_trigger_price(
        stop_loss_price,
        instrument,
        direction["position_side"],
    )
    validate_trigger_relation(
        normalized_stop_price,
        normalized_entry_price,
        direction["position_side"],
        "stop_loss",
    )
    risk_ratio = abs(normalized_entry_price - normalized_stop_price) / normalized_entry_price
    if risk_ratio <= 0:
        raise BinanceApiError("止损参数不合法")
    notional = stop_loss_amount / risk_ratio
    size = calc_contract_size(
        entry_price=str(normalized_entry_price),
        notional_usdt=str(notional),
        ct_val=str(instrument.get("ctVal") or "0"),
        lot_sz=str(
            instrument.get("marketLotSz") if normalized_order_type == "market" else instrument.get("lotSz")
            or instrument.get("lotSz")
            or "1"
        ),
        min_sz=str(
            instrument.get("marketMinSz") if normalized_order_type == "market" else instrument.get("minSz")
            or instrument.get("minSz")
            or "0"
        ),
        min_notional=str(instrument.get("minNotional") or "0"),
    )
    return {
        **direction,
        "entry_price": normalized_entry_price,
        "stop_loss_price": normalized_stop_price,
        "size": size,
        "trigger_protect": get_symbol_rules(
            instrument,
            "stop_market" if normalized_order_type == "market" else "limit",
        )["trigger_protect"],
    }


def _normalize_public_ticker(row: dict[str, Any]) -> dict[str, Any]:
    symbol = str(row.get("symbol") or "")
    last_price = row.get("lastPrice") or row.get("price") or row.get("markPrice") or "0"
    quote_volume = row.get("quoteVolume") or row.get("quoteVolume24h") or "0"
    return {
        "instId": to_inst_id(symbol),
        "last": str(last_price),
        "markPx": str(last_price),
        "volCcy24h": str(quote_volume),
    }


# U 本位 USDT 永续符号：币安期货行情会混入交割合约（BTCUSDT_260925）、
# 非 USDT 结算（BTCUSD1、ETHUSDC）等符号，只认纯字母数字 + USDT 结尾。
_USDT_PERP_SYMBOL_RE = re.compile(r"^[0-9A-Z]+USDT$")


def _normalize_public_price_ticker(row: dict[str, Any]) -> dict[str, Any]:
    symbol = str(row.get("symbol") or "")
    last_price = row.get("price") or row.get("lastPrice") or "0"
    return {
        "instId": to_inst_id(symbol),
        "last": str(last_price),
    }


def _algo_order_type(row: dict[str, Any]) -> str:
    order_type = str(row.get("type") or row.get("orderType") or "").upper()
    if not order_type and _d(row.get("tpTriggerPx") or "0") > 0:
        order_type = "TAKE_PROFIT_MARKET"
    if not order_type and _d(row.get("slTriggerPx") or "0") > 0:
        order_type = "STOP_MARKET"
    return order_type


def _exchange_bool(value: Any) -> bool:
    # Binance replies can contain JSON booleans or their string representation.
    return value is True or str(value).strip().lower() == "true"


def _parse_algo_order_row(row: dict[str, Any]) -> dict[str, Any]:
    order_type = _algo_order_type(row)
    if order_type not in {"STOP", "STOP_MARKET", "TAKE_PROFIT", "TAKE_PROFIT_MARKET"}:
        raise BinanceApiError(f"暂不支持的条件单类型: {order_type or 'unknown'}")
    current_algo_id = str(row.get("algoId") or row.get("orderId") or "").strip()
    if not current_algo_id:
        raise BinanceApiError("条件单返回缺少 algoId")
    symbol = str(row.get("symbol") or "").strip()
    if not symbol:
        raise BinanceApiError("条件单返回缺少 symbol")
    trigger_price = str(row.get("triggerPrice") or row.get("stopPrice") or "").strip()
    quantity = str(row.get("quantity") or row.get("origQty") or "").strip()
    close_position = _exchange_bool(row.get("closePosition"))
    if close_position and not quantity:
        quantity = "0"
    if not quantity:
        raise BinanceApiError("条件单返回缺少 quantity")
    return {
        "algoId": current_algo_id,
        "clientAlgoId": str(row.get("clientAlgoId") or row.get("clientOrderId") or "").strip(),
        "actualOrderId": str(row.get("actualOrderId") or row.get("orderId") or "").strip(),
        "instId": to_inst_id(symbol),
        "sz": quantity,
        "slTriggerPx": trigger_price if order_type in {"STOP", "STOP_MARKET"} else "0",
        "tpTriggerPx": trigger_price if order_type in {"TAKE_PROFIT", "TAKE_PROFIT_MARKET"} else "0",
        "side": str(row.get("side") or "").lower(),
        "posSide": _legacy_pos_side(
            str(row.get("positionSide") or "BOTH"),
            _d(quantity or "0"),
        ),
        "state": _legacy_order_state(str(row.get("algoStatus") or row.get("status") or "")),
        "algoType": order_type,
        "rawPositionSide": str(row.get("positionSide") or "BOTH").strip().upper(),
        "reduceOnly": _exchange_bool(row.get("reduceOnly")),
        "closePosition": close_position,
        "workingType": str(row.get("workingType") or "").strip().upper(),
        "priceProtect": _exchange_bool(row.get("priceProtect")),
    }


def _parse_algo_submit_response(payload: Any) -> dict[str, Any]:
    if isinstance(payload, dict):
        row = payload
    elif isinstance(payload, list) and payload:
        row = payload[0]
    else:
        row = {}
    s_code = str(row.get("sCode") or "0").strip() or "0"
    s_msg = str(row.get("sMsg") or row.get("msg") or "").strip()
    if s_code != "0":
        raise BinanceApiError(
            s_msg or "条件单创建失败",
            code=s_code,
            outcome_unknown=s_code in UNKNOWN_WRITE_RESULT_CODES,
        )
    algo_id = str(row.get("algoId") or row.get("orderId") or "").strip()
    if not algo_id:
        raise BinanceApiError("条件单创建失败，未返回algoId", outcome_unknown=True)
    return {"algoId": algo_id, "sCode": s_code, "sMsg": s_msg}


class BinanceAlgoClient:
    def __init__(self, client: "BinanceFuturesClient", *, log: Optional[logging.Logger] = None):
        self.client = client
        self.log = log or logger

    def get_algo(self, algo_id: str, inst_id: str = "") -> dict[str, Any]:
        payload = self.client.get_pending_algo_orders(
            ord_type="conditional",
            inst_type="SWAP",
            inst_id=inst_id,
            algo_id=algo_id,
            budget_priority=RequestPriority.CRITICAL,
        )
        rows = payload.get("data") or []
        if not rows:
            raise BinanceApiError(f"未查到条件单 algoId={algo_id}")
        return rows[0]

    def list_open_algos(self, inst_id: str = "") -> list[dict[str, Any]]:
        payload = self.client.get_pending_algo_orders(
            ord_type="conditional",
            inst_type="SWAP",
            inst_id=inst_id,
            budget_priority=RequestPriority.CRITICAL,
        )
        return payload.get("data") or []

    def cancel_algo(self, algo_id: str, inst_id: str, *, action: str = "cancel_algo") -> str:
        payload = self.client.cancel_algos(algo_id=algo_id, inst_id=inst_id)
        rows = payload.get("data") or []
        current_algo_id = ""
        if rows and isinstance(rows[0], dict):
            current_algo_id = str((rows[0] or {}).get("algoId") or "").strip()
        if not current_algo_id:
            raise BinanceApiError(
                f"条件单撤销未返回有效结果 action={action}",
                outcome_unknown=True,
            )
        self.log.info(
            "algo action=%s status=cancelled inst_id=%s algo_id=%s",
            action,
            inst_id,
            current_algo_id,
        )
        return current_algo_id

    def cancel_algo_confirmed(self, algo_id: str, inst_id: str, *, action: str = "cancel_algo") -> str:
        """Cancel once; recover a lost response by checking the live-order list."""
        current_algo_id = str(algo_id or "").strip()
        try:
            return self.cancel_algo(current_algo_id, inst_id, action=action)
        except Exception as submit_error:
            if not should_verify_cancel_result(submit_error):
                raise
            last_error: Exception = submit_error
            consecutive_absent = 0
            for attempt, delay in enumerate((0.0, *ALGO_VISIBILITY_RETRY_DELAYS_SECONDS)):
                if delay:
                    time.sleep(delay)
                try:
                    rows = self.list_open_algos(inst_id=inst_id)
                    if not any(str(row.get("algoId") or "") == current_algo_id for row in rows):
                        consecutive_absent += 1
                        if consecutive_absent >= 2:
                            self.log.info(
                                "algo action=%s status=cancel_recovered inst_id=%s algo_id=%s",
                                action,
                                inst_id,
                                current_algo_id,
                            )
                            return current_algo_id
                        last_error = BinanceApiError(
                            f"条件单首次查询已消失，等待再次确认 algoId={current_algo_id}"
                        )
                    else:
                        consecutive_absent = 0
                        last_error = BinanceApiError(f"条件单仍在挂单中 algoId={current_algo_id}")
                except Exception as exc:  # noqa: BLE001
                    last_error = exc
                    consecutive_absent = 0
                if isinstance(last_error, BinanceApiError) and _is_rate_limit_error(
                    last_error.code,
                    str(last_error),
                ):
                    break
                if attempt < len(ALGO_VISIBILITY_RETRY_DELAYS_SECONDS):
                    self.log.info(
                        "algo action=%s status=cancel_verify_retry inst_id=%s algo_id=%s attempt=%s err=%s",
                        action,
                        inst_id,
                        current_algo_id,
                        attempt + 1,
                        last_error,
                    )
            raise BinanceApiError(
                "条件单撤销结果未确认，请稍后重试",
                code="ALGO_CANCEL_UNCONFIRMED",
            ) from submit_error

    def cancel_many(self, algo_ids: list[str], inst_id: str, *, action: str) -> None:
        for algo_id in algo_ids:
            if not algo_id:
                continue
            self.cancel_algo_confirmed(str(algo_id), inst_id, action=action)

    def _recover_algo_submit(
        self,
        *,
        client_algo_id: Optional[str],
        inst_id: str,
        expected_size: str,
        expected_side: str,
        expected_pos_side: Optional[str],
        expected_algo_type: str,
        action: str,
        submit_error: Exception,
    ) -> str:
        current_client_algo_id = str(client_algo_id or "").strip()
        if not current_client_algo_id:
            raise submit_error
        if not should_recover_write_by_client_id(submit_error):
            raise submit_error

        last_error: Exception = submit_error
        for attempt, delay in enumerate((0.0, *ALGO_VISIBILITY_RETRY_DELAYS_SECONDS)):
            if delay:
                time.sleep(delay)
            try:
                rows = self.list_open_algos(inst_id=inst_id)
                recovered = next(
                    (
                        row
                        for row in rows
                        if str(row.get("clientAlgoId") or "").strip() == current_client_algo_id
                    ),
                    None,
                )
                if recovered:
                    algo_id = str(recovered.get("algoId") or "").strip()
                    if not algo_id:
                        raise BinanceApiError("条件单恢复结果缺少algoId")
                    expected = abs(_d(expected_size or "0"))
                    actual = abs(_d(recovered.get("sz") or "0"))
                    if expected > 0 and abs(actual - expected) > Decimal("0.00000001"):
                        raise BinanceApiError(
                            "同一客户端标识对应的条件单数量不一致",
                            code="ALGO_CLIENT_ID_CONFLICT",
                        )
                    if str(recovered.get("side") or "").lower() != str(expected_side or "").lower():
                        raise BinanceApiError(
                            "同一客户端标识对应的条件单方向不一致",
                            code="ALGO_CLIENT_ID_CONFLICT",
                        )
                    if expected_pos_side and str(recovered.get("posSide") or "").lower() != str(
                        expected_pos_side
                    ).lower():
                        raise BinanceApiError(
                            "同一客户端标识对应的持仓方向不一致",
                            code="ALGO_CLIENT_ID_CONFLICT",
                        )
                    if str(recovered.get("algoType") or "").upper() != str(expected_algo_type or "").upper():
                        raise BinanceApiError(
                            "同一客户端标识对应的条件单类型不一致",
                            code="ALGO_CLIENT_ID_CONFLICT",
                        )
                    self.log.info(
                        "algo action=%s status=submit_recovered inst_id=%s algo_id=%s client_algo_id=%s",
                        action,
                        inst_id,
                        algo_id,
                        current_client_algo_id,
                    )
                    return algo_id
                last_error = BinanceApiError(
                    f"未查到条件单 clientAlgoId={current_client_algo_id}"
                )
            except Exception as exc:  # noqa: BLE001
                last_error = exc
            if isinstance(last_error, BinanceApiError) and last_error.code == "ALGO_CLIENT_ID_CONFLICT":
                raise last_error
            if isinstance(last_error, BinanceApiError) and _is_rate_limit_error(
                last_error.code,
                str(last_error),
            ):
                break
            if attempt < len(ALGO_VISIBILITY_RETRY_DELAYS_SECONDS):
                self.log.info(
                    "algo action=%s status=submit_recovery_retry inst_id=%s client_algo_id=%s attempt=%s err=%s",
                    action,
                    inst_id,
                    current_client_algo_id,
                    attempt + 1,
                    last_error,
                )
        raise submit_error

    def create_stop_loss(
        self,
        *,
        inst_id: str,
        side: str,
        size: str,
        stop_loss_price: str,
        pos_side: Optional[str],
        client_algo_id: Optional[str] = None,
        visibility_mode: str = ALGO_VISIBILITY_ALLOW_DELAYED,
        action: str = "create_stop_loss",
    ) -> str:
        try:
            payload = self.client.place_stop_loss_order(
                inst_id=inst_id,
                side=side,
                size=size,
                stop_loss_price=stop_loss_price,
                pos_side=pos_side,
                client_algo_id=client_algo_id,
            )
            submit_row = _parse_algo_submit_response(payload.get("data") or payload)
            algo_id = submit_row["algoId"]
        except Exception as exc:
            algo_id = self._recover_algo_submit(
                client_algo_id=client_algo_id,
                inst_id=inst_id,
                expected_size=size,
                expected_side=side,
                expected_pos_side=pos_side,
                expected_algo_type="STOP",
                action=action,
                submit_error=exc,
            )
        try:
            verify_rows = self._verify_algo_visibility(
                algo_id=algo_id,
                inst_id=inst_id,
                expected_size=size,
                visibility_mode=visibility_mode,
                action=action,
            )
        except Exception as verify_error:
            if (
                visibility_mode == ALGO_VISIBILITY_REQUIRE_VISIBLE
                and getattr(verify_error, "code", "") != "ALGO_NOT_LIVE"
            ):
                try:
                    self.cancel_algo_confirmed(algo_id, inst_id, action=f"{action}_rollback")
                except Exception as rollback_exc:  # noqa: BLE001
                    self.log.error(
                        "algo action=%s status=rollback_unconfirmed inst_id=%s algo_id=%s err=%s",
                        action,
                        inst_id,
                        algo_id,
                        safe_error_summary(rollback_exc),
                    )
            raise
        if visibility_mode == ALGO_VISIBILITY_REQUIRE_VISIBLE and not verify_rows:
            raise BinanceApiError("止损单创建后未查到挂单")
        self.log.info(
            "algo action=%s status=created inst_id=%s algo_id=%s visibility=%s",
            action,
            inst_id,
            algo_id,
            visibility_mode,
        )
        return algo_id

    def create_stop_market(
        self,
        *,
        inst_id: str,
        side: str,
        size: str,
        trigger_price: str,
        pos_side: Optional[str],
        client_algo_id: Optional[str] = None,
        visibility_mode: str = ALGO_VISIBILITY_ALLOW_DELAYED,
        action: str = "create_stop_market",
    ) -> str:
        try:
            payload = self.client.place_stop_market_order(
                inst_id=inst_id,
                side=side,
                size=size,
                trigger_price=trigger_price,
                pos_side=pos_side,
                client_algo_id=client_algo_id,
            )
            submit_row = _parse_algo_submit_response(payload.get("data") or payload)
            algo_id = submit_row["algoId"]
        except Exception as exc:
            algo_id = self._recover_algo_submit(
                client_algo_id=client_algo_id,
                inst_id=inst_id,
                expected_size=size,
                expected_side=side,
                expected_pos_side=pos_side,
                expected_algo_type="STOP_MARKET",
                action=action,
                submit_error=exc,
            )
        try:
            verify_rows = self._verify_algo_visibility(
                algo_id=algo_id,
                inst_id=inst_id,
                expected_size=size,
                visibility_mode=visibility_mode,
                action=action,
            )
        except Exception as verify_error:
            if (
                visibility_mode == ALGO_VISIBILITY_REQUIRE_VISIBLE
                and getattr(verify_error, "code", "") != "ALGO_NOT_LIVE"
            ):
                try:
                    self.cancel_algo_confirmed(algo_id, inst_id, action=f"{action}_rollback")
                except Exception as rollback_exc:  # noqa: BLE001
                    self.log.error(
                        "algo action=%s status=rollback_unconfirmed inst_id=%s algo_id=%s err=%s",
                        action,
                        inst_id,
                        algo_id,
                        safe_error_summary(rollback_exc),
                    )
            raise
        if visibility_mode == ALGO_VISIBILITY_REQUIRE_VISIBLE and not verify_rows:
            raise BinanceApiError("市价保护止损创建后未查到挂单")
        self.log.info(
            "algo action=%s status=created inst_id=%s algo_id=%s visibility=%s",
            action,
            inst_id,
            algo_id,
            visibility_mode,
        )
        return algo_id

    def create_take_profit(
        self,
        *,
        inst_id: str,
        side: str,
        size: str,
        trigger_price: str,
        pos_side: Optional[str],
        order_type: str = "market",
        client_algo_id: Optional[str] = None,
        visibility_mode: str = ALGO_VISIBILITY_ALLOW_DELAYED,
        action: str = "create_take_profit",
    ) -> str:
        try:
            payload = self.client.place_take_profit_order(
                inst_id=inst_id,
                side=side,
                size=size,
                trigger_price=trigger_price,
                pos_side=pos_side,
                order_type=order_type,
                client_algo_id=client_algo_id,
            )
            submit_row = _parse_algo_submit_response(payload.get("data") or payload)
            algo_id = submit_row["algoId"]
        except Exception as exc:
            algo_id = self._recover_algo_submit(
                client_algo_id=client_algo_id,
                inst_id=inst_id,
                expected_size=size,
                expected_side=side,
                expected_pos_side=pos_side,
                expected_algo_type=(
                    "TAKE_PROFIT"
                    if str(order_type or "").lower() == "limit"
                    else "TAKE_PROFIT_MARKET"
                ),
                action=action,
                submit_error=exc,
            )
        if visibility_mode == ALGO_VISIBILITY_REQUIRE_VISIBLE:
            try:
                self._verify_algo_visibility(
                    algo_id=algo_id,
                    inst_id=inst_id,
                    expected_size=size,
                    visibility_mode=visibility_mode,
                    action=action,
                )
            except Exception as verify_error:
                if getattr(verify_error, "code", "") != "ALGO_NOT_LIVE":
                    try:
                        self.cancel_algo_confirmed(algo_id, inst_id, action=f"{action}_rollback")
                    except Exception as rollback_exc:  # noqa: BLE001
                        self.log.error(
                            "algo action=%s status=rollback_unconfirmed inst_id=%s algo_id=%s err=%s",
                            action,
                            inst_id,
                            algo_id,
                            safe_error_summary(rollback_exc),
                        )
                raise
        self.log.info(
            "algo action=%s status=created inst_id=%s algo_id=%s",
            action,
            inst_id,
            algo_id,
        )
        return algo_id

    def move_stop_loss(
        self,
        *,
        algo_id: str,
        inst_id: str,
        stop_loss_price: str,
        visibility_mode: str = ALGO_VISIBILITY_REQUIRE_VISIBLE,
        action: str = "move_stop_loss",
    ) -> str:
        current = self.get_algo(algo_id=algo_id, inst_id=inst_id)
        replacement_client_id = f"mv{hashlib.sha256(f'{algo_id}:{stop_loss_price}'.encode()).hexdigest()[:30]}"
        new_algo_id = self.create_stop_loss(
            inst_id=inst_id,
            side=str(current.get("side") or ""),
            size=str(current.get("sz") or "0"),
            stop_loss_price=stop_loss_price,
            pos_side=str(current.get("posSide") or "") or None,
            client_algo_id=replacement_client_id,
            visibility_mode=ALGO_VISIBILITY_REQUIRE_VISIBLE,
            action=action,
        )
        self.cancel_algo_confirmed(algo_id, inst_id, action=f"{action}_cancel_previous")
        self.log.info(
            "algo action=%s status=moved inst_id=%s old_algo_id=%s new_algo_id=%s",
            action,
            inst_id,
            algo_id,
            new_algo_id,
        )
        return new_algo_id

    def _verify_algo_visibility(
        self,
        *,
        algo_id: str,
        inst_id: str,
        expected_size: str,
        visibility_mode: str,
        action: str,
    ) -> list[dict[str, Any]]:
        retry_delays = (
            ALGO_VISIBILITY_RETRY_DELAYS_SECONDS
            if visibility_mode == ALGO_VISIBILITY_REQUIRE_VISIBLE
            else ()
        )
        matched: list[dict[str, Any]] = []
        last_error: Optional[Exception] = None

        for attempt in range(len(retry_delays) + 1):
            if attempt > 0:
                time.sleep(retry_delays[attempt - 1])
            direct_row: Optional[dict[str, Any]] = None
            try:
                if algo_id:
                    direct_row = self.get_algo(algo_id=algo_id, inst_id=inst_id)
                    rows = [direct_row]
                else:
                    rows = self.list_open_algos(inst_id=inst_id)
                matched = [row for row in rows if self._is_live_algo(row, algo_id)]
                if matched:
                    break
                if direct_row is not None:
                    raise BinanceApiError(
                        f"条件单已不在挂单状态 algoId={algo_id}",
                        code="ALGO_NOT_LIVE",
                    )
                last_error = BinanceApiError(f"未查到条件单 algoId={algo_id}")
            except Exception as exc:  # noqa: BLE001
                last_error = exc

            if isinstance(last_error, BinanceApiError) and last_error.code == "ALGO_NOT_LIVE":
                raise last_error

            # Binance may acknowledge a new algo order before the single-order
            # endpoint can see it. Cross-check the live list in the same attempt.
            if algo_id and not (
                isinstance(last_error, BinanceApiError)
                and (
                    last_error.code == "ALGO_NOT_LIVE"
                    or _is_rate_limit_error(last_error.code, str(last_error))
                )
            ):
                try:
                    matched = [
                        row
                        for row in self.list_open_algos(inst_id=inst_id)
                        if self._is_live_algo(row, algo_id)
                    ]
                    if matched:
                        break
                except Exception as exc:  # noqa: BLE001
                    last_error = exc

            if visibility_mode == ALGO_VISIBILITY_ALLOW_DELAYED:
                self.log.info(
                    "algo action=%s status=verify_delayed inst_id=%s algo_id=%s err=%s",
                    action,
                    inst_id,
                    algo_id,
                    last_error,
                )
                return []
            if isinstance(last_error, BinanceApiError) and _is_rate_limit_error(
                last_error.code,
                str(last_error),
            ):
                break
            if attempt < len(retry_delays):
                self.log.info(
                    "algo action=%s status=verify_retry inst_id=%s algo_id=%s attempt=%s delay=%s err=%s",
                    action,
                    inst_id,
                    algo_id,
                    attempt + 1,
                    retry_delays[attempt],
                    last_error,
                )

        if not matched:
            raise BinanceApiError(
                "条件单创建后未查到挂单",
                code="ALGO_VISIBILITY_TIMEOUT",
            ) from last_error

        expected = abs(_d(expected_size or "0"))
        actual = abs(_d((matched[0] or {}).get("sz") or "0"))
        if expected > 0 and abs(actual - expected) > Decimal("0.00000001"):
            try:
                self.cancel_algo_confirmed(algo_id, inst_id, action=f"{action}_rollback")
            except Exception as exc:  # noqa: BLE001
                raise BinanceApiError("条件单数量与预期不一致，回滚结果未确认") from exc
            raise BinanceApiError("条件单数量与预期不一致，已撤销")
        return matched

    @staticmethod
    def _is_live_algo(row: dict[str, Any], algo_id: str) -> bool:
        return (
            str((row or {}).get("algoId") or "") == str(algo_id)
            and str((row or {}).get("state") or "live").lower() == "live"
        )


_public_session_lock = threading.Lock()
_public_session: Optional[Any] = None


def _get_public_session() -> Optional[Any]:
    """复用与币安的长连接，避免每次请求重新做 TCP/TLS 握手。"""
    global _public_session
    if requests is None:
        return None
    if _public_session is None:
        with _public_session_lock:
            if _public_session is None:
                _public_session = _build_requests_session(pool_connections=4, pool_maxsize=8)
    return _public_session


def _public_json_request(
    path: str,
    query: Optional[dict[str, Any]] = None,
    *,
    timeout_seconds: Optional[float] = None,
) -> Any:
    budget_spec = classify_request(
        method="GET",
        path=path,
        base_url=_base_url(),
        query=query,
    )
    _raise_if_rate_limit_cooldown(budget_spec.scope)
    _track_binance_outbound(path)
    try:
        reserve_request_budget(budget_spec)
    except RequestBudgetExceeded as exc:
        raise BinanceApiError(
            f"Binance 请求预算保护中，约 {exc.retry_after} 秒后恢复，请稍后再试",
            code="LOCAL_RATE_BUDGET",
        ) from exc
    query_string = _qs(query)
    url = f"{_base_url()}{path}"
    if query_string:
        url = f"{url}?{query_string}"
    headers = {
        "Content-Type": "application/json",
        "User-Agent": "riskon-server/1.0",
    }
    response_headers = None

    timeout = float(timeout_seconds if timeout_seconds is not None else _timeout_seconds())

    session = _get_public_session()
    if session is not None:
        try:
            resp = session.get(url, headers=headers, timeout=timeout)
        except Exception as exc:  # noqa: BLE001
            raise BinanceApiError(f"连接 {_environment_label()} 失败，请稍后重试") from exc
        payload_text = resp.text or ""
        status_code = int(getattr(resp, "status_code", 500))
        response_headers = getattr(resp, "headers", None)
        _record_binance_used_weight(response_headers)
    else:
        req = request.Request(url=url, headers=headers, method="GET")
        status_code = 200
        try:
            with request.urlopen(req, timeout=timeout) as resp:
                status_code = getattr(resp, "status", 200)
                payload_text = resp.read().decode("utf-8")
                response_headers = getattr(resp, "headers", None)
                _record_binance_used_weight(response_headers)
        except error.HTTPError as http_err:
            status_code = int(getattr(http_err, "code", 500))
            payload_text = http_err.read().decode("utf-8", errors="ignore")
            response_headers = getattr(http_err, "headers", None)
            _record_binance_used_weight(response_headers)
        except Exception as exc:  # noqa: BLE001
            raise BinanceApiError(f"连接 {_environment_label()} 失败，请稍后重试") from exc

    if status_code in (418, 429):
        message = _http_rate_limit_message(payload_text, status_code)
        mark_rate_limit_cooldown(message, response_headers, scope=budget_spec.scope)
        raise BinanceApiError(message, code=str(status_code))

    try:
        payload = json.loads(payload_text)
    except ValueError as exc:
        raise BinanceApiError(f"Binance 返回了无效响应，请稍后重试 (http: {status_code})") from exc

    if isinstance(payload, dict) and payload.get("code") not in (None, 0, "0"):
        code = str(payload.get("code") or "")
        message = str(payload.get("msg") or "Binance 请求失败")
        if _is_rate_limit_error(code, message, status_code=status_code):
            mark_rate_limit_cooldown(message, response_headers, scope=budget_spec.scope)
        raise BinanceApiError(message, code=code)
    if status_code >= 400:
        message = str(payload.get("msg") or "") if isinstance(payload, dict) else ""
        code = str(payload.get("code") or status_code) if isinstance(payload, dict) else str(status_code)
        if _is_rate_limit_error(code, message, status_code=status_code):
            mark_rate_limit_cooldown(message, response_headers, scope=budget_spec.scope)
        raise BinanceApiError(message or f"Binance 请求失败 (http: {status_code})", code=code)
    return payload


class BinanceFuturesClient:
    def __init__(self, credentials: BinanceCredentials):
        self.credentials = credentials
        self.base_url = _base_url()
        self.timeout_seconds = _timeout_seconds()
        self.recv_window = _recv_window()

    def _sign(self, params: dict[str, Any]) -> str:
        query_string = _qs(params)
        return hmac.new(
            self.credentials.secret_key.encode("utf-8"),
            query_string.encode("utf-8"),
            hashlib.sha256,
        ).hexdigest()

    def _observe_private_request_result(self, error: Optional[Exception]) -> None:
        observer = getattr(self.credentials, "result_observer", None)
        if not callable(observer):
            return
        try:
            observer(error)
        except Exception as observer_error:  # noqa: BLE001
            logger.warning(
                "binance_binding_health_observer_failed err=%s",
                safe_error_summary(observer_error),
            )

    def _reserve_budget(
        self,
        *,
        method: str,
        path: str,
        base_url: str,
        query: Optional[dict[str, Any]],
        signed: bool,
        priority: RequestPriority | str | None,
        require_shared: bool = False,
    ):
        budget_spec = classify_request(
            method=method,
            path=path,
            base_url=base_url,
            query=query,
            priority=priority,
        )
        try:
            reserve_request_budget(
                budget_spec,
                account_api_key=self.credentials.api_key if signed else "",
                lead_trading=self.credentials.trading_mode == "lead",
                **({"require_shared": True} if require_shared else {}),
            )
        except RequestBudgetExceeded as exc:
            raise BinanceApiError(
                f"Binance 请求预算保护中，约 {exc.retry_after} 秒后恢复，请稍后再试",
                code="LOCAL_RATE_BUDGET",
                account_rate_limited=exc.scope in {"orders", "lead-orders"},
            ) from exc
        return budget_spec

    def _build_request_target(
        self,
        *,
        path: str,
        base_url: str,
        query: Optional[dict[str, Any]],
        signed: bool,
    ) -> tuple[str, dict[str, str]]:
        params = dict(query or {})
        if signed:
            params["timestamp"] = int(time.time() * 1000)
            params["recvWindow"] = self.recv_window
            params["signature"] = self._sign(params)
        query_string = _qs(params)
        url = f"{base_url}{path}"
        if query_string:
            url = f"{url}?{query_string}"
        headers = {
            "Content-Type": "application/json",
            "User-Agent": "riskon-server/1.0",
        }
        if signed or path == "/fapi/v1/listenKey":
            headers["X-MBX-APIKEY"] = self.credentials.api_key
        return url, headers

    @staticmethod
    def _decode_http_payload(response: _HttpResponseData, *, is_write_request: bool) -> Any:
        try:
            return json.loads(response.payload_text)
        except ValueError as exc:
            if response.status_code in (401, 403):
                raise BinanceApiError(
                    "Binance 拒绝访问，请检查 API Key、Secret Key 与 IP 白名单"
                ) from exc
            raise BinanceApiError(
                f"Binance 返回了无效响应，请稍后重试 (http: {response.status_code})",
                outcome_unknown=is_write_request,
            ) from exc

    def _validate_http_payload(
        self,
        payload: Any,
        *,
        response: _HttpResponseData,
        method: str,
        path: str,
        query: Optional[dict[str, Any]],
        is_write_request: bool,
        scope: str,
    ) -> Any:
        if (
            method == "GET"
            and path == "/sapi/v1/pay/transactions"
            and isinstance(payload, dict)
            and payload.get("code") == "000000"
            and payload.get("success") is True
            and 200 <= response.status_code < 300
        ):
            return payload
        if path.startswith("/sapi/v1/copyTrading/futures/") and isinstance(payload, dict) and payload.get("code") == "000000" and response.status_code < 400 and payload.get("success") is not False:
            return payload
        if isinstance(payload, dict) and payload.get("code") not in (None, 0, "0"):
            code = str(payload.get("code"))
            message = str(payload.get("msg") or "")
            normalized_message = message.strip().lower()
            if code == "200" and normalized_message in {
                "success",
                "the operation of cancel all open order is done.",
            }:
                return payload
            if _is_rate_limit_error(code, message, status_code=response.status_code):
                self._log_rate_limit_response(
                    method=method,
                    path=path,
                    query=query,
                    code=code,
                    message=message,
                    response=response,
                    scope=scope,
                )
            raise BinanceApiError(
                self._map_exchange_error(code, message or "Binance 请求失败"),
                code=code,
                outcome_unknown=(
                    is_write_request
                    and (
                        response.status_code >= 500
                        or code in UNKNOWN_WRITE_RESULT_CODES
                        or _is_rate_limit_error(code, message, status_code=response.status_code)
                    )
                ),
            )
        if response.status_code >= 400:
            message = str((payload or {}).get("msg") or "") if isinstance(payload, dict) else ""
            raise BinanceApiError(
                self._map_exchange_error(
                    str(response.status_code),
                    message or f"Binance 请求失败 (http: {response.status_code})",
                ),
                code=str(response.status_code),
                outcome_unknown=is_write_request and response.status_code >= 500,
            )
        return payload

    def _log_rate_limit_response(
        self,
        *,
        method: str,
        path: str,
        query: Optional[dict[str, Any]],
        code: str,
        message: str,
        response: _HttpResponseData,
        scope: str,
    ) -> None:
        reported_ip = _extract_ip_from_text(message)
        observed_egress_ip = detect_public_egress_ip()
        logger.warning(
            "binance_rate_limit method=%s path=%s code=%s http_status=%s query=%s reported_ip=%s observed_egress_ip=%s msg=%s",
            method,
            path,
            code,
            response.status_code,
            _safe_query_for_log(query),
            reported_ip,
            observed_egress_ip,
            message,
        )
        cooldown_scope = self._account_order_scope(scope) if code == "-1015" else scope
        mark_rate_limit_cooldown(message, response.headers, scope=cooldown_scope)

    def _account_order_scope(self, scope: str) -> str:
        fingerprint = hashlib.sha256(self.credentials.api_key.encode()).hexdigest()[:24]
        return f"{scope}:orders:{fingerprint}"

    def _request(
        self,
        method: str,
        path: str,
        query: Optional[dict[str, Any]] = None,
        signed: bool = True,
        base_url: Optional[str] = None,
        budget_priority: RequestPriority | str | None = None,
        require_shared_budget: bool = False,
    ) -> Any:
        normalized_method = method.upper()
        if self.credentials.trading_mode == "lead" and signed and not (
            path.startswith("/fapi/") or path.startswith("/sapi/v1/copyTrading/futures/")
        ):
            raise BinanceApiError("带单 API 仅用于合约交易，资金操作请在币安“我的带单”页面完成")
        request_base_url = (base_url or self.base_url).rstrip("/")
        scope = request_scope(request_base_url, path)
        _raise_if_rate_limit_cooldown(scope)
        if signed and is_exchange_mutation(normalized_method, path):
            _raise_if_rate_limit_cooldown(self._account_order_scope(scope), account_rate_limited=True)
        _track_binance_outbound(path)
        is_write_request = is_exchange_mutation(normalized_method, path)
        budget_spec = self._reserve_budget(
            method=normalized_method,
            path=path,
            base_url=request_base_url,
            query=query,
            signed=signed,
            priority=budget_priority,
            require_shared=require_shared_budget,
        )
        url, headers = self._build_request_target(
            path=path,
            base_url=request_base_url,
            query=query,
            signed=signed,
        )
        response = _perform_http_request(
            method=normalized_method,
            url=url,
            headers=headers,
            timeout=self.timeout_seconds,
            outcome_unknown_on_failure=is_write_request,
        )
        _record_binance_used_weight(
            response.headers,
            scope=budget_spec.scope,
            account_api_key=self.credentials.api_key if signed else "",
            lead_trading=self.credentials.trading_mode == "lead",
            account_weight=budget_spec.account_weight,
        )
        try:
            if response.status_code in (418, 429):
                # Only an explicit order-limit code proves account scope. An
                # unknown 429 or an IP ban still stops the shared IP budget.
                try:
                    throttle_payload = json.loads(response.payload_text)
                except (TypeError, ValueError):
                    throttle_payload = None
                throttle_code = (
                    "-1015" if response.status_code == 429
                    and isinstance(throttle_payload, dict)
                    and str(throttle_payload.get("code")) == "-1015"
                    else str(response.status_code)
                )
                message = _http_rate_limit_message(
                    response.payload_text,
                    response.status_code,
                )
                self._log_rate_limit_response(
                    method=normalized_method,
                    path=path,
                    query=query,
                    code=throttle_code,
                    message=message,
                    response=response,
                    scope=scope,
                )
                raise BinanceApiError(
                    self._map_exchange_error(throttle_code, message),
                    code=throttle_code,
                    outcome_unknown=is_write_request,
                )
            payload = self._decode_http_payload(response, is_write_request=is_write_request)
            payload = self._validate_http_payload(
                payload,
                response=response,
                method=normalized_method,
                path=path,
                query=query,
                is_write_request=is_write_request,
                scope=scope,
            )
        except BinanceApiError as exchange_error:
            if signed:
                self._observe_private_request_result(exchange_error)
            raise
        if signed:
            self._observe_private_request_result(None)
        return payload

    def _get_public_instrument(self, inst_id: str) -> dict[str, Any]:
        payload = self.get_instruments(inst_type="SWAP")
        rows = payload.get("data") or []
        instrument = next((row for row in rows if str(row.get("instId") or "") == inst_id), None)
        if not instrument:
            raise BinanceApiError("未找到币安合约规则，请确认交易对是否为 USDT 永续")
        return instrument

    def _normalize_order_quantity(self, inst_id: str, quantity: str, order_type: str) -> str:
        instrument = self._get_public_instrument(inst_id)
        normalized = normalize_quantity(_d(quantity), instrument, order_type)
        return _fmt(normalized)

    def _normalize_order_price(
        self,
        inst_id: str,
        price: str,
        *,
        price_kind: str = "limit",
        side: str = "",
        position_side: str = "",
    ) -> str:
        instrument = self._get_public_instrument(inst_id)
        raw_price = _d(price)
        if price_kind == "stop_trigger":
            normalized = normalize_stop_trigger_price(raw_price, instrument, position_side)
        elif price_kind == "take_profit_trigger":
            normalized = normalize_take_profit_trigger_price(raw_price, instrument, position_side)
        else:
            normalized = normalize_limit_price(raw_price, instrument, side)
        return _fmt(normalized)

    def get_leverage_bracket(self, inst_id: str) -> dict[str, Any]:
        symbol = _exchange_symbol(inst_id)
        payload = self._request(
            "GET",
            "/fapi/v1/leverageBracket",
            {"symbol": symbol},
            signed=True,
        )
        rows = payload if isinstance(payload, list) else [payload]
        result = []
        for row in rows:
            brackets = row.get("brackets") or []
            initial_leverage = str(_default_max_leverage())
            if brackets:
                initial_leverage = str((brackets[0] or {}).get("initialLeverage") or initial_leverage)
            result.append(
                {
                    "instId": to_inst_id(str(row.get("symbol") or symbol)),
                    "maxLever": initial_leverage,
                    "lever": initial_leverage,
                    "notionalCap": str((brackets[0] or {}).get("notionalCap") or "0") if brackets else "0",
                    "brackets": [
                        {"initialLeverage": str(item.get("initialLeverage") or "0"),
                         "notionalCap": str(item.get("notionalCap") or "0"),
                         "notionalFloor": str(item.get("notionalFloor") or "0")}
                        for item in brackets if isinstance(item, dict)
                    ],
                }
            )
        return _ok(result)

    def _map_exchange_error(self, code: str, default: str) -> str:
        mapped = {
            "1": default or "下单失败，请稍后重试",
            "50115": "请求过于频繁，请稍后重试",
            "-1003": "Binance 请求过于频繁，系统已暂停查询，请稍后再试",
            "418": "Binance 请求过于频繁，系统已暂停查询，请稍后再试",
            "429": "Binance 请求过于频繁，系统已暂停查询，请稍后再试",
            "50114": "请求时间戳异常，请稍后重试",
            "50110": "API Key 无效或不存在，请检查 API Key",
            "50113": "Secret Key 错误（签名失败），请检查 Secret Key",
            "50119": "API Key / Secret Key 组合不匹配，请检查 Binance API 配置",
            "-1021": "请求时间戳异常，请稍后重试",
            "-1022": "签名校验失败，请检查 Secret Key",
            "-1102": "请求参数不完整，请检查下单参数",
            "-1111": "下单精度不符合 Binance 规则，请检查价格和数量精度",
            "-4003": "下单数量不合法，请检查数量参数",
            "-4014": "价格不符合 Binance 最小变动单位，请按交易规则调整价格",
            "-4023": "下单数量不符合 Binance 步长规则，请按交易规则调整数量",
            "-2014": "API Key 格式错误，请检查 API Key",
            "-2015": "API Key、Secret Key 或 IP 白名单配置错误，请检查 Binance API 设置",
            "-2019": "账户保证金不足，无法下单",
            "-2021": "止损或止盈触发价不合法，请检查触发价格",
            "-2022": "ReduceOnly / 平仓参数不合法，请稍后重试",
            "-4046": "当前持仓模式与下单参数不匹配，请检查单向/双向持仓设置",
            "-4164": "当前杠杆或名义价值超过限制，请降低杠杆或仓位",
            "-5029": "触发保护限制不满足，请等待标记价格与成交价格偏差收敛后再提交条件单",
        }
        return mapped.get(code, default or f"Binance 请求失败 (code: {code})")

    def get_account_config(
        self,
        *,
        fresh: bool = False,
        budget_priority: RequestPriority | str | None = None,
    ) -> dict[str, Any]:
        # posMode 几乎永不变：缓存 10 分钟，避免每条查询路径重复发 accountConfig+balance 两个请求
        backend = _shared_cache_backend()
        cache_key = _account_config_cache_key(self.credentials.api_key)
        if not fresh and backend is not None:
            try:
                cached = backend.get(cache_key)
            except Exception:  # noqa: BLE001
                cached = None
            if isinstance(cached, dict):
                return cached
        account_config = self._request(
            "GET",
            "/fapi/v1/accountConfig",
            signed=True,
            budget_priority=budget_priority,
        )
        balances = self._request(
            "GET",
            "/fapi/v3/balance",
            signed=True,
            budget_priority=budget_priority,
        )
        balance_rows = balances if isinstance(balances, list) else balances.get("data") or []
        account_alias = ""
        if balance_rows:
            account_alias = str((balance_rows[0] or {}).get("accountAlias") or "")

        row = {
            "perm": "trade" if bool(account_config.get("canTrade", True)) else "read_only",
            "label": _environment_label(),
            "uid": account_alias,
            "posMode": _legacy_pos_mode(bool(account_config.get("dualSidePosition"))),
            "multiAssetsMargin": account_config.get("multiAssetsMargin"),
            "canTrade": account_config.get("canTrade"),
        }
        result = _ok([row])
        if backend is not None:
            try:
                backend.set(cache_key, result, timeout=ACCOUNT_CONFIG_CACHE_TTL_SECONDS)
            except Exception:  # noqa: BLE001
                pass
        return result

    def _copy_trading_data(self, path: str):
        payload = self._request("GET", path, signed=True, base_url=_spot_base_url())
        if not isinstance(payload, dict) or payload.get("code") != "000000" or payload.get("success") is False:
            raise BinanceApiError("带单接口未返回明确成功状态，请稍后重试")
        return payload.get("data")

    def get_lead_trader_status(self) -> bool:
        data = self._copy_trading_data("/sapi/v1/copyTrading/futures/userStatus")
        if not isinstance(data, dict) or type(data.get("isLeadTrader")) is not bool:
            raise BinanceApiError("带单身份返回格式异常，请稍后重试")
        return data["isLeadTrader"]

    def get_lead_symbols(self) -> list[str]:
        data = self._copy_trading_data("/sapi/v1/copyTrading/futures/leadSymbol")
        if not isinstance(data, list) or any(not isinstance(row, dict) or not row.get("symbol") or not row.get("quoteAsset") for row in data):
            raise BinanceApiError("带单交易白名单返回格式异常，请稍后重试")
        return [str(row["symbol"]) for row in data if row["quoteAsset"] == "USDT" and str(row["symbol"]).endswith("USDT")]

    def get_balance(self, ccy: str = "USDT", *, fresh: bool = False) -> dict[str, Any]:
        backend = _shared_cache_backend()
        target = str(ccy or "USDT").upper()
        key_digest = hashlib.sha256(str(self.credentials.api_key or "").encode("utf-8")).hexdigest()[:16]
        cache_key = f"trade:binance:futures-balance:{key_digest}:{target}"
        if not fresh and backend is not None:
            try:
                cached = backend.get(cache_key)
            except Exception:  # noqa: BLE001
                cached = None
            if isinstance(cached, dict):
                return cached
        payload = self._request("GET", "/fapi/v3/balance", signed=True)
        raw_assets = payload if isinstance(payload, list) else (
            payload.get("data") if isinstance(payload, dict) else None
        )
        assets = _require_balance_rows(raw_assets, source="合约账户")
        rows: list[dict[str, Any]] = []
        for asset in assets:
            if str(asset.get("asset") or "").upper() != target:
                continue
            balance = str(asset.get("balance") or asset.get("walletBalance") or "0")
            available_balance = str(asset.get("availableBalance") or "0")
            rows.append(
                {
                    "ccy": asset.get("asset"),
                    "totalEq": balance,
                    "details": [
                        {
                            "eq": balance,
                            "cashBal": balance,
                            "availEq": available_balance,
                        }
                    ],
                }
            )
        result = _ok(rows)
        if backend is not None:
            try:
                backend.set(cache_key, result, timeout=FUTURES_BALANCE_CACHE_TTL_SECONDS)
            except Exception:  # noqa: BLE001
                pass
        return result

    SPOT_BALANCE_CACHE_TTL_SECONDS = 30

    def get_spot_usdt_balance(self, ccy: str = "USDT", *, fresh: bool = False) -> str:
        """现货钱包 USDT 余额（free + locked）。

        走币安现货域名的签名接口 /api/v3/account（现货无独立 balance 端点，
        余额在 account 的 balances 数组里）；现货与合约的 IP 限频额度互相独立，
        且结果缓存 30 秒。
        """
        backend = _shared_cache_backend()
        key_digest = hashlib.sha256(str(self.credentials.api_key or "").encode("utf-8")).hexdigest()[:16]
        cache_key = f"trade:binance:spot-balance:{key_digest}:{str(ccy or 'USDT').upper()}"
        if not fresh and backend is not None:
            try:
                cached = backend.get(cache_key)
            except Exception:  # noqa: BLE001
                cached = None
            if isinstance(cached, str):
                return cached
        payload = self._request("GET", "/api/v3/account", signed=True, base_url=_spot_base_url())
        rows = _require_balance_rows(
            payload.get("balances") if isinstance(payload, dict) else None,
            source="现货账户",
        )
        target = str(ccy or "USDT").upper()
        total = Decimal("0")
        for row in rows or []:
            if str(row.get("asset") or "").upper() != target:
                continue
            total = _d(row.get("free") or "0") + _d(row.get("locked") or "0")
            break
        result = _fmt(total)
        if backend is not None:
            try:
                backend.set(cache_key, result, timeout=self.SPOT_BALANCE_CACHE_TTL_SECONDS)
            except Exception:  # noqa: BLE001
                pass
        return result

    def get_funding_usdt_balance(self, ccy: str = "USDT", *, fresh: bool = False) -> str:
        """资金账户 USDT 余额（free + locked + freeze），同样缓存 30 秒。"""
        backend = _shared_cache_backend()
        key_digest = hashlib.sha256(str(self.credentials.api_key or "").encode("utf-8")).hexdigest()[:16]
        cache_key = f"trade:binance:funding-balance:{key_digest}:{str(ccy or 'USDT').upper()}"
        if not fresh and backend is not None:
            try:
                cached = backend.get(cache_key)
            except Exception:  # noqa: BLE001
                cached = None
            if isinstance(cached, str):
                return cached
        payload = self._request(
            "POST",
            "/sapi/v1/asset/get-funding-asset",
            {"asset": str(ccy or "USDT").upper()},
            signed=True,
            base_url=_spot_base_url(),
        )
        rows = _require_balance_rows(payload, source="资金账户")
        target = str(ccy or "USDT").upper()
        total = Decimal("0")
        for row in rows:
            if str(row.get("asset") or "").upper() != target:
                continue
            total = _d(row.get("free") or "0") + _d(row.get("locked") or "0") + _d(row.get("freeze") or "0")
            break
        result = _fmt(total)
        if backend is not None:
            try:
                backend.set(cache_key, result, timeout=self.SPOT_BALANCE_CACHE_TTL_SECONDS)
            except Exception:  # noqa: BLE001
                pass
        return result

    def get_funding_usdt_free_balance(self, ccy: str = "USDT", *, fresh: bool = False) -> str:
        """Return only transferable funding-wallet balance."""
        backend = _shared_cache_backend()
        target = str(ccy or "USDT").upper()
        key_digest = hashlib.sha256(str(self.credentials.api_key or "").encode("utf-8")).hexdigest()[:16]
        cache_key = f"trade:binance:funding-free-balance:{key_digest}:{target}"
        if not fresh and backend is not None:
            try:
                cached = backend.get(cache_key)
            except Exception:  # noqa: BLE001
                cached = None
            if isinstance(cached, str):
                return cached
        payload = self._request(
            "POST",
            "/sapi/v1/asset/get-funding-asset",
            {"asset": target},
            signed=True,
            base_url=_spot_base_url(),
        )
        rows = _require_balance_rows(payload, source="资金账户")
        free = next(
            (_d(row.get("free") or "0") for row in rows if str(row.get("asset") or "").upper() == target),
            Decimal("0"),
        )
        result = _fmt(free)
        if backend is not None:
            try:
                backend.set(cache_key, result, timeout=self.SPOT_BALANCE_CACHE_TTL_SECONDS)
            except Exception:  # noqa: BLE001
                pass
        return result

    def get_spot_usdt_free_balance(self, ccy: str = "USDT", *, fresh: bool = False) -> str:
        """现货钱包可用（free）余额，用于划转决策；同样缓存 30 秒。
        与 get_spot_usdt_balance 的区别：不含 locked（locked 部分无法划转）。"""
        backend = _shared_cache_backend()
        key_digest = hashlib.sha256(str(self.credentials.api_key or "").encode("utf-8")).hexdigest()[:16]
        cache_key = f"trade:binance:spot-free-balance:{key_digest}:{str(ccy or 'USDT').upper()}"
        if not fresh and backend is not None:
            try:
                cached = backend.get(cache_key)
            except Exception:  # noqa: BLE001
                cached = None
            if isinstance(cached, str):
                return cached
        payload = self._request("GET", "/api/v3/account", signed=True, base_url=_spot_base_url())
        rows = _require_balance_rows(
            payload.get("balances") if isinstance(payload, dict) else None,
            source="现货账户",
        )
        target = str(ccy or "USDT").upper()
        free = Decimal("0")
        for row in rows or []:
            if str(row.get("asset") or "").upper() != target:
                continue
            free = _d(row.get("free") or "0")
            break
        result = _fmt(free)
        if backend is not None:
            try:
                backend.set(cache_key, result, timeout=self.SPOT_BALANCE_CACHE_TTL_SECONDS)
            except Exception:
                pass
        return result

    def _invalidate_wallet_balance_cache(self, ccy: str = "USDT") -> None:
        backend = _shared_cache_backend()
        if backend is None:
            return
        target = str(ccy or "USDT").upper()
        key_digest = hashlib.sha256(str(self.credentials.api_key or "").encode("utf-8")).hexdigest()[:16]
        for prefix in (
            "futures-balance",
            "spot-balance",
            "spot-free-balance",
            "funding-balance",
            "funding-free-balance",
        ):
            try:
                backend.delete(f"trade:binance:{prefix}:{key_digest}:{target}")
            except Exception:  # noqa: BLE001
                pass

    def transfer_between_spot_and_futures(
        self,
        amount: str,
        *,
        to_futures: bool,
        ccy: str = "USDT",
    ) -> str:
        """现货 ↔ USDT 本位合约账户内部划转（免费、即时）。
        to_futures=True 为现货→合约（type=1），否则合约→现货（type=2）。
        只能划转可用部分：交易所会拒绝超出可用余额的划转，因此不会动到持仓占用的保证金。
        返回交易所划转流水号 tranId。"""
        transfer_type = 1 if to_futures else 2
        payload = self._request(
            "POST",
            "/sapi/v1/futures/transfer",
            {
                "asset": str(ccy or "USDT").upper(),
                "amount": _fmt(_d(amount)),
                "type": transfer_type,
            },
            signed=True,
            base_url=_spot_base_url(),
        )
        tran_id = str(payload.get("tranId") or "") if isinstance(payload, dict) else ""
        if not tran_id:
            raise BinanceApiError("钱包划转未返回流水号，结果无法确认", outcome_unknown=True)
        self._invalidate_wallet_balance_cache(ccy)
        return tran_id

    def get_spot_futures_transfer_history(
        self,
        *,
        ccy: str = "USDT",
        start_time_ms: Optional[int] = None,
        end_time_ms: Optional[int] = None,
    ) -> list[dict[str, Any]]:
        """Query Spot/Futures wallet transfers for uncertain-result reconciliation."""
        query: dict[str, Any] = {
            "asset": str(ccy or "USDT").upper(),
            "current": 1,
            "size": 100,
        }
        if start_time_ms is not None:
            query["startTime"] = max(0, int(start_time_ms))
        if end_time_ms is not None:
            query["endTime"] = max(0, int(end_time_ms))
        payload = self._request(
            "GET",
            "/sapi/v1/futures/transfer",
            query,
            signed=True,
            base_url=_spot_base_url(),
        )
        return payload.get("rows") or [] if isinstance(payload, dict) else []

    def transfer_from_funding(self, amount: str, *, ccy: str = "USDT") -> str:
        """Allow only Funding -> USD-M Futures universal transfers."""
        payload = self._request(
            "POST",
            "/sapi/v1/asset/transfer",
            {
                "type": "FUNDING_UMFUTURE",
                "asset": str(ccy or "USDT").upper(),
                "amount": _fmt(_d(amount)),
            },
            signed=True,
            base_url=_spot_base_url(),
        )
        tran_id = str(payload.get("tranId") or "") if isinstance(payload, dict) else ""
        if not tran_id:
            raise BinanceApiError("资金账户划转未返回流水号，结果无法确认", outcome_unknown=True)
        self._invalidate_wallet_balance_cache(ccy)
        return tran_id

    def transfer_funding_to_spot(self, amount: str, *, ccy: str = "USDT") -> str:
        """Transfer Funding wallet assets into Spot before sub-to-master collection."""
        payload = self._request(
            "POST",
            "/sapi/v1/asset/transfer",
            {
                "type": "FUNDING_MAIN",
                "asset": str(ccy or "USDT").upper(),
                "amount": _fmt(_d(amount)),
            },
            signed=True,
            base_url=_spot_base_url(),
        )
        tran_id = str(payload.get("tranId") or "") if isinstance(payload, dict) else ""
        if not tran_id:
            raise BinanceApiError("资金转现货未返回流水号，结果无法确认", outcome_unknown=True)
        self._invalidate_wallet_balance_cache(ccy)
        return tran_id

    def get_universal_transfer_history(
        self,
        *,
        transfer_type: str,
        start_time_ms: Optional[int] = None,
        end_time_ms: Optional[int] = None,
    ) -> list[dict[str, Any]]:
        query: dict[str, Any] = {"type": str(transfer_type), "current": 1, "size": 100}
        if start_time_ms is not None:
            query["startTime"] = max(0, int(start_time_ms))
        if end_time_ms is not None:
            query["endTime"] = max(0, int(end_time_ms))
        payload = self._request(
            "GET", "/sapi/v1/asset/transfer", query, signed=True, base_url=_spot_base_url()
        )
        return payload.get("rows") or [] if isinstance(payload, dict) else []

    def transfer_spot_to_master(self, amount: str, *, ccy: str = "USDT") -> str:
        """Transfer sub-account Spot assets only to its owning master account."""
        payload = self._request(
            "POST",
            "/sapi/v1/sub-account/transfer/subToMaster",
            {
                "asset": str(ccy or "USDT").upper(),
                "amount": _fmt(_d(amount)),
            },
            signed=True,
            base_url=_spot_base_url(),
        )
        txn_id = str(payload.get("txnId") or payload.get("tranId") or "") if isinstance(payload, dict) else ""
        if not txn_id:
            raise BinanceApiError("子账户归集未返回流水号，结果无法确认", outcome_unknown=True)
        self._invalidate_wallet_balance_cache(ccy)
        return txn_id

    def get_sub_account_transfer_history(
        self,
        *,
        ccy: str = "USDT",
        start_time_ms: Optional[int] = None,
        transfer_type: int = 2,
        end_time_ms: Optional[int] = None,
        limit: Optional[int] = None,
    ) -> list[dict[str, Any]]:
        """Query sub-account transfers, defaulting to outgoing for reconciliation."""
        query: dict[str, Any] = {
            "asset": str(ccy or "USDT").upper(),
            "type": int(transfer_type),
        }
        if start_time_ms is not None:
            query["startTime"] = max(0, int(start_time_ms))
        if end_time_ms is not None:
            query["endTime"] = max(0, int(end_time_ms))
        if limit is not None:
            query["limit"] = max(1, min(200, int(limit)))
        payload = self._request(
            "GET",
            "/sapi/v1/sub-account/transfer/subUserHistory",
            query,
            signed=True,
            base_url=_spot_base_url(),
        )
        return payload if isinstance(payload, list) else []

    def probe_account_type(self) -> str:
        """通过主/子账户专用接口双向探测账户类型。

        ``/sapi/v1/sub-account/list`` 仅供主账户使用；``-8012`` 既可能表示
        主账户未开通子账户功能，也可能表示子账户调用了主账户专用接口。因此
        只有在该接口返回 ``-8012`` 后，子账户专用流水接口成功时才判定为子账户；
        两个接口都返回 ``-8012`` 才判定为未开通子账户功能的主账户。其他错误均
        保持 unknown，避免把权限/网络故障误当成真实账户类型。
        """
        try:
            self._request(
                "GET", "/sapi/v1/sub-account/list", None, signed=True, base_url=_spot_base_url()
            )
        except BinanceApiError as master_exc:
            if str(master_exc.code or "") != "-8012":
                return ACCOUNT_TYPE_UNKNOWN
            try:
                payload = self._request(
                    "GET",
                    "/sapi/v1/sub-account/transfer/subUserHistory",
                    {"asset": "USDT", "type": 2, "limit": 1},
                    signed=True,
                    base_url=_spot_base_url(),
                )
            except BinanceApiError as sub_exc:
                if str(sub_exc.code or "") == "-8012":
                    return ACCOUNT_TYPE_MASTER
                if is_sub_account_only_error(sub_exc):
                    return ACCOUNT_TYPE_MASTER
                return ACCOUNT_TYPE_UNKNOWN
            return ACCOUNT_TYPE_SUB if isinstance(payload, list) else ACCOUNT_TYPE_UNKNOWN
        return ACCOUNT_TYPE_MASTER

    def is_master_account_probe(self) -> bool:
        """兼容旧调用方：仅在双向探测明确判定主账户时返回 True。"""
        return self.probe_account_type() == ACCOUNT_TYPE_MASTER

    def withdraw_to_binance_address(
        self,
        amount: str,
        *,
        address: str,
        network: str,
        ccy: str = "USDT",
        withdraw_order_id: str = "",
    ) -> str:
        """Submit a Spot withdrawal to a configured Binance deposit address.

        Binance decides whether this settles internally or on-chain. Callers
        must reconcile withdrawal history and must not assume a no-fee route.
        """
        destination = str(address or "").strip()
        target_network = str(network or "").strip().upper()
        if not destination or not target_network:
            raise BinanceApiError("未配置目标主账户 Spot 充值地址或网络，无法发起归集")
        if not destination.isascii() or any(char.isspace() or ord(char) < 32 for char in destination):
            raise BinanceApiError("目标主账户 Spot 充值地址格式不正确")
        if "@" in destination or destination.isdigit():
            raise BinanceApiError("主账户归集不支持邮箱或 UID，请填写目标主账户 Spot 充值地址")
        if target_network not in CAPITAL_COLLECT_NETWORKS:
            raise BinanceApiError(
                "当前资金归集仅支持 BSC（BEP20）、TRX（TRC20）和 ETH（ERC20）网络，请填写匹配的目标主账户充值地址"
            )
        order_id = str(withdraw_order_id or "").strip()
        if not order_id:
            order_id = f"tt{int(time.time() * 1000)}{os.urandom(4).hex()}"
        params: dict[str, Any] = {
            "coin": str(ccy or "USDT").upper(),
            "amount": _fmt(_d(amount)),
            "address": destination,
            "network": target_network,
            "withdrawOrderId": order_id,
            "walletType": 0,
            # Binance documents this form value as the lowercase literal
            # ``true``. urllib would otherwise encode Python True as ``True``.
            "transactionFeeFlag": "true",
        }
        payload = self._request(
            "POST",
            "/sapi/v1/capital/withdraw/apply",
            params,
            signed=True,
            base_url=_spot_base_url(),
        )
        txn_id = str(payload.get("id") or "") if isinstance(payload, dict) else ""
        if not txn_id:
            raise BinanceApiError("提现申请未返回流水号，结果无法确认", outcome_unknown=True)
        self._invalidate_wallet_balance_cache(ccy)
        return txn_id

    def get_withdraw_history(
        self,
        *,
        ccy: str = "USDT",
        withdraw_order_id: str = "",
        status: Optional[int] = None,
        start_time_ms: Optional[int] = None,
        end_time_ms: Optional[int] = None,
        offset: Optional[int] = None,
        limit: int = 100,
    ) -> list[dict[str, Any]]:
        """Query withdraw/internal-transfer history for uncertain-result reconciliation."""
        query: dict[str, Any] = {
            "coin": str(ccy or "USDT").upper(),
            "limit": max(1, min(1000, int(limit))),
        }
        if str(withdraw_order_id or "").strip():
            query["withdrawOrderId"] = str(withdraw_order_id).strip()
        if status is not None:
            query["status"] = int(status)
        if start_time_ms is not None:
            query["startTime"] = max(0, int(start_time_ms))
        if end_time_ms is not None:
            query["endTime"] = max(0, int(end_time_ms))
        if offset is not None:
            query["offset"] = max(0, int(offset))
        payload = self._request(
            "GET",
            "/sapi/v1/capital/withdraw/history",
            query,
            signed=True,
            base_url=_spot_base_url(),
        )
        return payload if isinstance(payload, list) else []

    def get_deposit_history(
        self,
        *,
        ccy: str = "USDT",
        status: Optional[int] = None,
        start_time_ms: Optional[int] = None,
        end_time_ms: Optional[int] = None,
        offset: Optional[int] = None,
        limit: int = 1000,
    ) -> list[dict[str, Any]]:
        """Query Spot/Funding deposit history without source-address details."""
        query: dict[str, Any] = {
            "coin": str(ccy or "USDT").upper(),
            "limit": max(1, min(1000, int(limit))),
        }
        if status is not None:
            query["status"] = int(status)
        if start_time_ms is not None:
            query["startTime"] = max(0, int(start_time_ms))
        if end_time_ms is not None:
            query["endTime"] = max(0, int(end_time_ms))
        if offset is not None:
            query["offset"] = max(0, int(offset))
        payload = self._request(
            "GET",
            "/sapi/v1/capital/deposit/hisrec",
            query,
            signed=True,
            base_url=_spot_base_url(),
        )
        if not isinstance(payload, list) or any(not isinstance(row, dict) for row in payload):
            raise BinanceApiError("充值历史返回格式异常，不能确认同步完成")
        return payload

    def get_pay_transactions(
        self,
        *,
        start_time_ms: Optional[int] = None,
        end_time_ms: Optional[int] = None,
        limit: int = 100,
    ) -> list[dict[str, Any]]:
        """Read Binance Pay history without counterparty identity details."""
        query: dict[str, Any] = {"limit": max(1, min(100, int(limit)))}
        if start_time_ms is not None:
            query["startTime"] = max(0, int(start_time_ms))
        if end_time_ms is not None:
            query["endTime"] = max(0, int(end_time_ms))
        payload = self._request(
            "GET",
            "/sapi/v1/pay/transactions",
            query,
            signed=True,
            base_url=_spot_base_url(),
        )
        if (
            not isinstance(payload, dict)
            or payload.get("code") != "000000"
            or payload.get("success") is not True
        ):
            raise BinanceApiError("站内转账历史查询未成功，不能确认同步完成")
        rows = payload.get("data")
        if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
            raise BinanceApiError("站内转账历史返回格式异常，不能确认同步完成")
        fields = (
            "transactionId", "transactionTime", "amount", "currency",
            "orderType", "walletType", "walletTypes",
        )
        return [{key: row[key] for key in fields if key in row} for row in rows]

    def get_margin_account_snapshot(self) -> tuple[dict[str, Any], dict[str, Any]]:
        """Fresh read-only risk fields; do not reuse the ten-minute config cache."""
        config = self._request("GET", "/fapi/v1/accountConfig", signed=True,
                               budget_priority=RequestPriority.BACKGROUND)
        account = self._request("GET", "/fapi/v2/account", signed=True,
                                budget_priority=RequestPriority.BACKGROUND)
        if not isinstance(config, dict) or not isinstance(account, dict):
            raise BinanceApiError("保证金账户返回格式异常")
        return config, account

    def get_positions(
        self,
        inst_type: str = "SWAP",
        inst_id: str = "",
        *,
        budget_priority: RequestPriority | str | None = None,
    ) -> dict[str, Any]:
        target_symbol = _exchange_symbol(inst_id) if inst_id else ""
        query = {"symbol": target_symbol} if target_symbol else None
        payload = self._request(
            "GET",
            "/fapi/v3/positionRisk",
            query,
            signed=True,
            budget_priority=budget_priority,
        )
        rows = payload.get("data") if isinstance(payload, dict) else payload
        if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
            raise BinanceApiError("仓位查询返回格式异常，不能确认持仓状态")
        result: list[dict[str, Any]] = []
        for row in rows:
            symbol = str(row.get("symbol") or "")
            if not symbol:
                raise BinanceApiError("仓位查询返回缺少交易对，不能确认持仓状态")
            if target_symbol and symbol != target_symbol:
                raise BinanceApiError("仓位查询返回交易对不匹配，不能确认持仓状态")
            if not _USDT_PERP_SYMBOL_RE.fullmatch(symbol):
                if target_symbol:
                    raise BinanceApiError("仓位查询返回不支持的合约")
                continue
            try:
                qty = Decimal(str(row.get("positionAmt")))
            except (InvalidOperation, TypeError, ValueError) as exc:
                raise BinanceApiError("仓位查询返回数量异常，不能确认持仓状态") from exc
            if not qty.is_finite():
                raise BinanceApiError("仓位查询返回数量异常，不能确认持仓状态")
            if qty == 0:
                continue
            position_side = str(row.get("positionSide") or "BOTH").upper()
            legacy_pos_side = _legacy_pos_side(position_side, qty)
            mark_price = _d(row.get("markPrice") or "0")
            entry_price = _d(row.get("entryPrice") or "0")
            raw_unrealized_pnl = row.get("unRealizedProfit")
            unrealized_pnl = _d(raw_unrealized_pnl or "0")
            if not unrealized_pnl.is_finite():
                unrealized_pnl = Decimal("0")
            notional = abs(_d(row.get("notional") or mark_price * abs(qty)))
            leverage = _d(row.get("leverage") or "1")
            margin = (
                _d(row.get("positionInitialMargin") or "0")
                or _d(row.get("isolatedMargin") or "0")
                or (notional / leverage if notional > 0 and leverage > 0 else Decimal("0"))
            )
            upl_ratio = unrealized_pnl / margin if margin > 0 else Decimal("0")
            legacy_qty = abs(qty) if position_side in ("LONG", "SHORT") else qty
            result.append(
                {
                    "instId": to_inst_id(symbol),
                    "instType": inst_type,
                    "posSide": legacy_pos_side,
                    "pos": format(legacy_qty, "f"),
                    "avgPx": format(entry_price, "f"),
                    "markPx": format(mark_price, "f"),
                    "last": format(mark_price, "f"),
                    "upl": format(unrealized_pnl, "f"),
                    # Strict risk checks must validate the raw value; legacy UI
                    # consumers retain their numeric display fallback above.
                    "rawUpl": raw_unrealized_pnl,
                    "rawPositionSide": position_side,
                    "updateTime": row.get("updateTime"),
                    "uplRatio": format(upl_ratio, "f"),
                    "lever": str(row.get("leverage") or "1"),
                    "ctVal": "1",
                    "notionalUsd": format(notional, "f"),
                    "margin": format(margin, "f"),
                }
            )
        return _ok(result)

    def get_instruments(self, inst_type: str = "SWAP", uly: str = "") -> dict[str, Any]:
        exchange_info = _public_json_request("/fapi/v1/exchangeInfo")
        symbols = exchange_info.get("symbols") or []
        result: list[dict[str, Any]] = []
        underlying = str(uly or "").replace("-", "").upper()
        for row in symbols:
            if str(row.get("contractType") or "") != "PERPETUAL":
                continue
            if str(row.get("quoteAsset") or "") != "USDT":
                continue
            symbol = str(row.get("symbol") or "")
            if underlying and not symbol.startswith(underlying.replace("USDT", "")):
                continue
            result.append(_normalize_public_instrument(row))
        return _ok(result)

    def get_tickers(self, inst_type: str = "SWAP") -> dict[str, Any]:
        payload = _public_json_request("/fapi/v1/ticker/24hr")
        rows = payload if isinstance(payload, list) else [payload]
        result = [
            _normalize_public_ticker(row)
            for row in rows
            if str(row.get("symbol") or "").endswith("USDT")
        ]
        return _ok(result)

    def get_ticker(self, inst_id: str) -> dict[str, Any]:
        symbol = _exchange_symbol(inst_id)
        payload = _public_json_request("/fapi/v1/ticker/24hr", {"symbol": symbol})
        return _ok([_normalize_public_ticker(payload)])

    def get_last_prices(self, inst_ids: Optional[set[str]] = None) -> dict[str, Any]:
        # Price-only endpoint; keep timeout short so list API remains responsive.
        payload = _public_json_request("/fapi/v2/ticker/price", timeout_seconds=1.5)
        rows = payload if isinstance(payload, list) else [payload]
        expected_ids = set(inst_ids or [])
        result: list[dict[str, Any]] = []
        for row in rows:
            # 单个异类符号（交割/非 USDT）不能拖垮整份快照，识别不了就跳过
            if not _USDT_PERP_SYMBOL_RE.match(str((row or {}).get("symbol") or "")):
                continue
            normalized = _normalize_public_price_ticker(row or {})
            inst_id = str(normalized.get("instId") or "")
            if not inst_id:
                continue
            if expected_ids and inst_id not in expected_ids:
                continue
            result.append(normalized)
        return _ok(result)

    def get_mark_price_candles(self, inst_id: str, bar: str = "1m", limit: int = 1) -> dict[str, Any]:
        symbol = _exchange_symbol(inst_id)
        payload = _public_json_request(
            "/fapi/v1/markPriceKlines",
            {"symbol": symbol, "interval": _interval(bar), "limit": max(1, int(limit))},
        )
        result = []
        for row in payload:
            result.append(
                [
                    str(row[0]),
                    str(row[1]),
                    str(row[2]),
                    str(row[3]),
                    str(row[4]),
                    str(row[5]),
                    str(row[7] if len(row) > 7 else "0"),
                    str(row[8] if len(row) > 8 else "0"),
                ]
            )
        return _ok(result)

    def get_candles(self, inst_id: str, bar: str = "1m", limit: int = 1) -> dict[str, Any]:
        symbol = _exchange_symbol(inst_id)
        payload = _public_json_request(
            "/fapi/v1/klines",
            {"symbol": symbol, "interval": _interval(bar), "limit": max(1, int(limit))},
        )
        result = []
        for row in payload:
            result.append(
                [
                    str(row[0]),
                    str(row[1]),
                    str(row[2]),
                    str(row[3]),
                    str(row[4]),
                    str(row[5]),
                    str(row[7] if len(row) > 7 else "0"),
                    str(row[8] if len(row) > 8 else "0"),
                ]
            )
        return _ok(result)

    def get_historical_candles(
        self,
        inst_id: str,
        bar: str = "1m",
        limit: int = 500,
        *,
        start_time: Optional[int] = None,
        end_time: Optional[int] = None,
    ) -> list[dict[str, str]]:
        """Return raw futures OHLCV bars with both opening and closing timestamps.

        This intentionally uses Binance's public endpoint, so research never needs a
        user's exchange credentials.
        """
        symbol = _exchange_symbol(inst_id)
        query: dict[str, Any] = {"symbol": symbol, "interval": _interval(bar), "limit": min(max(1, int(limit)), 1500)}
        if start_time is not None:
            query["startTime"] = int(start_time)
        if end_time is not None:
            query["endTime"] = int(end_time)
        payload = _public_json_request("/fapi/v1/klines", query)
        rows: list[dict[str, str]] = []
        for row in payload if isinstance(payload, list) else []:
            if len(row) < 7:
                continue
            rows.append(
                {
                    "open_time": str(row[0]),
                    "open": str(row[1]),
                    "high": str(row[2]),
                    "low": str(row[3]),
                    "close": str(row[4]),
                    "volume": str(row[5]),
                    "close_time": str(row[6]),
                }
            )
        return rows

    def set_leverage(self, inst_id: str, leverage: int = 1, pos_side: Optional[str] = None) -> dict[str, Any]:
        symbol = _exchange_symbol(inst_id)
        payload = self._request(
            "POST",
            "/fapi/v1/leverage",
            {"symbol": symbol, "leverage": max(1, int(leverage))},
            signed=True,
        )
        return _ok([{"lever": str(payload.get("leverage") or leverage)}])

    def place_market_order(
        self,
        inst_id: str,
        side: str,
        size: str,
        pos_side: Optional[str] = None,
        new_client_order_id: Optional[str] = None,
    ) -> dict[str, Any]:
        from trading.adapters import trading_adapter
        trading_adapter(self.credentials.trading_mode).validate_entry(self, inst_id)
        symbol = _exchange_symbol(inst_id)
        normalized_size = self._normalize_order_quantity(inst_id, size, "market")
        params: dict[str, Any] = {
            "symbol": symbol,
            "side": str(side or "").upper(),
            "type": "MARKET",
            "quantity": normalized_size,
            "newOrderRespType": "RESULT",
        }
        if pos_side:
            params["positionSide"] = str(pos_side).upper()
        if new_client_order_id:
            params["newClientOrderId"] = str(new_client_order_id)
        payload = self._request(
            "POST", "/fapi/v1/order", params, signed=True,
            budget_priority=RequestPriority.NORMAL if self.credentials.trading_mode == "lead" else None,
        )
        order_id = str(payload.get("orderId") or "") if isinstance(payload, dict) else ""
        if not order_id:
            raise BinanceApiError("开仓未返回订单号，结果无法确认", outcome_unknown=True)
        return _ok(
            [
                {
                    "ordId": order_id,
                    "sCode": "0",
                    "sMsg": "",
                    "state": _legacy_order_state(str(payload.get("status") or "")),
                    "avgPx": str(payload.get("avgPrice") or payload.get("price") or "0"),
                    "fillSz": str(payload.get("executedQty") or "0"),
                    "accFillSz": str(payload.get("executedQty") or "0"),
                }
            ]
        )

    def place_limit_order(
        self,
        inst_id: str,
        side: str,
        size: str,
        price: str,
        pos_side: Optional[str] = None,
        new_client_order_id: Optional[str] = None,
    ) -> dict[str, Any]:
        from trading.adapters import trading_adapter
        trading_adapter(self.credentials.trading_mode).validate_entry(self, inst_id)
        symbol = _exchange_symbol(inst_id)
        normalized_size = self._normalize_order_quantity(inst_id, size, "limit")
        normalized_price = self._normalize_order_price(inst_id, price, price_kind="limit", side=side)
        params: dict[str, Any] = {
            "symbol": symbol,
            "side": str(side or "").upper(),
            "type": "LIMIT",
            "timeInForce": "GTC",
            "quantity": normalized_size,
            "price": normalized_price,
        }
        if pos_side:
            params["positionSide"] = str(pos_side).upper()
        if new_client_order_id:
            params["newClientOrderId"] = str(new_client_order_id)
        payload = self._request(
            "POST", "/fapi/v1/order", params, signed=True,
            budget_priority=RequestPriority.NORMAL if self.credentials.trading_mode == "lead" else None,
        )
        order_id = str(payload.get("orderId") or "") if isinstance(payload, dict) else ""
        if not order_id:
            raise BinanceApiError("限价开仓未返回订单号，结果无法确认", outcome_unknown=True)
        return _ok([{"ordId": order_id, "sCode": "0", "sMsg": ""}])

    def cancel_order(self, inst_id: str, order_id: str) -> dict[str, Any]:
        symbol = _exchange_symbol(inst_id)
        payload = self._request(
            "DELETE",
            "/fapi/v1/order",
            {"symbol": symbol, "orderId": order_id},
            signed=True,
        )
        response_order_id = str(payload.get("orderId") or "") if isinstance(payload, dict) else ""
        if not response_order_id:
            raise BinanceApiError("撤单未返回有效结果，状态需要重新确认", outcome_unknown=True)
        executed_quantity = payload.get("executedQty")
        fill_size = str(executed_quantity) if executed_quantity is not None else None
        return _ok([{
            "ordId": response_order_id,
            "state": _legacy_order_state(str(payload.get("status") or "CANCELED")),
            "avgPx": str(payload.get("avgPrice") or "0"),
            "fillSz": fill_size,
            "accFillSz": fill_size,
        }])

    def cancel_open_orders(self, inst_id: str) -> dict[str, Any]:
        payload = self._request(
            "DELETE",
            "/fapi/v1/allOpenOrders",
            {"symbol": _exchange_symbol(inst_id)},
            signed=True,
        )
        return _ok([{"instId": inst_id, "state": "canceled", "msg": str(payload.get("msg") or "")}])

    def get_order(
        self,
        inst_id: str,
        order_id: str = "",
        *,
        orig_client_order_id: str = "",
        budget_priority: RequestPriority | str | None = RequestPriority.CRITICAL,
    ) -> dict[str, Any]:
        symbol = _exchange_symbol(inst_id)
        query: dict[str, Any] = {"symbol": symbol}
        if order_id:
            query["orderId"] = order_id
        elif orig_client_order_id:
            query["origClientOrderId"] = orig_client_order_id
        else:
            raise BinanceApiError("查询订单失败：缺少 orderId / origClientOrderId")
        payload = self._request(
            "GET",
            "/fapi/v1/order",
            query,
            signed=True,
            budget_priority=budget_priority,
        )
        executed_quantity = payload.get("executedQty")
        fill_size = str(executed_quantity) if executed_quantity is not None else None
        row = {
            "ordId": str(payload.get("orderId") or order_id),
            "instId": to_inst_id(str(payload["symbol"])) if _USDT_PERP_SYMBOL_RE.fullmatch(str(payload.get("symbol") or "")) else "",
            "clientOrderId": str(payload.get("clientOrderId") or "").strip(),
            "rawPositionSide": str(payload.get("positionSide") or "BOTH").strip().upper(),
            "reduceOnly": _exchange_bool(payload.get("reduceOnly")),
            "state": _legacy_order_state(str(payload.get("status") or "")),
            "fillSz": fill_size,
            "accFillSz": fill_size,
            "avgPx": str(payload.get("avgPrice") or "0"),
            "px": str(payload.get("price") or "0"),
            "side": str(payload.get("side") or "").lower(),
            "sz": str(payload.get("origQty") or payload.get("executedQty") or "0"),
            "algoId": str(payload.get("orderId") or order_id),
            "slTriggerPx": str(payload.get("stopPrice") or "0"),
            "tpTriggerPx": str(payload.get("stopPrice") or "0"),
            "posSide": _legacy_pos_side(
                str(payload.get("positionSide") or "BOTH"),
                _d(payload.get("origQty") or "0"),
            ),
        }
        return _ok([row])

    def get_all_orders(
        self,
        inst_id: str = "",
        limit: int = 100,
        start_time: Optional[str] = None,
        end_time: Optional[str] = None,
    ) -> dict[str, Any]:
        params: dict[str, Any] = {"limit": max(1, min(int(limit), 1000))}
        if inst_id:
            params["symbol"] = _exchange_symbol(inst_id)
        if start_time:
            params["startTime"] = start_time
        if end_time:
            params["endTime"] = end_time
        payload = self._request("GET", "/fapi/v1/allOrders", params, signed=True)
        rows = payload if isinstance(payload, list) else payload.get("data") or []
        result = []
        for row in rows:
            result.append(
                {
                    "ordId": str(row.get("orderId") or ""),
                    "instId": to_inst_id(str(row.get("symbol") or "")),
                    "state": _legacy_order_state(str(row.get("status") or "")),
                    "side": str(row.get("side") or "").lower(),
                    "posSide": _legacy_pos_side(
                        str(row.get("positionSide") or "BOTH"),
                        _d(row.get("origQty") or "0"),
                    ),
                    "sz": str(row.get("origQty") or "0"),
                    "accFillSz": str(row.get("executedQty") or "0"),
                    "fillSz": str(row.get("executedQty") or "0"),
                    "avgPx": str(row.get("avgPrice") or row.get("price") or "0"),
                    "px": str(row.get("price") or "0"),
                    "cTime": str(row.get("time") or row.get("updateTime") or "0"),
                    "uTime": str(row.get("updateTime") or row.get("time") or "0"),
                    "reduceOnly": bool(row.get("reduceOnly", False)),
                    "origType": str(row.get("origType") or row.get("type") or ""),
                }
            )
        return _ok(result)

    def get_user_trades(
        self,
        inst_id: str = "",
        limit: int = 1000,
        start_time: Optional[str] = None,
        end_time: Optional[str] = None,
    ) -> dict[str, Any]:
        params: dict[str, Any] = {"limit": max(1, min(int(limit), 1000))}
        if inst_id:
            params["symbol"] = _exchange_symbol(inst_id)
        if start_time:
            params["startTime"] = start_time
        if end_time:
            params["endTime"] = end_time
        payload = self._request("GET", "/fapi/v1/userTrades", params, signed=True)
        rows = payload if isinstance(payload, list) else payload.get("data") or []
        result = []
        for row in rows:
            qty = _d(row.get("qty") or "0")
            side = str(row.get("side") or "").upper()
            signed_qty = qty if side == "BUY" else -qty
            raw_position_side = str(row.get("positionSide") or "BOTH").upper()
            result.append(
                {
                    "tradeId": str(row.get("id") or ""),
                    "ordId": str(row.get("orderId") or ""),
                    "instId": to_inst_id(str(row.get("symbol") or "")),
                    "side": side.lower(),
                    "posSide": _legacy_pos_side(
                        raw_position_side,
                        signed_qty,
                    ),
                    "rawPositionSide": raw_position_side,
                    "fillPx": str(row.get("price") or "0"),
                    "fillSz": str(row.get("qty") or "0"),
                    "quoteQty": str(row.get("quoteQty") or "0"),
                    "realizedPnl": str(row["realizedPnl"]) if row.get("realizedPnl") not in (None, "") else None,
                    "fee": str(row["commission"]) if row.get("commission") not in (None, "") else None,
                    "feeCcy": str(row.get("commissionAsset") or ""),
                    "maker": bool(row.get("maker")),
                    "time": str(row.get("time") or "0"),
                }
            )
        return _ok(result)

    def get_pending_orders(self, inst_type: str = "SWAP", inst_id: str = "") -> dict[str, Any]:
        query = {"symbol": _exchange_symbol(inst_id)} if inst_id else None
        payload = self._request("GET", "/fapi/v1/openOrders", query, signed=True)
        rows = payload if isinstance(payload, list) else payload.get("data") or []
        result = []
        for row in rows:
            result.append(
                {
                    "ordId": str(row.get("orderId") or ""),
                    "instId": to_inst_id(str(row.get("symbol") or "")),
                    "state": _legacy_order_state(str(row.get("status") or "")),
                    "avgPx": str(row.get("avgPrice") or row.get("price") or "0"),
                    "fillSz": str(row.get("executedQty") or "0"),
                    "accFillSz": str(row.get("executedQty") or "0"),
                    "px": str(row.get("price") or "0"),
                    "clientOrderId": str(row.get("clientOrderId") or "").strip(),
                    "side": str(row.get("side") or "").strip().lower(),
                    "positionSide": str(row.get("positionSide") or "BOTH").strip().upper(),
                    "reduceOnly": bool(row.get("reduceOnly")),
                }
            )
        return _ok(result)

    def get_pending_algo_orders(
        self,
        ord_type: str = "conditional",
        inst_type: str = "SWAP",
        inst_id: str = "",
        algo_id: str = "",
        *,
        budget_priority: RequestPriority | str | None = None,
    ) -> dict[str, Any]:
        target_symbol = _exchange_symbol(inst_id) if inst_id else ""
        if algo_id:
            query: dict[str, Any] = {"algoId": algo_id}
            payload = self._request(
                "GET",
                "/fapi/v1/algoOrder",
                query,
                signed=True,
                budget_priority=budget_priority,
            )
            rows = payload if isinstance(payload, list) else [payload]
        else:
            query = {"algoType": "CONDITIONAL"}
            if target_symbol:
                query["symbol"] = target_symbol
            payload = self._request(
                "GET",
                "/fapi/v1/openAlgoOrders",
                query,
                signed=True,
                budget_priority=budget_priority,
            )
            if isinstance(payload, list):
                rows = payload
            else:
                rows = (
                    payload.get("orders")
                    or payload.get("data")
                    or payload.get("rows")
                    or []
                )
        result: list[dict[str, Any]] = []
        for row in rows:
            try:
                parsed_row = _parse_algo_order_row(row)
            except BinanceApiError:
                continue
            if algo_id and str(parsed_row.get("algoId") or "") != str(algo_id):
                continue
            if target_symbol and str(parsed_row.get("instId") or "") != to_inst_id(target_symbol):
                continue
            result.append(parsed_row)
        return _ok(result)

    def get_algo_order_by_client_id(
        self,
        inst_id: str,
        client_algo_id: str,
        *,
        budget_priority: RequestPriority | str | None = RequestPriority.CRITICAL,
    ) -> dict[str, Any]:
        """Recover one submission, including canceled/triggered terminal orders."""
        if not str(client_algo_id or "").strip():
            raise BinanceApiError("查询条件单失败：缺少 clientAlgoId")
        payload = self._request(
            "GET", "/fapi/v1/algoOrder", {"clientAlgoId": client_algo_id},
            signed=True, budget_priority=budget_priority,
        )
        if not isinstance(payload, dict):
            raise BinanceApiError("条件单查询返回格式异常")
        row = _parse_algo_order_row(payload)
        if row["instId"] != to_inst_id(_exchange_symbol(inst_id)) or row["clientAlgoId"] != client_algo_id:
            raise BinanceApiError("条件单查询返回身份不匹配")
        return _ok([row])

    def place_stop_loss_order(
        self,
        inst_id: str,
        side: str,
        size: str,
        stop_loss_price: str,
        pos_side: Optional[str] = None,
        client_algo_id: Optional[str] = None,
    ) -> dict[str, Any]:
        symbol = _exchange_symbol(inst_id)
        instrument = self._get_public_instrument(inst_id)
        position_side = str(pos_side or "").lower() or ("long" if str(side or "").lower() == "sell" else "short")
        standardized = standardize_trigger_order_request(
            trigger_price=_d(stop_loss_price),
            quantity=_d(size),
            instrument=instrument,
            trigger_kind="stop_loss",
            position_side=position_side,
        )
        params: dict[str, Any] = {
            "algoType": "CONDITIONAL",
            "symbol": symbol,
            "side": str(side or "").upper(),
            "type": "STOP",
            "triggerPrice": _fmt(standardized["trigger_price"]),
            "price": _fmt(standardized["trigger_price"]),
            "quantity": _fmt(standardized["quantity"]),
            "reduceOnly": "true",
            "workingType": str(standardized["working_type"]),
            "priceProtect": str(standardized["price_protect"]),
        }
        if pos_side:
            params["positionSide"] = str(pos_side).upper()
            params.pop("reduceOnly", None)
        if client_algo_id:
            params["clientAlgoId"] = str(client_algo_id)[:36]
        payload = self._request("POST", "/fapi/v1/algoOrder", params, signed=True)
        return _ok([_parse_algo_submit_response(payload)])

    def place_take_profit_order(
        self,
        inst_id: str,
        side: str,
        size: str,
        trigger_price: str,
        pos_side: Optional[str] = None,
        order_type: str = "market",
        client_algo_id: Optional[str] = None,
    ) -> dict[str, Any]:
        symbol = _exchange_symbol(inst_id)
        instrument = self._get_public_instrument(inst_id)
        position_side = str(pos_side or "").lower() or ("long" if str(side or "").lower() == "sell" else "short")
        normalized_order_type = "limit" if str(order_type or "").lower() == "limit" else "market"
        standardized = standardize_trigger_order_request(
            trigger_price=_d(trigger_price),
            quantity=_d(size),
            instrument=instrument,
            trigger_kind="take_profit",
            position_side=position_side,
        )
        params: dict[str, Any] = {
            "algoType": "CONDITIONAL",
            "symbol": symbol,
            "side": str(side or "").upper(),
            "type": "TAKE_PROFIT" if normalized_order_type == "limit" else "TAKE_PROFIT_MARKET",
            "triggerPrice": _fmt(standardized["trigger_price"]),
            "quantity": _fmt(standardized["quantity"]),
            "reduceOnly": "true",
            # The outer guard must prioritise exit reliability over spike filtering.
            "workingType": "CONTRACT_PRICE",
            "priceProtect": "FALSE",
        }
        if normalized_order_type == "limit":
            params["price"] = _fmt(standardized["trigger_price"])
        if pos_side:
            params["positionSide"] = str(pos_side).upper()
            params.pop("reduceOnly", None)
        if client_algo_id:
            params["clientAlgoId"] = str(client_algo_id)[:36]
        payload = self._request("POST", "/fapi/v1/algoOrder", params, signed=True)
        return _ok([_parse_algo_submit_response(payload)])

    def place_stop_market_order(
        self,
        inst_id: str,
        side: str,
        size: str,
        trigger_price: str,
        pos_side: Optional[str] = None,
        client_algo_id: Optional[str] = None,
        working_type: str = "CONTRACT_PRICE",
    ) -> dict[str, Any]:
        """Place the reduce-only STOP_MARKET protection order."""
        if working_type not in {"CONTRACT_PRICE", "MARK_PRICE"}:
            raise BinanceApiError("止损触发参考类型必须为 CONTRACT_PRICE 或 MARK_PRICE")
        symbol = _exchange_symbol(inst_id)
        instrument = self._get_public_instrument(inst_id)
        position_side = str(pos_side or "").lower() or ("long" if str(side or "").lower() == "sell" else "short")
        standardized = standardize_trigger_order_request(
            trigger_price=_d(trigger_price),
            quantity=_d(size),
            instrument=instrument,
            trigger_kind="stop_loss",
            position_side=position_side,
        )
        params: dict[str, Any] = {
            "algoType": "CONDITIONAL",
            "symbol": symbol,
            "side": str(side or "").upper(),
            "type": "STOP_MARKET",
            "triggerPrice": _fmt(standardized["trigger_price"]),
            "quantity": _fmt(standardized["quantity"]),
            "reduceOnly": "true",
            # Preserve an adopted manual stop's trigger reference when restoring it.
            "workingType": working_type,
            "priceProtect": "FALSE",
        }
        if pos_side:
            params["positionSide"] = str(pos_side).upper()
            params.pop("reduceOnly", None)
        if client_algo_id:
            params["clientAlgoId"] = str(client_algo_id)[:36]
        payload = self._request("POST", "/fapi/v1/algoOrder", params, signed=True)
        return _ok([_parse_algo_submit_response(payload)])

    def amend_stop_loss_order(self, algo_id: str, inst_id: str, stop_loss_price: str) -> dict[str, Any]:
        current = self._request(
            "GET",
            "/fapi/v1/algoOrder",
            {"algoId": algo_id},
            signed=True,
        )
        side = str(current.get("side") or "").lower()
        qty = str(current.get("quantity") or current.get("origQty") or "0")
        position_side = str(current.get("positionSide") or "BOTH").upper()
        return self.place_stop_loss_order(
            inst_id=inst_id,
            side=side,
            size=qty,
            stop_loss_price=stop_loss_price,
            pos_side=None if position_side == "BOTH" else position_side.lower(),
        )

    def cancel_algos(self, algo_id: str, inst_id: str) -> dict[str, Any]:
        payload = self._request(
            "DELETE",
            "/fapi/v1/algoOrder",
            {"algoId": algo_id},
            signed=True,
        )
        response_algo_id = str(payload.get("algoId") or "") if isinstance(payload, dict) else ""
        if not response_algo_id:
            raise BinanceApiError("条件单撤销未返回有效结果，状态需要重新确认", outcome_unknown=True)
        return _ok([{"algoId": response_algo_id, "state": "canceled"}])

    def close_position(
        self,
        inst_id: str,
        pos_side: Optional[str] = None,
        *,
        expected_side: Optional[str] = None,
        client_order_id: Optional[str] = None,
        max_quantity: Optional[Decimal] = None,
    ) -> dict[str, Any]:
        requested_side = str(expected_side or pos_side or "").strip().lower()
        if requested_side and requested_side not in {"long", "short"}:
            raise BinanceApiError("平仓方向必须为 long 或 short")
        if pos_side and str(pos_side).strip().lower() != requested_side:
            raise BinanceApiError("平仓方向与预期仓位方向不一致")
        quantity_limit = None
        if max_quantity is not None:
            try:
                quantity_limit = Decimal(str(max_quantity))
            except (InvalidOperation, TypeError, ValueError) as exc:
                raise BinanceApiError("平仓数量上限无效") from exc
            if not quantity_limit.is_finite() or quantity_limit <= 0:
                raise BinanceApiError("平仓数量上限必须为有效正数")
        if client_order_id is not None and not re.fullmatch(r"[.A-Z:/a-z0-9_-]{1,36}", str(client_order_id)):
            raise BinanceApiError("平仓客户端订单编号无效")
        positions = self.get_positions(
            "SWAP",
            inst_id,
            budget_priority=RequestPriority.CRITICAL,
        ).get("data") or []
        target = None
        if requested_side:
            target = next((row for row in positions if str(row.get("posSide") or "").lower() == requested_side), None)
        elif positions:
            target = positions[0]
        if not target:
            return _ok([])

        qty = abs(_d(target.get("pos") or "0"))
        if not qty.is_finite():
            raise BinanceApiError("平仓仓位数量无效")
        if quantity_limit is not None:
            qty = min(qty, quantity_limit)
        if qty <= 0:
            return _ok([])
        target_side = str(target.get("posSide") or "").lower()
        if target_side not in {"long", "short"}:
            raise BinanceApiError("平仓仓位方向无效")
        raw_position_side = str(target.get("rawPositionSide") or (pos_side or "BOTH")).upper()
        if raw_position_side not in {"BOTH", "LONG", "SHORT"} or (
            raw_position_side != "BOTH" and raw_position_side.lower() != target_side
        ):
            raise BinanceApiError("平仓仓位模式与方向不一致")
        side = "SELL" if target_side == "long" else "BUY"
        params: dict[str, Any] = {
            "symbol": _exchange_symbol(inst_id),
            "side": side,
            "type": "MARKET",
            "quantity": self._normalize_order_quantity(inst_id, format(qty, "f"), "market"),
            "newOrderRespType": "RESULT",
            "reduceOnly": "true",
        }
        if raw_position_side != "BOTH":
            params["positionSide"] = raw_position_side
            params.pop("reduceOnly", None)
        if client_order_id:
            params["newClientOrderId"] = str(client_order_id)
        payload = self._request("POST", "/fapi/v1/order", params, signed=True)
        order_id = str(payload.get("orderId") or "") if isinstance(payload, dict) else ""
        if not order_id:
            raise BinanceApiError("平仓未返回订单号，结果需要重新确认", outcome_unknown=True)
        return _ok([{
            "ordId": order_id,
            "instId": to_inst_id(str(payload["symbol"])) if _USDT_PERP_SYMBOL_RE.fullmatch(str(payload.get("symbol") or "")) else "",
            "clientOrderId": str(payload.get("clientOrderId") or "").strip(),
            "side": str(payload.get("side") or "").strip().lower(),
            "rawPositionSide": str(payload.get("positionSide") or "").strip().upper(),
            "reduceOnly": _exchange_bool(payload.get("reduceOnly")),
            "sz": str(payload.get("origQty") or "0"),
            "avgPx": str(payload.get("avgPrice") or payload.get("price") or "0"),
            "fillPx": str(payload.get("avgPrice") or payload.get("price") or "0"),
            "fillSz": str(payload.get("executedQty") or "0"),
            "state": _legacy_order_state(str(payload.get("status") or "")),
            "sCode": "0",
            "sMsg": "",
        }])

    def get_bills(
        self,
        begin: Optional[str] = None,
        end: Optional[str] = None,
        bill_type: Optional[str] = None,
        limit: int = 100,
    ) -> dict[str, Any]:
        params: dict[str, Any] = {"limit": max(1, int(limit))}
        if begin:
            params["startTime"] = begin
        if end:
            params["endTime"] = end
        if bill_type:
            params["incomeType"] = bill_type
        payload = self._request("GET", "/fapi/v1/income", params, signed=True)
        rows = payload if isinstance(payload, list) else payload.get("data") or []
        result = []
        for row in rows:
            result.append(
                {
                    "instId": to_inst_id(str(row.get("symbol") or "")) if row.get("symbol") else "",
                    "pnl": str(row.get("income") or "0"),
                    "type": str(row.get("incomeType") or ""),
                    "uTime": str(row.get("time") or "0"),
                }
            )
        return _ok(result)

    def get_positions_history(
        self,
        inst_type: str = "SWAP",
        limit: int = 100,
        after: Optional[str] = None,
        before: Optional[str] = None,
    ) -> dict[str, Any]:
        return build_closed_position_history(self, limit=limit, after=after, before=before)

    def _payload_sub_error(self, payload: dict[str, Any]) -> Optional[str]:
        rows = payload.get("data")
        if isinstance(rows, list) and rows:
            first = rows[0]
            if isinstance(first, dict):
                detail = str(first.get("sMsg") or first.get("msg") or "").strip()
                return detail or None
        return None


def validate_binance_binding(credentials: BinanceCredentials) -> dict[str, Any]:
    client = BinanceFuturesClient(credentials)
    payload = client.get_account_config(fresh=True)
    rows = payload.get("data") or []
    if not rows:
        raise BinanceApiError(f"未能读取 {_environment_label()} 账户配置，请稍后重试")

    config = rows[0]
    perm = str(config.get("perm") or "").lower()
    if "trade" not in perm:
        raise BinanceApiError("您绑定的 Binance API 没有合约交易权限，请检查正式环境权限设置")

    if credentials.trading_mode == "lead":
        from trading.adapters import LeadTradingAdapter
        LeadTradingAdapter().validate_binding(client, config=config)

    return {
        "perm": config.get("perm"),
        "label": config.get("label"),
        "uid": config.get("uid"),
    }


def get_usdt_equity_snapshot(
    client: BinanceFuturesClient,
    *,
    fresh: bool = False,
) -> tuple[str, str]:
    """Return available and total USDT futures equity from one exchange read."""
    payload = client.get_balance("USDT", fresh=fresh)
    rows = _require_balance_rows(
        payload.get("data") if isinstance(payload, dict) else None,
        source="合约账户",
    )
    if not rows:
        raise BinanceApiError("合约账户未返回 USDT 余额，请稍后重试")
    row = rows[0]
    details = row.get("details") or []
    if not isinstance(details, list) or any(not isinstance(detail, dict) for detail in details):
        raise BinanceApiError("合约账户余额返回格式异常，请稍后重试")
    detail = details[0] if details else {}
    available = _fmt(
        detail.get("availEq")
        or row.get("availableBalance")
        or detail.get("eq")
        or detail.get("cashBal")
        or row.get("totalEq")
        or "0"
    )
    total = _fmt(
        detail.get("eq")
        or detail.get("cashBal")
        or row.get("totalEq")
        or row.get("balance")
        or "0"
    )
    return available, total


def get_usdt_equity_and_upl(client: BinanceFuturesClient) -> tuple[str, str]:
    available, _total = get_usdt_equity_snapshot(client)
    return available, _get_today_realized_pnl(client)


def get_usdt_total_equity(client: BinanceFuturesClient) -> str:
    """Return total USDT equity in the futures wallet.

    ``get_usdt_equity_and_upl`` intentionally exposes available equity for the
    trading screen.  Risk configuration needs the exchange-reported total
    equity instead, so locked margin is not mistaken for missing account
    assets.
    """
    _available, total = get_usdt_equity_snapshot(client)
    return total


def _get_today_realized_pnl(client: BinanceFuturesClient) -> str:
    try:
        now = datetime.now().astimezone()
        today_start = datetime(now.year, now.month, now.day, tzinfo=now.tzinfo)
        cutoff_ms = int(today_start.timestamp() * 1000)
        payload = client.get_bills(begin=str(cutoff_ms), limit=1000)
        rows = payload.get("data") or []
        total_pnl = Decimal("0")
        included_types = {"REALIZED_PNL", "COMMISSION", "FUNDING_FEE"}
        for row in rows:
            close_ts = int(str(row.get("uTime") or row.get("cTime") or "0"))
            if close_ts < cutoff_ms:
                continue
            bill_type = str(row.get("type") or "").upper()
            if bill_type not in included_types:
                continue
            total_pnl += _d(row.get("realizedPnl") or row.get("pnl") or "0")
        if total_pnl == 0:
            return "0"
        result = format(total_pnl.quantize(Decimal("0.01")), "f")
        return result.rstrip("0").rstrip(".") if "." in result else result
    except Exception:
        return "0"


def build_closed_position_history(
    client: BinanceFuturesClient,
    limit: int = 100,
    after: Optional[str] = None,
    before: Optional[str] = None,
) -> dict[str, Any]:
    trades_payload = client.get_user_trades(limit=max(limit * 20, 200), start_time=after, end_time=before)
    income_payload = client.get_bills(begin=after, end=before, limit=max(limit * 20, 200))
    trades = trades_payload.get("data") or []
    incomes = income_payload.get("data") or []

    trade_groups: dict[str, list[dict[str, Any]]] = {}
    for trade in trades:
        inst_id = str(trade.get("instId") or "")
        raw_position_side = str(trade.get("rawPositionSide") or "").upper()
        # In Binance one-way mode userTrades reports positionSide=BOTH.
        # Group BOTH trades together so an opening BUY and closing SELL form one position segment.
        pos_side_key = raw_position_side if raw_position_side in {"LONG", "SHORT"} else "BOTH"
        key = f"{inst_id}|{pos_side_key}"
        trade_groups.setdefault(key, []).append(trade)

    income_map: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for income in incomes:
        inst_id = str(income.get("instId") or "")
        income_type = str(income.get("type") or "")
        income_map.setdefault((inst_id, income_type), []).append(income)

    result: list[dict[str, Any]] = []
    for key, rows in trade_groups.items():
        ordered = sorted(rows, key=lambda item: int(str(item.get("time") or "0")))
        if not ordered:
            continue

        running_qty = Decimal("0")
        open_cost = Decimal("0")
        entry_time = 0
        total_realized = Decimal("0")
        total_fee = Decimal("0")
        total_open_qty = Decimal("0")
        total_close_qty = Decimal("0")
        weighted_open_px = Decimal("0")
        weighted_close_px = Decimal("0")
        close_time = 0
        last_direction = "long"
        segments: list[dict[str, Any]] = []

        for row in ordered:
            qty = _d(row.get("fillSz") or "0")
            if qty <= 0:
                continue
            fill_price = _d(row.get("fillPx") or "0")
            realized_pnl = _d(row.get("realizedPnl") or "0")
            fee = abs(_d(row.get("fee") or "0"))
            side = str(row.get("side") or "").lower()
            trade_time = int(str(row.get("time") or "0"))
            signed_qty = qty if side == "buy" else -qty
            closing_qty = Decimal("0")

            if running_qty == 0:
                entry_time = trade_time
                open_cost = Decimal("0")
                total_open_qty = Decimal("0")
                weighted_open_px = Decimal("0")
                total_close_qty = Decimal("0")
                weighted_close_px = Decimal("0")
                total_realized = Decimal("0")
                total_fee = Decimal("0")

            if running_qty == 0 or running_qty * signed_qty > 0:
                running_qty += signed_qty
                open_cost += fill_price * qty
                total_open_qty += qty
                weighted_open_px += fill_price * qty
                if signed_qty > 0:
                    last_direction = "long"
                elif signed_qty < 0:
                    last_direction = "short"
                continue

            closing_qty = min(abs(running_qty), qty)
            close_time = trade_time
            total_close_qty += closing_qty
            weighted_close_px += fill_price * closing_qty
            total_realized += realized_pnl
            total_fee += fee

            if abs(qty - closing_qty) > Decimal("0.00000001"):
                remaining_qty = qty - closing_qty
                running_qty = remaining_qty if side == "buy" else -remaining_qty
                open_cost = fill_price * remaining_qty
                total_open_qty = remaining_qty
                weighted_open_px = fill_price * remaining_qty
                entry_time = trade_time
            else:
                running_qty += signed_qty
                if running_qty == 0:
                    open_avg = weighted_open_px / total_open_qty if total_open_qty > 0 else Decimal("0")
                    close_avg = weighted_close_px / total_close_qty if total_close_qty > 0 else fill_price
                    close_total_pos = total_close_qty
                    pnl_ratio = total_realized / (open_avg * close_total_pos) if open_avg > 0 and close_total_pos > 0 else Decimal("0")
                    inst_id = str(row.get("instId") or "")
                    funding_rows = income_map.get((inst_id, "FUNDING_FEE"), [])
                    funding_fee = Decimal("0")
                    for item in funding_rows:
                        item_time = int(str(item.get("uTime") or "0"))
                        if entry_time <= item_time <= close_time:
                            funding_fee += _d(item.get("pnl") or "0")
                    segments.append(
                        {
                            "instId": inst_id,
                            "realizedPnl": format(total_realized, "f"),
                            "pnl": format(total_realized, "f"),
                            "uTime": str(close_time),
                            "cTime": str(entry_time),
                            "fee": format(total_fee, "f"),
                            "fundingFee": format(funding_fee, "f"),
                            "direction": last_direction,
                            "openAvgPx": format(open_avg, "f"),
                            "closeAvgPx": format(close_avg, "f"),
                            "closeTotalPos": format(close_total_pos, "f"),
                            "lever": "1",
                            "pnlRatio": format(pnl_ratio, "f"),
                        }
                    )
                    open_cost = Decimal("0")

        result.extend(segments)

    result.sort(key=lambda item: int(str(item.get("uTime") or "0")), reverse=True)
    return _ok(result[: max(1, int(limit))])


def calc_contract_size(
    entry_price: str,
    notional_usdt: str,
    ct_val: str,
    lot_sz: str,
    min_sz: str = "0",
    min_notional: str = "0",
) -> str:
    price = _d(entry_price)
    notional = _d(notional_usdt)
    contract_value = _d(ct_val) or Decimal("1")
    lot = _d(lot_sz)
    min_quantity = _d(min_sz)
    min_notional_value = _d(min_notional)
    if price <= 0 or notional <= 0 or contract_value <= 0:
        raise BinanceApiError("仓位计算失败，请检查参数")
    size = notional / (price * contract_value)
    if lot > 0:
        size = quantize_down(size, lot)
    if size <= 0:
        raise BinanceApiError("当前参数下可开仓数量为 0，请增大止损金额或调整止损价")
    if min_quantity > 0 and size < min_quantity:
        raise BinanceApiError(
            f"当前参数下可开仓数量小于币安最小下单量 {format(min_quantity, 'f')}，请提高止损金额或调整价格"
        )
    if min_notional_value > 0 and (price * size * contract_value) < min_notional_value:
        raise BinanceApiError(
            f"当前参数下名义价值低于币安最小限制 {format(min_notional_value, 'f')} USDT，请提高止损金额或调整价格"
        )
    return format(size, "f")


def _public_client() -> BinanceFuturesClient:
    return BinanceFuturesClient(BinanceCredentials("", ""))


def binance_get_instruments(inst_type: str = "SWAP", inst_id: str = "", uly: str = "") -> dict[str, Any]:
    payload = _public_client().get_instruments(inst_type=inst_type, uly=uly)
    rows = payload.get("data") or []
    if inst_id:
        rows = [row for row in rows if str(row.get("instId") or "") == inst_id]
    return _ok(rows)


def binance_get_ticker(inst_id: str) -> dict[str, Any]:
    if not inst_id:
        raise BinanceApiError("instId不能为空")
    return _public_client().get_ticker(inst_id)


def binance_get_tickers(inst_type: str = "SWAP") -> dict[str, Any]:
    return _public_client().get_tickers(inst_type=inst_type)


def binance_get_last_prices(inst_ids: Optional[set[str]] = None) -> dict[str, Any]:
    return _public_client().get_last_prices(inst_ids=inst_ids)


def binance_get_candles(inst_id: str, bar: str = "1m", limit: int = 1) -> dict[str, Any]:
    if not inst_id:
        raise BinanceApiError("instId不能为空")
    return _public_client().get_candles(inst_id, bar=bar, limit=limit)


def binance_get_historical_candles(
    inst_id: str,
    bar: str = "1m",
    limit: int = 500,
    *,
    start_time: Optional[int] = None,
    end_time: Optional[int] = None,
) -> list[dict[str, str]]:
    if not inst_id:
        raise BinanceApiError("instId不能为空")
    return _public_client().get_historical_candles(
        inst_id, bar=bar, limit=limit, start_time=start_time, end_time=end_time
    )


def binance_get_derivatives_metrics(
    inst_id: str,
    period: str = "15m",
    *,
    history_limit: int = 60,
    funding_limit: int = 120,
) -> dict[str, Any]:
    """Fetch public USDⓈ-M sentiment inputs used by the market scanner.

    These endpoints do not require customer credentials.  Keep this function
    separate from the authenticated trading client so analysis can never reuse
    a user's order permissions.
    """
    symbol = _exchange_symbol(inst_id)
    normalized_period = _interval(period)
    query = {"symbol": symbol, "period": normalized_period, "limit": min(max(20, int(history_limit)), 500)}
    funding = _public_json_request("/fapi/v1/fundingRate", {"symbol": symbol, "limit": min(max(30, int(funding_limit)), 1000)})
    open_interest = _public_json_request("/futures/data/openInterestHist", query)
    long_short = _public_json_request("/futures/data/globalLongShortAccountRatio", query)
    taker = _public_json_request("/futures/data/takerlongshortRatio", query)
    return {
        "funding": funding if isinstance(funding, list) else [],
        "open_interest": open_interest if isinstance(open_interest, list) else [],
        "long_short": long_short if isinstance(long_short, list) else [],
        "taker": taker if isinstance(taker, list) else [],
    }
