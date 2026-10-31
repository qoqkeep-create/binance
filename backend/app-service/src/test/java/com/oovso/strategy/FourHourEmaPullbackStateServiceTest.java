package com.oovso.strategy;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import com.oovso.market.MarketKline;
import java.math.BigDecimal;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneId;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CyclicBarrier;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.Primary;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

@ActiveProfiles("test")
@SpringBootTest
@Transactional
@Import(FourHourEmaPullbackStateServiceTest.ClockConfiguration.class)
class FourHourEmaPullbackStateServiceTest {

    private static final BigDecimal TARGET = new BigDecimal("100");

    private static final BigDecimal TOLERANCE = BigDecimal.ONE;

    private static final long BUCKET_OPEN = 14_400_000L;

    @Autowired
    private FourHourEmaPullbackStateService service;

    @Autowired
    private FourHourEmaPullbackStateMapper mapper;

    @Autowired
    private JdbcTemplate jdbcTemplate;

    @Autowired
    private MutableClock clock;

    @BeforeEach
    void resetClock() {
        clock.setMillis(0);
    }

    @Test
    void suppressesRetouchesWithinTheSameFourHourCandleDuringCooldown() {
        List<Long> touches = new ArrayList<>();
        evaluate(live(1, 90), TrendDirection.SHORT, touches);
        evaluate(live(2, 100), TrendDirection.SHORT, touches);
        evaluate(live(3, 100), TrendDirection.SHORT, touches);
        evaluate(live(4, 98), TrendDirection.SHORT, touches);
        MarketKline retouch = live(5, 99);
        retouch.setHighPrice(new BigDecimal("110"));
        evaluate(retouch, TrendDirection.SHORT, touches);

        assertEquals(List.of(event(2)), touches);
        assertEquals("TOUCHING", stateFor("ETHUSDC").getPhase());
    }

    @Test
    void rejectsDuplicateAndOutOfOrderEventsAndSurvivesServiceRestart() {
        List<Long> touches = new ArrayList<>();
        evaluate(live(1, 110), TrendDirection.LONG, touches);
        evaluate(live(2, 100), TrendDirection.LONG, touches);
        // New Java object reads the same durable TOUCHING phase.
        FourHourEmaPullbackStateService restarted = new FourHourEmaPullbackStateService(mapper, clock);
        restarted.evaluate(live(2, 110), TrendDirection.LONG, TARGET, TOLERANCE, touches::add);
        restarted.evaluate(live(1, 110), TrendDirection.LONG, TARGET, TOLERANCE, touches::add);
        restarted.evaluate(live(3, 100), TrendDirection.LONG, TARGET, TOLERANCE, touches::add);

        assertEquals(List.of(event(2)), touches);
    }

    @Test
    void crossingTheWholeToleranceBandStillCountsAsATouch() {
        List<Long> touches = new ArrayList<>();
        evaluate(live(1, 90), TrendDirection.SHORT, touches);
        evaluate(live(2, 105), TrendDirection.SHORT, touches);
        evaluate(live(3, 104), TrendDirection.SHORT, touches);
        evaluate(live(4, 100), TrendDirection.SHORT, touches);
        assertEquals(List.of(event(2)), touches);
    }

    @Test
    void aBreakThroughTheTargetDoesNotRearmUntilPriceReturnsToTrendSide() {
        List<Long> touches = new ArrayList<>();
        evaluate(live(1, 100), TrendDirection.LONG, touches);
        evaluate(live(2, 95), TrendDirection.LONG, touches);
        evaluate(live(3, 100), TrendDirection.LONG, touches);
        evaluate(live(4, 102), TrendDirection.LONG, touches);
        evaluate(live(5, 101), TrendDirection.LONG, touches);
        assertEquals(List.of(event(1)), touches);
        assertEquals("TOUCHING", stateFor("ETHUSDC").getPhase());
    }

