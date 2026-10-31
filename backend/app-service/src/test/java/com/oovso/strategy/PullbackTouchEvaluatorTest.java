package com.oovso.strategy;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.oovso.market.MarketKline;
import java.math.BigDecimal;
import org.junit.jupiter.api.Test;

class PullbackTouchEvaluatorTest {

    @Test
    void usesAtrToleranceWhenItIsSmallerThanRateCap() {
        assertTrue(touches(kline("100.10", "101", "100.5"), "100", "1", TrendDirection.LONG));
        assertFalse(touches(kline("100.1001", "101", "100.5"), "100", "1", TrendDirection.LONG));
    }

    @Test
    void usesRateCapWhenItIsSmallerThanAtrTolerance() {
        assertTrue(touches(kline("99", "99.80", "99.5"), "100", "10", TrendDirection.SHORT));
        assertFalse(touches(kline("99", "99.79", "99.5"), "100", "10", TrendDirection.SHORT));
    }

    @Test
    void actualTouchOrCrossAlwaysMatches() {
        MarketKline kline = kline("99", "101", "100");

        assertTrue(PullbackTouchEvaluator.touches(
                kline,
                new BigDecimal("100"),
                BigDecimal.ZERO,
                TrendDirection.LONG,
                0,
                0,
                false,
                0.003
        ));
        assertTrue(PullbackTouchEvaluator.touches(
                kline,
                new BigDecimal("100"),
                BigDecimal.ZERO,
                TrendDirection.SHORT,
                0,
                0,
                false,
                0.003
        ));
    }

    @Test
    void shortDoesNotMatchWhenEntireKlineIsAboveTarget() {
        MarketKline linkKline = kline("7.877", "7.909", "7.900");

        assertFalse(touches(linkKline, "7.778359303597049", "0.10", TrendDirection.SHORT));
        assertFalse(touches(linkKline, "7.599991638128828", "0.10", TrendDirection.SHORT));
    }

    @Test
    void longDoesNotMatchWhenEntireKlineIsBelowTarget() {
        assertFalse(touches(kline("98.50", "99.50", "99.20"), "100", "1", TrendDirection.LONG));
    }

    @Test
    void keepsOptionalCloseConfirmation() {
        assertFalse(PullbackTouchEvaluator.touches(
                kline("99", "101", "99.6"),
                new BigDecimal("100"),
                BigDecimal.ONE,
                TrendDirection.LONG,
                0.1,
                0.002,
                true,
                0.003
        ));
    }

    private boolean touches(MarketKline kline, String target, String atr, TrendDirection direction) {
        return PullbackTouchEvaluator.touches(
                kline,
                new BigDecimal(target),
                new BigDecimal(atr),
                direction,
                0.1,
                0.002,
                false,
                0.003
        );
    }

    private MarketKline kline(String low, String high, String close) {
        MarketKline kline = new MarketKline();
        kline.setLowPrice(new BigDecimal(low));
        kline.setHighPrice(new BigDecimal(high));
        kline.setClosePrice(new BigDecimal(close));
        return kline;
    }
}
