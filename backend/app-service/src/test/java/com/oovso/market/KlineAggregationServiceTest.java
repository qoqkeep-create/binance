package com.oovso.market;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import java.math.BigDecimal;
import java.util.List;
import org.junit.jupiter.api.Test;

class KlineAggregationServiceTest {

    private final KlineStorageProperties properties = new KlineStorageProperties();

    private final MarketKlineMapper marketKlineMapper = mock(MarketKlineMapper.class);

    private final KlineAggregationService service = new KlineAggregationService(properties, marketKlineMapper);

    @Test
    void aggregatesCompleteOneHourFromOneMinuteKlines() {
        properties.setAggregationIntervals(List.of("1h"));
        long bucketOpenTime = 3_600_000L;
        List<MarketKline> sourceKlines = oneMinuteKlines(bucketOpenTime, 60);
        when(marketKlineMapper.selectClosedInRange(
                eq("BINANCE"),
                eq("USDM"),
                eq("PERPETUAL"),
                eq("BTCUSDC"),
                eq("1m"),
                eq(bucketOpenTime),
                eq(bucketOpenTime + MarketKlineService.intervalMillis("1h"))
        )).thenReturn(sourceKlines);

        List<MarketKline> aggregated = service.aggregateClosedSourceKline(sourceKlines.getLast());

        assertEquals(1, aggregated.size());
        MarketKline oneHour = aggregated.getFirst();
        assertEquals("1h", oneHour.getIntervalCode());
        assertEquals("1m", oneHour.getSourceInterval());
        assertEquals(bucketOpenTime, oneHour.getOpenTimeMs());
        assertEquals(sourceKlines.getLast().getCloseTimeMs(), oneHour.getCloseTimeMs());
        assertEquals(new BigDecimal("100"), oneHour.getOpenPrice());
        assertEquals(new BigDecimal("169"), oneHour.getHighPrice());
        assertEquals(new BigDecimal("99"), oneHour.getLowPrice());
        assertEquals(new BigDecimal("159.5"), oneHour.getClosePrice());
        assertEquals(new BigDecimal("60"), oneHour.getVolume());
        assertEquals(new BigDecimal("120"), oneHour.getQuoteVolume());
        assertEquals(1770L, oneHour.getTradeCount());
        assertEquals(new BigDecimal("30.0"), oneHour.getTakerBuyVolume());
        assertEquals(new BigDecimal("42.0"), oneHour.getTakerBuyQuoteVolume());
    }

    @Test
    void skipsIncompleteSourceBucket() {
        properties.setAggregationIntervals(List.of("1h"));
        long bucketOpenTime = 3_600_000L;
        List<MarketKline> sourceKlines = oneMinuteKlines(bucketOpenTime, 59);
        when(marketKlineMapper.selectClosedInRange(
                eq("BINANCE"),
                eq("USDM"),
                eq("PERPETUAL"),
                eq("BTCUSDC"),
                eq("1m"),
                anyLong(),
                anyLong()
        )).thenReturn(sourceKlines);

        List<MarketKline> aggregated = service.aggregateClosedSourceKline(oneMinuteKline(bucketOpenTime + 59 * 60_000L, 59));

        assertTrue(aggregated.isEmpty());
    }

    @Test
    void aggregatesExplicitBucketFromOneMinuteKlines() {
        long bucketOpenTime = 3_600_000L;
        List<MarketKline> sourceKlines = oneMinuteKlines(bucketOpenTime, 60);
        when(marketKlineMapper.selectClosedInRange(
                eq("BINANCE"),
                eq("USDM"),
                eq("PERPETUAL"),
                eq("BTCUSDC"),
                eq("1m"),
                eq(bucketOpenTime),
                eq(bucketOpenTime + MarketKlineService.intervalMillis("1h"))
        )).thenReturn(sourceKlines);

        java.util.Optional<MarketKline> aggregated = service.aggregateClosedBucket(
                "BINANCE",
                "USDM",
                "PERPETUAL",
                "BTCUSDC",
                "1m",
                "1h",
                bucketOpenTime
        );

        assertTrue(aggregated.isPresent());
        assertEquals("1h", aggregated.get().getIntervalCode());
        assertEquals("1m", aggregated.get().getSourceInterval());
        assertEquals(new BigDecimal("159.5"), aggregated.get().getClosePrice());
    }

