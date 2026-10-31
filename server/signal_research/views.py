from datetime import datetime, timezone as dt_timezone
from statistics import median

from django.conf import settings
from django.db.models import F
from django.utils import timezone
from rest_framework.views import APIView

from common.binance import BinanceApiError
from common.errors import safe_error_summary
from common.response import fail, ok
from signal_research.ai import StrategyAiError, build_ai_request, build_research_packet, generate_strategy_draft, strategy_code, validate_definition
from signal_research.models import ResearchAiModel, ResearchAiModelSelection, ResearchStrategy, SignalSample
from signal_research.services import (
    STRATEGY_NAME,
    SUPPORTED_TIMEFRAMES,
    TIMEFRAME_MS,
    calculate_features,
    candle_payload,
    fetch_candles,
    format_rule_text,
    scan_backtest,
)
from trading.constants import ALLOWED_TRADING_SYMBOLS
from common.utils import aes_decrypt_with_metadata, aes_encrypt


def _symbol(value) -> str:
    return "".join(char for char in str(value or "").upper() if char.isalnum())


def _timeframe(value) -> str:
    return str(value or "").strip().lower()


def _timestamp(value):
    text = str(value or "").strip()
    if not text:
        return None
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
        if timezone.is_naive(parsed):
            parsed = timezone.make_aware(parsed, timezone.get_current_timezone())
        return parsed.astimezone(dt_timezone.utc)
    except (TypeError, ValueError):
        return None


def _serialize(sample: SignalSample, include_candles=False):
    payload = {
        "id": sample.id, "symbol": sample.symbol, "timeframe": sample.timeframe, "expected_direction": sample.expected_direction,
        "signal_time": sample.signal_time.isoformat(), "note": sample.note, "trusted": sample.trusted,
        "features": sample.features or {}, "fetched_at": sample.fetched_at.isoformat() if sample.fetched_at else "",
        "created_at": sample.created_at.isoformat(), "updated_at": sample.updated_at.isoformat(),
    }
    if include_candles:
        payload["candles"] = sample.candles or []
    return payload


def _serialize_strategy(item: ResearchStrategy):
    return {
        "id": item.id, "name": item.name, "version": item.version, "status": item.status,
        "provider": item.provider, "model": item.model, "natural_rules": item.natural_rules or [],
        "definition": item.definition or {}, "code": item.code, "rationale": item.rationale,
        "research_packet": item.research_packet or {}, "created_at": item.created_at.isoformat(),
        "published_at": item.published_at.isoformat() if item.published_at else "",
    }


def _model_config(request, profile_id=None):
    if not profile_id:
        profile_id = ResearchAiModelSelection.objects.filter(user=request.user).values_list("model_id", flat=True).first()
    if profile_id:
        profile = ResearchAiModel.objects.filter(id=profile_id).first()
        if not profile:
            return None, None
        encrypted = profile.api_key_encrypted
        api_key, is_legacy = aes_decrypt_with_metadata(encrypted)
        if is_legacy:
            upgraded = aes_encrypt(api_key)
            ResearchAiModel.objects.filter(pk=profile.pk, api_key_encrypted=encrypted).update(
                api_key_encrypted=upgraded
            )
            profile.api_key_encrypted = upgraded
        return profile, {"base_url": profile.base_url, "api_key": api_key, "model": profile.model}
    return None, {"base_url": settings.AI_BASE_URL, "api_key": settings.AI_API_KEY, "model": settings.AI_MODEL}


def _serialize_model(item: ResearchAiModel):
    return {"id": item.id, "name": item.name, "provider": item.provider, "base_url": item.base_url, "model": item.model, "is_active": item.is_active, "is_default": False}


def _ready_samples(user):
    # Legacy future samples may already carry ready features computed too early.
    # They become evidence only after a capture performed at/after sample time.
    return SignalSample.objects.filter(
        user=user, features__ready=True, signal_time__lte=timezone.now(),
        fetched_at__isnull=False, fetched_at__gte=F("signal_time"),
    )


