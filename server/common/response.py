from rest_framework.response import Response


def ok(data=None, message="成功", code=200):
    return Response({"code": code, "message": message, "data": data})


def fail(message="请求失败", code=400, data=None, status=400):
    return Response({"code": code, "message": message, "data": data}, status=status)
