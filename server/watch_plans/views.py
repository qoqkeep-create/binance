from decimal import Decimal, InvalidOperation
from typing import Optional

from django.utils import timezone
from rest_framework.views import APIView

from common.response import fail, ok
from watch_plans.models import WatchPlan
from trading.constants import ALLOWED_TRADING_SYMBOLS


def _normalize_symbol(text: str) -> str:
    return "".join(ch for ch in str(text or "").strip().upper() if ch.isalnum())[:50]


def _parse_int(value, default: int) -> int:
    try:
        parsed = int(str(value))
    except Exception:
        return default
    return parsed


def _parse_decimal_amount(value) -> Optional[Decimal]:
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    try:
        return Decimal(text)
    except (InvalidOperation, ValueError, TypeError):
        return None


def _parse_timeframe(value: str) -> Optional[str]:
    text = str(value or "").strip().lower()
    allowed = {
        WatchPlan.TIMEFRAME_15M,
        WatchPlan.TIMEFRAME_1H,
        WatchPlan.TIMEFRAME_4H,
        WatchPlan.TIMEFRAME_1D,
    }
    if text in allowed:
        return text
    return None


def _parse_plan_type(value) -> Optional[int]:
    parsed = _parse_int(value, WatchPlan.PLAN_TYPE_LEFT)
    if parsed in (WatchPlan.PLAN_TYPE_LEFT, WatchPlan.PLAN_TYPE_RIGHT):
        return parsed
    return None


def _parse_plan_date(value) -> Optional[timezone.datetime.date]:
    text = str(value or "").strip()
    if not text:
        return None
    try:
        return timezone.datetime.fromisoformat(f"{text}T00:00:00").date()
    except Exception:
        return None


def _serialize_decimal_amount(value: Optional[Decimal]) -> str:
    if value is None:
        return ""
    return format(value, ".2f")


def _serialize_item(item: WatchPlan) -> dict:
    return {
        "id": item.id,
        "symbol": item.symbol,
        "plan_date": item.plan_date.isoformat() if item.plan_date else "",
        "plan_type": item.plan_type,
        "timeframe": item.timeframe,
        "direction": item.direction,
        "content": item.content,
        "take_profit_expectation": item.take_profit_expectation,
        "review_content": item.review_content,
        "status": item.status,
        "result": item.result,
        "result_amount": _serialize_decimal_amount(item.result_amount),
        "score": item.score,
        "score_payload": item.score_payload if isinstance(item.score_payload, dict) else {},
        "created_at": item.created_at.isoformat() if item.created_at else "",
        "updated_at": item.updated_at.isoformat() if item.updated_at else "",
    }


class WatchPlanListView(APIView):
    def get(self, request):
        qs = WatchPlan.objects.filter(user=request.user).order_by("-created_at", "-id")
        rows = []
        for item in qs[:500]:
            rows.append(_serialize_item(item))
        return ok(data=rows)


class WatchPlanCreateView(APIView):
    def post(self, request):
        payload = request.data if isinstance(request.data, dict) else {}
        symbol = _normalize_symbol(payload.get("symbol") or "")
        if not symbol:
            return fail("交易对不能为空")
        if symbol not in ALLOWED_TRADING_SYMBOLS:
            return fail("交易对不在允许列表")
        plan_date = _parse_plan_date(payload.get("plan_date")) or timezone.localdate()
        plan_type = _parse_plan_type(payload.get("plan_type"))
        if plan_type is None:
            return fail("类型不正确")
        timeframe = _parse_timeframe(payload.get("timeframe") or "")
        if not timeframe:
            return fail("时间周期不正确")
        direction = _parse_int(payload.get("direction"), WatchPlan.DIRECTION_LONG)
        if direction not in (WatchPlan.DIRECTION_LONG, WatchPlan.DIRECTION_SHORT):
            return fail("方向不正确")
        content = str(payload.get("content") or "").strip()
        if len(content) > 5000:
            return fail("内容过长")
        take_profit_expectation = str(payload.get("take_profit_expectation") or "").strip()
        if len(take_profit_expectation) > 5000:
            return fail("止盈预期过长")

        item = WatchPlan.objects.create(
            user=request.user,
            symbol=symbol,
            plan_date=plan_date,
            plan_type=plan_type,
            timeframe=timeframe,
            direction=direction,
            content=content,
            take_profit_expectation=take_profit_expectation,
            review_content="",
            status=WatchPlan.STATUS_DEFAULT,
            result=WatchPlan.RESULT_NONE,
            result_amount=None,
            score=None,
            score_payload={},
        )
        return ok(data=_serialize_item(item), message="创建成功")


