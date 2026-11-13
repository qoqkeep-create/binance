from django.urls import path

from experiences.views import (
    TradingExperienceDetailView,
    TradingExperienceListCreateView,
    TradingExperienceUploadUrlView,
)


urlpatterns = [
    path("list", TradingExperienceListCreateView.as_view()),
    path("create", TradingExperienceListCreateView.as_view()),
    path("upload-url", TradingExperienceUploadUrlView.as_view()),
    path("<int:experience_id>", TradingExperienceDetailView.as_view()),
]
