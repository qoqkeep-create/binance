from django.urls import path

from plans.views import TradingPlanDetailView, TradingPlanListCreateView

urlpatterns = [
    path("list", TradingPlanListCreateView.as_view()),
    path("create", TradingPlanListCreateView.as_view()),
    path("<int:plan_id>", TradingPlanDetailView.as_view()),
]