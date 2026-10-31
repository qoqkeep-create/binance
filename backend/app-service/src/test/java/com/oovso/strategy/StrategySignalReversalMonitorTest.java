package com.oovso.strategy;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.oovso.market.MarketClosedKlineEvent;
import com.oovso.market.MarketKline;
import com.oovso.market.MarketKlineMapper;
import com.oovso.market.MarketKlineService;
import java.math.BigDecimal;
import java.util.List;
import org.junit.jupiter.api.Test;

class StrategySignalReversalMonitorTest {

    @Test
    void claimsAndNotifiesMatchingUserOnce() {
        StrategySignalMapper signalMapper = mock(StrategySignalMapper.class);
        MarketKlineMapper klineMapper = mock(MarketKlineMapper.class);
        CandlestickPatternDetector detector =
                mock(CandlestickPatternDetector.class);
        MacdMomentumDecayDetector macdMomentumDecayDetector =
                mock(MacdMomentumDecayDetector.class);
        ReversalAlertStateService stateService =
                mock(ReversalAlertStateService.class);
        ReversalAlertHandler handler = mock(ReversalAlertHandler.class);
        StrategySignalReversalMonitor monitor =
                new StrategySignalReversalMonitor(
                        signalMapper,
                        klineMapper,
                        detector,
                        macdMomentumDecayDetector,
                        stateService,
                        List.of(handler)
                );
        MarketKline latest = kline(7_200_000L, "10.4");
        List<MarketKline> history = List.of(
                kline(0L, "12"),
                kline(3_600_000L, "11"),
                latest
        );
        StrategySignalReversalWatch watch = watch();
        var pattern = new CandlestickPatternDetector.PatternMatch(
                "BULLISH_ENGULFING",
                88,
                List.of("看涨吞没")
        );
        when(signalMapper.selectActiveReversalWatches(
                "BINANCE",
                "USDM",
                "PERPETUAL",
                "BTCUSDC",
                "1h"
        )).thenReturn(List.of(watch));
        when(klineMapper.selectLatestClosed(
                "BINANCE",
                "USDM",
                "PERPETUAL",
                "BTCUSDC",
                "1h",
                1_500
        )).thenReturn(history.reversed());
        when(detector.detectConfirmedReversal(
                any(),
                org.mockito.ArgumentMatchers.eq(2),
                org.mockito.ArgumentMatchers.eq(TrendDirection.LONG)
        )).thenReturn(pattern);
        when(stateService.claim(any())).thenReturn(true);

        monitor.onMarketClosedKline(new MarketClosedKlineEvent(latest));

        verify(stateService).claim(any());
        verify(handler).onReversalAlert(any());
    }

    @Test
    void monitorsOneHourReversalForFourHourSourceSignal() {
        StrategySignalMapper signalMapper = mock(StrategySignalMapper.class);
        MarketKlineMapper klineMapper = mock(MarketKlineMapper.class);
        CandlestickPatternDetector detector =
                mock(CandlestickPatternDetector.class);
        MacdMomentumDecayDetector macdMomentumDecayDetector =
                mock(MacdMomentumDecayDetector.class);
        ReversalAlertStateService stateService =
                mock(ReversalAlertStateService.class);
        ReversalAlertHandler handler = mock(ReversalAlertHandler.class);
        StrategySignalReversalMonitor monitor =
                new StrategySignalReversalMonitor(
                        signalMapper,
                        klineMapper,
                        detector,
                        macdMomentumDecayDetector,
                        stateService,
                        List.of(handler)
                );
        MarketKline latest = kline(7_200_000L, "10.4");
        StrategySignalReversalWatch watch = watch();
        watch.setSourceIntervalCode("4h");
        when(signalMapper.selectActiveReversalWatches(
                "BINANCE", "USDM", "PERPETUAL", "BTCUSDC", "1h"
        )).thenReturn(List.of(watch));
        when(klineMapper.selectLatestClosed(
                "BINANCE", "USDM", "PERPETUAL", "BTCUSDC", "1h", 1_500
        )).thenReturn(List.of(latest));
        when(detector.detectConfirmedReversal(any(),
                org.mockito.ArgumentMatchers.eq(0),
                org.mockito.ArgumentMatchers.eq(TrendDirection.LONG)
        )).thenReturn(new CandlestickPatternDetector.PatternMatch(
                "HAMMER", 82, List.of("锤形线")
        ));
        when(stateService.claim(any())).thenReturn(true);

        monitor.onMarketClosedKline(new MarketClosedKlineEvent(latest));

        var captor = org.mockito.ArgumentCaptor.forClass(ReversalAlert.class);
        verify(handler).onReversalAlert(captor.capture());
        org.junit.jupiter.api.Assertions.assertEquals(
                "4h",
                captor.getValue().intervalCode()
        );
        org.junit.jupiter.api.Assertions.assertEquals(
                "1h",
                latest.getIntervalCode()
        );
    }

