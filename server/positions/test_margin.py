from copy import deepcopy
from dataclasses import replace
from datetime import datetime, timezone
from decimal import Decimal
from types import SimpleNamespace
from unittest.mock import patch

from django.core.cache import cache
from django.test import SimpleTestCase
from rest_framework.test import APIClient

from api_bindings.context import TradingAccountContext
from common.binance import BinanceApiError, BinanceCredentials, BinanceFuturesClient
from common.binance_rate_limit import RequestPriority, classify_request
from positions.margin import present_margin


def snapshot():
    return {"assets": [{"asset": "USDT", "walletBalance": "480", "unrealizedProfit": "-300",
                        "marginBalance": "180", "maintMargin": "190", "initialMargin": "270",
                        "positionInitialMargin": "250", "openOrderInitialMargin": "20",
                        "availableBalance": "0"}], "positions": [
        {"symbol": "AAAUSDT", "positionAmt": "10", "positionSide": "BOTH", "isolated": False,
         "leverage": "75", "positionInitialMargin": "100", "openOrderInitialMargin": "20",
         "maintMargin": "80", "unrealizedProfit": "-170"},
        {"symbol": "BBBUSDT", "positionAmt": "-2", "positionSide": "SHORT", "isolated": False,
         "leverage": "50", "positionInitialMargin": "150", "openOrderInitialMargin": "0",
         "maintMargin": "110", "unrealizedProfit": "-130"}]}


class MarginCalculationTests(SimpleTestCase):
    def present(self, value=None, multi=False):
        return present_margin({"multiAssetsMargin": multi}, value or snapshot(), observed_at=1000)

    def test_exchange_equity_is_denominator_not_available_or_initial_margin(self):
        result = self.present()
        self.assertEqual(Decimal(result["margin_ratio_percent"]), Decimal(190) / 180 * 100)
        self.assertTrue(result["liquidation_reached"])
        self.assertEqual(Decimal(result["total_usage_percent"]), Decimal(150))
        self.assertEqual(Decimal(result["position_usage_percent"]), Decimal(250) / 180 * 100)
        self.assertEqual(result["positions"][1]["side"], "short")
        self.assertEqual(result["positions"][0]["leverage"], "75")

    def test_actual_maintenance_not_inferred_from_leverage(self):
        data = snapshot()
        data["positions"][0]["leverage"] = "5"
        self.assertEqual(self.present(data)["margin_ratio_percent"], self.present()["margin_ratio_percent"])

    def test_zero_or_negative_equity_does_not_become_green_zero(self):
        for equity in ("0", "-10"):
            data = snapshot()
            data["assets"][0].update(marginBalance=equity, walletBalance=str(Decimal(equity) + 300))
            result = self.present(data)
            self.assertIsNone(result["margin_ratio_percent"])
            self.assertIsNone(result["total_usage_percent"])
            self.assertTrue(result["liquidation_reached"])

    def test_funded_empty_account_and_zero_balance(self):
        data = snapshot()
        data["positions"] = []
        data["assets"][0] = {key: "0" for key in data["assets"][0]}
        data["assets"][0].update(asset="USDT", walletBalance="100", marginBalance="100")
        self.assertEqual(self.present(data)["margin_ratio_percent"], "0")
        data["assets"][0].update(walletBalance="0", marginBalance="0")
        self.assertIsNone(self.present(data)["margin_ratio_percent"])

    def test_missing_nan_infinite_negative_and_inconsistent_fields_fail(self):
        for field in ("marginBalance", "maintMargin", "positionInitialMargin", "availableBalance"):
            for bad in (None, "NaN", "Infinity", "", True):
                data = snapshot()
                data["assets"][0][field] = bad
                with self.subTest(field=field, bad=bad), self.assertRaises(BinanceApiError):
                    self.present(data)
        for change in ({"maintMargin": "-1"}, {"marginBalance": "999"}, {"initialMargin": "1"}):
            data = snapshot()
            data["assets"][0].update(change)
            with self.assertRaises(BinanceApiError):
                self.present(data)

    def test_unsupported_modes_never_emit_a_cross_ratio(self):
        self.assertFalse(self.present(multi=True)["supported"])
        for field, value in (("isolated", True), ("symbol", "AAAUSDC")):
            data = snapshot()
            data["positions"][0][field] = value
            result = self.present(data)
            self.assertFalse(result["supported"])
            self.assertNotIn("margin_ratio_percent", result)
            self.assertTrue(result["reason"])

    def test_invalid_direction_mode_quantity_and_duplicate_positions_fail(self):
        for key, value in (("positionSide", "UNKNOWN"), ("positionAmt", "NaN"), ("isolated", None)):
            data = snapshot()
            data["positions"][0][key] = value
            with self.assertRaises(BinanceApiError):
                self.present(data)
        data = snapshot()
        data["positions"].append(deepcopy(data["positions"][0]))
        with self.assertRaises(BinanceApiError):
            self.present(data)

    def test_read_method_only_gets_and_reserves_full_background_weights(self):
        client = BinanceFuturesClient(BinanceCredentials(api_key="fixture", secret_key="fixture"))
        with patch.object(client, "_request", side_effect=[{"multiAssetsMargin": False}, snapshot()]) as request:
            client.get_margin_account_snapshot()
        self.assertEqual([call.args[:2] for call in request.call_args_list],
                         [("GET", "/fapi/v1/accountConfig"), ("GET", "/fapi/v2/account")])
        for call in request.call_args_list:
            self.assertEqual(call.kwargs["budget_priority"], RequestPriority.BACKGROUND)
            spec = classify_request(method="GET", path=call.args[1], base_url="https://fapi.binance.com",
                                    priority=RequestPriority.BACKGROUND)
            self.assertEqual(spec.weight, 5)
            self.assertFalse(spec.counts_as_order)

    def test_unfilled_order_occupancy_is_included_without_inventing_a_position(self):
        data = snapshot()
        data["positions"][0].update(positionAmt="0", positionInitialMargin="0", maintMargin="0", unrealizedProfit="0")
        data["assets"][0].update(positionInitialMargin="150", initialMargin="170", maintMargin="110")
        result = self.present(data)
        self.assertEqual(result["positions"][0]["side"], "none")
        self.assertEqual(result["positions"][0]["open_order_initial_margin"], "20")


