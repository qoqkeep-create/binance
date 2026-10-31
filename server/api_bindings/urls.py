from django.urls import path

from api_bindings.views import ApiBindView, ApiInfoView, ApiUnbindView

urlpatterns = [
    path("bind", ApiBindView.as_view()),
    path("info", ApiInfoView.as_view()),
    path("unbind", ApiUnbindView.as_view()),
]
