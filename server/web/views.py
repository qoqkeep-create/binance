from django.db import transaction
from django.utils import timezone
from rest_framework.views import APIView

from common.request import request_data_mapping
from common.response import fail, ok
from web.models import WebSettings
from web.serializers import SettingsPatchSerializer
from web.validation import SettingsValidationError, merge_settings


def _payload(row):
    return {
        "settings": row.settings if isinstance(row.settings, dict) else {},
        "version": row.version,
        "updatedAt": row.updated_at.isoformat() if row.updated_at else timezone.now().isoformat(),
    }


class WebSettingsView(APIView):
    """Read and atomically update preferences for the authenticated Web user."""

    def get(self, request):
        row, _ = WebSettings.objects.get_or_create(user=request.user)
        return ok(_payload(row))

    def patch(self, request):
        data = request_data_mapping(request)
        if data is None:
            return fail("请求参数必须是对象")
        serializer = SettingsPatchSerializer(data=data)
        if not serializer.is_valid():
            detail = serializer.errors
            message = next(iter(next(iter(detail.values()), ["请求参数错误"])), "请求参数错误")
            return fail(str(message))
        with transaction.atomic():
            row, _ = WebSettings.objects.select_for_update().get_or_create(user=request.user)
            if serializer.validated_data["baseVersion"] != row.version:
                return fail("设置已在其他页面更新。", code=409, status=409, data=_payload(row))
            try:
                row.settings = merge_settings(row.settings, serializer.validated_data["patch"])
            except SettingsValidationError as exc:
                return fail(str(exc))
            row.version += 1
            row.save(update_fields=["settings", "version", "updated_at"])
        return ok(_payload(row))
