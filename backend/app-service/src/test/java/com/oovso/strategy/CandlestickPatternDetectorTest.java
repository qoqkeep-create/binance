package com.oovso.strategy;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;

import com.oovso.market.MarketKline;
import java.math.BigDecimal;
import java.util.Arrays;
import java.util.List;
import org.junit.jupiter.api.Test;

class CandlestickPatternDetectorTest {

    private final CandlestickPatternDetector detector = new CandlestickPatternDetector();

    @Test
    void detectsBullishSingleCandlePatterns() {
        assertPattern("DRAGONFLY_DOJI", TrendDirection.LONG, k(10.30, 10.35, 9.00, 10.32));
        assertPattern("HAMMER", TrendDirection.LONG, k(10.20, 10.40, 9.00, 10.35));
        assertPattern("INVERTED_HAMMER", TrendDirection.LONG, k(10.00, 11.30, 9.90, 10.15));
        assertPattern("DOJI_BULLISH_REVERSAL", TrendDirection.LONG, k(10.00, 10.80, 9.20, 10.03));
    }

    @Test
    void detectsBearishSingleCandlePatterns() {
        assertPattern("GRAVESTONE_DOJI", TrendDirection.SHORT, k(10.00, 11.30, 9.95, 10.02));
        assertPattern("HANGING_MAN", TrendDirection.SHORT, k(10.20, 10.40, 9.00, 10.35));
        assertPattern("SHOOTING_STAR", TrendDirection.SHORT, k(10.30, 11.50, 9.95, 10.00));
        assertPattern("DOJI_BEARISH_REVERSAL", TrendDirection.SHORT, k(10.00, 10.80, 9.20, 10.03));
    }

    @Test
    void detectsEngulfingAndPiercingPatterns() {
        assertPattern(
                "BULLISH_ENGULFING",
                TrendDirection.LONG,
                k(10.80, 11.00, 9.80, 10.00),
                k(9.90, 11.20, 9.70, 11.00)
        );
        assertPattern(
                "BEARISH_ENGULFING",
                TrendDirection.SHORT,
                k(10.00, 10.90, 9.90, 10.80),
                k(10.90, 11.00, 9.70, 9.80)
        );
        assertPattern(
                "PIERCING_LINE",
                TrendDirection.LONG,
                k(10.80, 11.00, 9.80, 10.00),
                k(9.95, 10.80, 9.70, 10.65)
        );
        assertPattern(
                "DARK_CLOUD_COVER",
                TrendDirection.SHORT,
                k(10.00, 11.10, 9.90, 11.00),
                k(11.05, 11.20, 10.30, 10.40)
        );
    }

    @Test
    void detectsStarPatterns() {
        assertPattern(
                "MORNING_STAR",
                TrendDirection.LONG,
                k(12.00, 12.20, 9.80, 10.00),
                k(9.80, 10.10, 9.50, 9.90),
                k(9.90, 11.30, 9.80, 11.20)
        );
        assertPattern(
                "EVENING_STAR",
                TrendDirection.SHORT,
                k(10.00, 12.20, 9.80, 12.00),
                k(12.10, 12.30, 11.90, 12.00),
                k(12.00, 12.10, 10.60, 10.80)
        );
    }

    @Test
    void detectsCannonAndSoldierPatterns() {
        assertPattern(
                "BULLISH_CANNON",
                TrendDirection.LONG,
                k(10.00, 11.20, 9.90, 11.00),
                k(10.90, 11.00, 10.20, 10.40),
                k(10.50, 11.50, 10.40, 11.40)
        );
        assertPattern(
                "BEARISH_CANNON",
                TrendDirection.SHORT,
                k(11.00, 11.10, 9.80, 10.00),
                k(10.10, 10.80, 10.00, 10.70),
                k(10.60, 10.70, 9.40, 9.60)
        );
        assertPattern(
                "THREE_WHITE_SOLDIERS",
                TrendDirection.LONG,
                k(10.00, 11.05, 9.90, 10.90),
                k(10.50, 11.40, 10.40, 11.30),
                k(10.90, 11.80, 10.80, 11.70)
        );
        assertPattern(
                "THREE_BLACK_CROWS",
                TrendDirection.SHORT,
                k(11.70, 11.80, 10.80, 10.90),
                k(11.30, 11.40, 10.40, 10.50),
                k(10.90, 11.00, 9.90, 10.00)
        );
    }

