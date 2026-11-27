"""Validation for Web terminal preferences.

Only the settings used by the existing Web UI are persisted. This keeps the
API compatible with the original Flask service while using the iOS account.
"""

import json
import math
import re
import unicodedata

from rest_framework import serializers


class SettingsValidationError(serializers.ValidationError):
    pass


def _visible_text(value: object, *, max_length: int, message: str, min_length: int = 0) -> str:
    if (not isinstance(value, str) or len(value) < min_length or len(value) > max_length
            or any(unicodedata.category(ch).startswith("C") for ch in value)):
        raise SettingsValidationError(message)
    return value


def _validate_chart(value: object) -> dict:
    if not isinstance(value, dict) or set(value) - {"interval", "timeFrame", "chartType", "studies"}:
        raise SettingsValidationError("图表设置字段不正确。")
    result = {}
    for key, item in value.items():
        if key == "interval":
            if not isinstance(item, str) or not re.fullmatch(r"(?:[1-9][0-9]{0,4}[SMHDW]?|[DWM])", item):
                raise SettingsValidationError("图表周期无效。")
        elif key == "timeFrame":
            if not isinstance(item, str) or not (item == "all" or re.fullmatch(r"[1-9][0-9]{0,3}[smhdwMyY]", item)):
                raise SettingsValidationError("图表时间范围无效。")
        elif key == "chartType":
            if not isinstance(item, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,32}", item):
                raise SettingsValidationError("图表类型无效。")
        elif key == "studies":
            if not isinstance(item, list) or len(item) > 24:
                raise SettingsValidationError("图表指标设置过多。")
            for study in item:
                if not isinstance(study, dict) or set(study) - {"id", "overlay", "inputs"} or "id" not in study:
                    raise SettingsValidationError("图表指标格式不正确。")
                _visible_text(study["id"], max_length=120, min_length=1, message="图表指标标识无效。")
                if "overlay" in study and type(study["overlay"]) is not bool:
                    raise SettingsValidationError("图表指标叠加设置无效。")
                if "inputs" in study:
                    inputs = study["inputs"]
                    if not isinstance(inputs, dict) or len(inputs) > 128:
                        raise SettingsValidationError("图表指标参数过多。")
                    for name, setting in inputs.items():
                        _visible_text(name, max_length=80, min_length=1, message="图表指标参数标识无效。")
                        if setting is not None and type(setting) not in (str, bool, int, float):
                            raise SettingsValidationError("图表指标参数须为简单值。")
                        if isinstance(setting, str) and (len(setting) > 256 or any(unicodedata.category(ch).startswith("C") for ch in setting)):
                            raise SettingsValidationError("图表指标参数过长。")
                        if type(setting) in (int, float) and (abs(setting) > 1e15 or not math.isfinite(setting)):
                            raise SettingsValidationError("图表指标参数数值无效。")
        result[key] = item
    if len(json.dumps(result, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")) > 32 * 1024:
        raise SettingsValidationError("图表设置不能超过 32KB。")
    return result


def _validate_position_tools(value: object) -> dict:
    if not isinstance(value, dict) or set(value) - {"defaults", "positions"}:
        raise SettingsValidationError("多空测量设置字段不正确。")
    defaults = value.get("defaults")
    positions = value.get("positions")
    required_defaults = {"accountSize", "riskMode", "riskValue", "lotSize", "leverage", "qtyPrecision", "priceRangePercent"}
    if not isinstance(defaults, dict) or set(defaults) != required_defaults or defaults.get("riskMode") not in {"percent", "currency"}:
        raise SettingsValidationError("多空测量默认设置不正确。")
    for key in required_defaults - {"riskMode"}:
        item = defaults[key]
        if not isinstance(item, (int, float)) or isinstance(item, bool) or not math.isfinite(item):
            raise SettingsValidationError("多空测量默认设置数值不正确。")
    if (defaults["accountSize"] <= 0 or defaults["riskValue"] <= 0 or defaults["lotSize"] <= 0
            or defaults["leverage"] <= 0 or not 0 <= defaults["qtyPrecision"] <= 8
            or defaults["qtyPrecision"] % 1 or not 0 < defaults["priceRangePercent"] <= 200):
        raise SettingsValidationError("多空测量默认设置超出范围。")
    if not isinstance(positions, list) or len(positions) > 12:
        raise SettingsValidationError("多空测量对象过多。")
    position_fields = {"id", "direction", "left", "right", "entryY", "targetY", "stopY", "createdAt"}
    for position in positions:
        if not isinstance(position, dict) or set(position) != position_fields or position["direction"] not in {"long", "short"}:
            raise SettingsValidationError("多空测量对象格式不正确。")
        _visible_text(position["id"], max_length=80, min_length=1, message="多空测量对象标识不正确。")
        numbers = [position[key] for key in ("left", "right", "entryY", "targetY", "stopY", "createdAt")]
        if any(not isinstance(item, (int, float)) or isinstance(item, bool) or not math.isfinite(item) for item in numbers):
            raise SettingsValidationError("多空测量对象数值不正确。")
        if (not 0 <= position["left"] < position["right"] <= 1
                or any(not 0 <= position[key] <= 1 for key in ("entryY", "targetY", "stopY"))):
            raise SettingsValidationError("多空测量对象位置不正确。")
    if len(json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")) > 32 * 1024:
        raise SettingsValidationError("多空测量设置不能超过 32KB。")
    return value


def validate_patch(value: object) -> dict:
    if not isinstance(value, dict):
        raise SettingsValidationError("设置须为 JSON 对象。")
    enums = {
        "theme": {"dark", "light"},
        "activeNav": {"行情", "信号", "引擎"},
        "marketGroup": {"top20", "alts", "gainers", "losers"},
        "assistantTopInterval": {"2m", "5m", "10m"},
    }
    allowed = set(enums) | {"selectedSymbol", "marketQuery", "showInsightPanel", "chart", "positionTools"}
    if set(value) - allowed:
        raise SettingsValidationError("包含不支持的个人设置。")
    result = {}
    for key, item in value.items():
        if key in enums and (not isinstance(item, str) or item not in enums[key]):
            raise SettingsValidationError("个人设置选项无效。")
        if key == "selectedSymbol" and (not isinstance(item, str) or not re.fullmatch(r"[A-Z0-9]{1,30}USDT", item)):
            raise SettingsValidationError("合约标识无效。")
        if key == "marketQuery":
            _visible_text(item, max_length=80, message="搜索条件须不超过 80 个可见字符。")
        if key == "showInsightPanel" and type(item) is not bool:
            raise SettingsValidationError("面板设置须为布尔值。")
        result[key] = _validate_chart(item) if key == "chart" else _validate_position_tools(item) if key == "positionTools" else item
    return result


def merge_settings(existing: object, patch: object) -> dict:
    current = existing if isinstance(existing, dict) else {}
    checked = validate_patch(patch)
    merged = {**current, **checked}
    if isinstance(current.get("chart"), dict) and isinstance(checked.get("chart"), dict):
        merged["chart"] = {**current["chart"], **checked["chart"]}
    return validate_patch(merged)