class WatchPlanUpdateView(APIView):
    def post(self, request):
        payload = request.data if isinstance(request.data, dict) else {}
        item_id = _parse_int(payload.get("id"), 0)
        if item_id <= 0:
            return fail("记录ID不正确")
        item = WatchPlan.objects.filter(id=item_id, user=request.user).first()
        if not item:
            return fail("记录不存在", status=404)

        symbol = payload.get("symbol")
        plan_date = payload.get("plan_date")
        plan_type = payload.get("plan_type")
        timeframe = payload.get("timeframe")
        direction = payload.get("direction")
        content = payload.get("content")
        take_profit_expectation = payload.get("take_profit_expectation")
        review_content = payload.get("review_content")
        status = payload.get("status")
        result = payload.get("result")
        result_amount = payload.get("result_amount")
        has_score = "score" in payload
        has_score_payload = "score_payload" in payload

        update_fields = ["updated_at"]

        if symbol is not None:
            next_symbol = _normalize_symbol(symbol)
            if not next_symbol:
                return fail("交易对不能为空")
            if next_symbol not in ALLOWED_TRADING_SYMBOLS:
                return fail("交易对不在允许列表")
            item.symbol = next_symbol
            update_fields.append("symbol")

        if plan_date is not None:
            next_plan_date = _parse_plan_date(plan_date)
            if not next_plan_date:
                return fail("日期不正确")
            item.plan_date = next_plan_date
            update_fields.append("plan_date")

        if plan_type is not None:
            next_plan_type = _parse_plan_type(plan_type)
            if next_plan_type is None:
                return fail("类型不正确")
            item.plan_type = next_plan_type
            update_fields.append("plan_type")

        if timeframe is not None:
            next_timeframe = _parse_timeframe(timeframe)
            if not next_timeframe:
                return fail("时间周期不正确")
            item.timeframe = next_timeframe
            update_fields.append("timeframe")

        if direction is not None:
            next_direction = _parse_int(direction, item.direction)
            if next_direction not in (WatchPlan.DIRECTION_LONG, WatchPlan.DIRECTION_SHORT):
                return fail("方向不正确")
            item.direction = next_direction
            update_fields.append("direction")

        if content is not None:
            next_content = str(content or "")
            if len(next_content) > 5000:
                return fail("内容过长")
            item.content = next_content
            update_fields.append("content")

        if take_profit_expectation is not None:
            next_take_profit_expectation = str(take_profit_expectation or "")
            if len(next_take_profit_expectation) > 5000:
                return fail("止盈预期过长")
            item.take_profit_expectation = next_take_profit_expectation
            update_fields.append("take_profit_expectation")

        if review_content is not None:
            next_review = str(review_content or "")
            if len(next_review) > 5000:
                return fail("复盘内容过长")
            item.review_content = next_review
            update_fields.append("review_content")

        if status is not None:
            next_status = _parse_int(status, item.status)
            if next_status not in (WatchPlan.STATUS_DEFAULT, WatchPlan.STATUS_DONE, WatchPlan.STATUS_SKIPPED):
                return fail("状态不正确")
            item.status = next_status
            update_fields.append("status")

        if result is not None:
            next_result = _parse_int(result, item.result)
            if next_result not in (WatchPlan.RESULT_NONE, WatchPlan.RESULT_STOP_LOSS, WatchPlan.RESULT_TAKE_PROFIT):
                return fail("结果不正确")
            item.result = next_result
            if next_result == WatchPlan.RESULT_NONE:
                item.result_amount = None
                update_fields.append("result_amount")
            update_fields.append("result")

        if result_amount is not None:
            raw_amount = str(result_amount).strip()
            next_amount = _parse_decimal_amount(result_amount)
            if item.result == WatchPlan.RESULT_NONE:
                if raw_amount:
                    return fail("请先选择止盈或止损")
                item.result_amount = None
            else:
                if not raw_amount:
                    item.result_amount = None
                else:
                    if next_amount is None or next_amount < 0:
                        return fail("止盈止损金额不能小于0")
                    item.result_amount = next_amount
            update_fields.append("result_amount")

        if has_score:
            raw_score = payload.get("score")
            if raw_score in (None, ""):
                item.score = None
                item.score_payload = {}
                update_fields.extend(["score", "score_payload"])
            else:
                next_score = _parse_int(raw_score, -1)
                if next_score < 0 or next_score > 100:
                    return fail("评分必须在0到100之间")
                item.score = next_score
                update_fields.append("score")

        if has_score_payload:
            next_payload = payload.get("score_payload")
            if next_payload in (None, ""):
                item.score_payload = {}
            elif isinstance(next_payload, dict):
                item.score_payload = next_payload
            else:
                return fail("评分明细格式不正确")
            update_fields.append("score_payload")

        item.updated_at = timezone.now()
        item.save(update_fields=sorted(set(update_fields)))
        return ok(data=_serialize_item(item), message="更新成功")


class WatchPlanDeleteView(APIView):
    def post(self, request):
        payload = request.data if isinstance(request.data, dict) else {}
        item_id = _parse_int(payload.get("id"), 0)
        if item_id <= 0:
            return fail("记录ID不正确")
        deleted, _ = WatchPlan.objects.filter(id=item_id, user=request.user).delete()
        if not deleted:
            return fail("记录不存在", status=404)
        return ok(message="删除成功")