class SampleListView(APIView):
    def get(self, request):
        return ok([_serialize(item) for item in SignalSample.objects.filter(user=request.user)[:500]])

    def post(self, request):
        payload = request.data if isinstance(request.data, dict) else {}
        symbol, timeframe, signal_time = _symbol(payload.get("symbol")), _timeframe(payload.get("timeframe")), _timestamp(payload.get("signal_time"))
        if symbol not in ALLOWED_TRADING_SYMBOLS:
            return fail("请选择允许列表中的合约币种")
        if timeframe not in SUPPORTED_TIMEFRAMES:
            return fail("K线周期不正确")
        if not signal_time:
            return fail("请填写已收盘K线的收盘时间")
        if signal_time > timezone.now():
            return fail("样本时间不能晚于当前时间，请选择已收盘K线")
        direction = str(payload.get("expected_direction") or SignalSample.DIRECTION_NEUTRAL)
        if direction not in {SignalSample.DIRECTION_LONG, SignalSample.DIRECTION_SHORT, SignalSample.DIRECTION_NEUTRAL}:
            return fail("预期方向不正确")
        note = str(payload.get("note") or "").strip()
        if len(note) > 2000:
            return fail("备注不能超过2000字")
        trusted = payload.get("trusted")
        if trusted not in (None, True, False):
            return fail("可信标记不正确")
        sample = SignalSample.objects.create(user=request.user, symbol=symbol, timeframe=timeframe, signal_time=signal_time, expected_direction=direction, note=note, trusted=trusted)
        return ok(_serialize(sample), "已保存")


class SampleDetailView(APIView):
    def get_object(self, request, sample_id):
        return SignalSample.objects.filter(id=sample_id, user=request.user).first()

    def get(self, request, sample_id):
        sample = self.get_object(request, sample_id)
        return ok(_serialize(sample, True)) if sample else fail("样本不存在", status=404)

    def patch(self, request, sample_id):
        sample = self.get_object(request, sample_id)
        if not sample:
            return fail("样本不存在", status=404)
        payload = request.data if isinstance(request.data, dict) else {}
        if "note" in payload:
            sample.note = str(payload.get("note") or "").strip()[:2000]
        if "trusted" in payload and payload["trusted"] in (None, True, False):
            sample.trusted = payload["trusted"]
        sample.save(update_fields=["note", "trusted", "updated_at"])
        return ok(_serialize(sample))

    def delete(self, request, sample_id):
        sample = self.get_object(request, sample_id)
        if not sample:
            return fail("样本不存在", status=404)
        sample.delete()
        return ok(message="已删除")


class FetchSampleView(APIView):
    def post(self, request, sample_id):
        sample = SignalSample.objects.filter(id=sample_id, user=request.user).first()
        if not sample:
            return fail("样本不存在", status=404)
        now = timezone.now()
        if sample.signal_time > now:
            return fail("样本时间不能晚于当前时间，请选择已收盘K线")
        closed_by = min(int(sample.signal_time.timestamp() * 1000), int(now.timestamp() * 1000))
        try:
            candles = fetch_candles(sample.symbol, sample.timeframe, end_time_ms=closed_by, limit=420)
        except BinanceApiError as exc:
            return fail(safe_error_summary(exc, include_type=False), status=502)
        if not candles:
            return fail("币安没有返回对应K线")
        # The exchange may include its current open bar even with an end time.
        # Keep only data already known at the sample time and at this request.
        candles = [row for row in candles if row["close_time"] <= closed_by]
        if not candles:
            return fail("没有对应的已收盘K线，请核对样本时间")
        sample.candles = candle_payload(candles)
        sample.features = calculate_features(candles, len(candles) - 1)
        sample.fetched_at = now
        sample.save(update_fields=["candles", "features", "fetched_at", "updated_at"])
        return ok(_serialize(sample, True), "数据已获取")


