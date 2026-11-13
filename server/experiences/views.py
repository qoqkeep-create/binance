from rest_framework.views import APIView

from common.request import request_data_mapping
from common.response import fail, ok
from experiences.models import TradingExperience
from experiences.oss import OSSConfigurationError, create_presigned_put
from experiences.serializers import TradingExperienceSerializer


def _payload(instance):
    return TradingExperienceSerializer(instance).data


class TradingExperienceListCreateView(APIView):
    def get(self, request):
        rows = TradingExperience.objects.filter(user=request.user)
        return ok(data=[_payload(row) for row in rows])

    def post(self, request):
        payload = request_data_mapping(request)
        if payload is None:
            return fail("请求参数必须是对象")
        serializer = TradingExperienceSerializer(data=payload)
        if not serializer.is_valid():
            return fail(_first_error(serializer.errors))
        row = serializer.save(user=request.user)
        return ok(message="保存成功", data=_payload(row))


class TradingExperienceDetailView(APIView):
    def _get(self, request, experience_id):
        return TradingExperience.objects.filter(id=experience_id, user=request.user).first()

    def get(self, request, experience_id):
        row = self._get(request, experience_id)
        if row is None:
            return fail("交易经验不存在", status=404)
        return ok(data=_payload(row))

    def patch(self, request, experience_id):
        return self._save(request, experience_id, partial=True)

    def put(self, request, experience_id):
        return self._save(request, experience_id, partial=False)

    def delete(self, request, experience_id):
        row = self._get(request, experience_id)
        if row is None:
            return fail("交易经验不存在", status=404)
        row.delete()
        return ok(message="删除成功", data=None)

    def _save(self, request, experience_id, *, partial):
        row = self._get(request, experience_id)
        if row is None:
            return fail("交易经验不存在", status=404)
        payload = request_data_mapping(request)
        if payload is None:
            return fail("请求参数必须是对象")
        serializer = TradingExperienceSerializer(row, data=payload, partial=partial)
        if not serializer.is_valid():
            return fail(_first_error(serializer.errors))
        row = serializer.save()
        return ok(message="保存成功", data=_payload(row))


class TradingExperienceUploadUrlView(APIView):
    """Return a short-lived browser-to-OSS upload URL for one image."""

    def post(self, request):
        payload = request_data_mapping(request)
        if payload is None:
            return fail("请求参数必须是对象")
        content_type = str(payload.get("content_type") or "").strip().lower()
        try:
            size = int(payload.get("size"))
        except (TypeError, ValueError):
            return fail("图片大小格式错误")
        try:
            data = create_presigned_put(
                user_id=request.user.id,
                content_type=content_type,
                size=size,
            )
        except OSSConfigurationError as exc:
            return fail(str(exc), code=503, status=503)
        except ValueError as exc:
            return fail(str(exc))
        return ok(data=data)


def _first_error(errors):
    if not errors:
        return "请求参数错误"
    key = next(iter(errors))
    value = errors[key]
    if isinstance(value, list) and value:
        return str(value[0])
    return str(value)
