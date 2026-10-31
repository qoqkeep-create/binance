package com.oovso.strategy;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

class SuperEmaPullbackStrategyPropertiesTest {

    @Test
    void symbolFilterUsesConservativeDefaults() {
        SuperEmaPullbackStrategyProperties properties = new SuperEmaPullbackStrategyProperties();

        assertEquals(55, properties.getEmaMiddlePeriod());
        assertEquals(0.1, properties.getPullbackTouchToleranceAtrMultiple());
        assertEquals(0.002, properties.getPullbackTouchToleranceMaxRate());
        assertFalse(properties.isReversalPatternRequired());
        assertEquals(21, properties.getIndicatorPeriods().getEmaFastPeriod());
        assertTrue(properties.getFifteenMinute().isEnabled());
        assertEquals(3_000, properties.getFifteenMinute().getHistorySize());
        assertTrue(properties.getFourHour().isEnabled());
        assertEquals(500, properties.getFourHour().getHistorySize());
        assertTrue(properties.getFourHour().isEma144OutermostRequired());
        assertTrue(properties.getFourHour().isIntrabarAlertEnabled());
        assertEquals(250, properties.getFourHour().getIntrabarAnalysisIntervalMillis());
        assertEquals(12, properties.getIndicatorPeriods().getMacdShortPeriod());
        assertEquals(26, properties.getIndicatorPeriods().getMacdLongPeriod());
        assertEquals(9, properties.getIndicatorPeriods().getMacdSignalPeriod());
        assertEquals(5, properties.getRelativeExtremeLookbackBars());
        assertEquals(3, properties.getRelativeExtremeMinComparisonBars());
        assertEquals(
                0.6,
                properties.getRelativeExtremeMinQualifyingRatio()
        );
        assertEquals(
                0.5,
                properties.getRelativeExtremeToleranceAtrMultiple()
        );
        assertEquals(
                0.005,
                properties.getRelativeExtremeToleranceMaxRate()
        );
        assertTrue(properties.getSymbolFilter().isEnabled());
        assertTrue(properties.getSymbolFilter().getMinListingDays() >= 180);
        assertTrue(properties.getSymbolFilter().getMinAdx() >= 20);
    }
}
