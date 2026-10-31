from django.urls import path

from positions.views import StrategyCancelView, StrategyLogView, StrategyRebindView

urlpatterns = [
    path("cancel", StrategyCancelView.as_view()),
    path("log", StrategyLogView.as_view()),
    path("rebind", StrategyRebindView.as_view()),
]
