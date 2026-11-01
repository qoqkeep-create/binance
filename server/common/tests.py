import hashlib
from base64 import b64encode
from decimal import Decimal
from unittest.mock import Mock, patch

from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from django.conf import settings
from django.core.cache import cache
from django.test import TestCase, override_settings

from common.binance import (
    ALGO_VISIBILITY_ALLOW_DELAYED,
    ALGO_VISIBILITY_REQUIRE_VISIBLE,
    ALGO_VISIBILITY_RETRY_DELAYS_SECONDS,
    BinanceAlgoClient,
    BinanceApiError,
    BinanceCredentials,
    BinanceFuturesClient,
    _get_today_realized_pnl,
    _public_json_request,
    build_closed_position_history,
    clear_account_config_cache,
    clear_rate_limit_cooldown,
    get_usdt_equity_snapshot,
    get_usdt_total_equity,
    mark_rate_limit_cooldown,
    normalize_limit_price,
    normalize_stop_trigger_price,
    normalize_take_profit_trigger_price,
    rate_limit_cooldown_remaining,
    standardize_open_order_request,
    standardize_trigger_order_request,
)
from common.utils import aes_decrypt, aes_decrypt_with_metadata, aes_encrypt
from common.binance_rate_limit import (
    RequestBudgetExceeded,
    RequestBudgetSpec,
    RequestPriority,
    _clear_local_budget_state,
    classify_request,
    observe_response_headers,
    reserve_request_budget,
)
from common.ops_alerts import send_ops_alert_once
from common.errors import safe_error_summary


class SafeErrorSummaryTests(TestCase):
    def test_redacts_urls_and_credential_values(self):
        summary = safe_error_summary(
            RuntimeError(
                "POST https://notify.example.test/send?signature=abc&token=query-secret "
                "api_key=header-secret password=hidden failed"
            )
        )

        self.assertTrue(summary.startswith("RuntimeError:"))
        self.assertIn("[redacted-url]", summary)
        self.assertNotIn("notify.example.test", summary)
        self.assertNotIn("abc", summary)
        self.assertNotIn("query-secret", summary)
        self.assertNotIn("header-secret", summary)
        self.assertNotIn("hidden", summary)

    def test_redacts_authorization_and_quoted_header_values(self):
        summary = safe_error_summary(
            RuntimeError(
                "headers={'Authorization': 'Bearer bearer-secret', "
                "'X-MBX-APIKEY': 'mbx-secret', 'signature': 'signed-value'}"
            )
        )

        self.assertNotIn("bearer-secret", summary)
        self.assertNotIn("mbx-secret", summary)
        self.assertNotIn("signed-value", summary)
        self.assertGreaterEqual(summary.count("[redacted]"), 3)

    def test_can_omit_exception_type_for_user_facing_and_persisted_messages(self):
        summary = safe_error_summary(
            BinanceApiError("请求失败 token=secret"),
            include_type=False,
        )

        self.assertEqual(summary, "请求失败 token=[redacted]")


class OpsAlertTests(TestCase):
    def setUp(self):
        cache.clear()

    @override_settings(
        OPS_ALERT_URL="https://alerts.example.test/ops",
        OPS_ALERT_TOKEN="test-token",
        OPS_ALERT_TIMEOUT_SECONDS=1,
    )
    @patch("common.ops_alerts.request.urlopen")
    def test_failed_delivery_does_not_suppress_immediate_retry(self, mock_urlopen):
        response = Mock()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        response.read.return_value = b'{"ok": true}'
        mock_urlopen.side_effect = [OSError("temporary failure"), response]

        self.assertFalse(send_ops_alert_once(key="same-alert", title="test", text="first"))
        self.assertTrue(send_ops_alert_once(key="same-alert", title="test", text="second"))
        self.assertEqual(mock_urlopen.call_count, 2)

    @override_settings(
        OPS_ALERT_URL="https://alerts.example.test/ops",
        OPS_ALERT_TOKEN="test-token",
        OPS_ALERT_TIMEOUT_SECONDS=1,
    )
    @patch("common.ops_alerts.request.urlopen")
    def test_successful_delivery_keeps_cooldown(self, mock_urlopen):
        response = Mock()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        response.read.return_value = b'{"ok": true}'
        mock_urlopen.return_value = response

        self.assertTrue(send_ops_alert_once(key="same-alert", title="test", text="first"))
        self.assertFalse(send_ops_alert_once(key="same-alert", title="test", text="second"))
        self.assertEqual(mock_urlopen.call_count, 1)


class BinanceRequestBudgetTests(TestCase):
    def setUp(self):
        cache.clear()
        _clear_local_budget_state()

    def test_request_classification_reserves_writes_and_deprioritizes_history(self):
        write_spec = classify_request(
            method="POST",
            path="/fapi/v1/order",
            base_url="https://fapi.binance.com",
        )
        history_spec = classify_request(
            method="GET",
            path="/fapi/v1/income",
            base_url="https://fapi.binance.com",
        )

        self.assertEqual(write_spec.priority, RequestPriority.CRITICAL)
        self.assertTrue(write_spec.counts_as_order)
        self.assertEqual(history_spec.priority, RequestPriority.BACKGROUND)
        self.assertEqual(history_spec.weight, 30)

    def test_continuous_kline_repair_reserves_full_weight(self):
        spec = classify_request(method="GET", path="/fapi/v1/continuousKlines",
            base_url="https://fapi.binance.com", query={"limit": 1500}, priority="background")
        self.assertEqual(spec.weight, 10)
        self.assertEqual(spec.priority, RequestPriority.BACKGROUND)

    def test_balance_request_weights_match_their_exchange_scopes(self):
        spot = classify_request(
            method="GET",
            path="/api/v3/account",
            base_url="https://api.binance.com",
        )
        futures = classify_request(
            method="GET",
            path="/fapi/v3/balance",
            base_url="https://fapi.binance.com",
        )

        self.assertEqual((spot.scope, spot.weight), ("spot", 20))
        self.assertEqual((futures.scope, futures.weight), ("futures", 5))

    def test_read_only_funding_post_is_not_classified_as_exchange_write(self):
        funding = classify_request(
            method="POST",
            path="/sapi/v1/asset/get-funding-asset",
            base_url="https://api.binance.com",
        )
        transfer = classify_request(
            method="POST",
            path="/sapi/v1/asset/transfer",
            base_url="https://api.binance.com",
        )

        self.assertEqual(funding.priority, RequestPriority.NORMAL)
        self.assertFalse(funding.counts_as_order)
        self.assertEqual(transfer.priority, RequestPriority.CRITICAL)

    def test_rate_limit_cooldown_is_isolated_by_api_scope(self):
        mark_rate_limit_cooldown(scope="sapi")

        self.assertGreater(rate_limit_cooldown_remaining("sapi"), 0)
        self.assertEqual(rate_limit_cooldown_remaining("futures"), 0)

    @patch("common.binance.time.time", return_value=1_000.0)
    def test_rate_limit_retry_after_header_is_case_insensitive(self, _mock_time):
        mark_rate_limit_cooldown(headers={"retry-after": "45"}, scope="spot")

        self.assertGreaterEqual(rate_limit_cooldown_remaining("spot"), 45)

    @override_settings(
        BINANCE_FUTURES_WEIGHT_LIMIT_PER_MINUTE=100,
        BINANCE_BACKGROUND_WEIGHT_RATIO=0.50,
        BINANCE_CRITICAL_WEIGHT_RATIO=0.90,
    )
    def test_background_budget_cannot_consume_critical_reserve(self):
        background = RequestBudgetSpec(
            scope="futures",
            priority=RequestPriority.BACKGROUND,
            weight=50,
            counts_as_order=False,
        )
        critical = RequestBudgetSpec(
            scope="futures",
            priority=RequestPriority.CRITICAL,
            weight=10,
            counts_as_order=False,
        )

        reserve_request_budget(background, now=120.0)
        with self.assertRaises(RequestBudgetExceeded):
            reserve_request_budget(background, now=120.0)
        reserve_request_budget(critical, now=120.0)

    @override_settings(
        BINANCE_ORDER_LIMIT_PER_MINUTE=2,
        BINANCE_ORDER_LIMIT_RATIO=1.0,
    )
    def test_order_budget_is_isolated_by_account(self):
        spec = RequestBudgetSpec(
            scope="futures",
            priority=RequestPriority.CRITICAL,
            weight=1,
            counts_as_order=True,
        )

        reserve_request_budget(spec, account_api_key="account-a", now=120.0)
        reserve_request_budget(spec, account_api_key="account-a", now=120.0)
        with self.assertRaises(RequestBudgetExceeded):
            reserve_request_budget(spec, account_api_key="account-a", now=120.0)
        reserve_request_budget(spec, account_api_key="account-b", now=120.0)

    @override_settings(
        BINANCE_FUTURES_WEIGHT_LIMIT_PER_MINUTE=100,
        BINANCE_CRITICAL_WEIGHT_RATIO=1.0,
        BINANCE_ORDER_LIMIT_PER_MINUTE=1,
        BINANCE_ORDER_LIMIT_RATIO=1.0,
    )
    def test_rejected_order_budget_releases_reserved_request_weight(self):
        spec = RequestBudgetSpec(
            scope="futures",
            priority=RequestPriority.CRITICAL,
            weight=10,
            counts_as_order=True,
        )

        reserve_request_budget(spec, account_api_key="account-a", now=120.0)
        with self.assertRaises(RequestBudgetExceeded):
            reserve_request_budget(spec, account_api_key="account-a", now=120.0)

        self.assertEqual(cache.get("trade:binance:budget:weight:futures:2"), 10)

    def test_response_headers_raise_shared_observation_floor(self):
        used_weight, order_count = observe_response_headers(
            {"X-MBX-USED-WEIGHT-1M": "321", "X-MBX-ORDER-COUNT-1M": "12"},
            scope="futures",
            account_api_key="account-a",
            now=120.0,
        )

        self.assertEqual((used_weight, order_count), (321, 12))
        self.assertEqual(cache.get("trade:binance:budget:weight:futures:2"), 321)

    @override_settings(
        BINANCE_FUTURES_WEIGHT_LIMIT_PER_MINUTE=100,
        BINANCE_CRITICAL_WEIGHT_RATIO=1.0,
    )
    @patch("common.binance_rate_limit.cache.add", side_effect=ConnectionError("redis unavailable"))
    def test_response_headers_raise_local_observation_floor(self, _cache_add):
        observe_response_headers(
            {"X-MBX-USED-WEIGHT-1M": "99"},
            scope="futures",
            now=120.0,
        )
        spec = RequestBudgetSpec(
            scope="futures",
            priority=RequestPriority.CRITICAL,
            weight=1,
            counts_as_order=False,
        )

        reserve_request_budget(spec, now=120.0)
        with self.assertRaises(RequestBudgetExceeded):
            reserve_request_budget(spec, now=120.0)

    @override_settings(
        BINANCE_FUTURES_WEIGHT_LIMIT_PER_MINUTE=1,
        BINANCE_CRITICAL_WEIGHT_RATIO=1.0,
    )
    def test_cache_failure_uses_local_mirror_of_prior_reservations(self):
        spec = RequestBudgetSpec(
            scope="futures",
            priority=RequestPriority.CRITICAL,
            weight=1,
            counts_as_order=False,
        )
        reserve_request_budget(spec, now=120.0)

        with patch(
            "common.binance_rate_limit.cache.add",
            side_effect=ConnectionError("redis unavailable"),
        ):
            with self.assertRaises(RequestBudgetExceeded):
                reserve_request_budget(spec, now=120.0)

    @patch("common.binance_rate_limit.cache.add", side_effect=ConnectionError("redis unavailable"))
    def test_cache_failure_degrades_without_blocking_request(self, _cache_add):
        reserve_request_budget(
            RequestBudgetSpec(
                scope="futures",
                priority=RequestPriority.CRITICAL,
                weight=1,
                counts_as_order=False,
            ),
            now=120.0,
        )

    @override_settings(
        BINANCE_FUTURES_WEIGHT_LIMIT_PER_MINUTE=2,
        BINANCE_CRITICAL_WEIGHT_RATIO=1.0,
    )
    @patch("common.binance_rate_limit.cache.add", side_effect=ConnectionError("redis unavailable"))
    def test_cache_failure_uses_process_local_weight_limit(self, _cache_add):
        spec = RequestBudgetSpec(
            scope="futures",
            priority=RequestPriority.CRITICAL,
            weight=1,
            counts_as_order=False,
        )

        reserve_request_budget(spec, now=120.0)
        reserve_request_budget(spec, now=120.0)
        with self.assertRaises(RequestBudgetExceeded):
            reserve_request_budget(spec, now=120.0)

    @override_settings(
        BINANCE_FUTURES_WEIGHT_LIMIT_PER_MINUTE=1,
        BINANCE_CRITICAL_WEIGHT_RATIO=1.0,
    )
    @patch("common.binance_rate_limit.cache.add", side_effect=ConnectionError("redis unavailable"))
    def test_process_local_weight_limit_resets_in_next_window(self, _cache_add):
        spec = RequestBudgetSpec(
            scope="futures",
            priority=RequestPriority.CRITICAL,
            weight=1,
            counts_as_order=False,
        )

        reserve_request_budget(spec, now=120.0)
        with self.assertRaises(RequestBudgetExceeded):
            reserve_request_budget(spec, now=120.0)
        reserve_request_budget(spec, now=180.0)

    @override_settings(
        BINANCE_FUTURES_WEIGHT_LIMIT_PER_MINUTE=2,
        BINANCE_CRITICAL_WEIGHT_RATIO=1.0,
        BINANCE_ORDER_LIMIT_PER_MINUTE=1,
        BINANCE_ORDER_LIMIT_RATIO=1.0,
    )
    @patch("common.binance_rate_limit.cache.add", side_effect=ConnectionError("redis unavailable"))
    def test_local_order_rejection_releases_local_weight(self, _cache_add):
        order_spec = RequestBudgetSpec(
            scope="futures",
            priority=RequestPriority.CRITICAL,
            weight=1,
            counts_as_order=True,
        )
        read_spec = RequestBudgetSpec(
            scope="futures",
            priority=RequestPriority.CRITICAL,
            weight=1,
            counts_as_order=False,
        )

        reserve_request_budget(order_spec, account_api_key="account-a", now=120.0)
        with self.assertRaises(RequestBudgetExceeded):
            reserve_request_budget(order_spec, account_api_key="account-a", now=120.0)
        reserve_request_budget(read_spec, now=120.0)
        with self.assertRaises(RequestBudgetExceeded):
            reserve_request_budget(read_spec, now=120.0)

    @patch("common.binance_rate_limit._LOCAL_COUNTER_MAX_ENTRIES", 1)
    @patch("common.binance_rate_limit.cache.add", side_effect=ConnectionError("redis unavailable"))
    def test_process_local_budget_fails_closed_when_fallback_capacity_is_full(self, _cache_add):
        futures = RequestBudgetSpec(
            scope="futures",
            priority=RequestPriority.CRITICAL,
            weight=1,
            counts_as_order=False,
        )
        spot = RequestBudgetSpec(
            scope="spot",
            priority=RequestPriority.CRITICAL,
            weight=1,
            counts_as_order=False,
        )

        reserve_request_budget(futures, now=120.0)
        with self.assertRaises(RequestBudgetExceeded):
            reserve_request_budget(spot, now=120.0)


