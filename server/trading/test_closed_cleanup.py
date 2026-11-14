from datetime import timedelta
from decimal import Decimal
from time import time
from unittest.mock import MagicMock, patch

from django.core.cache import cache
from django.test import TestCase

from positions.models import Order, OrderStrategySnapshot, TradeNotificationEvent
from trading.services import (
    _close_fully_offset_order,
    reconcile_open_orders_protection,
    run_strategy_engine,
)
from users.models import User


class ClosedPositionCleanupTests(TestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(email="closed-cleanup@example.com", password="123456")
        self.order = Order.objects.create(
            user=self.user,
            binance_order_id="entry-short",
            binance_stop_market_order_id="old-stop",
            strategy_tp_algo_ids=["old-profit"],
            symbol="ZECUSDT",
            side=1,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("110"),
            current_stop_price=Decimal("110"),
            stop_loss_amount=Decimal("10"),
            size=Decimal("1"),
            exchange_size=Decimal("1"),
            leverage=10,
            status=0,
            strategy_status=Order.STRATEGY_STATUS_RUNNING,
        )
        strategy = OrderStrategySnapshot.objects.create(
            order=self.order,
            user=self.user,
            strategy_id="cleanup-strategy",
            strategy_name="平仓清理测试",
            strategy_config=[{"profitRR": 1, "reducePosition": 50, "stopLossType": "none"}],
        )
        self.order.strategy_snapshot_id = strategy.id
        self.order.save(update_fields=["strategy_snapshot_id"])
        self.client = MagicMock()
        self.client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        self.client.get_positions.return_value = {"code": "0", "data": []}
        self.client.get_pending_orders.return_value = {"code": "0", "data": []}
        self.client.get_algo_order.return_value = {"code": "0", "data": []}
        self.algos = {
            algo_id: {
                "algoId": algo_id, "instId": "ZEC-USDT-SWAP", "state": "live",
                "posSide": "short" if algo_id != "new-long-stop" else "long",
            }
            for algo_id in ("old-stop", "old-profit", "new-long-stop")
        }
        self.client.get_pending_algo_orders.side_effect = lambda *args, **kwargs: {
            "code": "0", "data": list(self.algos.values()),
        }

        def cancel(*, algo_id, inst_id):
            self.algos.pop(algo_id, None)
            return {"code": "0", "data": [{"algoId": algo_id}]}

        self.client.cancel_algos.side_effect = cancel
        self.client.get_user_trades.return_value = {"code": "0", "data": []}
        for target, value in (
            ("trading.services.get_user_binance_credentials", object()),
            ("trading.services.BinanceFuturesClient", self.client),
        ):
            patcher = patch(target, return_value=value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def _close_rows(self, quantity="1"):
        return [{
            "ordId": "close-short", "instId": "ZEC-USDT-SWAP",
            "rawPositionSide": "SHORT", "side": "buy", "fillSz": quantity,
            "fillPx": "95", "realizedPnl": "5", "fee": "0.1",
            "time": str(int((self.order.created_at + timedelta(seconds=1)).timestamp() * 1000)),
        }]

    def _assert_closed_and_scoped_cleanup(self):
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, 1)
        self.assertEqual(self.order.close_binance_order_id, "close-short")
        self.assertEqual(self.order.exchange_size, Decimal("0"))
        self.assertEqual(self.order.binance_stop_market_order_id, "")
        self.assertEqual(self.order.strategy_tp_algo_ids, [])
        self.assertEqual(set(self.algos), {"new-long-stop"})
        self.assertEqual(
            {c.kwargs["algo_id"] for c in self.client.cancel_algos.call_args_list},
            {"old-stop", "old-profit"},
        )
        self.assertEqual(TradeNotificationEvent.objects.filter(order=self.order).count(), 1)
        self.client.close_position.assert_not_called()
        self.client.place_stop_loss_order.assert_not_called()

    def test_protection_closes_empty_position_after_recent_live_position_check(self):
        self.assertFalse(_close_fully_offset_order(self.order, self.client, source="test-live"))
        self.client.get_user_trades.return_value = {"code": "0", "data": self._close_rows()}

        self.assertEqual(reconcile_open_orders_protection(), 1)

        self._assert_closed_and_scoped_cleanup()
        self.assertEqual(self.client.get_user_trades.call_count, 2)
        self.assertEqual(reconcile_open_orders_protection(), 0)
        self.assertEqual(self.client.cancel_algos.call_count, 2)

    def test_protection_closes_short_and_preserves_reopened_long(self):
        self.client.get_positions.return_value = {"code": "0", "data": [{
            "instId": "ZEC-USDT-SWAP", "posSide": "long", "pos": "2", "last": "95",
        }]}
        self.client.get_user_trades.return_value = {"code": "0", "data": self._close_rows()}

        self.assertEqual(reconcile_open_orders_protection(), 1)

        self._assert_closed_and_scoped_cleanup()

    def test_strategy_closes_empty_position_after_recent_live_position_check(self):
        self.assertFalse(_close_fully_offset_order(self.order, self.client, source="test-live"))
        self.client.get_user_trades.return_value = {"code": "0", "data": self._close_rows()}

        self.assertEqual(run_strategy_engine(), 0)

        self._assert_closed_and_scoped_cleanup()
        self.assertEqual(self.client.get_user_trades.call_count, 2)
        self.client.get_mark_price_candles.assert_not_called()

    def test_empty_snapshot_requires_complete_close_evidence_and_throttles_rechecks(self):
        self.client.get_user_trades.return_value = {"code": "0", "data": self._close_rows("0.5")}
        with patch("trading.services._process_single_strategy_order") as process:
            self.assertEqual(reconcile_open_orders_protection(), 0)
            self.assertEqual(run_strategy_engine(), 0)
            self.assertEqual(reconcile_open_orders_protection(), 0)
            process.assert_not_called()

        self.assertEqual(self.client.get_user_trades.call_count, 1)
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, 0)
        self.assertEqual(self.order.binance_stop_market_order_id, "old-stop")
        self.assertEqual(self.order.strategy_tp_algo_ids, ["old-profit"])
        self.client.cancel_algos.assert_not_called()
        self.client.close_position.assert_not_called()
        self.assertFalse(TradeNotificationEvent.objects.filter(order=self.order).exists())

        self.client.get_user_trades.return_value = {"code": "0", "data": self._close_rows()}
        with patch("django.core.cache.backends.locmem.time.time", return_value=time() + 31):
            self.assertEqual(reconcile_open_orders_protection(), 1)
        self.assertEqual(self.client.get_user_trades.call_count, 2)
        self._assert_closed_and_scoped_cleanup()
