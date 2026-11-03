from django.urls import path
from market_stream.views import KlinesView, SymbolsView, TickersView, WatchlistView
from market_stream.diagnostics import ChartLoadReportsView
from mobile.auth import MobileLoginView, MobileLogoutView, MobileMeView, MobileRefreshView, MobileRegisterView
from mobile.views import CommandsView, CommandDetailView

from mobile.push import PushRegisterView, PushUnregisterView
from mobile.live_activities import LiveActivityRegisterView, LiveActivityUnregisterView

urlpatterns = [
    path("push/devices/register", PushRegisterView.as_view()),
    path("push/devices/unregister", PushUnregisterView.as_view()),
    path("push/live-activities/register", LiveActivityRegisterView.as_view()),
    path("push/live-activities/unregister", LiveActivityUnregisterView.as_view()),
    path("commands", CommandsView.as_view()),
    path("commands/<uuid:command_id>", CommandDetailView.as_view()),
    path("auth/login", MobileLoginView.as_view()),
    path("auth/register", MobileRegisterView.as_view()),
    path("auth/me", MobileMeView.as_view()),
    path("auth/refresh", MobileRefreshView.as_view()),
    path("auth/logout", MobileLogoutView.as_view()),
    path("market/klines", KlinesView.as_view()),
    path("market/chart-load-reports", ChartLoadReportsView.as_view()),
    path("market/tickers", TickersView.as_view()),
    path("market/symbols", SymbolsView.as_view()),
    path("market/tickers/popular", TickersView.as_view(), {"kind": "popular"}),
    path("market/tickers/search", TickersView.as_view(), {"kind": "search"}),
    path("market/watchlist/defaults", WatchlistView.as_view()),
    path("market/watchlist", WatchlistView.as_view()),
]
