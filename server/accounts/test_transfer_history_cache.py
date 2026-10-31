from contextlib import contextmanager
from datetime import datetime, timedelta
from decimal import Decimal
from io import StringIO
from unittest.mock import patch
from zoneinfo import ZoneInfo

from django.core.management import call_command
from django.test import SimpleTestCase
from rest_framework import status
from rest_framework.test import APITestCase

from accounts.models import TransferHistoryRecord, TransferHistorySyncState
from accounts.transfer_history import (
    TRANSFER_HISTORY_SOURCE_VERSION,
    TRANSFER_HISTORY_START,
    get_cached_transfer_history,
    sync_all_transfer_histories,
    sync_transfer_history_for_user,
)
from api_bindings.models import ApiBinding
from api_bindings.services import build_api_key_fingerprint
from common.binance import BinanceApiError
from common.utils import aes_encrypt
from users.models import User


SHANGHAI = ZoneInfo("Asia/Shanghai")
NOW = datetime(2026, 9, 4, 12, 0, tzinfo=SHANGHAI)


def _create_binding(user, api_key="k" * 24):
    return ApiBinding.objects.create(
        user=user,
        api_key=aes_encrypt(api_key),
        api_key_fingerprint=build_api_key_fingerprint(api_key),
        secret_key=aes_encrypt("s" * 24),
        passphrase=aes_encrypt(""),
        alias="测试账户",
        status=1,
    )


def _history_payload(*, amount="100", record_id="sub-1", account_type="sub"):
    return {
        "start_at": TRANSFER_HISTORY_START.isoformat(),
        "account_type": account_type,
        "outgoing_total": amount,
        "incoming_total": "0",
        "net_amount": amount,
        "records": [
            {
                "id": record_id,
                "direction": "outgoing",
                "amount": amount,
                "asset": "USDT",
                "occurred_at": datetime(2026, 9, 3, 8, 30, tzinfo=SHANGHAI).isoformat(),
                "route": "现货 -> 所属主账户",
                "channel": "币安账户划转",
            }
        ],
    }