    @Test
    void detectsThreeMethodsAndBreakoutPatterns() {
        assertPattern(
                "RISING_THREE_METHODS",
                TrendDirection.LONG,
                k(10.00, 11.20, 9.90, 11.00),
                k(10.90, 11.00, 10.50, 10.82),
                k(10.80, 10.90, 10.40, 10.72),
                k(10.70, 10.80, 10.30, 10.62),
                k(10.80, 11.50, 10.70, 11.40)
        );
        assertPattern(
                "FALLING_THREE_METHODS",
                TrendDirection.SHORT,
                k(11.00, 11.10, 9.80, 10.00),
                k(10.10, 10.50, 10.00, 10.18),
                k(10.20, 10.60, 10.10, 10.28),
                k(10.30, 10.70, 10.20, 10.38),
                k(10.20, 10.30, 9.50, 9.60)
        );
        assertPattern(
                "ONE_YANG_FINGER",
                TrendDirection.LONG,
                k(10.00, 10.40, 9.90, 10.20),
                k(10.20, 10.45, 10.00, 10.30),
                k(10.30, 10.50, 10.10, 10.35),
                k(10.35, 11.40, 10.30, 11.30)
        );
        assertPattern(
                "HEAD_CUTTING_YIN",
                TrendDirection.SHORT,
                k(10.80, 11.00, 10.50, 10.70),
                k(10.70, 10.90, 10.45, 10.60),
                k(10.60, 10.80, 10.40, 10.55),
                k(10.55, 10.60, 9.50, 9.60)
        );
    }

    @Test
    void detectsFairyGuidePattern() {
        assertPattern(
                "BULLISH_FAIRY_GUIDE",
                TrendDirection.LONG,
                k(10.00, 11.30, 9.90, 10.15),
                k(10.20, 10.90, 10.10, 10.80)
        );
    }

    @Test
    void confirmedReversalRequiresOpposingContext() {
        List<MarketKline> values = List.of(
                k(12.00, 12.10, 10.90, 11.10),
                k(11.20, 11.30, 10.30, 10.50),
                k(10.60, 10.70, 9.80, 10.00),
                k(10.20, 10.30, 9.70, 9.80),
                k(9.70, 10.50, 9.60, 10.40)
        );

        CandlestickPatternDetector.PatternMatch match =
                detector.detectConfirmedReversal(
                        values,
                        values.size() - 1,
                        TrendDirection.LONG
                );

        assertNotNull(match);
        assertEquals("BULLISH_ENGULFING", match.patternCode());
    }

    @Test
    void confirmedReversalRejectsContinuationAndNeutralDoji() {
        List<MarketKline> continuation = List.of(
                k(12.00, 12.10, 10.90, 11.10),
                k(11.20, 11.30, 10.30, 10.50),
                k(10.60, 10.70, 9.80, 10.00),
                k(10.00, 11.20, 9.90, 11.00),
                k(10.90, 11.00, 10.50, 10.82),
                k(10.80, 10.90, 10.40, 10.72),
                k(10.70, 10.80, 10.30, 10.62),
                k(10.80, 11.50, 10.70, 11.40)
        );
        assertEquals(
                "RISING_THREE_METHODS",
                detector.detect(
                        continuation,
                        continuation.size() - 1,
                        TrendDirection.LONG
                ).patternCode()
        );
        assertNull(detector.detectConfirmedReversal(
                continuation,
                continuation.size() - 1,
                TrendDirection.LONG
        ));

        List<MarketKline> doji = List.of(
                k(12.00, 12.10, 10.90, 11.10),
                k(11.20, 11.30, 10.30, 10.50),
                k(10.60, 10.70, 9.80, 10.00),
                k(10.00, 10.80, 9.20, 10.03)
        );
        assertNull(detector.detectConfirmedReversal(
                doji,
                doji.size() - 1,
                TrendDirection.LONG
        ));
    }

    @Test
    void rejectsIncoherentOhlcValues() {
        assertNull(detector.detect(
                List.of(k(10.00, 9.90, 9.50, 10.20)),
                0,
                TrendDirection.LONG
        ));
    }

    @Test
    void rejectsIncompleteOhlcWithoutThrowing() {
        MarketKline incomplete = new MarketKline();
        incomplete.setOpenPrice(BigDecimal.TEN);

        assertNull(detector.detect(
                List.of(incomplete),
                0,
                TrendDirection.LONG
        ));
    }

    private void assertPattern(String expected, TrendDirection direction, MarketKline... klines) {
        List<MarketKline> values = Arrays.asList(klines);
        CandlestickPatternDetector.PatternMatch match = detector.detect(values, values.size() - 1, direction);
        assertNotNull(match);
        assertEquals(expected, match.patternCode());
    }

    private MarketKline k(double open, double high, double low, double close) {
        MarketKline kline = new MarketKline();
        kline.setOpenPrice(BigDecimal.valueOf(open));
        kline.setHighPrice(BigDecimal.valueOf(high));
        kline.setLowPrice(BigDecimal.valueOf(low));
        kline.setClosePrice(BigDecimal.valueOf(close));
        return kline;
    }
}