    @Test
    void firstObservationCanRecoverAnEarlierWickWithoutReusingItOnEveryUpdate() {
        List<Long> touches = new ArrayList<>();
        MarketKline wick = live(1, 90);
        wick.setHighPrice(TARGET);
        evaluate(wick, TrendDirection.SHORT, touches);
        wick.setEventTimeMs(event(2));
        evaluate(wick, TrendDirection.SHORT, touches);
        wick.setEventTimeMs(event(3));
        evaluate(wick, TrendDirection.SHORT, touches);
        assertEquals(List.of(event(1)), touches);
    }

    @Test
    void closedCandleDoesNotReuseAnObservedIntrabarWickButCanCatchFinalPriceTouch() {
        List<Long> touches = new ArrayList<>();
        MarketKline wick = live(1, 90);
        wick.setHighPrice(TARGET);
        evaluate(wick, TrendDirection.SHORT, touches);
        wick.setEventTimeMs(event(2));
        evaluate(wick, TrendDirection.SHORT, touches);
        MarketKline closed = live(3, 90);
        closed.setClosedState(1);
        closed.setHighPrice(TARGET);
        evaluate(closed, TrendDirection.SHORT, touches);
        assertEquals(List.of(event(1)), touches);

        MarketKline nextBucket = live(4, 90);
        nextBucket.setOpenTimeMs(BUCKET_OPEN * 2);
        nextBucket.setCloseTimeMs(BUCKET_OPEN * 3 - 1);
        nextBucket.setEventTimeMs(BUCKET_OPEN * 2 + 1_000);
        evaluate(nextBucket, TrendDirection.SHORT, touches);
        nextBucket.setClosedState(1);
        nextBucket.setClosePrice(TARGET);
        nextBucket.setHighPrice(TARGET);
        evaluate(nextBucket, TrendDirection.SHORT, touches);
        assertEquals(List.of(event(1)), touches);
    }

    @Test
    void unobservedClosedCandleCanRecoverATouchAndIgnoresItsDuplicate() {
        List<Long> touches = new ArrayList<>();
        evaluate(live(1, 90), TrendDirection.SHORT, touches);
        MarketKline closed = live(2, 90);
        closed.setOpenTimeMs(BUCKET_OPEN * 2);
        closed.setCloseTimeMs(BUCKET_OPEN * 3 - 1);
        closed.setClosedState(1);
        closed.setHighPrice(TARGET);
        evaluate(closed, TrendDirection.SHORT, touches);
        evaluate(closed, TrendDirection.SHORT, touches);
        assertEquals(List.of(BUCKET_OPEN * 3 - 1), touches);
    }

    @Test
    void losingAndRecoveringEmaAlignmentDoesNotReuseTheSameOldWick() {
        List<Long> touches = new ArrayList<>();
        MarketKline wick = live(1, 90);
        wick.setHighPrice(TARGET);
        evaluate(wick, TrendDirection.SHORT, touches);
        wick.setEventTimeMs(event(2));
        evaluate(wick, null, touches);
        wick.setEventTimeMs(event(3));
        evaluate(wick, TrendDirection.SHORT, touches);
        evaluate(live(4, 100), TrendDirection.SHORT, touches);
        assertEquals(List.of(event(1)), touches);
    }

    @Test
    void temporaryInvalidAlignmentWhilePriceStaysInsideDoesNotConsumeTheTouchAgain() {
        List<Long> touches = new ArrayList<>();
        evaluate(live(1, 100), TrendDirection.SHORT, touches);
        evaluate(live(2, 100), null, touches);
        evaluate(live(3, 100), TrendDirection.SHORT, touches);
        evaluate(live(4, 100), null, touches);
        evaluate(live(5, 100), TrendDirection.SHORT, touches);
        assertEquals(List.of(event(1)), touches);
    }

