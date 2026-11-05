from django.urls import path
from positions.margin import PositionMarginView

from positions.views import BreakEvenStopView, ManualTakeProfitView, PositionCloseView, PositionListView, PositionHistoryView

urlpatterns = [
    path("margin", PositionMarginView.as_view()),
    path("list", PositionListView.as_view()),
    path("close", PositionCloseView.as_view()),
    path("break-even-stop", BreakEvenStopView.as_view()),
    path("take-profit", ManualTakeProfitView.as_view()),
    path("history", PositionHistoryView.as_view()),
]
