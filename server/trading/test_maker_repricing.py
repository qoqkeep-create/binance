from contextlib import ExitStack
from decimal import Decimal
from unittest.mock import MagicMock, patch

from rest_framework.test import APITestCase

from api_bindings.context import TradingAccountContext
from common.binance import BinanceApiError
from trading.models import TradeOpenRequest
from users.models import User


class MakerRepricingTests(APITestCase):
    """Exercise the open API with a book that moves before Binance accepts GTX."""

    def setUp(self):
        self.user = User.objects.create_user(email="maker-reprice@example.com", password="test-pass")
        self.client.force_authenticate(self.user)
        self.exchange = MagicMock()
        self.exchange.get_account_config.return_value = {"data": [{"posMode": "long_short_mode"}]}
        self.exchange.get_order.return_value = {"data": []}
        self.account = TradingAccountContext(
            user_id=self.user.id, binding_id=0, api_key_fingerprint="", alias="test",
            binding_created_at=None, credentials=object(),
        )
        stack = self.enterContext(ExitStack())
        for name, value in {
            "get_user_trading_account": self.account,
            "BinanceFuturesClient": self.exchange,
            "_has_unresolved_stop_protection": False,
            "load_exchange_activity": {},
            "check_duplicate_order": None,
            "_entry_capital_error": None,
            "_extract_ticker": {"last": "100"},
            "_extract_instrument": {
                "ctVal": "1", "lotSz": "0.001", "marketLotSz": "0.001", "tickSz": "0.1",
            },
            "_resolve_max_leverage": 10,
            "_ensure_notional_within_cap": None,
            "_ensure_available_margin": None,
            "_set_opening_leverage": None,
            "_resolve_strategy_snapshot_payload": {
                "strategy_id": "1", "strategy_name": "Test", "strategy_config": {},
            },
        }.items():
            stack.enter_context(patch(f"trading.views.{name}", return_value=value))
        stack.enter_context(patch("trading.opening.ORDER_RECOVERY_RETRY_DELAYS_SECONDS", (0,)))
        self.payload = {
            "symbol": "BTCUSDT", "stop_loss_price": "90", "stop_loss_amount": "50",
            "include_fee": False, "strategy_id": "1", "execution_mode": "maker",
            "client_request_id": "22222222-2222-4222-8222-222222222222",
        }

    def book(self, bid, ask):
        return {"data": [{"bidPx": str(bid), "askPx": str(ask)}]}

    def accepted(self, **changes):
        return {"data": [{
            "ordId": "maker-accepted", "state": "live", "sz": "5", "side": "buy",
            "fillSz": "0", "accFillSz": "0", "avgPx": "0", **changes,
        }]}

    def post(self):
        return self.client.post("/v1/trade/open", self.payload, format="json")

    def test_definitive_rejection_reprices_buy_and_persists_before_next_gtx(self):
        self.exchange.get_book_ticker.side_effect = [self.book("99.9", "100"), self.book("99.7", "99.8")]
        seen_intents = []

        def submit(**kwargs):
            intent = TradeOpenRequest.objects.get().request_payload["_execution_intent"]
            seen_intents.append(dict(intent))
            self.assertEqual(Decimal(intent["maker_price"]), Decimal(kwargs["price"]))
            if len(seen_intents) == 1:
                raise BinanceApiError("Post Only would take liquidity", code="-5022")
            return self.accepted()

        self.exchange.place_limit_order.side_effect = submit
        response = self.post()

        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["data"]["state"], "PENDING_MAKER")
        calls = self.exchange.place_limit_order.call_args_list
        self.assertEqual([Decimal(call.kwargs["price"]) for call in calls], [Decimal("99.8"), Decimal("99.6")])
        self.assertEqual(calls[0].kwargs["new_client_order_id"], calls[1].kwargs["new_client_order_id"])
        self.assertEqual(calls[0].kwargs["size"], calls[1].kwargs["size"])
        self.assertTrue(all(call.kwargs["time_in_force"] == "GTX" for call in calls))
        self.assertEqual(TradeOpenRequest.objects.get().status, TradeOpenRequest.STATUS_SUBMITTED)
        self.exchange.place_market_order.assert_not_called()

    def test_buy_reprice_never_moves_toward_a_more_expensive_quote(self):
        self.exchange.get_book_ticker.side_effect = [self.book("99.9", "100"), self.book("100.5", "100.6")]
        self.exchange.place_limit_order.side_effect = [BinanceApiError("GTX rejected", code="-5022"), self.accepted()]
        response = self.post()
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual([Decimal(call.kwargs["price"]) for call in self.exchange.place_limit_order.call_args_list],
                         [Decimal("99.8"), Decimal("99.8")])

    def test_sell_reprice_never_moves_toward_a_cheaper_quote(self):
        self.payload["stop_loss_price"] = "110"
        self.exchange.get_book_ticker.side_effect = [self.book("100", "100.1"), self.book("99.5", "99.6")]
        self.exchange.place_limit_order.side_effect = [BinanceApiError("GTX rejected", code="-5022"), self.accepted(side="sell")]
        response = self.post()
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual([Decimal(call.kwargs["price"]) for call in self.exchange.place_limit_order.call_args_list],
                         [Decimal("100.2"), Decimal("100.2")])

    def test_three_definitive_rejections_stop_with_actionable_chinese_error(self):
        self.exchange.get_book_ticker.return_value = self.book("99.9", "100")
        self.exchange.place_limit_order.side_effect = BinanceApiError("Post Only would take liquidity", code="-5022")
        response = self.post()
        self.assertEqual(response.status_code, 400, response.data)
        self.assertIn("Maker", response.data["message"])
        self.assertIn("未挂成", response.data["message"])
        self.assertEqual(self.exchange.place_limit_order.call_count, 3)
        self.assertEqual(TradeOpenRequest.objects.get().status, TradeOpenRequest.STATUS_FAILED)
        self.exchange.place_market_order.assert_not_called()

    def test_price_crossing_original_stop_does_not_reverse_direction_or_retry(self):
        self.exchange.get_book_ticker.side_effect = [self.book("99.9", "100"), self.book("89.9", "90")]
        self.exchange.place_limit_order.side_effect = BinanceApiError("GTX rejected", code="-5022")
        response = self.post()
        self.assertEqual(response.status_code, 400, response.data)
        self.assertIn("止损", response.data["message"])
        self.assertEqual(self.exchange.place_limit_order.call_count, 1)

    def test_unknown_outcome_never_reprices_or_resends_even_on_same_api_retry(self):
        self.exchange.get_book_ticker.return_value = self.book("99.9", "100")
        self.exchange.place_limit_order.side_effect = BinanceApiError("timeout", outcome_unknown=True)
        first = self.post()
        second = self.post()
        self.assertEqual(first.status_code, 409, first.data)
        self.assertEqual(second.status_code, 409, second.data)
        self.assertEqual(self.exchange.place_limit_order.call_count, 1)
        self.assertEqual(self.exchange.get_book_ticker.call_count, 1)
        self.exchange.place_market_order.assert_not_called()

    def test_unknown_flag_overrides_post_only_error_code(self):
        self.exchange.get_book_ticker.return_value = self.book("99.9", "100")
        self.exchange.place_limit_order.side_effect = BinanceApiError("unknown", code="-5022", outcome_unknown=True)
        response = self.post()
        self.assertEqual(response.status_code, 409, response.data)
        self.assertEqual(self.exchange.place_limit_order.call_count, 1)
        self.assertEqual(self.exchange.get_book_ticker.call_count, 1)

    def test_unknown_reply_after_reprice_keeps_last_intent_and_does_not_submit_a_third_order(self):
        self.exchange.get_book_ticker.side_effect = [self.book("99.9", "100"), self.book("99.7", "99.8")]
        self.exchange.place_limit_order.side_effect = [
            BinanceApiError("GTX rejected", code="-5022"),
            BinanceApiError("timeout", outcome_unknown=True),
        ]
        response = self.post()
        self.assertEqual(response.status_code, 409, response.data)
        self.assertEqual(self.exchange.place_limit_order.call_count, 2)
        intent = TradeOpenRequest.objects.get().request_payload["_execution_intent"]
        self.assertEqual(Decimal(intent["maker_price"]), Decimal("99.6"))
        self.assertEqual(Decimal(intent["maker_market_price"]), Decimal("99.8"))
        self.exchange.place_market_order.assert_not_called()

    def test_retry_of_a_failed_request_returns_to_unresolved_before_an_unknown_write(self):
        self.exchange.get_book_ticker.return_value = self.book("99.9", "100")
        self.exchange.place_limit_order.side_effect = BinanceApiError("GTX rejected", code="-5022")
        self.assertEqual(self.post().status_code, 400)
        record = TradeOpenRequest.objects.get()
        self.assertEqual(record.status, TradeOpenRequest.STATUS_FAILED)
        self.exchange.place_limit_order.side_effect = BinanceApiError("timeout", outcome_unknown=True)
        second = self.post()
        third = self.post()
        self.assertEqual(second.status_code, 409, second.data)
        self.assertEqual(third.status_code, 409, third.data)
        record.refresh_from_db()
        self.assertNotEqual(record.status, TradeOpenRequest.STATUS_FAILED)
        self.assertEqual(self.exchange.place_limit_order.call_count, 4)

    def test_timeout_can_recover_the_same_repriced_order_without_another_write(self):
        self.exchange.get_book_ticker.side_effect = [self.book("99.9", "100"), self.book("99.7", "99.8")]
        self.exchange.place_limit_order.side_effect = [
            BinanceApiError("GTX rejected", code="-5022"),
            BinanceApiError("timeout", outcome_unknown=True),
        ]
        self.exchange.get_order.return_value = self.accepted()
        response = self.post()
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["data"]["maker_order_id"], "maker-accepted")
        self.assertEqual(self.exchange.place_limit_order.call_count, 2)
        self.assertEqual(response.data["data"]["maker_price"], "99.6")
        query = self.exchange.get_order.call_args.kwargs
        self.assertEqual(query["orig_client_order_id"], TradeOpenRequest.objects.get().client_order_id)

    def test_unrelated_definitive_error_does_not_reprice(self):
        self.exchange.get_book_ticker.return_value = self.book("99.9", "100")
        self.exchange.place_limit_order.side_effect = BinanceApiError("insufficient margin", code="-2019")
        response = self.post()
        self.assertEqual(response.status_code, 400, response.data)
        self.assertEqual(self.exchange.place_limit_order.call_count, 1)
        self.assertEqual(self.exchange.get_book_ticker.call_count, 1)