class TransferHistoryCacheTests(APITestCase):
    def setUp(self):
        self.user = User.objects.create_user(email="cache@example.com", password="123456")
        self.binding = _create_binding(self.user)
        self.fingerprint = self.binding.api_key_fingerprint

    @patch("accounts.transfer_history.build_transfer_history")
    def test_first_sync_backfills_from_configured_start_and_persists(self, mock_build):
        mock_build.return_value = _history_payload()

        result = sync_transfer_history_for_user(self.user, now=NOW)

        self.assertEqual(result["stored_records"], 1)
        self.assertEqual(mock_build.call_args.kwargs["start_at"], TRANSFER_HISTORY_START)
        self.assertEqual(mock_build.call_args.kwargs["now"], NOW)
        record = TransferHistoryRecord.objects.get()
        self.assertEqual(record.api_key_fingerprint, self.fingerprint)
        self.assertEqual(record.amount, Decimal("100"))
        state = TransferHistorySyncState.objects.get()
        self.assertEqual(state.synced_through, NOW)
        self.assertEqual(state.last_synced_at, NOW)
        self.assertEqual(state.last_error, "")

    @patch("accounts.transfer_history.build_transfer_history")
    def test_incremental_sync_rechecks_three_day_overlap(self, mock_build):
        previous = NOW - timedelta(days=1)
        TransferHistorySyncState.objects.create(
            user=self.user,
            api_key_fingerprint=self.fingerprint,
            account_type="sub",
            source_version=TRANSFER_HISTORY_SOURCE_VERSION,
            synced_through=previous,
            last_synced_at=previous,
        )
        mock_build.return_value = _history_payload()

        sync_transfer_history_for_user(self.user, now=NOW)

        self.assertEqual(
            mock_build.call_args.kwargs["start_at"],
            previous - timedelta(days=3),
        )

    @patch("accounts.transfer_history.build_transfer_history")
    def test_repeated_sync_updates_same_record_without_duplicate(self, mock_build):
        mock_build.return_value = _history_payload(amount="100")
        sync_transfer_history_for_user(self.user, now=NOW)
        mock_build.return_value = _history_payload(amount="99.99")

        sync_transfer_history_for_user(self.user, now=NOW + timedelta(days=1))

        self.assertEqual(TransferHistoryRecord.objects.count(), 1)
        self.assertEqual(TransferHistoryRecord.objects.get().amount, Decimal("99.99"))

    @patch("accounts.transfer_history.build_transfer_history")
    def test_failed_sync_keeps_success_cursor_and_records_error(self, mock_build):
        previous = NOW - timedelta(days=1)
        state = TransferHistorySyncState.objects.create(
            user=self.user,
            api_key_fingerprint=self.fingerprint,
            account_type="sub",
            synced_through=previous,
            last_synced_at=previous,
        )
        mock_build.side_effect = BinanceApiError("Binance timeout")

        with self.assertRaises(BinanceApiError):
            sync_transfer_history_for_user(self.user, now=NOW)

        state.refresh_from_db()
        self.assertEqual(state.synced_through, previous)
        self.assertEqual(state.last_synced_at, previous)
        self.assertEqual(state.last_error, "Binance timeout")

    @patch("accounts.transfer_history.build_transfer_history")
    def test_binding_change_during_sync_does_not_write_exchange_rows(self, mock_build):
        def replace_binding_during_query(*_args, **_kwargs):
            self.binding.delete()
            return _history_payload()

        mock_build.side_effect = replace_binding_during_query

        with self.assertRaisesMessage(BinanceApiError, "绑定已发生变化"):
            sync_transfer_history_for_user(self.user, now=NOW)

        self.assertFalse(TransferHistoryRecord.objects.exists())
        state = TransferHistorySyncState.objects.get(
            user=self.user,
            api_key_fingerprint=self.fingerprint,
        )
        self.assertIsNone(state.synced_through)
        self.assertIsNone(state.last_synced_at)
        self.assertIn("绑定已发生变化", state.last_error)

    @patch("accounts.transfer_history.build_transfer_history")
    @patch("accounts.transfer_history.distributed_cache_lock")
    def test_busy_distributed_lock_stops_sync_before_exchange_query(
        self,
        mock_lock,
        mock_build,
    ):
        @contextmanager
        def busy_lock(_key, *, timeout):
            self.assertEqual(timeout, 120)
            yield False

        mock_lock.side_effect = busy_lock

        with self.assertRaisesMessage(BinanceApiError, "正在同步"):
            sync_transfer_history_for_user(self.user, now=NOW)

        mock_build.assert_not_called()

    def test_cache_is_scoped_to_current_api_key(self):
        TransferHistoryRecord.objects.create(
            user=self.user,
            api_key_fingerprint="old-fingerprint",
            account_type="sub",
            record_id="old-record",
            direction="outgoing",
            amount=Decimal("20"),
            asset="USDT",
            occurred_at=NOW,
            route="现货 -> 所属主账户",
            channel="币安账户划转",
        )

        payload = get_cached_transfer_history(self.user)

        self.assertEqual(payload["records"], [])
        self.assertEqual(payload["outgoing_total"], "0")
        self.assertEqual(payload["sync_status"], "pending")

    def test_same_api_key_rebinding_can_reuse_cached_history(self):
        TransferHistoryRecord.objects.create(
            user=self.user,
            api_key_fingerprint=self.fingerprint,
            account_type="sub",
            record_id="same-key-record",
            direction="incoming",
            amount=Decimal("12.5"),
            asset="USDT",
            occurred_at=NOW,
            route="所属主账户 -> 资金",
            channel="币安账户划转",
        )
        self.binding.delete()
        _create_binding(self.user)

        payload = get_cached_transfer_history(self.user)

        self.assertEqual(len(payload["records"]), 1)
        self.assertEqual(payload["incoming_total"], "12.5")
        self.assertEqual(payload["account_type"], "sub")

    def test_cache_paginates_records_but_aggregates_all_rows(self):
        TransferHistoryRecord.objects.bulk_create(
            [
                TransferHistoryRecord(
                    user=self.user,
                    api_key_fingerprint=self.fingerprint,
                    account_type="sub",
                    record_id=f"record-{index:02d}",
                    direction="outgoing" if index < 15 else "incoming",
                    amount=Decimal("1"),
                    asset="USDT",
                    occurred_at=NOW - timedelta(minutes=index),
                    route="现货 -> 所属主账户",
                    channel="币安账户划转",
                )
                for index in range(25)
            ]
        )

        payload = get_cached_transfer_history(self.user, page=2, page_size=10)

        self.assertEqual(payload["outgoing_total"], "15")
        self.assertEqual(payload["incoming_total"], "10")
        self.assertEqual(payload["net_amount"], "5")
        self.assertEqual(len(payload["records"]), 10)
        self.assertEqual(
            payload["pagination"],
            {
                "page": 2,
                "page_size": 10,
                "total": 25,
                "total_pages": 3,
                "has_next": True,
            },
        )

