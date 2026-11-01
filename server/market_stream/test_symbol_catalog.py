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
        cache.clear()

    def request(self, view, path, **kwargs):
        request = APIRequestFactory().get(path)
        force_authenticate(request, user=type("User", (), {"is_authenticated": True})())
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
