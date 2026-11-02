from decimal import Decimal

from django.test import TestCase
from rest_framework.test import APIRequestFactory, force_authenticate

from trading.models import Strategy, StrategyLevel
from trading.strategy_views import StrategyListView, StrategySetActiveView
from users.models import User


class StrategyLoadingTests(TestCase):
    def test_manual_profit_selection_only_changes_users_future_default(self):
        user = User.objects.create_user(email="manual@example.invalid", password="test-only-password")
        other = User.objects.create_user(email="other-manual@example.invalid", password="test-only-password")
        selected = Strategy.objects.create(user=user, name="Selected", is_active=True)
        unrelated = Strategy.objects.create(user=other, name="Other", is_active=True)
        request = APIRequestFactory().post("/v1/strategy/set-active", {"manual": True}, format="json")
        force_authenticate(request, user=user)
        response = StrategySetActiveView.as_view()(request)
        self.assertEqual(response.data["code"], 200)
        selected.refresh_from_db()
        unrelated.refresh_from_db()
        self.assertFalse(selected.is_active)
        self.assertTrue(unrelated.is_active)
        self.assertEqual(Strategy.objects.filter(user=user).count(), 1)

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
