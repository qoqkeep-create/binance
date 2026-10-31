"""Provider-neutral, explicitly invoked AI analysis for signal research."""
from __future__ import annotations

import json
from collections import Counter
from statistics import median
from typing import Any
from urllib import error, request
from urllib.parse import urlsplit

from django.conf import settings


class StrategyAiError(Exception):
    pass


def validate_ai_base_url(value: str) -> str:
    base_url = str(value or "").strip()
    if any(char in base_url for char in "\r\n\t"):
        raise StrategyAiError("AI 服务地址格式不正确")
    try:
        parsed = urlsplit(base_url)
        _ = parsed.port
    except ValueError as exc:
        raise StrategyAiError("AI 服务地址格式不正确") from exc
    if parsed.scheme.lower() not in {"http", "https"} or not parsed.hostname:
        raise StrategyAiError("AI 服务地址必须使用 HTTP 或 HTTPS")
    if parsed.username is not None or parsed.password is not None:
        raise StrategyAiError("AI 服务地址不能包含用户名或密码")
    if parsed.query or parsed.fragment:
        raise StrategyAiError("AI 服务地址不能包含查询参数或片段")
    return base_url.rstrip("/")


DEFAULT_DEFINITION = {
    "flip_window": 8,
    "min_ema_gap_atr": 0.0,
    "max_close_distance_atr": 0.35,
    "require_ema144_alignment": False,
}

FEATURE_GUIDE = {
    "trend": "EMA 排列、归一化斜率、SuperTrend 状态与持续时间，衡量方向和成熟度。",
    "position": "相对 EMA、20/55 根高低点和布林带的位置，衡量是否处于追涨杀跌或合理回踩位置。",
    "volatility": "ATR、20 根收益波动率和布林带宽度，衡量环境是否扩张、收缩或异常。",
    "candle": "实体、上下影线、收盘位置均按 ATR 归一化，衡量该根 K 的确认质量。",
    "volume": "相对均量与 Z 分数，衡量价格动作是否得到量能确认。",
}

SYSTEM_PROMPT = """你是严谨的量化研究助理。基于已标注的币安合约单周期、已收盘 K 线样本，提出一个可审查的 EMA + SuperTrend 回踩策略草案。研究目标不是预测收益，而是找出可信与不可信样本间可复现、可量化且不使用未来数据的差异。先比较正反例，再提出少量具有统计意义的条件；不要凭单个样本过拟合；明确指出样本不足或冲突。只输出 JSON，不要 markdown。JSON 格式：{"name":"...","natural_rules":["..."],"rationale":"说明正反例差异、风险和样本不足","definition":{"flip_window":8,"min_ema_gap_atr":0,"max_close_distance_atr":0.35,"require_ema144_alignment":false}}。所有 definition 参数必须在给定字段内。"""
MAX_AI_RESPONSE_BYTES = 2 * 1024 * 1024


def build_research_packet(samples) -> dict[str, Any]:
    rows = []
    for sample in samples:
        features = sample.features if isinstance(sample.features, dict) else {}
        rows.append({
            "symbol": sample.symbol,
            "timeframe": sample.timeframe,
            "expected_direction": sample.expected_direction,
            "signal_time": sample.signal_time.isoformat(),
            "note": sample.note[:600],
            "trusted": sample.trusted,
            "features": features,
        })
    ready = [row for row in rows if row["features"].get("ready")]
    distances = [float(row["features"]["close_to_ema21_atr"]) for row in ready if isinstance(row["features"].get("close_to_ema21_atr"), (int, float))]
    return {
        "schema_version": 1,
        "data_scope": "仅使用录入周期自身的已收盘 K 线；不包含更高周期、未来 K 线或账户数据。",
        "feature_guide": FEATURE_GUIDE,
        "sample_count": len(rows),
        "trusted_count": sum(row["trusted"] is True for row in rows),
        "rejected_count": sum(row["trusted"] is False for row in rows),
        "summary": {
            "timeframes": dict(Counter(row["timeframe"] for row in rows)),
            "median_close_to_ema21_atr": round(median(distances), 4) if distances else None,
        },
        "samples": rows[:100],
    }