    @Test
    void freshOneMinuteWickTriggersEvenWhenLatestPriceAlreadyRetreated() {
        List<Long> touches = new ArrayList<>();
        evaluateSource(live(1, 90), minute(0, 90, 90), TrendDirection.SHORT, touches);
        evaluateSource(live(2, 95), minute(0, 100, 90), TrendDirection.SHORT, touches);
        evaluateSource(live(3, 94), minute(0, 100, 90), TrendDirection.SHORT, touches);
        evaluateSource(live(4, 93), minute(0, 100, 90), TrendDirection.SHORT, touches);
        assertEquals(List.of(event(2)), touches);
    }

    @Test
    void newMinuteWickIsConsumedWithoutAnotherAlertDuringCooldown() {
        List<Long> touches = new ArrayList<>();
        evaluateSource(live(1, 110), minute(0, 110, 110), TrendDirection.LONG, touches);
        evaluateSource(live(2, 105), minute(0, 110, 100), TrendDirection.LONG, touches);
        evaluateSource(live(3, 110), minute(0, 110, 100), TrendDirection.LONG, touches);
        evaluateSource(live(4, 110), minute(0, 110, 100), TrendDirection.LONG, touches);
        MarketKline newMinute = live(61, 106);
        evaluateSource(newMinute, minute(1, 110, 100), TrendDirection.LONG, touches);
        evaluateSource(live(62, 105), minute(1, 110, 100), TrendDirection.LONG, touches);
        assertEquals(List.of(event(2)), touches);
        assertEquals(event(62), stateFor("ETHUSDC").getLastEventMs());
        assertEquals(BUCKET_OPEN + 60_000L, stateFor("ETHUSDC").getLastSourceOpenMs());
    }

    @Test
    void olderSourceMinuteCannotRearmOrTriggerEvenWithANewerDeliveryTime() {
        List<Long> touches = new ArrayList<>();
        evaluateSource(live(61, 90), minute(1, 90, 90), TrendDirection.SHORT, touches);
        evaluateSource(live(62, 100), minute(0, 100, 90), TrendDirection.SHORT, touches);
        evaluateSource(live(63, 95), minute(1, 100, 90), TrendDirection.SHORT, touches);
        assertEquals(List.of(event(63)), touches);
    }

    @Test
    @Transactional(propagation = Propagation.NOT_SUPPORTED)
    void rollsBackTouchCursorWhenSignalInsertionFails() {
        MarketKline kline = live(1, 100);
        kline.setPair("ROLLBACKUSDC");
        assertThrows(IllegalStateException.class, () -> service.evaluate(
                kline, TrendDirection.SHORT, TARGET, TOLERANCE, ignored -> {
                    throw new IllegalStateException("signal insertion failed");
                }
        ));
        assertEquals(0, jdbcTemplate.queryForObject(
                "select count(1) from four_hour_ema_pullback_state where pair = ?",
                Integer.class, kline.getPair()
        ));
        List<Long> touches = new ArrayList<>();
        evaluate(kline, TrendDirection.SHORT, touches);
        assertEquals(List.of(event(1)), touches);
    }

    @Test
    @Transactional(propagation = Propagation.NOT_SUPPORTED)
    void concurrentDuplicateEventsClaimTheTouchOnlyOnce() throws Exception {
        AtomicInteger touches = new AtomicInteger();
        CyclicBarrier barrier = new CyclicBarrier(2);
        try (var executor = Executors.newFixedThreadPool(2)) {
            var first = executor.submit(() -> concurrentEvaluate(barrier, touches));
            var second = executor.submit(() -> concurrentEvaluate(barrier, touches));
            first.get(10, TimeUnit.SECONDS);
            second.get(10, TimeUnit.SECONDS);
        }
        assertEquals(1, touches.get());
    }