class DeepHealthTests(TestCase):
    def tearDown(self):
        cache.delete("ops:scheduler:heartbeat")

    @patch("common.health._migrations_ready", return_value=True)
    @patch("common.health._database_ready", return_value=True)
    def test_deep_health_requires_all_dependencies(self, _database, _migrations):
        cache.set("ops:scheduler:heartbeat", "2026-09-05T00:00:00+00:00", timeout=60)

        response = self.client.get("/v1/health")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "ok")
        self.assertEqual(
            response.json()["checks"],
            {"database": True, "migrations": True, "scheduler": True},
        )

    @patch("common.health._migrations_ready", return_value=True)
    @patch("common.health._database_ready", return_value=True)
    def test_deep_health_fails_when_scheduler_lease_is_missing(
        self, _database, _migrations
    ):
        response = self.client.get("/v1/health")

        self.assertEqual(response.status_code, 503)
        self.assertFalse(response.json()["checks"]["scheduler"])

    @patch("common.health.cache.get", side_effect=ConnectionError("redis unavailable"))
    @patch("common.health._migrations_ready", return_value=True)
    @patch("common.health._database_ready", return_value=True)
    def test_deep_health_degrades_cleanly_when_cache_is_unavailable(
        self, _database, _migrations, _cache_get
    ):
        response = self.client.get("/v1/health")

        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json()["status"], "unavailable")


class CredentialEncryptionTests(TestCase):
    @staticmethod
    def _legacy_encrypt(value: str) -> str:
        raw_key = getattr(settings, "AES_SECRET_KEY", settings.SECRET_KEY)
        key = hashlib.sha256(raw_key.encode("utf-8")).digest()
        padder = padding.PKCS7(algorithms.AES.block_size).padder()
        padded = padder.update(value.encode("utf-8")) + padder.finalize()
        encryptor = Cipher(algorithms.AES(key), modes.CBC(key[:16])).encryptor()
        encrypted = encryptor.update(padded) + encryptor.finalize()
        return b64encode(encrypted).decode("ascii")

    def test_gcm_encryption_uses_random_nonce_and_round_trips(self):
        first = aes_encrypt("sensitive-value")
        second = aes_encrypt("sensitive-value")

        self.assertTrue(first.startswith("v2:"))
        self.assertNotEqual(first, second)
        self.assertEqual(aes_decrypt(first), "sensitive-value")
        self.assertEqual(aes_decrypt_with_metadata(first), ("sensitive-value", False))

    @override_settings(
        SECRET_KEY="legacy-secret-key-used-before-key-separation",
        AES_SECRET_KEY="new-independent-aes-secret-key",
    )
    def test_gcm_reads_secret_key_ciphertext_during_key_rotation(self):
        with override_settings(AES_SECRET_KEY="legacy-secret-key-used-before-key-separation"):
            encrypted = aes_encrypt("legacy-gcm-value")

        self.assertEqual(aes_decrypt_with_metadata(encrypted), ("legacy-gcm-value", True))

    @override_settings(
        SECRET_KEY="django-signing-key-kept-separate",
        AES_SECRET_KEY="new-independent-aes-secret-key",
        AES_PREVIOUS_SECRET_KEY="previous-production-aes-key",
    )
    def test_gcm_reads_explicit_previous_aes_key_during_rotation(self):
        with override_settings(AES_SECRET_KEY="previous-production-aes-key"):
            encrypted = aes_encrypt("previous-gcm-value")

        self.assertEqual(aes_decrypt_with_metadata(encrypted), ("previous-gcm-value", True))

    @override_settings(
        SECRET_KEY="django-signing-key-kept-separate",
        AES_SECRET_KEY="new-independent-aes-secret-key",
        AES_PREVIOUS_SECRET_KEY="previous-production-aes-key",
    )
    def test_cbc_reads_explicit_previous_aes_key_during_rotation(self):
        with override_settings(AES_SECRET_KEY="previous-production-aes-key"):
            encrypted = self._legacy_encrypt("previous-cbc-value")

        self.assertEqual(aes_decrypt_with_metadata(encrypted), ("previous-cbc-value", True))

    def test_gcm_tampering_is_rejected_without_legacy_fallback(self):
        encrypted = aes_encrypt("sensitive-value")
        prefix, nonce, tag, ciphertext = encrypted.split(":")
        replacement = "A" if ciphertext[0] != "A" else "B"
        tampered = ":".join((prefix, nonce, tag, f"{replacement}{ciphertext[1:]}"))

        with self.assertRaisesMessage(ValueError, "authentication failed"):
            aes_decrypt(tampered)

    def test_legacy_cbc_ciphertext_remains_readable(self):
        encrypted = self._legacy_encrypt("legacy-value")

        self.assertEqual(aes_decrypt_with_metadata(encrypted), ("legacy-value", True))


