import json
from contextlib import contextmanager
from datetime import datetime, timedelta
from decimal import Decimal
from unittest.mock import Mock, patch
from urllib.parse import parse_qs, urlsplit
from zoneinfo import ZoneInfo

from django.core.cache import cache
from django.test import TestCase
from rest_framework.test import APIClient

from accounts.models import TransferHistoryRecord, TransferHistorySyncState
from accounts.transfer_history import TRANSFER_HISTORY_START, build_transfer_history, sync_transfer_history_for_user
from api_bindings.models import ApiBinding
from api_bindings.services import build_api_key_fingerprint
from common.binance import BinanceApiError, _HttpResponseData
from common.binance_rate_limit import _clear_local_budget_state
from common.utils import aes_encrypt
from users.models import User

NOW = datetime(2026, 10, 1, 3, tzinfo=ZoneInfo("Asia/Shanghai"))
RECEIVED_AT = datetime(2026, 9, 30, 11, 23, 10, 208000, tzinfo=ZoneInfo("Asia/Shanghai"))


def pay_row(transaction_id="synthetic-c2c-receipt", amount="600", **overrides):
    return {
        "transactionId": transaction_id, "transactionTime": int(RECEIVED_AT.timestamp() * 1000),
        "amount": amount, "currency": "USDT", "walletType": 1, "orderType": "C2C",
        **overrides,
    }


