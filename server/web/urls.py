from django.urls import path

from web.views import WebSettingsView

urlpatterns = [
    path("settings", WebSettingsView.as_view()),
]
