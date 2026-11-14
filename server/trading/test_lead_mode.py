import json
from decimal import Decimal
from unittest.mock import MagicMock, Mock, patch

from django.core.cache import cache
from django.test import SimpleTestCase, override_settings
from rest_framework.test import APITestCase

from accounts.models import LeadTradingSettings
from api_bindings.models import ApiBinding
from api_bindings.services import build_api_key_fingerprint, get_user_trading_account
from common.binance import BinanceApiError, BinanceCredentials, BinanceFuturesClient, _HttpResponseData
from common.binance_rate_limit import RequestBudgetExceeded, RequestBudgetSpec, RequestPriority, _clear_local_budget_state, reserve_request_budget
from common.trading_mode import TradingMode
from common.utils import aes_encrypt
from positions.models import LimitOrder, Order
from trading.models import Strategy, StrategyLevel
from positions.views import _record_current_account_key, _scoped_order_queryset
from trading.adapters import LeadTradingAdapter
from trading.balance_cap import ExchangeActivitySnapshot
from trading.open_requests import build_client_order_id, resolve_open_request
from trading.services import _group_protection_orders, sync_limit_order_status
from users.models import User


class LeadAdapterContractTests(SimpleTestCase):
    def setUp(self):
        cache.clear()
        _clear_local_budget_state()
        self.client = BinanceFuturesClient(BinanceCredentials("test-lead-key", "test-secret", trading_mode="lead"))

    @patch("common.binance._perform_http_request")
    def test_official_envelope_is_accepted_by_actual_transport(self, http):
        http.return_value = _HttpResponseData(200, json.dumps({"code": "000000", "success": True, "data": {"isLeadTrader": True}}))
        self.assertTrue(self.client.get_lead_trader_status())
        self.assertIn("/sapi/v1/copyTrading/futures/userStatus?", http.call_args.kwargs["url"])
        self.assertIn("signature=", http.call_args.kwargs["url"])

    @patch("common.binance._perform_http_request")
    def test_status_error_and_malformed_success_never_prove_lead_identity(self, http):
        for body in ({"code": "000000", "data": {"isLeadTrader": "true"}},
                     {"code": "000000", "success": False, "data": {"isLeadTrader": True}},
                     {"data": {"isLeadTrader": True}}):
            with self.subTest(body=body):
                http.return_value = _HttpResponseData(200, json.dumps(body))
                with self.assertRaises(BinanceApiError):
                    self.client.get_lead_trader_status()

    @patch("common.binance.BinanceFuturesClient._request")
    def test_symbol_whitelist_filters_non_usdt_and_rejects_missing_fields(self, request):
        request.return_value = {"code": "000000", "data": [{"symbol": "BTCUSDT", "quoteAsset": "USDT"}, {"symbol": "ETHUSDC", "quoteAsset": "USDC"}]}
        self.assertEqual(self.client.get_lead_symbols(), ["BTCUSDT"])
        request.return_value = {"code": "000000", "data": [{"symbol": "BTCUSDT"}]}
        with self.assertRaises(BinanceApiError):
            self.client.get_lead_symbols()

    def test_binding_requires_lead_status_trade_permission_and_single_asset(self):
        client = Mock()
        client.get_lead_trader_status.return_value = False
        adapter = LeadTradingAdapter()
        with self.assertRaises(BinanceApiError):
            adapter.validate_binding(client, config={"canTrade": True, "multiAssetsMargin": False})
        client.get_lead_trader_status.return_value = True
        for config in ({"canTrade": False, "multiAssetsMargin": False}, {"canTrade": True, "multiAssetsMargin": True}, {}):
            with self.assertRaises(BinanceApiError):
                adapter.validate_binding(client, config=config)
        adapter.validate_binding(client, config={"canTrade": True, "multiAssetsMargin": False})

    @patch("common.binance._perform_http_request")
    def test_capital_requests_are_rejected_before_any_network_call(self, http):
        for path in ("/sapi/v1/asset/transfer", "/sapi/v1/sub-account/transfer/subToMaster", "/sapi/v1/capital/withdraw/apply", "/api/v3/account"):
            with self.assertRaises(BinanceApiError):
                self.client._request("POST", path)
        http.assert_not_called()

    @patch("common.binance.BinanceFuturesClient.get_lead_symbols", return_value=[])
    @patch("common.binance.BinanceFuturesClient._request")
    def test_removed_symbol_blocks_new_entry_but_still_allows_close(self, request, _symbols):
        with self.assertRaises(BinanceApiError):
            self.client.place_market_order("BTC-USDT-SWAP", "buy", "1")
        request.assert_not_called()
        request.return_value = {"orderId": 101, "status": "FILLED", "executedQty": "1", "avgPrice": "100"}
        with patch.object(self.client, "get_positions", return_value={"data": [{"pos": "1", "posSide": "long"}]}), patch.object(self.client, "_normalize_order_quantity", return_value="1"):
            result = self.client.close_position("BTC-USDT-SWAP")
        self.assertEqual(result["data"][0]["ordId"], "101")
        self.assertEqual(request.call_args.args[2]["reduceOnly"], "true")

    def test_short_window_reserves_capacity_for_protection_and_shares_ip_budget(self):
        ordinary = RequestBudgetSpec("futures", RequestPriority.NORMAL, 1, True)
        critical = RequestBudgetSpec("futures", RequestPriority.CRITICAL, 1, True)
        for _ in range(14):
            reserve_request_budget(ordinary, account_api_key="lead-key", now=100, lead_trading=True)
        with self.assertRaises(RequestBudgetExceeded):
            reserve_request_budget(ordinary, account_api_key="lead-key", now=100, lead_trading=True)
        for _ in range(4):
            reserve_request_budget(critical, account_api_key="lead-key", now=100, lead_trading=True)
        with self.assertRaises(RequestBudgetExceeded):
            reserve_request_budget(critical, account_api_key="lead-key", now=100, lead_trading=True)
        reserve_request_budget(ordinary, account_api_key="ordinary-key", now=100)
        reserve_request_budget(ordinary, account_api_key="lead-key", now=110, lead_trading=True)

    @patch("common.binance.detect_public_egress_ip", return_value="")
    @patch("common.binance._perform_http_request")
    def test_lead_order_throttle_does_not_cool_down_ordinary_account(self, http, _ip):
        http.side_effect = [
            _HttpResponseData(429, json.dumps({"code": -1015, "msg": "Too many new orders"})),
            _HttpResponseData(200, json.dumps([])),
        ]
        with self.assertRaises(BinanceApiError):
            self.client._request("POST", "/fapi/v1/order")
        ordinary = BinanceFuturesClient(BinanceCredentials("ordinary-key", "test-secret"))
        self.assertEqual(ordinary._request("GET", "/fapi/v3/positionRisk"), [])
        with self.assertRaises(BinanceApiError):
            self.client._request("POST", "/fapi/v1/order")
        self.assertEqual(http.call_count, 2)


