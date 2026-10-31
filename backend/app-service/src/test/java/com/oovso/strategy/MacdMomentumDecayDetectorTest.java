package com.oovso.strategy;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.oovso.indicator.Ta4jKlineSeriesFactory;
import com.oovso.market.MarketKline;
import com.oovso.market.MarketKlineService;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;

class MacdMomentumDecayDetectorTest {

    private final MacdMomentumDecayDetector detector =
            new MacdMomentumDecayDetector(
                    new SuperEmaPullbackStrategyProperties(),
                    new Ta4jKlineSeriesFactory()
            );

    @Test
    void detectsNegativeHistogramMovingTowardZero() {
        List<MarketKline> klines = series(
                List.of("99", "97", "94", "90", "86", "105")
        );

        MacdMomentumDecayDetector.DecayMatch match = detector.detectDecay(
                klines,
                klines.size() - 1
        );

        assertEquals("MACD_MOMENTUM_DECAY", match.triggerCode());
        assertEquals("MACD能量衰减", match.triggerName());
    }

    @Test
    void detectsPositiveHistogramMovingTowardZero() {
        List<MarketKline> klines = series(
                List.of("101", "103", "106", "110", "114", "95")
        );

        MacdMomentumDecayDetector.DecayMatch match = detector.detectDecay(
                klines,
                klines.size() - 1
        );

        assertEquals("MACD_MOMENTUM_DECAY", match.triggerCode());
    }

    @Test
    void detectsMomentumDecayFromFifteenMinuteKlines() {
        List<MarketKline> klines = series(
                List.of("99", "97", "94", "90", "86", "105"),
                "15m"
        );

        MacdMomentumDecayDetector.DecayMatch match = detector.detectDecay(
                klines,
                klines.size() - 1
        );

        assertEquals("MACD_MOMENTUM_DECAY", match.triggerCode());
    }

    @Test
    void doesNotTriggerWhenHistogramMovesFartherFromZero() {
        List<MarketKline> klines = series(
                List.of("99", "97", "94", "90", "86", "82")
        );

        assertNull(detector.detectDecay(klines, klines.size() - 1));
    }

    @Test
    void comparesOnlyAbsoluteDistanceToZero() {
        assertTrue(detector.isCloserToZero(-2.0, -1.0));
        assertTrue(detector.isCloserToZero(2.0, 1.0));
        assertTrue(detector.isCloserToZero(2.0, -1.0));
        assertFalse(detector.isCloserToZero(-1.0, -2.0));
        assertFalse(detector.isCloserToZero(1.0, 1.0));
    }

    private List<MarketKline> series(List<String> tailCloses) {
        return series(tailCloses, "1h");
    }

    private List<MarketKline> series(
            List<String> tailCloses,
            String intervalCode
    ) {
        List<MarketKline> result = new ArrayList<>();
        long openTime = 0;
        long intervalMillis = MarketKlineService.intervalMillis(intervalCode);
        for (int index = 0; index < 100; index++) {
            result.add(kline(openTime, "100", "100", intervalCode));
            openTime += intervalMillis;
        }
        BigDecimal previous = new BigDecimal("100");
        for (String tailClose : tailCloses) {
            result.add(kline(
                    openTime,
                    previous.toPlainString(),
                    tailClose,
                    intervalCode
            ));
            previous = new BigDecimal(tailClose);
            openTime += intervalMillis;
        }
        return result;
    }

    private MarketKline kline(
            long openTime,
            String open,
            String close,
            String intervalCode
    ) {
        BigDecimal openPrice = new BigDecimal(open);
        BigDecimal closePrice = new BigDecimal(close);
        BigDecimal high = openPrice.max(closePrice).add(BigDecimal.ONE);
        BigDecimal low = openPrice.min(closePrice).subtract(BigDecimal.ONE);
        MarketKline kline = new MarketKline();
        kline.setIntervalCode(intervalCode);
        kline.setOpenTimeMs(openTime);
        kline.setCloseTimeMs(
                openTime
                        + MarketKlineService.intervalMillis(
                                intervalCode
                        )
                        - 1
        );
        kline.setOpenPrice(openPrice);
        kline.setHighPrice(high);
        kline.setLowPrice(low);
        kline.setClosePrice(closePrice);
        return kline;
    }
}
