package com.oovso.market;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.time.LocalDate;
import java.util.List;
import org.junit.jupiter.api.Test;

class KlineStoragePropertiesTest {

    @Test
    void usesOneMinuteAsAggregationSourceByDefault() {
        KlineStorageProperties properties = new KlineStorageProperties();

        assertTrue(properties.isAggregationEnabled());
        assertEquals("1m", properties.normalizedAggregationSourceInterval());
        assertEquals(List.of("5m", "15m", "1h", "4h", "1d"), properties.normalizedAggregationIntervals());
        assertEquals(List.of("1m", "5m", "15m", "1h", "4h", "1d"), properties.normalizedBackfillIntervals());
        assertFalse(properties.isStartupHistoricalBackfillEnabled());
        assertEquals(LocalDate.of(2018, 1, 1), properties.getHistoricalBackfillStartDate());
        assertEquals(10, properties.getHistoricalBackfillWindowDays());
        assertEquals(List.of("1m", "5m", "15m", "1h", "4h", "1d"), properties.normalizedHistoricalBackfillIntervals());
        assertEquals(3000, properties.cacheSize("1m"));
        assertEquals(3000, properties.cacheSize("1h"));
    }

    @Test
    void ignoresUnsupportedConfiguredIntervals() {
        KlineStorageProperties properties = new KlineStorageProperties();
        properties.setAggregationIntervals(List.of("5M", "bad", "1H", "5m"));
        properties.setBackfillIntervals(List.of("1M", "nope", "4H"));

        assertEquals(List.of("5m", "1h"), properties.normalizedAggregationIntervals());
        assertEquals(List.of("1m", "4h"), properties.normalizedBackfillIntervals());
    }

    @Test
    void fallsBackToDefaultBackfillIntervals() {
        KlineStorageProperties properties = new KlineStorageProperties();
        properties.setBackfillIntervals(List.of("bad"));

        assertEquals(List.of("1m", "5m", "15m", "1h", "4h", "1d"), properties.normalizedBackfillIntervals());
    }

    @Test
    void fallsBackToDefaultHistoricalBackfillIntervalsWithOneHour() {
        KlineStorageProperties properties = new KlineStorageProperties();
        properties.setHistoricalBackfillIntervals(List.of("bad"));

        assertEquals(
                List.of("1m", "5m", "15m", "1h", "4h", "1d"),
                properties.normalizedHistoricalBackfillIntervals()
        );
    }
}
