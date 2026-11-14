import json
from datetime import datetime
from unittest.mock import Mock, patch
from decimal import Decimal
from urllib.parse import unquote
from zoneinfo import ZoneInfo

from rest_framework import status
from rest_framework.test import APITestCase

from accounts.services import get_user_trade_balance, round_up_stop_loss
from accounts.transfer_history import MASTER_WINDOW_MS, _master_windows, _sub_account_rows, build_transfer_history
from accounts.views import _build_avatar_data_url
from api_bindings.models import ApiBinding
from common.binance import BinanceApiError
from common.utils import aes_encrypt
from users.models import User
from trading.models import CapitalSweep


class AccountInfoTests(APITestCase):
    def setUp(self):
        self.user = User.objects.create_user(email="account_test@example.com", password="123456")
        login_resp = self.client.post(
            "/v1/auth/login",
            {"email": "account_test@example.com", "password": "123456", "agreed": True},
            format="json",
        )
        token = login_resp.data["data"]["token"]
        self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")

    def test_account_info_without_binding(self):
        resp = self.client.get("/v1/account/info")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data["data"]["balance"], "--")
        self.assertEqual(resp.data["data"]["spot_balance"], "--")
        self.assertEqual(resp.data["data"]["funding_balance"], "--")
        self.assertEqual(resp.data["data"]["today_pnl"], "--")
        self.assertEqual(resp.data["data"]["stop_loss_amount"], "120.00")

    @patch("accounts.views.BinanceFuturesClient")
    @patch("accounts.views.get_usdt_equity_snapshot", return_value=("1000", "1000"))
    @patch("accounts.views.get_user_binance_credentials", return_value=object())
    def test_pending_collection_keeps_result_check_available_even_with_clean_wallets(self, _creds, _equity, client):
        client.return_value.get_spot_usdt_balance.return_value = "0"
        client.return_value.get_funding_usdt_balance.return_value = "0"
        sweep = CapitalSweep.objects.create(
            user=self.user, amount=Decimal("100"), target_balance=Decimal("1000"),
            status=CapitalSweep.STATUS_SPOT_PENDING,
        )
        self.assertTrue(self.client.get("/v1/account/info").data["data"]["pending_capital_collection"])
        sweep.status = CapitalSweep.STATUS_COMPLETED
        sweep.save()
        self.assertFalse(self.client.get("/v1/account/info").data["data"]["pending_capital_collection"])

    def test_account_profile_without_binding(self):
        resp = self.client.get("/v1/account/profile")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data["data"]["bound"], False)
        self.assertIn("avatar_url", resp.data["data"])
        self.assertIn("email_masked", resp.data["data"])

    def test_version_info_uses_deployment_version_without_running_git(self):
        with patch.dict("os.environ", {"APP_VERSION": "release-ABCDEF123456"}):
            resp = self.client.get("/v1/account/version")

        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data["data"]["version"], "abcdef123456")

    @patch("accounts.views.BinanceFuturesClient")
    @patch("accounts.views.get_usdt_equity_snapshot")
    @patch("accounts.views.get_user_binance_credentials")
    def test_account_info_with_binding(self, mock_creds, mock_equity, mock_client_cls):
        mock_creds.return_value = object()
        mock_equity.return_value = ("123.45", "125.00")
        mock_client_cls.return_value.get_spot_usdt_balance.return_value = "50.00"
        mock_client_cls.return_value.get_funding_usdt_balance.return_value = "500.25"
        resp = self.client.get("/v1/account/info")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data["data"]["balance"], "123.45")
        self.assertEqual(resp.data["data"]["total_balance"], "675.25")
        self.assertEqual(resp.data["data"]["spot_balance"], "50.00")
        self.assertEqual(resp.data["data"]["funding_balance"], "500.25")
        self.assertEqual(resp.data["data"]["today_pnl"], "--")
        mock_equity.assert_called_once_with(mock_client_cls.return_value, fresh=False)
        mock_client_cls.return_value.get_spot_usdt_balance.assert_called_once_with(fresh=False)
        mock_client_cls.return_value.get_funding_usdt_balance.assert_called_once_with(fresh=False)
        mock_client_cls.assert_called_once_with(mock_creds.return_value)

    @patch("accounts.views.BinanceFuturesClient")
    @patch("accounts.views.get_usdt_equity_snapshot", return_value=("123.45", "125.00"))
    @patch("accounts.views.get_user_binance_credentials", return_value=object())
    def test_account_info_fresh_query_bypasses_all_wallet_caches(
        self, _mock_creds, mock_equity, mock_client_cls
    ):
        mock_client_cls.return_value.get_spot_usdt_balance.return_value = "50.00"
        mock_client_cls.return_value.get_funding_usdt_balance.return_value = "500.25"

        resp = self.client.get("/v1/account/info?fresh=1")

        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        mock_equity.assert_called_once_with(mock_client_cls.return_value, fresh=True)
        mock_client_cls.return_value.get_spot_usdt_balance.assert_called_once_with(fresh=True)
        mock_client_cls.return_value.get_funding_usdt_balance.assert_called_once_with(fresh=True)

    @patch("accounts.views.BinanceFuturesClient")
    @patch("accounts.views.get_usdt_equity_snapshot", return_value=("123.45", "125.00"))
    @patch("accounts.views.get_user_binance_credentials", return_value=object())
    def test_account_info_keeps_contract_balance_when_spot_read_fails(
        self, _mock_creds, _mock_equity, mock_client_cls
    ):
        mock_client_cls.return_value.get_spot_usdt_balance.side_effect = BinanceApiError("timeout")
        mock_client_cls.return_value.get_funding_usdt_balance.return_value = "500.25"

        resp = self.client.get("/v1/account/info")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data["data"]["balance"], "123.45")
        self.assertEqual(resp.data["data"]["spot_balance"], "--")
        self.assertEqual(resp.data["data"]["total_balance"], "--")

    @patch("accounts.views.BinanceFuturesClient")
    @patch("accounts.views.get_usdt_equity_snapshot")
    @patch("accounts.views.get_user_binance_credentials", return_value=object())
    def test_account_info_stops_wallet_queries_after_shared_rate_limit(
        self,
        _mock_creds,
        mock_equity,
        mock_client_cls,
    ):
        mock_equity.side_effect = BinanceApiError(
            "Binance 请求预算保护中",
            code="LOCAL_RATE_BUDGET",
        )

        response = self.client.get("/v1/account/info")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["data"]["balance"], "--")
        mock_client_cls.return_value.get_spot_usdt_balance.assert_not_called()
        mock_client_cls.return_value.get_funding_usdt_balance.assert_not_called()

    @patch("accounts.views.BinanceFuturesClient")
    @patch("accounts.views.get_usdt_equity_snapshot", return_value=("123.45", "125.00"))
    @patch("accounts.views.get_user_binance_credentials", return_value=object())
    def test_account_info_stops_after_spot_auth_failure_but_keeps_futures_value(
        self,
        _mock_creds,
        _mock_equity,
        mock_client_cls,
    ):
        mock_client_cls.return_value.get_spot_usdt_balance.side_effect = BinanceApiError(
            "API Key permission denied",
            code="-1002",
        )

        response = self.client.get("/v1/account/info")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["data"]["balance"], "123.45")
        self.assertEqual(response.data["data"]["spot_balance"], "--")
        mock_client_cls.return_value.get_funding_usdt_balance.assert_not_called()

    @patch("accounts.views.BinanceFuturesClient")
    def test_account_profile_with_binding(self, mock_client_cls):
        ApiBinding.objects.create(
            user=self.user,
            api_key=aes_encrypt("k" * 24),
            secret_key=aes_encrypt("s" * 24),
            passphrase=aes_encrypt(""),
            alias="主账户",
            status=1,
        )
        mock_client = mock_client_cls.return_value
        mock_client.get_account_config.return_value = {
            "code": "0",
            "data": [
                {
                    "label": "Binance Futures 实盘",
                    "uid": "acc-alias-1",
                    "perm": "trade",
                    "posMode": "long_short_mode",
                }
            ],
        }

        resp = self.client.get("/v1/account/profile")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data["data"]["bound"], True)
        self.assertEqual(resp.data["data"]["display_name"], "主账户")
        self.assertNotIn("account_id", resp.data["data"])
        self.assertEqual(resp.data["data"]["permission"], "trade")
        self.assertEqual(resp.data["data"]["position_mode"], "long_short_mode")
        self.assertTrue(resp.data["data"]["avatar_url"].startswith("data:image/svg+xml"))
        self.assertNotIn("api_key", resp.data["data"])
        self.assertNotIn("api_key_masked", resp.data["data"])
        self.assertNotIn("secret_key", resp.data["data"])

    @patch("accounts.views.get_user_trade_balance")
    def test_get_stop_loss_setting(self, mock_balance):
        mock_balance.return_value = Decimal("50.74")
        resp = self.client.get("/v1/account/stop-loss")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data["data"]["current_amount"], "120.00")

    @patch("accounts.views.get_user_trade_balance")
    def test_post_stop_loss_setting(self, mock_balance):
        mock_balance.return_value = Decimal("50.74")
        resp = self.client.post("/v1/account/stop-loss", {"amount": "150"}, format="json")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertIn("message", resp.data)

    def test_stop_loss_rounds_up_to_the_next_risk_step(self):
        cases = (
            ("0.01", "1"),
            ("1.01", "2"),
            ("19.01", "20"),
            ("20.01", "25"),
            ("99.01", "100"),
            ("100.01", "110"),
        )
        for raw, expected in cases:
            with self.subTest(raw=raw):
                self.assertEqual(round_up_stop_loss(Decimal(raw)), Decimal(expected))

    @patch("accounts.views.get_user_trade_balance", return_value=Decimal("1000"))
    def test_increasing_stop_loss_takes_effect_immediately_during_testing(self, _mock_balance):
        resp = self.client.post("/v1/account/stop-loss", {"amount": "200"}, format="json")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data["message"], "止损金额已立即生效")
        self.user.refresh_from_db()
        self.assertEqual(self.user.stop_loss_amount, Decimal("200"))
        self.assertIsNone(self.user.pending_stop_loss_amount)
        self.assertIsNone(self.user.pending_stop_loss_effective_at)

    @patch("accounts.views.get_user_trade_balance")
    def test_stop_loss_update_rejects_binding_change_in_progress(self, mock_balance):
        from trading.locks import api_binding_lifecycle_lock

        with api_binding_lifecycle_lock(self.user.id) as locked:
            response = self.client.post(
                "/v1/account/stop-loss",
                {"amount": "100"},
                format="json",
            )

        self.assertTrue(locked)
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("API 绑定正在变更", response.data["message"])
        mock_balance.assert_not_called()

    @patch("accounts.views.get_user_trade_balance")
    def test_stop_loss_update_rejects_concurrent_account_mutation(self, mock_balance):
        from api_bindings.services import get_user_trading_account_identity
        from trading.locks import user_trading_activity_lock

        identity = get_user_trading_account_identity(self.user)
        with user_trading_activity_lock(identity) as locked:
            response = self.client.post(
                "/v1/account/stop-loss",
                {"amount": "100"},
                format="json",
            )

        self.assertTrue(locked)
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("资金或交易请求正在处理中", response.data["message"])
        mock_balance.assert_not_called()

    @patch("accounts.services.get_usdt_total_equity", return_value="0")
    @patch("accounts.services.BinanceFuturesClient")
    @patch("accounts.services.get_user_binance_credentials", return_value=object())
    def test_stop_loss_baseline_uses_spot_and_funding_when_futures_empty(
        self, _mock_creds, mock_client_cls, _mock_futures_total
    ):
        client = mock_client_cls.return_value
        client.get_spot_usdt_balance.return_value = "210.25"
        client.get_funding_usdt_balance.return_value = "89.75"

        self.assertEqual(get_user_trade_balance(self.user), Decimal("300.00"))
        client.get_spot_usdt_balance.assert_called_once_with("USDT", fresh=True)
        client.get_funding_usdt_balance.assert_called_once_with("USDT", fresh=True)

    @patch("accounts.services.get_usdt_total_equity", return_value="0")
    @patch("accounts.services.BinanceFuturesClient")
    @patch("accounts.services.get_user_binance_credentials", return_value=object())
    def test_stop_loss_baseline_rejects_zero_total_assets(
        self, _mock_creds, mock_client_cls, _mock_futures_total
    ):
        client = mock_client_cls.return_value
        client.get_spot_usdt_balance.return_value = "0"
        client.get_funding_usdt_balance.return_value = "0"

        with self.assertRaises(BinanceApiError):
            get_user_trade_balance(self.user)

    def test_cancel_stop_loss_setting(self):
        self.user.pending_stop_loss_amount = Decimal("150")
        self.user.pending_stop_loss_from = Decimal("120")
        self.user.save(update_fields=["pending_stop_loss_amount", "pending_stop_loss_from"])
        resp = self.client.post("/v1/account/stop-loss/cancel", {}, format="json")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)

    @patch("accounts.views.logger")
    def test_client_layout_log(self, mock_logger):
        payload = {
            "reason": "holdings-data-loaded",
            "path": "/holdings",
            "standalone": True,
            "user_agent": "test-agent",
            "metrics": {
                "innerHeight": 812,
                "visualViewportHeight": 724,
                "safeBottom": 34,
                "navHeight": 82,
            },
        }
        resp = self.client.post("/v1/account/client-layout-log", payload, format="json")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data["data"]["logged"], True)
        mock_logger.info.assert_called_once()

    def test_avatar_svg_escapes_alias_text(self):
        svg = unquote(_build_avatar_data_url("<alias", "seed").split(",", 1)[1])

        self.assertIn(">&lt;</text>", svg)
        self.assertNotIn("><</text>", svg)

    @patch("accounts.views.logger")
    def test_client_layout_log_normalizes_client_fields_to_one_line(self, mock_logger):
        response = self.client.post(
            "/v1/account/client-layout-log",
            {
                "reason": "loaded\r\nforged-entry",
                "path": "/holdings\nforged-path",
                "user_agent": "browser\twith\ncontrols",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        logged_values = mock_logger.info.call_args.args[1:]
        self.assertTrue(all("\n" not in str(value) and "\r" not in str(value) for value in logged_values))
        self.assertIn("loaded forged-entry", logged_values)

    @patch("accounts.views.logger")
    def test_client_layout_log_redacts_sensitive_metrics(self, mock_logger):
        response = self.client.post(
            "/v1/account/client-layout-log",
            {
                "metrics": {
                    "Authorization": "Bearer browser-secret",
                    "url": "https://example.test/path?token=query-secret",
                },
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        logged_values = " ".join(str(value) for value in mock_logger.info.call_args.args[1:])
        self.assertNotIn("browser-secret", logged_values)
        self.assertNotIn("query-secret", logged_values)
        self.assertIn("[redacted", logged_values)


class TransferHistoryServiceTests(APITestCase):
    SHANGHAI = ZoneInfo("Asia/Shanghai")
    NOW = datetime(2026, 9, 3, 12, 0, tzinfo=SHANGHAI)

    def setUp(self):
        self.user = User.objects.create_user(email="history_test@example.com", password="123456")

    @staticmethod
    def _ms(day: int, hour: int = 12) -> int:
        return int(datetime(2026, 9, day, hour, tzinfo=TransferHistoryServiceTests.SHANGHAI).timestamp() * 1000)

    @patch("accounts.transfer_history.account_type_for_client", return_value="sub")
    @patch("accounts.transfer_history.BinanceFuturesClient")
    @patch("accounts.transfer_history.get_user_binance_credentials", return_value=object())
    def test_sub_account_counts_only_successful_usdt_inflows_and_spot_outflows(
        self, _mock_credentials, mock_client_cls, _mock_account_type
    ):
        client = mock_client_cls.return_value
        client.get_deposit_history.return_value = []
        client.get_pay_transactions.return_value = []

        def history(**kwargs):
            if kwargs["transfer_type"] == 1:
                return [
                    {
                        "tranId": 1,
                        "type": 1,
                        "asset": "USDT",
                        "qty": "100.25",
                        "fromAccountType": "SPOT",
                        "toAccountType": "FUNDING",
                        "counterParty": "master",
                        "email": "owner@example.com",
                        "status": "SUCCESS",
                        "time": self._ms(1),
                    },
                    {"tranId": 2, "type": 1, "asset": "USDT", "qty": "99", "status": "PROCESS", "time": self._ms(2)},
                    {"tranId": 3, "type": 1, "asset": "BTC", "qty": "1", "status": "SUCCESS", "time": self._ms(2)},
                ]
            return [
                {
                    "tranId": 4,
                    "type": 2,
                    "asset": "USDT",
                    "qty": "150.75",
                    "fromAccountType": "SPOT",
                    "toAccountType": "SPOT",
                    "counterParty": "master",
                    "email": "owner@example.com",
                    "status": "SUCCESS",
                    "time": self._ms(3),
                },
                {
                    "tranId": 5,
                    "type": 2,
                    "asset": "USDT",
                    "qty": "20",
                    "fromAccountType": "USDT_FUTURE",
                    "toAccountType": "SPOT",
                    "status": "SUCCESS",
                    "time": self._ms(3),
                },
                {"tranId": 6, "type": 2, "asset": "USDT", "qty": "80", "fromAccountType": "SPOT", "status": "FAILURE", "time": self._ms(3)},
            ]

        client.get_sub_account_transfer_history.side_effect = history
        result = build_transfer_history(self.user, now=self.NOW)

        self.assertEqual(result["account_type"], "sub")
        self.assertEqual(result["outgoing_total"], "150.75")
        self.assertEqual(result["incoming_total"], "100.25")
        self.assertEqual(result["net_amount"], "50.50")
        self.assertEqual([row["direction"] for row in result["records"]], ["outgoing", "incoming"])
        self.assertEqual(result["records"][0]["route"], "现货 -> 所属主账户")
        self.assertEqual(result["records"][1]["route"], "所属主账户 -> 资金")
        serialized = json.dumps(result, ensure_ascii=False)
        self.assertNotIn("owner@example.com", serialized)
        self.assertNotIn("counterParty", serialized)

    @patch("accounts.transfer_history.account_type_for_client", return_value="master")
    @patch("accounts.transfer_history.BinanceFuturesClient")
    @patch("accounts.transfer_history.get_user_binance_credentials", return_value=object())
    def test_master_account_counts_completed_deposits_and_spot_withdrawals(
        self, _mock_credentials, mock_client_cls, _mock_account_type
    ):
        client = mock_client_cls.return_value
        client.get_pay_transactions.return_value = []
        client.get_deposit_history.return_value = [
            {
                "id": "deposit-1",
                "coin": "USDT",
                "amount": "40",
                "status": 1,
                "walletType": 0,
                "transferType": 1,
                "insertTime": self._ms(1),
                "address": "secret-deposit-address",
            },
            {"id": "deposit-2", "coin": "USDT", "amount": "90", "status": 0, "walletType": 0, "insertTime": self._ms(2)},
            {"id": "deposit-3", "coin": "USDT", "amount": "50", "status": 1, "walletType": 1, "insertTime": self._ms(2)},
        ]
        client.get_withdraw_history.return_value = [
            {
                "id": "withdraw-1",
                "coin": "USDT",
                "amount": "100",
                "status": 6,
                "walletType": 0,
                "transferType": 1,
                "withdrawOrderId": "tt-order-1",
                "completeTime": "2026-09-03 02:00:00",
                "address": "secret-withdraw-address",
            },
            {"id": "withdraw-2", "coin": "USDT", "amount": "80", "status": 4, "walletType": 0, "applyTime": "2026-09-02 02:00:00"},
            {"id": "withdraw-3", "coin": "USDT", "amount": "70", "status": 6, "walletType": 1, "applyTime": "2026-09-02 02:00:00"},
        ]

        result = build_transfer_history(self.user, now=self.NOW)

        self.assertEqual(result["account_type"], "master")
        self.assertEqual(result["outgoing_total"], "100")
        self.assertEqual(result["incoming_total"], "90")
        self.assertEqual(result["net_amount"], "10")
        self.assertEqual(result["records"][0]["route"], "现货 -> 归集账户")
        self.assertEqual(result["records"][0]["channel"], "币安站内转账")
        serialized = json.dumps(result, ensure_ascii=False)
        self.assertNotIn("secret-deposit-address", serialized)
        self.assertNotIn("secret-withdraw-address", serialized)
        self.assertNotIn("withdrawOrderId", serialized)

    @patch("accounts.transfer_history.account_type_for_client", return_value="master")
    @patch("accounts.transfer_history.BinanceFuturesClient")
    @patch("accounts.transfer_history.get_user_binance_credentials", return_value=object())
    def test_master_history_paginates_full_pages(
        self, _mock_credentials, mock_client_cls, _mock_account_type
    ):
        client = mock_client_cls.return_value
        client.get_pay_transactions.return_value = []
        full_page = [
            {"id": f"deposit-{index}", "coin": "USDT", "amount": "1", "status": 1, "walletType": 0, "insertTime": self._ms(1)}
            for index in range(1000)
        ]
        client.get_deposit_history.side_effect = [full_page, []]
        client.get_withdraw_history.return_value = []

        result = build_transfer_history(self.user, now=self.NOW)

        self.assertEqual(result["incoming_total"], "1000")
        self.assertEqual(client.get_deposit_history.call_args_list[0].kwargs["offset"], 0)
        self.assertEqual(client.get_deposit_history.call_args_list[1].kwargs["offset"], 1000)

    def test_sub_account_full_page_is_split_into_non_overlapping_time_ranges(self):
        client = Mock()
        client.get_sub_account_transfer_history.side_effect = [
            [{"tranId": index} for index in range(200)],
            [{"tranId": "left"}],
            [{"tranId": "right"}],
        ]

        rows = _sub_account_rows(client, transfer_type=2, start_ms=100, end_ms=199)

        self.assertEqual(rows, [{"tranId": "left"}, {"tranId": "right"}])
        calls = client.get_sub_account_transfer_history.call_args_list
        self.assertEqual((calls[1].kwargs["start_time_ms"], calls[1].kwargs["end_time_ms"]), (100, 149))
        self.assertEqual((calls[2].kwargs["start_time_ms"], calls[2].kwargs["end_time_ms"]), (150, 199))

    def test_master_windows_are_contiguous_and_shorter_than_ninety_days(self):
        windows = list(_master_windows(100, 100 + MASTER_WINDOW_MS * 2 + 5))

        self.assertEqual(len(windows), 3)
        self.assertTrue(all(end - start <= MASTER_WINDOW_MS for start, end in windows))
        self.assertTrue(all(windows[index][1] + 1 == windows[index + 1][0] for index in range(2)))

    @patch("accounts.transfer_history.account_type_for_client", return_value="master")
    @patch("accounts.transfer_history.BinanceFuturesClient")
    @patch("accounts.transfer_history.get_user_binance_credentials", return_value=object())
    def test_master_account_history_uses_centralized_account_probe(
        self, _mock_credentials, mock_client_cls, _mock_account_type
    ):
        client = mock_client_cls.return_value
        client.get_pay_transactions.return_value = []
        client.get_deposit_history.return_value = []
        client.get_withdraw_history.return_value = []

        result = build_transfer_history(self.user, now=self.NOW)

        self.assertEqual(result["account_type"], "master")
        client.get_sub_account_transfer_history.assert_not_called()

    @patch("accounts.transfer_history.account_type_for_client", return_value="unknown")
    @patch("accounts.transfer_history.BinanceFuturesClient")
    @patch("accounts.transfer_history.get_user_binance_credentials", return_value=object())
    def test_unknown_account_type_is_rejected(
        self, _mock_credentials, _mock_client_cls, _mock_account_type
    ):
        with self.assertRaisesMessage(BinanceApiError, "无法确认当前 Binance 账户类型"):
            build_transfer_history(self.user, now=self.NOW)

    @patch("accounts.transfer_history.get_user_binance_credentials", return_value=None)
    def test_unbound_account_is_rejected(self, _mock_credentials):
        with self.assertRaisesMessage(BinanceApiError, "请先绑定 Binance API"):
            build_transfer_history(self.user, now=self.NOW)


class TransferHistoryApiTests(APITestCase):
    URL = "/v1/account/transfer-history"

    def setUp(self):
        self.user = User.objects.create_user(email="history_api@example.com", password="123456")
        login_resp = self.client.post(
            "/v1/auth/login",
            {"email": "history_api@example.com", "password": "123456", "agreed": True},
            format="json",
        )
        token = login_resp.data["data"]["token"]
        self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")

    @patch("accounts.views.get_cached_transfer_history")
    def test_get_transfer_history(self, mock_build):
        mock_build.return_value = {
            "start_at": "2026-08-28T00:00:00+08:00",
            "account_type": "sub",
            "outgoing_total": "150",
            "incoming_total": "100",
            "net_amount": "50",
            "records": [],
        }
        response = self.client.get(self.URL)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["data"]["net_amount"], "50")
        mock_build.assert_called_once_with(self.user, page=1, page_size=20)

    @patch("accounts.views.get_cached_transfer_history")
    def test_get_transfer_history_validates_pagination(self, mock_build):
        mock_build.return_value = {"records": [], "pagination": {"page": 2}}
        response = self.client.get(self.URL, {"page": 2, "page_size": 50})

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        mock_build.assert_called_once_with(self.user, page=2, page_size=50)

        invalid = self.client.get(self.URL, {"page": 0, "page_size": 101})
        self.assertEqual(invalid.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(invalid.data["message"], "分页参数无效")

    @patch("accounts.views.get_cached_transfer_history", side_effect=BinanceApiError("历史接口不可用"))
    def test_binance_error_does_not_return_partial_totals(self, _mock_build):
        response = self.client.get(self.URL)
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["message"], "历史接口不可用")
        self.assertIsNone(response.data["data"])


class CapitalCollectAccountTests(APITestCase):
    URL = "/v1/account/capital-collect-account"

    def setUp(self):
        self.user = User.objects.create_user(email="collect_test@example.com", password="123456")
        login_resp = self.client.post(
            "/v1/auth/login",
            {"email": "collect_test@example.com", "password": "123456", "agreed": True},
            format="json",
        )
        token = login_resp.data["data"]["token"]
        self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")

    def test_get_reports_sub_account_when_unbound(self):
        resp = self.client.get(self.URL)
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data["data"]["capital_collect_account"], "")
        self.assertEqual(resp.data["data"]["capital_collect_address"], "")
        self.assertEqual(resp.data["data"]["capital_collect_network"], "")
        self.assertFalse(resp.data["data"]["capital_collect_network_supported"])
        self.assertEqual(resp.data["data"]["account_type"], "unknown")

    def test_save_rejects_json_array(self):
        resp = self.client.post(self.URL, [], format="json")

        self.assertEqual(resp.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(resp.data["message"], "请求参数必须是对象")

    @patch("accounts.views.account_type_for_client", return_value="master")
    @patch("accounts.views.get_user_binance_credentials", return_value=object())
    def test_get_reports_master_account_when_probe_hits(self, _mock_creds, _mock_probe):
        resp = self.client.get(self.URL)
        self.assertEqual(resp.data["data"]["account_type"], "master")

    @patch("accounts.views.account_type_for_client", return_value="sub")
    @patch("accounts.views.get_user_binance_credentials", return_value=object())
    def test_get_reports_sub_account_when_probe_confirms(self, _mock_creds, _mock_probe):
        resp = self.client.get(self.URL)
        self.assertEqual(resp.data["data"]["account_type"], "sub")

    @patch("accounts.views.account_type_for_client", side_effect=RuntimeError("network"))
    @patch("accounts.views.get_user_binance_credentials", return_value=object())
    def test_get_reports_unknown_when_probe_fails(self, _mock_creds, _mock_probe):
        resp = self.client.get(self.URL)
        self.assertEqual(resp.data["data"]["account_type"], "unknown")

    @patch("accounts.views.get_user_binance_credentials", return_value=None)
    def test_save_valid_address_and_network(self, _mock_creds):
        resp = self.client.post(
            self.URL,
            {"capital_collect_address": "0x1234567890abcdef1234567890abcdef12345678", "capital_collect_network": "bSc"},
            format="json",
        )
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.user.refresh_from_db()
        self.assertEqual(self.user.capital_collect_account, "0x1234567890abcdef1234567890abcdef12345678")
        self.assertEqual(self.user.capital_collect_network, "BSC")
        self.assertEqual(resp.data["data"]["capital_collect_address"], "0x1234567890abcdef1234567890abcdef12345678")
        self.assertEqual(resp.data["data"]["capital_collect_network"], "BSC")
        self.assertTrue(resp.data["data"]["capital_collect_network_supported"])

    @patch("accounts.views.get_user_binance_credentials", return_value=None)
    def test_save_rejects_unsupported_network(self, _mock_creds):
        resp = self.client.post(
            self.URL,
            {"capital_collect_address": "0x1234567890abcdef1234567890abcdef12345678", "capital_collect_network": "SOL"},
            format="json",
        )
        self.assertEqual(resp.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("仅支持 BSC", resp.data["message"])

    @patch("accounts.views.get_user_binance_credentials", return_value=None)
    def test_save_accepts_all_supported_networks(self, _mock_creds):
        address = "0x1234567890abcdef1234567890abcdef12345678"
        for network in ("trx", "ETH"):
            with self.subTest(network=network):
                resp = self.client.post(
                    self.URL,
                    {"capital_collect_address": address, "capital_collect_network": network},
                    format="json",
                )
                self.assertEqual(resp.status_code, status.HTTP_200_OK)
                self.assertEqual(resp.data["data"]["capital_collect_network"], network.upper())

    @patch("accounts.views.get_user_binance_credentials", return_value=None)
    def test_unsupported_legacy_network_is_reported_without_conversion(self, _mock_creds):
        self.user.capital_collect_account = "TQx9d8qM7exampleAddress"
        self.user.capital_collect_network = "SOL"
        self.user.save(update_fields=["capital_collect_account", "capital_collect_network"])

        resp = self.client.get(self.URL)

        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data["data"]["capital_collect_network"], "SOL")
        self.assertFalse(resp.data["data"]["capital_collect_network_supported"])
        self.user.refresh_from_db()
        self.assertEqual(self.user.capital_collect_network, "SOL")

    @patch("accounts.views.get_user_binance_credentials", return_value=None)
    def test_save_rejects_invalid_formats(self, _mock_creds):
        invalid_payloads = [
            {"capital_collect_address": "target@example.com", "capital_collect_network": "TRX"},
            {"capital_collect_address": "12345678", "capital_collect_network": "TRX"},
            {"capital_collect_address": "address", "capital_collect_network": ""},
            {"capital_collect_address": "0x1234567890abcdef1234567890abcdef12345678", "capital_collect_network": "bad network"},
            {"capital_collect_address": " " * 3 + "0x1234567890abcdef1234567890abcdef12345678", "capital_collect_network": "BSC"},
        ]
        for payload in invalid_payloads:
            resp = self.client.post(self.URL, payload, format="json")
            self.assertEqual(resp.status_code, status.HTTP_400_BAD_REQUEST, payload)

    @patch("accounts.views.get_user_binance_credentials", return_value=None)
    def test_save_empty_value_clears_configuration(self, _mock_creds):
        self.user.capital_collect_account = "0x1234567890abcdef1234567890abcdef12345678"
        self.user.capital_collect_network = "BSC"
        self.user.save(update_fields=["capital_collect_account", "capital_collect_network"])
        resp = self.client.post(
            self.URL,
            {"capital_collect_address": "", "capital_collect_network": ""},
            format="json",
        )
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertIn("已清除", resp.data["message"])
        self.user.refresh_from_db()
        self.assertEqual(self.user.capital_collect_account, "")
        self.assertEqual(self.user.capital_collect_network, "")