class TransferHistoryApiCacheTests(APITestCase):
    URL = "/v1/account/transfer-history"
    SYNC_URL = "/v1/account/transfer-history/sync"

    def setUp(self):
        self.user = User.objects.create_user(email="cache-api@example.com", password="123456")
        binding = _create_binding(self.user)
        TransferHistoryRecord.objects.create(
            user=self.user,
            api_key_fingerprint=binding.api_key_fingerprint,
            account_type="master",
            record_id="deposit-1",
            direction="incoming",
            amount=Decimal("45"),
            asset="USDT",
            occurred_at=NOW,
            route="币安账户 -> 现货",
            channel="币安站内转账",
        )
        TransferHistorySyncState.objects.create(
            user=self.user,
            api_key_fingerprint=binding.api_key_fingerprint,
            account_type="master",
            synced_through=NOW,
            last_synced_at=NOW,
        )
        login = self.client.post(
            "/v1/auth/login",
            {"email": self.user.email, "password": "123456", "agreed": True},
            format="json",
        )
        self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {login.data['data']['token']}")

    @patch("accounts.transfer_history.BinanceFuturesClient")
    def test_api_reads_database_without_constructing_binance_client(self, mock_client):
        response = self.client.get(self.URL)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["data"]["incoming_total"], "45")
        self.assertEqual(response.data["data"]["sync_status"], "ready")
        self.assertEqual(len(response.data["data"]["records"]), 1)
        mock_client.assert_not_called()

    @patch("accounts.views.get_cached_transfer_history")
    @patch("accounts.views.sync_transfer_history_for_user")
    def test_manual_sync_updates_current_user_then_returns_cache(
        self, mock_sync, mock_cached
    ):
        mock_sync.return_value = {"stored_records": 1}
        mock_cached.return_value = {
            "start_at": TRANSFER_HISTORY_START.isoformat(),
            "account_type": "master",
            "outgoing_total": "0",
            "incoming_total": "45",
            "net_amount": "-45",
            "last_synced_at": NOW.isoformat(),
            "sync_status": "ready",
            "records": [],
        }

        response = self.client.post(self.SYNC_URL, {}, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["data"]["sync_status"], "ready")
        mock_sync.assert_called_once_with(self.user)
        mock_cached.assert_called_once_with(self.user, page=1, page_size=20)

    @patch("accounts.views.get_cached_transfer_history")
    @patch(
        "accounts.views.sync_transfer_history_for_user",
        side_effect=BinanceApiError("Binance timeout"),
    )
    def test_manual_sync_error_does_not_fall_back_to_a_live_read(
        self, _mock_sync, mock_cached
    ):
        response = self.client.post(self.SYNC_URL, {}, format="json")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["message"], "Binance timeout")
        mock_cached.assert_not_called()

    @patch("accounts.views.sync_transfer_history_for_user")
    def test_cached_get_never_starts_manual_sync(self, mock_sync):
        response = self.client.get(self.URL)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        mock_sync.assert_not_called()


class TransferHistoryBatchSyncTests(APITestCase):
    @patch("accounts.transfer_history.sync_transfer_history_for_user")
    def test_one_user_failure_does_not_stop_other_users(self, mock_sync):
        first = User.objects.create_user(email="batch-1@example.com", password="123456")
        second = User.objects.create_user(email="batch-2@example.com", password="123456")
        _create_binding(first, "a" * 24)
        _create_binding(second, "b" * 24)
        mock_sync.side_effect = [BinanceApiError("bad key"), {"stored_records": 2}]

        result = sync_all_transfer_histories(now=NOW)

        self.assertEqual(result, {"attempted": 2, "synced": 1, "failed": 1, "stored_records": 2})
        self.assertEqual(mock_sync.call_count, 2)

    @patch("accounts.transfer_history.logger.exception")
    @patch("accounts.transfer_history.sync_transfer_history_for_user")
    def test_shared_rate_limit_stops_remaining_accounts(self, mock_sync, mock_exception_log):
        first = User.objects.create_user(email="rate-batch-1@example.com", password="123456")
        second = User.objects.create_user(email="rate-batch-2@example.com", password="123456")
        _create_binding(first, "c" * 24)
        _create_binding(second, "d" * 24)
        mock_sync.side_effect = BinanceApiError(
            "Binance 请求预算保护中",
            code="LOCAL_RATE_BUDGET",
        )

        result = sync_all_transfer_histories(now=NOW)

        self.assertEqual(result, {"attempted": 1, "synced": 0, "failed": 1, "stored_records": 0})
        self.assertEqual(mock_sync.call_count, 1)
        mock_exception_log.assert_not_called()


class TransferHistorySchedulerTests(SimpleTestCase):
    @patch("trading.scheduler.BackgroundScheduler")
    def test_daily_sync_is_registered_for_0010_shanghai_time(self, scheduler_cls):
        from trading import scheduler as scheduler_module

        scheduler_module._scheduler = None
        scheduler = scheduler_cls.return_value
        try:
            scheduler_module.start_scheduler()
            calls = [
                call
                for call in scheduler.add_job.call_args_list
                if call.kwargs.get("id") == "sync_transfer_history"
            ]
            self.assertEqual(len(calls), 1)
            self.assertIn("hour='0'", str(calls[0].kwargs["trigger"]))
            self.assertIn("minute='10'", str(calls[0].kwargs["trigger"]))
            self.assertEqual(str(calls[0].kwargs["trigger"].timezone), "Asia/Shanghai")
            heartbeat_calls = [
                call
                for call in scheduler.add_job.call_args_list
                if call.kwargs.get("id") == "scheduler_heartbeat"
            ]
            self.assertEqual(len(heartbeat_calls), 1)
        finally:
            scheduler_module.stop_scheduler()


class TransferHistoryCommandTests(SimpleTestCase):
    @patch("accounts.management.commands.sync_transfer_history.sync_all_transfer_histories")
    def test_management_command_reports_batch_result(self, mock_sync):
        mock_sync.return_value = {
            "attempted": 2,
            "synced": 1,
            "failed": 1,
            "stored_records": 3,
        }
        stdout = StringIO()

        call_command("sync_transfer_history", stdout=stdout)

        self.assertIn("成功 1", stdout.getvalue())
        self.assertIn("失败 1", stdout.getvalue())