class BinanceErrorMappingTests(TestCase):
    def setUp(self):
        clear_rate_limit_cooldown()
        self.client = BinanceFuturesClient(
            BinanceCredentials(api_key="k", secret_key="s", passphrase="p")
        )

    def test_code_1_keeps_original_message(self):
        msg = "Order failed. Margin is insufficient. (sCode: 51008)"
        self.assertEqual(self.client._map_exchange_error("1", msg), msg)

    def test_non_code_1_uses_predefined_mapping(self):
        self.assertEqual(
            self.client._map_exchange_error("50115", "fallback"),
            "请求过于频繁，请稍后重试",
        )

    def test_binance_rate_limit_uses_actionable_message(self):
        self.assertEqual(
            self.client._map_exchange_error("-1003", "Too many requests"),
            "Binance 请求过于频繁，系统已暂停查询，请稍后再试",
        )

    def test_local_budget_error_is_treated_as_rate_limit(self):
        from common.binance import (
            is_binance_preflight_rate_limit_error,
            is_binance_rate_limit_error,
        )

        error = BinanceApiError("request budget unavailable", code="LOCAL_RATE_BUDGET")
        self.assertTrue(is_binance_rate_limit_error(error))
        self.assertTrue(is_binance_preflight_rate_limit_error(error))

    def test_exchange_rate_limit_is_not_a_preflight_rejection(self):
        from common.binance import is_binance_preflight_rate_limit_error

        self.assertFalse(
            is_binance_preflight_rate_limit_error(
                BinanceApiError("too many requests", code="-1003")
            )
        )

    def test_request_accepts_binance_code_200_success_payload(self):
        class FakeResponse:
            status_code = 200
            text = '{"code":200,"msg":"success"}'

        with patch("common.binance._get_private_session") as get_session:
            get_session.return_value.request.return_value = FakeResponse()
            payload = self.client._request("DELETE", "/fapi/v1/algoOrder", {"algoId": "1"}, signed=True)

        self.assertEqual(payload["code"], 200)

    def test_request_marks_json_http_5xx_write_as_unknown(self):
        class FakeResponse:
            status_code = 503
            text = '{"msg":"upstream unavailable"}'
            headers = {}

        with patch("common.binance._get_private_session") as get_session:
            get_session.return_value.request.return_value = FakeResponse()
            with self.assertRaises(BinanceApiError) as raised:
                self.client._request("POST", "/fapi/v1/order", {"symbol": "BTCUSDT"}, signed=True)

        self.assertTrue(raised.exception.outcome_unknown)
        self.assertEqual(raised.exception.code, "503")

    def test_request_marks_exchange_rate_limited_write_as_unknown(self):
        class FakeResponse:
            status_code = 429
            text = '{"code":-1003,"msg":"Too many requests"}'
            headers = {}

        with patch("common.binance._get_private_session") as get_session:
            get_session.return_value.request.return_value = FakeResponse()
            with self.assertRaises(BinanceApiError) as raised:
                self.client._request(
                    "POST",
                    "/sapi/v1/asset/transfer",
                    {"type": "FUNDING_MAIN", "amount": "10"},
                    signed=True,
                    base_url="https://api.binance.com",
                )

        self.assertTrue(raised.exception.outcome_unknown)
        self.assertEqual(raised.exception.code, "429")

    def test_read_only_post_transport_failure_is_not_an_unknown_write(self):
        with patch("common.binance._get_private_session") as get_session:
            get_session.return_value.request.side_effect = TimeoutError("timeout")
            with self.assertRaises(BinanceApiError) as raised:
                self.client._request(
                    "POST",
                    "/sapi/v1/asset/get-funding-asset",
                    {"asset": "USDT"},
                    signed=True,
                    base_url="https://api.binance.com",
                )

        self.assertFalse(raised.exception.outcome_unknown)

    def test_private_request_reports_auth_result_to_binding_observer(self):
        observer = Mock()
        client = BinanceFuturesClient(
            BinanceCredentials(api_key="k", secret_key="s", result_observer=observer)
        )

        class FailureResponse:
            status_code = 400
            text = '{"code":-2014,"msg":"invalid key"}'
            headers = {}

        with patch("common.binance._get_private_session") as get_session:
            get_session.return_value.request.return_value = FailureResponse()
            with self.assertRaises(BinanceApiError):
                client._request("GET", "/fapi/v3/balance", signed=True)

        observed_error = observer.call_args.args[0]
        self.assertIsInstance(observed_error, BinanceApiError)
        self.assertEqual(observed_error.code, "-2014")

    def test_private_request_reports_success_to_binding_observer(self):
        observer = Mock()
        client = BinanceFuturesClient(
            BinanceCredentials(api_key="k", secret_key="s", result_observer=observer)
        )

        class SuccessResponse:
            status_code = 200
            text = "[]"
            headers = {}

        with patch("common.binance._get_private_session") as get_session:
            get_session.return_value.request.return_value = SuccessResponse()
            client._request("GET", "/fapi/v3/balance", signed=True)

        observer.assert_called_once_with(None)

    @patch("common.binance.detect_public_egress_ip", return_value="47.236.86.243")
    def test_request_logs_rate_limit_with_safe_query(self, _mock_ip):
        class FakeResponse:
            status_code = 429
            text = '{"code":-1003,"msg":"Too many requests; current limit of IP(47.24.86.24) is 2400 requests per minute."}'

        with patch("common.binance._get_private_session") as get_session:
            get_session.return_value.request.return_value = FakeResponse()
            with self.assertLogs("common.binance", level="WARNING") as cm:
                with self.assertRaises(BinanceApiError):
                    self.client._request(
                        "GET",
                        "/fapi/v1/order",
                        {
                            "symbol": "BTCUSDT",
                            "orderId": "1",
                            "address": "sensitive-destination",
                            "quantity": "12.5",
                        },
                        signed=True,
                    )

        joined = "\n".join(cm.output)
        self.assertIn("binance_rate_limit", joined)
        self.assertIn("path=/fapi/v1/order", joined)
        self.assertIn("query={'symbol': 'BTCUSDT', 'orderId': '1'}", joined)
        self.assertIn("reported_ip=47.24.86.24", joined)
        self.assertIn("observed_egress_ip=47.236.86.243", joined)
        self.assertNotIn("signature", joined)
        self.assertNotIn("timestamp", joined)
        self.assertNotIn("sensitive-destination", joined)
        self.assertNotIn("12.5", joined)

    @patch("common.binance.detect_public_egress_ip", return_value="47.236.86.243")
    def test_http_rate_limit_with_non_json_body_activates_shared_cooldown(self, _mock_ip):
        class FakeResponse:
            status_code = 429
            text = "upstream throttle page"
            headers = {"retry-after": "45"}

        with patch("common.binance._get_private_session") as get_session:
            get_session.return_value.request.return_value = FakeResponse()
            with self.assertRaises(BinanceApiError) as raised:
                self.client._request("GET", "/fapi/v3/balance", signed=True)

        self.assertEqual(raised.exception.code, "429")
        self.assertGreater(rate_limit_cooldown_remaining("futures"), 0)

    def test_public_http_rate_limit_with_non_json_body_activates_shared_cooldown(self):
        class FakeResponse:
            status_code = 418
            text = ""
            headers = {}

        with patch("common.binance._get_public_session") as get_session:
            get_session.return_value.get.return_value = FakeResponse()
            with self.assertRaises(BinanceApiError) as raised:
                _public_json_request("/fapi/v1/klines")

        self.assertEqual(raised.exception.code, "418")
        self.assertGreater(rate_limit_cooldown_remaining("futures"), 0)


