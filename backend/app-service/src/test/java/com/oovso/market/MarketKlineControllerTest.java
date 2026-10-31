package com.oovso.market;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.oovso.binance.BinanceContinuousKlineProperties;
import com.oovso.binance.BinanceUsdmMarketDataClient;
import com.oovso.binance.BinanceUsdmMarketDataClient.ChartTradingData;
import com.oovso.binance.BinanceUsdmMarketDataClient.ChartTradingDataSeries;
import com.oovso.strategy.StrategySymbolWhitelist;
import com.oovso.strategy.SuperEmaPullbackStrategyProperties;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.stream.IntStream;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

class MarketKlineControllerTest {

    @Test
    void returnsLatestKlinesInAscendingOrder() throws Exception {
        Fixture fixture = fixture();
        MarketKline latest = kline(2_000L, "102");
        MarketKline earlier = kline(1_000L, "101");
        when(fixture.mapper().selectLatestClosed(
                "BINANCE",
                "USDM",
                "PERPETUAL",
                "BTCUSDC",
                "1h",
                300
        )).thenReturn(List.of(latest, earlier));

        MarketKlineController.KlineHistoryResponse response =
                fixture.controller().klines(
                        "btc", "1h", 300, null, null).data();

        assertEquals("BTCUSDC", response.symbol());
        assertEquals(
                List.of(1_000L, 2_000L),
                response.items().stream()
                        .map(MarketKlineController.KlineItem::openTime)
                        .toList()
        );
    }

    @Test
    void usesCompleteStoredHistoryWithoutCallingBinance() throws Exception {
        Fixture fixture = fixture();
        List<MarketKline> stored = IntStream.range(0, 50)
                .mapToObj(index -> kline(
                        index * 3_600_000L,
                        String.valueOf(100 + index)
                ))
                .toList();
        when(fixture.mapper().selectLatestClosed(
                "BINANCE",
                "USDM",
                "PERPETUAL",
                "BTCUSDC",
                "1h",
                50
        )).thenReturn(stored);
        MarketKline current = kline(
                System.currentTimeMillis() + 3_600_000L,
                "200"
        );
        current.setCloseTimeMs(current.getOpenTimeMs() + 3_599_999L);
        when(fixture.aggregationService().aggregatePartialBucket(
                org.mockito.ArgumentMatchers.anyString(),
                org.mockito.ArgumentMatchers.anyString(),
                org.mockito.ArgumentMatchers.anyString(),
                org.mockito.ArgumentMatchers.anyString(),
                org.mockito.ArgumentMatchers.eq("1h"),
                org.mockito.ArgumentMatchers.anyLong()
        )).thenReturn(Optional.of(current));

        MarketKlineController.KlineHistoryResponse response =
                fixture.controller().klines(
                        "btc", "1h", 50, null, null).data();

        assertEquals(50, response.items().size());
        assertEquals(
                current.getOpenTimeMs(),
                response.items().getLast().openTime()
        );
        verify(fixture.marketDataClient(), never())
                .loadRecentContinuousKlines(
                        "BTCUSDC",
                        "1h",
                        50
                );
        verifyNoInteractions(fixture.marketKlineService());
    }

