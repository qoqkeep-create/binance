import json
from types import SimpleNamespace
from unittest.mock import patch

from django.core.cache import cache
from django.test import SimpleTestCase, override_settings

from common.binance import (
    BinanceApiError,
    BinanceCredentials,
    BinanceFuturesClient,
    clear_rate_limit_cooldown,
)
from common.binance_rate_limit import (
    RequestBudgetExceeded,
    RequestPriority,
    _clear_local_budget_state,
    classify_request,
    observe_response_headers,
    reserve_request_budget,
)


class BinancePayHistoryTests(SimpleTestCase):
    def setUp(self):
        cache.clear()
        _clear_local_budget_state()
        clear_rate_limit_cooldown()
        self.client = BinanceFuturesClient(
            BinanceCredentials(api_key="pay-test-key", secret_key="pay-test-secret")
        )
        self.receipt = {
            "orderType": "C2C",
            "transactionId": "pay-receipt-600",
            "transactionTime": 1_790_738_590_208,
            "amount": "600.00000000",
            "currency": "USDT",
            "walletType": 1,
        }

    def test_real_http_validation_accepts_pay_success_code(self):
        response = SimpleNamespace(
            status_code=200,
            text=json.dumps({"code": "000000", "success": True, "data": [self.receipt]}),
            headers={},
        )
        with patch("common.binance._get_private_session") as get_session:
            get_session.return_value.request.return_value = response
            payload = self.client._request(
                "GET",
                "/sapi/v1/pay/transactions",
                {"startTime": 123, "endTime": 456, "limit": 100},
                base_url="https://api.binance.com",
            )

        self.assertEqual(payload["data"], [self.receipt])

    def test_pay_success_code_is_not_accepted_by_other_endpoints(self):
        response = SimpleNamespace(
            status_code=200,
            text=json.dumps({"code": "000000", "success": True, "data": []}),
            headers={},
        )
        with patch("common.binance._get_private_session") as get_session:
            get_session.return_value.request.return_value = response
            with self.assertRaises(BinanceApiError):
                self.client._request("GET", "/fapi/v3/balance")

    def test_pay_success_requires_true_success_and_successful_http_status(self):
        cases = [(200, False), (200, None), (200, "true"), (400, True), (503, True)]
        for status, success in cases:
            with self.subTest(status=status, success=success), patch(
                "common.binance._get_private_session"
            ) as get_session, patch("common.binance.reserve_request_budget"):
                get_session.return_value.request.return_value = SimpleNamespace(
                    status_code=status,
                    text=json.dumps({"code": "000000", "success": success, "data": []}),
                    headers={},
                )
                with self.assertRaises(BinanceApiError):
                    self.client._request("GET", "/sapi/v1/pay/transactions")

    def test_query_uses_signed_pay_endpoint_and_bounded_parameters(self):
        payload = {"code": "000000", "success": True, "data": [self.receipt]}
        with patch.object(self.client, "_request", return_value=payload) as mock_request:
            rows = self.client.get_pay_transactions(
                start_time_ms=123,
                end_time_ms=456,
                limit=1000,
            )

        self.assertEqual(rows, [self.receipt])
        args, kwargs = mock_request.call_args
        self.assertEqual(args, (
            "GET",
            "/sapi/v1/pay/transactions",
            {"startTime": 123, "endTime": 456, "limit": 100},
        ))
        self.assertTrue(kwargs["signed"])
        self.assertEqual(kwargs["base_url"], "https://api.binance.com")

    def test_getter_validates_envelope_and_data_instead_of_returning_empty(self):
        malformed = [
            [],
            {},
            {"code": "0", "success": True, "data": []},
            {"code": "000000", "data": []},
            {"code": "000000", "success": False, "data": []},
            {"code": "000000", "success": True},
            {"code": "000000", "success": True, "data": None},
            {"code": "000000", "success": True, "data": {}},
            {"code": "000000", "success": True, "data": [self.receipt, None]},
        ]
        for payload in malformed:
            with self.subTest(payload=payload), patch.object(
                self.client, "_request", return_value=payload
            ), self.assertRaises(BinanceApiError):
                self.client.get_pay_transactions()

    def test_successful_empty_history_remains_valid(self):
        with patch.object(self.client, "_request", return_value={
            "code": "000000", "success": True, "data": []
        }):
            self.assertEqual(self.client.get_pay_transactions(), [])

    def test_real_request_returns_receipt_without_counterparty_identity(self):
        private_receipt = {
            **self.receipt,
            "payerInfo": {"name": "payer-name", "binanceId": "payer-uid"},
            "receiverInfo": {"email": "receiver@example.test", "phoneNumber": "phone"},
            "fundsDetail": [{"currency": "USDT", "amount": "600"}],
        }
        response = SimpleNamespace(
            status_code=200,
            text=json.dumps({"code": "000000", "success": True, "data": [private_receipt]}),
            headers={},
        )
        with patch("common.binance._get_private_session") as get_session:
            get_session.return_value.request.return_value = response
            rows = self.client.get_pay_transactions(start_time_ms=123, end_time_ms=456)

        self.assertEqual(rows, [self.receipt])
        self.assertNotIn("payerInfo", rows[0])
        self.assertNotIn("receiverInfo", rows[0])


