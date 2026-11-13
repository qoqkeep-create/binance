from rest_framework.views import APIView

from common.request import request_data_mapping
from common.response import fail, ok
from plans.models import TradingPlan
from plans.serializers import TradingPlanSerializer


def _payload(instance):
    return TradingPlanSerializer(instance).data


def _first_error(errors):
    if not errors:
        return "请求参数错误"
    key = next(iter(errors))
    value = errors[key]
    if isinstance(value, list) and value:
        return str(value[0])
    return str(value)


class TradingPlanListCreateView(APIView):
    def get(self, request):
        rows = TradingPlan.objects.filter(user=request.user)
        return ok(data=[_payload(row) for row in rows])

    def post(self, request):
        payload = request_data_mapping(request)
        if payload is None:
            return fail("请求参数必须是对象")
        serializer = TradingPlanSerializer(data=payload)
        if not serializer.is_valid():
            return fail(_first_error(serializer.errors))
        row = serializer.save(user=request.user)
        return ok(message="保存成功", data=_payload(row))


class TradingPlanDetailView(APIView):
    def _get(self, request, plan_id):
        return TradingPlan.objects.filter(id=plan_id, user=request.user).first()

    def get(self, request, plan_id):
        row = self._get(request, plan_id)
        if row is None:
            return fail("计划不存在", status=404)
        return ok(data=_payload(row))

    def patch(self, request, plan_id):
        return self._save(request, plan_id, partial=True)

    def put(self, request, plan_id):
        return self._save(request, plan_id, partial=False)

    def delete(self, request, plan_id):
        row = self._get(request, plan_id)
        if row is None:
            return fail("计划不存在", status=404)
        row.delete()
        return ok(message="删除成功", data=None)

    def _save(self, request, plan_id, *, partial):
        row = self._get(request, plan_id)
        if row is None:
            return fail("计划不存在", status=404)
        payload = request_data_mapping(request)
        if payload is None:
            return fail("请求参数必须是对象")
        serializer = TradingPlanSerializer(row, data=payload, partial=partial)
        if not serializer.is_valid():
            return fail(_first_error(serializer.errors))
        serializer.save()
        return ok(message="保存成功", data=_payload(row))