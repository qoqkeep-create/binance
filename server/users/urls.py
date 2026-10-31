from django.urls import path

from users.views import (
    AdminSettingsView,
    LoginView,
    LogoutView,
    PasswordResetConfirmView,
    PasswordResetRequestView,
    PreflightCompleteView,
    PreflightStatusView,
    RefreshAccessTokenView,
    RegisterView,
)

urlpatterns = [
    path("register", RegisterView.as_view()),
    path("login", LoginView.as_view()),
    path("logout", LogoutView.as_view()),
    path("refresh", RefreshAccessTokenView.as_view()),
    path("password-reset/request", PasswordResetRequestView.as_view()),
    path("password-reset/confirm", PasswordResetConfirmView.as_view()),
    path("preflight-status", PreflightStatusView.as_view()),
    path("preflight-complete", PreflightCompleteView.as_view()),
    path("admin-settings", AdminSettingsView.as_view()),
]