    @Test
    void persistsOnlyMissingClosedBinanceFallbackKlines()
            throws Exception {
        Fixture fixture = fixture();
        MarketKline stored = kline(1_000L, "101");
        MarketKline overlappingFallback = kline(1_000L, "999");
        MarketKline missingClosed = kline(2_000L, "102");
        MarketKline current = kline(3_000L, "103");
        current.setCloseTimeMs(System.currentTimeMillis() + 60_000);
        when(fixture.mapper().selectLatestClosed(
                "BINANCE",
                "USDM",
                "PERPETUAL",
                "BTCUSDC",
                "1h",
                50
        )).thenReturn(List.of(stored));
        when(fixture.marketDataClient().loadRecentContinuousKlines(
                "BTCUSDC",
                "1h",
                50
        )).thenReturn(List.of(
                overlappingFallback,
                missingClosed,
                current
        ));

        MarketKlineController.KlineHistoryResponse response =
                fixture.controller().klines(
                        "btc", "1h", 50, null, null).data();

        assertEquals(
                List.of(1_000L, 2_000L, 3_000L),
                response.items().stream()
                        .map(MarketKlineController.KlineItem::openTime)
                        .toList()
        );
        assertEquals(
                new BigDecimal("101"),
                response.items().getFirst().closePrice()
        );
        @SuppressWarnings("unchecked")
        ArgumentCaptor<List<MarketKline>> persisted =
                ArgumentCaptor.forClass(List.class);
        verify(fixture.marketKlineService())
                .saveBackfilledClosedKlines(persisted.capture());
        assertEquals(
                List.of(2_000L),
                persisted.getValue().stream()
                        .map(MarketKline::getOpenTimeMs)
                        .toList()
        );
    }

    @Test
    void noLongerExposesChartDepthEndpoint() throws Exception {
        Fixture fixture = fixture();
        MockMvcBuilders.standaloneSetup(fixture.controller())
                .build()
                .perform(get("/api/market/depth")
                        .param("symbol", "ETHUSDC")
                        .param("limit", "100"))
                .andExpect(status().isNotFound());
        verifyNoInteractions(fixture.marketDataClient());
    }

    @Test
    void skipsTradingDataWhenChartDoesNotRequestIt() throws Exception {
        Fixture fixture = fixture();
        MarketKline live = kline(3_000L, "103");
        when(fixture.marketDataClient().loadRecentContinuousKlines(
                "BTCUSDC",
                "5m",
                300
        )).thenReturn(List.of(live));

        MarketKlineController.KlineHistoryResponse response =
                fixture.controller().klines(
                        "btc", "5m", 300, null, null).data();

        assertEquals(List.of(3_000L), response.items().stream()
                .map(MarketKlineController.KlineItem::openTime)
                .toList());
        assertNull(response.items().getFirst().tradingData());
        verify(fixture.marketDataClient(), never()).loadChartTradingData(
                "BTCUSDC",
                "5m",
                Set.of()
        );
    }

    @Test
    void attachesTradingDataToMatchingRecentKline() throws Exception {
        Fixture fixture = fixture();
        MarketKline live = kline(3_600_000L, "103");
        ChartTradingData tradingData = new ChartTradingData(
                new BigDecimal("123.4"),
                new BigDecimal("567.8"),
                new BigDecimal("0.57"),
                new BigDecimal("0.43"),
                new BigDecimal("1.32"),
                new BigDecimal("0.61"),
                new BigDecimal("0.39"),
                new BigDecimal("1.56"),
                new BigDecimal("0.48"),
                new BigDecimal("0.52"),
                new BigDecimal("0.92"),
                new BigDecimal("12"),
                new BigDecimal("9"),
                new BigDecimal("10"),
                new BigDecimal("0.001"),
                new BigDecimal("65010"),
                new BigDecimal("65000")
        );
        Set<ChartTradingDataSeries> requested = Set.of(
                ChartTradingDataSeries.OPEN_INTEREST,
                ChartTradingDataSeries.TOP_POSITION_RATIO,
                ChartTradingDataSeries.BUY_SELL_VOLUME,
                ChartTradingDataSeries.BASIS
        );
        when(fixture.marketDataClient().loadRecentContinuousKlines(
                "BTCUSDC",
                "1h",
                300
        )).thenReturn(List.of(live));
        when(fixture.marketDataClient().loadChartTradingData(
                "BTCUSDC",
                "1h",
                requested
        )).thenReturn(Map.of(3_600_000L, tradingData));

        MarketKlineController.KlineItem item = fixture.controller().klines(
                "btc",
                "1h",
                300,
                null,
                "openInterest,topPositionRatio,buySellVolume,basis"
        ).data().items().getFirst();

        assertEquals(new BigDecimal("567.8"),
                item.tradingData().openInterestNotional());
        assertEquals(new BigDecimal("1.56"),
                item.tradingData().topLongShortPositionRatio());
        assertEquals(new BigDecimal("12"),
                item.tradingData().takerBuyVolume());
        assertEquals(new BigDecimal("0.001"),
                item.tradingData().basisRate());
    }

