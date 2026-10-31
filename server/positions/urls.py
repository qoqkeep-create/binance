from django.urls import path

from positions.views import BreakEvenStopView, ManualTakeProfitView, PositionCloseView, PositionListView, PositionHistoryView

urlpatterns = [
    path("list", PositionListView.as_view()),
    path("close", PositionCloseView.as_view()),
    path("break-even-stop", BreakEvenStopView.as_view()),
    path("take-profit", ManualTakeProfitView.as_view()),
    path("history", PositionHistoryView.as_view()),
]