@override_settings(BINANCE_SAPI_WEIGHT_LIMIT_PER_MINUTE=12000, BINANCE_BACKGROUND_WEIGHT_RATIO=0.65)
class BinancePayBudgetTests(SimpleTestCase):
    def setUp(self):
        cache.clear()
        _clear_local_budget_state()
        self.spec = classify_request(
            method="GET",
            path="/sapi/v1/pay/transactions",
            base_url="https://api.binance.com",
        )

    def test_pay_uses_background_account_weight_without_order_budget(self):
        self.assertEqual(self.spec.scope, "sapi")
        self.assertEqual(self.spec.priority, RequestPriority.BACKGROUND)
        self.assertEqual(self.spec.weight, 3000)
        self.assertTrue(self.spec.account_weight)
        self.assertFalse(self.spec.counts_as_order)

    def test_account_weight_is_isolated_and_same_key_remains_bounded(self):
        for account_key in ("account-a", "account-b", "account-c", "account-d"):
            for _ in range(39):
                reserve_request_budget(self.spec, account_api_key=account_key, now=120.0)
            with self.assertRaises(RequestBudgetExceeded):
                reserve_request_budget(self.spec, account_api_key=account_key, now=120.0)

    def test_uid_header_updates_only_its_account_weight(self):
        observe_response_headers(
            {"x-sapi-used-uid-weight-1m": "117000"},
            scope="sapi",
            account_api_key="account-a",
            now=120.0,
            account_weight=True,
        )

        with self.assertRaises(RequestBudgetExceeded):
            reserve_request_budget(self.spec, account_api_key="account-a", now=120.0)
        reserve_request_budget(self.spec, account_api_key="account-b", now=120.0)
        deposit = classify_request(
            method="GET",
            path="/sapi/v1/capital/deposit/hisrec",
            base_url="https://api.binance.com",
        )
        self.assertFalse(deposit.account_weight)
        reserve_request_budget(deposit, account_api_key="account-a", now=120.0)

    def test_other_uid_endpoint_header_does_not_consume_pay_budget(self):
        observe_response_headers(
            {"X-SAPI-USED-UID-WEIGHT-1M": "180000"},
            scope="sapi",
            account_api_key="account-a",
            now=120.0,
        )
        reserve_request_budget(self.spec, account_api_key="account-a", now=120.0)

    def test_ip_and_uid_headers_remain_separate_budget_dimensions(self):
        observe_response_headers(
            {"X-SAPI-USED-UID-WEIGHT-1M": "117000", "X-SAPI-USED-IP-WEIGHT-1M": "7800"},
            scope="sapi",
            account_api_key="account-a",
            now=120.0,
            account_weight=True,
        )

        with self.assertRaises(RequestBudgetExceeded):
            reserve_request_budget(self.spec, account_api_key="account-a", now=120.0)
        reserve_request_budget(self.spec, account_api_key="account-b", now=120.0)
        deposit = classify_request(
            method="GET",
            path="/sapi/v1/capital/deposit/hisrec",
            base_url="https://api.binance.com",
        )
        with self.assertRaises(RequestBudgetExceeded):
            reserve_request_budget(deposit, account_api_key="account-b", now=120.0)
