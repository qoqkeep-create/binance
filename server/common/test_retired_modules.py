from django.apps import apps
from django.test import SimpleTestCase
from django.urls import Resolver404, resolve


class RetiredResearchTests(SimpleTestCase):
    def test_research_endpoints_are_removed(self):
        for endpoint in (
            "samples", "samples/1", "samples/1/fetch", "chart", "rules",
            "strategies", "strategies/preview", "strategies/generate",
            "strategies/1", "strategies/1/publish", "backtest",
            "ai-models", "ai-models/1/activate",
        ):
            with self.subTest(endpoint=endpoint), self.assertRaises(Resolver404):
                resolve(f"/v1/signal-research/{endpoint}")

    def test_research_is_not_a_runtime_app(self):
        self.assertFalse(apps.is_installed("signal_research"))

    def test_observation_and_trading_modules_remain_available(self):
        for endpoint in ("watch-plan/list", "position/list", "trade/limit-order/list"):
            with self.subTest(endpoint=endpoint):
                self.assertIsNotNone(resolve(f"/v1/{endpoint}"))