    @Test
    void newSameMinuteExtremeProvesAnotherWickAfterPriceHasRearmed() {
        List<Long> touches = new ArrayList<>();
        evaluateSource(live(1, 90), minute(0, 90, 90), TrendDirection.SHORT, touches);
        evaluateSource(live(2, 95), minute(0, 100, 90), TrendDirection.SHORT, touches);
        evaluateSource(live(3, 94), minute(0, 100, 90), TrendDirection.SHORT, touches);
        evaluateSource(live(4, 95), minute(0, 101, 90), TrendDirection.SHORT, touches);
        evaluateSource(live(5, 95), minute(0, 101, 90), TrendDirection.SHORT, touches);

        assertEquals(List.of(event(2)), touches);
        assertEquals(new BigDecimal("101"), stateFor("ETHUSDC").getLastSourceHigh().stripTrailingZeros());
    }

    @Test
    void firstLiveSourceDoesNotReplayAnOldFourHourWick() {
        List<Long> touches = new ArrayList<>();
        MarketKline accumulated = live(1, 90);
        accumulated.setHighPrice(new BigDecimal("110"));
        evaluateSource(accumulated, minute(0, 92, 90), TrendDirection.SHORT, touches);

        assertEquals(List.of(), touches);
        evaluateSource(live(2, 95), minute(0, 100, 90), TrendDirection.SHORT, touches);
        assertEquals(List.of(event(2)), touches);
    }

    @Test
    void finalMinuteWickIsConsumedOnceRegardlessOfFourHourCloseEventOrder() {
        for (boolean closeFirst : List.of(true, false)) {
            String pair = closeFirst ? "CLOSEFIRSTUSDC" : "SOURCEFIRSTUSDC";
            long finalEvent = BUCKET_OPEN * 2 + 10;
            MarketKline previous = live(1, 95);
            previous.setPair(pair);
            previous.setEventTimeMs(finalEvent - 1_000);
            List<Long> touches = new ArrayList<>();
            evaluateSource(previous, minute(239, 98, 90), TrendDirection.SHORT, touches);

            MarketKline closed = live(2, 95);
            closed.setPair(pair);
            closed.setClosedState(1);
            closed.setHighPrice(TARGET);
            closed.setEventTimeMs(finalEvent);
            MarketKline lastSnapshot = live(2, 95);
            lastSnapshot.setPair(pair);
            lastSnapshot.setEventTimeMs(finalEvent);
            if (closeFirst) {
                evaluate(closed, TrendDirection.SHORT, touches);
            }
            evaluateSource(lastSnapshot, minute(239, 100, 90), TrendDirection.SHORT, touches);
            evaluate(closed, TrendDirection.SHORT, touches);
            evaluateSource(lastSnapshot, minute(239, 100, 90), TrendDirection.SHORT, touches);

            assertEquals(List.of(finalEvent), touches);
        }
    }

    @Test
    void cooldownAllowsANewTouchAtExactlyTwentyFourHoursOfServerTime() {
        List<Long> touches = new ArrayList<>();
        long firstTouch = BUCKET_OPEN * 2 - 1_000;
        long cooldown = FourHourEmaPullbackStateService.ALERT_COOLDOWN_MS;
        evaluate(at(firstTouch, 100), TrendDirection.SHORT, touches);
        evaluate(at(BUCKET_OPEN + cooldown - 1, 90), TrendDirection.SHORT, touches);
        evaluate(at(BUCKET_OPEN + cooldown, 100), TrendDirection.SHORT, touches);
        evaluate(at(firstTouch + cooldown - 1, 90), TrendDirection.SHORT, touches);
        assertEquals(List.of(firstTouch), touches);

        evaluate(at(firstTouch + cooldown, 100), TrendDirection.SHORT, touches);

        assertEquals(List.of(firstTouch, firstTouch + cooldown), touches);
        assertEquals(firstTouch + cooldown, stateFor("ETHUSDC").getLastAlertTimeMs());
    }

