from decimal import Decimal
from unittest.mock import patch

from django.test import TestCase

from common.binance import BinanceCredentials, BinanceFuturesClient
from positions.models import Order
from trading.services import ProtectionAccountSnapshot, _emergency_close_unprotected_position
from trading.views import _emergency_close_position
from users.models import User


class WebCloseDirectionTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(email="close-direction@example.invalid", password="test-only")
        self.order = Order.objects.create(
            user=self.user, symbol="BTCUSDT", side=0, binance_order_id="test-entry",
            open_price=Decimal("100"), stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("10"), size=Decimal("1"), leverage=1,
        )
        self.exchange = BinanceFuturesClient(BinanceCredentials(api_key="test", secret_key="test"))
        self.reverse = {
            "instId": "BTC-USDT-SWAP", "posSide": "short", "pos": "-1", "rawPositionSide": "BOTH",
        }

    @patch("trading.views._resolve_pos_side", return_value=None)
    @patch("trading.views.time.sleep")
    def test_entry_emergency_close_does_not_close_a_new_reverse_net_position(self, _sleep, _side):
        with patch.object(self.exchange, "get_positions", return_value={"data": [self.reverse]}), patch.object(
            self.exchange, "_normalize_order_quantity", side_effect=lambda _inst, qty, _kind: qty,
        ), patch.object(self.exchange, "_request", return_value={}) as write:
            confirmed, _receipt = _emergency_close_position(self.exchange, "BTC-USDT-SWAP", 0)

        self.assertTrue(confirmed)
        write.assert_not_called()

    @patch("trading.services.finalize_confirmed_emergency_close")
    @patch("trading.services.time.sleep")
    def test_protection_emergency_close_does_not_close_a_new_reverse_net_position(self, _sleep, finalize):
        snapshot = ProtectionAccountSnapshot(
            client=self.exchange, pos_mode="net_mode",
            positions=[{"instId": "BTC-USDT-SWAP", "posSide": "long", "pos": "1", "markPx": "89"}],
            algo_map={}, close_trade_rows={},
        )
        with patch.object(self.exchange, "get_positions", return_value={"data": [self.reverse]}), patch.object(
            self.exchange, "_normalize_order_quantity", side_effect=lambda _inst, qty, _kind: qty,
        ), patch.object(self.exchange, "_request", return_value={}) as write:
            changed = _emergency_close_unprotected_position(self.order, snapshot, Decimal("90"))

        self.assertEqual(changed, 1)
        write.assert_not_called()
        finalize.assert_called_once()
