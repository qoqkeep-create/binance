from django.urls import path

from watch_plans.views import WatchPlanCreateView, WatchPlanDeleteView, WatchPlanListView, WatchPlanUpdateView

urlpatterns = [
    path("list", WatchPlanListView.as_view()),
    path("create", WatchPlanCreateView.as_view()),
    path("update", WatchPlanUpdateView.as_view()),
    path("delete", WatchPlanDeleteView.as_view()),
]
