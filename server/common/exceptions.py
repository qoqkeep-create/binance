from rest_framework.response import Response
from rest_framework.views import exception_handler

from api_bindings.exceptions import ApiBindingConflictError


def custom_exception_handler(exc, context):
    if isinstance(exc, ApiBindingConflictError):
        return Response(
            {"code": 409, "message": str(exc), "data": None},
            status=409,
        )
    response = exception_handler(exc, context)
    if response is None:
        return response

    message = "请求参数错误"
    if isinstance(response.data, dict):
        detail = response.data.get("detail")
        if detail:
            message = str(detail)
        else:
            first_key = next(iter(response.data.keys()), None)
            if first_key:
                first_val = response.data[first_key]
                if isinstance(first_val, list) and first_val:
                    message = str(first_val[0])
                else:
                    message = str(first_val)

    response.data = {"code": response.status_code, "message": message, "data": None}
    return response
