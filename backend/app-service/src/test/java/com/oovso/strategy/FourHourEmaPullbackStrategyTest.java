package com.oovso.strategy;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.oovso.indicator.MarketIndicatorMapper;
import com.oovso.indicator.Ta4jKlineSeriesFactory;
import com.oovso.market.MarketKline;
import com.oovso.market.MarketKlineMapper;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.function.Consumer;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.mockito.ArgumentCaptor;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

class FourHourEmaPullbackStrategyTest {

    @Test
    void shortTouchDoesNotRequireRecentSuperTrendFlipOrReversalPattern() {
        Fixture fixture = fixture(TrendDirection.SHORT, true);
        fixture.strategy().onFourHourIntrabar(snapshot(false));

        ArgumentCaptor<StrategySignal> signal = ArgumentCaptor.forClass(StrategySignal.class);
        verify(fixture.signalMapper()).insertIgnore(signal.capture());
        assertEquals("SHORT", signal.getValue().getDirection());
        assertEquals("4h", signal.getValue().getIntervalCode());
        assertEquals("NO_REVERSAL_PATTERN", signal.getValue().getPatternCode());
        assertTrue(signal.getValue().getTouchEventTimeMs() > 0);
        assertTrue(signal.getValue().getReasonJson().contains("FOUR_HOUR_EMA144_RETOUCH"));
        verify(fixture.signalMapper(), never()).countByFlip(
                any(), any(), any(), any(), any(), any(), anyLong(), any()
        );
        verify(fixture.indicatorMapper(), never()).upsert(any());
        verify(fixture.handler()).onSignal(signal.getValue());
    }

    @Test
    void longTouchUsesEmaDirectionAndWaitsForCommitBeforeNotifying() {
        Fixture fixture = fixture(TrendDirection.LONG, true);
        TransactionSynchronizationManager.initSynchronization();
        try {
            fixture.strategy().onFourHourIntrabar(snapshot(true));
            verify(fixture.handler(), never()).onSignal(any());
            List<TransactionSynchronization> callbacks =
                    TransactionSynchronizationManager.getSynchronizations();
            assertEquals(1, callbacks.size());
            callbacks.forEach(TransactionSynchronization::afterCommit);
            verify(fixture.handler()).onSignal(any());
        } finally {
            TransactionSynchronizationManager.clearSynchronization();
        }
    }

    @Test
    void acceptedTouchesAfterTheCooldownHaveDistinctPersistentKeys() {
        Fixture fixture = fixture(TrendDirection.SHORT, true);
        FourHourIntrabarKlineAggregator.Snapshot snapshot = snapshot(false);
        fixture.strategy().onFourHourIntrabar(snapshot);
        long nextTriggerOffset = 28 * 60 * 60 * 1_000L;
        snapshot.provisional().setOpenTimeMs(snapshot.provisional().getOpenTimeMs() + nextTriggerOffset);
        snapshot.provisional().setCloseTimeMs(snapshot.provisional().getCloseTimeMs() + nextTriggerOffset);
        snapshot.provisional().setEventTimeMs(snapshot.provisional().getEventTimeMs() + nextTriggerOffset);
        fixture.strategy().onFourHourIntrabar(snapshot);

        ArgumentCaptor<StrategySignal> signals = ArgumentCaptor.forClass(StrategySignal.class);
        verify(fixture.signalMapper(), org.mockito.Mockito.times(2)).insertIgnore(signals.capture());
        StrategySignal first = signals.getAllValues().getFirst();
        StrategySignal second = signals.getAllValues().getLast();
        assertEquals(first.getFlipOpenTimeMs(), second.getFlipOpenTimeMs());
        assertNotEquals(first.getTriggerOpenTimeMs(), second.getTriggerOpenTimeMs());
        assertNotEquals(first.getId(), second.getId());
        assertNotEquals(first.getTouchEventTimeMs(), second.getTouchEventTimeMs());
    }

    @Test
    void duplicateSignalInsertDoesNotNotify() {
        Fixture fixture = fixture(TrendDirection.SHORT, false);
        fixture.strategy().onFourHourIntrabar(snapshot(false));
        verify(fixture.handler(), never()).onSignal(any());
    }

    @ParameterizedTest
    @CsvSource({
            "102, 103, 100",
            "98, 97, 100",
            "1237.735640741735, 1213.60570317745, 1245.408860497426",
            "102, 102, 100",
            "98, 98, 100",
            "102, 100, 100",
            "98, 100, 100",
            "100, 102, 100",
            "100, 98, 100",
            "100, 100, 100"
    })
    void rejectsReversedOrEqualEmaPairs(String ema21, String ema55, String ema144) {
        assertNull(SuperEmaPullbackStrategy.fourHourDirection(
                new BigDecimal(ema21), new BigDecimal(ema55), new BigDecimal(ema144)
        ));
    }

