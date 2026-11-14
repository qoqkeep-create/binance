from contextlib import contextmanager
from decimal import Decimal
from types import SimpleNamespace
from unittest.mock import MagicMock, Mock, patch

from django.core.cache import cache
from django.test import TestCase, override_settings

from accounts.models import LeadTradingSettings
from api_bindings.context import build_trading_account_identity
from api_bindings.models import ApiBinding
from common.binance import BinanceApiError, BinanceCredentials, BinanceFuturesClient
from common.binance_rate_limit import RequestPriority
from positions.models import LimitOrder, Order
from trading.account_cache import position_cache_key
from trading.external_positions import (
    adopt_external_position_snapshot,
    close_external_position,
    reconcile_external_positions,
)
from trading.models import TradeOpenRequest
from users.models import User


class ExternalPositionDiscoveryTests(TestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(
            email="external-discovery@example.com", password="test-password", stop_loss_amount=Decimal("10"),
        )
        self.accounts = {}
        self.binding, self.account, self.exchange = self.bind(self.user)
        factory = patch("trading.external_positions.get_user_trading_account", side_effect=self.account_for)
        self.account_factory = factory.start()
        self.addCleanup(factory.stop)
        network = patch("requests.sessions.Session.request", side_effect=AssertionError("tests must not access network"))
        network.start()
        self.addCleanup(network.stop)

    def account_for(self, user, *, active_only, trading_mode):
        self.assertTrue(active_only)
        return self.accounts[(user.id, trading_mode)]

    def bind(self, user, mode="ordinary", *, status=1):
        fingerprint = f"test-user-{user.id}-{mode}"
        binding = ApiBinding.objects.create(
            user=user, trading_mode=mode, api_key_fingerprint=fingerprint,
            api_key="unused-test-placeholder", secret_key="unused-test-placeholder",
            passphrase="", alias="test account", status=status,
        )
        exchange = MagicMock()
        exchange.get_account_config.return_value = {"data": [{"posMode": "long_short_mode"}]}
        exchange.get_positions.return_value = {"data": [self.row()]}
        account = SimpleNamespace(
            user_id=user.id, trading_mode=mode, api_key_fingerprint=fingerprint,
            binding_created_at=binding.created_at, generation=(fingerprint, binding.created_at),
            identity=build_trading_account_identity(user_id=user.id, api_key_fingerprint=fingerprint, trading_mode=mode),
            create_futures_client=Mock(return_value=exchange),
        )
        self.accounts[(user.id, mode)] = account
        return binding, account, exchange

    @staticmethod
    def row(symbol="BTC-USDT-SWAP", side="long", quantity="1"):
        return {
            "instId": symbol, "posSide": side, "rawPositionSide": side.upper(), "pos": quantity,
            "avgPx": "100", "markPx": "105", "rawUpl": "5", "upl": "5", "ctVal": "1", "lever": "10",
        }

    def web_order(self, *, fingerprint=None, mode="ordinary", side=0, symbol="BTCUSDT"):
        return Order.objects.create(
            user=self.user, trading_mode=mode,
            api_key_fingerprint=fingerprint or self.account.api_key_fingerprint,
            binance_order_id=f"web-discovery-{Order.objects.count()}", symbol=symbol, side=side,
            open_price=Decimal("100"), stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("10"), size=Decimal("1"), leverage=10,
        )

    def pending_limit(self, *, fingerprint=None, status=LimitOrder.STATUS_PENDING):
        return LimitOrder.objects.create(
            user=self.user, api_key_fingerprint=fingerprint or self.account.api_key_fingerprint,
            binance_order_id=f"limit-discovery-{LimitOrder.objects.count()}", symbol="BTCUSDT", side=0,
            limit_price=Decimal("100"), stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("10"), size=Decimal("1"), leverage=10, status=status,
        )

    def opening_request(self, status, *, fingerprint=None):
        request_id = f"request-discovery-{TradeOpenRequest.objects.count()}"
        return TradeOpenRequest.objects.create(
            user=self.user, api_key_fingerprint=fingerprint or self.account.api_key_fingerprint,
            symbol="BTCUSDT", client_request_id=request_id, client_order_id=request_id,
            status=status, request_payload={"side": 0},
        )

    @patch("trading.external_positions.reconcile_external_order")
    def test_discovers_position_without_local_order_and_adopts_only_once(self, protect):
        self.assertEqual(Order.objects.count(), 0)
        self.assertEqual(reconcile_external_positions(), 1)
        self.assertEqual(reconcile_external_positions(), 1)
        order = Order.objects.get()
        self.assertEqual(order.position_origin, Order.ORIGIN_EXTERNAL)
        self.assertIsNone(order.binance_order_id)
        self.assertEqual(order.stop_loss_amount, Decimal("10"))
        self.assertEqual(order.entry_fee_status, Order.ENTRY_FEE_STATUS_ESTIMATED)
        self.assertTrue(order.external_active_key)
        self.assertEqual(protect.call_count, 2)
        self.assertEqual({call.args[0].id for call in protect.call_args_list}, {order.id})
        self.exchange.get_positions.assert_called_with("SWAP", None, budget_priority=RequestPriority.CRITICAL)

    @patch("trading.external_positions.reconcile_external_order")
    def test_reads_fresh_positions_even_when_shared_cache_says_empty(self, protect):
        cache.set(position_cache_key("exchange_rows", self.account.identity), [], timeout=60)
        with patch("trading.services.load_shared_exchange_positions") as shared:
            reconcile_external_positions()
        shared.assert_not_called()
        self.exchange.get_positions.assert_called_once()
        self.assertEqual(Order.objects.filter(position_origin=Order.ORIGIN_EXTERNAL).count(), 1)
        protect.assert_called_once()

    @patch("trading.external_positions.reconcile_external_order")
    def test_web_order_owns_its_direction_and_keeps_strategy_untouched(self, protect):
        order = self.web_order()
        order.binance_stop_market_order_id = "web-original-stop"
        order.strategy_status = Order.STRATEGY_STATUS_RUNNING
        order.save(update_fields=["binance_stop_market_order_id", "strategy_status"])
        reconcile_external_positions()
        self.assertEqual(Order.objects.count(), 1)
        protect.assert_not_called()
        order.refresh_from_db()
        self.assertEqual(order.position_origin, Order.ORIGIN_WEB)
        self.assertEqual(order.binance_stop_market_order_id, "web-original-stop")
        self.assertEqual(order.strategy_status, Order.STRATEGY_STATUS_RUNNING)

    @patch("trading.external_positions.reconcile_external_order")
    def test_pending_limit_fill_gets_web_reconciler_priority(self, protect):
        pending = self.pending_limit()
        pending.filled_size = Decimal("0.5")
        pending.save(update_fields=["filled_size"])
        reconcile_external_positions()
        self.assertFalse(Order.objects.exists())
        protect.assert_not_called()

    @patch("trading.external_positions.reconcile_external_order")
    def test_unresolved_web_open_requests_block_external_adoption(self, protect):
        for state in (TradeOpenRequest.STATUS_PENDING, TradeOpenRequest.STATUS_SUBMITTED, TradeOpenRequest.STATUS_RECOVERED):
            with self.subTest(state=state):
                request = self.opening_request(state)
                reconcile_external_positions()
                self.assertFalse(Order.objects.exists())
                protect.assert_not_called()
                request.delete()

    @patch("trading.external_positions.reconcile_external_order")
    def test_position_read_adopts_manual_position_even_with_unresolved_open_request(self, protect):
        self.opening_request(TradeOpenRequest.STATUS_SUBMITTED)

        adopted = adopt_external_position_snapshot(self.user, self.account, [self.row()])

        self.assertEqual(len(adopted), 1)
        self.assertEqual(adopted[0].position_origin, Order.ORIGIN_EXTERNAL)
        self.assertEqual(adopted[0].symbol, "BTCUSDT")
        protect.assert_not_called()

    @patch("trading.external_positions.reconcile_external_order")
    def test_failed_requests_and_cancelled_limits_do_not_hide_manual_position(self, protect):
        self.opening_request(TradeOpenRequest.STATUS_FAILED)
        self.pending_limit(status=LimitOrder.STATUS_CANCELLED)
        reconcile_external_positions()
        self.assertEqual(Order.objects.get().position_origin, Order.ORIGIN_EXTERNAL)
        protect.assert_called_once()

    @patch("trading.external_positions.reconcile_external_order")
    def test_cancelled_unfilled_limit_resolves_its_submitted_request_for_discovery(self, protect):
        limit = self.pending_limit(status=LimitOrder.STATUS_CANCELLED)
        request = self.opening_request(TradeOpenRequest.STATUS_SUBMITTED)
        request.binance_order_id = limit.binance_order_id
        request.save(update_fields=["binance_order_id"])

        reconcile_external_positions()

        self.assertEqual(Order.objects.get().position_origin, Order.ORIGIN_EXTERNAL)
        protect.assert_called_once()
        request.refresh_from_db()
        self.assertEqual(request.status, TradeOpenRequest.STATUS_SUBMITTED)
        self.assertIsNone(request.order_id)

    @patch("trading.external_positions.reconcile_external_order")
    def test_cancelled_limit_with_unadopted_fill_keeps_request_blocked(self, protect):
        limit = self.pending_limit(status=LimitOrder.STATUS_CANCELLED)
        limit.filled_size = Decimal("0.5")
        limit.save(update_fields=["filled_size"])
        request = self.opening_request(TradeOpenRequest.STATUS_SUBMITTED)
        request.binance_order_id = limit.binance_order_id
        request.save(update_fields=["binance_order_id"])

        reconcile_external_positions()

        self.assertFalse(Order.objects.exists())
        protect.assert_not_called()

    @patch("trading.external_positions.reconcile_external_order")
    def test_closed_web_owner_resolves_unlinked_request_for_later_manual_position(self, protect):
        old = self.web_order()
        old.status = 1
        old.save(update_fields=["status"])
        request = self.opening_request(TradeOpenRequest.STATUS_SUBMITTED)
        request.binance_order_id = old.binance_order_id
        request.save(update_fields=["binance_order_id"])

        reconcile_external_positions()

        external = Order.objects.get(position_origin=Order.ORIGIN_EXTERNAL)
        self.assertNotEqual(external.id, old.id)
        protect.assert_called_once()

    @patch("trading.external_positions.reconcile_external_order")
    def test_cancelled_limit_from_other_account_does_not_resolve_current_request(self, protect):
        limit = self.pending_limit(fingerprint="old-test-key", status=LimitOrder.STATUS_CANCELLED)
        request = self.opening_request(TradeOpenRequest.STATUS_SUBMITTED)
        request.binance_order_id = limit.binance_order_id
        request.save(update_fields=["binance_order_id"])

        reconcile_external_positions()

        self.assertFalse(Order.objects.exists())
        protect.assert_not_called()

    @patch("trading.external_positions.reconcile_external_order")
    def test_orders_and_pending_requests_from_an_old_key_do_not_own_current_position(self, protect):
        old = self.web_order(fingerprint="old-test-key")
        self.pending_limit(fingerprint="old-test-key")
        self.opening_request(TradeOpenRequest.STATUS_SUBMITTED, fingerprint="old-test-key")
        reconcile_external_positions()
        external = Order.objects.get(position_origin=Order.ORIGIN_EXTERNAL)
        self.assertEqual(external.api_key_fingerprint, self.account.api_key_fingerprint)
        self.assertNotEqual(external.id, old.id)
        self.assertEqual(protect.call_args.args[0].id, external.id)

    @override_settings(LEAD_TRADING_ENABLED=False)
    @patch("trading.external_positions.reconcile_external_order")
    def test_lead_scan_is_separate_and_uses_lead_risk_even_when_new_entries_disabled(self, protect):
        _, lead, lead_client = self.bind(self.user, "lead")
        LeadTradingSettings.objects.create(user=self.user, stop_loss_amount=Decimal("45"))
        web = self.web_order()
        reconcile_external_positions(trading_mode="lead")
        external = Order.objects.get(position_origin=Order.ORIGIN_EXTERNAL)
        self.assertEqual(external.trading_mode, "lead")
        self.assertEqual(external.api_key_fingerprint, lead.api_key_fingerprint)
        self.assertEqual(external.stop_loss_amount, Decimal("45"))
        self.account.create_futures_client.assert_not_called()
        lead_client.get_positions.assert_called_once()
        self.assertEqual(protect.call_args.args[0].id, external.id)
        web.refresh_from_db()
        self.assertEqual(web.stop_loss_amount, Decimal("10"))

    @patch("trading.external_positions.reconcile_external_order")
    def test_two_hedge_directions_have_separate_active_slots(self, protect):
        self.exchange.get_positions.return_value = {"data": [self.row(), self.row(side="short", quantity="2")]}
        reconcile_external_positions()
        orders = list(Order.objects.order_by("side"))
        self.assertEqual([order.side for order in orders], [0, 1])
        self.assertEqual([order.size for order in orders], [Decimal("1"), Decimal("2")])
        self.assertNotEqual(orders[0].external_active_key, orders[1].external_active_key)
        self.assertEqual(protect.call_count, 2)

    @patch("trading.external_positions.reconcile_external_order")
    def test_web_long_does_not_hide_manual_short_on_same_symbol(self, protect):
        self.web_order()
        self.exchange.get_positions.return_value = {"data": [self.row(), self.row(side="short", quantity="2")]}
        reconcile_external_positions()
        external = Order.objects.get(position_origin=Order.ORIGIN_EXTERNAL)
        self.assertEqual(external.side, 1)
        self.assertEqual(protect.call_args.args[0].id, external.id)

    @patch("trading.external_positions.reconcile_external_order")
    def test_unfilled_exchange_order_and_zero_position_are_not_adopted(self, protect):
        self.exchange.get_positions.return_value = {"data": [self.row(quantity="0")]}
        self.exchange.get_pending_orders.return_value = {"data": [{"instId": "BTC-USDT-SWAP", "state": "live"}]}
        reconcile_external_positions()
        self.assertFalse(Order.objects.exists())
        protect.assert_not_called()

    def test_zero_risk_is_explicitly_blocked_without_guessing_an_order(self):
        self.user.stop_loss_amount = Decimal("0")
        self.user.save(update_fields=["stop_loss_amount"])
        reconcile_external_positions()
        order = Order.objects.get(position_origin=Order.ORIGIN_EXTERNAL)
        self.assertEqual(order.stop_loss_amount, Decimal("0"))
        self.assertEqual(order.stop_protection_status, Order.STOP_PROTECTION_CONFIG_REQUIRED)
        self.assertIn("止损额度", order.stop_protection_error)
        self.exchange.close_position.assert_not_called()
        self.exchange.place_stop_market_order.assert_not_called()

    @patch("trading.external_positions.reconcile_external_order")
    def test_invalid_binding_is_not_scanned(self, protect):
        self.binding.status = 0
        self.binding.save(update_fields=["status"])
        self.assertEqual(reconcile_external_positions(), 0)
        self.account_factory.assert_not_called()
        self.account.create_futures_client.assert_not_called()
        protect.assert_not_called()

    @patch("trading.external_positions.reconcile_external_order")
    def test_busy_account_is_not_scanned(self, protect):
        @contextmanager
        def busy(*args, **kwargs):
            yield False

        with patch("trading.external_positions.user_trading_activity_lock", side_effect=busy):
            self.assertEqual(reconcile_external_positions(), 0)
        self.account.create_futures_client.assert_not_called()
        protect.assert_not_called()

    @patch("trading.external_positions.reconcile_external_order")
    def test_binding_generation_changed_before_account_lock_prevents_exchange_access(self, protect):
        @contextmanager
        def changed_binding(*args, **kwargs):
            ApiBinding.objects.filter(pk=self.binding.pk).update(api_key_fingerprint="replacement-test-key")
            yield True

        with patch("trading.external_positions.user_trading_activity_lock", side_effect=changed_binding):
            self.assertEqual(reconcile_external_positions(), 0)
        self.account.create_futures_client.assert_not_called()
        self.assertFalse(Order.objects.exists())
        protect.assert_not_called()

    @patch("trading.external_positions.reconcile_external_order")
    def test_one_account_read_failure_does_not_prevent_next_account_discovery(self, protect):
        other = User.objects.create_user(email="other-discovery@example.com", password="test-password")
        _, other_account, _ = self.bind(other)
        self.exchange.get_positions.side_effect = BinanceApiError("simulated account outage")
        self.assertEqual(reconcile_external_positions(), 1)
        order = Order.objects.get(position_origin=Order.ORIGIN_EXTERNAL)
        self.assertEqual(order.user_id, other.id)
        self.assertEqual(order.api_key_fingerprint, other_account.api_key_fingerprint)
        protect.assert_called_once()

    @patch("trading.external_positions.reconcile_external_order")
    def test_unresolved_short_request_does_not_block_long_adoption(self, protect):
        TradeOpenRequest.objects.create(
            user=self.user, api_key_fingerprint=self.account.api_key_fingerprint,
            symbol="BTCUSDT", client_request_id="req-side-short", client_order_id="req-side-short",
            status=TradeOpenRequest.STATUS_SUBMITTED,
            request_payload={"_execution_intent": {"side_code": 1}},
        )
        self.assertEqual(reconcile_external_positions(), 1)
        order = Order.objects.get()
        self.assertEqual(order.side, 0)
        # The same unresolved request still blocks its own direction.
        order.delete()
        self.exchange.get_positions.return_value = {"data": [self.row(side="short")]}
        self.assertEqual(reconcile_external_positions(), 1)
        self.assertFalse(Order.objects.exists())

    @patch("trading.external_positions.reconcile_external_order")
    def test_request_without_known_direction_blocks_both_sides(self, protect):
        self.opening_request(TradeOpenRequest.STATUS_SUBMITTED)
        self.assertEqual(reconcile_external_positions(), 1)
        self.assertFalse(Order.objects.exists())

    @patch("trading.external_positions.reconcile_external_order")
    def test_invalid_position_row_does_not_abort_other_adoptions(self, protect):
        invalid = self.row()
        invalid["posSide"] = "sideways"
        self.exchange.get_positions.return_value = {"data": [invalid, self.row()]}
        self.assertEqual(reconcile_external_positions(), 1)
        order = Order.objects.get()
        self.assertEqual(order.symbol, "BTCUSDT")
        self.assertEqual(order.side, 0)


class ExternalCloseAdapterIntegrationTests(TestCase):
    """Exercise the real adapter's Binance payload normalization with mocked I/O."""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(email="external-protocol@example.com", password="test-password")
        self.exchange = BinanceFuturesClient(BinanceCredentials(api_key="test-placeholder", secret_key="test-placeholder"))
        instrument = patch.object(self.exchange, "_get_public_instrument", return_value={
            "lotSz": "0.001", "minSz": "0.001", "marketLotSz": "0.001", "marketMinSz": "0.001",
        })
        instrument.start()
        self.addCleanup(instrument.stop)
        network = patch("requests.sessions.Session.request", side_effect=AssertionError("tests must not access network"))
        network.start()
        self.addCleanup(network.stop)

    def order(self, side=0):
        return Order.objects.create(
            user=self.user, position_origin=Order.ORIGIN_EXTERNAL,
            external_active_key=f"test-protocol-slot-{Order.objects.count()}",
            binance_order_id=None, symbol="BTCUSDT", side=side,
            open_price=Decimal("100"), stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("10"), size=Decimal("1"), leverage=10,
        )

    def raw_position(self, side, mode):
        return [{
            "symbol": "BTCUSDT", "positionAmt": "1" if side == 0 else "-1",
            "positionSide": ("LONG" if side == 0 else "SHORT") if mode == "long_short_mode" else "BOTH",
            "entryPrice": "100", "markPrice": "105", "unRealizedProfit": "5", "leverage": "10",
        }]

    def receipt(self, params, **overrides):
        return {
            "symbol": "BTCUSDT", "orderId": 6789, "clientOrderId": params["newClientOrderId"],
            "positionSide": params.get("positionSide", "BOTH"), "side": params["side"],
            "reduceOnly": params.get("reduceOnly", False), "status": "FILLED", "origQty": "1",
            "executedQty": "1", "avgPrice": "105", **overrides,
        }

    def test_normalized_receipt_confirms_both_directions_in_net_and_hedge_modes(self):
        for mode in ("net_mode", "long_short_mode"):
            for side in (0, 1):
                with self.subTest(mode=mode, side=side):
                    order = self.order(side)
                    posts = []

                    def request(method, path, params=None, **kwargs):
                        if (method, path) == ("GET", "/fapi/v3/positionRisk"):
                            return self.raw_position(side, mode)
                        if (method, path) == ("POST", "/fapi/v1/order"):
                            order.refresh_from_db()
                            self.assertEqual(order.external_close_request["client_id"], params["newClientOrderId"])
                            self.assertEqual(params["symbol"], "BTCUSDT")
                            self.assertEqual(params["side"], "SELL" if side == 0 else "BUY")
                            if mode == "net_mode":
                                self.assertEqual(params["reduceOnly"], "true")
                            else:
                                self.assertEqual(params["positionSide"], "LONG" if side == 0 else "SHORT")
                                self.assertNotIn("reduceOnly", params)
                            posts.append(params)
                            return self.receipt(params)
                        self.fail(f"unexpected adapter request {method} {path}")

                    with patch.object(self.exchange, "_request", side_effect=request):
                        self.assertTrue(close_external_position(order, self.exchange, pos_mode=mode, reason="manual"))
                    order.refresh_from_db()
                    self.assertEqual(len(posts), 1)
                    self.assertEqual(order.status, 1)
                    self.assertIsNone(order.external_active_key)
                    self.assertIsNone(order.pnl)
                    self.assertEqual(order.close_binance_order_id, "6789")
                    self.assertEqual(order.close_price, Decimal("105"))

    def test_timeout_recovers_by_original_client_id_without_second_market_order(self):
        order = self.order()
        posts = []

        def request(method, path, params=None, **kwargs):
            if (method, path) == ("GET", "/fapi/v3/positionRisk"):
                return self.raw_position(0, "net_mode")
            if (method, path) == ("POST", "/fapi/v1/order"):
                posts.append(params)
                raise BinanceApiError("simulated timeout", outcome_unknown=True)
            if (method, path) == ("GET", "/fapi/v1/order"):
                self.assertEqual(params["origClientOrderId"], posts[0]["newClientOrderId"])
                return self.receipt(posts[0])
            self.fail(f"unexpected adapter request {method} {path}")

        with patch.object(self.exchange, "_request", side_effect=request):
            self.assertFalse(close_external_position(order, self.exchange, pos_mode="net_mode"))
            self.assertTrue(close_external_position(order, self.exchange, pos_mode="net_mode"))
        order.refresh_from_db()
        self.assertEqual(order.status, 1)
        self.assertEqual(len(posts), 1)

    def test_adapter_preserves_wrong_receipt_symbol_so_service_refuses_to_confirm(self):
        order = self.order()

        def request(method, path, params=None, **kwargs):
            if (method, path) == ("GET", "/fapi/v3/positionRisk"):
                return self.raw_position(0, "net_mode")
            if (method, path) == ("POST", "/fapi/v1/order"):
                return self.receipt(params, symbol="ETHUSDT")
            self.fail(f"unexpected adapter request {method} {path}")

        with patch.object(self.exchange, "_request", side_effect=request):
            self.assertFalse(close_external_position(order, self.exchange, pos_mode="net_mode"))
        order.refresh_from_db()
        self.assertEqual(order.status, 0)
        self.assertIsNotNone(order.external_active_key)
        self.assertIn("身份不匹配", order.stop_protection_error)
