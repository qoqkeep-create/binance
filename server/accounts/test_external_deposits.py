from contextlib import contextmanager
from datetime import datetime, timedelta
from decimal import Decimal
from unittest.mock import Mock, patch
from zoneinfo import ZoneInfo

from django.core.cache import cache
from django.test import TestCase

from accounts.models import TransferHistoryRecord, TransferHistorySyncState
from accounts.transfer_history import (
    TRANSFER_HISTORY_START,
    build_transfer_history,
    get_cached_transfer_history,
    sync_transfer_history_for_user,
)
from api_bindings.models import ApiBinding
from api_bindings.services import build_api_key_fingerprint
from common.binance import BinanceApiError, BinanceCredentials, BinanceFuturesClient
from common.utils import aes_encrypt
from users.models import User


NOW = datetime(2026, 9, 30, 12, tzinfo=ZoneInfo("Asia/Shanghai"))


def deposit(record_id="deposit", amount="10", **overrides):
    return {
        "id": record_id, "coin": "USDT", "amount": amount, "status": 1,
        "walletType": 1, "transferType": 0, "network": "TRX",
        "insertTime": int((NOW - timedelta(hours=1)).timestamp() * 1000),
        **overrides,
    }


def sub_transfer(record_id, direction, amount):
    return {
        "tranId": record_id, "type": direction, "asset": "USDT", "qty": amount,
        "status": "SUCCESS", "counterParty": "master", "fromAccountType": "SPOT",
        "toAccountType": "FUNDING", "time": int((NOW - timedelta(hours=2)).timestamp() * 1000),
    }