    @Test
    void monitorsFifteenMinuteReversalForFifteenMinuteSourceSignal() {
        StrategySignalMapper signalMapper = mock(StrategySignalMapper.class);
        MarketKlineMapper klineMapper = mock(MarketKlineMapper.class);
        CandlestickPatternDetector detector =
                mock(CandlestickPatternDetector.class);
        MacdMomentumDecayDetector macdMomentumDecayDetector =
                mock(MacdMomentumDecayDetector.class);
        ReversalAlertStateService stateService =
                mock(ReversalAlertStateService.class);
        ReversalAlertHandler handler = mock(ReversalAlertHandler.class);
        StrategySignalReversalMonitor monitor =
                new StrategySignalReversalMonitor(
                        signalMapper,
                        klineMapper,
                        detector,
                        macdMomentumDecayDetector,
                        stateService,
                        List.of(handler)
                );
        MarketKline latest = kline(1_800_000L, "10.4", "15m");
        StrategySignalReversalWatch watch = watch();
        watch.setSourceIntervalCode("15m");
        when(signalMapper.selectActiveReversalWatches(
                "BINANCE", "USDM", "PERPETUAL", "BTCUSDC", "15m"
        )).thenReturn(List.of(watch));
        when(klineMapper.selectLatestClosed(
                "BINANCE", "USDM", "PERPETUAL", "BTCUSDC", "15m", 1_500
        )).thenReturn(List.of(latest));
        when(detector.detectConfirmedReversal(any(),
                org.mockito.ArgumentMatchers.eq(0),
                org.mockito.ArgumentMatchers.eq(TrendDirection.LONG)
        )).thenReturn(new CandlestickPatternDetector.PatternMatch(
                "HAMMER", 82, List.of("锤形线")
        ));
        when(stateService.claim(any())).thenReturn(true);

        monitor.onMarketClosedKline(new MarketClosedKlineEvent(latest));

        var captor = org.mockito.ArgumentCaptor.forClass(ReversalAlert.class);
        verify(handler).onReversalAlert(captor.capture());
        org.junit.jupiter.api.Assertions.assertEquals(
                "15m",
                captor.getValue().intervalCode()
        );
    }

    @Test
    void doesNotNotifyWhenAnotherEventAlreadyClaimedTrigger() {
        StrategySignalMapper signalMapper = mock(StrategySignalMapper.class);
        MarketKlineMapper klineMapper = mock(MarketKlineMapper.class);
        CandlestickPatternDetector detector =
                mock(CandlestickPatternDetector.class);
        MacdMomentumDecayDetector macdMomentumDecayDetector =
                mock(MacdMomentumDecayDetector.class);
        ReversalAlertStateService stateService =
                mock(ReversalAlertStateService.class);
        ReversalAlertHandler handler = mock(ReversalAlertHandler.class);
        StrategySignalReversalMonitor monitor =
                new StrategySignalReversalMonitor(
                        signalMapper,
                        klineMapper,
                        detector,
                        macdMomentumDecayDetector,
                        stateService,
                        List.of(handler)
                );
        MarketKline latest = kline(7_200_000L, "10.4");
        when(signalMapper.selectActiveReversalWatches(
                any(), any(), any(), any(), any()
        )).thenReturn(List.of(watch()));
        when(klineMapper.selectLatestClosed(
                any(), any(), any(), any(), any(),
                org.mockito.ArgumentMatchers.anyInt()
        )).thenReturn(List.of(latest));
        when(detector.detectConfirmedReversal(
                any(),
                org.mockito.ArgumentMatchers.eq(0),
                org.mockito.ArgumentMatchers.eq(TrendDirection.LONG)
        )).thenReturn(new CandlestickPatternDetector.PatternMatch(
                "HAMMER",
                82,
                List.of("锤形线")
        ));
        when(stateService.claim(any())).thenReturn(false);

        monitor.onMarketClosedKline(new MarketClosedKlineEvent(latest));

        verify(handler, never()).onReversalAlert(any());
    }

