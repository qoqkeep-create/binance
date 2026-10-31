from rest_framework import serializers
from rest_framework.views import APIView

from common.response import fail, ok
from common.trading_mode import request_trading_mode
from positions.operation_logs import get_operation_logs


class OperationLogQuerySerializer(serializers.Serializer):
    cursor = serializers.CharField(required=False, default="", allow_blank=True, max_length=1000)
    limit = serializers.IntegerField(required=False, default=20, min_value=1, max_value=50)


class OperationLogView(APIView):
    def get(self, request):
        query = OperationLogQuerySerializer(data=request.query_params)
        if not query.is_valid():
            return fail("日志分页参数无效")
        try:
            data = get_operation_logs(request.user, trading_mode=request_trading_mode(request), **query.validated_data)
        except ValueError as exc:
            return fail(str(exc))
        return ok(data=data)
