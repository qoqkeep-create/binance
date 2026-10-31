from contextlib import contextmanager
from decimal import Decimal
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from django.test import SimpleTestCase, TestCase

from positions.models import LimitOrder, Order
from trading.execution import UNKNOWN, confirm_entry_execution, parse_entry_execution
from trading.external_positions import reconcile_external_positions
from trading.models import TradeOpenRequest
from trading.services import _sync_limit_order_status_unlocked, sync_limit_order_status


def fill_row(order_id="incomplete-fill", *, price="0", quantity="0.5", state="canceled"):
    return {
        "ordId": order_id, "instId": "BTC-USDT-SWAP", "state": state,
        "fillSz": quantity, "accFillSz": quantity, "avgPx": price,
    }


class IncompleteFillParsingTests(SimpleTestCase):
    def test_positive_fill_without_valid_average_remains_unknown_and_preserves_quantity(self):
        for price in (None, "0", "-1", "invalid", "NaN", "Infinity"):
            with self.subTest(price=price):
                execution = parse_entry_execution(fill_row(price=price), requested_size=Decimal("1"))
                self.assertEqual(execution.state, UNKNOWN)
                self.assertEqual(execution.filled_size, Decimal("0.5"))
                self.assertFalse(execution.has_fill)

    def test_confirmation_retains_known_quantity_when_queries_fail_or_return_less(self):
        for next_row in (None, fill_row(quantity="0"), fill_row(price="100", quantity="0.25")):
            with self.subTest(next_row=next_row):
                client = MagicMock()
                client.get_order.return_value = {"data": [next_row] if next_row else []}
                execution = confirm_entry_execution(
                    client, inst_id="BTC-USDT-SWAP", requested_size=Decimal("1"),
                    initial_row=fill_row(), retry_delays=(0,),
                )
                self.assertEqual(execution.state, UNKNOWN)
                self.assertEqual(execution.filled_size, Decimal("0.5"))

    def test_confirmation_can_recover_average_for_the_known_fill(self):
        client = MagicMock()
        client.get_order.return_value = {"data": [fill_row(price="100")]}
        execution = confirm_entry_execution(
            client, inst_id="BTC-USDT-SWAP", requested_size=Decimal("1"),
            initial_row=fill_row(), retry_delays=(0,),
        )
        self.assertTrue(execution.has_fill)
        self.assertEqual(execution.filled_size, Decimal("0.5"))
        self.assertEqual(execution.average_price, Decimal("100"))

    def test_missing_or_invalid_fill_quantity_cannot_confirm_zero_fill_cancellation(self):
        for quantity in (None, "", "invalid", "-1", "NaN", "Infinity"):
            with self.subTest(quantity=quantity):
                execution = parse_entry_execution(fill_row(quantity=quantity))
                self.assertEqual(execution.state, UNKNOWN)
                self.assertFalse(execution.has_fill)

    def test_observer_receives_known_quantity_before_confirmation_hits_rate_limit(self):
        from common.binance import BinanceApiError

        client = MagicMock()
        rate_limit = BinanceApiError("test request budget", code="LOCAL_RATE_BUDGET")
        client.get_order.side_effect = [{"data": [fill_row()]}, rate_limit]
        observed = []
        with self.assertRaises(BinanceApiError) as raised:
            confirm_entry_execution(
                client, inst_id="BTC-USDT-SWAP", requested_size=Decimal("1"),
                retry_delays=(0, 0, 0), on_incomplete_fill=observed.append,
            )
        self.assertIs(raised.exception, rate_limit)
        self.assertEqual(client.get_order.call_count, 2)
        self.assertEqual([execution.filled_size for execution in observed], [Decimal("0.5")])


