from decimal import Decimal
from unittest.mock import Mock, patch

from django.core.cache import cache
from django.db import DatabaseError, transaction
from django.utils import timezone
from rest_framework.test import APITestCase

from common.binance import BinanceApiError
from positions.models import Order, TradeOperationLog
from trading.services import (
    ProtectionAccountSnapshot,
    _converge_stop_loss_order,
    _emergency_close_unprotected_position,
    _reconcile_stop_loss_protection,
    _record_stop_protection_retry_failure,
)
from users.models import User


class WebOperationLogTests(APITestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(email="operation-test@example.com", password="test-only")
        self.client.force_authenticate(self.user)
        self.order = Order.objects.create(
            user=self.user, binance_order_id="test-entry", symbol="BTCUSDT", side=0,
            open_price=Decimal("100"), stop_loss_price=Decimal("90"),
            current_stop_price=Decimal("90"), stop_loss_amount=Decimal("10"),
            size=Decimal("1"), leverage=1,
        )
        self.exchange = Mock()
        self.exchange.get_account_config.return_value = {"data": [{"posMode": "long_short_mode"}]}
        self.exchange.get_positions.return_value = {"data": [{
            "instId": "BTC-USDT-SWAP", "posSide": "long", "pos": "1", "markPx": "100", "ctVal": "1",
        }]}
        self.snapshot = ProtectionAccountSnapshot(
            client=self.exchange, pos_mode="long_short_mode", positions=[], algo_map={}, close_trade_rows={},
        )
        no_network = patch("common.binance._perform_http_request", side_effect=AssertionError("No private network in tests"))
        no_network.start()
        self.addCleanup(no_network.stop)

    def logs(self, action):
        return TradeOperationLog.objects.filter(order=self.order, action=action).order_by("id")

    def confirm_protection(self):
        self.order.binance_stop_market_order_id = "test-stop"
        self.snapshot.algo_map = {"test-stop": {"algoId": "test-stop"}}
        with patch("trading.services._protection_is_complete", return_value=True):
            return _reconcile_stop_loss_protection(
                order=self.order, snapshot=self.snapshot, strategy_snapshot=None,
                exchange_size=Decimal("1"), current_price=Decimal("100"), stop_price=Decimal("90"),
            )

    def test_strategy_free_protection_failure_recovery_and_repeat_failure_are_visible(self):
        _record_stop_protection_retry_failure(self.order, "temporary timeout")
        _record_stop_protection_retry_failure(self.order, "temporary timeout")
        self.assertEqual(self.logs("stop_protection").count(), 1)
        self.assertEqual(self.logs("stop_protection").get().status, "pending")
        self.confirm_protection()
        self.confirm_protection()
        _record_stop_protection_retry_failure(self.order, "temporary timeout")
        self.assertEqual(list(self.logs("stop_protection").values_list("status", flat=True)), ["pending", "success", "pending"])
        self.assertIsNone(self.order.strategy_snapshot_id)

    def test_stop_ack_is_pending_until_live_protection_is_confirmed(self):
        with patch("trading.services._normalize_stop_loss_request", return_value={"stop_price": Decimal("90"), "size": Decimal("1")}), patch(
            "trading.services._place_stop_loss_protection_verified", return_value=("", "test-stop"),
        ):
            changed = _converge_stop_loss_order(
                self.exchange, self.order, exchange_size=Decimal("1"), stop_price=Decimal("90"),
                current_price=Decimal("100"), pos_mode="long_short_mode", algo_rows=[],
            )
        self.assertTrue(changed)
        self.assertEqual(self.logs("stop_protection").get().status, "pending")
        self.confirm_protection()
        self.assertEqual(list(self.logs("stop_protection").values_list("status", flat=True)), ["pending", "success"])

    @patch("trading.services.time.sleep")
    def test_emergency_rejection_and_unknown_outcome_are_not_reported_as_closed(self, _sleep):
        for unknown, expected in ((False, "failed"), (True, "pending")):
            with self.subTest(unknown=unknown):
                self.exchange.close_position.side_effect = BinanceApiError("test refusal or timeout", outcome_unknown=unknown)
                result = _emergency_close_unprotected_position(self.order, self.snapshot, Decimal("90"))
                self.assertEqual(result, 0)
                self.assertEqual(self.logs("emergency_close").last().status, expected)
                self.order.refresh_from_db()
                self.assertEqual(self.order.status, 0)
        self.assertFalse(self.logs("emergency_close").filter(status="success").exists())

    def test_log_database_failure_does_not_rollback_protection_state(self):
        with transaction.atomic(), patch(
            "positions.operation_logs.TradeOperationLog.objects.create", side_effect=DatabaseError("log table unavailable"),
        ):
            _record_stop_protection_retry_failure(self.order, "test timeout")
            self.order.refresh_from_db()
            self.assertEqual(self.order.stop_protection_retry_count, 1)
            self.assertEqual(self.order.stop_protection_status, Order.STOP_PROTECTION_PENDING)
        self.assertFalse(TradeOperationLog.objects.exists())

    def test_visibility_grace_does_not_log_unseen_stop_as_confirmed(self):
        self.order.binance_stop_market_order_id = "still-invisible"
        self.order.stop_loss_order_created_at = timezone.now()
        _reconcile_stop_loss_protection(
            order=self.order, snapshot=self.snapshot, strategy_snapshot=None,
            exchange_size=Decimal("1"), current_price=Decimal("100"), stop_price=Decimal("90"),
        )
        self.assertFalse(self.logs("stop_protection").filter(status="success").exists())

    @patch("positions.views.time.sleep")
    def test_manual_close_unknown_and_rejected_results_keep_source_and_status(self, _sleep):
        with patch("positions.views.get_user_binance_credentials", return_value=object()), patch(
            "positions.views.BinanceFuturesClient", return_value=self.exchange,
        ):
            self.exchange.close_position.side_effect = BinanceApiError("unknown", outcome_unknown=True)
            response = self.client.post("/v1/position/close", {"position_id": self.order.pk}, format="json")
            self.assertEqual(response.status_code, 400)
            self.assertEqual(self.logs("manual_close").last().status, "pending")
            self.exchange.close_position.side_effect = BinanceApiError("permission denied")
            response = self.client.post("/v1/position/close", {"position_id": self.order.pk}, format="json")
        self.assertEqual(response.status_code, 400)
        self.assertEqual(self.logs("manual_close").last().status, "failed")
        self.assertEqual(set(self.logs("manual_close").values_list("actor", flat=True)), {"user"})
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, 0)

    def test_manual_take_profit_submit_and_cancel_have_distinct_confirmed_actions(self):
        with patch("positions.views.get_user_binance_credentials", return_value=object()), patch(
            "positions.views.BinanceFuturesClient", return_value=self.exchange,
        ), patch("positions.views.BinanceAlgoClient") as algo_cls:
            algo_cls.return_value.create_take_profit.return_value = "test-take-profit"
            response = self.client.post("/v1/position/take-profit", {
                "position_id": self.order.pk, "take_profit_price": "120", "order_type": "limit",
            }, format="json")
            self.assertEqual(response.status_code, 200)
            response = self.client.delete("/v1/position/take-profit", {"position_id": self.order.pk}, format="json")
        self.assertEqual(response.status_code, 200)
        logs = list(self.logs("manual_take_profit"))
        self.assertEqual(len(logs), 2)
        self.assertIn("已受理", logs[0].message)
        self.assertIn("120", logs[0].message)
        self.assertIn("已确认取消", logs[1].message)
        self.assertTrue(all(log.actor == "user" for log in logs))

    def test_take_profit_visibility_timeout_is_pending_even_without_unknown_flag(self):
        self.order.manual_take_profit_algo_id = "old-take-profit"
        self.order.manual_take_profit_price = Decimal("120")
        self.order.save(update_fields=["manual_take_profit_algo_id", "manual_take_profit_price"])
        with patch("positions.views.get_user_binance_credentials", return_value=object()), patch(
            "positions.views.BinanceFuturesClient", return_value=self.exchange,
        ), patch("positions.views.BinanceAlgoClient") as algo_cls:
            algo_cls.return_value.create_take_profit.side_effect = BinanceApiError(
                "accepted order not visible; rollback unconfirmed", code="ALGO_VISIBILITY_TIMEOUT",
            )
            response = self.client.post("/v1/position/take-profit", {
                "position_id": self.order.pk, "take_profit_price": "130", "order_type": "market",
            }, format="json")
        self.assertEqual(response.status_code, 400)
        log = self.logs("manual_take_profit").get()
        self.assertEqual(log.status, "pending")
        self.assertIn("待核对", log.message)
        self.order.refresh_from_db()
        self.assertEqual(self.order.manual_take_profit_algo_id, "old-take-profit")

    def test_break_even_visibility_timeout_is_pending_even_without_unknown_flag(self):
        with patch("positions.views.get_user_binance_credentials", return_value=object()), patch(
            "positions.views.BinanceFuturesClient", return_value=self.exchange,
        ), patch("positions.views.BinanceAlgoClient") as algo_cls:
            algo_cls.return_value.create_take_profit.side_effect = BinanceApiError(
                "accepted order not visible; rollback unconfirmed", code="ALGO_VISIBILITY_TIMEOUT",
            )
            response = self.client.post("/v1/position/break-even-stop", {
                "position_id": self.order.pk, "mode": "without_fee",
            }, format="json")
        self.assertEqual(response.status_code, 400)
        log = self.logs("break_even").get()
        self.assertEqual(log.status, "pending")
        self.assertIn("待核对", log.message)