class MarginEndpointTests(SimpleTestCase):
    def setUp(self):
        cache.clear()
        self.api = APIClient()
        self.api.force_authenticate(SimpleNamespace(id=7, is_authenticated=True))
        self.context = TradingAccountContext(7, 1, "fixture-key", "fixture", datetime(2026, 1, 1, tzinfo=timezone.utc),
                                            BinanceCredentials(api_key="fixture", secret_key="fixture"))

    def get(self, mode="ordinary"):
        return self.api.get("/v1/position/margin", HTTP_X_TRADING_MODE=mode)

    def test_authentication_required(self):
        self.api = APIClient()
        self.assertIn(self.get().status_code, (401, 403))

    @patch("positions.margin.get_user_binding_generation")
    @patch("positions.margin.get_user_trading_account")
    @patch("api_bindings.context.BinanceFuturesClient")
    def test_cache_and_binding_generation_are_isolated(self, client, account, generation):
        account.return_value = self.context
        generation.return_value = self.context.generation
        client.return_value.get_margin_account_snapshot.return_value = ({"multiAssetsMargin": False}, snapshot())
        self.assertEqual(self.get().status_code, 200)
        self.assertEqual(self.get().status_code, 200)
        self.assertEqual(client.call_count, 1)
        generation.return_value = ("another-key", self.context.binding_created_at)
        self.assertEqual(self.get().status_code, 409)

    @patch("positions.margin.get_user_trading_account", return_value=None)
    def test_unbound_lead_does_not_fall_back(self, account):
        self.assertEqual(self.get("lead").status_code, 400)
        self.assertEqual(account.call_args.kwargs["trading_mode"], "lead")

    @patch("positions.margin.get_user_binding_generation")
    @patch("positions.margin.get_user_trading_account")
    @patch("api_bindings.context.BinanceFuturesClient")
    def test_read_failure_not_cached_or_returned_as_zero(self, client, account, generation):
        account.return_value = self.context
        generation.return_value = self.context.generation
        client.return_value.get_margin_account_snapshot.side_effect = BinanceApiError("fixture unavailable")
        self.assertEqual(self.get().status_code, 400)
        self.assertEqual(self.get().status_code, 400)
        self.assertEqual(client.call_count, 2)

    @patch("positions.margin.get_user_binding_generation")
    @patch("positions.margin.get_user_trading_account")
    @patch("api_bindings.context.BinanceFuturesClient")
    def test_user_key_mode_and_binding_date_cannot_share_cache(self, client, account, generation):
        client.return_value.get_margin_account_snapshot.return_value = ({"multiAssetsMargin": False}, snapshot())
        contexts = [self.context, replace(self.context, user_id=8),
                    replace(self.context, api_key_fingerprint="second-key"),
                    replace(self.context, trading_mode="lead"),
                    replace(self.context, binding_created_at=datetime(2026, 2, 1, tzinfo=timezone.utc))]
        for context in contexts:
            account.return_value = context
            generation.return_value = context.generation
            self.assertEqual(self.get(context.trading_mode).status_code, 200)
        self.assertEqual(client.call_count, len(contexts))

    @patch("positions.margin.time")
    @patch("positions.margin.get_user_trading_account")
    @patch("api_bindings.context.BinanceFuturesClient")
    def test_slow_snapshot_is_rejected(self, client, account, clock):
        clock.time.side_effect = [0, 21]
        account.return_value = self.context
        client.return_value.get_margin_account_snapshot.return_value = ({"multiAssetsMargin": False}, snapshot())
        self.assertEqual(self.get().status_code, 400)
