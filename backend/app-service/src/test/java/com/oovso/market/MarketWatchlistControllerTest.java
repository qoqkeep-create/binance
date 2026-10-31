package com.oovso.market;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.oovso.binance.BinanceContinuousKlineProperties;
import com.oovso.binance.BinanceUsdmMarketDataClient;
import com.oovso.binance.BinanceUsdmSymbol;
import com.oovso.strategy.StrategySymbolWhitelist;
import com.oovso.strategy.SuperEmaPullbackStrategyProperties;
import java.util.List;
import org.junit.jupiter.api.Test;

class MarketWatchlistControllerTest {

    @Test
    void defaultsReturnOnlyActivePairsForTheConfiguredQuoteAsset()
            throws Exception {
        SuperEmaPullbackStrategyProperties strategyProperties =
                new SuperEmaPullbackStrategyProperties();
        strategyProperties.setSymbolWhitelist(
                List.of("btc", "ETH", "ETC", "btc")
        );
        BinanceContinuousKlineProperties marketProperties =
                new BinanceContinuousKlineProperties();
        marketProperties.setQuoteAsset("USDC");
        StrategySymbolWhitelist whitelist = new StrategySymbolWhitelist(
                strategyProperties,
                marketProperties
        );
        BinanceUsdmMarketDataClient marketDataClient =
                mock(BinanceUsdmMarketDataClient.class);
        when(marketDataClient.loadTargetSymbols()).thenReturn(List.of(
                new BinanceUsdmSymbol("BTCUSDC", "PERPETUAL", 1),
                new BinanceUsdmSymbol("ETHUSDC", "PERPETUAL", 1)
        ));

        MarketWatchlistController controller =
                new MarketWatchlistController(
                        whitelist,
                        marketDataClient
                );
        MarketWatchlistController.DefaultWatchlistResponse response =
                controller.defaults().data();

        assertEquals("USDC", response.quoteAsset());
        assertEquals(
                List.of("BTCUSDC", "ETHUSDC"),
                response.symbols());
        assertEquals(
                List.of("BTCUSDC", "ETHUSDC"),
                response.availableSymbols());
    }
}
