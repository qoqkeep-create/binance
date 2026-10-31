from unittest.mock import patch

from django.core.cache import cache
from django.db import IntegrityError, transaction
from rest_framework.test import APITestCase

from api_bindings.models import ApiBinding
from api_bindings.services import build_api_key_fingerprint, get_user_trading_account
from common.trading_mode import TradingMode
from common.utils import aes_encrypt
from users.models import User


class TradingModeBindingTests(APITestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(email="modes@example.com", password="test-password")
        self.client.force_authenticate(self.user)

    def binding(self, mode):
        key = f"test-{mode}-key"
        return ApiBinding.objects.create(
            user=self.user, trading_mode=mode, alias=mode,
            api_key=aes_encrypt(key), api_key_fingerprint=build_api_key_fingerprint(key),
            secret_key=aes_encrypt("test-secret"), passphrase=aes_encrypt(""),
        )

    def test_two_bindings_resolve_separately_and_default_stays_ordinary(self):
        ordinary = self.binding(TradingMode.ORDINARY)
        lead = self.binding(TradingMode.LEAD)
        first = get_user_trading_account(self.user)
        second = get_user_trading_account(self.user, trading_mode=TradingMode.LEAD)
        self.assertEqual(first.binding_id, ordinary.id)
        self.assertEqual(second.binding_id, lead.id)
        self.assertNotEqual(first.identity, second.identity)
        self.assertNotEqual(first.cache_namespace, second.cache_namespace)
        self.assertEqual(second.credentials.trading_mode, TradingMode.LEAD)

    def test_missing_or_disabled_lead_never_uses_ordinary_key(self):
        self.binding(TradingMode.ORDINARY)
        self.assertIsNone(get_user_trading_account(self.user, trading_mode=TradingMode.LEAD))
        lead = self.binding(TradingMode.LEAD)
        lead.status = 0
        lead.save()
        self.assertIsNone(get_user_trading_account(self.user, trading_mode=TradingMode.LEAD, active_only=True))
        self.assertIsNotNone(get_user_trading_account(self.user, active_only=True))

    def test_database_rejects_duplicate_mode_and_cross_mode_key(self):
        ordinary = self.binding(TradingMode.ORDINARY)
        with self.assertRaises(IntegrityError), transaction.atomic():
            ApiBinding.objects.create(user=self.user, alias="duplicate", api_key="encrypted", secret_key="encrypted")
        with self.assertRaises(IntegrityError), transaction.atomic():
            ApiBinding.objects.create(user=self.user, trading_mode=TradingMode.LEAD,
                                      api_key_fingerprint=ordinary.api_key_fingerprint,
                                      alias="same-key", api_key="encrypted", secret_key="encrypted")

    def test_info_returns_only_selected_mode_without_secrets(self):
        self.binding(TradingMode.ORDINARY)
        self.binding(TradingMode.LEAD)
        with self.settings(LEAD_TRADING_ENABLED=True):
            response = self.client.get("/v1/api/info", HTTP_X_TRADING_MODE="lead")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["data"]["alias"], "lead")
        self.assertNotIn("api_key", response.data["data"])
        self.assertNotIn("secret_key", response.data["data"])

    def test_unknown_mode_and_disabled_mode_never_fall_back(self):
        self.binding(TradingMode.ORDINARY)
        with self.settings(LEAD_TRADING_ENABLED=False):
            self.assertEqual(self.client.post("/v1/api/bind", {}, format="json", HTTP_X_TRADING_MODE="lead").status_code, 400)
        self.assertEqual(self.client.get("/v1/api/info", HTTP_X_TRADING_MODE="typo").status_code, 400)

    def test_allowed_frontend_can_send_mode_header(self):
        with self.settings(CORS_ALLOWED_ORIGINS=["https://ui.example.com"]):
            response = self.client.options("/v1/api/info", HTTP_ORIGIN="https://ui.example.com",
                HTTP_ACCESS_CONTROL_REQUEST_METHOD="GET",
                HTTP_ACCESS_CONTROL_REQUEST_HEADERS="authorization,x-trading-mode")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response["Access-Control-Allow-Origin"], "https://ui.example.com")
        self.assertIn("x-trading-mode", response["Access-Control-Allow-Headers"])

    def test_rejected_mode_keeps_cors_headers_and_clear_error(self):
        with self.settings(CORS_ALLOWED_ORIGINS=["https://ui.example.com"]):
            response = self.client.get("/v1/api/info", HTTP_ORIGIN="https://ui.example.com",
                                       HTTP_X_TRADING_MODE="invalid")
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response["Access-Control-Allow-Origin"], "https://ui.example.com")
        self.assertIn("交易模式无效", response.json()["message"])

    @patch("api_bindings.views.BinanceFuturesClient")
    def test_unbind_lead_preserves_ordinary_binding(self, client_type):
        ordinary = self.binding(TradingMode.ORDINARY)
        lead = self.binding(TradingMode.LEAD)
        client = client_type.return_value
        for method in (client.get_positions, client.get_pending_orders, client.get_pending_algo_orders):
            method.return_value = {"data": []}
        with self.settings(LEAD_TRADING_ENABLED=True):
            response = self.client.post("/v1/api/unbind", HTTP_X_TRADING_MODE="lead")
        self.assertEqual(response.status_code, 200)
        self.assertTrue(ApiBinding.objects.filter(pk=ordinary.pk).exists())
        self.assertFalse(ApiBinding.objects.filter(pk=lead.pk).exists())
