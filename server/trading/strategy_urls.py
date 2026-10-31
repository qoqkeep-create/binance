from django.urls import path

from trading.strategy_views import (
    StrategyDeleteView,
    StrategyListView,
    StrategySaveView,
    StrategySetActiveView,
)

urlpatterns = [
    path("list", StrategyListView.as_view()),
    path("save", StrategySaveView.as_view()),
    path("delete", StrategyDeleteView.as_view()),
    path("set-active", StrategySetActiveView.as_view()),
]