def build_ai_request(packet: dict[str, Any], config: dict[str, str] | None = None) -> dict[str, Any]:
    config = config or {"model": settings.AI_MODEL}
    return {
        "model": config["model"],
        "messages": [{"role": "system", "content": SYSTEM_PROMPT}, {"role": "user", "content": json.dumps(packet, ensure_ascii=False)}],
        "temperature": 0.2,
    }


def _extract_json(content: str) -> dict[str, Any]:
    text = str(content or "").strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[1] if "\n" in text else ""
        if text.rstrip().endswith("```"):
            text = text.rstrip()[:-3]
    try:
        parsed = json.loads(text)
    except (TypeError, ValueError) as exc:
        raise StrategyAiError("模型没有返回有效的 JSON 策略草案") from exc
    if not isinstance(parsed, dict):
        raise StrategyAiError("模型返回的策略草案格式不正确")
    return parsed


def validate_definition(value: Any) -> dict[str, Any]:
    raw = value if isinstance(value, dict) else {}
    definition = dict(DEFAULT_DEFINITION)
    try:
        definition["flip_window"] = max(1, min(20, int(raw.get("flip_window", definition["flip_window"]))))
        definition["min_ema_gap_atr"] = max(0, min(5, float(raw.get("min_ema_gap_atr", definition["min_ema_gap_atr"]))))
        definition["max_close_distance_atr"] = max(0.05, min(3, float(raw.get("max_close_distance_atr", definition["max_close_distance_atr"]))))
        definition["require_ema144_alignment"] = bool(raw.get("require_ema144_alignment", False))
    except (TypeError, ValueError) as exc:
        raise StrategyAiError("策略参数格式不正确") from exc
    return definition


def strategy_code(definition: dict[str, Any]) -> str:
    return "\n".join([
        f"flip_window = {definition['flip_window']}",
        f"min_ema_gap_atr = {definition['min_ema_gap_atr']}",
        f"max_close_distance_atr = {definition['max_close_distance_atr']}",
        f"require_ema144_alignment = {definition['require_ema144_alignment']}",
        "long = recent_supertrend_flip('up', flip_window) and ema21 > ema55 and low <= ema21 < close",
        "short = recent_supertrend_flip('down', flip_window) and ema21 < ema55 and high >= ema21 > close",
    ])


def _decode_ai_response(raw: bytes) -> Any:
    if len(raw) > MAX_AI_RESPONSE_BYTES:
        raise StrategyAiError("AI 服务返回内容过大")
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise StrategyAiError("AI 服务返回格式不正确") from exc


def generate_strategy_draft(packet: dict[str, Any], config: dict[str, str] | None = None) -> dict[str, Any]:
    config = config or {"base_url": settings.AI_BASE_URL, "api_key": settings.AI_API_KEY, "model": settings.AI_MODEL}
    if not config.get("api_key") or not config.get("base_url") or not config.get("model"):
        raise StrategyAiError("AI 尚未配置：请联系管理员设置 AI_PROVIDER、AI_BASE_URL、AI_MODEL 与 AI_API_KEY")
    base_url = validate_ai_base_url(config["base_url"])
    body = json.dumps(build_ai_request(packet, config), ensure_ascii=False).encode("utf-8")
    url = f"{base_url}/chat/completions"
    req = request.Request(url, data=body, method="POST", headers={"Authorization": f"Bearer {config['api_key']}", "Content-Type": "application/json"})
    try:
        with request.urlopen(req, timeout=settings.AI_TIMEOUT_SECONDS) as response:
            raw_response = response.read(MAX_AI_RESPONSE_BYTES + 1)
    except error.HTTPError as exc:
        raise StrategyAiError(f"AI 服务请求失败（HTTP {exc.code}）") from exc
    except Exception as exc:
        raise StrategyAiError("AI 服务连接失败，请稍后重试") from exc
    payload = _decode_ai_response(raw_response)
    try:
        content = payload["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as exc:
        raise StrategyAiError("AI 服务返回格式不正确") from exc
    draft = _extract_json(content)
    definition = validate_definition(draft.get("definition"))
    rules = [str(item).strip()[:600] for item in draft.get("natural_rules", []) if str(item).strip()][:10]
    if not rules:
        raise StrategyAiError("AI 草案缺少规则说明")
    return {"name": str(draft.get("name") or "AI 策略草案")[:120], "natural_rules": rules, "rationale": str(draft.get("rationale") or "")[:4000], "definition": definition, "code": strategy_code(definition)}