    @Test
    void accumulatedEventsJumpingAheadCannotBypassServerTimeCooldown() {
        List<Long> touches = new ArrayList<>();
        long serverTime = 1_000_000_000L;
        long firstEvent = event(1);
        long cooldown = FourHourEmaPullbackStateService.ALERT_COOLDOWN_MS;
        clock.setMillis(serverTime);
        service.evaluate(at(firstEvent, 100), TrendDirection.SHORT, TARGET, TOLERANCE, touches::add);

        long futureEvent = firstEvent + cooldown * 2;
        clock.setMillis(serverTime + 1_000);
        service.evaluate(at(futureEvent, 90), TrendDirection.SHORT, TARGET, TOLERANCE, touches::add);
        service.evaluate(at(futureEvent + 1, 100), TrendDirection.SHORT, TARGET, TOLERANCE, touches::add);
        clock.setMillis(serverTime + cooldown - 1);
        service.evaluate(at(futureEvent + 2, 90), TrendDirection.SHORT, TARGET, TOLERANCE, touches::add);
        service.evaluate(at(futureEvent + 3, 100), TrendDirection.SHORT, TARGET, TOLERANCE, touches::add);
        assertEquals(List.of(firstEvent), touches);
        assertEquals(serverTime, stateFor("ETHUSDC").getLastAlertTimeMs());

        clock.setMillis(serverTime + cooldown);
        service.evaluate(at(futureEvent + 4, 90), TrendDirection.SHORT, TARGET, TOLERANCE, touches::add);
        service.evaluate(at(futureEvent + 5, 100), TrendDirection.SHORT, TARGET, TOLERANCE, touches::add);
        assertEquals(List.of(firstEvent, futureEvent + 5), touches);
        assertEquals(serverTime + cooldown, stateFor("ETHUSDC").getLastAlertTimeMs());
    }

    @Test
    void delayedExchangeEventsCanAlertAfterTwentyFourHoursOfServerTime() {
        List<Long> touches = new ArrayList<>();
        long serverTime = 1_000_000_000L;
        long firstEvent = event(1);
        clock.setMillis(serverTime);
        service.evaluate(at(firstEvent, 100), TrendDirection.SHORT, TARGET, TOLERANCE, touches::add);

        clock.setMillis(serverTime + FourHourEmaPullbackStateService.ALERT_COOLDOWN_MS);
        service.evaluate(at(firstEvent + 1, 90), TrendDirection.SHORT, TARGET, TOLERANCE, touches::add);
        service.evaluate(at(firstEvent + 2, 100), TrendDirection.SHORT, TARGET, TOLERANCE, touches::add);

        assertEquals(List.of(firstEvent, firstEvent + 2), touches);
        assertEquals(clock.millis(), stateFor("ETHUSDC").getLastAlertTimeMs());
    }

    @Test
    void reversingDirectionSharesTheSameSymbolCooldownButOtherSymbolsAreIndependent() {
        List<Long> touches = new ArrayList<>();
        evaluate(live(1, 100), TrendDirection.LONG, touches);
        evaluate(live(2, 90), TrendDirection.SHORT, touches);
        evaluate(live(3, 100), TrendDirection.SHORT, touches);
        assertEquals(List.of(event(1)), touches);
        assertEquals("SHORT", stateFor("ETHUSDC").getDirection());

        MarketKline otherSymbol = live(4, 100);
        otherSymbol.setPair("ZECUSDC");
        evaluate(otherSymbol, TrendDirection.SHORT, touches);
        assertEquals(List.of(event(1), event(4)), touches);

        long boundary = event(1) + FourHourEmaPullbackStateService.ALERT_COOLDOWN_MS;
        evaluate(at(boundary - 1, 90), TrendDirection.SHORT, touches);
        evaluate(at(boundary, 100), TrendDirection.SHORT, touches);
        assertEquals(List.of(event(1), event(4), boundary), touches);
    }

