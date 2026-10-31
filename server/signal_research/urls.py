from django.urls import path

from signal_research.views import AiModelActivateView, AiModelListView, BacktestView, ChartView, FetchSampleView, RuleView, SampleDetailView, SampleListView, StrategyDetailView, StrategyGenerateView, StrategyListView, StrategyPreviewView, StrategyPublishView

urlpatterns = [
    path("samples", SampleListView.as_view()),
    path("samples/<int:sample_id>", SampleDetailView.as_view()),
    path("samples/<int:sample_id>/fetch", FetchSampleView.as_view()),
    path("rules", RuleView.as_view()),
    path("strategies", StrategyListView.as_view()),
    path("strategies/generate", StrategyGenerateView.as_view()),
    path("strategies/preview", StrategyPreviewView.as_view()),
    path("ai-models", AiModelListView.as_view()),
    path("ai-models/<int:model_id>/activate", AiModelActivateView.as_view()),
    path("strategies/<int:strategy_id>", StrategyDetailView.as_view()),
    path("strategies/<int:strategy_id>/publish", StrategyPublishView.as_view()),
    path("backtest", BacktestView.as_view()),
    path("chart", ChartView.as_view()),
]
