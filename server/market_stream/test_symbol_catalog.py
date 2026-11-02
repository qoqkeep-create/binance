from unittest.mock import patch

from django.core.cache import cache
from django.test import TestCase, override_settings
from rest_framework.test import APIRequestFactory, force_authenticate

from market_stream import service
from market_stream.models import MarketSymbol
from market_stream.views import SymbolsView, TickersView, WatchlistView


@override_settings(MARKET_QUOTE_ASSET="USDT")
class SymbolCatalogTests(TestCase):
    def setUp(self):
        from users.models import User
        cache.clear()
        self.user = User.objects.create(email="catalog-fixture@example.invalid")

    def request(self, view, path, **kwargs):
        request = APIRequestFactory().get(path)
        force_authenticate(request, user=self.user)
        return view.as_view()(request, **kwargs)

    @patch("market_stream.service.tickers")
    def test_search_returns_the_pagination_contract_decoded_by_ios(self, tickers):
        tickers.return_value = [{"symbol": "BTCUSDT"}, {"symbol": "ETHUSDT"}]
        response = self.request(TickersView, "/api/market/tickers/search?query=USDT&size=1&page=0", kind="search")
        data = response.data["data"]
        self.assertEqual({key: data.get(key) for key in ("query", "page", "size", "totalElements", "totalPages")},
                         {"query": "USDT", "page": 0, "size": 1, "totalElements": 2, "totalPages": 2})
        self.assertTrue(data["hasNext"])
        self.assertEqual(data["items"], [{"symbol": "BTCUSDT"}])

    @patch("market_stream.service.public_request")
    def test_catalog_and_defaults_use_durable_directory_after_cache_loss(self, upstream):
        MarketSymbol.objects.create(symbol="ETHUSDT", quote_asset="USDT")
        MarketSymbol.objects.create(symbol="BTCUSDT", quote_asset="USDT")
        MarketSymbol.objects.create(symbol="OLDUSDT", quote_asset="USDT", active=False)
        MarketSymbol.objects.create(symbol="BTCUSDC", quote_asset="USDC")
        for view in (SymbolsView, WatchlistView):
            response = self.request(view, "/api/market/symbols")
            self.assertEqual(response.status_code, 200)
            self.assertEqual(set(response.data["data"]["symbols"]), {"BTCUSDT", "ETHUSDT"})
        upstream.assert_not_called()

    @patch("market_stream.service.public_request")
    def test_empty_catalog_fails_promptly_without_requesting_binance(self, upstream):
        response = self.request(SymbolsView, "/api/market/symbols")
        self.assertEqual(response.status_code, 503)
        upstream.assert_not_called()

    @patch("market_stream.service.public_request")
    def test_collector_refresh_persists_active_contracts_and_retains_last_snapshot_on_failure(self, upstream):
        def contract(symbol, **values):
            return {"symbol": symbol, "quoteAsset": "USDT", "status": "TRADING", "contractType": "PERPETUAL", **values}
        upstream.return_value = {"symbols": [contract("BTCUSDT"), contract("ETHUSDT"),
            contract("OLDUSDT", status="SETTLING"), contract("BTCUSDC", quoteAsset="USDC"),
            contract("BTCUSDT_261225", contractType="CURRENT_QUARTER")]}
        self.assertEqual(service.symbols(refresh=True), ["BTCUSDT", "ETHUSDT"])
        cache.clear()
        self.assertEqual(service.symbols(cached_only=True), ["BTCUSDT", "ETHUSDT"])
        upstream.return_value = {"symbols": [contract("BTCUSDT")]}
        service.symbols(refresh=True)
        self.assertFalse(MarketSymbol.objects.get(symbol="ETHUSDT").active)
        upstream.return_value = {"symbols": []}
        with self.assertRaises(ValueError):
            service.symbols(refresh=True)
        cache.clear()
        self.assertEqual(service.symbols(cached_only=True), ["BTCUSDT"])


