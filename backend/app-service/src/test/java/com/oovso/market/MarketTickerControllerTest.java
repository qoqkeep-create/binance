package com.oovso.market;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.oovso.binance.BinanceContinuousKlineProperties;
import com.oovso.binance.BinanceUsdmMarketDataClient;
import com.oovso.binance.BinanceUsdmMarketDataClient.Ticker24h;
import com.oovso.binance.BinanceUsdmSymbol;
import com.oovso.strategy.StrategySymbolWhitelist;
import com.oovso.strategy.SuperEmaPullbackStrategyProperties;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

class MarketTickerControllerTest {

    @Test
    void returnsOnlyActiveTickersForConfiguredQuoteAsset() throws Exception {
        BinanceContinuousKlineProperties marketProperties =
                new BinanceContinuousKlineProperties();
        marketProperties.setQuoteAsset("USDC");
        StrategySymbolWhitelist whitelist = new StrategySymbolWhitelist(
                new SuperEmaPullbackStrategyProperties(),
                marketProperties
        );
        BinanceUsdmMarketDataClient marketDataClient =
                mock(BinanceUsdmMarketDataClient.class);
        when(marketDataClient.loadTargetSymbols()).thenReturn(List.of(
                new BinanceUsdmSymbol("BTCUSDC", "PERPETUAL", 1),
                new BinanceUsdmSymbol("ETHUSDC", "PERPETUAL", 1)
        ));
        when(marketDataClient.load24hTickers()).thenReturn(Map.of(
                "BTCUSDC",
                new Ticker24h(
                        "BTCUSDC",
                        new BigDecimal("118425.5"),
                        new BigDecimal("1468362.2"),
                        new BigDecimal("-0.0108"),
                        1_785_231_000_100L
                ),
                "UNUSEDUSDC",
                new Ticker24h(
                        "UNUSEDUSDC",
                        BigDecimal.ONE,
                        BigDecimal.TEN,
                        BigDecimal.ZERO,
                        1_785_231_000_100L
                )
        ));

        MarketTickerQueryService queryService = new MarketTickerQueryService(
                marketDataClient,
                whitelist
        );
        MarketTickerController controller = new MarketTickerController(
                queryService
        );
        MarketTickerController.MarketTickersResponse response =
                controller.tickers().data();

        assertEquals("USDC", response.quoteAsset());
        assertEquals(1, response.tickers().size());
        MarketTickerSnapshot ticker = response.tickers().getFirst();
        assertEquals("BTCUSDC", ticker.symbol());
        assertEquals(new BigDecimal("118425.5"), ticker.lastPrice());
        assertEquals(new BigDecimal("-1.08"), ticker.priceChangePercent24h());
    }

    @Test
    void popularTickersArePagedByQuoteVolumeDescending()
            throws Exception {
        Fixture fixture = fixture();

        MarketTickerQueryService.MarketTickerPage firstPage =
                fixture.controller().popular(0, 2).data();
        MarketTickerQueryService.MarketTickerPage secondPage =
                fixture.controller().popular(1, 2).data();

        assertEquals("USDC", firstPage.quoteAsset());
        assertEquals(3, firstPage.totalElements());
        assertEquals(2, firstPage.totalPages());
        assertTrue(firstPage.hasNext());
        assertEquals(
                List.of("ETHUSDC", "SOLUSDC"),
                firstPage.items().stream()
                        .map(MarketTickerSnapshot::symbol)
                        .toList()
        );
        assertFalse(secondPage.hasNext());
        assertEquals(
                List.of("BTCUSDC"),
                secondPage.items().stream()
                        .map(MarketTickerSnapshot::symbol)
                        .toList()
        );
        verify(fixture.marketDataClient(), times(1))
                .load24hTickers();
        verify(fixture.marketDataClient(), times(1))
                .loadTargetSymbols();
    }

    @Test
    void searchNormalizesPairSeparatorsAndReturnsMatchingTicker()
            throws Exception {
        Fixture fixture = fixture();

        MarketTickerQueryService.MarketTickerPage response =
                fixture.controller()
                        .search(" btc/usdc ", 0, 20)
                        .data();

        assertEquals("BTCUSDC", response.query());
        assertEquals(1, response.totalElements());
        assertEquals("BTCUSDC", response.items().getFirst().symbol());
    }

    private Fixture fixture() throws Exception {
        BinanceContinuousKlineProperties marketProperties =
                new BinanceContinuousKlineProperties();
        marketProperties.setQuoteAsset("USDC");
        StrategySymbolWhitelist whitelist = new StrategySymbolWhitelist(
                new SuperEmaPullbackStrategyProperties(),
                marketProperties
        );
        BinanceUsdmMarketDataClient marketDataClient =
                mock(BinanceUsdmMarketDataClient.class);
        when(marketDataClient.loadTargetSymbols()).thenReturn(List.of(
                new BinanceUsdmSymbol("BTCUSDC", "PERPETUAL", 1),
                new BinanceUsdmSymbol("ETHUSDC", "PERPETUAL", 1),
                new BinanceUsdmSymbol("SOLUSDC", "PERPETUAL", 1)
        ));
        when(marketDataClient.load24hTickers()).thenReturn(Map.of(
                "BTCUSDC",
                ticker("BTCUSDC", "118425.5", "100", "-1.08"),
                "ETHUSDC",
                ticker("ETHUSDC", "3850.1", "300", "2.50"),
                "SOLUSDC",
                ticker("SOLUSDC", "195.2", "200", "1.25")
        ));
        MarketTickerQueryService queryService =
                new MarketTickerQueryService(
                        marketDataClient,
                        whitelist
                );
        return new Fixture(
                new MarketTickerController(queryService),
                marketDataClient
        );
    }

    private Ticker24h ticker(
            String pair,
            String price,
            String volume,
            String changePercent
    ) {
        return new Ticker24h(
                pair,
                new BigDecimal(price),
                new BigDecimal(volume),
                new BigDecimal(changePercent).movePointLeft(2),
                1_785_231_000_100L
        );
    }

    private record Fixture(
            MarketTickerController controller,
            BinanceUsdmMarketDataClient marketDataClient
    ) {
    }
}
