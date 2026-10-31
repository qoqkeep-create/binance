from datetime import timedelta
from decimal import Decimal
from unittest.mock import MagicMock, patch

from django.core.cache import cache
from django.db import connection
from django.test.utils import CaptureQueriesContext
from rest_framework.test import APITestCase
from django.utils import timezone

from api_bindings.models import ApiBinding
from common.binance import BinanceApiError
from positions import views
from positions.cleanup import ClosedOrderCleanupResult
from positions.models import Order, OrderStrategyLog, OrderStrategySnapshot, TradeNotificationEvent
from users.models import User


def empty_cleanup_result():
    return ClosedOrderCleanupResult("", "", [], "", [], [], [], False)


class PositionReviewRegressionTests(APITestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(email="review-position@example.com", password="test")
        self.client.force_authenticate(self.user)
        self.binding = ApiBinding.objects.create(
            user=self.user, api_key="synthetic", secret_key="synthetic", passphrase="",
            api_key_fingerprint="review-current", alias="synthetic",
        )
        self.order = self.make_order()

    def make_order(self, **overrides):
        values = dict(
            user=self.user, api_key_fingerprint="review-current", symbol="BTCUSDT", side=0,
            binance_order_id="entry-review", open_price=Decimal("100"),
            stop_loss_price=Decimal("90"), stop_loss_amount=Decimal("10"),
            size=Decimal("1"), leverage=10,
        )
        values.update(overrides)
        return Order.objects.create(**values)

    def strategy_snapshot(self, order=None):
        order = order or self.order
        snapshot = OrderStrategySnapshot.objects.create(
            order=order, user=self.user, strategy_name="review", strategy_config=[],
        )
        order.strategy_snapshot_id = snapshot.id
        order.save(update_fields=["strategy_snapshot_id"])
        return snapshot

    def log(self, snapshot, desc, *, error="", result="成功"):
        return OrderStrategyLog.objects.create(
            order_id=snapshot.order_id, snapshot=snapshot, behavior_desc=desc,
            error=error, result=result,
        )

    def test_manual_close_supplies_local_direction_in_net_mode(self):
        client = MagicMock()
        client.get_account_config.return_value = {"data": [{"posMode": "net_mode"}]}
        client.get_positions.return_value = {"data": [{
            "instId": "BTC-USDT-SWAP", "posSide": "net", "pos": "-1", "avgPx": "100",
        }]}
        client.close_position.side_effect = BinanceApiError("持仓方向不匹配")
        with patch.object(views, "get_user_binance_credentials", return_value=object()), \
                patch.object(views, "BinanceFuturesClient", return_value=client), \
                patch.object(views, "_confirm_manual_close", return_value=False):
            response = self.client.post("/v1/position/close", {"position_id": self.order.id})
        self.assertEqual(response.status_code, 400)
        self.assertEqual(client.close_position.call_args.kwargs.get("expected_side"), "long")
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, 0)

    def test_zero_realized_profit_is_not_replaced_by_last_fill_price(self):
        self.order.close_binance_order_id = "final-close"
        self.order.save(update_fields=["close_binance_order_id"])
        rows = dict(
            trade_rows=[
                dict(ordId="partial", fillSz="0.5", fillPx="110", realizedPnl="5", fee="0.1"),
                dict(ordId="final-close", fillSz="0.5", fillPx="90", realizedPnl="-5", fee="0.1"),
            ],
            entry_trade_rows=[dict(fee="0.1")], bill_rows=[], is_fully_closed=True,
        )
        self.assertTrue(views._reconcile_order_settlement(
            order=self.order, client=MagicMock(), close_price=Decimal("90"), exchange_rows=rows,
        ))
        self.assertEqual(self.order.realized_pnl, Decimal("0"))
        self.assertEqual(self.order.pnl, Decimal("-0.3"))

    def test_explicit_zero_trade_profit_and_fee_win_over_adjacent_bills(self):
        rows = {"rows_by_order_id": {self.order.id: {
            "trade_rows": [dict(realizedPnl="0", fee="0")],
            "entry_trade_rows": [dict(fee="0")],
            "bill_rows": [dict(type="REALIZED_PNL", pnl="20"), dict(type="COMMISSION", pnl="-2")],
        }}}
        result = views._build_order_history_financials(self.order, rows)
        self.assertEqual(result["realized_pnl"], Decimal("0"))
        self.assertEqual(result["fee"], Decimal("0"))
        self.assertEqual(result["source_flags"]["realized_pnl"], "binance_trade")

    def test_missing_trade_financial_fields_still_fall_back_to_bills(self):
        rows = {"rows_by_order_id": {self.order.id: {
            "trade_rows": [dict(fillSz="1")],
            "bill_rows": [dict(type="REALIZED_PNL", pnl="20"), dict(type="COMMISSION", pnl="-2")],
        }}}
        result = views._build_order_history_financials(self.order, rows)
        self.assertEqual(result["realized_pnl"], Decimal("20"))
        self.assertEqual(result["fee"], Decimal("-2"))

    def test_nonfinite_trade_fields_use_bill_fallback_before_arithmetic(self):
        self.order.close_binance_order_id = "final-close"
        self.order.save(update_fields=["close_binance_order_id"])
        for field in ("realizedPnl", "fee"):
            for values in (["sNaN"], ["Infinity", "-Infinity"]):
                trades = [{
                    "ordId": "final-close", "fillSz": str(Decimal("1") / len(values)),
                    "fillPx": "100", "realizedPnl": "0", "fee": "0", field: value,
                } for value in values]
                rows = dict(
                    trade_rows=trades, entry_trade_rows=[dict(fee="0")],
                    bill_rows=[dict(type="REALIZED_PNL", pnl="5"), dict(type="COMMISSION", pnl="-1")],
                    is_fully_closed=True,
                )
                expected_pnl = Decimal("5") if field == "realizedPnl" else Decimal("0")
                expected_fee = Decimal("-1") if field == "fee" else Decimal("0")
                with self.subTest(field=field, values=values, path="history"):
                    result = views._build_order_history_financials(
                        self.order, {"rows_by_order_id": {self.order.id: rows}},
                    )
                    self.assertEqual(result["realized_pnl"], expected_pnl)
                    self.assertEqual(result["fee"], expected_fee)
                    source_field = "realized_pnl" if field == "realizedPnl" else "fee"
                    self.assertEqual(result["source_flags"][source_field], "binance_bill")
                with self.subTest(field=field, values=values, path="settlement"):
                    self.assertTrue(views._reconcile_order_settlement(
                        order=self.order, client=MagicMock(), close_price=Decimal("100"), exchange_rows=rows,
                    ))
                    self.assertEqual(self.order.realized_pnl, expected_pnl)
                    self.assertEqual(self.order.realized_fee, expected_fee)
                    self.assertEqual(self.order.settlement_status, Order.SETTLEMENT_STATUS_ESTIMATED)
                    self.assertIn("来自时间窗口账单", self.order.settlement_error)

    def test_complete_zero_settlement_is_confirmed_but_missing_fee_stays_estimated(self):
        self.order.close_binance_order_id = "final-close"
        self.order.save(update_fields=["close_binance_order_id"])
        rows = dict(
            trade_rows=[dict(ordId="final-close", fillSz="1", fillPx="100", realizedPnl="0", fee="0")],
            entry_trade_rows=[dict(fee="0")], bill_rows=[], is_fully_closed=True,
        )
        self.assertTrue(views._reconcile_order_settlement(
            order=self.order, client=MagicMock(), close_price=Decimal("100"), exchange_rows=rows,
        ))
        self.assertEqual(self.order.settlement_status, Order.SETTLEMENT_STATUS_SETTLED)
        self.assertEqual(self.order.realized_fee, Decimal("0"))
        del rows["trade_rows"][0]["fee"]
        self.assertTrue(views._reconcile_order_settlement(
            order=self.order, client=MagicMock(), close_price=Decimal("100"), exchange_rows=rows,
        ))
        self.assertEqual(self.order.settlement_status, Order.SETTLEMENT_STATUS_ESTIMATED)
        self.assertIn("缺少手续费", self.order.settlement_error)

    def test_known_zero_local_profit_is_not_rederived(self):
        self.order.realized_pnl = Decimal("0")
        self.order.close_price = Decimal("110")
        result = views._serialize_history_order(self.order, set(), {})
        self.assertEqual(result["realized_pnl"], "0.00000000")

    def test_entry_fee_missing_fields_remain_pending_while_explicit_zero_confirms(self):
        client = MagicMock()
        for fee in (None, "", "invalid"):
            with self.subTest(fee=fee):
                client.get_user_trades.return_value = {"data": [
                    dict(ordId=self.order.binance_order_id, fillSz="0.5", fee="0.1"),
                    dict(ordId=self.order.binance_order_id, fillSz="0.5", fee=fee),
                ]}
                self.assertFalse(views._sync_entry_fee_for_order(self.order, client))
                self.order.refresh_from_db()
                self.assertEqual(self.order.entry_fee_status, Order.ENTRY_FEE_STATUS_PENDING)
                self.assertIsNone(self.order.entry_realized_fee)
        client.get_user_trades.return_value = {"data": [
            dict(ordId=self.order.binance_order_id, fillSz="1", fee="0", feeCcy="USDT"),
        ]}
        self.assertTrue(views._sync_entry_fee_for_order(self.order, client))
        self.assertEqual(self.order.entry_realized_fee, Decimal("0"))
        self.assertEqual(self.order.entry_fee_status, Order.ENTRY_FEE_STATUS_CONFIRMED)

    def test_strategy_log_preserves_failure_after_recovery(self):
        snapshot = self.strategy_snapshot()
        failed = self.log(snapshot, "止损保护待恢复", error="余额不足", result="失败")
        self.log(snapshot, "止损保护待恢复", error="余额不足", result="失败")
        recovered = self.log(snapshot, "止损保护已恢复")
        failed_again = self.log(snapshot, "止损保护待恢复", error="余额不足", result="失败")
        response = self.client.get("/v1/strategy/log", {"position_id": self.order.id})
        self.assertEqual([row["id"] for row in response.data["data"]["logs"]],
                         [failed.id, recovered.id, failed_again.id])

    def test_strategy_summary_is_one_query_and_recovery_clears_only_visible_errors(self):
        snapshot = self.strategy_snapshot()
        self.log(snapshot, "止损保护待恢复", error="余额不足", result="失败")
        self.log(snapshot, "止损保护已恢复")
        self.log(snapshot, "临时通信失败", error="connection timeout", result="失败")
        second = self.make_order(binance_order_id="entry-second")
        second_snapshot = self.strategy_snapshot(second)
        self.log(second_snapshot, "移动止损失败", error="保证金不足", result="失败")
        self.log(second_snapshot, "策略继续运行")
        self.log(second_snapshot, "", result="失败")
        old_snapshot = OrderStrategySnapshot.objects.create(
            order=second, user=self.user, strategy_name="old", strategy_config=[],
        )
        self.log(old_snapshot, "止损保护已恢复")
        with self.assertNumQueries(1):
            summaries = views._latest_strategy_errors([self.order.id, second.id])
        self.assertEqual(summaries[self.order.id], "")
        self.assertEqual(summaries[second.id], "保证金不足")
        self.log(snapshot, "止损保护待恢复", error="余额不足", result="失败")
        self.assertEqual(views._latest_strategy_errors([self.order.id])[self.order.id], "余额不足")
        other_user = User.objects.create_user(email="review-summary-other@example.com", password="test")
        for owner, snapshot_order in ((other_user, second), (self.user, self.order)):
            with self.subTest(owner_id=owner.id, snapshot_order_id=snapshot_order.id):
                invalid_snapshot = OrderStrategySnapshot.objects.create(
                    order=snapshot_order, user=owner, strategy_name="invalid", strategy_config=[],
                )
                second.strategy_snapshot_id = invalid_snapshot.id
                second.save(update_fields=["strategy_snapshot_id"])
                OrderStrategyLog.objects.create(
                    order=second, snapshot=invalid_snapshot, behavior_desc="移动止损失败",
                    error="不应展示其他归属的错误", result="失败",
                )
                self.assertEqual(views._latest_strategy_errors([second.id])[second.id], "")

    def test_history_serializes_and_supplements_only_visible_closed_orders(self):
        self.order.delete()
        now = timezone.now()
        orders = [self.make_order(
            binance_order_id=f"history-{index}", status=1, closed_at=now - timedelta(minutes=index),
        ) for index in range(1000)]
        with patch.object(views, "_load_history_exchange_rows", return_value={}) as load, \
                patch.object(views, "_load_history_position_rows", return_value={}), \
                patch.object(views, "_serialize_history_order", wraps=views._serialize_history_order) as serialize, \
                CaptureQueriesContext(connection) as captured:
            response = self.client.get("/v1/position/history", {"page": 3, "page_size": 20})
        data = response.data["data"]
        self.assertEqual(data["pagination"]["total"], 1000)
        self.assertEqual([item["id"] for item in data["items"]], [order.id for order in orders[40:60]])
        self.assertEqual(serialize.call_count, 20)
        supplemented = [order for call in load.call_args_list for order in call.args[1]]
        self.assertEqual([order.id for order in supplemented], [order.id for order in orders[40:60]])
        windows = [query["sql"] for query in captured if "history_closed_at" in query["sql"]]
        self.assertEqual(len(windows), 1)
        self.assertIn("LIMIT 20", windows[0].upper())
        self.assertIn("OFFSET 40", windows[0].upper())

    def test_history_merges_reductions_across_pages_with_stable_ties(self):
        now = timezone.now().replace(microsecond=0)
        closed = [self.make_order(
            binance_order_id=f"closed-{index}", status=1, closed_at=now - timedelta(minutes=index),
        ) for index in range(5)]
        self.order.exchange_size = Decimal("0.5")
        self.order.save(update_fields=["exchange_size"])
        reduction_time = now - timedelta(minutes=1)
        expected = sorted([*( (order.closed_at, order.id) for order in closed),
                           (reduction_time, self.order.id)], reverse=True)

        def exchange_rows(_user, orders, **_kwargs):
            return {"rows_by_order_id": {order.id: {"trade_rows": [dict(
                fillSz="0.5", fillPx="110", realizedPnl="5", fee="0.1",
                time=str(int(reduction_time.timestamp() * 1000)),
            )]} for order in orders if order.status == 0}}

        with patch.object(views, "_load_history_exchange_rows", side_effect=exchange_rows), \
                patch.object(views, "_load_history_position_rows", return_value={}):
            for page in range(1, 4):
                response = self.client.get("/v1/position/history", {"page": page, "page_size": 2})
                data = response.data["data"]
                self.assertEqual(data["pagination"]["total"], 6)
                self.assertEqual([item["id"] for item in data["items"]],
                                 [order_id for _, order_id in expected[(page - 1) * 2:page * 2]])

    def test_history_legacy_probe_only_matches_real_active_direction(self):
        stale = self.make_order(binance_order_id="stale-short", side=1)
        stale_other = self.make_order(binance_order_id="stale-eth", symbol="ETHUSDT")
        live_positions = {("BTC-USDT-SWAP", "long"): {"upl": "1"}}
        with patch.object(views, "_load_history_position_rows", return_value=live_positions), \
                patch.object(views, "_load_history_exchange_rows", return_value={}) as load:
            self.client.get("/v1/position/history")
        supplemented = {order.id for call in load.call_args_list for order in call.args[1]}
        self.assertIn(self.order.id, supplemented)
        self.assertNotIn(stale.id, supplemented)
        self.assertNotIn(stale_other.id, supplemented)

    def test_reduction_evidence_without_receipt_does_not_invent_history_financials(self):
        TradeNotificationEvent.objects.create(
            order=self.order, event_key="review-reduction", event_type="reduction", title="减仓", content="",
        )
        with patch.object(views, "_load_history_position_rows", return_value={}), \
                patch.object(views, "_load_history_exchange_rows", return_value={}) as load:
            response = self.client.get("/v1/position/history")
        self.assertEqual(response.data["data"]["pagination"]["total"], 0)
        self.assertTrue(any(self.order.id in [order.id for order in call.args[1]]
                            for call in load.call_args_list))

    def test_stale_bindings_cannot_occupy_maintenance_batch(self):
        stale = self.make_order(api_key_fingerprint="old-key", binance_order_id="old-entry")
        now = timezone.now()
        Order.objects.filter(pk=stale.pk).update(created_at=now - timedelta(days=2))
        client = MagicMock()
        client.get_account_config.return_value = {"data": [{"posMode": "net_mode"}]}
        client.get_positions.return_value = {"data": []}
        client.get_user_trades.return_value = {"data": []}
        with patch.object(views, "_credentials_for_binding_generation", return_value=object()), \
                patch.object(views, "BinanceFuturesClient", return_value=client), \
                patch.object(views, "_sync_entry_fee_for_order", return_value=True) as fee, \
                patch.object(views, "_auto_close_missing_exchange_order", return_value=True) as close:
            self.assertEqual(views.sync_pending_entry_fees(limit=1), 1)
            self.assertEqual(fee.call_args.args[0].id, self.order.id)
            self.assertEqual(views.reconcile_stale_open_orders(limit=1), 1)
            self.assertEqual(close.call_args.args[0].id, self.order.id)
            Order.objects.filter(pk__in=[self.order.pk, stale.pk]).update(
                status=1, closed_at=now - timedelta(minutes=10), binance_stop_order_id="remaining-stop",
            )
            with patch.object(views, "_reconcile_order_settlement", return_value=True) as settle, \
                    patch.object(views, "_has_nearby_close_trade", return_value=False) as audit, \
                    patch.object(views, "cleanup_closed_order_exchange_artifacts", return_value=empty_cleanup_result()) as cleanup:
                self.assertEqual(views.reconcile_pending_order_settlements(limit=1), 1)
                self.assertEqual(settle.call_args.kwargs["order"].id, self.order.id)
                self.assertEqual(views.audit_suspicious_closed_orders(limit=1), 1)
                self.assertEqual(audit.call_args.args[0].id, self.order.id)
                self.assertEqual(views.reconcile_closed_order_exchange_artifacts(limit=1), 1)
                self.assertEqual(cleanup.call_args.args[0].id, self.order.id)

    def test_maintenance_excludes_disabled_missing_and_previous_legacy_generations(self):
        old_legacy = self.make_order(api_key_fingerprint=None, binance_order_id="old-legacy")
        Order.objects.filter(pk=old_legacy.pk).update(created_at=self.binding.created_at - timedelta(seconds=1))
        new_legacy = self.make_order(api_key_fingerprint=None, binance_order_id="new-legacy")
        selected = set(views._maintenance_eligible_orders(Order.objects.all()).values_list("id", flat=True))
        self.assertEqual(selected, {self.order.id, new_legacy.id})
        ApiBinding.objects.filter(pk=self.binding.pk).update(status=0)
        self.assertFalse(views._maintenance_eligible_orders(Order.objects.all()).exists())
        self.binding.delete()
        self.assertFalse(views._maintenance_eligible_orders(Order.objects.all()).exists())

    def test_maintenance_identity_matrix_matches_user_mode_and_legacy_boundary(self):
        lead_binding = ApiBinding.objects.create(
            user=self.user, trading_mode="lead", api_key_fingerprint="review-lead",
            api_key="synthetic", secret_key="synthetic", passphrase="", alias="synthetic",
        )
        other_user = User.objects.create_user(email="review-maintenance-other@example.com", password="test")
        other_binding = ApiBinding.objects.create(
            user=other_user, api_key_fingerprint="review-other",
            api_key="synthetic", secret_key="synthetic", passphrase="", alias="synthetic",
        )
        lead_order = self.make_order(
            trading_mode="lead", api_key_fingerprint=lead_binding.api_key_fingerprint, binance_order_id="lead-current",
        )
        other_order = self.make_order(
            user=other_user, api_key_fingerprint=other_binding.api_key_fingerprint, binance_order_id="other-current",
        )
        self.make_order(user=other_user, binance_order_id="foreign-user-same-fingerprint")
        self.make_order(trading_mode="lead", binance_order_id="foreign-mode-same-fingerprint")
        self.make_order(trading_mode="lead", api_key_fingerprint=None, binance_order_id="lead-without-fingerprint")
        legacy_boundary = self.make_order(api_key_fingerprint=None, binance_order_id="legacy-at-binding-boundary")
        Order.objects.filter(pk=legacy_boundary.pk).update(created_at=self.binding.created_at)
        selected = set(views._maintenance_eligible_orders(Order.objects.all()).values_list("id", flat=True))
        self.assertEqual(selected, {self.order.id, lead_order.id, other_order.id, legacy_boundary.id})

    def test_cleaned_orders_cannot_starve_residual_artifact_queue(self):
        now = timezone.now()
        self.order.status = 1
        self.order.closed_at = now - timedelta(minutes=2)
        self.order.binance_stop_order_id = "remaining-stop"
        self.order.save(update_fields=["status", "closed_at", "binance_stop_order_id"])
        self.make_order(binance_order_id="already-cleaned", status=1, closed_at=now)
        with patch.object(views, "_credentials_for_binding_generation", return_value=object()), \
                patch.object(views, "BinanceFuturesClient"), \
                patch.object(views, "cleanup_closed_order_exchange_artifacts", return_value=empty_cleanup_result()) as cleanup:
            self.assertEqual(views.reconcile_closed_order_exchange_artifacts(limit=1), 1)
        self.assertEqual(cleanup.call_args.args[0].id, self.order.id)
