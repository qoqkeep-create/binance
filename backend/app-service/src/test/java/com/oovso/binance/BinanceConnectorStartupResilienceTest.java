package com.oovso.binance;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.oovso.realtime.RealtimeProperties;
import java.util.List;
import org.junit.jupiter.api.Test;

class BinanceConnectorStartupResilienceTest {

    @Test
    void continuousKlineStartupSurvivesInitialExchangeInfoFailure()
            throws Exception {
        BinanceContinuousKlineProperties properties = enabledProperties();
        BinanceUsdmMarketDataClient marketDataClient = mock(
                BinanceUsdmMarketDataClient.class
        );
        when(marketDataClient.loadTargetSymbols()).thenThrow(
                new BinanceRestRateLimitException("rate limited", 123_456)
        );
        BinanceUsdMarginedPerpetualContinuousKlineConnector connector =
                new BinanceUsdMarginedPerpetualContinuousKlineConnector(
                        properties,
                        marketDataClient,
                        List.of()
                );

        try {
            assertDoesNotThrow(connector::start);
            assertTrue(connector.isRunning());
        } finally {
            connector.stop();
        }
    }

    @Test
    void marketTickerStartupSurvivesInitialExchangeInfoFailure()
            throws Exception {
        BinanceContinuousKlineProperties properties = enabledProperties();
        BinanceUsdmMarketDataClient marketDataClient = mock(
                BinanceUsdmMarketDataClient.class
        );
        when(marketDataClient.loadTargetSymbols()).thenThrow(
                new BinanceRestRateLimitException("rate limited", 123_456)
        );
        BinanceUsdMarginedMarketTickerConnector connector =
                new BinanceUsdMarginedMarketTickerConnector(
                        properties,
                        marketDataClient,
                        new RealtimeProperties(),
                        List.of()
                );

        try {
            assertDoesNotThrow(connector::start);
            assertTrue(connector.isRunning());
        } finally {
            connector.stop();
        }
    }

    private BinanceContinuousKlineProperties enabledProperties() {
        BinanceContinuousKlineProperties properties =
                new BinanceContinuousKlineProperties();
        properties.setEnabled(true);
        properties.setQuoteAsset("USDC");
        properties.setReconnectEnabled(false);
        properties.setSymbolRefreshEnabled(false);
        return properties;
    }
}