    @Test
    void loadsHistoryStrictlyBeforeRequestedOpenTime() throws Exception {
        Fixture fixture = fixture();
        MarketKline older = kline(1_000L, "101");
        when(fixture.marketDataClient().loadContinuousKlinesBefore(
                "BTCUSDC",
                "1h",
                2_000L,
                300
        )).thenReturn(List.of(older));

        MarketKlineController.KlineHistoryResponse response =
                fixture.controller().klines(
                        "btc", "1h", 300, 2_000L, "openInterest").data();

        assertEquals(List.of(1_000L), response.items().stream()
                .map(MarketKlineController.KlineItem::openTime)
                .toList());
        verify(fixture.marketDataClient()).loadContinuousKlinesBefore(
                "BTCUSDC",
                "1h",
                2_000L,
                300
        );
        verify(fixture.marketDataClient(), never()).loadChartTradingData(
                "BTCUSDC",
                "1h",
                Set.of(ChartTradingDataSeries.OPEN_INTEREST)
        );
    }

    @Test
    void rejectsUnsupportedTradingDataSeries() throws Exception {
        Fixture fixture = fixture();

        MockMvcBuilders.standaloneSetup(fixture.controller())
                .build()
                .perform(get("/api/market/klines")
                        .param("symbol", "BTCUSDC")
                        .param("interval", "1h")
                        .param("tradingData", "unknown"))
                .andExpect(status().isBadRequest());
    }

    private Fixture fixture() {
        MarketKlineMapper mapper = mock(MarketKlineMapper.class);
        KlineStorageProperties storageProperties =
                new KlineStorageProperties();
        BinanceContinuousKlineProperties marketProperties =
                new BinanceContinuousKlineProperties();
        marketProperties.setQuoteAsset("USDC");
        StrategySymbolWhitelist whitelist =
                new StrategySymbolWhitelist(
                        new SuperEmaPullbackStrategyProperties(),
                        marketProperties
                );
        BinanceUsdmMarketDataClient marketDataClient =
                mock(BinanceUsdmMarketDataClient.class);
        MarketKlineService marketKlineService =
                mock(MarketKlineService.class);
        KlineAggregationService aggregationService =
                mock(KlineAggregationService.class);
        return new Fixture(
                new MarketKlineController(
                        mapper,
                        storageProperties,
                        marketKlineService,
                        aggregationService,
                        whitelist,
                        marketDataClient
                ),
                mapper,
                marketKlineService,
                aggregationService,
                marketDataClient
        );
    }

    private MarketKline kline(long openTime, String closePrice) {
        MarketKline kline = new MarketKline();
        kline.setOpenTimeMs(openTime);
        kline.setCloseTimeMs(openTime + 999);
        kline.setOpenPrice(new BigDecimal(closePrice));
        kline.setHighPrice(new BigDecimal(closePrice));
        kline.setLowPrice(new BigDecimal(closePrice));
        kline.setClosePrice(new BigDecimal(closePrice));
        kline.setVolume(BigDecimal.ONE);
        kline.setQuoteVolume(BigDecimal.TEN);
        kline.setTradeCount(1L);
        return kline;
    }

    private record Fixture(
            MarketKlineController controller,
            MarketKlineMapper mapper,
            MarketKlineService marketKlineService,
            KlineAggregationService aggregationService,
            BinanceUsdmMarketDataClient marketDataClient
    ) {
    }
}
