package com.oovso.strategy;

import static org.junit.jupiter.api.Assertions.assertEquals;

import com.oovso.market.MarketKline;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;

class DynamicSymbolKlineFilterTest {

    @Test
    void calculatesBarsPerDayForEveryStrategyInterval() {
        assertEquals(96, DynamicSymbolKlineFilter.barsPerDay("15m"));
        assertEquals(24, DynamicSymbolKlineFilter.barsPerDay("1h"));
        assertEquals(6, DynamicSymbolKlineFilter.barsPerDay("4h"));
    }

    @Test
    void calculatesMedianDailyQuoteVolumeFromHourlyKlines() {
        List<MarketKline> klines = new ArrayList<>();
        addDay(klines, "10");
        addDay(klines, "20");
        addDay(klines, "30");

        BigDecimal median = DynamicSymbolKlineFilter.medianDailyQuoteVolume(klines, 3);

        assertEquals(0, median.compareTo(new BigDecimal("480")));
    }

    @Test
    void calculatesMedianDailyQuoteVolumeFromFourHourKlines() {
        List<MarketKline> klines = new ArrayList<>();
        addFourHourDay(klines, "10");
        addFourHourDay(klines, "20");
        addFourHourDay(klines, "30");

        BigDecimal median = DynamicSymbolKlineFilter
                .medianDailyQuoteVolume(klines, 3, 6);

        assertEquals(0, median.compareTo(new BigDecimal("120")));
    }

    private void addDay(List<MarketKline> klines, String hourlyQuoteVolume) {
        for (int hour = 0; hour < 24; hour++) {
            MarketKline kline = new MarketKline();
            kline.setQuoteVolume(new BigDecimal(hourlyQuoteVolume));
            klines.add(kline);
        }
    }

    private void addFourHourDay(
            List<MarketKline> klines,
            String quoteVolume
    ) {
        for (int bar = 0; bar < 6; bar++) {
            MarketKline kline = new MarketKline();
            kline.setQuoteVolume(new BigDecimal(quoteVolume));
            klines.add(kline);
        }
    }
}
