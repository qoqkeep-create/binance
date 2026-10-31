package com.oovso.strategy;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.timeout;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.binance.connector.client.derivatives_trading_usds_futures.websocket.stream.model.ContinuousContractKlineCandlestickStreamsResponse;
import com.oovso.market.KlineStorageProperties;
import java.io.IOException;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;

class FourHourIntrabarStrategyHandlerTest {

    private final ExecutorService executor = Executors.newSingleThreadExecutor();

    @AfterEach
    void shutdown() {
        executor.shutdownNow();
    }

    @Test
    void analyzesUnclosedOneMinuteUpdateImmediately() throws IOException {
        SuperEmaPullbackStrategyProperties properties = new SuperEmaPullbackStrategyProperties();
        properties.getFourHour().setIntrabarAnalysisIntervalMillis(0);
        FourHourIntrabarKlineAggregator aggregator = mock(FourHourIntrabarKlineAggregator.class);
        SuperEmaPullbackStrategy strategy = mock(SuperEmaPullbackStrategy.class);
        StrategySymbolWhitelist whitelist = mock(StrategySymbolWhitelist.class);
        when(whitelist.contains("BTCUSDC")).thenReturn(true);
        FourHourIntrabarKlineAggregator.Snapshot snapshot =
                new FourHourIntrabarKlineAggregator.Snapshot(mock(com.oovso.market.MarketKline.class), List.of());
        when(aggregator.aggregate(any(), eq(500))).thenReturn(Optional.of(snapshot));
        FourHourIntrabarStrategyHandler handler = new FourHourIntrabarStrategyHandler(
                properties,
                new KlineStorageProperties(),
                aggregator,
                strategy,
                whitelist,
                mock(StrategySymbolEligibilityService.class),
                executor
        );

        handler.onKline(event(false));

        verify(strategy, timeout(1_000)).onFourHourIntrabar(snapshot);
    }

    @Test
    void analyzesFinalOneMinuteUpdateToCatchLastInstantWicks() throws IOException {
        FourHourIntrabarKlineAggregator aggregator = mock(FourHourIntrabarKlineAggregator.class);
        SuperEmaPullbackStrategy strategy = mock(SuperEmaPullbackStrategy.class);
        StrategySymbolWhitelist whitelist = mock(StrategySymbolWhitelist.class);
        when(whitelist.contains("BTCUSDC")).thenReturn(true);
        FourHourIntrabarStrategyHandler handler = new FourHourIntrabarStrategyHandler(
                new SuperEmaPullbackStrategyProperties(),
                new KlineStorageProperties(),
                aggregator,
                strategy,
                whitelist,
                mock(StrategySymbolEligibilityService.class),
                executor
        );

        handler.onKline(event(true));

        verify(aggregator, timeout(1_000)).aggregate(
                org.mockito.ArgumentMatchers.argThat(kline -> kline.getClosedState() == 1),
                eq(500)
        );
    }

    private ContinuousContractKlineCandlestickStreamsResponse event(boolean closed) throws IOException {
        return ContinuousContractKlineCandlestickStreamsResponse.fromJson("""
                {
                  "e":"continuous_kline",
                  "E":1786597200123,
                  "ps":"BTCUSDC",
                  "ct":"PERPETUAL",
                  "k":{
                    "t":1786597200000,
                    "T":1786597259999,
                    "i":"1m",
                    "o":"64000.0",
                    "c":"64010.0",
                    "h":"64020.0",
                    "l":"63990.0",
                    "v":"10.0",
                    "n":12,
                    "x":%s,
                    "q":"640050.0",
                    "V":"4.0",
                    "Q":"256020.0"
                  }
                }
                """.formatted(closed));
    }
}