class BinanceResponseNormalizationTests(TestCase):
    def setUp(self):
        cache.clear()
        clear_rate_limit_cooldown()
        clear_account_config_cache("k")
        self.client = BinanceFuturesClient(
            BinanceCredentials(api_key="k", secret_key="s", passphrase="p")
        )

    def test_order_lookup_reserves_critical_recovery_budget_by_default(self):
        with patch.object(
            self.client,
            "_request",
            return_value={"orderId": 123, "status": "NEW", "symbol": "BTCUSDT"},
        ) as request_mock:
            self.client.get_order("BTC-USDT-SWAP", order_id="123")

        request_mock.assert_called_once_with(
            "GET",
            "/fapi/v1/order",
            {"symbol": "BTCUSDT", "orderId": "123"},
            signed=True,
            budget_priority=RequestPriority.CRITICAL,
        )

    def test_protection_reads_can_reserve_critical_budget_explicitly(self):
        with patch.object(self.client, "_request", return_value=[]) as request_mock:
            self.client.get_positions(
                "SWAP",
                "BTC-USDT-SWAP",
                budget_priority=RequestPriority.CRITICAL,
            )

        request_mock.assert_called_once_with(
            "GET",
            "/fapi/v3/positionRisk",
            {"symbol": "BTCUSDT"},
            signed=True,
            budget_priority=RequestPriority.CRITICAL,
        )

        with patch.object(self.client, "_request", return_value={"orders": []}) as request_mock:
            self.client.get_pending_algo_orders(
                inst_id="BTC-USDT-SWAP",
                budget_priority=RequestPriority.CRITICAL,
            )

        request_mock.assert_called_once_with(
            "GET",
            "/fapi/v1/openAlgoOrders",
            {"algoType": "CONDITIONAL", "symbol": "BTCUSDT"},
            signed=True,
            budget_priority=RequestPriority.CRITICAL,
        )

    @patch("common.binance._record_binance_used_weight")
    @patch("common.binance._track_binance_outbound")
    @patch("common.binance._get_public_session")
    def test_public_request_records_path_and_exchange_weight(
        self,
        mock_get_session,
        mock_track,
        mock_record_weight,
    ):
        response = mock_get_session.return_value.get.return_value
        response.text = "[]"
        response.status_code = 200
        response.headers = {"X-MBX-USED-WEIGHT-1M": "17"}

        self.assertEqual(_public_json_request("/fapi/v1/klines"), [])

        mock_track.assert_called_once_with("/fapi/v1/klines")
        mock_record_weight.assert_called_once_with(response.headers)

    @patch("common.binance._get_public_session")
    def test_public_request_rejects_http_error_without_binance_code(self, mock_get_session):
        response = mock_get_session.return_value.get.return_value
        response.text = '{"message":"upstream unavailable"}'
        response.status_code = 503
        response.headers = {}

        with self.assertRaises(BinanceApiError) as raised:
            _public_json_request("/fapi/v1/klines")

        self.assertEqual(raised.exception.code, "503")
        self.assertIn("http: 503", str(raised.exception))

    def test_get_all_orders_normalizes_binance_payload(self):
        payload = [
            {
                "orderId": 123,
                "symbol": "BTCUSDT",
                "status": "FILLED",
                "side": "SELL",
                "positionSide": "SHORT",
                "origQty": "0.5",
                "executedQty": "0.5",
                "avgPrice": "62000.1",
                "price": "62000.0",
                "time": 1710000000000,
                "updateTime": 1710000001000,
                "reduceOnly": True,
                "origType": "TAKE_PROFIT_MARKET",
            }
        ]
        with patch.object(self.client, "_request", return_value=payload):
            rows = self.client.get_all_orders("BTC-USDT-SWAP").get("data") or []

        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["ordId"], "123")
        self.assertEqual(rows[0]["instId"], "BTC-USDT-SWAP")
        self.assertEqual(rows[0]["state"], "filled")
        self.assertEqual(rows[0]["side"], "sell")
        self.assertEqual(rows[0]["posSide"], "short")
        self.assertEqual(rows[0]["reduceOnly"], True)
        self.assertEqual(rows[0]["origType"], "TAKE_PROFIT_MARKET")

    def test_get_spot_usdt_balance_sums_free_and_locked(self):
        payload = {
            "makerCommission": 10,
            "balances": [
                {"asset": "BTC", "free": "0.1", "locked": "0.05"},
                {"asset": "USDT", "free": "100.5", "locked": "20.25"},
            ],
        }
        with patch.object(self.client, "_request", return_value=payload) as mock_request:
            result = self.client.get_spot_usdt_balance()

        self.assertEqual(result, "120.75")
        _args, kwargs = mock_request.call_args
        self.assertIn("api.binance.com", str(kwargs.get("base_url") or ""))

    def test_get_spot_usdt_balance_without_asset_returns_zero(self):
        # 用不同币种避开上一用例的 30 秒缓存 key
        payload = {"balances": [{"asset": "BTC", "free": "1", "locked": "0"}]}
        with patch.object(self.client, "_request", return_value=payload):
            self.assertEqual(self.client.get_spot_usdt_balance("ETH"), "0")

    def test_wallet_balance_reads_reject_malformed_exchange_payloads(self):
        cases = (
            (self.client.get_spot_usdt_balance, {}),
            (self.client.get_spot_usdt_free_balance, {"balances": {}}),
            (self.client.get_funding_usdt_balance, {}),
            (self.client.get_funding_usdt_free_balance, ["invalid-row"]),
        )
        for read_balance, payload in cases:
            with self.subTest(method=read_balance.__name__), patch.object(
                self.client,
                "_request",
                return_value=payload,
            ):
                with self.assertRaisesMessage(BinanceApiError, "余额返回格式异常"):
                    read_balance("USDT", fresh=True)

    def test_get_funding_usdt_balance_sums_wallet_parts(self):
        payload = [
            {"asset": "USDT", "free": "4300", "locked": "0", "freeze": "700", "withdrawing": "0"},
        ]
        with patch.object(self.client, "_request", return_value=payload):
            self.assertEqual(self.client.get_funding_usdt_balance(), "5000")

    def test_get_funding_usdt_free_balance_uses_only_free(self):
        payload = [{"asset": "USDT", "free": "12.5", "locked": "3", "freeze": "4"}]
        with patch.object(self.client, "_request", return_value=payload):
            self.assertEqual(self.client.get_funding_usdt_free_balance("USDT", fresh=True), "12.5")

    def test_transfer_from_funding_is_allowlisted_and_requires_transaction_id(self):
        with patch.object(self.client, "_request", return_value={"tranId": 123}) as mock_request:
            self.assertEqual(self.client.transfer_from_funding("20"), "123")
        args, kwargs = mock_request.call_args
        self.assertEqual(args[:2], ("POST", "/sapi/v1/asset/transfer"))
        self.assertEqual(args[2], {"type": "FUNDING_UMFUTURE", "asset": "USDT", "amount": "20"})
        self.assertTrue(kwargs["signed"])

        with patch.object(self.client, "_request", return_value={}):
            with self.assertRaisesMessage(BinanceApiError, "未返回流水号") as raised:
                self.client.transfer_from_funding("20")
        self.assertTrue(raised.exception.outcome_unknown)

    def test_wallet_transfer_missing_transaction_ids_are_unknown_outcomes(self):
        calls = (
            lambda: self.client.transfer_between_spot_and_futures("1", to_futures=True),
            lambda: self.client.transfer_funding_to_spot("1"),
            lambda: self.client.transfer_spot_to_master("1"),
        )
        for call_transfer in calls:
            with self.subTest(call=call_transfer), patch.object(self.client, "_request", return_value={}):
                with self.assertRaises(BinanceApiError) as raised:
                    call_transfer()
                self.assertTrue(raised.exception.outcome_unknown)

    def test_transfer_funding_to_spot_uses_funding_main(self):
        with patch.object(self.client, "_request", return_value={"tranId": 321}) as mock_request:
            self.assertEqual(self.client.transfer_funding_to_spot("12.5"), "321")
        args, kwargs = mock_request.call_args
        self.assertEqual(args[:2], ("POST", "/sapi/v1/asset/transfer"))
        self.assertEqual(args[2], {"type": "FUNDING_MAIN", "asset": "USDT", "amount": "12.5"})
        self.assertTrue(kwargs["signed"])

    def test_universal_transfer_history_uses_requested_type(self):
        payload = {"total": 1, "rows": [{"tranId": 321, "type": "FUNDING_MAIN"}]}
        with patch.object(self.client, "_request", return_value=payload) as mock_request:
            rows = self.client.get_universal_transfer_history(
                transfer_type="FUNDING_MAIN", start_time_ms=123, end_time_ms=456
            )
        self.assertEqual(rows, payload["rows"])
        args, kwargs = mock_request.call_args
        self.assertEqual(args[:2], ("GET", "/sapi/v1/asset/transfer"))
        self.assertEqual(
            args[2],
            {
                "type": "FUNDING_MAIN",
                "current": 1,
                "size": 100,
                "startTime": 123,
                "endTime": 456,
            },
        )
        self.assertTrue(kwargs["signed"])

    def test_transfer_spot_to_master_has_no_destination_parameter(self):
        with patch.object(self.client, "_request", return_value={"txnId": 456}) as mock_request:
            self.assertEqual(self.client.transfer_spot_to_master("100"), "456")
        args, kwargs = mock_request.call_args
        self.assertEqual(args[:2], ("POST", "/sapi/v1/sub-account/transfer/subToMaster"))
        self.assertEqual(args[2], {"asset": "USDT", "amount": "100"})
        self.assertNotIn("email", args[2])
        self.assertTrue(kwargs["signed"])

    def test_spot_futures_transfer_history_queries_confirmed_rows(self):
        payload = {"total": 1, "rows": [{"tranId": 123, "type": 2, "amount": "10", "status": "CONFIRMED"}]}
        with patch.object(self.client, "_request", return_value=payload) as mock_request:
            rows = self.client.get_spot_futures_transfer_history(
                ccy="USDT",
                start_time_ms=456,
                end_time_ms=789,
            )
        self.assertEqual(rows, payload["rows"])
        args, kwargs = mock_request.call_args
        self.assertEqual(args[:2], ("GET", "/sapi/v1/futures/transfer"))
        self.assertEqual(
            args[2],
            {
                "asset": "USDT",
                "current": 1,
                "size": 100,
                "startTime": 456,
                "endTime": 789,
            },
        )
        self.assertTrue(kwargs["signed"])

    def test_sub_account_transfer_history_queries_only_outgoing(self):
        with patch.object(self.client, "_request", return_value=[]) as mock_request:
            self.client.get_sub_account_transfer_history(ccy="USDT", start_time_ms=123)
        args, kwargs = mock_request.call_args
        self.assertEqual(args[:2], ("GET", "/sapi/v1/sub-account/transfer/subUserHistory"))
        self.assertEqual(args[2], {"asset": "USDT", "type": 2, "startTime": 123})
        self.assertTrue(kwargs["signed"])

    def test_sub_account_transfer_history_supports_direction_and_bounded_window(self):
        with patch.object(self.client, "_request", return_value=[]) as mock_request:
            self.client.get_sub_account_transfer_history(
                ccy="USDT",
                transfer_type=1,
                start_time_ms=123,
                end_time_ms=456,
                limit=200,
            )
        args, kwargs = mock_request.call_args
        self.assertEqual(args[:2], ("GET", "/sapi/v1/sub-account/transfer/subUserHistory"))
        self.assertEqual(
            args[2],
            {"asset": "USDT", "type": 1, "startTime": 123, "endTime": 456, "limit": 200},
        )
        self.assertTrue(kwargs["signed"])

    def test_withdraw_to_binance_address_uses_documented_params(self):
        with patch.object(self.client, "_request", return_value={"id": 789}) as mock_request:
            self.assertEqual(
                self.client.withdraw_to_binance_address(
                    "100",
                    address="0x1234567890abcdef1234567890abcdef12345678",
                    network="BSC",
                    withdraw_order_id="tt-order-1",
                ),
                "789",
            )
        args, kwargs = mock_request.call_args
        self.assertEqual(args[:2], ("POST", "/sapi/v1/capital/withdraw/apply"))
        params = args[2]
        self.assertEqual(params["coin"], "USDT")
        self.assertEqual(params["amount"], "100")
        self.assertEqual(params["address"], "0x1234567890abcdef1234567890abcdef12345678")
        self.assertEqual(params["network"], "BSC")
        self.assertEqual(params["withdrawOrderId"], "tt-order-1")
        self.assertEqual(params["walletType"], 0)
        self.assertEqual(params["transactionFeeFlag"], "true")
        self.assertNotIn("email", params)
        self.assertNotIn("binanceId", params)
        self.assertTrue(kwargs["signed"])

    def test_withdraw_encodes_lowercase_transaction_fee_flag(self):
        class FakeResponse:
            status_code = 200
            text = '{"id":"789"}'
            headers = {}

        with patch("common.binance._get_private_session") as get_session:
            get_session.return_value.request.return_value = FakeResponse()
            self.client.withdraw_to_binance_address(
                "100",
                address="0x1234567890abcdef1234567890abcdef12345678",
                network="BSC",
                withdraw_order_id="tt-order-1",
            )

        request_url = get_session.return_value.request.call_args.kwargs["url"]
        self.assertIn("transactionFeeFlag=true", request_url)
        self.assertNotIn("transactionFeeFlag=True", request_url)

    def test_withdraw_requires_address_and_network_and_rejects_identity(self):
        with self.assertRaisesMessage(BinanceApiError, "未配置目标主账户 Spot 充值地址或网络"):
            self.client.withdraw_to_binance_address("1", address="", network="TRX")
        with self.assertRaisesMessage(BinanceApiError, "不支持邮箱或 UID"):
            self.client.withdraw_to_binance_address("1", address="123456", network="TRX")
        with self.assertRaisesMessage(BinanceApiError, "不支持邮箱或 UID"):
            self.client.withdraw_to_binance_address("1", address="a@example.com", network="TRX")
        with self.assertRaisesMessage(BinanceApiError, "仅支持 BSC"):
            self.client.withdraw_to_binance_address(
                "1", address="0x1234567890abcdef1234567890abcdef12345678", network="SOL"
            )

    def test_withdraw_history_query_shape(self):
        with patch.object(self.client, "_request", return_value=[{"id": 1}]) as mock_request:
            rows = self.client.get_withdraw_history(
                ccy="USDT", withdraw_order_id="tt-order-1", start_time_ms=321
            )
        self.assertEqual(rows, [{"id": 1}])
        args, kwargs = mock_request.call_args
        self.assertEqual(args[:2], ("GET", "/sapi/v1/capital/withdraw/history"))
        self.assertEqual(
            args[2],
            {"coin": "USDT", "limit": 100, "withdrawOrderId": "tt-order-1", "startTime": 321},
        )
        self.assertTrue(kwargs["signed"])

    def test_withdraw_history_supports_completed_status_window_and_offset(self):
        with patch.object(self.client, "_request", return_value=[]) as mock_request:
            self.client.get_withdraw_history(
                ccy="USDT",
                status=6,
                start_time_ms=123,
                end_time_ms=456,
                offset=1000,
                limit=1000,
            )
        args, kwargs = mock_request.call_args
        self.assertEqual(args[:2], ("GET", "/sapi/v1/capital/withdraw/history"))
        self.assertEqual(
            args[2],
            {
                "coin": "USDT",
                "limit": 1000,
                "status": 6,
                "startTime": 123,
                "endTime": 456,
                "offset": 1000,
            },
        )
        self.assertTrue(kwargs["signed"])

    def test_deposit_history_query_shape(self):
        with patch.object(self.client, "_request", return_value=[{"id": "1"}]) as mock_request:
            rows = self.client.get_deposit_history(
                ccy="USDT",
                status=1,
                start_time_ms=123,
                end_time_ms=456,
                offset=1000,
                limit=1000,
            )
        self.assertEqual(rows, [{"id": "1"}])
        args, kwargs = mock_request.call_args
        self.assertEqual(args[:2], ("GET", "/sapi/v1/capital/deposit/hisrec"))
        self.assertEqual(
            args[2],
            {
                "coin": "USDT",
                "limit": 1000,
                "status": 1,
                "startTime": 123,
                "endTime": 456,
                "offset": 1000,
            },
        )
        self.assertTrue(kwargs["signed"])

    def test_account_type_probe_success_on_master_endpoint_is_master(self):
        with patch.object(self.client, "_request", return_value={"subAccounts": []}) as mock_request:
            self.assertEqual(self.client.probe_account_type(), "master")
            self.assertTrue(self.client.is_master_account_probe())
        self.assertEqual(mock_request.call_count, 2)

    def test_account_type_probe_sub_account_endpoint_is_sub(self):
        with patch.object(
            self.client,
            "_request",
            side_effect=[
                BinanceApiError("子账户功能未开通", code="-8012"),
                [],
            ],
        ) as mock_request:
            self.assertEqual(self.client.probe_account_type(), "sub")
        self.assertEqual(mock_request.call_count, 2)
        self.assertEqual(mock_request.call_args_list[0].args[:2], ("GET", "/sapi/v1/sub-account/list"))
        self.assertEqual(mock_request.call_args_list[1].args[:2], ("GET", "/sapi/v1/sub-account/transfer/subUserHistory"))

    def test_account_type_probe_both_minus_8012_is_master_without_sub_accounts(self):
        with patch.object(
            self.client,
            "_request",
            side_effect=BinanceApiError("子账户功能未开通", code="-8012"),
        ):
            self.assertEqual(self.client.probe_account_type(), "master")

    def test_account_type_probe_sub_only_error_is_master_without_sub_accounts(self):
        with patch.object(
            self.client,
            "_request",
            side_effect=[
                BinanceApiError("子账户功能未开通", code="-8012"),
                BinanceApiError(
                    "This endpoint is allowed to request from sub account only",
                    code="-12022",
                ),
            ],
        ):
            self.assertEqual(self.client.probe_account_type(), "master")

    def test_account_type_probe_does_not_trust_minus_12022_without_role_message(self):
        with patch.object(
            self.client,
            "_request",
            side_effect=[
                BinanceApiError("子账户功能未开通", code="-8012"),
                BinanceApiError("unrelated permission failure", code="-12022"),
            ],
        ):
            self.assertEqual(self.client.probe_account_type(), "unknown")

    def test_account_type_probe_other_errors_are_unknown(self):
        with patch.object(
            self.client, "_request", side_effect=BinanceApiError("限频", code="-1003")
        ):
            self.assertEqual(self.client.probe_account_type(), "unknown")
            self.assertFalse(self.client.is_master_account_probe())

    def test_account_type_probe_invalid_sub_account_payload_is_unknown(self):
        with patch.object(
            self.client,
            "_request",
            side_effect=[
                BinanceApiError("子账户功能未开通", code="-8012"),
                {"unexpected": "payload"},
            ],
        ):
            self.assertEqual(self.client.probe_account_type(), "unknown")

    def test_get_user_trades_normalizes_binance_payload(self):
        payload = [
            {
                "id": 88,
                "orderId": 123,
                "symbol": "ETHUSDT",
                "side": "BUY",
                "positionSide": "LONG",
                "qty": "2",
                "price": "3200.5",
                "quoteQty": "6401",
                "realizedPnl": "12.5",
                "commission": "1.2",
                "commissionAsset": "USDT",
                "maker": False,
                "time": 1710000002000,
            }
        ]
        with patch.object(self.client, "_request", return_value=payload):
            rows = self.client.get_user_trades("ETH-USDT-SWAP").get("data") or []

        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["tradeId"], "88")
        self.assertEqual(rows[0]["ordId"], "123")
        self.assertEqual(rows[0]["instId"], "ETH-USDT-SWAP")
        self.assertEqual(rows[0]["side"], "buy")
        self.assertEqual(rows[0]["posSide"], "long")
        self.assertEqual(rows[0]["rawPositionSide"], "LONG")
        self.assertEqual(rows[0]["fillPx"], "3200.5")
        self.assertEqual(rows[0]["fillSz"], "2")
        self.assertEqual(rows[0]["realizedPnl"], "12.5")
        self.assertEqual(rows[0]["fee"], "1.2")

    def test_get_user_trades_preserves_missing_financial_fields_and_explicit_zero(self):
        base = {"symbol": "ETHUSDT", "qty": "1", "side": "BUY"}
        payload = [
            base,
            {**base, "realizedPnl": None, "commission": ""},
            {**base, "realizedPnl": 0, "commission": "0"},
        ]
        with patch.object(self.client, "_request", return_value=payload):
            rows = self.client.get_user_trades("ETH-USDT-SWAP")["data"]
        for row in rows[:2]:
            self.assertIsNone(row["realizedPnl"])
            self.assertIsNone(row["fee"])
        self.assertEqual(rows[2]["realizedPnl"], "0")
        self.assertEqual(rows[2]["fee"], "0")

    def test_get_pending_orders_filters_and_normalizes_open_orders(self):
        payload = [
            {
                "orderId": 7001,
                "symbol": "BTCUSDT",
                "status": "NEW",
                "price": "61500",
                "avgPrice": "0",
                "executedQty": "0",
                "side": "BUY",
                "positionSide": "LONG",
                "reduceOnly": False,
            },
            {
                "orderId": 7002,
                "symbol": "ETHUSDT",
                "status": "PARTIALLY_FILLED",
                "price": "3200",
                "avgPrice": "3199.8",
                "executedQty": "1.5",
            },
        ]
        with patch.object(self.client, "_request", return_value=payload):
            rows = self.client.get_pending_orders().get("data") or []

        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["ordId"], "7001")
        self.assertEqual(rows[0]["state"], "live")
        self.assertEqual(rows[0]["side"], "buy")
        self.assertEqual(rows[0]["positionSide"], "LONG")
        self.assertFalse(rows[0]["reduceOnly"])
        self.assertEqual(rows[1]["state"], "partially_filled")
        self.assertEqual(rows[1]["accFillSz"], "1.5")

    def test_get_pending_orders_scopes_exchange_query_to_symbol(self):
        with patch.object(self.client, "_request", return_value=[]) as mock_request:
            self.client.get_pending_orders(inst_id="BTC-USDT-SWAP")

        self.assertEqual(mock_request.call_args.args[1], "/fapi/v1/openOrders")
        self.assertEqual(mock_request.call_args.args[2], {"symbol": "BTCUSDT"})

    def test_get_pending_algo_orders_keeps_only_stop_and_take_profit_orders(self):
        payload = {
            "orders": [
                {
                    "algoId": 8001,
                    "symbol": "BTCUSDT",
                    "orderType": "STOP_MARKET",
                    "algoStatus": "NEW",
                    "quantity": "0.8",
                    "triggerPrice": "59000",
                    "side": "SELL",
                    "positionSide": "LONG",
                },
                {
                    "algoId": 8002,
                    "symbol": "BTCUSDT",
                    "orderType": "TAKE_PROFIT",
                    "algoStatus": "NEW",
                    "quantity": "0.4",
                    "triggerPrice": "63000",
                    "side": "SELL",
                    "positionSide": "LONG",
                },
                {
                    "algoId": 8003,
                    "symbol": "BTCUSDT",
                    "orderType": "LIMIT",
                    "algoStatus": "NEW",
                    "quantity": "1",
                    "side": "BUY",
                    "positionSide": "BOTH",
                },
            ]
        }
        with patch.object(self.client, "_request", return_value=payload):
            rows = self.client.get_pending_algo_orders(inst_id="BTC-USDT-SWAP").get("data") or []

        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["algoId"], "8001")
        self.assertEqual(rows[0]["slTriggerPx"], "59000")
        self.assertEqual(rows[1]["algoId"], "8002")
        self.assertEqual(rows[1]["tpTriggerPx"], "63000")
        self.assertEqual(rows[1]["algoType"], "TAKE_PROFIT")

    def test_get_pending_algo_orders_by_algo_id_does_not_send_symbol(self):
        payload = {
            "algoId": 8001,
            "symbol": "BTCUSDT",
            "orderType": "STOP_MARKET",
            "algoStatus": "NEW",
            "quantity": "0.8",
            "triggerPrice": "59000",
            "side": "SELL",
            "positionSide": "LONG",
        }
        with patch.object(self.client, "_request", return_value=payload) as mock_request:
            rows = self.client.get_pending_algo_orders(inst_id="BTC-USDT-SWAP", algo_id="8001").get("data") or []

        self.assertEqual(rows[0]["algoId"], "8001")
        self.assertEqual(mock_request.call_args.args[1], "/fapi/v1/algoOrder")
        self.assertEqual(mock_request.call_args.args[2], {"algoId": "8001"})

    def test_get_account_config_uses_latest_account_endpoints(self):
        side_effects = [
            {"canTrade": True, "dualSidePosition": True},
            [{"accountAlias": "alias-001", "asset": "USDT", "balance": "100", "availableBalance": "88"}],
        ]
        with patch.object(self.client, "_request", side_effect=side_effects) as mock_request:
            rows = self.client.get_account_config().get("data") or []

        self.assertEqual(rows[0]["perm"], "trade")
        self.assertEqual(rows[0]["uid"], "alias-001")
        self.assertEqual(rows[0]["posMode"], "long_short_mode")
        self.assertEqual(mock_request.call_args_list[0].args[1], "/fapi/v1/accountConfig")
        self.assertEqual(mock_request.call_args_list[1].args[1], "/fapi/v3/balance")

    def test_get_balance_uses_v3_balance_payload(self):
        payload = [
            {"accountAlias": "alias-001", "asset": "USDT", "balance": "102.5", "availableBalance": "97.2"},
            {"accountAlias": "alias-001", "asset": "BTC", "balance": "0.1", "availableBalance": "0.08"},
        ]
        with patch.object(self.client, "_request", return_value=payload) as mock_request:
            rows = self.client.get_balance("USDT").get("data") or []
            cached_rows = self.client.get_balance("USDT").get("data") or []
            fresh_rows = self.client.get_balance("USDT", fresh=True).get("data") or []

        self.assertEqual(rows[0]["totalEq"], "102.5")
        self.assertEqual(cached_rows, rows)
        self.assertEqual(fresh_rows, rows)
        self.assertEqual(mock_request.call_count, 2)
        self.assertEqual(rows[0]["details"][0]["availEq"], "97.2")
        self.assertEqual(mock_request.call_args.args[1], "/fapi/v3/balance")

    def test_get_usdt_total_equity_uses_total_futures_equity(self):
        with patch.object(
            self.client,
            "get_balance",
            return_value={
                "code": "0",
                "data": [
                    {
                        "totalEq": "125.5",
                        "details": [{"eq": "125.5", "availEq": "80.0", "cashBal": "125.5"}],
                    }
                ],
            },
        ):
            self.assertEqual(get_usdt_total_equity(self.client), "125.5")

    def test_get_usdt_equity_snapshot_reads_futures_balance_once(self):
        with patch.object(
            self.client,
            "get_balance",
            return_value={
                "code": "0",
                "data": [
                    {
                        "totalEq": "125.5",
                        "details": [{"eq": "125.5", "availEq": "80.0", "cashBal": "125.5"}],
                    }
                ],
            },
        ) as mock_get_balance:
            self.assertEqual(get_usdt_equity_snapshot(self.client), ("80.0", "125.5"))

        mock_get_balance.assert_called_once_with("USDT", fresh=False)

    def test_get_usdt_equity_snapshot_rejects_empty_usdt_balance(self):
        with patch.object(
            self.client,
            "get_balance",
            return_value={"code": "0", "data": []},
        ):
            with self.assertRaisesMessage(BinanceApiError, "未返回 USDT 余额"):
                get_usdt_equity_snapshot(self.client)

    def test_place_market_order_supports_new_client_order_id(self):
        with patch.object(self.client, "_get_public_instrument", return_value={"marketLotSz": "0.001", "marketMinSz": "0.001"}), \
             patch.object(self.client, "_request", return_value={"orderId": 101, "status": "FILLED", "avgPrice": "100", "executedQty": "1"}) as mock_request:
            self.client.place_market_order(
                inst_id="BTC-USDT-SWAP",
                side="buy",
                size="1",
                pos_side="long",
                new_client_order_id="rt-test-client-1",
            )

        params = mock_request.call_args.args[2]
        self.assertEqual(params["newClientOrderId"], "rt-test-client-1")

    def test_order_writes_treat_missing_exchange_id_as_unknown(self):
        with patch.object(
            self.client,
            "_get_public_instrument",
            return_value={"marketLotSz": "0.001", "marketMinSz": "0.001"},
        ), patch.object(self.client, "_request", return_value={}):
            with self.assertRaises(BinanceApiError) as market_error:
                self.client.place_market_order(
                    inst_id="BTC-USDT-SWAP",
                    side="buy",
                    size="1",
                    pos_side="long",
                    new_client_order_id="rt-test-missing-id",
                )
        self.assertTrue(market_error.exception.outcome_unknown)

        with patch.object(self.client, "_request", return_value={}):
            with self.assertRaises(BinanceApiError) as cancel_error:
                self.client.cancel_order("BTC-USDT-SWAP", "123")
        self.assertTrue(cancel_error.exception.outcome_unknown)

    def test_get_order_supports_orig_client_order_id(self):
        with patch.object(self.client, "_request", return_value={"orderId": 102, "status": "NEW"}) as mock_request:
            self.client.get_order(
                inst_id="BTC-USDT-SWAP",
                orig_client_order_id="rt-test-client-2",
            )

        params = mock_request.call_args.args[2]
        self.assertNotIn("orderId", params)
        self.assertEqual(params["origClientOrderId"], "rt-test-client-2")

    def test_price_normalization_is_side_aware(self):
        instrument = {"tickSz": "0.1"}
        self.assertEqual(normalize_limit_price(Decimal("100.01"), instrument, "buy"), Decimal("100.0"))
        self.assertEqual(normalize_limit_price(Decimal("100.01"), instrument, "sell"), Decimal("100.1"))
        self.assertEqual(normalize_stop_trigger_price(Decimal("100.01"), instrument, "long"), Decimal("100.0"))
        self.assertEqual(normalize_stop_trigger_price(Decimal("100.01"), instrument, "short"), Decimal("100.1"))
        self.assertEqual(normalize_take_profit_trigger_price(Decimal("100.01"), instrument, "long"), Decimal("100.1"))
        self.assertEqual(normalize_take_profit_trigger_price(Decimal("100.01"), instrument, "short"), Decimal("100.0"))

    def test_standardize_open_order_request_uses_market_rules(self):
        instrument = {
            "ctVal": "1",
            "lotSz": "0.01",
            "minSz": "0.01",
            "marketLotSz": "0.1",
            "marketMinSz": "0.1",
            "tickSz": "0.1",
            "minNotional": "5",
            "triggerProtect": "0.05",
        }
        result = standardize_open_order_request(
            entry_price=Decimal("100"),
            stop_loss_price=Decimal("90.02"),
            stop_loss_amount=Decimal("10"),
            instrument=instrument,
            order_type="market",
        )

        self.assertEqual(result["open_side"], "buy")
        self.assertEqual(result["close_side"], "sell")
        self.assertEqual(result["position_side"], "long")
        self.assertEqual(result["stop_loss_price"], Decimal("90.0"))
        self.assertEqual(result["size"], "1.0")

    def test_standardize_trigger_order_request_validates_take_profit_relation(self):
        instrument = {
            "marketLotSz": "0.001",
            "marketMinSz": "0.001",
            "tickSz": "0.1",
            "triggerProtect": "0.05",
        }
        with self.assertRaisesMessage(BinanceApiError, "多单止盈价必须高于参考价"):
            standardize_trigger_order_request(
                trigger_price=Decimal("99.9"),
                quantity=Decimal("0.5"),
                instrument=instrument,
                trigger_kind="take_profit",
                position_side="long",
                reference_price=Decimal("100"),
            )

        result = standardize_trigger_order_request(
            trigger_price=Decimal("100.06"),
            quantity=Decimal("0.5"),
            instrument=instrument,
            trigger_kind="take_profit",
            position_side="long",
            reference_price=Decimal("100"),
        )
        self.assertEqual(result["trigger_price"], Decimal("100.1"))
        self.assertEqual(result["quantity"], Decimal("0.5"))

    def test_place_stop_loss_order_uses_limit_algo_endpoint(self):
        with patch.object(self.client, "_get_public_instrument", return_value={"marketLotSz": "0.001", "marketMinSz": "0.001", "tickSz": "0.1"}), \
             patch.object(self.client, "_request", return_value={"algoId": 9001}) as mock_request:
            rows = self.client.place_stop_loss_order(
                inst_id="BTC-USDT-SWAP",
                side="sell",
                size="0.5",
                stop_loss_price="59000.12",
                pos_side="long",
            ).get("data") or []

        self.assertEqual(rows[0]["algoId"], "9001")
        self.assertEqual(mock_request.call_args.args[0], "POST")
        self.assertEqual(mock_request.call_args.args[1], "/fapi/v1/algoOrder")
        self.assertEqual(mock_request.call_args.args[2]["algoType"], "CONDITIONAL")
        self.assertEqual(mock_request.call_args.args[2]["type"], "STOP")
        self.assertEqual(mock_request.call_args.args[2]["triggerPrice"], "59000.1")
        self.assertEqual(mock_request.call_args.args[2]["price"], "59000.1")

    def test_place_algo_orders_support_client_algo_id(self):
        with patch.object(self.client, "_get_public_instrument", return_value={"marketLotSz": "0.001", "marketMinSz": "0.001", "tickSz": "0.1"}), \
             patch.object(self.client, "_request", return_value={"algoId": 9005}) as mock_request:
            self.client.place_take_profit_order(
                inst_id="BTC-USDT-SWAP",
                side="sell",
                size="0.5",
                trigger_price="60000",
                pos_side="long",
                client_algo_id="tt123tp1",
            )

        self.assertEqual(mock_request.call_args.args[2]["clientAlgoId"], "tt123tp1")

    def test_place_stop_loss_order_rounds_short_trigger_up(self):
        with patch.object(self.client, "_get_public_instrument", return_value={"marketLotSz": "0.001", "marketMinSz": "0.001", "tickSz": "0.1"}), \
             patch.object(self.client, "_request", return_value={"algoId": 9003}) as mock_request:
            self.client.place_stop_loss_order(
                inst_id="BTC-USDT-SWAP",
                side="buy",
                size="0.5",
                stop_loss_price="59000.12",
                pos_side="short",
            )

        self.assertEqual(mock_request.call_args.args[2]["triggerPrice"], "59000.2")

    def test_place_stop_market_order_uses_contract_price_without_price_protect(self):
        with patch.object(self.client, "_get_public_instrument", return_value={"marketLotSz": "0.001", "marketMinSz": "0.001", "tickSz": "0.1"}), \
             patch.object(self.client, "_request", return_value={"algoId": 9007}) as mock_request:
            self.client.place_stop_market_order(
                inst_id="BTC-USDT-SWAP",
                side="sell",
                size="0.5",
                trigger_price="59000.12",
                pos_side="long",
            )

        params = mock_request.call_args.args[2]
        self.assertEqual(params["type"], "STOP_MARKET")
        self.assertEqual(params["triggerPrice"], "59000.1")
        self.assertEqual(params["workingType"], "CONTRACT_PRICE")
        self.assertEqual(params["priceProtect"], "FALSE")

    def test_place_take_profit_order_rounds_long_trigger_up(self):
        with patch.object(self.client, "_get_public_instrument", return_value={"marketLotSz": "0.001", "marketMinSz": "0.001", "tickSz": "0.1"}), \
             patch.object(self.client, "_request", return_value={"algoId": 9004}) as mock_request:
            self.client.place_take_profit_order(
                inst_id="BTC-USDT-SWAP",
                side="sell",
                size="0.5",
                trigger_price="59000.12",
                pos_side="long",
            )

        self.assertEqual(mock_request.call_args.args[2]["triggerPrice"], "59000.2")

    def test_place_limit_take_profit_order_uses_take_profit_with_price(self):
        with patch.object(self.client, "_get_public_instrument", return_value={"marketLotSz": "0.001", "marketMinSz": "0.001", "tickSz": "0.1"}), \
             patch.object(self.client, "_request", return_value={"algoId": 9006}) as mock_request:
            self.client.place_take_profit_order(
                inst_id="BTC-USDT-SWAP",
                side="sell",
                size="0.5",
                trigger_price="59000.12",
                pos_side="long",
                order_type="limit",
            )

        params = mock_request.call_args.args[2]
        self.assertEqual(params["type"], "TAKE_PROFIT")
        self.assertEqual(params["triggerPrice"], "59000.2")
        self.assertEqual(params["price"], "59000.2")

    @patch("common.binance._public_json_request")
    def test_get_last_prices_uses_v2_price_ticker(self, mock_public):
        mock_public.return_value = [{"symbol": "BTCUSDT", "price": "60000"}]

        rows = self.client.get_last_prices({"BTC-USDT-SWAP"}).get("data") or []

        self.assertEqual(rows[0]["last"], "60000")
        self.assertEqual(mock_public.call_args.args[0], "/fapi/v2/ticker/price")

    @patch("common.binance._public_json_request")
    def test_get_mark_price_candles_uses_mark_price_endpoint(self, mock_public):
        mock_public.return_value = [[1, "100", "110", "90", "105", "1", 2, "3", 4]]

        rows = self.client.get_mark_price_candles("BTC-USDT-SWAP").get("data") or []

        self.assertEqual(rows[0][2], "110")
        self.assertEqual(mock_public.call_args.args[0], "/fapi/v1/markPriceKlines")

    @patch("common.binance._public_json_request")
    def test_get_candles_uses_regular_kline_endpoint(self, mock_public):
        mock_public.return_value = [[1, "100", "110", "90", "105", "1", 2, "3", 4]]

        rows = self.client.get_candles("BTC-USDT-SWAP", bar="15m", limit=220).get("data") or []

        self.assertEqual(rows[0][2], "110")
        self.assertEqual(mock_public.call_args.args[0], "/fapi/v1/klines")
        self.assertEqual(mock_public.call_args.args[1]["interval"], "15m")

    def test_cancel_algos_uses_algo_endpoint(self):
        with patch.object(self.client, "_request", return_value={"algoId": 9002}) as mock_request:
            rows = self.client.cancel_algos(algo_id="9002", inst_id="BTC-USDT-SWAP").get("data") or []

        self.assertEqual(rows[0]["algoId"], "9002")
        self.assertEqual(mock_request.call_args.args[0], "DELETE")
        self.assertEqual(mock_request.call_args.args[1], "/fapi/v1/algoOrder")
        self.assertEqual(mock_request.call_args.args[2], {"algoId": "9002"})

    def test_algo_client_allows_delayed_visibility_for_stop_loss(self):
        algo_client = BinanceAlgoClient(self.client)
        with patch.object(self.client, "place_stop_loss_order", return_value={"code": "0", "data": [{"algoId": "9002"}]}), \
             patch.object(self.client, "get_pending_algo_orders", side_effect=BinanceApiError("timeout")):
            algo_id = algo_client.create_stop_loss(
                inst_id="BTC-USDT-SWAP",
                side="sell",
                size="0.5",
                stop_loss_price="59000",
                pos_side="long",
                visibility_mode=ALGO_VISIBILITY_ALLOW_DELAYED,
            )

        self.assertEqual(algo_id, "9002")

    @patch("common.binance.time.sleep")
    def test_algo_client_requires_visible_stop_loss_when_requested(self, mock_sleep):
        algo_client = BinanceAlgoClient(self.client)
        with patch.object(self.client, "place_stop_loss_order", return_value={"code": "0", "data": [{"algoId": "9002"}]}), \
             patch.object(self.client, "get_pending_algo_orders", return_value={"code": "0", "data": []}) as mock_get, \
             patch.object(self.client, "cancel_algos", return_value={"code": "0", "data": [{"algoId": "9002"}]}):
            with self.assertRaisesMessage(BinanceApiError, "条件单创建后未查到挂单"):
                algo_client.create_stop_loss(
                    inst_id="BTC-USDT-SWAP",
                    side="sell",
                    size="0.5",
                    stop_loss_price="59000",
                    pos_side="long",
                    visibility_mode=ALGO_VISIBILITY_REQUIRE_VISIBLE,
                )
        self.assertEqual(mock_get.call_count, 10)
        self.assertEqual(mock_sleep.call_count, 4)

    def test_algo_client_cross_checks_open_list_when_single_order_query_is_delayed(self):
        algo_client = BinanceAlgoClient(self.client)
        visible = {
            "algoId": "9002",
            "clientAlgoId": "tp-client-1",
            "instId": "BTC-USDT-SWAP",
            "sz": "0.5",
            "slTriggerPx": "0",
            "tpTriggerPx": "61000",
            "side": "sell",
            "posSide": "long",
            "state": "live",
            "algoType": "TAKE_PROFIT_MARKET",
        }
        with patch.object(
            self.client,
            "place_take_profit_order",
            return_value={"code": "0", "data": [{"algoId": "9002"}]},
        ), patch.object(
            self.client,
            "get_pending_algo_orders",
            side_effect=[
                BinanceApiError("未查到条件单"),
                {"code": "0", "data": [visible]},
            ],
        ) as mock_get, patch.object(self.client, "cancel_algos") as mock_cancel:
            algo_id = algo_client.create_take_profit(
                inst_id="BTC-USDT-SWAP",
                side="sell",
                size="0.5",
                trigger_price="61000",
                pos_side="long",
                client_algo_id="tp-client-1",
                visibility_mode=ALGO_VISIBILITY_REQUIRE_VISIBLE,
            )

        self.assertEqual(algo_id, "9002")
        self.assertEqual(mock_get.call_count, 2)
        self.assertEqual(mock_get.call_args_list[0].kwargs["algo_id"], "9002")
        self.assertNotIn("algo_id", mock_get.call_args_list[1].kwargs)
        mock_cancel.assert_not_called()

    def test_algo_client_does_not_rollback_an_already_finished_order(self):
        algo_client = BinanceAlgoClient(self.client)
        finished = {
            "algoId": "9002",
            "instId": "BTC-USDT-SWAP",
            "sz": "0.5",
            "state": "finished",
            "algoType": "TAKE_PROFIT_MARKET",
        }
        with patch.object(
            self.client,
            "place_take_profit_order",
            return_value={"code": "0", "data": [{"algoId": "9002"}]},
        ), patch.object(
            self.client,
            "get_pending_algo_orders",
            return_value={"code": "0", "data": [finished]},
        ), patch.object(self.client, "cancel_algos") as mock_cancel:
            with self.assertRaisesMessage(BinanceApiError, "已不在挂单状态") as raised:
                algo_client.create_take_profit(
                    inst_id="BTC-USDT-SWAP",
                    side="sell",
                    size="0.5",
                    trigger_price="61000",
                    pos_side="long",
                    client_algo_id="tp-client-1",
                    visibility_mode=ALGO_VISIBILITY_REQUIRE_VISIBLE,
                )

        self.assertEqual(raised.exception.code, "ALGO_NOT_LIVE")
        mock_cancel.assert_not_called()

    def test_algo_client_recovers_unknown_submit_by_client_id_without_resubmitting(self):
        algo_client = BinanceAlgoClient(self.client)
        visible = {
            "algoId": "9003",
            "clientAlgoId": "stop-client-1",
            "instId": "BTC-USDT-SWAP",
            "sz": "0.5",
            "slTriggerPx": "59000",
            "tpTriggerPx": "0",
            "side": "sell",
            "posSide": "long",
            "state": "live",
            "algoType": "STOP",
        }
        with patch.object(
            self.client,
            "place_stop_loss_order",
            side_effect=BinanceApiError("请求超时", code="-1007", outcome_unknown=True),
        ) as mock_place, patch.object(
            self.client,
            "get_pending_algo_orders",
            return_value={"code": "0", "data": [visible]},
        ):
            algo_id = algo_client.create_stop_loss(
                inst_id="BTC-USDT-SWAP",
                side="sell",
                size="0.5",
                stop_loss_price="59000",
                pos_side="long",
                client_algo_id="stop-client-1",
            )

        self.assertEqual(algo_id, "9003")
        mock_place.assert_called_once()

    def test_algo_client_does_not_query_after_definitive_submit_rejection(self):
        algo_client = BinanceAlgoClient(self.client)
        with patch.object(
            self.client,
            "place_take_profit_order",
            side_effect=BinanceApiError("止盈价无效", code="-1130"),
        ) as mock_place, patch.object(self.client, "get_pending_algo_orders") as mock_get:
            with self.assertRaisesMessage(BinanceApiError, "止盈价无效"):
                algo_client.create_take_profit(
                    inst_id="BTC-USDT-SWAP",
                    side="sell",
                    size="0.5",
                    trigger_price="60000",
                    pos_side="long",
                    client_algo_id="tp-client-1",
                )

        mock_place.assert_called_once()
        mock_get.assert_not_called()

    def test_algo_client_recovers_duplicate_client_algo_id(self):
        algo_client = BinanceAlgoClient(self.client)
        visible = {
            "algoId": "9004",
            "clientAlgoId": "tp-client-duplicate",
            "instId": "BTC-USDT-SWAP",
            "sz": "0.5",
            "slTriggerPx": "0",
            "tpTriggerPx": "60000",
            "side": "sell",
            "posSide": "long",
            "state": "live",
            "algoType": "TAKE_PROFIT_MARKET",
        }
        with patch.object(
            self.client,
            "place_take_profit_order",
            side_effect=BinanceApiError("The client algo id is duplicated", code="-20132"),
        ) as mock_place, patch.object(
            self.client,
            "get_pending_algo_orders",
            return_value={"code": "0", "data": [visible]},
        ):
            algo_id = algo_client.create_take_profit(
                inst_id="BTC-USDT-SWAP",
                side="sell",
                size="0.5",
                trigger_price="60000",
                pos_side="long",
                client_algo_id="tp-client-duplicate",
            )

        self.assertEqual(algo_id, "9004")
        mock_place.assert_called_once()

    def test_algo_client_rejects_duplicate_client_id_with_different_order_type(self):
        algo_client = BinanceAlgoClient(self.client)
        conflicting = {
            "algoId": "9004",
            "clientAlgoId": "tp-client-conflict",
            "instId": "BTC-USDT-SWAP",
            "sz": "0.5",
            "slTriggerPx": "60000",
            "tpTriggerPx": "0",
            "side": "sell",
            "posSide": "long",
            "state": "live",
            "algoType": "STOP_MARKET",
        }
        with patch.object(
            self.client,
            "place_take_profit_order",
            side_effect=BinanceApiError("The client algo id is duplicated", code="-20132"),
        ) as mock_place, patch.object(
            self.client,
            "get_pending_algo_orders",
            return_value={"code": "0", "data": [conflicting]},
        ) as mock_get:
            with self.assertRaisesMessage(BinanceApiError, "条件单类型不一致") as raised:
                algo_client.create_take_profit(
                    inst_id="BTC-USDT-SWAP",
                    side="sell",
                    size="0.5",
                    trigger_price="60000",
                    pos_side="long",
                    client_algo_id="tp-client-conflict",
                )

        self.assertEqual(raised.exception.code, "ALGO_CLIENT_ID_CONFLICT")
        mock_place.assert_called_once()
        mock_get.assert_called_once()

    @patch("common.binance.time.sleep")
    def test_algo_client_cancel_unknown_response_requires_two_absent_reads(self, mock_sleep):
        algo_client = BinanceAlgoClient(self.client)
        with patch.object(
            self.client,
            "cancel_algos",
            side_effect=BinanceApiError("请求超时", code="-1007", outcome_unknown=True),
        ) as mock_cancel, patch.object(
            self.client,
            "get_pending_algo_orders",
            side_effect=[{"code": "0", "data": []}, {"code": "0", "data": []}],
        ) as mock_get:
            algo_id = algo_client.cancel_algo_confirmed("9005", "BTC-USDT-SWAP")

        self.assertEqual(algo_id, "9005")
        mock_cancel.assert_called_once()
        self.assertEqual(mock_get.call_count, 2)
        mock_sleep.assert_called_once_with(ALGO_VISIBILITY_RETRY_DELAYS_SECONDS[0])

    def test_algo_client_cancel_definitive_rejection_is_not_retried(self):
        algo_client = BinanceAlgoClient(self.client)
        with patch.object(
            self.client,
            "cancel_algos",
            side_effect=BinanceApiError("权限不足", code="-2015"),
        ) as mock_cancel, patch.object(self.client, "get_pending_algo_orders") as mock_get:
            with self.assertRaisesMessage(BinanceApiError, "权限不足"):
                algo_client.cancel_algo_confirmed("9005", "BTC-USDT-SWAP")

        mock_cancel.assert_called_once()
        mock_get.assert_not_called()

    @patch("common.binance.time.sleep")
    def test_algo_client_retries_until_replacement_take_profit_is_visible(self, mock_sleep):
        algo_client = BinanceAlgoClient(self.client)
        visible = {
            "algoId": "9004",
            "instId": "BTC-USDT-SWAP",
            "sz": "0.5",
            "slTriggerPx": "0",
            "tpTriggerPx": "60000",
            "side": "sell",
            "posSide": "long",
            "state": "live",
            "algoType": "TAKE_PROFIT_MARKET",
        }
        with patch.object(
            self.client,
            "place_take_profit_order",
            return_value={"code": "0", "data": [{"algoId": "9004"}]},
        ), patch.object(
            self.client,
            "get_pending_algo_orders",
            side_effect=[
                {"code": "0", "data": []},
                {"code": "0", "data": []},
                {"code": "0", "data": [visible]},
            ],
        ) as mock_get:
            algo_id = algo_client.create_take_profit(
                inst_id="BTC-USDT-SWAP",
                side="sell",
                size="0.5",
                trigger_price="60000",
                pos_side="long",
                visibility_mode=ALGO_VISIBILITY_REQUIRE_VISIBLE,
            )

        self.assertEqual(algo_id, "9004")
        self.assertEqual(mock_get.call_count, 3)
        mock_sleep.assert_called_once_with(ALGO_VISIBILITY_RETRY_DELAYS_SECONDS[0])

    def test_algo_client_move_stop_loss_returns_new_algo_id(self):
        algo_client = BinanceAlgoClient(self.client)
        with patch.object(
            self.client,
            "get_pending_algo_orders",
            side_effect=[
                {"code": "0", "data": [{"algoId": "old-1", "instId": "BTC-USDT-SWAP", "sz": "0.5", "slTriggerPx": "59000", "tpTriggerPx": "0", "side": "sell", "posSide": "long", "state": "live", "algoType": "STOP_MARKET"}]},
                {"code": "0", "data": [{"algoId": "new-1", "instId": "BTC-USDT-SWAP", "sz": "0.5", "slTriggerPx": "59500", "tpTriggerPx": "0", "side": "sell", "posSide": "long", "state": "live", "algoType": "STOP_MARKET"}]},
            ],
        ), patch.object(
            self.client,
            "place_stop_loss_order",
            return_value={"code": "0", "data": [{"algoId": "new-1"}]},
        ), patch.object(
            self.client,
            "cancel_algos",
            return_value={"code": "0", "data": [{"algoId": "old-1"}]},
        ) as mock_cancel:
            new_algo_id = algo_client.move_stop_loss(
                algo_id="old-1",
                inst_id="BTC-USDT-SWAP",
                stop_loss_price="59500",
                visibility_mode=ALGO_VISIBILITY_REQUIRE_VISIBLE,
            )

        self.assertEqual(new_algo_id, "new-1")
        mock_cancel.assert_called_once_with(algo_id="old-1", inst_id="BTC-USDT-SWAP")

    def test_get_positions_normalizes_long_short_and_one_way_position_risk(self):
        payload = [
            {
                "symbol": "BTCUSDT",
                "positionAmt": "0.3",
                "positionSide": "LONG",
                "markPrice": "62000",
                "entryPrice": "60000",
                "unRealizedProfit": "600",
                "notional": "18600",
                "leverage": "25",
            },
            {
                "symbol": "ETHUSDT",
                "positionAmt": "-2",
                "positionSide": "BOTH",
                "markPrice": "3200",
                "entryPrice": "3300",
                "unRealizedProfit": "200",
                "notional": "-6400",
                "leverage": "10",
            },
            {
                "symbol": "XRPUSDT",
                "positionAmt": "0",
                "positionSide": "BOTH",
                "markPrice": "1",
                "entryPrice": "1",
                "unRealizedProfit": "0",
                "notional": "0",
                "leverage": "5",
            },
        ]
        with patch.object(self.client, "_request", return_value=payload):
            rows = self.client.get_positions().get("data") or []

        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["instId"], "BTC-USDT-SWAP")
        self.assertEqual(rows[0]["posSide"], "long")
        self.assertEqual(rows[0]["pos"], "0.3")
        self.assertEqual(rows[0]["margin"], "744")
        self.assertEqual(Decimal(rows[0]["uplRatio"]).quantize(Decimal("0.0001")), Decimal("0.8065"))
        self.assertEqual(rows[1]["instId"], "ETH-USDT-SWAP")
        self.assertEqual(rows[1]["posSide"], "short")
        self.assertEqual(rows[1]["pos"], "-2")
        self.assertEqual(rows[1]["margin"], "640")
        self.assertEqual(Decimal(rows[1]["uplRatio"]), Decimal("0.3125"))

    def test_get_positions_uses_v3_position_risk_with_symbol_filter(self):
        with patch.object(self.client, "_request", return_value=[]) as mock_request:
            self.client.get_positions(inst_id="BTC-USDT-SWAP")

        self.assertEqual(mock_request.call_args.args[1], "/fapi/v3/positionRisk")
        self.assertEqual(mock_request.call_args.args[2], {"symbol": "BTCUSDT"})

    def test_get_leverage_bracket_normalizes_first_bracket(self):
        payload = [
            {
                "symbol": "BTCUSDT",
                "brackets": [
                    {"initialLeverage": 50, "notionalCap": "250000"},
                    {"initialLeverage": 25, "notionalCap": "1000000"},
                ],
            }
        ]
        with patch.object(self.client, "_request", return_value=payload):
            rows = self.client.get_leverage_bracket("BTC-USDT-SWAP").get("data") or []

        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["instId"], "BTC-USDT-SWAP")
        self.assertEqual(rows[0]["maxLever"], "50")
        self.assertEqual(rows[0]["notionalCap"], "250000")

    def test_get_bills_normalizes_income_rows_with_missing_symbol(self):
        payload = [
            {
                "symbol": "BTCUSDT",
                "income": "12.34",
                "incomeType": "REALIZED_PNL",
                "time": 1710000000000,
            },
            {
                "symbol": "",
                "income": "-1.23",
                "incomeType": "COMMISSION",
                "time": 1710000001000,
            },
        ]
        with patch.object(self.client, "_request", return_value=payload):
            rows = self.client.get_bills(limit=50).get("data") or []

        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["instId"], "BTC-USDT-SWAP")
        self.assertEqual(rows[0]["type"], "REALIZED_PNL")
        self.assertEqual(rows[1]["instId"], "")
        self.assertEqual(rows[1]["pnl"], "-1.23")

    def test_closed_position_history_groups_one_way_both_trades(self):
        class FakeClient:
            def get_user_trades(self, **kwargs):  # noqa: ARG002
                return {
                    "code": "0",
                    "data": [
                        {
                            "instId": "BTC-USDT-SWAP",
                            "side": "buy",
                            "posSide": "long",
                            "rawPositionSide": "BOTH",
                            "fillPx": "100",
                            "fillSz": "1",
                            "realizedPnl": "0",
                            "fee": "0.1",
                            "time": "1710000000000",
                        },
                        {
                            "instId": "BTC-USDT-SWAP",
                            "side": "sell",
                            "posSide": "short",
                            "rawPositionSide": "BOTH",
                            "fillPx": "110",
                            "fillSz": "1",
                            "realizedPnl": "10",
                            "fee": "0.1",
                            "time": "1710000060000",
                        },
                    ],
                }

            def get_bills(self, **kwargs):  # noqa: ARG002
                return {"code": "0", "data": []}

        rows = build_closed_position_history(FakeClient(), limit=10).get("data") or []

        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["direction"], "long")
        self.assertEqual(rows[0]["openAvgPx"], "100")
        self.assertEqual(rows[0]["closeAvgPx"], "110")
        self.assertEqual(rows[0]["realizedPnl"], "10")

    def test_get_today_realized_pnl_includes_fee_and_funding(self):
        class FakeClient:
            def get_bills(self, **kwargs):
                self.kwargs = kwargs
                return {
                    "code": "0",
                    "data": [
                        {"uTime": "4102444800000", "pnl": "12.34", "type": "REALIZED_PNL"},
                        {"uTime": "4102444800200", "pnl": "-0.34", "type": "COMMISSION"},
                        {"uTime": "4102444800300", "pnl": "-0.20", "type": "FUNDING_FEE"},
                        {"uTime": "4102444801000", "pnl": "-2.00", "type": "REALIZED_PNL"},
                        {"uTime": "4102444801200", "pnl": "1.50", "type": "TRANSFER"},
                    ],
                }

        client = FakeClient()
        value = _get_today_realized_pnl(client)  # far-future timestamps ensure they remain >= today's cutoff

        self.assertEqual(value, "9.8")
        self.assertNotIn("bill_type", client.kwargs)
