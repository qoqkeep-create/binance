from datetime import timedelta
from decimal import Decimal
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from django.core.cache import cache
from django.utils import timezone
from rest_framework.test import APITestCase

from positions.models import Order
from positions.views import (
    _auto_close_missing_exchange_order_safely,
    _reconcile_order_settlement,
    _sync_entry_fee_for_order,
    audit_suspicious_closed_orders,
    reconcile_closed_order_exchange_artifacts,
    reconcile_pending_order_settlements,
    reconcile_stale_open_orders,
    sync_pending_entry_fees,
)
from users.models import User


class ExternalPositionApiTests(APITestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(email="manual-position@example.com", password="test-password")
        self.client.force_authenticate(self.user)
        self.order = Order.objects.create(
            user=self.user,
            binance_order_id=None,
            position_origin="exchange_external",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("10"),
            size=Decimal("1"),
            leverage=10,
        )
        self.exchange = MagicMock()
        self.exchange.get_account_config.return_value = {"data": [{"posMode": "long_short_mode"}]}
        self.exchange.get_positions.return_value = {"data": [self.position_row("long", "1", "100", "5")]}
        self.exchange.get_open_algo_orders.return_value = {"data": []}
        for target, value in (
            ("positions.views.get_user_binance_credentials", object()),
            ("positions.views.BinanceFuturesClient", self.exchange),
            ("positions.views._load_public_last_price_map", {"BTC-USDT-SWAP": Decimal("105")}),
            ("positions.views.load_shared_open_algo_rows", []),
        ):
            patcher = patch(target, return_value=value)
            patcher.start()
            self.addCleanup(patcher.stop)

    @staticmethod
    def position_row(side, size, price, pnl, update_time=None):
        row = {
            "instId": "BTC-USDT-SWAP", "posSide": side, "pos": size,
            "avgPx": price, "markPx": "105", "upl": pnl, "ctVal": "1", "lever": "10",
        }
        if update_time is not None:
            row["updateTime"] = update_time
        return row

    def test_manual_position_is_labelled_and_cannot_bind_strategy(self):
        response = self.client.get("/v1/position/list")
        self.assertEqual(response.status_code, 200)
        row = response.data["data"][0]
        self.assertEqual(row["position_origin"], "exchange_external")
        self.assertFalse(row["can_bind_strategy"])

    @patch("positions.views.user_trading_activity_lock")
    @patch("positions.views.get_user_trading_account")
    def test_manual_position_without_local_order_is_discovered_during_list_read(self, account, lock):
        self.order.delete()
        self.exchange.get_positions.return_value = {
            "data": [self.position_row("long", "1", "100", "5", update_time="1762164030123")]
        }
        account.return_value = SimpleNamespace(
            identity="user:manual-position",
            api_key_fingerprint="",
            binding_created_at=None,
            generation=("", None),
            trading_mode="ordinary",
        )
        lock.return_value.__enter__.return_value = True

        response = self.client.get("/v1/position/list")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.data["data"]), 1)
        self.assertEqual(response.data["data"][0]["position_origin"], "exchange_external")
        self.assertEqual(response.data["data"][0]["opened_at"], "2025-11-03T10:00:30.123000+00:00")
        self.assertEqual(Order.objects.filter(position_origin=Order.ORIGIN_EXTERNAL).count(), 1)

    def test_opposite_positions_are_matched_by_symbol_and_direction(self):
        short = Order.objects.create(
            user=self.user, binance_order_id="web-short", symbol="BTCUSDT", side=1,
            open_price=Decimal("120"), stop_loss_price=Decimal("125"),
            stop_loss_amount=Decimal("10"), size=Decimal("2"), leverage=10,
        )
        self.exchange.get_positions.return_value = {"data": [
            self.position_row("long", "1", "100", "5"),
            self.position_row("short", "2", "120", "30"),
        ]}
        response = self.client.get("/v1/position/list")
        rows = {row["id"]: row for row in response.data["data"]}
        self.assertEqual(rows[self.order.id]["exchange_size"], "1")
        self.assertEqual(rows[self.order.id]["open_price"], "100")
        self.assertEqual(rows[short.id]["exchange_size"], "2")
        self.assertEqual(rows[short.id]["open_price"], "120")
        self.assertEqual(rows[short.id]["position_origin"], "web")

    def test_signed_net_position_matches_short_and_ignores_zero_rows(self):
        self.order.side = 1
        self.order.save(update_fields=["side"])
        self.exchange.get_positions.return_value = {"data": [
            self.position_row("", "-1", "100", "-5"),
            self.position_row("long", "0", "0", "0"),
        ]}
        response = self.client.get("/v1/position/list")
        self.assertEqual(len(response.data["data"]), 1)
        self.assertEqual(response.data["data"][0]["open_price"], "100")

    @patch("positions.views._auto_close_missing_exchange_order_safely")
    def test_list_leaves_missing_manual_position_to_external_reconciler(self, auto_close):
        self.exchange.get_positions.return_value = {"data": []}
        response = self.client.get("/v1/position/list")
        self.assertEqual(response.data["data"], [])
        auto_close.assert_not_called()
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, 0)

    @patch("trading.external_positions.close_external_position")
    @patch("positions.views.best_effort_cleanup_closed_order_exchange_artifacts")
    def test_manual_close_uses_external_lifecycle_and_tolerates_unknown_pnl(self, cleanup, close):
        def confirmed(order, client, *, pos_mode, reason):
            self.assertEqual(client, self.exchange)
            self.assertEqual(pos_mode, "long_short_mode")
            self.assertEqual(reason, "manual")
            order.status = 1
            order.pnl = None
            order.pnl_ratio = None
            order.save(update_fields=["status", "pnl", "pnl_ratio"])
            return True

        close.side_effect = confirmed
        response = self.client.post("/v1/position/close", {"position_id": self.order.id}, format="json")
        self.assertEqual(response.status_code, 200)
        close.assert_called_once()
        cleanup.assert_not_called()
        self.exchange.close_position.assert_not_called()

    @patch("trading.external_positions.close_external_position", return_value=False)
    @patch("positions.views.best_effort_cleanup_closed_order_exchange_artifacts")
    def test_unconfirmed_manual_close_keeps_position_and_protection(self, cleanup, close):
        self.order.binance_stop_market_order_id = "manual-protection"
        self.order.save(update_fields=["binance_stop_market_order_id"])
        response = self.client.post("/v1/position/close", {"position_id": self.order.id}, format="json")
        self.assertEqual(response.status_code, 400)
        self.assertIn("尚未确认", response.data["message"])
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, 0)
        self.assertEqual(self.order.binance_stop_market_order_id, "manual-protection")
        cleanup.assert_not_called()
        self.exchange.close_position.assert_not_called()

    @patch("trading.external_positions.close_external_position")
    def test_manual_close_rejects_other_users_order_before_exchange_calls(self, close):
        other = User.objects.create_user(email="other-manual-position@example.com", password="test-password")
        self.client.force_authenticate(other)
        response = self.client.post("/v1/position/close", {"position_id": self.order.id}, format="json")
        self.assertEqual(response.status_code, 400)
        close.assert_not_called()
        self.exchange.get_account_config.assert_not_called()

    @patch("trading.external_positions.close_external_position")
    def test_manual_close_rejects_other_trading_mode(self, close):
        self.order.trading_mode = "lead"
        self.order.save(update_fields=["trading_mode"])
        response = self.client.post("/v1/position/close", {"position_id": self.order.id}, format="json")
        self.assertEqual(response.status_code, 400)
        close.assert_not_called()

    def test_manual_strategy_rebind_and_cancel_do_not_disable_protection(self):
        self.order.binance_stop_market_order_id = "manual-protection"
        self.order.save(update_fields=["binance_stop_market_order_id"])
        for path, data in (
            ("/v1/strategy/rebind", {"position_id": self.order.id, "strategy_id": "any"}),
            ("/v1/strategy/cancel", {"position_id": self.order.id}),
        ):
            with self.subTest(path=path):
                response = self.client.post(path, data, format="json")
                self.assertEqual(response.status_code, 400)
                self.assertIn("手动仓", response.data["message"])
        self.order.refresh_from_db()
        self.assertEqual(self.order.binance_stop_market_order_id, "manual-protection")
        self.exchange.cancel_algo_order.assert_not_called()

    def test_manual_break_even_cannot_bypass_external_stop_state(self):
        response = self.client.post(
            "/v1/position/break-even-stop",
            {"position_id": self.order.id, "mode": "without_fee"},
            format="json",
        )
        self.assertEqual(response.status_code, 400)
        self.assertIn("手动仓", response.data["message"])
        self.exchange.get_positions.assert_not_called()

    def test_legacy_open_reconcilers_and_fee_helpers_ignore_manual_position(self):
        self.assertEqual(reconcile_stale_open_orders(), 0)
        self.assertEqual(sync_pending_entry_fees(), 0)
        self.assertFalse(_sync_entry_fee_for_order(self.order, self.exchange))
        self.assertFalse(_auto_close_missing_exchange_order_safely(
            self.order, self.exchange, account_identity="manual-account", pos_mode="long_short_mode", source="test",
        ))
        self.assertFalse(_reconcile_order_settlement(order=self.order, client=self.exchange, close_price=Decimal("105")))
        self.exchange.get_positions.assert_not_called()
        self.exchange.get_user_trades.assert_not_called()

    def test_legacy_closed_reconcilers_ignore_manual_position(self):
        self.order.status = 1
        self.order.closed_at = timezone.now() - timedelta(minutes=5)
        self.order.binance_stop_market_order_id = "external-residual"
        self.order.save(update_fields=["status", "closed_at", "binance_stop_market_order_id"])
        self.assertEqual(reconcile_pending_order_settlements(), 0)
        self.assertEqual(reconcile_closed_order_exchange_artifacts(), 0)
        self.assertEqual(audit_suspicious_closed_orders(), 0)
        self.exchange.get_user_trades.assert_not_called()
        self.exchange.cancel_algo_order.assert_not_called()

    def test_manual_history_stays_estimated_and_does_not_infer_opening_fills(self):
        self.order.status = 1
        self.order.closed_at = timezone.now()
        self.order.pnl = Decimal("5")
        self.order.save(update_fields=["status", "closed_at", "pnl"])
        response = self.client.get("/v1/position/history")
        self.assertEqual(response.status_code, 200)
        row = response.data["data"]["items"][0]
        self.assertEqual(row["position_origin"], "exchange_external")
        self.assertEqual(row["settlement_status"], "estimated")
        self.assertIn("不完整", row["settlement_note"])
        self.assertEqual(row["data_source_flags"]["pnl"], "local_estimated_order")
        self.exchange.get_user_trades.assert_not_called()
        self.exchange.get_bills.assert_not_called()

    def test_manual_history_preserves_unknown_profit_price_and_fees_as_null(self):
        self.order.status = 1
        self.order.closed_at = timezone.now()
        self.order.pnl = None
        self.order.pnl_ratio = None
        self.order.close_price = None
        self.order.save(update_fields=["status", "closed_at", "pnl", "pnl_ratio", "close_price"])
        response = self.client.get("/v1/position/history")
        row = response.data["data"]["items"][0]
        for field in ("pnl", "pnl_ratio", "realized_pnl", "close_price", "fee", "funding_fee"):
            with self.subTest(field=field):
                self.assertIsNone(row[field])
        self.assertEqual(row["settlement_status"], "estimated")

    def test_manual_history_reconciles_missing_financials_from_exchange_history(self):
        self.order.status = 1
        self.order.closed_at = timezone.now()
        self.order.pnl = None
        self.order.pnl_ratio = None
        self.order.close_price = None
        self.order.realized_pnl = None
        self.order.realized_fee = None
        self.order.realized_funding_fee = None
        self.order.save(update_fields=[
            "status", "closed_at", "pnl", "pnl_ratio", "close_price",
            "realized_pnl", "realized_fee", "realized_funding_fee",
        ])
        close_time = str(int(self.order.closed_at.timestamp() * 1000))
        self.exchange.get_positions_history.return_value = {"data": [{
            "instId": "BTC-USDT-SWAP",
            "direction": "long",
            "openAvgPx": "100",
            "closeAvgPx": "110",
            "closeTotalPos": "1",
            "realizedPnl": "10",
            "fee": "0.2",
            "fundingFee": "-0.1",
            "uTime": close_time,
        }]}

        response = self.client.get("/v1/position/history")

        self.assertEqual(response.status_code, 200)
        row = response.data["data"]["items"][0]
        self.assertEqual(row["close_price"], "110")
        self.assertEqual(row["pnl"], "9.70000000")
        self.assertEqual(row["realized_pnl"], "10.00000000")
        self.assertEqual(row["fee"], "-0.20000000")
        self.assertEqual(row["funding_fee"], "-0.10000000")
        self.assertEqual(row["pnl_ratio"], "9.7000")
        self.order.refresh_from_db()
        self.assertEqual(self.order.pnl, Decimal("9.7"))
        self.assertEqual(self.order.realized_fee, Decimal("-0.2"))
        self.exchange.get_positions_history.assert_called_once_with(limit=40)

    def test_manual_history_snapshot_requests_exchange_follow_up_for_missing_financials(self):
        self.order.status = 1
        self.order.closed_at = timezone.now()
        self.order.pnl = None
        self.order.close_price = None
        self.order.save(update_fields=["status", "closed_at", "pnl", "close_price"])

        response = self.client.get("/v1/position/history", {"snapshot": "local"})

        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.data["data"]["exchange_refresh_required"])
        self.exchange.get_positions_history.assert_not_called()

    def test_manual_history_keeps_unknown_when_exchange_match_is_ambiguous(self):
        self.order.status = 1
        self.order.closed_at = timezone.now()
        self.order.pnl = None
        self.order.close_price = None
        self.order.realized_pnl = None
        self.order.realized_fee = None
        self.order.realized_funding_fee = None
        close_time = str(int(self.order.closed_at.timestamp() * 1000))
        segment = {
            "instId": "BTC-USDT-SWAP",
            "direction": "long",
            "openAvgPx": "100",
            "closeAvgPx": "110",
            "closeTotalPos": "1",
            "realizedPnl": "10",
            "fee": "0.2",
            "fundingFee": "-0.1",
            "uTime": close_time,
        }
        self.exchange.get_positions_history.return_value = {
            "data": [segment, dict(segment)]
        }
        self.order.save(update_fields=[
            "status", "closed_at", "pnl", "close_price", "realized_pnl",
            "realized_fee", "realized_funding_fee",
        ])

        response = self.client.get("/v1/position/history")

        self.assertEqual(response.status_code, 200)
        row = response.data["data"]["items"][0]
        for field in ("pnl", "realized_pnl", "close_price", "fee", "funding_fee"):
            with self.subTest(field=field):
                self.assertIsNone(row[field])
        self.order.refresh_from_db()
        self.assertIsNone(self.order.pnl)