    @ParameterizedTest
    @CsvSource({"true, true", "true, false", "false, true", "false, false"})
    void reversedFastAndMiddleEmaCannotTriggerEvenWhenEma144IsOutermost(
            boolean rising,
            boolean legacyOutermostSetting
    ) {
        Fixture fixture = fixture(rising ? TrendDirection.LONG : TrendDirection.SHORT, true);
        fixture.properties().getFourHour().setEma144OutermostRequired(legacyOutermostSetting);
        FourHourIntrabarKlineAggregator.Snapshot snapshot = snapshot(rising);
        // A pullback in the most recent 20 candles reverses EMA21/EMA55 while
        // EMA144 remains on the outside. That loose condition used to alert.
        for (int index = 480; index < 500; index++) {
            MarketKline kline = snapshot.klines().get(index);
            BigDecimal close = BigDecimal.valueOf(rising
                    ? 980 - 3L * (index - 480) : 520 + 3L * (index - 480));
            kline.setOpenPrice(close);
            kline.setClosePrice(close);
            kline.setHighPrice(close.add(BigDecimal.ONE));
            kline.setLowPrice(close.subtract(BigDecimal.ONE));
        }
        fixture.strategy().onFourHourIntrabar(snapshot);

        verify(fixture.stateService()).evaluate(
                eq(snapshot.provisional()), isNull(), any(), any(), isNull(), any()
        );
        verify(fixture.signalMapper(), never()).insertIgnore(any());
        verify(fixture.handler(), never()).onSignal(any());
    }

    @Test
    void flatEqualEmasDoNotTriggerATouchSignal() {
        Fixture fixture = fixture(TrendDirection.LONG, true);
        FourHourIntrabarKlineAggregator.Snapshot snapshot = snapshot(true);
        for (MarketKline kline : snapshot.klines()) {
            kline.setOpenPrice(BigDecimal.valueOf(100));
            kline.setClosePrice(BigDecimal.valueOf(100));
            kline.setHighPrice(BigDecimal.valueOf(101));
            kline.setLowPrice(BigDecimal.valueOf(99));
        }
        fixture.strategy().onFourHourIntrabar(snapshot);

        verify(fixture.stateService()).evaluate(
                eq(snapshot.provisional()), isNull(), any(), any(), isNull(), any()
        );
        verify(fixture.signalMapper(), never()).insertIgnore(any());
        verify(fixture.handler(), never()).onSignal(any());
    }

    private Fixture fixture(TrendDirection direction, boolean inserted) {
        SuperEmaPullbackStrategyProperties properties = new SuperEmaPullbackStrategyProperties();
        properties.setMaxWaitPullbackBars(0);
        properties.setReversalPatternRequired(true);
        MarketIndicatorMapper indicatorMapper = mock(MarketIndicatorMapper.class);
        StrategySignalMapper signalMapper = mock(StrategySignalMapper.class);
        when(signalMapper.insertIgnore(any())).thenReturn(inserted ? 1 : 0);
        StrategySymbolWhitelist whitelist = mock(StrategySymbolWhitelist.class);
        when(whitelist.contains("ETHUSDC")).thenReturn(true);
        FourHourEmaPullbackStateService stateService = mock(FourHourEmaPullbackStateService.class);
        doAnswer(invocation -> {
            MarketKline kline = invocation.getArgument(0);
            Consumer<Long> onTouch = invocation.getArgument(5);
            onTouch.accept(kline.getEventTimeMs());
            return null;
        }).when(stateService).evaluate(any(), eq(direction), any(), any(), isNull(), any());
        StrategySignalHandler handler = mock(StrategySignalHandler.class);
        SuperEmaPullbackStrategy strategy = new SuperEmaPullbackStrategy(
                properties, mock(MarketKlineMapper.class), indicatorMapper, signalMapper,
                new Ta4jKlineSeriesFactory(), new CandlestickPatternDetector(),
                mock(StrategySymbolEligibilityService.class), whitelist,
                mock(DynamicSymbolKlineFilter.class), List.of(handler), stateService
        );
        return new Fixture(strategy, signalMapper, indicatorMapper, handler, stateService, properties);
    }

    private FourHourIntrabarKlineAggregator.Snapshot snapshot(boolean rising) {
        long interval = 4 * 60 * 60 * 1_000L;
        List<MarketKline> klines = new ArrayList<>();
        for (int index = 0; index < 500; index++) {
            MarketKline kline = new MarketKline();
            kline.setExchange("BINANCE");
            kline.setMarketType("USDM");
            kline.setContractType("PERPETUAL");
            kline.setPair("ETHUSDC");
            kline.setIntervalCode("4h");
            kline.setSourceInterval("1m");
            kline.setOpenTimeMs(index * interval);
            kline.setCloseTimeMs((index + 1) * interval - 1);
            kline.setEventTimeMs(index * interval + 60_000);
            BigDecimal close = BigDecimal.valueOf(rising ? 500 + index : 1_000 - index);
            kline.setOpenPrice(close);
            kline.setClosePrice(close);
            kline.setHighPrice(close.add(BigDecimal.ONE));
            kline.setLowPrice(close.subtract(BigDecimal.ONE));
            kline.setVolume(BigDecimal.TEN);
            kline.setQuoteVolume(BigDecimal.TEN.multiply(close));
            kline.setClosedState(index == 499 ? 0 : 1);
            klines.add(kline);
        }
        return new FourHourIntrabarKlineAggregator.Snapshot(klines.getLast(), klines);
    }

    private record Fixture(
            SuperEmaPullbackStrategy strategy,
            StrategySignalMapper signalMapper,
            MarketIndicatorMapper indicatorMapper,
            StrategySignalHandler handler,
            FourHourEmaPullbackStateService stateService,
            SuperEmaPullbackStrategyProperties properties
    ) {
    }
}
