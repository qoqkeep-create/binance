from decimal import Decimal
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from django.test import TestCase

from positions.models import Order
from trading.services import _adopt_tighter_exchange_stop, _reconcile_stop_loss_protection
from users.models import User


class ManualStopForwardRegressionTests(TestCase):
    def _order(self, *, side: int):
        initial = Decimal("90") if side == 0 else Decimal("110")
        return Order.objects.create(
            user=User.objects.create_user(
                email=f"manual-stop-{side}@example.com", password="test-only"
            ),
            binance_order_id=f"manual-stop-{side}",
            binance_stop_market_order_id="old-stop",
            symbol="BTCUSDT",
            side=side,
            open_price=Decimal("100"),
            initial_stop_price=initial,
            stop_loss_price=initial,
            current_stop_price=initial,
            stop_loss_amount=Decimal("10"),
            size=Decimal("1"),
            leverage=10,
            status=0,
        )

    def _snapshot(self, *, side: int, moved_price: str):
        return SimpleNamespace(
            client=MagicMock(),
            pos_mode="long_short_mode",
            positions=[],
            close_trade_rows={},
            algo_map={
                "new-stop": {
                    "algoId": "new-stop",
                    "instId": "BTC-USDT-SWAP",
                    "algoType": "STOP_MARKET",
                    "side": "sell" if side == 0 else "buy",
                    "posSide": "long" if side == 0 else "short",
                    "state": "live",
                    "sz": "1",
                    "slTriggerPx": moved_price,
                }
            },
        )

    @patch("trading.services._get_instrument_trade_rules", return_value={
        "tickSz": Decimal("0.1"),
        "marketLotSz": Decimal("0.001"),
        "marketMinSz": Decimal("0.001"),
    })
    @patch("trading.services._rebuild_stop_loss_for_remaining_position", return_value=False)
    def test_long_manual_forward_stop_is_adopted(self, _rebuild, _rules):
        order = self._order(side=0)
        snapshot = self._snapshot(side=0, moved_price="95")

        _reconcile_stop_loss_protection(
            order=order,
            snapshot=snapshot,
            strategy_snapshot=None,
            exchange_size=Decimal("1"),
            current_price=Decimal("105"),
            stop_price=Decimal("90"),
        )

        order.refresh_from_db()
        self.assertEqual(order.initial_stop_price, Decimal("90"))
        self.assertEqual(order.current_stop_price, Decimal("95"))
        self.assertEqual(order.stop_loss_price, Decimal("95"))
        self.assertEqual(order.binance_stop_market_order_id, "new-stop")

    @patch("trading.services._get_instrument_trade_rules", return_value={
        "tickSz": Decimal("0.1"),
        "marketLotSz": Decimal("0.001"),
        "marketMinSz": Decimal("0.001"),
    })
    @patch("trading.services._rebuild_stop_loss_for_remaining_position", return_value=False)
    def test_short_manual_forward_stop_is_adopted(self, _rebuild, _rules):
        order = self._order(side=1)
        snapshot = self._snapshot(side=1, moved_price="105")

        _reconcile_stop_loss_protection(
            order=order,
            snapshot=snapshot,
            strategy_snapshot=None,
            exchange_size=Decimal("1"),
            current_price=Decimal("95"),
            stop_price=Decimal("110"),
        )

        order.refresh_from_db()
        self.assertEqual(order.initial_stop_price, Decimal("110"))
        self.assertEqual(order.current_stop_price, Decimal("105"))
        self.assertEqual(order.stop_loss_price, Decimal("105"))
        self.assertEqual(order.binance_stop_market_order_id, "new-stop")

    def test_looser_exchange_stop_never_overwrites_forwarded_local_stop(self):
        order = self._order(side=0)
        order.current_stop_price = Decimal("95")
        order.stop_loss_price = Decimal("95")
        order.binance_stop_market_order_id = "forwarded-stop"
        order.save(update_fields=[
            "current_stop_price", "stop_loss_price", "binance_stop_market_order_id",
        ])
        adopted = _adopt_tighter_exchange_stop(
            order,
            [{
                "algoId": "older-stop",
                "algoType": "STOP_MARKET",
                "state": "live",
                "sz": "1",
                "slTriggerPx": "90",
            }],
            local_stop=Decimal("95"),
            exchange_size=Decimal("1"),
        )
        self.assertIsNone(adopted)
        order.refresh_from_db()
        self.assertEqual(order.current_stop_price, Decimal("95"))
        self.assertEqual(order.stop_loss_price, Decimal("95"))
        self.assertEqual(order.binance_stop_market_order_id, "forwarded-stop")
