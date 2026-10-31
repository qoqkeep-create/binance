package com.oovso.strategy;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.oovso.market.MarketKline;
import com.oovso.market.MarketKlineMapper;
import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;
import java.util.stream.IntStream;
import org.junit.jupiter.api.Test;

class FourHourIntrabarKlineAggregatorTest {

    private final MarketKlineMapper mapper = mock(MarketKlineMapper.class);

    private final FourHourIntrabarKlineAggregator aggregator =
            new FourHourIntrabarKlineAggregator(mapper);

    @Test
    void buildsProvisionalFourHourWithoutWaitingForClose() {
        long bucketOpen = 14_400_000L;
        long liveMinuteOpen = bucketOpen + 2 * 60_000L;
        List<MarketKline> closedMinutes = List.of(
                minute(bucketOpen, 100, 1),
                minute(bucketOpen + 60_000L, 101, 1)
        );
        MarketKline live = minute(liveMinuteOpen, 102, 0);
        live.setHighPrice(new BigDecimal("120"));
        live.setLowPrice(new BigDecimal("98"));
        live.setClosePrice(new BigDecimal("110"));

        when(mapper.selectClosedInRange(
                eq("BINANCE"),
                eq("USDM"),
                eq("PERPETUAL"),
                eq("BTCUSDC"),
                eq("1m"),
                eq(bucketOpen),
                eq(liveMinuteOpen)
        )).thenReturn(closedMinutes);
        when(mapper.selectClosedBefore(
                eq("BINANCE"),
                eq("USDM"),
                eq("PERPETUAL"),
                eq("BTCUSDC"),
                eq("4h"),
                eq(bucketOpen),
                eq(2)
        )).thenReturn(List.of(
                fourHour(bucketOpen - 28_800_000L),
                fourHour(bucketOpen - 14_400_000L)
        ));

        Optional<FourHourIntrabarKlineAggregator.Snapshot> result = aggregator.aggregate(live, 3);

        assertTrue(result.isPresent());
        MarketKline provisional = result.orElseThrow().provisional();
        assertEquals("4h", provisional.getIntervalCode());
        assertEquals(0, provisional.getClosedState());
        assertEquals(bucketOpen, provisional.getOpenTimeMs());
        assertEquals(new BigDecimal("100"), provisional.getOpenPrice());
        assertEquals(new BigDecimal("120"), provisional.getHighPrice());
        assertEquals(new BigDecimal("98"), provisional.getLowPrice());
        assertEquals(new BigDecimal("110"), provisional.getClosePrice());
        assertEquals(3, result.orElseThrow().klines().size());
        assertSame(live, result.orElseThrow().sourceOneMinute());
    }

    @Test
    void finalOneMinuteWickStillBuildsAnUnpersistedFourHourSnapshot() {
        long bucketOpen = 14_400_000L;
        MarketKline finalMinute = minute(bucketOpen, 100, 1);
        finalMinute.setHighPrice(new BigDecimal("120"));
        when(mapper.selectClosedInRange(
                "BINANCE", "USDM", "PERPETUAL", "BTCUSDC", "1m", bucketOpen, bucketOpen
        )).thenReturn(List.of());

        FourHourIntrabarKlineAggregator.Snapshot snapshot =
                aggregator.aggregate(finalMinute, 1).orElseThrow();

        assertEquals(0, snapshot.provisional().getClosedState());
        assertEquals(new BigDecimal("120"), snapshot.provisional().getHighPrice());
        assertSame(finalMinute, snapshot.sourceOneMinute());
        verify(mapper, org.mockito.Mockito.never()).upsert(org.mockito.ArgumentMatchers.any());
    }

    @Test
    void reusesClosedMinuteAndFourHourHistoryWithinSameLiveMinute() {
        long bucketOpen = 14_400_000L;
        long liveMinuteOpen = bucketOpen + 60_000L;
        MarketKline first = minute(liveMinuteOpen, 101, 0);
        MarketKline second = minute(liveMinuteOpen, 102, 0);
        when(mapper.selectClosedInRange(
                eq("BINANCE"),
                eq("USDM"),
                eq("PERPETUAL"),
                eq("BTCUSDC"),
                eq("1m"),
                eq(bucketOpen),
                eq(liveMinuteOpen)
        )).thenReturn(List.of(minute(bucketOpen, 100, 1)));
        when(mapper.selectClosedBefore(
                eq("BINANCE"),
                eq("USDM"),
                eq("PERPETUAL"),
                eq("BTCUSDC"),
                eq("4h"),
                eq(bucketOpen),
                eq(1)
        )).thenReturn(List.of(fourHour(bucketOpen - 14_400_000L)));

        assertTrue(aggregator.aggregate(first, 2).isPresent());
        assertTrue(aggregator.aggregate(second, 2).isPresent());

        verify(mapper, times(1)).selectClosedInRange(
                eq("BINANCE"),
                eq("USDM"),
                eq("PERPETUAL"),
                eq("BTCUSDC"),
                eq("1m"),
                anyLong(),
                anyLong()
        );
        verify(mapper, times(1)).selectClosedBefore(
                eq("BINANCE"),
                eq("USDM"),
                eq("PERPETUAL"),
                eq("BTCUSDC"),
                eq("4h"),
                anyLong(),
                eq(1)
        );
    }

    @Test
    void skipsWhenClosedMinutesHaveGap() {
        long bucketOpen = 14_400_000L;
        long liveMinuteOpen = bucketOpen + 2 * 60_000L;
        when(mapper.selectClosedInRange(
                eq("BINANCE"),
                eq("USDM"),
                eq("PERPETUAL"),
                eq("BTCUSDC"),
                eq("1m"),
                eq(bucketOpen),
                eq(liveMinuteOpen)
        )).thenReturn(List.of(minute(bucketOpen, 100, 1)));

        assertTrue(aggregator.aggregate(minute(liveMinuteOpen, 102, 0), 2).isEmpty());
    }

    private MarketKline fourHour(long openTime) {
        MarketKline kline = minute(openTime, 100, 1);
        kline.setIntervalCode("4h");
        kline.setCloseTimeMs(openTime + 14_399_999L);
        return kline;
    }

    private MarketKline minute(long openTime, int price, int closedState) {
        MarketKline kline = new MarketKline();
        kline.setExchange("BINANCE");
        kline.setMarketType("USDM");
        kline.setContractType("PERPETUAL");
        kline.setPair("BTCUSDC");
        kline.setIntervalCode("1m");
        kline.setOpenTimeMs(openTime);
        kline.setCloseTimeMs(openTime + 59_999L);
        kline.setEventTimeMs(openTime + 1_000L);
        kline.setOpenPrice(BigDecimal.valueOf(price));
        kline.setHighPrice(BigDecimal.valueOf(price + 2L));
        kline.setLowPrice(BigDecimal.valueOf(price - 2L));
        kline.setClosePrice(BigDecimal.valueOf(price + 1L));
        kline.setVolume(BigDecimal.ONE);
        kline.setQuoteVolume(BigDecimal.TEN);
        kline.setTradeCount(1L);
        kline.setTakerBuyVolume(new BigDecimal("0.5"));
        kline.setTakerBuyQuoteVolume(new BigDecimal("5"));
        kline.setClosedState(closedState);
        kline.setSourceInterval("1m");
        return kline;
    }
}
