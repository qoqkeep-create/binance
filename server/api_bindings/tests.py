from decimal import Decimal
import hashlib
from base64 import b64encode
from datetime import timedelta
from unittest.mock import MagicMock, patch

from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from django.conf import settings
from django.core.cache import cache
from django.db import IntegrityError, transaction
from django.test import override_settings
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APITestCase

from api_bindings.context import record_belongs_to_trading_account
from api_bindings.exceptions import ApiBindingConflictError
from api_bindings.models import ApiBinding
from api_bindings.services import (
    build_api_key_fingerprint,
    find_conflicting_binding,
    get_binding_api_key_fingerprint,
    get_user_api_key_fingerprint,
    get_user_binance_credentials_for_generation,
    get_user_trading_account,
    record_binding_exchange_result,
)
from trading.account_cache import position_cache_key
from common.binance import BinanceApiError
from common.utils import aes_decrypt, aes_encrypt
from trading.models import CapitalSweep
from users.models import User


class ApiBindingTests(APITestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(email="api_test@example.com", password="123456")
        login_resp = self.client.post(
            "/v1/auth/login",
            {"email": "api_test@example.com", "password": "123456", "agreed": True},
            format="json",
        )
        token = login_resp.data["data"]["token"]
        self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")

    @staticmethod
    def _legacy_encrypt(value: str) -> str:
        raw_key = getattr(settings, "AES_SECRET_KEY", settings.SECRET_KEY)
        key = hashlib.sha256(raw_key.encode("utf-8")).digest()
        padder = padding.PKCS7(algorithms.AES.block_size).padder()
        padded = padder.update(value.encode("utf-8")) + padder.finalize()
        encryptor = Cipher(algorithms.AES(key), modes.CBC(key[:16])).encryptor()
        encrypted = encryptor.update(padded) + encryptor.finalize()
        return b64encode(encrypted).decode("ascii")

    def test_reading_legacy_binding_upgrades_all_credentials(self):
        binding = ApiBinding.objects.create(
            user=self.user,
            api_key=self._legacy_encrypt("k" * 24),
            secret_key=self._legacy_encrypt("s" * 24),
            passphrase=self._legacy_encrypt("p" * 12),
            alias="legacy-api",
            status=1,
        )

        from api_bindings.services import get_user_binance_credentials

        credentials = get_user_binance_credentials(self.user)
        binding.refresh_from_db()

        self.assertEqual(credentials.api_key, "k" * 24)
        self.assertEqual(credentials.secret_key, "s" * 24)
        self.assertEqual(credentials.passphrase, "p" * 12)
        self.assertTrue(binding.api_key.startswith("v2:"))
        self.assertTrue(binding.secret_key.startswith("v2:"))
        self.assertTrue(binding.passphrase.startswith("v2:"))

    @override_settings(
        SECRET_KEY="django-signing-key-kept-separate",
        AES_SECRET_KEY="new-independent-aes-secret-key",
        AES_PREVIOUS_SECRET_KEY="previous-production-aes-key",
    )
    def test_reading_previous_aes_gcm_binding_rewrites_with_primary_key(self):
        with override_settings(AES_SECRET_KEY="previous-production-aes-key"):
            old_api_key = aes_encrypt("k" * 24)
            old_secret_key = aes_encrypt("s" * 24)
            old_passphrase = aes_encrypt("p" * 12)
        binding = ApiBinding.objects.create(
            user=self.user,
            api_key=old_api_key,
            secret_key=old_secret_key,
            passphrase=old_passphrase,
            alias="old-gcm-api",
            status=1,
        )

        from api_bindings.services import get_user_binance_credentials

        credentials = get_user_binance_credentials(self.user)
        binding.refresh_from_db()

        self.assertEqual(credentials.api_key, "k" * 24)
        self.assertEqual(credentials.secret_key, "s" * 24)
        self.assertEqual(credentials.passphrase, "p" * 12)
        self.assertNotEqual(binding.api_key, old_api_key)
        self.assertEqual(aes_decrypt(binding.api_key), "k" * 24)
        with override_settings(
            AES_SECRET_KEY="previous-production-aes-key",
            AES_PREVIOUS_SECRET_KEY="",
        ):
            with self.assertRaisesMessage(ValueError, "authentication failed"):
                aes_decrypt(binding.api_key)

    def test_trading_account_context_has_stable_binding_identity(self):
        api_key = "k" * 24
        binding = ApiBinding.objects.create(
            user=self.user,
            api_key=aes_encrypt(api_key),
            api_key_fingerprint=build_api_key_fingerprint(api_key),
            secret_key=aes_encrypt("s" * 24),
            passphrase=aes_encrypt("p" * 12),
            alias="primary-api",
            status=1,
        )

        account = get_user_trading_account(self.user, active_only=True)

        self.assertIsNotNone(account)
        self.assertEqual(account.user_id, self.user.id)
        self.assertEqual(account.binding_id, binding.id)
        self.assertEqual(account.api_key_fingerprint, build_api_key_fingerprint(api_key))
        self.assertEqual(account.binding_created_at, binding.created_at)
        self.assertEqual(
            account.generation,
            (build_api_key_fingerprint(api_key), binding.created_at),
        )
        self.assertEqual(account.identity, f"api-key:{build_api_key_fingerprint(api_key)}")
        self.assertIn(f"trade:account:{binding.id}:", account.cache_namespace)
        self.assertEqual(account.credentials.api_key, api_key)

    def test_trading_account_context_can_exclude_inactive_binding(self):
        ApiBinding.objects.create(
            user=self.user,
            api_key=aes_encrypt("k" * 24),
            secret_key=aes_encrypt("s" * 24),
            passphrase=aes_encrypt("p" * 12),
            alias="disabled-api",
            status=0,
        )

        self.assertIsNone(get_user_trading_account(self.user, active_only=True))
        self.assertIsNotNone(get_user_trading_account(self.user))

        from api_bindings.services import get_user_binance_credentials

        self.assertIsNone(get_user_binance_credentials(self.user))

    @patch("api_bindings.services.decrypt_binding_fields")
    def test_stored_api_key_fingerprint_does_not_decrypt_credentials(self, mock_decrypt):
        fingerprint = build_api_key_fingerprint("k" * 24)
        ApiBinding.objects.create(
            user=self.user,
            api_key=aes_encrypt("k" * 24),
            api_key_fingerprint=fingerprint,
            secret_key=aes_encrypt("s" * 24),
            passphrase=aes_encrypt("p" * 12),
            alias="fingerprinted-api",
            status=1,
        )

        self.assertEqual(get_user_api_key_fingerprint(self.user), fingerprint)
        mock_decrypt.assert_not_called()

    def test_api_key_fingerprint_is_unique_at_database_boundary(self):
        fingerprint = build_api_key_fingerprint("shared-key" * 3)
        ApiBinding.objects.create(
            user=self.user,
            api_key="encrypted-key",
            api_key_fingerprint=fingerprint,
            secret_key="encrypted-secret",
            passphrase="",
            alias="first",
        )
        other_user = User.objects.create_user(email="other-fingerprint@example.com", password="123456")

        with self.assertRaises(IntegrityError), transaction.atomic():
            ApiBinding.objects.create(
                user=other_user,
                api_key="other-encrypted-key",
                api_key_fingerprint=fingerprint,
                secret_key="other-encrypted-secret",
                passphrase="",
                alias="second",
            )

    def test_legacy_binding_fingerprint_is_persisted_without_changing_generation_time(self):
        api_key = "legacy-key" * 3
        binding = ApiBinding.objects.create(
            user=self.user,
            api_key=aes_encrypt(api_key),
            secret_key=aes_encrypt("s" * 24),
            passphrase=aes_encrypt("p" * 12),
            alias="legacy-fingerprint",
            status=1,
        )
        stable_updated_at = timezone.now() - timedelta(days=1)
        ApiBinding.objects.filter(pk=binding.pk).update(updated_at=stable_updated_at)

        fingerprint = get_user_api_key_fingerprint(self.user)
        binding.refresh_from_db()

        self.assertEqual(fingerprint, build_api_key_fingerprint(api_key))
        self.assertEqual(binding.api_key_fingerprint, fingerprint)
        self.assertEqual(binding.updated_at, stable_updated_at)

    def test_legacy_duplicate_fingerprint_is_disabled_with_explicit_error(self):
        api_key = "legacy-duplicate-key" * 2
        fingerprint = build_api_key_fingerprint(api_key)
        other_user = User.objects.create_user(email="legacy-owner@example.com", password="123456")
        ApiBinding.objects.create(
            user=other_user,
            api_key=aes_encrypt(api_key),
            api_key_fingerprint=fingerprint,
            secret_key=aes_encrypt("other-secret"),
            passphrase="",
            alias="existing-owner",
            status=1,
        )
        binding = ApiBinding.objects.create(
            user=self.user,
            api_key=aes_encrypt(api_key),
            secret_key=aes_encrypt("current-secret"),
            passphrase="",
            alias="legacy-duplicate",
            status=1,
        )

        with self.assertRaisesMessage(ApiBindingConflictError, "重复绑定"):
            get_binding_api_key_fingerprint(binding)

        binding.refresh_from_db()
        self.assertEqual(binding.status, 0)
        self.assertIn("重复", binding.status_reason)

    def test_conflict_scan_logs_broken_legacy_binding_without_credentials(self):
        broken_user = User.objects.create_user(
            email="broken-legacy@example.com",
            password="123456",
        )
        broken = ApiBinding.objects.create(
            user=broken_user,
            api_key="not-valid-ciphertext",
            secret_key=aes_encrypt("other-secret"),
            passphrase="",
            alias="broken-legacy",
            status=1,
        )

        with self.assertLogs("api_bindings.services", level="WARNING") as logs:
            conflict = find_conflicting_binding(user=self.user, api_key="candidate-key")

        joined = "\n".join(logs.output)
        self.assertIsNone(conflict)
        self.assertIn(f"binding_id={broken.id}", joined)
        self.assertIn(f"user_id={broken_user.id}", joined)
        self.assertNotIn("not-valid-ciphertext", joined)

    def test_legacy_record_uses_binding_creation_not_mutable_health_timestamp(self):
        binding_created_at = timezone.now() - timedelta(days=2)
        record_created_at = timezone.now() - timedelta(days=1)

        self.assertTrue(
            record_belongs_to_trading_account(
                record_fingerprint="",
                record_created_at=record_created_at,
                account_fingerprint="current-fingerprint",
                binding_created_at=binding_created_at,
            )
        )
        self.assertFalse(
            record_belongs_to_trading_account(
                record_fingerprint="",
                record_created_at=binding_created_at - timedelta(seconds=1),
                account_fingerprint="current-fingerprint",
                binding_created_at=binding_created_at,
            )
        )

    def test_generation_credentials_never_switch_to_a_rebound_key(self):
        old_key = "old-generation-key" * 2
        old_binding = ApiBinding.objects.create(
            user=self.user,
            api_key=aes_encrypt(old_key),
            api_key_fingerprint=build_api_key_fingerprint(old_key),
            secret_key=aes_encrypt("old-secret" * 3),
            passphrase=aes_encrypt("old-passphrase"),
            alias="old-binding",
            status=1,
        )
        old_created_at = old_binding.created_at
        old_fingerprint = old_binding.api_key_fingerprint
        old_binding.delete()
        new_key = "new-generation-key" * 2
        ApiBinding.objects.create(
            user=self.user,
            api_key=aes_encrypt(new_key),
            api_key_fingerprint=build_api_key_fingerprint(new_key),
            secret_key=aes_encrypt("new-secret" * 3),
            passphrase=aes_encrypt("new-passphrase"),
            alias="new-binding",
            status=1,
        )

        credentials = get_user_binance_credentials_for_generation(
            self.user,
            api_key_fingerprint=old_fingerprint,
            binding_created_at=old_created_at,
        )

        self.assertIsNone(credentials)

    def test_repeated_deterministic_auth_failures_disable_binding(self):
        binding = ApiBinding.objects.create(
            user=self.user,
            api_key=aes_encrypt("k" * 24),
            secret_key=aes_encrypt("s" * 24),
            passphrase=aes_encrypt("p" * 12),
            alias="failing-api",
            status=1,
        )

        for expected_count in (1, 2):
            disabled = record_binding_exchange_result(
                binding.id,
                BinanceApiError("invalid key", code="-2014"),
            )
            binding.refresh_from_db()
            self.assertFalse(disabled)
            self.assertEqual(binding.status, 1)
            self.assertEqual(binding.consecutive_auth_failures, expected_count)

        with self.assertLogs("api_bindings.services", level="ERROR") as logs:
            disabled = record_binding_exchange_result(
                binding.id,
                BinanceApiError("invalid key", code="-2014"),
            )
        binding.refresh_from_db()

        self.assertTrue(disabled)
        self.assertEqual(binding.status, 0)
        self.assertEqual(binding.consecutive_auth_failures, 3)
        self.assertIn("binance_binding_disabled", "\n".join(logs.output))
        self.assertNotIn("invalid key", binding.status_reason)

    def test_transient_exchange_failure_does_not_affect_binding_health(self):
        binding = ApiBinding.objects.create(
            user=self.user,
            api_key=aes_encrypt("k" * 24),
            secret_key=aes_encrypt("s" * 24),
            passphrase=aes_encrypt("p" * 12),
            alias="healthy-api",
            status=1,
        )

        record_binding_exchange_result(
            binding.id,
            BinanceApiError("timeout", code="-1007", outcome_unknown=True),
        )
        binding.refresh_from_db()

        self.assertEqual(binding.status, 1)
        self.assertEqual(binding.consecutive_auth_failures, 0)

    def test_successful_private_request_clears_auth_failure_streak(self):
        binding = ApiBinding.objects.create(
            user=self.user,
            api_key=aes_encrypt("k" * 24),
            secret_key=aes_encrypt("s" * 24),
            passphrase=aes_encrypt("p" * 12),
            alias="recovering-api",
            status=1,
            consecutive_auth_failures=2,
            last_auth_failure_at=timezone.now(),
            status_reason="old state",
        )

        record_binding_exchange_result(binding.id, None)
        binding.refresh_from_db()

        self.assertEqual(binding.consecutive_auth_failures, 0)
        self.assertIsNone(binding.last_auth_failure_at)
        self.assertEqual(binding.status_reason, "")

    @patch("api_bindings.views.validate_binance_binding")
    def test_api_info_keeps_current_status_on_transient_validation_error(self, mock_validate):
        mock_validate.side_effect = BinanceApiError("timeout", code="-1007")
        ApiBinding.objects.create(
            user=self.user,
            api_key=aes_encrypt("k" * 24),
            secret_key=aes_encrypt("s" * 24),
            passphrase=aes_encrypt("p" * 12),
            alias="main-api",
            status=1,
        )

        response = self.client.get("/v1/api/info?validate=1")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["data"]["status"], 1)
        self.assertEqual(ApiBinding.objects.get(user=self.user).status, 1)
        mock_validate.assert_called_once()

    @patch("api_bindings.views.validate_binance_binding")
    def test_bind_success(self, mock_validate):
        mock_validate.return_value = {"perm": "read_only,trade", "uid": "uid-1", "label": "main"}
        resp = self.client.post(
            "/v1/api/bind",
            {
                "api_key": "k" * 24,
                "secret_key": "s" * 24,
                "passphrase": "p" * 12,
                "alias": "main-api",
            },
            format="json",
        )
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data["code"], 200)
        self.assertTrue(ApiBinding.objects.filter(user=self.user).exists())
        binding = ApiBinding.objects.get(user=self.user)
        self.assertEqual(binding.binance_uid, "uid-1")
        self.assertEqual(binding.binance_label, "main")

    @patch("api_bindings.views.validate_binance_binding")
    def test_bind_rejects_busy_binding_lifecycle_without_exchange_validation(self, mock_validate):
        from trading.locks import api_binding_lifecycle_lock

        with api_binding_lifecycle_lock(self.user.id) as locked:
            response = self.client.post(
                "/v1/api/bind",
                {
                    "api_key": "k" * 24,
                    "secret_key": "s" * 24,
                    "passphrase": "p" * 12,
                    "alias": "main-api",
                },
                format="json",
            )

        self.assertTrue(locked)
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("API 绑定正在变更", response.data["message"])
        self.assertFalse(ApiBinding.objects.filter(user=self.user).exists())
        mock_validate.assert_not_called()

    @patch("api_bindings.views.validate_binance_binding")
    def test_bind_fail_on_binance_validation_error(self, mock_validate):
        mock_validate.side_effect = BinanceApiError("API信息不匹配")
        resp = self.client.post(
            "/v1/api/bind",
            {
                "api_key": "k" * 24,
                "secret_key": "s" * 24,
                "passphrase": "p" * 12,
                "alias": "main-api",
            },
            format="json",
        )
        self.assertEqual(resp.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(resp.data["message"], "API信息不匹配")

    @patch("api_bindings.views.BinanceFuturesClient")
    @patch("api_bindings.views.validate_binance_binding")
    def test_unbind_is_idempotent(self, mock_validate, mock_client_cls):
        mock_validate.return_value = {"perm": "read_only,trade", "uid": "uid-1", "label": "main"}
        mock_client = MagicMock()
        mock_client.get_positions.return_value = {"data": []}
        mock_client.get_pending_orders.return_value = {"data": []}
        mock_client.get_pending_algo_orders.return_value = {"data": []}
        mock_client_cls.return_value = mock_client
        self.client.post(
            "/v1/api/bind",
            {
                "api_key": "k" * 24,
                "secret_key": "s" * 24,
                "passphrase": "p" * 12,
                "alias": "main-api",
            },
            format="json",
        )
        first = self.client.post("/v1/api/unbind", {}, format="json")
        second = self.client.post("/v1/api/unbind", {}, format="json")
        self.assertEqual(first.status_code, status.HTTP_200_OK)
        self.assertEqual(second.status_code, status.HTTP_200_OK)
        self.assertEqual(second.data["message"], "解绑成功")

    @patch("api_bindings.views.BinanceFuturesClient")
    @patch("api_bindings.views.validate_binance_binding")
    def test_unbind_clears_account_scoped_position_cache(self, mock_validate, mock_client_cls):
        api_key = "k" * 24
        fingerprint = build_api_key_fingerprint(api_key)
        mock_validate.return_value = {"perm": "read_only,trade", "uid": "uid-1", "label": "main"}
        mock_client = MagicMock()
        mock_client.get_positions.return_value = {"data": []}
        mock_client.get_pending_orders.return_value = {"data": []}
        mock_client.get_pending_algo_orders.return_value = {"data": []}
        mock_client_cls.return_value = mock_client
        self.client.post(
            "/v1/api/bind",
            {
                "api_key": api_key,
                "secret_key": "s" * 24,
                "passphrase": "p" * 12,
                "alias": "main-api",
            },
            format="json",
        )
        key = position_cache_key("exchange_rows", f"api-key:{fingerprint}")
        cache.set(key, [{"instId": "BTC-USDT-SWAP"}], timeout=60)

        response = self.client.post("/v1/api/unbind", {}, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIsNone(cache.get(key))

    @patch("api_bindings.views.BinanceFuturesClient")
    def test_unbind_legacy_binding_uses_derived_fingerprint_lock(self, mock_client_cls):
        api_key = "legacy-lock-key" * 2
        binding = ApiBinding.objects.create(
            user=self.user,
            api_key=aes_encrypt(api_key),
            secret_key=aes_encrypt("s" * 24),
            passphrase=aes_encrypt("p" * 12),
            alias="legacy-lock",
            status=1,
        )
        identity = f"api-key:{build_api_key_fingerprint(api_key)}"

        from trading.locks import user_trading_activity_lock

        with user_trading_activity_lock(identity) as locked:
            response = self.client.post("/v1/api/unbind", {}, format="json")

        self.assertTrue(locked)
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("账户操作正在进行", response.data["message"])
        self.assertTrue(ApiBinding.objects.filter(pk=binding.pk).exists())
        mock_client_cls.assert_not_called()

    @patch("api_bindings.views.BinanceFuturesClient")
    def test_unbind_rejects_busy_binding_lifecycle_without_exchange_queries(self, mock_client_cls):
        binding = ApiBinding.objects.create(
            user=self.user,
            api_key=aes_encrypt("k" * 24),
            secret_key=aes_encrypt("s" * 24),
            passphrase=aes_encrypt("p" * 12),
            alias="main-api",
            status=1,
        )

        from trading.locks import api_binding_lifecycle_lock

        with api_binding_lifecycle_lock(self.user.id) as locked:
            response = self.client.post("/v1/api/unbind", {}, format="json")

        self.assertTrue(locked)
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("API 绑定正在变更", response.data["message"])
        self.assertTrue(ApiBinding.objects.filter(pk=binding.pk).exists())
        mock_client_cls.assert_not_called()

    @patch("api_bindings.views.BinanceFuturesClient")
    def test_unbind_rejects_each_kind_of_exchange_activity(self, mock_client_cls):
        binding = ApiBinding.objects.create(
            user=self.user,
            api_key=aes_encrypt("k" * 24),
            secret_key=aes_encrypt("s" * 24),
            passphrase=aes_encrypt("p" * 12),
            alias="main-api",
            status=1,
        )
        cases = (
            ("get_positions", "交易所仍有真实持仓"),
            ("get_pending_orders", "交易所仍有未成交普通挂单"),
            ("get_pending_algo_orders", "交易所仍有未成交条件单"),
        )
        for method_name, expected in cases:
            with self.subTest(method_name=method_name):
                mock_client = MagicMock()
                mock_client.get_positions.return_value = {"data": []}
                mock_client.get_pending_orders.return_value = {"data": []}
                mock_client.get_pending_algo_orders.return_value = {"data": []}
                getattr(mock_client, method_name).return_value = {"data": [{"id": "open"}]}
                mock_client_cls.return_value = mock_client

                response = self.client.post("/v1/api/unbind", {}, format="json")

                self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
                self.assertIn(expected, response.data["message"])
                self.assertTrue(ApiBinding.objects.filter(id=binding.id).exists())

    @patch("api_bindings.views.BinanceFuturesClient")
    def test_unbind_rejects_each_active_capital_sweep_without_exchange_calls(self, mock_client_cls):
        binding = ApiBinding.objects.create(
            user=self.user,
            api_key=aes_encrypt("k" * 24),
            secret_key=aes_encrypt("s" * 24),
            passphrase=aes_encrypt("p" * 12),
            alias="main-api",
            status=1,
        )
        active_statuses = (
            CapitalSweep.STATUS_FUNDING_REFILL_PENDING,
            CapitalSweep.STATUS_SPOT_REFILL_PENDING,
            CapitalSweep.STATUS_FUTURES_PENDING,
            CapitalSweep.STATUS_FUNDING_PENDING,
            CapitalSweep.STATUS_SPOT_PENDING,
        )
        for sweep_status in active_statuses:
            with self.subTest(sweep_status=sweep_status):
                CapitalSweep.objects.create(
                    user=self.user,
                    amount=Decimal("10"),
                    target_balance=Decimal("1000"),
                    status=sweep_status,
                )

                response = self.client.post("/v1/api/unbind", {}, format="json")

                self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
                self.assertIn("未完成的资金归集", response.data["message"])
                self.assertTrue(ApiBinding.objects.filter(id=binding.id).exists())
                CapitalSweep.objects.all().delete()
        mock_client_cls.assert_not_called()

    @patch("api_bindings.views.BinanceFuturesClient")
    def test_unbind_fails_closed_when_exchange_snapshot_fails(self, mock_client_cls):
        binding = ApiBinding.objects.create(
            user=self.user,
            api_key=aes_encrypt("k" * 24),
            secret_key=aes_encrypt("s" * 24),
            passphrase=aes_encrypt("p" * 12),
            alias="main-api",
            status=1,
        )
        mock_client_cls.return_value.get_positions.side_effect = BinanceApiError("timeout")

        response = self.client.post("/v1/api/unbind", {}, format="json")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("无法确认交易所持仓和挂单状态", response.data["message"])
        self.assertTrue(ApiBinding.objects.filter(id=binding.id).exists())

    @patch("api_bindings.views.validate_binance_binding")
    def test_api_info_never_returns_credentials(self, mock_validate):
        mock_validate.return_value = {"perm": "read_only,trade", "uid": "uid-1", "label": "main"}
        ApiBinding.objects.create(
            user=self.user,
            api_key=aes_encrypt("k" * 24),
            secret_key=aes_encrypt("s" * 24),
            passphrase=aes_encrypt("p" * 12),
            alias="main-api",
            status=1,
        )

        resp = self.client.get("/v1/api/info")

        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data["data"], {"alias": "main-api", "status": 1,
                                            "api_key_masked": "kkkkk**kkkkk"})
        self.assertNotIn("api_key", resp.data["data"])
        self.assertNotIn("secret_key", resp.data["data"])
        mock_validate.assert_not_called()

    def test_api_key_label_is_bounded_and_never_reveals_entire_short_key(self):
        binding = ApiBinding.objects.create(user=self.user, api_key=aes_encrypt("fixture"),
            secret_key=aes_encrypt("secret-fixture"), alias="label", status=1)
        for key, expected in (("a", "**"), ("ab", "**"), ("abc", "a**c"),
                              ("abcdefghijk", "abcde**ghijk"), ("A" * 64, "AAAAA**AAAAA")):
            binding.api_key = aes_encrypt(key)
            binding.save(update_fields=["api_key"])
            data = self.client.get("/v1/api/info").data["data"]
            self.assertEqual(data["api_key_masked"], expected)
            self.assertLessEqual(len(data["api_key_masked"]), 12)
            self.assertNotIn("secret-fixture", str(data))
        binding.api_key = "invalid-ciphertext"
        binding.save(update_fields=["api_key"])
        self.assertEqual(self.client.get("/v1/api/info").data["data"]["api_key_masked"], "**")

    @patch("api_bindings.views.validate_binance_binding")
    def test_bind_allows_same_account_alias_from_other_user(self, mock_validate):
        other_user = User.objects.create_user(email="other@example.com", password="123456")
        ApiBinding.objects.create(
            user=other_user,
            api_key="encrypted-key",
            secret_key="encrypted-secret",
            passphrase="encrypted-pass",
            binance_uid="shared-uid",
            binance_label="shared",
            alias="other-api",
            status=1,
        )
        mock_validate.return_value = {"perm": "read_only,trade", "uid": "shared-uid", "label": "main"}

        resp = self.client.post(
            "/v1/api/bind",
            {
                "api_key": "k" * 24,
                "secret_key": "s" * 24,
                "passphrase": "p" * 12,
                "alias": "main-api",
            },
            format="json",
        )

        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data["code"], 200)
        binding = ApiBinding.objects.get(user=self.user)
        self.assertEqual(binding.binance_uid, "shared-uid")

    @patch("api_bindings.views.validate_binance_binding")
    def test_bind_fail_when_api_key_fingerprint_already_bound_by_other_user(self, mock_validate):
        other_user = User.objects.create_user(email="other-key@example.com", password="123456")
        api_key = "k" * 24
        ApiBinding.objects.create(
            user=other_user,
            api_key=aes_encrypt(api_key),
            api_key_fingerprint=build_api_key_fingerprint(api_key),
            secret_key=aes_encrypt("other-secret"),
            passphrase=aes_encrypt("other-passphrase"),
            binance_uid="alias-a",
            binance_label="shared",
            alias="other-api",
            status=1,
        )
        mock_validate.return_value = {"perm": "read_only,trade", "uid": "alias-b", "label": "main"}

        resp = self.client.post(
            "/v1/api/bind",
            {
                "api_key": api_key,
                "secret_key": "s" * 24,
                "passphrase": "p" * 12,
                "alias": "main-api",
            },
            format="json",
        )

        self.assertEqual(resp.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(resp.data["message"], "绑定失败，该 API Key 已绑定到其他平台账号，请先解绑后再重试")

    @patch("api_bindings.views.validate_binance_binding")
    def test_bind_same_key_is_serialized_across_requests(self, mock_validate):
        api_key = "serialized-key" * 2
        fingerprint = build_api_key_fingerprint(api_key)
        mock_validate.return_value = {"perm": "read_only,trade", "uid": "uid-1", "label": "main"}

        from trading.locks import api_binding_registration_lock

        with api_binding_registration_lock(fingerprint) as locked:
            response = self.client.post(
                "/v1/api/bind",
                {
                    "api_key": api_key,
                    "secret_key": "s" * 24,
                    "passphrase": "p" * 12,
                    "alias": "main-api",
                },
                format="json",
            )

        self.assertTrue(locked)
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("正在绑定处理中", response.data["message"])
        self.assertFalse(ApiBinding.objects.filter(user=self.user).exists())

    @patch("api_bindings.views.ApiBinding.objects.create", side_effect=IntegrityError("duplicate"))
    @patch("api_bindings.views.validate_binance_binding")
    def test_bind_database_race_returns_controlled_error(self, mock_validate, _mock_create):
        mock_validate.return_value = {"perm": "read_only,trade", "uid": "uid-1", "label": "main"}

        response = self.client.post(
            "/v1/api/bind",
            {
                "api_key": "race-key" * 3,
                "secret_key": "s" * 24,
                "passphrase": "p" * 12,
                "alias": "main-api",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("并发绑定", response.data["message"])