class ExternalDepositHistoryTests(TestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(email="external-deposit@example.com", password="test-password")
        self.binding = self.bind("test-external-deposit-key")
        self.no_network = patch("common.binance._perform_http_request", side_effect=AssertionError("Private network is forbidden in tests"))
        self.no_network.start()
        self.addCleanup(self.no_network.stop)

    def bind(self, key):
        return ApiBinding.objects.create(
            user=self.user, api_key=aes_encrypt(key), secret_key=aes_encrypt("test-secret"),
            passphrase=aes_encrypt(""), api_key_fingerprint=build_api_key_fingerprint(key), status=1,
        )

    @contextmanager
    def exchange(self, account_type="master"):
        client = Mock(spec=BinanceFuturesClient)
        client.get_deposit_history.return_value = []
        client.get_withdraw_history.return_value = []
        client.get_sub_account_transfer_history.return_value = []
        client.get_pay_transactions.return_value = []
        with patch("accounts.transfer_history.BinanceFuturesClient", return_value=client), patch(
            "accounts.transfer_history.account_type_for_client", return_value=account_type,
        ):
            yield client

    def build(self):
        return build_transfer_history(self.user, now=NOW, credentials=BinanceCredentials("test", "test"))

    def legacy_state(self):
        previous = NOW - timedelta(days=1)
        state, _ = TransferHistorySyncState.objects.update_or_create(
            user=self.user, api_key_fingerprint=self.binding.api_key_fingerprint,
            defaults={"source_version": 0, "synced_through": previous, "last_synced_at": previous},
        )
        return state, previous

    def assert_failed_state_unchanged(self, state, previous):
        state.refresh_from_db()
        self.assertEqual(state.source_version, 0)
        self.assertEqual(state.synced_through, previous)
        self.assertEqual(state.last_synced_at, previous)
        self.assertTrue(state.last_error)

    def test_master_includes_funding_spot_and_unknown_wallet_deposits_and_preserves_withdrawals(self):
        missing_wallet = deposit("missing", ".30")
        missing_wallet.pop("walletType")
        with self.exchange() as client:
            client.get_deposit_history.return_value = [
                deposit("funding", "100.10", transferType=1),
                deposit("spot", ".20", walletType=0), missing_wallet,
                deposit("unknown", ".40", walletType=999),
            ]
            client.get_withdraw_history.return_value = [{
                "id": "withdrawal", "coin": "USDT", "amount": "50", "status": 6,
                "walletType": 0, "network": "TRX", "applyTime": NOW.isoformat(),
            }]
            result = self.build()

        self.assertEqual(Decimal(result["incoming_total"]), Decimal("101"))
        self.assertEqual(Decimal(result["outgoing_total"]), Decimal("50"))
        self.assertEqual(Decimal(result["net_amount"]), Decimal("-51"))
        routes = [(row["route"], row["channel"]) for row in result["records"]]
        self.assertIn(("币安账户 -> 资金", "币安站内转账"), routes)
        self.assertIn(("外部账户 -> 现货", "TRX充值"), routes)
        self.assertEqual(routes.count(("外部账户 -> 账户", "TRX充值")), 2)
        self.assertIn(("现货 -> 外部账户", "TRX转出"), routes)
        self.assertEqual(client.get_deposit_history.call_args.kwargs["status"], 1)
        client.get_sub_account_transfer_history.assert_not_called()

    def test_sub_account_external_deposit_coexists_with_parent_transfers(self):
        with self.exchange("sub") as client:
            client.get_deposit_history.return_value = [deposit(amount="2.05")]
            client.get_sub_account_transfer_history.side_effect = lambda **kw: [
                sub_transfer("from-parent", 1, "12.50") if kw["transfer_type"] == 1
                else sub_transfer("to-parent", 2, "3.20")
            ]
            result = self.build()

        self.assertEqual(Decimal(result["incoming_total"]), Decimal("14.55"))
        self.assertEqual(Decimal(result["outgoing_total"]), Decimal("3.20"))
        self.assertEqual(Decimal(result["net_amount"]), Decimal("-11.35"))
        self.assertEqual(len(result["records"]), 3)
        self.assertEqual({row["route"] for row in result["records"]}, {
            "外部账户 -> 资金", "所属主账户 -> 资金", "现货 -> 所属主账户",
        })
        client.get_withdraw_history.assert_not_called()
        client.get_deposit_history.assert_called_once()
        self.assertEqual({call.kwargs["transfer_type"] for call in client.get_sub_account_transfer_history.call_args_list}, {1, 2})

    def test_only_completed_usdt_deposits_count_for_both_account_types(self):
        for account_type in ("master", "sub"):
            with self.subTest(account_type=account_type), self.exchange(account_type) as client:
                client.get_deposit_history.return_value = [
                    deposit("completed", "0.25", status="1"),
                    *[deposit(f"status-{status}", "1000", status=status) for status in (0, 2, 6, 7, 8, None, "SUCCESS")],
                    deposit("wrong-coin", "1000", coin="BTC"),
                    deposit("invalid-amount", "NaN"), deposit("negative-amount", "-5"),
                    deposit("future", "1000", insertTime=int((NOW + timedelta(days=1)).timestamp() * 1000)),
                ]
                result = self.build()
            self.assertEqual(len(result["records"]), 1)
            self.assertEqual(Decimal(result["incoming_total"]), Decimal("0.25"))

    def test_duplicate_exchange_id_deduplicates_without_losing_decimal_precision(self):
        first = deposit("first", "0.100000000000000001")
        second = deposit("second", "0.200000000000000002")
        with self.exchange() as client:
            client.get_deposit_history.return_value = [first, second, dict(first)]
            result = self.build()
            client.get_deposit_history.return_value = [second, first]
            reordered = self.build()
        self.assertEqual(len(result["records"]), 2)
        self.assertEqual(result["incoming_total"], "0.300000000000000003")
        self.assertEqual({row["id"] for row in result["records"]}, {row["id"] for row in reordered["records"]})

    def test_repeated_actual_source_sync_is_idempotent_and_cached_totals_are_decimal(self):
        with self.exchange() as client:
            client.get_deposit_history.return_value = [deposit("a", ".1"), deposit("b", ".2"), deposit("a", ".1")]
            sync_transfer_history_for_user(self.user, now=NOW)
            ids = set(TransferHistoryRecord.objects.values_list("pk", flat=True))
            sync_transfer_history_for_user(self.user, now=NOW + timedelta(hours=1))
        self.assertEqual(set(TransferHistoryRecord.objects.values_list("pk", flat=True)), ids)
        self.assertEqual(len(ids), 2)
        self.assertEqual(sum(TransferHistoryRecord.objects.values_list("amount", flat=True), Decimal("0")), Decimal(".3"))
        with patch("accounts.transfer_history.BinanceFuturesClient", side_effect=AssertionError("Cached reads must not construct an exchange client")):
            cached = get_cached_transfer_history(self.user)
        self.assertEqual(cached["incoming_total"], "0.3")
        self.assertEqual(cached["net_amount"], "-0.3")

    def test_source_upgrade_backfills_older_deposit_then_restores_three_day_overlap(self):
        state, _ = self.legacy_state()
        old_deposit = deposit("previously-missing", "12.50", insertTime=int((TRANSFER_HISTORY_START + timedelta(days=1)).timestamp() * 1000))
        with self.exchange() as client:
            client.get_deposit_history.side_effect = lambda **kw: [old_deposit] if kw["start_time_ms"] <= old_deposit["insertTime"] <= kw["end_time_ms"] else []
            sync_transfer_history_for_user(self.user, now=NOW)
            self.assertEqual(client.get_deposit_history.call_args.kwargs["start_time_ms"], int(TRANSFER_HISTORY_START.timestamp() * 1000))
            state.refresh_from_db()
            self.assertEqual(state.source_version, 2)
            self.assertEqual(state.synced_through, NOW)
            self.assertEqual(TransferHistoryRecord.objects.get().amount, Decimal("12.50"))
            client.get_deposit_history.reset_mock()
            result = sync_transfer_history_for_user(self.user, now=NOW + timedelta(days=1))
            self.assertEqual(client.get_deposit_history.call_args.kwargs["start_time_ms"], int((NOW - timedelta(days=3)).timestamp() * 1000))
        self.assertEqual(result["stored_records"], 0)
        self.assertEqual(TransferHistoryRecord.objects.count(), 1)

    def test_master_withdrawal_source_failure_does_not_partially_write_new_deposits(self):
        with self.exchange() as client:
            client.get_deposit_history.return_value = [deposit("existing", "10")]
            sync_transfer_history_for_user(self.user, now=NOW - timedelta(minutes=10))
            state, previous = self.legacy_state()
            client.get_deposit_history.return_value = [deposit("existing", "999"), deposit("new", "20")]
            client.get_withdraw_history.side_effect = BinanceApiError("withdrawal history unavailable")
            with self.assertRaises(BinanceApiError):
                sync_transfer_history_for_user(self.user, now=NOW)
        self.assert_failed_state_unchanged(state, previous)
        self.assertEqual(TransferHistoryRecord.objects.count(), 1)
        self.assertEqual(TransferHistoryRecord.objects.get().amount, Decimal("10"))

    def test_sub_deposit_failure_does_not_commit_partial_parent_transfer_history(self):
        with self.exchange("sub") as client:
            client.get_sub_account_transfer_history.side_effect = lambda **kw: [sub_transfer("existing", 1, "10")] if kw["transfer_type"] == 1 else []
            sync_transfer_history_for_user(self.user, now=NOW - timedelta(minutes=10))
            state, previous = self.legacy_state()
            client.get_sub_account_transfer_history.side_effect = lambda **kw: [sub_transfer("new", 1, "999")] if kw["transfer_type"] == 1 else []
            client.get_deposit_history.side_effect = BinanceApiError("deposit history unavailable")
            with self.assertRaises(BinanceApiError):
                sync_transfer_history_for_user(self.user, now=NOW)
        self.assert_failed_state_unchanged(state, previous)
        self.assertEqual(TransferHistoryRecord.objects.count(), 1)
        self.assertEqual(TransferHistoryRecord.objects.get().amount, Decimal("10"))

    def test_binding_replacement_during_deposit_read_cannot_write_or_advance_old_state(self):
        state, previous = self.legacy_state()
        old_fingerprint = self.binding.api_key_fingerprint

        def replace_binding(**kwargs):
            self.binding.delete()
            self.binding = self.bind("replacement-deposit-key")
            return [deposit("belongs-to-old-key", "99")]

        with self.exchange() as client:
            client.get_deposit_history.side_effect = replace_binding
            with self.assertRaisesMessage(BinanceApiError, "绑定已发生变化"):
                sync_transfer_history_for_user(self.user, now=NOW)
        self.assert_failed_state_unchanged(state, previous)
        self.assertEqual(state.api_key_fingerprint, old_fingerprint)
        self.assertFalse(TransferHistoryRecord.objects.exists())
        self.assertEqual(get_cached_transfer_history(self.user)["records"], [])
        self.assertFalse(TransferHistorySyncState.objects.filter(api_key_fingerprint=self.binding.api_key_fingerprint).exists())

    def test_cached_deposits_are_scoped_to_user_and_current_key(self):
        with self.exchange() as client:
            client.get_deposit_history.return_value = [deposit("same-exchange-id", "1.25")]
            sync_transfer_history_for_user(self.user, now=NOW)
        current = TransferHistoryRecord.objects.get()
        other_user = User.objects.create_user(email="another-deposit@example.com", password="test-password")
        for user_id, fingerprint in ((self.user.pk, "old-fingerprint"), (other_user.pk, self.binding.api_key_fingerprint)):
            TransferHistoryRecord.objects.create(
                user_id=user_id, api_key_fingerprint=fingerprint, account_type="master",
                record_id=current.record_id, direction="incoming", amount=Decimal("999"),
                occurred_at=NOW, route="外部账户 -> 资金", channel="TRX充值",
            )
        with patch("accounts.transfer_history.BinanceFuturesClient", side_effect=AssertionError("Cached reads cannot query Binance")):
            result = get_cached_transfer_history(self.user)
        self.assertEqual(result["incoming_total"], "1.25")
        self.assertEqual(result["pagination"]["total"], 1)
