"""Server-side convergence of non-terminal open requests.

A filled or definitively ended exchange order must never wait for a user to
open a page. These tests use exchange stubs only; no real orders are placed.
"""
from decimal import Decimal
from types import SimpleNamespace
from unittest.mock import MagicMock, Mock, patch

from django.core.cache import cache
from django.test import TestCase

from api_bindings.context import build_trading_account_identity
from api_bindings.models import ApiBinding
from common.binance import BinanceApiError
from positions.models import Order
from trading.models import TradeOpenRequest
from trading.views import reconcile_open_requests
from users.models import User


class OpenRequestReconcileTests(TestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(
            email="open-reconcile@example.com", password="test-only", stop_loss_amount=Decimal("100"),
        )
        self.binding = ApiBinding.objects.create(
            user=self.user, trading_mode="ordinary", api_key_fingerprint="fp-open-reconcile",
            api_key="unused-test-placeholder", secret_key="unused-test-placeholder",
            passphrase="", alias="test account", status=1,
        )
        self.exchange = MagicMock()
        self.account = SimpleNamespace(
            user_id=self.user.id, trading_mode="ordinary", api_key_fingerprint="fp-open-reconcile",
            binding_created_at=self.binding.created_at,
            generation=("fp-open-reconcile", self.binding.created_at),
            identity=build_trading_account_identity(
                user_id=self.user.id, api_key_fingerprint="fp-open-reconcile", trading_mode="ordinary",
            ),
            create_futures_client=Mock(return_value=self.exchange),
        )
        factory = patch(
            "trading.views.get_user_trading_account", return_value=self.account,
        )
        factory.start()
        self.addCleanup(factory.stop)
        network = patch(
            "requests.sessions.Session.request",
            side_effect=AssertionError("tests must not access network"),
        )
        network.start()
        self.addCleanup(network.stop)
        instrument = patch(
            "trading.views._extract_instrument", return_value={"ctVal": "1"},
        )
        instrument.start()
        self.addCleanup(instrument.stop)
        protection = patch(
            "trading.views._resolve_entry_stop_protection", return_value=(None, None),
        )
        protection.start()
        self.addCleanup(protection.stop)
        converge = patch("trading.services._converge_stop_loss_order")
        converge.start()
        self.addCleanup(converge.stop)

    def request(self, status=TradeOpenRequest.STATUS_SUBMITTED, *, order_id="ex-1", payload=None):
        intent = {
            "execution_mode": "maker",
            "side_code": 0,
            "size": "1",
            "stop_loss_price": "90",
            "stop_loss_amount": "100",
            "leverage": 10,
        }
        return TradeOpenRequest.objects.create(
            user=self.user, api_key_fingerprint="fp-open-reconcile", symbol="BTCUSDT",
            client_request_id=f"req-{TradeOpenRequest.objects.count()}",
            client_order_id=f"client-{TradeOpenRequest.objects.count()}",
            binance_order_id=order_id, status=status,
            request_payload={"_execution_intent": intent, **(payload or {})},
        )

    def filled_row(self, **extra):
        row = {"state": "filled", "ordId": "ex-1", "fillSz": "1", "accFillSz": "1", "avgPx": "100"}
        row.update(extra)
        return {"data": [row]}

    def test_confirmed_fill_is_adopted_without_client_interaction(self):
        open_request = self.request()
        self.exchange.get_order.return_value = self.filled_row()
        self.assertEqual(reconcile_open_requests(), 1)
        open_request.refresh_from_db()
        order = Order.objects.get()
        self.assertEqual(order.position_origin, Order.ORIGIN_WEB)
        self.assertEqual(order.binance_order_id, "ex-1")
        self.assertEqual(open_request.order_id, order.id)
        self.assertEqual(Order.objects.count(), 1)
        # A second round must not duplicate the position; linked requests are
        # skipped entirely, so no exchange read is repeated for them.
        self.assertEqual(reconcile_open_requests(), 0)
        self.assertEqual(Order.objects.count(), 1)

    def test_terminal_zero_fill_releases_the_request(self):
        open_request = self.request()
        self.exchange.get_order.return_value = {
            "data": [{"state": "canceled", "ordId": "ex-1", "fillSz": "0", "accFillSz": "0", "avgPx": "0"}]
        }
        reconcile_open_requests()
        open_request.refresh_from_db()
        self.assertEqual(open_request.status, TradeOpenRequest.STATUS_FAILED)
        self.assertEqual(Order.objects.count(), 0)

    def test_definitively_absent_order_releases_the_request(self):
        open_request = self.request()
        self.exchange.get_order.side_effect = BinanceApiError("Order does not exist", code="-2013")
        reconcile_open_requests()
        open_request.refresh_from_db()
        self.assertEqual(open_request.status, TradeOpenRequest.STATUS_FAILED)

    def test_live_order_keeps_waiting_without_local_position(self):
        open_request = self.request()
        self.exchange.get_order.return_value = {
            "data": [{"state": "live", "ordId": "ex-1", "fillSz": "0", "accFillSz": "0", "avgPx": "0"}]
        }
        reconcile_open_requests()
        open_request.refresh_from_db()
        self.assertEqual(open_request.status, TradeOpenRequest.STATUS_SUBMITTED)
        self.assertEqual(Order.objects.count(), 0)

    def test_query_failure_keeps_request_for_next_round(self):
        open_request = self.request()
        self.exchange.get_order.side_effect = BinanceApiError("throttled", code="-1003")
        reconcile_open_requests()
        open_request.refresh_from_db()
        self.assertEqual(open_request.status, TradeOpenRequest.STATUS_SUBMITTED)

    def test_partial_fill_is_adopted_and_protected(self):
        open_request = self.request()
        self.exchange.get_order.return_value = self.filled_row(
            state="partially_filled", fillSz="0.4", accFillSz="0.4",
        )
        reconcile_open_requests()
        order = Order.objects.get()
        self.assertEqual(order.size, Decimal("0.4"))
        self.assertEqual(order.stop_loss_amount, Decimal("100"))

    def test_young_pending_request_without_order_id_is_left_to_command_recovery(self):
        open_request = self.request(status=TradeOpenRequest.STATUS_PENDING, order_id="")
        reconcile_open_requests()
        self.exchange.get_order.assert_not_called()
        open_request.refresh_from_db()
        self.assertEqual(open_request.status, TradeOpenRequest.STATUS_PENDING)

    def test_missing_intent_keeps_request_visible_instead_of_guessing(self):
        open_request = self.request()
        open_request.request_payload = {}
        open_request.save(update_fields=["request_payload"])
        self.exchange.get_order.return_value = self.filled_row()
        reconcile_open_requests()
        open_request.refresh_from_db()
        self.assertEqual(open_request.status, TradeOpenRequest.STATUS_SUBMITTED)
        self.assertEqual(Order.objects.count(), 0)

    def test_inactive_binding_is_not_reconciled(self):
        self.binding.status = 0
        self.binding.save(update_fields=["status"])
        self.request()
        self.assertEqual(reconcile_open_requests(), 0)
        self.exchange.get_order.assert_not_called()