class PayTransferHistoryTests(TestCase):
    def setUp(self):
        cache.clear()
        _clear_local_budget_state()
        self.user = User.objects.create_user(email="pay-history@example.test", password="test")
        self.binding = ApiBinding.objects.create(
            user=self.user, api_key=aes_encrypt("synthetic-pay-key"), secret_key=aes_encrypt("synthetic-secret"),
            passphrase=aes_encrypt(""), api_key_fingerprint=build_api_key_fingerprint("synthetic-pay-key"),
            alias="test", status=1,
        )
        self.api = APIClient()
        self.api.force_authenticate(self.user)
        network = patch("common.binance._perform_http_request", side_effect=AssertionError("No real exchange requests in tests"))
        network.start()
        self.addCleanup(network.stop)

    @contextmanager
    def exchange(self, account_type="master"):
        client = Mock()
        client.get_deposit_history.return_value = []
        client.get_withdraw_history.return_value = []
        client.get_sub_account_transfer_history.return_value = []
        client.get_pay_transactions.return_value = []
        with patch("accounts.transfer_history.BinanceFuturesClient", return_value=client), patch(
            "accounts.transfer_history.account_type_for_client", return_value=account_type,
        ):
            yield client

    def test_uid_receipt_600_is_persisted_and_shown_by_actual_history_api(self):
        with self.exchange() as client:
            client.get_pay_transactions.return_value = [pay_row()]
            response = self.api.post("/v1/account/transfer-history/sync", {}, format="json")
            self.assertEqual(response.status_code, 200, response.data)
            data = response.data["data"]
            self.assertEqual(Decimal(data["incoming_total"]), Decimal("600"))
            self.assertEqual(len(data["records"]), 1)
            self.assertEqual(data["records"][0]["route"], "币安账户 -> 资金")
            self.assertEqual(data["records"][0]["channel"], "币安站内转账")
            self.assertTrue(TransferHistoryRecord.objects.get().record_id.startswith("pay-"))
            self.api.post("/v1/account/transfer-history/sync", {}, format="json")
        self.assertEqual(TransferHistoryRecord.objects.count(), 1)
        with patch("accounts.transfer_history.BinanceFuturesClient", side_effect=AssertionError("History GET only reads DB")):
            displayed = self.api.get("/v1/account/transfer-history")
        self.assertEqual(Decimal(displayed.data["data"]["incoming_total"]), Decimal("600"))

    def test_pay_receipts_and_expenditures_use_signed_decimal_for_both_account_types(self):
        for account_type in ("master", "sub"):
            with self.subTest(account_type=account_type), self.exchange(account_type) as client:
                client.get_pay_transactions.return_value = [
                    pay_row("received", ".10000001"), pay_row("sent", "-.02000001", walletType=2),
                    pay_row("wrong-asset", "999", currency="BTC"), pay_row("zero", "0"),
                    pay_row("invalid", "NaN"), pay_row("missing-id", "5", transactionId=""),
                    pay_row("future", "50", transactionTime=int((NOW + timedelta(days=1)).timestamp() * 1000)),
                ]
                result = build_transfer_history(self.user, now=NOW)
            self.assertEqual(result["incoming_total"], "0.10000001")
            self.assertEqual(result["outgoing_total"], "0.02000001")
            self.assertEqual({row["route"] for row in result["records"]}, {"币安账户 -> 资金", "现货 -> 币安账户"})

    def test_history_api_accepts_actual_pay_http_contract_and_persists_600(self):
        def fake_http(*, method, url, **kwargs):
            self.assertEqual(method, "GET")
            path = urlsplit(url).path
            if path == "/sapi/v1/pay/transactions":
                payload = {"code": "000000", "success": True, "data": [pay_row()]}
            elif path in {"/sapi/v1/capital/deposit/hisrec", "/sapi/v1/capital/withdraw/history"}:
                payload = []
            else:
                raise AssertionError("Unexpected exchange endpoint in history sync")
            return _HttpResponseData(status_code=200, payload_text=json.dumps(payload), headers={})

        with patch("common.binance._perform_http_request", side_effect=fake_http), patch(
            "accounts.transfer_history.account_type_for_client", return_value="master",
        ):
            response = self.api.post("/v1/account/transfer-history/sync", {}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(Decimal(response.data["data"]["incoming_total"]), Decimal("600"))
        self.assertEqual(TransferHistoryRecord.objects.get().amount, Decimal("600"))

    def test_pay_source_failure_preserves_success_cursor_and_old_records(self):
        prior = NOW - timedelta(days=1)
        state = TransferHistorySyncState.objects.create(
            user=self.user, api_key_fingerprint=self.binding.api_key_fingerprint, source_version=1,
            synced_through=prior, last_synced_at=prior,
        )
        old = TransferHistoryRecord.objects.create(
            user=self.user, api_key_fingerprint=self.binding.api_key_fingerprint,
            record_id="existing", direction="incoming", amount=Decimal("10"),
            occurred_at=prior, account_type="master", asset="USDT", route="外部账户 -> 资金",
        )
        with self.exchange() as client:
            client.get_deposit_history.return_value = [{
                "id": "not-committed", "coin": "USDT", "amount": "99", "status": 1,
                "walletType": 1, "insertTime": int(RECEIVED_AT.timestamp() * 1000),
            }]
            client.get_pay_transactions.side_effect = BinanceApiError("synthetic Pay failure")
            with self.assertRaises(BinanceApiError):
                sync_transfer_history_for_user(self.user, now=NOW)
        state.refresh_from_db()
        self.assertEqual(state.synced_through, prior)
        self.assertEqual(state.source_version, 1)
        self.assertEqual(TransferHistoryRecord.objects.count(), 1)
        self.assertEqual(TransferHistoryRecord.objects.get().pk, old.pk)

    def test_source_upgrade_backfills_old_pay_receipt(self):
        prior = NOW - timedelta(days=1)
        state = TransferHistorySyncState.objects.create(
            user=self.user, api_key_fingerprint=self.binding.api_key_fingerprint, source_version=1,
            synced_through=prior, last_synced_at=prior,
        )
        old_time = TRANSFER_HISTORY_START + timedelta(days=1)
        old = pay_row("old-receipt", "12.50", transactionTime=int(old_time.timestamp() * 1000))
        with self.exchange() as client:
            client.get_pay_transactions.side_effect = lambda **kw: [old] if kw["start_time_ms"] <= old["transactionTime"] <= kw["end_time_ms"] else []
            sync_transfer_history_for_user(self.user, now=NOW)
            self.assertEqual(client.get_pay_transactions.call_args.kwargs["start_time_ms"], int(TRANSFER_HISTORY_START.timestamp() * 1000))
        self.assertEqual(TransferHistoryRecord.objects.get().amount, Decimal("12.50"))
        state.refresh_from_db()
        self.assertEqual(state.source_version, 2)

    def test_full_pay_page_is_split_without_boundary_loss(self):
        start = int(RECEIVED_AT.timestamp() * 1000)
        rows = [pay_row(str(index), "1", transactionTime=start + index) for index in range(101)]

        def fake_http(*, method, url, **kwargs):
            self.assertEqual(method, "GET")
            parsed = urlsplit(url)
            if parsed.path == "/sapi/v1/pay/transactions":
                query = parse_qs(parsed.query)
                left, right = int(query["startTime"][0]), int(query["endTime"][0])
                page = [row for row in rows if left <= row["transactionTime"] <= right][:100]
                payload = {"code": "000000", "success": True, "data": page}
            elif parsed.path in {"/sapi/v1/capital/deposit/hisrec", "/sapi/v1/capital/withdraw/history"}:
                payload = []
            else:
                raise AssertionError("Unexpected exchange endpoint in history sync")
            return _HttpResponseData(status_code=200, payload_text=json.dumps(payload), headers={})

        with patch("common.binance._perform_http_request", side_effect=fake_http), patch(
            "accounts.transfer_history.account_type_for_client", return_value="master",
        ):
            result = build_transfer_history(self.user, start_at=RECEIVED_AT, now=RECEIVED_AT + timedelta(milliseconds=100))
        self.assertEqual(len(result["records"]), 101)
        self.assertEqual(result["incoming_total"], "101")

    def test_full_pay_page_at_one_timestamp_fails_without_advancing_cursor(self):
        point = int(RECEIVED_AT.timestamp() * 1000)
        with self.exchange() as client:
            client.get_pay_transactions.return_value = [pay_row(str(index), "1", transactionTime=point) for index in range(100)]
            with self.assertRaises(BinanceApiError):
                build_transfer_history(self.user, start_at=RECEIVED_AT, now=RECEIVED_AT)
