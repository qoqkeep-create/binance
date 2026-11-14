from decimal import Decimal
from unittest.mock import patch

from rest_framework.test import APITestCase

from accounts.models import LeadTradingSettings
from users.models import User


class FixedStopLossTests(APITestCase):
    def setUp(self):
        self.user = User.objects.create_user(email="fixed-risk@example.com", password="password")
        self.client.force_authenticate(user=self.user)

    @patch("accounts.views.get_user_trade_balance", side_effect=AssertionError("balance must not be read"))
    def test_read_and_write_fixed_amount_without_balance_or_binding(self, balance):
        response = self.client.get("/v1/account/stop-loss")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(Decimal(response.data["data"]["current_amount"]), Decimal("120"))
        for amount in ("50", "127.25", "200"):
            with self.subTest(amount=amount):
                response = self.client.post("/v1/account/stop-loss", {"amount": amount}, format="json")
                self.assertEqual(response.status_code, 200, response.data)
                self.user.refresh_from_db()
                self.assertEqual(self.user.stop_loss_amount, Decimal(amount))
        balance.assert_not_called()

    def test_outside_fixed_range_and_percentage_inputs_are_rejected(self):
        for payload in ({"amount": "49.99"}, {"amount": "200.01"}, {"amount": "NaN"}, {"percentage": 10}):
            with self.subTest(payload=payload):
                response = self.client.post("/v1/account/stop-loss", payload, format="json")
                self.assertEqual(response.status_code, 400)
                if "percentage" in payload:
                    self.assertIn("固定金额", response.data["message"])
                self.user.refresh_from_db()
                self.assertEqual(self.user.stop_loss_amount, Decimal("120"))

    @patch("accounts.mode_settings.lead_balance", side_effect=AssertionError("lead balance must not be read"))
    def test_lead_fixed_amount_stays_separate_from_ordinary_setting(self, balance):
        response = self.client.post("/v1/account/stop-loss", {"amount": "150"}, format="json", HTTP_X_TRADING_MODE="lead")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(LeadTradingSettings.objects.get(user=self.user).stop_loss_amount, Decimal("150"))
        self.user.refresh_from_db()
        self.assertEqual(self.user.stop_loss_amount, Decimal("120"))
        response = self.client.get("/v1/account/stop-loss", HTTP_X_TRADING_MODE="lead")
        self.assertEqual(response.status_code, 200)
        balance.assert_not_called()
