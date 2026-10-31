from decimal import Decimal

from django.test import TestCase
from rest_framework.test import APIRequestFactory, force_authenticate

from trading.models import Strategy, StrategyLevel
from trading.strategy_views import StrategyListView
from users.models import User


class StrategyLoadingTests(TestCase):
    def test_strategy_list_has_two_queries_independent_of_template_count(self):
        user = User.objects.create_user(email="strategy-loading@example.invalid", password="test-only-password")
        for i in range(30):
            strategy = Strategy.objects.create(user=user, name=f"Template {i}")
            for position in (3, 1, 2):
                StrategyLevel.objects.create(strategy=strategy, sort_order=position, profit_rr=Decimal(position))
        request = APIRequestFactory().get("/v1/strategy/list")
        force_authenticate(request, user=user)
        with self.assertNumQueries(2):
            response = StrategyListView.as_view()(request)
        self.assertEqual(len(response.data["data"]), 30)
        for strategy in response.data["data"]:
            self.assertEqual([level["profitRR"] for level in strategy["levels"]], [1, 2, 3])