    @Test
    void aggregatesPartialCurrentBucketFromClosedOneMinuteKlines() {
        long bucketOpenTime = 3_600_000L;
        List<MarketKline> sourceKlines = oneMinuteKlines(bucketOpenTime, 30);
        when(marketKlineMapper.selectClosedInRange(
                "BINANCE",
                "USDM",
                "PERPETUAL",
                "BTCUSDC",
                "1m",
                bucketOpenTime,
                bucketOpenTime + MarketKlineService.intervalMillis("1h")
        )).thenReturn(sourceKlines);

        MarketKline current = service.aggregatePartialBucket(
                "BINANCE",
                "USDM",
                "PERPETUAL",
                "BTCUSDC",
                "1h",
                bucketOpenTime
        ).orElseThrow();

        assertEquals(bucketOpenTime, current.getOpenTimeMs());
        assertEquals(
                bucketOpenTime + MarketKlineService.intervalMillis("1h") - 1,
                current.getCloseTimeMs()
        );
        assertEquals(0, current.getClosedState());
        assertEquals(new BigDecimal("100"), current.getOpenPrice());
        assertEquals(new BigDecimal("139"), current.getHighPrice());
        assertEquals(new BigDecimal("99"), current.getLowPrice());
        assertEquals(new BigDecimal("129.5"), current.getClosePrice());
        assertEquals(new BigDecimal("30"), current.getVolume());
    }

    @Test
    void skipsPartialCurrentBucketWhenOneMinuteKlinesHaveGap() {
        long bucketOpenTime = 3_600_000L;
        List<MarketKline> sourceKlines = new java.util.ArrayList<>(
                oneMinuteKlines(bucketOpenTime, 30)
        );
        sourceKlines.remove(12);
        when(marketKlineMapper.selectClosedInRange(
                "BINANCE",
                "USDM",
                "PERPETUAL",
                "BTCUSDC",
                "1m",
                bucketOpenTime,
                bucketOpenTime + MarketKlineService.intervalMillis("1h")
        )).thenReturn(sourceKlines);

        assertTrue(service.aggregatePartialBucket(
                "BINANCE",
                "USDM",
                "PERPETUAL",
                "BTCUSDC",
                "1h",
                bucketOpenTime
        ).isEmpty());
    }

    @Test
    void waitsUntilTargetIntervalBoundary() {
        properties.setAggregationIntervals(List.of("1h"));

        List<MarketKline> aggregated = service.aggregateClosedSourceKline(oneMinuteKline(3_600_000L + 58 * 60_000L, 58));

        assertTrue(aggregated.isEmpty());
    }

    private List<MarketKline> oneMinuteKlines(long bucketOpenTime, int count) {
        return java.util.stream.IntStream.range(0, count)
                .mapToObj(index -> oneMinuteKline(bucketOpenTime + index * 60_000L, index))
                .toList();
    }

    private MarketKline oneMinuteKline(long openTimeMs, int index) {
        MarketKline kline = new MarketKline();
        kline.setExchange("BINANCE");
        kline.setMarketType("USDM");
        kline.setContractType("PERPETUAL");
        kline.setPair("BTCUSDC");
        kline.setIntervalCode("1m");
        kline.setOpenTimeMs(openTimeMs);
        kline.setCloseTimeMs(openTimeMs + 59_999L);
        kline.setEventTimeMs(openTimeMs + 60_000L);
        kline.setOpenPrice(new BigDecimal(100 + index));
        kline.setHighPrice(new BigDecimal(110 + index));
        kline.setLowPrice(new BigDecimal(99 + index));
        kline.setClosePrice(new BigDecimal("100.5").add(new BigDecimal(index)));
        kline.setVolume(BigDecimal.ONE);
        kline.setQuoteVolume(new BigDecimal("2"));
        kline.setTradeCount((long) index);
        kline.setTakerBuyVolume(new BigDecimal("0.5"));
        kline.setTakerBuyQuoteVolume(new BigDecimal("0.7"));
        kline.setClosedState(1);
        kline.setSourceInterval("1m");
        return kline;
    }
}