    @Test
    void triggersOnMacdMomentumDecayWhenNoCandlestickPatternExists() {
        StrategySignalMapper signalMapper = mock(StrategySignalMapper.class);
        MarketKlineMapper klineMapper = mock(MarketKlineMapper.class);
        CandlestickPatternDetector detector =
                mock(CandlestickPatternDetector.class);
        MacdMomentumDecayDetector macdMomentumDecayDetector =
                mock(MacdMomentumDecayDetector.class);
        ReversalAlertStateService stateService =
                mock(ReversalAlertStateService.class);
        ReversalAlertHandler handler = mock(ReversalAlertHandler.class);
        StrategySignalReversalMonitor monitor =
                new StrategySignalReversalMonitor(
                        signalMapper,
                        klineMapper,
                        detector,
                        macdMomentumDecayDetector,
                        stateService,
                        List.of(handler)
                );
        MarketKline latest = kline(7_200_000L, "10.4");
        when(signalMapper.selectActiveReversalWatches(
                any(), any(), any(), any(), any()
        )).thenReturn(List.of(watch()));
        when(klineMapper.selectLatestClosed(
                any(), any(), any(), any(), any(),
                org.mockito.ArgumentMatchers.anyInt()
        )).thenReturn(List.of(latest));
        when(macdMomentumDecayDetector.detectDecay(
                any(),
                org.mockito.ArgumentMatchers.eq(0)
        )).thenReturn(new MacdMomentumDecayDetector.DecayMatch(
                "MACD_MOMENTUM_DECAY",
                "MACD能量衰减",
                76
        ));
        when(stateService.claim(any())).thenReturn(true);

        monitor.onMarketClosedKline(new MarketClosedKlineEvent(latest));

        var captor = org.mockito.ArgumentCaptor.forClass(ReversalAlert.class);
        verify(handler).onReversalAlert(captor.capture());
        org.junit.jupiter.api.Assertions.assertEquals(
                "MACD_MOMENTUM_DECAY",
                captor.getValue().patternCode()
        );
    }

    @Test
    void ignoresClosedCandleThatDidNotFinishAfterLatestActivation() {
        StrategySignalMapper signalMapper = mock(StrategySignalMapper.class);
        MarketKlineMapper klineMapper = mock(MarketKlineMapper.class);
        CandlestickPatternDetector detector =
                mock(CandlestickPatternDetector.class);
        MacdMomentumDecayDetector macdMomentumDecayDetector =
                mock(MacdMomentumDecayDetector.class);
        ReversalAlertStateService stateService =
                mock(ReversalAlertStateService.class);
        ReversalAlertHandler handler = mock(ReversalAlertHandler.class);
        StrategySignalReversalMonitor monitor =
                new StrategySignalReversalMonitor(
                        signalMapper,
                        klineMapper,
                        detector,
                        macdMomentumDecayDetector,
                        stateService,
                        List.of(handler)
                );
        MarketKline latest = kline(7_200_000L, "10.4");
        StrategySignalReversalWatch watch = watch();
        watch.setRequestedTimeMs(latest.getCloseTimeMs());
        when(signalMapper.selectActiveReversalWatches(
                any(), any(), any(), any(), any()
        )).thenReturn(List.of(watch));
        when(klineMapper.selectLatestClosed(
                any(), any(), any(), any(), any(),
                org.mockito.ArgumentMatchers.anyInt()
        )).thenReturn(List.of(latest));

        monitor.onMarketClosedKline(new MarketClosedKlineEvent(latest));

        verify(detector, never()).detectConfirmedReversal(
                any(),
                org.mockito.ArgumentMatchers.anyInt(),
                any()
        );
        verify(stateService, never()).claim(any());
        verify(handler, never()).onReversalAlert(any());
    }

    private StrategySignalReversalWatch watch() {
        StrategySignalReversalWatch watch =
                new StrategySignalReversalWatch();
        watch.setUserId("user-a");
        watch.setSignalId("signal-a");
        watch.setExchange("BINANCE");
        watch.setMarketType("USDM");
        watch.setContractType("PERPETUAL");
        watch.setSymbol("BTCUSDC");
        watch.setSourceIntervalCode("1h");
        watch.setDirection("LONG");
        watch.setRequestedTimeMs(0L);
        return watch;
    }

    private MarketKline kline(long openTimeMs, String close) {
        return kline(openTimeMs, close, "1h");
    }

    private MarketKline kline(
            long openTimeMs,
            String close,
            String intervalCode
    ) {
        MarketKline kline = new MarketKline();
        kline.setExchange("BINANCE");
        kline.setMarketType("USDM");
        kline.setContractType("PERPETUAL");
        kline.setPair("BTCUSDC");
        kline.setIntervalCode(intervalCode);
        kline.setOpenTimeMs(openTimeMs);
        kline.setCloseTimeMs(
                openTimeMs
                        + MarketKlineService.intervalMillis(
                                intervalCode
                        )
                        - 1
        );
        kline.setOpenPrice(new BigDecimal(close));
        kline.setHighPrice(new BigDecimal(close));
        kline.setLowPrice(new BigDecimal(close));
        kline.setClosePrice(new BigDecimal(close));
        return kline;
    }
}
