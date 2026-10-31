package com.oovso.strategy;

import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.oovso.indicator.MarketIndicatorMapper;
import com.oovso.indicator.Ta4jKlineSeriesFactory;
import com.oovso.market.MarketClosedKlineEvent;
import com.oovso.market.MarketKline;
import com.oovso.market.MarketKlineMapper;
import java.util.List;
import org.junit.jupiter.api.Test;

class SuperEmaPullbackStrategyIntervalTest {

    @Test
    void analyzesClosedFifteenMinuteKlineWithDedicatedHistoryWindow() {
        Fixture fixture = fixture();
        MarketKline kline = kline("15m");
        when(fixture.marketKlineMapper().selectLatestClosed(
                "BINANCE", "USDM", "PERPETUAL", "BTCUSDC", "15m", 3_000
        )).thenReturn(List.of());

        fixture.strategy().onMarketClosedKline(
                new MarketClosedKlineEvent(kline)
        );

        verify(fixture.marketKlineMapper()).selectLatestClosed(
                "BINANCE", "USDM", "PERPETUAL", "BTCUSDC", "15m", 3_000
        );
    }

    @Test
    void ignoresIntervalsWithoutAlertSupport() {
        Fixture fixture = fixture();

        fixture.strategy().onMarketClosedKline(
                new MarketClosedKlineEvent(kline("5m"))
        );

        verify(fixture.marketKlineMapper(), never()).selectLatestClosed(
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.anyInt()
        );
    }

    private Fixture fixture() {
        SuperEmaPullbackStrategyProperties properties =
                new SuperEmaPullbackStrategyProperties();
        MarketKlineMapper marketKlineMapper = mock(MarketKlineMapper.class);
        StrategySymbolWhitelist symbolWhitelist =
                mock(StrategySymbolWhitelist.class);
        when(symbolWhitelist.contains("BTCUSDC")).thenReturn(true);
        SuperEmaPullbackStrategy strategy = new SuperEmaPullbackStrategy(
                properties,
                marketKlineMapper,
                mock(MarketIndicatorMapper.class),
                mock(StrategySignalMapper.class),
                new Ta4jKlineSeriesFactory(),
                new CandlestickPatternDetector(),
                mock(StrategySymbolEligibilityService.class),
                symbolWhitelist,
                mock(DynamicSymbolKlineFilter.class),
                List.of(),
                mock(FourHourEmaPullbackStateService.class)
        );
        return new Fixture(strategy, marketKlineMapper);
    }

    private MarketKline kline(String intervalCode) {
        MarketKline kline = new MarketKline();
        kline.setExchange("BINANCE");
        kline.setMarketType("USDM");
        kline.setContractType("PERPETUAL");
        kline.setPair("BTCUSDC");
        kline.setIntervalCode(intervalCode);
        kline.setOpenTimeMs(0L);
        return kline;
    }

    private record Fixture(
            SuperEmaPullbackStrategy strategy,
            MarketKlineMapper marketKlineMapper
    ) {
    }
}