    @Test
    void stayingInsideAfterCooldownDoesNotReplayTheConsumedTouch() {
        List<Long> touches = new ArrayList<>();
        long firstTouch = event(1);
        long boundary = firstTouch + FourHourEmaPullbackStateService.ALERT_COOLDOWN_MS;
        evaluate(at(firstTouch, 100), TrendDirection.SHORT, touches);
        evaluate(at(boundary, 100), TrendDirection.SHORT, touches);
        assertEquals(List.of(firstTouch), touches);

        evaluate(at(boundary + 1, 90), TrendDirection.SHORT, touches);
        evaluate(at(boundary + 2, 100), TrendDirection.SHORT, touches);
        assertEquals(List.of(firstTouch, boundary + 2), touches);
    }

    @Test
    void aWickConsumedDuringCooldownCannotBeReplayedAtExpiry() {
        List<Long> touches = new ArrayList<>();
        long firstTouch = event(10);
        long boundary = firstTouch + FourHourEmaPullbackStateService.ALERT_COOLDOWN_MS;
        evaluate(at(firstTouch, 100), TrendDirection.SHORT, touches);
        evaluate(at(boundary - 3_000, 90), TrendDirection.SHORT, touches);
        MarketKline source = new MarketKline();
        source.setOpenTimeMs(Math.floorDiv(boundary - 2_000, 60_000) * 60_000);
        source.setHighPrice(TARGET);
        source.setLowPrice(new BigDecimal("90"));
        evaluateSource(at(boundary - 2_000, 95), source, TrendDirection.SHORT, touches);
        evaluateSource(at(boundary - 1_000, 90), source, TrendDirection.SHORT, touches);
        evaluateSource(at(boundary, 95), source, TrendDirection.SHORT, touches);
        assertEquals(List.of(firstTouch), touches);

        source.setHighPrice(new BigDecimal("101"));
        evaluateSource(at(boundary + 1_000, 95), source, TrendDirection.SHORT, touches);
        assertEquals(List.of(firstTouch, boundary + 1_000), touches);
    }

    @Test
    void cooldownRemainsDurableAcrossAServiceRestartAndDifferentFourHourBuckets() {
        List<Long> touches = new ArrayList<>();
        evaluate(live(1, 100), TrendDirection.SHORT, touches);
        FourHourEmaPullbackStateService restarted = new FourHourEmaPullbackStateService(mapper, clock);
        restarted.evaluate(at(event(1) + BUCKET_OPEN, 90), TrendDirection.SHORT,
                TARGET, TOLERANCE, touches::add);
        restarted.evaluate(at(event(1) + BUCKET_OPEN + 1, 100), TrendDirection.SHORT,
                TARGET, TOLERANCE, touches::add);
        assertEquals(List.of(event(1)), touches);
        assertEquals(event(1), stateFor("ETHUSDC").getLastAlertTimeMs());
    }

    @Test
    @Transactional(propagation = Propagation.NOT_SUPPORTED)
    void failedSignalInsertionDoesNotConsumeCooldownOnAnExistingState() {
        String pair = "COOLDOWNFAILUSDC";
        MarketKline armed = live(1, 90);
        armed.setPair(pair);
        evaluate(armed, TrendDirection.SHORT, new ArrayList<>());
        MarketKline touch = live(2, 100);
        touch.setPair(pair);
        assertThrows(IllegalStateException.class, () -> service.evaluate(
                touch, TrendDirection.SHORT, TARGET, TOLERANCE, ignored -> {
                    throw new IllegalStateException("signal insertion failed");
                }
        ));
        assertEquals(-1L, jdbcTemplate.queryForObject(
                "select last_alert_time_ms from four_hour_ema_pullback_state where pair = ?",
                Long.class, pair
        ));
        assertEquals(event(1), jdbcTemplate.queryForObject(
                "select last_event_ms from four_hour_ema_pullback_state where pair = ?",
                Long.class, pair
        ));

        List<Long> touches = new ArrayList<>();
        evaluate(touch, TrendDirection.SHORT, touches);
        assertEquals(List.of(event(2)), touches);
    }

