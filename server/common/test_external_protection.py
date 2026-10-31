from decimal import Decimal
from unittest.mock import patch

from django.test import SimpleTestCase

from common.binance import BinanceApiError, BinanceCredentials, BinanceFuturesClient
from common.binance_rate_limit import RequestPriority


class ExternalProtectionAdapterTests(SimpleTestCase):
    def setUp(self):
        self.client = BinanceFuturesClient(BinanceCredentials(api_key="test", secret_key="test"))

    def algo_row(self, **changes):
        return {
            "algoId": 123,
            "clientAlgoId": "external-stop-123",
            "symbol": "BTCUSDT",
            "orderType": "STOP_MARKET",
            "algoStatus": "NEW",
            "side": "SELL",
            "positionSide": "BOTH",
            "triggerPrice": "59000",
            "quantity": "0.2",
            "reduceOnly": "true",
            "closePosition": "false",
            "workingType": "CONTRACT_PRICE",
            "priceProtect": "false",
            **changes,
        }

    def position(self, **changes):
        return {
            "instId": "BTC-USDT-SWAP", "posSide": "long", "pos": "0.2",
            "rawPositionSide": "BOTH", **changes,
        }

    def test_full_close_stop_without_quantity_is_not_discarded(self):
        for quantity in (None, "0", 0):
            with self.subTest(quantity=quantity), patch.object(
                self.client, "_request",
                return_value=[self.algo_row(quantity=quantity, closePosition="true", reduceOnly="false")],
            ):
                rows = self.client.get_pending_algo_orders(inst_id="BTC-USDT-SWAP")["data"]
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["sz"], "0")
            self.assertTrue(rows[0]["closePosition"])
            self.assertFalse(rows[0]["reduceOnly"])
            self.assertFalse(rows[0]["priceProtect"])
            self.assertEqual(rows[0]["rawPositionSide"], "BOTH")
            self.assertEqual(rows[0]["workingType"], "CONTRACT_PRICE")

    def test_protection_flags_preserve_boolean_and_string_false(self):
        for value in (False, "false", "FALSE", None):
            with self.subTest(value=value), patch.object(
                self.client, "_request",
                return_value=[self.algo_row(reduceOnly=value, closePosition=value, priceProtect=value)],
            ):
                row = self.client.get_pending_algo_orders()["data"][0]
            self.assertFalse(row["reduceOnly"])
            self.assertFalse(row["closePosition"])
            self.assertFalse(row["priceProtect"])

    def test_algo_client_id_lookup_includes_terminal_order_and_checks_identity(self):
        with patch.object(self.client, "_request", return_value=self.algo_row(algoStatus="CANCELED")) as request:
            rows = self.client.get_algo_order_by_client_id("BTC-USDT-SWAP", "external-stop-123")["data"]
        self.assertEqual(rows[0]["state"], "canceled")
        request.assert_called_once_with(
            "GET", "/fapi/v1/algoOrder", {"clientAlgoId": "external-stop-123"},
            signed=True, budget_priority=RequestPriority.CRITICAL,
        )
        for overrides in ({"symbol": "ETHUSDT"}, {"clientAlgoId": "other"}):
            with self.subTest(overrides=overrides), patch.object(
                self.client, "_request", return_value=self.algo_row(**overrides),
            ):
                with self.assertRaises(BinanceApiError):
                    self.client.get_algo_order_by_client_id("BTC-USDT-SWAP", "external-stop-123")

    def test_position_raw_pnl_and_identity_survive_normalization(self):
        for pnl in (None, "bad", "NaN", "-101.25"):
            payload = {
                "symbol": "BTCUSDT", "positionAmt": "-0.2", "positionSide": "SHORT",
                "entryPrice": "60000", "markPrice": "60100", "updateTime": 123456,
                "unRealizedProfit": pnl,
            }
            with self.subTest(pnl=pnl), patch.object(self.client, "_request", return_value=[payload]):
                row = self.client.get_positions()["data"][0]
            self.assertEqual(row["rawUpl"], pnl)
            self.assertEqual(row["rawPositionSide"], "SHORT")
            self.assertEqual(row["updateTime"], 123456)

    def test_order_recovery_keeps_identity_and_actual_partial_fill(self):
        payload = {
            "orderId": 456, "clientOrderId": "external-close-123", "positionSide": "SHORT",
            "symbol": "BTCUSDT",
            "side": "BUY", "reduceOnly": "false", "status": "PARTIALLY_FILLED",
            "origQty": "0.2", "executedQty": "0.03",
        }
        with patch.object(self.client, "_request", return_value=payload):
            row = self.client.get_order("BTC-USDT-SWAP", orig_client_order_id="external-close-123")["data"][0]
        self.assertEqual(row["clientOrderId"], "external-close-123")
        self.assertEqual(row["instId"], "BTC-USDT-SWAP")
        self.assertEqual(row["rawPositionSide"], "SHORT")
        self.assertEqual(row["side"], "buy")
        self.assertFalse(row["reduceOnly"])
        self.assertEqual(row["sz"], "0.2")
        self.assertEqual(row["fillSz"], "0.03")
        self.assertEqual(row["state"], "partially_filled")

    def test_close_and_recovery_never_fabricate_receipt_symbol(self):
        for symbol, expected in (("ETHUSDT", "ETH-USDT-SWAP"), (None, ""), ("invalid", "")):
            payload = {"orderId": 456, "status": "FILLED", "executedQty": "0.2", "symbol": symbol}
            with self.subTest(symbol=symbol), patch.object(self.client, "_request", return_value=payload), patch.object(
                self.client, "get_positions", return_value={"data": [self.position()]},
            ), patch.object(self.client, "_normalize_order_quantity", return_value="0.2"):
                close = self.client.close_position("BTC-USDT-SWAP", expected_side="long")["data"][0]
                recovery = self.client.get_order("BTC-USDT-SWAP", order_id="456")["data"][0]
                self.assertEqual(close["instId"], expected)
                self.assertEqual(recovery["instId"], expected)

    def test_account_positions_ignore_unsupported_contracts_but_target_query_is_strict(self):
        supported = {"symbol": "BTCUSDT", "positionAmt": "0.2", "entryPrice": "60000", "markPrice": "60100"}
        unsupported = [{"symbol": symbol, "positionAmt": "1"} for symbol in ("ETHUSDC", "BTCUSD1", "BTCUSDT_261225")]
        with patch.object(self.client, "_request", return_value=[*unsupported, supported]):
            self.assertEqual([row["instId"] for row in self.client.get_positions()["data"]], ["BTC-USDT-SWAP"])
        for symbol in ("ETHUSDC", "ETHUSDT", ""):
            with self.subTest(symbol=symbol), patch.object(self.client, "_request", return_value=[{**supported, "symbol": symbol}]):
                with self.assertRaises(BinanceApiError):
                    self.client.get_positions(inst_id="BTC-USDT-SWAP")

    def test_stop_market_can_preserve_mark_price_reference(self):
        for working_type in ("MARK_PRICE", "CONTRACT_PRICE"):
            with self.subTest(working_type=working_type), patch.object(
                self.client, "_get_public_instrument", return_value={},
            ), patch("common.binance.standardize_trigger_order_request", return_value={
                "trigger_price": Decimal("59000"), "quantity": Decimal("0.2"),
            }), patch.object(self.client, "_request", return_value={"algoId": 123}) as request:
                self.client.place_stop_market_order("BTC-USDT-SWAP", "sell", "0.2", "59000", working_type=working_type)
            self.assertEqual(request.call_args.args[2]["workingType"], working_type)
            self.assertEqual(request.call_args.args[2]["priceProtect"], "FALSE")
        with patch.object(self.client, "_request") as request, patch.object(self.client, "_get_public_instrument") as instrument:
            with self.assertRaises(BinanceApiError):
                self.client.place_stop_market_order("BTC-USDT-SWAP", "sell", "0.2", "59000", working_type="UNKNOWN")
            request.assert_not_called()
            instrument.assert_not_called()

    def test_malformed_position_snapshot_does_not_prove_flat_position(self):
        for payload in (
            {}, None, "", {"data": None}, {"data": {}}, [None], ["row"], [{}],
            [{"symbol": "BTCUSDT", "positionAmt": "NaN"}],
            [{"symbol": "BTCUSDT", "positionAmt": "Infinity"}],
            [{"symbol": "BTCUSDT", "positionAmt": "invalid"}],
            [{"symbol": "BTCUSDT"}],
        ):
            with self.subTest(payload=payload), patch.object(self.client, "_request", return_value=payload):
                with self.assertRaises(BinanceApiError):
                    self.client.get_positions()
        for payload in ([], {"data": []}):
            with self.subTest(payload=payload), patch.object(self.client, "_request", return_value=payload):
                self.assertEqual(self.client.get_positions()["data"], [])

    def test_missing_requested_side_never_closes_other_side(self):
        with patch.object(self.client, "get_positions", return_value={"data": [self.position(posSide="short", pos="-0.2")]}), patch.object(
            self.client, "_request",
        ) as request, patch.object(self.client, "_normalize_order_quantity", return_value="0.2"):
            self.assertEqual(self.client.close_position("BTC-USDT-SWAP", pos_side="long")["data"], [])
            self.assertEqual(self.client.close_position("BTC-USDT-SWAP", expected_side="long")["data"], [])
        request.assert_not_called()

    def test_one_way_close_retains_reduce_only_and_caps_quantity(self):
        with patch.object(self.client, "get_positions", return_value={"data": [self.position()]}), patch.object(
            self.client, "_normalize_order_quantity", side_effect=lambda inst, qty, kind: qty,
        ), patch.object(self.client, "_request", return_value={"orderId": 456, "status": "FILLED", "executedQty": "0.1"}) as request:
            result = self.client.close_position(
                "BTC-USDT-SWAP", pos_side="long", expected_side="long",
                client_order_id="external-close-123", max_quantity=Decimal("0.1"),
            )["data"][0]
        params = request.call_args.args[2]
        self.assertEqual(params["reduceOnly"], "true")
        self.assertNotIn("positionSide", params)
        self.assertEqual(params["newClientOrderId"], "external-close-123")
        self.assertEqual(params["quantity"], "0.1")
        self.assertEqual(params["side"], "SELL")
        self.assertEqual(result["fillSz"], "0.1")
        self.assertEqual(result["state"], "filled")

    def test_hedge_close_uses_live_position_side_without_reduce_only(self):
        with patch.object(self.client, "get_positions", return_value={"data": [self.position(posSide="short", rawPositionSide="SHORT")]}), patch.object(
            self.client, "_normalize_order_quantity", return_value="0.2",
        ), patch.object(self.client, "_request", return_value={"orderId": 456, "status": "NEW", "origQty": "0.2"}) as request:
            result = self.client.close_position("BTC-USDT-SWAP", expected_side="short")["data"][0]
        params = request.call_args.args[2]
        self.assertEqual(params["positionSide"], "SHORT")
        self.assertEqual(params["side"], "BUY")
        self.assertNotIn("reduceOnly", params)
        self.assertEqual(result["fillSz"], "0")
        self.assertEqual(result["state"], "live")

    def test_unknown_close_result_is_never_retried_by_adapter(self):
        with patch.object(self.client, "get_positions", return_value={"data": [self.position()]}), patch.object(
            self.client, "_normalize_order_quantity", return_value="0.2",
        ), patch.object(self.client, "_request", side_effect=BinanceApiError("timeout", outcome_unknown=True)) as request:
            with self.assertRaises(BinanceApiError):
                self.client.close_position("BTC-USDT-SWAP", expected_side="long", client_order_id="external-close-123")
        self.assertEqual(request.call_count, 1)

    def test_filled_receipt_without_executed_quantity_does_not_fabricate_fill(self):
        with patch.object(self.client, "get_positions", return_value={"data": [self.position()]}), patch.object(
            self.client, "_normalize_order_quantity", return_value="0.2",
        ), patch.object(self.client, "_request", return_value={"orderId": 456, "status": "FILLED", "origQty": "0.2"}):
            row = self.client.close_position("BTC-USDT-SWAP", expected_side="long")["data"][0]
        self.assertEqual(row["sz"], "0.2")
        self.assertEqual(row["fillSz"], "0")

    def test_conflicting_sides_or_invalid_max_quantity_do_not_submit(self):
        for overrides in (
            {"pos_side": "short"}, {"expected_side": "invalid"},
            {"max_quantity": Decimal("-1")}, {"max_quantity": Decimal("NaN")},
        ):
            with self.subTest(overrides=overrides), patch.object(
                self.client, "get_positions", return_value={"data": [self.position()]},
            ), patch.object(self.client, "_request") as request:
                with self.assertRaises(BinanceApiError):
                    self.client.close_position("BTC-USDT-SWAP", **{"expected_side": "long", **overrides})
            request.assert_not_called()
