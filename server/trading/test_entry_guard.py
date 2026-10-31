from contextlib import nullcontext
from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

from api_bindings.context import TradingAccountContext
from django.test import SimpleTestCase

from trading.entry_guard import entry_submission_guard


class EntrySubmissionGuardTests(SimpleTestCase):
    def setUp(self):
        self.user = MagicMock()
        self.user.id = 7
        self.created_at = datetime(2026, 9, 11, tzinfo=timezone.utc)
        self.account = TradingAccountContext(
            user_id=7,
            binding_id=11,
            api_key_fingerprint="fingerprint",
            alias="primary",
            binding_created_at=self.created_at,
            credentials=MagicMock(),
        )

    @patch("trading.entry_guard.get_user_binding_generation")
    @patch("trading.entry_guard.trade_submit_lock")
    @patch("trading.entry_guard.user_trading_activity_lock")
    def test_allows_entry_with_one_captured_account_generation(
        self,
        mock_activity_lock,
        mock_submit_lock,
        mock_generation,
    ):
        mock_activity_lock.return_value = nullcontext(True)
        mock_submit_lock.return_value = nullcontext(True)
        mock_generation.return_value = self.account.generation

        with entry_submission_guard(
            self.user,
            self.account,
            action="market-open",
            symbol="BTCUSDT",
        ) as guard:
            self.assertTrue(guard.allowed)
            self.assertEqual(guard.error, "")

        mock_activity_lock.assert_called_once_with(self.account.identity)
        mock_submit_lock.assert_called_once_with(
            "market-open",
            self.account.identity,
            "BTCUSDT",
        )
        mock_generation.assert_called_once_with(self.user, trading_mode=self.account.trading_mode)

    @patch("trading.entry_guard.trade_submit_lock")
    @patch("trading.entry_guard.user_trading_activity_lock")
    def test_rejects_busy_account_without_entering_submit_lock(
        self,
        mock_activity_lock,
        mock_submit_lock,
    ):
        mock_activity_lock.return_value = nullcontext(False)

        with entry_submission_guard(
            self.user,
            self.account,
            action="limit-create",
            symbol="ETHUSDT",
        ) as guard:
            self.assertFalse(guard.allowed)
            self.assertEqual(guard.error, "请求处理中，请勿重复提交")

        mock_submit_lock.assert_not_called()

    @patch("trading.entry_guard.get_user_binding_generation")
    @patch("trading.entry_guard.trade_submit_lock")
    @patch("trading.entry_guard.user_trading_activity_lock")
    def test_rejects_changed_binding_generation(
        self,
        mock_activity_lock,
        mock_submit_lock,
        mock_generation,
    ):
        mock_activity_lock.return_value = nullcontext(True)
        mock_submit_lock.return_value = nullcontext(True)
        mock_generation.return_value = ("new-fingerprint", self.created_at)

        with entry_submission_guard(
            self.user,
            self.account,
            action="limit-chase",
            symbol="BTCUSDT",
        ) as guard:
            self.assertFalse(guard.allowed)
            self.assertEqual(guard.error, "API 绑定已发生变化，请刷新后重试")
