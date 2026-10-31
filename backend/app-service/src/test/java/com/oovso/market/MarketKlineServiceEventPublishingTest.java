package com.oovso.market;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.binance.connector.client.derivatives_trading_usds_futures.websocket.stream.model.ContinuousContractKlineCandlestickStreamsResponse;
import java.math.BigDecimal;
import java.util.List;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ZSetOperations;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

class MarketKlineServiceEventPublishingTest {

    private final MarketKlineMapper marketKlineMapper = mock(MarketKlineMapper.class);

    private final StringRedisTemplate redisTemplate = mock(StringRedisTemplate.class);

    private final ZSetOperations<String, String> zSetOperations = mock();

    private final KlineStorageProperties properties = new KlineStorageProperties();

    private final KlineAggregationService aggregationService = mock(KlineAggregationService.class);

    private final ApplicationEventPublisher eventPublisher = mock(ApplicationEventPublisher.class);

    private MarketKlineService service;

    @BeforeEach
    void setUp() {
        when(redisTemplate.opsForZSet()).thenReturn(zSetOperations);
        when(zSetOperations.zCard(anyString())).thenReturn(1L);
        service = new MarketKlineService(
                marketKlineMapper,
                redisTemplate,
                properties,
                aggregationService,
                eventPublisher
        );
    }

    @AfterEach
    void tearDown() {
        if (TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.clearSynchronization();
        }
    }

    @Test
    void publishesRealtimeClosedKlinesAfterCommit() throws Exception {
        MarketKline oneHour = kline("1h", 3_600_000L);
        when(aggregationService.aggregateClosedSourceKline(any())).thenReturn(List.of(oneHour));
        TransactionSynchronizationManager.initSynchronization();

        service.saveClosedKline(event());

        verify(eventPublisher, never()).publishEvent(any());
        List<TransactionSynchronization> synchronizations = TransactionSynchronizationManager.getSynchronizations();
        assertEquals(1, synchronizations.size());

        synchronizations.getFirst().afterCommit();

        ArgumentCaptor<Object> events = ArgumentCaptor.forClass(Object.class);
        verify(eventPublisher, times(2)).publishEvent(events.capture());
        List<String> intervals = events.getAllValues().stream()
                .map(MarketClosedKlineEvent.class::cast)
                .map(MarketClosedKlineEvent::kline)
                .map(MarketKline::getIntervalCode)
                .toList();
        assertEquals(List.of("1m", "1h"), intervals);
    }

    @Test
    void backfilledKlinesDoNotPublishEvents() {
        service.saveBackfilledClosedKline(kline("1m", 3_600_000L));

        verify(eventPublisher, never()).publishEvent(any());
        verify(aggregationService, never()).aggregateClosedSourceKline(any());
    }

    private ContinuousContractKlineCandlestickStreamsResponse event() throws java.io.IOException {
        return ContinuousContractKlineCandlestickStreamsResponse.fromJson("""
                {
                  "e": "continuous_kline",
                  "E": 3600060,
                  "ps": "BTCUSDC",
                  "ct": "PERPETUAL",
                  "k": {
                    "t": 3600000,
                    "T": 3659999,
                    "i": "1m",
                    "f": 1,
                    "L": 2,
                    "o": "100",
                    "c": "101",
                    "h": "102",
                    "l": "99",
                    "v": "10",
                    "n": 3,
                    "x": true,
                    "q": "1000",
                    "V": "4",
                    "Q": "400",
                    "B": "0"
                  }
                }
                """);
    }

    private MarketKline kline(String intervalCode, long openTimeMs) {
        MarketKline kline = new MarketKline();
        kline.setExchange("BINANCE");
        kline.setMarketType("USDM");
        kline.setContractType("PERPETUAL");
        kline.setPair("BTCUSDC");
        kline.setIntervalCode(intervalCode);
        kline.setOpenTimeMs(openTimeMs);
        kline.setCloseTimeMs(openTimeMs + MarketKlineService.intervalMillis(intervalCode) - 1);
        kline.setEventTimeMs(openTimeMs + MarketKlineService.intervalMillis(intervalCode));
        kline.setOpenPrice(new BigDecimal("100"));
        kline.setHighPrice(new BigDecimal("102"));
        kline.setLowPrice(new BigDecimal("99"));
        kline.setClosePrice(new BigDecimal("101"));
        kline.setVolume(new BigDecimal("10"));
        kline.setQuoteVolume(new BigDecimal("1000"));
        kline.setTradeCount(3L);
        kline.setTakerBuyVolume(new BigDecimal("4"));
        kline.setTakerBuyQuoteVolume(new BigDecimal("400"));
        kline.setClosedState(1);
        kline.setSourceInterval(intervalCode);
        return kline;
    }
}