class BinanceExecutionFactsTests(SimpleTestCase):
    def adapted_executions(self, payload):
        from common.binance import BinanceCredentials, BinanceFuturesClient

        exchange = BinanceFuturesClient(BinanceCredentials(api_key="test", secret_key="test"))
        for method in (exchange.get_order, exchange.cancel_order):
            with patch.object(exchange, "_request", return_value=payload):
                row = method(inst_id="BTC-USDT-SWAP", order_id="123")["data"][0]
            yield row, parse_entry_execution(row, requested_size=Decimal("1"))

    def test_missing_quantity_stays_unknown_through_real_adapter_and_parser(self):
        for row, execution in self.adapted_executions({"orderId": 123, "symbol": "BTCUSDT", "status": "CANCELED"}):
            self.assertIsNone(row["fillSz"])
            self.assertEqual(execution.state, UNKNOWN)

    def test_limit_price_cannot_substitute_for_missing_fill_average(self):
        payload = {"orderId": 123, "symbol": "BTCUSDT", "status": "CANCELED", "executedQty": "0.5", "price": "100"}
        for _row, execution in self.adapted_executions(payload):
            self.assertEqual(execution.state, UNKNOWN)
            self.assertEqual(execution.filled_size, Decimal("0.5"))

    def test_explicit_zero_quantity_remains_a_confirmed_unfilled_cancellation(self):
        payload = {"orderId": 123, "symbol": "BTCUSDT", "status": "CANCELED", "executedQty": "0", "avgPrice": "0"}
        for row, execution in self.adapted_executions(payload):
            self.assertEqual(row["fillSz"], "0")
            self.assertEqual(execution.state, "pending")
            self.assertEqual(execution.filled_size, Decimal("0"))


class IncompleteLimitOwnershipTests(TestCase):
    def setUp(self):
        from trading.test_external_discovery import ExternalPositionDiscoveryTests

        self.fixture = ExternalPositionDiscoveryTests()
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.setUp()
        self.limit = self.fixture.pending_limit()
        self.request = self.fixture.opening_request(TradeOpenRequest.STATUS_SUBMITTED)
        self.request.binance_order_id = self.limit.binance_order_id
        self.request.save(update_fields=["binance_order_id"])

    def sync(self, *, price="0", quantity="0.5"):
        self.fixture.exchange.get_order.return_value = {
            "data": [fill_row(self.limit.binance_order_id, price=price, quantity=quantity)],
        }
        with patch("trading.services.BinanceFuturesClient", return_value=self.fixture.exchange):
            return _sync_limit_order_status_unlocked(self.limit, credentials=object())

    def assert_web_ownership_pending(self):
        self.limit.refresh_from_db()
        self.assertEqual(self.limit.status, LimitOrder.STATUS_PENDING)
        self.assertEqual(self.limit.filled_size, Decimal("0.5"))
        with patch("trading.external_positions.reconcile_external_order") as protect:
            reconcile_external_positions()
        self.assertFalse(Order.objects.exists())
        protect.assert_not_called()

    def test_sync_preserves_incomplete_fill_and_scanner_does_not_adopt_it_as_manual(self):
        self.assertTrue(self.sync())
        self.assert_web_ownership_pending()
        self.fixture.exchange.place_stop_market_order.assert_not_called()

    def test_later_lower_snapshot_cannot_release_the_known_partial_fill(self):
        self.sync()
        for quantity, price in (("0", "0"), ("0.25", "100")):
            with self.subTest(quantity=quantity, price=price):
                self.sync(quantity=quantity, price=price)
                self.assert_web_ownership_pending()

    def test_later_confirmed_average_adopts_original_web_order(self):
        self.sync()
        with patch("trading.services._converge_stop_loss_order"), patch("trading.services.enqueue_open_notification"):
            self.assertTrue(self.sync(price="100"))
        self.limit.refresh_from_db()
        owner = Order.objects.get()
        self.assertEqual(owner.position_origin, Order.ORIGIN_WEB)
        self.assertEqual(owner.size, Decimal("0.5"))
        self.assertEqual(owner.open_price, Decimal("100"))
        self.assertEqual(self.limit.order_id, owner.id)
        self.assertEqual(self.limit.status, LimitOrder.STATUS_CANCELLED)
        with patch("trading.external_positions.reconcile_external_order") as protect:
            reconcile_external_positions()
        self.assertEqual(Order.objects.count(), 1)
        protect.assert_not_called()

    def test_sync_refreshes_fill_evidence_after_acquiring_account_lock(self):
        LimitOrder.objects.filter(pk=self.limit.pk).update(filled_size=Decimal("0.5"))
        self.fixture.exchange.get_order.return_value = {
            "data": [fill_row(self.limit.binance_order_id, quantity="0")],
        }
        with patch("trading.services.get_user_binding_generation", return_value=self.fixture.account.generation), patch(
            "trading.services._credentials_for_binding_generation", return_value=object(),
        ), patch("trading.services.BinanceFuturesClient", return_value=self.fixture.exchange):
            sync_limit_order_status(self.limit)
        self.assert_web_ownership_pending()