@override_settings(MARKET_QUOTE_ASSET="USDT")
class SavedCatalogTests(TestCase):
    def setUp(self):
        from users.models import User
        from market_stream.models import MarketCapitalization
        from django.utils import timezone
        cache.clear()
        self.user = User.objects.create_user(email="catalog@example.invalid", password="test-only-password")
        self.other = User.objects.create_user(email="other-catalog@example.invalid", password="test-only-password")
        for symbol in ["BTCUSDT", "ETHUSDT", "ADAUSDT", "1000SHIBUSDT", "NEWUSDT"]:
            MarketSymbol.objects.create(symbol=symbol, quote_asset="USDT")
        MarketCapitalization.objects.create(coins={"BTC": {"market_cap": "1000000"},
            "ETH": {"market_cap": "500000"}, "ADA": {"market_cap": "10000"},
            "SHIB": {"market_cap": "20000"}}, refreshed_at=timezone.now())

    def call(self, method="get", data=None, user=None):
        request = getattr(APIRequestFactory(), method)("/api/market/watchlist", data or {}, format="json")
        force_authenticate(request, user=user or self.user)
        return WatchlistView.as_view()(request)

    @patch("market_stream.catalog._fetch_coins")
    def test_saved_order_empty_list_and_user_isolation_survive_cache_loss(self, upstream):
        self.assertEqual(self.call("post", {"symbols": ["ADAUSDT", "BTCUSDT", "ADAUSDT"]}).data["code"], 200)
        cache.clear()
        saved = self.call().data["data"]
        self.assertTrue(saved["isCustomized"])
        self.assertEqual(saved["symbols"], ["ADAUSDT", "BTCUSDT"])
        self.assertFalse(self.call(user=self.other).data["data"]["isCustomized"])
        self.call("post", {"symbols": []})
        self.assertEqual(self.call().data["data"]["symbols"], [])
        self.assertTrue(self.call().data["data"]["isCustomized"])
        upstream.assert_not_called()

    def test_invalid_or_delisted_symbols_do_not_replace_saved_watchlist(self):
        self.call("post", {"symbols": ["ETHUSDT"]})
        for data in [{"symbols": ["WRONGUSDT"]}, {"symbols": "BTCUSDT"}, {"symbols": [None]}]:
            self.assertNotEqual(self.call("post", data).data["code"], 200)
            self.assertEqual(self.call().data["data"]["symbols"], ["ETHUSDT"])

    def test_catalog_uses_market_cap_and_underlying_bundle_with_unknowns_last(self):
        result = self.call().data["data"]
        self.assertEqual(result["availableSymbols"], ["BTCUSDT", "ETHUSDT", "1000SHIBUSDT", "ADAUSDT", "NEWUSDT"])
        self.assertEqual(result["marketCaps"]["1000SHIBUSDT"], "20000")
        self.assertIsNotNone(result["marketCapsUpdatedAt"])

    @patch("market_stream.catalog._fetch_coins")
    def test_weekly_refresh_does_not_refetch_fresh_snapshot(self, upstream):
        from market_stream.catalog import refresh_market_caps
        self.assertFalse(refresh_market_caps())
        upstream.assert_not_called()

    @patch("market_stream.catalog._fetch_coins")
    def test_due_refresh_persists_decimal_amounts_and_skips_next_week(self, upstream):
        from datetime import timedelta
        from django.utils import timezone
        from market_stream.models import MarketCapitalization
        from market_stream.catalog import refresh_market_caps
        MarketCapitalization.objects.update(refreshed_at=timezone.now() - timedelta(days=8))
        upstream.return_value = [{"symbol": "eth", "id": "ethereum", "market_cap": "123456789012345.125"},
                                 {"symbol": "eth", "id": "smaller-token", "market_cap": "12"}]
        self.assertTrue(refresh_market_caps())
        self.assertEqual(MarketCapitalization.objects.get().coins["ETH"]["market_cap"], "123456789012345.125")
        self.assertFalse(refresh_market_caps())
        upstream.assert_called_once()

    @patch("market_stream.catalog._fetch_coins", side_effect=TimeoutError)
    def test_failed_refresh_keeps_snapshot_and_backs_off(self, upstream):
        from datetime import timedelta
        from django.utils import timezone
        from market_stream.models import MarketCapitalization
        from market_stream.catalog import refresh_market_caps
        MarketCapitalization.objects.update(refreshed_at=timezone.now() - timedelta(days=8))
        original = MarketCapitalization.objects.get().coins
        with self.assertRaises(TimeoutError):
            refresh_market_caps()
        self.assertEqual(MarketCapitalization.objects.get().coins, original)
        self.assertFalse(refresh_market_caps())
        upstream.assert_called_once()

    @patch("market_stream.catalog.time.sleep")
    @patch("market_stream.catalog._fetch_coins")
    def test_later_batch_failure_does_not_publish_partial_ranking(self, upstream, sleep):
        from datetime import timedelta
        from django.utils import timezone
        from market_stream.models import MarketCapitalization
        from market_stream.catalog import refresh_market_caps
        MarketCapitalization.objects.update(refreshed_at=timezone.now() - timedelta(days=8))
        MarketSymbol.objects.bulk_create([MarketSymbol(symbol=f"TEST{i}USDT", quote_asset="USDT") for i in range(60)])
        original = MarketCapitalization.objects.get().coins
        upstream.side_effect = [[{"symbol": "btc", "market_cap": "99"}], TimeoutError()]
        with self.assertRaises(TimeoutError):
            refresh_market_caps()
        self.assertEqual(MarketCapitalization.objects.get().coins, original)