class RuleView(APIView):
    def get(self, request):
        samples = list(_ready_samples(request.user).filter(trusted=True))
        feature_rows = [item.features for item in samples if isinstance(item.features, dict)]
        evidence = []
        if feature_rows:
            distances = [float(row["close_to_ema21_atr"]) for row in feature_rows if isinstance(row.get("close_to_ema21_atr"), (int, float))]
            pullbacks = sum(bool(row.get("pullback_to_ema21")) for row in feature_rows)
            alignments = sum(row.get("ema_alignment") in ("多头排列", "空头排列") for row in feature_rows)
            if distances:
                evidence.append(f"可信样本中，收盘价距 EMA21 的中位数为 {median(distances):.3f} ATR。")
            evidence.append(f"{pullbacks}/{len(feature_rows)} 个可信样本发生了 EMA21 触及/回踩。")
            evidence.append(f"{alignments}/{len(feature_rows)} 个可信样本出现明确的 EMA 排列。")
        return ok({
            "name": STRATEGY_NAME, "trusted_sample_count": len(samples), "rules": format_rule_text(), "evidence": evidence,
            "code": "signal = supertrend_flip_within(8) and ema21_retest_confirmed()\nlong = trend == 1 and ema21 > ema55 and signal and low <= ema21 < close\nshort = trend == -1 and ema21 < ema55 and signal and high >= ema21 > close",
        })


class StrategyListView(APIView):
    def get(self, request):
        return ok([_serialize_strategy(item) for item in ResearchStrategy.objects.filter(user=request.user)[:100]])


class StrategyGenerateView(APIView):
    def post(self, request):
        samples = _ready_samples(request.user).filter(trusted__in=[True, False]).order_by("signal_time")
        packet = build_research_packet(samples)
        if packet["trusted_count"] < 1:
            return fail("请至少标记一个已采集的可信样本，再生成策略草案")
        profile_id = request.data.get("model_profile_id") if isinstance(request.data, dict) else None
        profile, config = _model_config(request, profile_id)
        if config is None:
            return fail("所选大模型不存在", status=404)
        try:
            draft = generate_strategy_draft(packet, config)
        except StrategyAiError as exc:
            return fail(safe_error_summary(exc, include_type=False), status=502)
        version = (ResearchStrategy.objects.filter(user=request.user, name=draft["name"]).order_by("-version").values_list("version", flat=True).first() or 0) + 1
        strategy = ResearchStrategy.objects.create(
            user=request.user, name=draft["name"], version=version, status=ResearchStrategy.STATUS_DRAFT,
            provider=profile.provider if profile else settings.AI_PROVIDER, model=config["model"], research_packet=packet, definition=draft["definition"],
            natural_rules=draft["natural_rules"], code=draft["code"], rationale=draft["rationale"],
        )
        return ok(_serialize_strategy(strategy), "AI 策略草案已生成，请审核后发布")


class StrategyPreviewView(APIView):
    def get(self, request):
        samples = _ready_samples(request.user).filter(trusted__in=[True, False]).order_by("signal_time")
        packet = build_research_packet(samples)
        profile_id = request.query_params.get("model_profile_id")
        profile, config = _model_config(request, profile_id)
        if config is None:
            return fail("所选大模型不存在", status=404)
        return ok({"packet": packet, "request": build_ai_request(packet, config)})


class AiModelListView(APIView):
    def get(self, request):
        selected_id = ResearchAiModelSelection.objects.filter(user=request.user).values_list("model_id", flat=True).first()
        rows = [_serialize_model(item) | {"is_active": item.id == selected_id} for item in ResearchAiModel.objects.all()]
        if settings.AI_API_KEY and settings.AI_BASE_URL and settings.AI_MODEL:
            rows.append({"id": 0, "name": "平台默认 GLM", "provider": settings.AI_PROVIDER or "platform", "base_url": settings.AI_BASE_URL, "model": settings.AI_MODEL, "is_active": not any(item["is_active"] for item in rows), "is_default": True})
        return ok(rows)

class AiModelActivateView(APIView):
    def post(self, request, model_id):
        item = ResearchAiModel.objects.filter(id=model_id).first()
        if not item:
            return fail("模型不存在", status=404)
        ResearchAiModelSelection.objects.update_or_create(user=request.user, defaults={"model": item})
        return ok(_serialize_model(item))