@override_settings(LEAD_TRADING_ENABLED=True)
class LeadAccountIsolationTests(APITestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(email="lead-isolation@example.com", password="test-password")
        self.client.force_authenticate(self.user)
        self.bindings = {}
        for mode in TradingMode.values:
            key = f"test-key-{mode}"
            self.bindings[mode] = ApiBinding.objects.create(user=self.user, trading_mode=mode, alias=mode,
                api_key=aes_encrypt(key), secret_key=aes_encrypt("test-secret"), passphrase=aes_encrypt(""),
                api_key_fingerprint=build_api_key_fingerprint(key))
        LeadTradingSettings.objects.create(user=self.user, stop_loss_amount=Decimal("100"))
        self.strategy = Strategy.objects.create(user=self.user, name="测试止盈策略", is_active=True)
        StrategyLevel.objects.create(
            strategy=self.strategy, sort_order=1, profit_rr=Decimal("2"),
            reduce_position=Decimal("50"), stop_loss_type=StrategyLevel.STOP_LOSS_TYPE_NONE)

    def order(self, mode):
        return Order.objects.create(user=self.user, trading_mode=mode,
            api_key_fingerprint=self.bindings[mode].api_key_fingerprint,
            binance_order_id="same-exchange-id", symbol="BTCUSDT", side=0, open_price=100,
            stop_loss_price=90, stop_loss_amount=100, size=10, leverage=10)

    def test_queries_and_scheduler_group_both_modes_of_same_user(self):
        ordinary, lead = self.order("ordinary"), self.order("lead")
        self.assertEqual(list(_scoped_order_queryset(self.user)), [ordinary])
        self.assertEqual(list(_scoped_order_queryset(self.user, trading_mode="lead")), [lead])
        eligible, _, _ = _group_protection_orders([ordinary, lead])
        self.assertEqual(len(eligible), 2)
        generations = {}
        first = _record_current_account_key(ordinary, generations)
        second = _record_current_account_key(lead, generations)
        self.assertNotEqual(first, second)
        self.assertEqual(len(generations), 2)

    @patch("trading.services._sync_limit_order_status_unlocked", return_value=True)
    def test_background_limit_sync_uses_order_mode_not_last_web_selection(self, sync):
        lead = LimitOrder.objects.create(user=self.user, trading_mode="lead",
            api_key_fingerprint=self.bindings["lead"].api_key_fingerprint,
            binance_order_id="limit-lead", symbol="BTCUSDT", side=0, limit_price=100,
            stop_loss_price=90, stop_loss_amount=100, size=10, leverage=10)
        self.assertTrue(sync_limit_order_status(lead))
        self.assertEqual(sync.call_args.kwargs["credentials"].api_key, "test-key-lead")

    @patch("positions.views.BinanceFuturesClient")
    def test_cross_mode_position_id_cannot_trigger_any_exchange_mutation(self, client):
        ordinary = self.order("ordinary")
        for route, body in (("close", {"position_id": ordinary.id}),
                            ("break-even-stop", {"position_id": ordinary.id, "mode": "with_fee"}),
                            ("take-profit", {"position_id": ordinary.id, "take_profit_price": "110"})):
            with self.subTest(route=route):
                response = self.client.post(f"/v1/position/{route}", body, format="json", HTTP_X_TRADING_MODE="lead")
                self.assertEqual(response.status_code, 400)
        client.assert_not_called()

    def test_same_client_request_is_distinct_in_each_mode(self):
        rows = []
        for mode in TradingMode.values:
            account = get_user_trading_account(self.user, trading_mode=mode)
            cid = build_client_order_id("mo", account.identity, "BTCUSDT", "same-request")
            rows.append(resolve_open_request(user=self.user, trading_mode=mode, symbol="BTCUSDT",
                client_request_id="same-request", client_order_id=cid, request_payload={"symbol": "BTCUSDT"}).request)
        self.assertNotEqual(rows[0].id, rows[1].id)
        self.assertNotEqual(rows[0].api_key_fingerprint, rows[1].api_key_fingerprint)

    def test_lead_capital_paths_cannot_reach_ordinary_wallets(self):
        for path in ("/v1/trade/capital/normalize", "/v1/trade/capital/remind", "/v1/account/capital-collect-account", "/v1/account/transfer-history/sync"):
            response = self.client.post(path, {}, format="json", HTTP_X_TRADING_MODE="lead")
            self.assertEqual(response.status_code, 400)
            self.assertIn("暂不支持", response.json()["message"])

    @patch("trading.adapters.get_usdt_equity_snapshot")
    def test_lead_capital_thresholds_and_existing_position_behavior(self, balance):
        adapter = LeadTradingAdapter()
        empty = ExchangeActivitySnapshot((), (), ())
        for amount, expected in (("149.99", "shortfall"), ("150", "ready"), ("499.99", "ready"), ("500", "ready"), ("500.01", "ready"), ("1000", "ready"), ("1000.01", "normalization_required")):
            with self.subTest(amount=amount):
                balance.return_value = (amount, amount)
                self.assertEqual(adapter.capital_precheck(self.user, Mock(), activity_snapshot=empty)["status"], expected)
        balance.reset_mock()
        state = adapter.capital_precheck(self.user, Mock(), activity_snapshot=ExchangeActivitySnapshot(({"symbol": "BTCUSDT"},), (), ()))
        self.assertEqual(state["status"], "not_required")
        balance.assert_not_called()

    @patch("accounts.mode_settings.lead_balance", return_value=("1000", "1000"))
    def test_lead_risk_setting_does_not_change_ordinary_setting(self, _balance):
        old_amount = self.user.stop_loss_amount
        response = self.client.post("/v1/account/stop-loss", {"amount": "100"}, format="json", HTTP_X_TRADING_MODE="lead")
        self.assertEqual(response.status_code, 200)
        self.user.refresh_from_db()
        self.assertEqual(self.user.stop_loss_amount, old_amount)
        self.assertEqual(LeadTradingSettings.objects.get(user=self.user).stop_loss_amount, 100)

    @override_settings(LEAD_TRADING_ENABLED=False)
    def test_disabled_entry_keeps_existing_portfolio_accessible(self):
        response = self.client.get("/v1/api/info", HTTP_X_TRADING_MODE="lead")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["data"]["alias"], "lead")
        response = self.client.get("/v1/account/version")
        self.assertFalse(response.data["data"]["lead_trading_enabled"])
        self.assertTrue(response.data["data"]["lead_trading_bound"])
        for path in ("/v1/api/bind", "/v1/trade/open", "/v1/trade/limit-order/create", "/v1/trade/limit-order/chase"):
            response = self.client.post(path, {}, format="json", HTTP_X_TRADING_MODE="lead")
            self.assertEqual(response.status_code, 400)

    @patch("trading.services._load_protection_account_snapshot")
    def test_mode_protection_batches_only_touch_their_own_accounts(self, snapshot):
        from trading.services import reconcile_open_orders_protection
        ordinary, lead = self.order("ordinary"), self.order("lead")
        snapshot.side_effect = BinanceApiError("account order limit", code="-1015")
        reconcile_open_orders_protection(trading_mode="lead")
        self.assertEqual(snapshot.call_args.args[0].pk, lead.pk)
        snapshot.reset_mock()
        snapshot.side_effect = None
        snapshot.return_value = None
        reconcile_open_orders_protection(trading_mode="ordinary")
        self.assertEqual(snapshot.call_count, 1)
        self.assertEqual(snapshot.call_args.args[0].pk, ordinary.pk)

    def mock_exchange(self):
        exchange = MagicMock()
        exchange.get_positions.return_value = {"data": []}
        exchange.get_pending_orders.return_value = {"data": []}
        exchange.get_pending_algo_orders.return_value = {"data": []}
        exchange.get_account_config.return_value = {"data": [{"posMode": "long_short_mode", "canTrade": True, "multiAssetsMargin": False}]}
        exchange.get_balance.return_value = {"data": [{"details": [{"availEq": "500", "eq": "500"}]}]}
        exchange.get_leverage_bracket.return_value = {"data": [{"notionalCap": "1000000", "maxLever": "10"}]}
        exchange.place_market_order.return_value = {"data": [{"ordId": "lead-market", "state": "filled", "accFillSz": "10", "avgPx": "100", "sz": "10", "side": "buy"}]}
        exchange.place_limit_order.return_value = {"data": [{"ordId": "lead-limit", "state": "live", "accFillSz": "0"}]}
        exchange.place_stop_market_order.return_value = {"data": [{"algoId": "lead-stop"}]}
        exchange.get_order.return_value = exchange.place_market_order.return_value
        rules = {"ctVal": "1", "lotSz": "0.001", "minSz": "0.001", "marketLotSz": "0.001", "tickSz": "0.1", "lever": "10"}
        cache.set("trade:inst_rules:BTC-USDT-SWAP", rules, 300)
        self.factories = []
        for target in ("trading.views.BinanceFuturesClient", "trading.services.BinanceFuturesClient", "positions.views.BinanceFuturesClient"):
            patcher = patch(target, return_value=exchange)
            self.factories.append(patcher.start())
            self.addCleanup(patcher.stop)
        for target, value in (("trading.views._extract_ticker", {"last": "100"}),
                              ("trading.views._extract_instrument", rules),
                              ("trading.adapters.get_usdt_equity_snapshot", ("500", "500"))):
            patcher = patch(target, return_value=value)
            patcher.start()
            self.addCleanup(patcher.stop)
        return exchange

    def test_full_lead_market_entry_is_idempotent_and_preserves_ordinary_orders(self):
        ordinary = self.order("ordinary")
        exchange = self.mock_exchange()
        payload = {"symbol": "BTCUSDT", "stop_loss_price": "90", "stop_loss_amount": "100", "include_fee": False,
                   "strategy_id": str(self.strategy.id),
                   "ema_check_id": "test-ema", "client_request_id": "11111111-1111-4111-8111-111111111111"}
        first = self.client.post("/v1/trade/open", payload, format="json", HTTP_X_TRADING_MODE="lead")
        self.assertEqual(first.status_code, 200, first.data)
        second = self.client.post("/v1/trade/open", payload, format="json", HTTP_X_TRADING_MODE="lead")
        self.assertEqual(second.status_code, 200, second.data)
        self.assertEqual(first.data["data"]["position_id"], second.data["data"]["position_id"])
        self.assertEqual(exchange.place_market_order.call_count, 1)
        lead = Order.objects.get(pk=first.data["data"]["position_id"])
        self.assertEqual(lead.trading_mode, "lead")
        self.assertEqual(lead.api_key_fingerprint, self.bindings["lead"].api_key_fingerprint)
        self.assertEqual(lead.size, Decimal("10"))
        self.assertTrue(exchange.place_stop_market_order.called)
        exchange.close_position.assert_not_called()
        self.assertEqual(Order.objects.get(pk=ordinary.pk).status, 0)
        self.assertEqual(self.factories[0].call_args.args[0].trading_mode, "lead")

    def test_limit_entry_and_background_partial_fill_use_same_lead_account(self):
        exchange = self.mock_exchange()
        exchange.get_order.return_value = exchange.place_limit_order.return_value
        payload = {"symbol": "BTCUSDT", "limit_price": "100", "stop_loss_price": "90", "stop_loss_amount": "100",
                   "strategy_id": str(self.strategy.id),
                   "client_request_id": "22222222-2222-4222-8222-222222222222"}
        response = self.client.post("/v1/trade/limit-order/create", payload, format="json", HTTP_X_TRADING_MODE="lead")
        self.assertEqual(response.status_code, 200, response.data)
        limit = LimitOrder.objects.get(trading_mode="lead")
        exchange.get_order.return_value = {"data": [{"ordId": "lead-limit", "state": "partially_filled", "accFillSz": "2", "avgPx": "100"}]}
        sync_limit_order_status(limit)
        limit.refresh_from_db()
        self.assertIsNotNone(limit.order_id)
        self.assertEqual(limit.order.trading_mode, "lead")
        self.assertEqual(limit.order.size, Decimal("2"))
        self.assertEqual(limit.order.api_key_fingerprint, limit.api_key_fingerprint)
        self.assertEqual(self.factories[1].call_args.args[0].trading_mode, "lead")

    def test_lead_chase_confirms_cancel_before_single_market_entry(self):
        exchange = self.mock_exchange()
        limit = LimitOrder.objects.create(user=self.user, trading_mode="lead", api_key_fingerprint=self.bindings["lead"].api_key_fingerprint,
            binance_order_id="lead-old-limit", symbol="BTCUSDT", side=0, limit_price=100, stop_loss_price=90, stop_loss_amount=100, size=10, leverage=10)
        cancelled = False
        def cancel(**kwargs):
            nonlocal cancelled
            cancelled = True
            return {"data": [{"ordId": limit.binance_order_id, "state": "canceled"}]}
        def get_order(*, order_id="", **kwargs):
            if order_id == limit.binance_order_id:
                return {"data": [{"ordId": order_id, "state": "canceled" if cancelled else "live", "accFillSz": "0"}]}
            return exchange.place_market_order.return_value
        def place_market(**kwargs):
            self.assertTrue(cancelled)
            return {"data": [{"ordId": "lead-market", "state": "filled", "accFillSz": kwargs["size"], "avgPx": "100"}]}
        exchange.cancel_order.side_effect = cancel
        exchange.get_order.side_effect = get_order
        exchange.place_market_order.side_effect = place_market
        response = self.client.post("/v1/trade/limit-order/chase", {"limit_order_id": limit.pk}, format="json", HTTP_X_TRADING_MODE="lead")
        self.assertEqual(response.status_code, 200, response.data)
        limit.refresh_from_db()
        self.assertEqual(limit.order.trading_mode, "lead")
        self.assertEqual(exchange.place_market_order.call_count, 1)

    def test_lead_lost_submission_response_recovers_without_resubmitting(self):
        exchange = self.mock_exchange()
        exchange.place_market_order.side_effect = BinanceApiError("timeout", outcome_unknown=True)
        payload = {"symbol": "BTCUSDT", "stop_loss_price": "90", "stop_loss_amount": "100",
                   "strategy_id": str(self.strategy.id),
                   "include_fee": False, "ema_check_id": "test-ema",
                   "client_request_id": "33333333-3333-4333-8333-333333333333"}
        response = self.client.post("/v1/trade/open", payload, format="json", HTTP_X_TRADING_MODE="lead")
        self.assertEqual(response.status_code, 200, response.data)
        replay = self.client.post("/v1/trade/open", payload, format="json", HTTP_X_TRADING_MODE="lead")
        self.assertEqual(replay.status_code, 200, replay.data)
        exchange.place_market_order.assert_called_once()
        self.assertEqual(Order.objects.get().trading_mode, "lead")

    @patch("trading.execution.time.sleep", return_value=None)
    def test_lead_uncertain_cancel_does_not_chase_or_touch_ordinary_order(self, _sleep):
        ordinary = self.order("ordinary")
        exchange = self.mock_exchange()
        limit = LimitOrder.objects.create(user=self.user, trading_mode="lead",
            api_key_fingerprint=self.bindings["lead"].api_key_fingerprint,
            binance_order_id="lead-pending", symbol="BTCUSDT", side=0, limit_price=100,
            stop_loss_price=90, stop_loss_amount=100, size=10, leverage=10)
        exchange.get_order.return_value = {"data": [{"ordId": "lead-pending", "state": "live", "accFillSz": "0"}]}
        response = self.client.post("/v1/trade/limit-order/chase", {"limit_order_id": limit.pk},
                                    format="json", HTTP_X_TRADING_MODE="lead")
        self.assertEqual(response.status_code, 400, response.data)
        exchange.place_market_order.assert_not_called()
        limit.refresh_from_db()
        self.assertEqual(limit.status, LimitOrder.STATUS_PENDING)
        self.assertEqual(Order.objects.get(pk=ordinary.pk).status, 0)

    def test_explicit_leverage_is_used_for_market_and_frozen_in_execution_intent(self):
        from trading.models import TradeOpenRequest
        exchange = self.mock_exchange()
        exchange.get_leverage_bracket.return_value = {'data': [{'instId': 'BTC-USDT-SWAP',
            'maxLever':'50','notionalCap':'100', 'brackets':[
                {'initialLeverage':50,'notionalCap':'100'}, {'initialLeverage':25,'notionalCap':'1000000'}]}]}
        payload = {'symbol':'BTCUSDT','stop_loss_price':'90','stop_loss_amount':'100','include_fee':False,
            'strategy_id':str(self.strategy.id),
            'ema_check_id':'test-ema','leverage':25,'client_request_id':'55555555-5555-4555-8555-555555555555'}
        response=self.client.post('/v1/trade/open',payload,format='json',HTTP_X_TRADING_MODE='lead')
        self.assertEqual(response.status_code,200,response.data)
        self.assertEqual(Order.objects.get(trading_mode='lead').leverage,25)
        self.assertEqual(exchange.set_leverage.call_args.kwargs['leverage'],25)
        self.assertEqual(TradeOpenRequest.objects.get().request_payload['_execution_intent']['leverage'],25)
        self.client.post('/v1/trade/open',payload,format='json',HTTP_X_TRADING_MODE='lead')
        self.assertEqual(exchange.place_market_order.call_count,1)

    def test_explicit_leverage_is_used_for_limit_entry(self):
        exchange=self.mock_exchange()
        exchange.get_order.return_value=exchange.place_limit_order.return_value
        exchange.get_leverage_bracket.return_value={'data':[{'instId':'BTC-USDT-SWAP','brackets':[
            {'initialLeverage':25,'notionalCap':'1000000'}]}]}
        payload={'symbol':'BTCUSDT','limit_price':'100','stop_loss_price':'90','stop_loss_amount':'100',
            'strategy_id':str(self.strategy.id),
            'leverage':25,'client_request_id':'66666666-6666-4666-8666-666666666666'}
        response=self.client.post('/v1/trade/limit-order/create',payload,format='json',HTTP_X_TRADING_MODE='lead')
        self.assertEqual(response.status_code,200,response.data)
        self.assertEqual(LimitOrder.objects.get(trading_mode='lead').leverage,25)
        self.assertEqual(exchange.set_leverage.call_args.kwargs['leverage'],25)
