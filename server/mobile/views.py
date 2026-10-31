from rest_framework.views import APIView
from common.response import fail, ok
from common.trading_mode import request_trading_mode
from mobile.commands import command_view, submit
from mobile.models import TradingCommand


class CommandsView(APIView):
    def get(self, request):
        rows = TradingCommand.objects.filter(user=request.user, trading_mode=request_trading_mode(request)).order_by("-created_at")[:100]
        return ok([command_view(row) for row in rows])

    def post(self, request):
        try:
            if not isinstance(request.data, dict):
                raise ValueError("请求参数必须是对象")
            command = submit(request.user, request_trading_mode(request), request.data.get("action"),
                             request.data.get("payload"), request.headers.get("Idempotency-Key", ""))
        except (ValueError, TypeError) as exc:
            return fail(str(exc), code=409, status=409)
        return ok(command_view(command), message="命令已持久化，等待执行")


class CommandDetailView(APIView):
    def get(self, request, command_id):
        command = TradingCommand.objects.filter(pk=command_id, user=request.user, trading_mode=request_trading_mode(request)).first()
        if command is None:
            return fail("命令不存在", code=404, status=404)
        return ok(command_view(command))