class IncompleteLimitMutationTests(TestCase):
    def setUp(self):
        from rest_framework.test import APIClient
        from trading.tests import TradingApiTests

        self.fixture = TradingApiTests()
        self.fixture.client = APIClient()
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.setUp()
        self.limit = self.fixture._create_limit_order_for_chase()
        self.exchange = MagicMock()
        self.exchange.get_order.return_value = {"data": [fill_row(self.limit.binance_order_id)]}
        self.exchange.cancel_order.return_value = {"data": [fill_row(self.limit.binance_order_id)]}
        for target, value in (
            ("trading.views.BinanceFuturesClient", self.exchange),
            ("trading.views.get_user_binance_credentials", object()),
        ):
            mocked = patch(target, return_value=value)
            mocked.start()
            self.addCleanup(mocked.stop)
        sleeping = patch("trading.execution.time.sleep")
        sleeping.start()
        self.addCleanup(sleeping.stop)
        network = patch("requests.sessions.Session.request", side_effect=AssertionError("no network in tests"))
        network.start()
        self.addCleanup(network.stop)

    def assert_rejected_without_new_entry(self, path):
        response = self.fixture.client.post(path, {"limit_order_id": self.limit.id}, format="json")
        self.assertEqual(response.status_code, 400)
        self.limit.refresh_from_db()
        self.assertEqual(self.limit.status, LimitOrder.STATUS_PENDING)
        self.assertFalse(Order.objects.exists())
        self.exchange.place_market_order.assert_not_called()

    def test_cancel_keeps_incomplete_partial_fill_pending(self):
        self.assert_rejected_without_new_entry("/v1/trade/limit-order/cancel")
        self.assertEqual(self.limit.filled_size, Decimal("0.5"))

    def test_cancel_does_not_forget_quantity_when_followup_reports_zero(self):
        self.exchange.get_order.return_value = {"data": [fill_row(self.limit.binance_order_id, quantity="0")]}
        self.assert_rejected_without_new_entry("/v1/trade/limit-order/cancel")

    def test_chase_keeps_preexisting_incomplete_partial_fill_pending(self):
        self.assert_rejected_without_new_entry("/v1/trade/limit-order/chase")
        self.assertEqual(self.limit.filled_size, Decimal("0.5"))

    def test_chase_does_not_forget_fill_reported_during_cancel(self):
        self.exchange.get_order.side_effect = lambda **_kwargs: {
            "data": [fill_row(
                self.limit.binance_order_id, quantity="0",
                state="canceled" if self.exchange.cancel_order.call_count else "live",
            )],
        }
        self.assert_rejected_without_new_entry("/v1/trade/limit-order/chase")
        self.exchange.cancel_order.assert_called_once()

    def test_later_cancel_retry_cannot_release_fill_evidence_saved_by_previous_request(self):
        self.assert_rejected_without_new_entry("/v1/trade/limit-order/cancel")
        for quantity, price in (("0", "0"), ("0.25", "100")):
            with self.subTest(quantity=quantity, price=price):
                self.exchange.get_order.return_value = {
                    "data": [fill_row(self.limit.binance_order_id, quantity=quantity, price=price)],
                }
                self.exchange.cancel_order.return_value = self.exchange.get_order.return_value
                self.assert_rejected_without_new_entry("/v1/trade/limit-order/cancel")
                self.assertEqual(self.limit.filled_size, Decimal("0.5"))

    def test_later_chase_retry_cannot_release_fill_evidence_saved_by_previous_request(self):
        self.assert_rejected_without_new_entry("/v1/trade/limit-order/chase")
        for quantity, price in (("0", "0"), ("0.25", "100")):
            with self.subTest(quantity=quantity, price=price):
                self.exchange.get_order.return_value = {
                    "data": [fill_row(self.limit.binance_order_id, quantity=quantity, price=price)],
                }
                self.exchange.cancel_order.return_value = self.exchange.get_order.return_value
                self.assert_rejected_without_new_entry("/v1/trade/limit-order/chase")
                self.assertEqual(self.limit.filled_size, Decimal("0.5"))

    def test_chase_preserves_quantity_observed_before_rate_limit(self):
        from common.binance import BinanceApiError

        self.exchange.get_order.side_effect = [
            {"data": [fill_row(self.limit.binance_order_id)]},
            BinanceApiError("test request budget", code="LOCAL_RATE_BUDGET"),
        ]
        self.assert_rejected_without_new_entry("/v1/trade/limit-order/chase")
        self.assertEqual(self.limit.filled_size, Decimal("0.5"))
        self.assertEqual(self.exchange.get_order.call_count, 2)

    def test_chase_refreshes_fill_evidence_after_acquiring_account_lock(self):
        @contextmanager
        def account_lock(*_args, **_kwargs):
            LimitOrder.objects.filter(pk=self.limit.pk).update(filled_size=Decimal("0.5"))
            yield SimpleNamespace(allowed=True)

        self.exchange.get_order.return_value = {"data": [fill_row(self.limit.binance_order_id, quantity="0")]}
        with patch("trading.views.entry_submission_guard", side_effect=account_lock):
            self.assert_rejected_without_new_entry("/v1/trade/limit-order/chase")
        self.assertEqual(self.limit.filled_size, Decimal("0.5"))
        self.exchange.cancel_order.assert_not_called()

    def test_limit_create_preserves_incomplete_fill_before_later_zero_snapshot(self):
        self.limit.delete()
        self.exchange.place_limit_order.return_value = {"data": [fill_row("created-incomplete-fill")]}
        self.exchange.get_order.return_value = {"data": [fill_row("created-incomplete-fill", quantity="0")]}
        self.exchange.get_positions.return_value = {"data": []}
        self.exchange.get_account_config.return_value = {"data": [{"posMode": "long_short_mode"}]}
        with patch("trading.views._extract_instrument", return_value={
            "ctVal": "1", "lotSz": "0.001", "tickSz": "0.1", "lever": "10",
        }), patch("trading.views._extract_ticker", return_value={"last": "110"}):
            response = self.fixture.client.post("/v1/trade/limit-order/create", {
                "symbol": "BTCUSDT", "limit_price": "100", "stop_loss_price": "90",
                "stop_loss_amount": "30", "client_request_id": "11111111-1111-4111-8111-111111111111",
            }, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        created = LimitOrder.objects.get(binance_order_id="created-incomplete-fill")
        self.assertEqual(created.filled_size, Decimal("0.5"))
        with patch("trading.services.BinanceFuturesClient", return_value=self.exchange):
            _sync_limit_order_status_unlocked(created, credentials=object())
        created.refresh_from_db()
        self.assertEqual(created.status, LimitOrder.STATUS_PENDING)
        self.assertEqual(created.filled_size, Decimal("0.5"))
        self.assertFalse(Order.objects.exists())
