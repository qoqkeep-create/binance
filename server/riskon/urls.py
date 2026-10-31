from django.contrib import admin
from django.urls import include, path

from common.health import deep_health

urlpatterns = [
    path("api/", include("mobile.urls")),
    path("admin/", admin.site.urls),
    path("v1/health", deep_health),
    path("v1/auth/", include("users.urls")),
    path("v1/api/", include("api_bindings.urls")),
    path("v1/account/", include("accounts.urls")),
    path("v1/trade/", include("trading.urls")),
    path("v1/position/", include("positions.urls")),
    path("v1/watch-plan/", include("watch_plans.urls")),
    path("v1/signal-research/", include("signal_research.urls")),
    path("v1/strategy/", include("positions.strategy_urls")),
    path("v1/strategy/", include("trading.strategy_urls")),
]