    private FourHourEmaPullbackState stateFor(String pair) {
        FourHourEmaPullbackState key = new FourHourEmaPullbackState();
        key.setExchange("BINANCE");
        key.setMarketType("USDM");
        key.setContractType("PERPETUAL");
        key.setPair(pair);
        return mapper.selectForUpdate(key);
    }

    private MarketKline at(long timestamp, int close) {
        MarketKline kline = live(1, close);
        long bucketOpen = Math.floorDiv(timestamp, BUCKET_OPEN) * BUCKET_OPEN;
        kline.setOpenTimeMs(bucketOpen);
        kline.setCloseTimeMs(bucketOpen + BUCKET_OPEN - 1);
        kline.setEventTimeMs(timestamp);
        return kline;
    }

    private void concurrentEvaluate(CyclicBarrier barrier, AtomicInteger touches) {
        try {
            barrier.await(5, TimeUnit.SECONDS);
            MarketKline kline = live(1, 100);
            kline.setPair("CONCURRENTUSDC");
            service.evaluate(kline, TrendDirection.LONG, TARGET, TOLERANCE,
                    ignored -> touches.incrementAndGet());
        } catch (Exception ex) {
            throw new RuntimeException(ex);
        }
    }

    private void evaluate(MarketKline kline, TrendDirection direction, List<Long> touches) {
        clock.setMillis(kline.getEventTimeMs());
        service.evaluate(kline, direction, TARGET, TOLERANCE, touches::add);
    }

    private void evaluateSource(
            MarketKline kline, MarketKline source, TrendDirection direction, List<Long> touches
    ) {
        clock.setMillis(kline.getEventTimeMs());
        service.evaluate(kline, direction, TARGET, TOLERANCE, source, touches::add);
    }

    private MarketKline minute(int offset, int high, int low) {
        MarketKline source = new MarketKline();
        source.setOpenTimeMs(BUCKET_OPEN + offset * 60_000L);
        source.setHighPrice(BigDecimal.valueOf(high));
        source.setLowPrice(BigDecimal.valueOf(low));
        return source;
    }

    private long event(int sequence) {
        return BUCKET_OPEN + sequence * 1_000L;
    }

    private MarketKline live(int sequence, int close) {
        MarketKline kline = new MarketKline();
        kline.setExchange("BINANCE");
        kline.setMarketType("USDM");
        kline.setContractType("PERPETUAL");
        kline.setPair("ETHUSDC");
        kline.setIntervalCode("4h");
        kline.setOpenTimeMs(BUCKET_OPEN);
        kline.setCloseTimeMs(BUCKET_OPEN * 2 - 1);
        kline.setEventTimeMs(event(sequence));
        kline.setOpenPrice(BigDecimal.valueOf(close));
        kline.setHighPrice(BigDecimal.valueOf(close));
        kline.setLowPrice(BigDecimal.valueOf(close));
        kline.setClosePrice(BigDecimal.valueOf(close));
        kline.setClosedState(0);
        return kline;
    }

    @TestConfiguration
    static class ClockConfiguration {
        @Bean
        MutableClock mutableClock() {
            return new MutableClock();
        }

        @Bean
        @Primary
        FourHourEmaPullbackStateService testStateService(
                FourHourEmaPullbackStateMapper mapper, MutableClock clock
        ) {
            return new FourHourEmaPullbackStateService(mapper, clock);
        }
    }

    static final class MutableClock extends Clock {
        private final AtomicLong now = new AtomicLong();

        void setMillis(long time) {
            now.set(time);
        }

        @Override
        public ZoneId getZone() {
            return ZoneId.of("UTC");
        }

        @Override
        public Clock withZone(ZoneId zone) {
            return this;
        }

        @Override
        public long millis() {
            return now.get();
        }

        @Override
        public Instant instant() {
            return Instant.ofEpochMilli(millis());
        }
    }
}
