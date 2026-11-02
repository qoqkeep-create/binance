from django.urls import path

from trading.capital_wallet_views import CapitalWalletView
from trading.leverage_views import LeverageBracketsView

from trading.views import (
    SymbolInfoView,
    SymbolListView,
    MarketKlinesView,
    PublicMarketKlinesView,
    MarketPricesView,
    TradeEmaCheckView,
    TradeOpenView,
    CapitalPrecheckView,
    CapitalNormalizeView,
    CapitalReminderView,
    LimitOrderCreateView,
    LimitOrderListView,
    LimitOrderCancelView,
    LimitOrderChaseView,
    TradingViewMessageIngestView,
    TradingViewPendingMessagesView,
    TradingViewAckMessagesView,
    TradingViewSignalListView,
)

urlpatterns = [
    path("symbols", SymbolListView.as_view()),
    path("symbol/info", SymbolInfoView.as_view()),
    path("leverage-brackets", LeverageBracketsView.as_view()),
    path("market/klines", MarketKlinesView.as_view()),
    path("market/klines-public/<str:symbol>/<str:interval>", PublicMarketKlinesView.as_view()),
    path("market/prices", MarketPricesView.as_view()),
    path("ema-check", TradeEmaCheckView.as_view()),
    path("capital/wallet/precheck", CapitalWalletView.as_view()),
    path("capital/wallet/execute", CapitalWalletView.as_view(execute=True)),
    path("capital/precheck", CapitalPrecheckView.as_view()),
    path("capital/normalize", CapitalNormalizeView.as_view()),
    path("capital/remind", CapitalReminderView.as_view()),
    path("open", TradeOpenView.as_view()),
    path("open-position", TradeOpenView.as_view()),
    # 限价委托相关
    path("limit-order/create", LimitOrderCreateView.as_view()),
    path("limit-order/list", LimitOrderListView.as_view()),
    path("limit-order/cancel", LimitOrderCancelView.as_view()),
    path("limit-order/chase", LimitOrderChaseView.as_view()),
    path("tradingview/messages/ingest", TradingViewMessageIngestView.as_view()),
    path("tradingview/messages/pending", TradingViewPendingMessagesView.as_view()),
    path("tradingview/messages/ack", TradingViewAckMessagesView.as_view()),
    path("tradingview/signals", TradingViewSignalListView.as_view()),
]
