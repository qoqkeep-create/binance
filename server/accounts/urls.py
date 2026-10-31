from django.urls import path

from accounts.operation_log_views import OperationLogView

from accounts.views import (
    AccountInfoView,
    AccountProfileView,
    CapitalCollectAccountView,
    ClientLayoutLogView,
    StopLossCancelView,
    StopLossSettingView,
    TransferHistoryView,
    TransferHistorySyncView,
    VersionInfoView,
)

urlpatterns = [
    path("info", AccountInfoView.as_view()),
    path("profile", AccountProfileView.as_view()),
    path("version", VersionInfoView.as_view()),
    path("client-layout-log", ClientLayoutLogView.as_view()),
    path("stop-loss", StopLossSettingView.as_view()),
    path("stop-loss/cancel", StopLossCancelView.as_view()),
    path("capital-collect-account", CapitalCollectAccountView.as_view()),
    path("transfer-history", TransferHistoryView.as_view()),
    path("transfer-history/sync", TransferHistorySyncView.as_view()),
    path("operation-logs", OperationLogView.as_view()),
]