class StrategyDetailView(APIView):
    def get_object(self, request, strategy_id):
        return ResearchStrategy.objects.filter(id=strategy_id, user=request.user).first()

    def patch(self, request, strategy_id):
        item = self.get_object(request, strategy_id)
        if not item:
            return fail("策略不存在", status=404)
        if item.status == ResearchStrategy.STATUS_PUBLISHED:
            return fail("已发布版本不可修改，请生成新版本")
        payload = request.data if isinstance(request.data, dict) else {}
        updates = {}
        if "name" in payload:
            updates["name"] = str(payload.get("name") or "").strip()[:120] or item.name
        if "natural_rules" in payload and isinstance(payload["natural_rules"], list):
            updates["natural_rules"] = [str(rule).strip()[:600] for rule in payload["natural_rules"] if str(rule).strip()][:10]
        if "rationale" in payload:
            updates["rationale"] = str(payload.get("rationale") or "")[:4000]
        if "definition" in payload:
            try:
                updates["definition"] = validate_definition(payload["definition"])
                updates["code"] = strategy_code(updates["definition"])
            except StrategyAiError as exc:
                return fail(safe_error_summary(exc, include_type=False))
        # Compete with publication in one database write. A stale draft read
        # must never rewrite a version published while validation was running.
        if updates and not ResearchStrategy.objects.filter(
            pk=item.pk, user=request.user, status=ResearchStrategy.STATUS_DRAFT
        ).update(**updates):
            return fail("已发布版本不可修改，请生成新版本")
        item.refresh_from_db()
        return ok(_serialize_strategy(item))


class StrategyPublishView(APIView):
    def post(self, request, strategy_id):
        item = StrategyDetailView().get_object(request, strategy_id)
        if not item:
            return fail("策略不存在", status=404)
        ResearchStrategy.objects.filter(
            pk=item.pk, user=request.user, status=ResearchStrategy.STATUS_DRAFT
        ).update(status=ResearchStrategy.STATUS_PUBLISHED, published_at=timezone.now())
        item.refresh_from_db()
        return ok(_serialize_strategy(item), "策略版本已发布")


class BacktestView(APIView):
    def post(self, request):
        payload = request.data if isinstance(request.data, dict) else {}
        symbol, timeframe = _symbol(payload.get("symbol")), _timeframe(payload.get("timeframe"))
        try:
            strategy_id = int(payload.get("strategy_id"))
        except (TypeError, ValueError):
            return fail("请选择已发布的策略版本")
        strategy = ResearchStrategy.objects.filter(id=strategy_id, user=request.user, status=ResearchStrategy.STATUS_PUBLISHED).first()
        if not strategy:
            return fail("请选择已发布的策略版本")
        start, end = _timestamp(payload.get("start_time")), _timestamp(payload.get("end_time"))
        if symbol not in ALLOWED_TRADING_SYMBOLS or timeframe not in SUPPORTED_TIMEFRAMES:
            return fail("币种或周期不正确")
        if not start or not end or start >= end:
            return fail("请选择有效的回测时间范围")
        try:
            rows = scan_backtest(symbol, timeframe, int(start.timestamp() * 1000), int(end.timestamp() * 1000), strategy.definition)
        except BinanceApiError as exc:
            return fail(safe_error_summary(exc, include_type=False), status=502)
        return ok({"strategy": _serialize_strategy(strategy), "results": rows})


class ChartView(APIView):
    def get(self, request):
        symbol, timeframe = _symbol(request.query_params.get("symbol")), _timeframe(request.query_params.get("timeframe"))
        signal_time = _timestamp(request.query_params.get("signal_time"))
        if symbol not in ALLOWED_TRADING_SYMBOLS or timeframe not in SUPPORTED_TIMEFRAMES or not signal_time:
            return fail("图表参数不正确")
        try:
            candles = fetch_candles(symbol, timeframe, end_time_ms=int(signal_time.timestamp() * 1000) + 80 * TIMEFRAME_MS[timeframe], limit=300)
        except BinanceApiError as exc:
            return fail(safe_error_summary(exc, include_type=False), status=502)
        return ok({"candles": candle_payload(candles), "signal_time": int(signal_time.timestamp() * 1000)})
