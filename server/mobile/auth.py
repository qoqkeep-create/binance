"""Adapt the existing authentication service without bypassing its rate limits."""
from rest_framework.permissions import AllowAny
from rest_framework.test import APIRequestFactory
from rest_framework.views import APIView

from common.response import fail, ok
from users.models import User
from users.views import LoginView, RegisterView, RefreshAccessTokenView, LogoutView


def user_payload(user):
    return {"id": str(user.pk), "email": user.email, "displayName": user.email.split("@")[0],
            "canViewReferenceNotifications": False, "isAdmin": user.is_admin}


def internal_request(request, path, data):
    raw = APIRequestFactory().post(path, data, format="json", REMOTE_ADDR=request.META.get("REMOTE_ADDR", ""))
    raw.COOKIES = request.COOKIES.copy()
    return raw


class MobileLoginView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        if not isinstance(request.data, dict):
            return fail("请求参数必须是对象")
        data = {**request.data, "email": request.data.get("email", request.data.get("account", ""))}
        response = LoginView.as_view()(internal_request(request, "/v1/auth/login", data))
        if response.status_code != 200 or response.data.get("code") != 200:
            return response
        payload = response.data["data"]
        response.data = {"code": 200, "data": {"accessToken": payload["token"],
                         "user": user_payload(User.objects.get(pk=payload["user_id"]))}, "message": "登录成功"}
        return response


class MobileRegisterView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        if not isinstance(request.data, dict):
            return fail("请求参数必须是对象")
        data = {**request.data, "email": request.data.get("email", request.data.get("account", ""))}
        response = RegisterView.as_view()(internal_request(request, "/v1/auth/register", data))
        if response.data.get("code") != 200:
            return response
        return MobileLoginView.as_view()(internal_request(request, "/api/auth/login", data))


class MobileMeView(APIView):
    def get(self, request):
        return ok(user_payload(request.user))


class MobileRefreshView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        response = RefreshAccessTokenView.as_view()(internal_request(request, "/v1/auth/refresh", {}))
        if response.data.get("code") == 200:
            response.data["data"] = {"accessToken": response.data["data"]["token"]}
        return response


class MobileLogoutView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        from mobile.models import PushDevice
        from uuid import UUID
        try:
            installation = UUID(request.headers.get('X-Push-Installation-ID', ''))
            if request.user.is_authenticated:
                PushDevice.objects.filter(user=request.user, installation_id=installation).update(active=False)
                from mobile.live_activities import request_end
                request_end(user_id=request.user.pk, installation_id=installation)
        except (ValueError, TypeError):
            pass
        return LogoutView.as_view()(internal_request(request, "/v1/auth/logout", {}))
