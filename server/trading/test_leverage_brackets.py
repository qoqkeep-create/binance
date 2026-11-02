"""Leverage cards are signed reads, tested entirely against substitutes."""
from datetime import datetime, timezone
from decimal import Decimal
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from django.core.cache import cache
from django.test import TestCase
from rest_framework.test import APIClient, APIRequestFactory, force_authenticate

from common.binance import BinanceApiError
from trading.leverage_views import LeverageBracketsView
from users.models import User


class LeverageBracketsTests(TestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create(email="tiers@example.invalid")
        self.client = MagicMock()
        self.client.get_balance.return_value = {"data": [{"details": [{"availEq": "10000"}]}]}
        self.client.get_leverage_bracket.return_value = {"data": [{
            "instId": "BTC-USDT-SWAP", "maxLever": "50", "notionalCap": "250000",
            "brackets": [{"initialLeverage": "50", "notionalCap": "250000.125"},
                         {"initialLeverage": "25", "notionalCap": "1000000.00000001"}]}]}

    def account(self, owner=1, mode="ordinary", generation="a"):
        return SimpleNamespace(user_id=owner, binding_id=owner,
            binding_created_at=datetime(2026, 1, 1, tzinfo=timezone.utc),
            generation=(generation, mode), cache_namespace=f"{owner}:{mode}:{generation}",
            create_futures_client=MagicMock(return_value=self.client))

    def call(self, mode="ordinary", symbol="BTCUSDT", method="get"):
        request = getattr(APIRequestFactory(), method)("/v1/trade/leverage-brackets",
            {"symbol": symbol}, HTTP_X_TRADING_MODE=mode)
        force_authenticate(request, user=self.user)
        return LeverageBracketsView.as_view()(request)

    def test_public_route_requires_authentication_and_rejects_writes(self):
        client = APIClient()
        url = "/v1/trade/leverage-brackets"
        self.assertEqual(client.get(url, {"symbol": "BTCUSDT"}).status_code, 401)
        client.force_authenticate(user=self.user)
        self.assertEqual(client.post(url, {"symbol": "BTCUSDT"}).status_code, 405)
        self.client.get_leverage_bracket.assert_not_called()

    @patch("trading.leverage_views.get_user_trading_account", return_value=None)
    def test_unbound_account_never_reads_exchange(self, account):
        self.assertEqual(self.call().status_code, 400)
        self.client.get_leverage_bracket.assert_not_called()

    @patch("trading.leverage_views.get_user_trading_account")
    def test_all_tiers_preserve_decimal_caps_without_mutating_leverage(self, account):
        account.return_value = self.account()
        response = self.call()
        self.assertEqual(response.data["data"], {"symbol": "BTCUSDT", "brackets": [
            {"leverage": 50, "max_notional": "250000.125", "max_open_amount": "250000.125"},
            {"leverage": 25, "max_notional": "1000000.00000001", "max_open_amount": "250000"}]})
        self.call()
        self.client.get_leverage_bracket.assert_called_once_with("BTC-USDT-SWAP")
        self.assertEqual(self.client.get_balance.call_count, 2)
        self.client.set_leverage.assert_not_called()

    @patch("trading.leverage_views.get_user_trading_account")
    def test_cache_isolates_user_mode_and_binding_generation(self, account):
        for owner, mode, generation in [(1,"ordinary","a"),(1,"lead","a"),(2,"ordinary","a"),(1,"ordinary","b")]:
            account.return_value = self.account(owner, mode, generation)
            self.assertEqual(self.call(mode=mode).status_code, 200)
        self.assertEqual(self.client.get_leverage_bracket.call_count, 4)

    @patch("trading.leverage_views.get_user_trading_account")
    def test_previous_release_cache_does_not_break_new_capacity_cards(self, account):
        current = self.account()
        account.return_value = current
        generation = current.binding_created_at.isoformat()
        old_key = f"trade:leverage-tiers:{current.user_id}:{current.cache_namespace}:{generation}:BTCUSDT"
        cache.set(old_key, {"symbol": "BTCUSDT", "brackets": [
            {"leverage": 50, "max_notional": "250000.125"}]}, timeout=300)
        response = self.call()
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["data"]["brackets"][0]["max_open_amount"], "250000.125")
        self.client.get_leverage_bracket.assert_called_once_with("BTC-USDT-SWAP")

    @patch("trading.leverage_views.get_user_trading_account")
    def test_rebinding_during_read_rejects_old_response(self, account):
        account.side_effect = [self.account(generation="a"), self.account(generation="b")]
        self.assertEqual(self.call().status_code, 409)
        account.side_effect = None; account.return_value = self.account(generation="a")
        self.assertEqual(self.call().status_code, 200)
        self.assertEqual(self.client.get_leverage_bracket.call_count, 2)

    @patch("trading.leverage_views.get_user_trading_account")
    def test_failure_is_not_cached_or_replaced_by_invented_tiers(self, account):
        account.return_value = self.account()
        self.client.get_leverage_bracket.side_effect = [BinanceApiError("暂时不可用"), {"data": []}]
        self.assertEqual(self.call().status_code, 400)
        self.assertEqual(self.call().status_code, 400)
        self.assertEqual(self.client.get_leverage_bracket.call_count, 2)

    @patch("trading.leverage_views.get_user_trading_account")
    def test_invalid_symbol_and_post_do_not_read_or_write_exchange(self, account):
        self.assertEqual(self.call(symbol="../BTCUSDT").status_code, 400)
        self.assertEqual(self.call(method="post").status_code, 405)
        account.assert_not_called()

    @patch("trading.leverage_views.get_user_trading_account")
    def test_duplicate_leverage_uses_largest_cap_and_skips_invalid_values(self, account):
        account.return_value = self.account()
        self.client.get_leverage_bracket.return_value["data"][0]["brackets"] += [
            {"initialLeverage": "50", "notionalCap": "500000.25"},
            {"initialLeverage": "NaN", "notionalCap": "2"},
            {"initialLeverage": "0", "notionalCap": "2"},
            {"initialLeverage": "2", "notionalCap": "Infinity"}]
        result = self.call().data["data"]["brackets"]
        self.assertEqual(Decimal(next(row for row in result if row["leverage"] == 50)["max_notional"]), Decimal("500000.25"))
        self.assertEqual(len(result), 2)

    @patch("trading.leverage_views.get_user_trading_account")
    def test_only_three_highest_funded_capacities_are_returned(self, account):
        account.return_value = self.account()
        self.client.get_leverage_bracket.return_value['data'][0]['brackets'] = [
            {'initialLeverage': value, 'notionalCap': str(1000000 / value)} for value in [100, 50, 25, 10, 5]]
        self.client.get_balance.return_value = {'data': [{'details': [{'availEq': '1000'}]}]}
        rows = self.call().data['data']['brackets']
        self.assertEqual([row['leverage'] for row in rows], [25, 50, 10])
        self.client.get_balance.return_value = {'data': [{'details': [{'availEq': '10'}]}]}
        self.assertEqual(self.call().data['data']['brackets'][0]['leverage'], 100)

    def test_selected_leverage_checks_its_cap_before_any_exchange_write(self):
        from trading.leverage_views import opening_leverage
        value = opening_leverage(self.client, 'BTC-USDT-SWAP', 25, size='5000', entry_price=Decimal('100'), instrument={})
        self.assertEqual(value, 25)
        with self.assertRaises(BinanceApiError):
            opening_leverage(self.client, 'BTC-USDT-SWAP', 50, size='5000', entry_price=Decimal('100'), instrument={})
        with self.assertRaises(BinanceApiError):
            opening_leverage(self.client, 'BTC-USDT-SWAP', 3, size='1', entry_price=Decimal('100'), instrument={})
        self.client.set_leverage.assert_not_called()
