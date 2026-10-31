package com.oovso.market;

import com.binance.connector.client.derivatives_trading_usds_futures.websocket.stream.model.ContinuousContractKlineCandlestickStreamsResponse;
import com.binance.connector.client.derivatives_trading_usds_futures.websocket.stream.model.ContinuousContractKlineCandlestickStreamsResponseK;
import com.google.gson.JsonObject;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.LocalDateTime;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.util.StringUtils;

@Service
public class MarketKlineService {

    private static final Logger log = LoggerFactory.getLogger(MarketKlineService.class);

    public static final String INTERVAL_1M = "1m";

    public static final String INTERVAL_5M = "5m";

    public static final String INTERVAL_15M = "15m";

    public static final String INTERVAL_1H = "1h";

    public static final String INTERVAL_4H = "4h";

    public static final String INTERVAL_1D = "1d";

    public static final List<String> SUPPORTED_INTERVALS = List.of(
            INTERVAL_1M,
            INTERVAL_5M,
            INTERVAL_15M,
            INTERVAL_1H,
            INTERVAL_4H,
            INTERVAL_1D
    );

    private final MarketKlineMapper marketKlineMapper;

    private final StringRedisTemplate stringRedisTemplate;

    private final KlineStorageProperties properties;

    private final KlineAggregationService klineAggregationService;

    private final ApplicationEventPublisher eventPublisher;

    public MarketKlineService(
            MarketKlineMapper marketKlineMapper,
            StringRedisTemplate stringRedisTemplate,
            KlineStorageProperties properties,
            KlineAggregationService klineAggregationService,
            ApplicationEventPublisher eventPublisher
    ) {
        this.marketKlineMapper = marketKlineMapper;
        this.stringRedisTemplate = stringRedisTemplate;
        this.properties = properties;
        this.klineAggregationService = klineAggregationService;
        this.eventPublisher = eventPublisher;
    }

    @Transactional
    public void saveClosedKline(ContinuousContractKlineCandlestickStreamsResponse event) {
        if (!properties.isEnabled()) {
            return;
        }
        ContinuousContractKlineCandlestickStreamsResponseK kline = event.getkLowerCase();
        if (kline == null || !Boolean.TRUE.equals(kline.getxLowerCase())) {
            return;
        }

        MarketKline closedKline = fromEvent(event, kline);
        List<MarketKline> persistedKlines = upsertCacheAndAggregate(closedKline);
        publishClosedKlineEventsAfterCommit(persistedKlines);
    }

    @Transactional
    public void saveBackfilledClosedKline(MarketKline closedKline) {
        if (!properties.isEnabled()) {
            return;
        }
        upsertAndCache(closedKline);
    }

    @Transactional
    public void saveBackfilledClosedKlines(List<MarketKline> closedKlines) {
        if (!properties.isEnabled() || closedKlines == null) {
            return;
        }
        closedKlines.forEach(this::upsertAndCache);
    }

    public void warmRedisCache(String contractType, String pair) {
        if (!properties.isEnabled()) {
            return;
        }
        String normalizedContractType = valueOrDefault(contractType, "PERPETUAL").toUpperCase(Locale.ROOT);
        String normalizedPair = pair.toUpperCase(Locale.ROOT);
        for (String intervalCode : properties.normalizedCacheIntervals()) {
            int cacheSize = Math.max(1, properties.cacheSize(intervalCode));
            String key = redisKey(normalizedContractType, normalizedPair, intervalCode);
            Long currentSize = stringRedisTemplate.opsForZSet().zCard(key);
            if (currentSize != null && currentSize >= cacheSize) {
                continue;
            }

            List<MarketKline> latestKlines = marketKlineMapper.selectLatestClosed(
                    properties.getExchange(),
                    properties.getMarketType(),
                    normalizedContractType,
                    normalizedPair,
                    intervalCode,
                    cacheSize
            );
            latestKlines.stream()
                    .sorted(Comparator.comparing(MarketKline::getOpenTimeMs))
                    .forEach(this::cache);
            if (!latestKlines.isEmpty()) {
                log.info(
                        "Warmed Redis cache {} {} {} with {} recent klines",
                        normalizedPair,
                        normalizedContractType,
                        intervalCode,
                        latestKlines.size()
                );
            }
        }
    }

    public static long intervalMillis(String intervalCode) {
        return switch (intervalCode) {
            case INTERVAL_1M -> Duration.ofMinutes(1).toMillis();
            case INTERVAL_5M -> Duration.ofMinutes(5).toMillis();
            case INTERVAL_15M -> Duration.ofMinutes(15).toMillis();
            case INTERVAL_1H -> Duration.ofHours(1).toMillis();
            case INTERVAL_4H -> Duration.ofHours(4).toMillis();
            case INTERVAL_1D -> Duration.ofDays(1).toMillis();
            default -> throw new IllegalArgumentException("Unsupported kline interval: " + intervalCode);
        };
    }

    public static boolean isSupportedInterval(String intervalCode) {
        return SUPPORTED_INTERVALS.contains(intervalCode);
    }

    private MarketKline fromEvent(
            ContinuousContractKlineCandlestickStreamsResponse event,
            ContinuousContractKlineCandlestickStreamsResponseK kline
    ) {
        MarketKline entity = new MarketKline();
        entity.setExchange(properties.getExchange());
        entity.setMarketType(properties.getMarketType());
        entity.setContractType(valueOrDefault(event.getCt(), "PERPETUAL"));
        entity.setPair(event.getPs());
        entity.setIntervalCode(kline.getiLowerCase());
        entity.setOpenTimeMs(kline.gettLowerCase());
        entity.setCloseTimeMs(kline.getT());
        entity.setEventTimeMs(event.getE());
        entity.setOpenPrice(decimal(kline.getoLowerCase()));
        entity.setHighPrice(decimal(kline.gethLowerCase()));
        entity.setLowPrice(decimal(kline.getlLowerCase()));
        entity.setClosePrice(decimal(kline.getcLowerCase()));
        entity.setVolume(decimal(kline.getvLowerCase()));
        entity.setQuoteVolume(decimal(kline.getqLowerCase()));
        entity.setTradeCount(kline.getnLowerCase());
        entity.setTakerBuyVolume(decimal(kline.getV()));
        entity.setTakerBuyQuoteVolume(decimal(kline.getQ()));
        entity.setClosedState(Boolean.TRUE.equals(kline.getxLowerCase()) ? 1 : 0);
        entity.setSourceInterval(kline.getiLowerCase());
        fillBaseFields(entity);
        return entity;
    }

    private List<MarketKline> upsertCacheAndAggregate(MarketKline kline) {
        upsertAndCache(kline);
        List<MarketKline> persisted = new java.util.ArrayList<>();
        persisted.add(kline);
        for (MarketKline aggregated : klineAggregationService.aggregateClosedSourceKline(kline)) {
            upsertAndCache(aggregated);
            persisted.add(aggregated);
        }
        return persisted;
    }

    private void upsertAndCache(MarketKline kline) {
        normalizeClosedKline(kline);
        kline.setId(idFor(kline));
        marketKlineMapper.upsert(kline);
        cache(kline);
    }

    private void publishClosedKlineEventsAfterCommit(List<MarketKline> klines) {
        if (klines.isEmpty()) {
            return;
        }
        Runnable publisher = () -> klines.forEach(kline -> eventPublisher.publishEvent(new MarketClosedKlineEvent(kline)));
        if (!TransactionSynchronizationManager.isSynchronizationActive()) {
            publisher.run();
            return;
        }
        TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
            @Override
            public void afterCommit() {
                publisher.run();
            }
        });
    }

    private void normalizeClosedKline(MarketKline kline) {
        kline.setExchange(valueOrDefault(kline.getExchange(), properties.getExchange()));
        kline.setMarketType(valueOrDefault(kline.getMarketType(), properties.getMarketType()));
        kline.setContractType(valueOrDefault(kline.getContractType(), "PERPETUAL").toUpperCase(Locale.ROOT));
        kline.setPair(kline.getPair().toUpperCase(Locale.ROOT));
        kline.setIntervalCode(valueOrDefault(kline.getIntervalCode(), INTERVAL_1H).toLowerCase(Locale.ROOT));
        kline.setClosedState(1);
        kline.setSourceInterval(valueOrDefault(kline.getSourceInterval(), kline.getIntervalCode()).toLowerCase(Locale.ROOT));
        fillBaseFields(kline);
    }

    private void cache(MarketKline kline) {
        String key = redisKey(kline);
        String value = toJson(kline);
        double score = kline.getOpenTimeMs().doubleValue();
        stringRedisTemplate.opsForZSet().removeRangeByScore(key, score, score);
        stringRedisTemplate.opsForZSet().add(key, value, score);

        int cacheSize = Math.max(1, properties.cacheSize(kline.getIntervalCode()));
        Long currentSize = stringRedisTemplate.opsForZSet().zCard(key);
        if (currentSize != null && currentSize > cacheSize) {
            stringRedisTemplate.opsForZSet().removeRange(key, 0, currentSize - cacheSize - 1);
        }
        if (properties.getRedisKeyExpireDays() > 0) {
            stringRedisTemplate.expire(key, Duration.ofDays(properties.getRedisKeyExpireDays()));
        }
    }

    private String redisKey(MarketKline kline) {
        return redisKey(kline.getContractType(), kline.getPair(), kline.getIntervalCode());
    }

    private String redisKey(String contractType, String pair, String intervalCode) {
        return String.join(
                ":",
                properties.getRedisKeyPrefix(),
                contractType,
                pair,
                intervalCode
        );
    }

    private String toJson(MarketKline kline) {
        JsonObject json = new JsonObject();
        json.addProperty("id", kline.getId());
        json.addProperty("exchange", kline.getExchange());
        json.addProperty("marketType", kline.getMarketType());
        json.addProperty("contractType", kline.getContractType());
        json.addProperty("pair", kline.getPair());
        json.addProperty("intervalCode", kline.getIntervalCode());
        json.addProperty("openTimeMs", kline.getOpenTimeMs());
        json.addProperty("closeTimeMs", kline.getCloseTimeMs());
        json.addProperty("eventTimeMs", kline.getEventTimeMs());
        json.addProperty("openPrice", plain(kline.getOpenPrice()));
        json.addProperty("highPrice", plain(kline.getHighPrice()));
        json.addProperty("lowPrice", plain(kline.getLowPrice()));
        json.addProperty("closePrice", plain(kline.getClosePrice()));
        json.addProperty("volume", plain(kline.getVolume()));
        json.addProperty("quoteVolume", plain(kline.getQuoteVolume()));
        json.addProperty("tradeCount", kline.getTradeCount());
        json.addProperty("takerBuyVolume", plain(kline.getTakerBuyVolume()));
        json.addProperty("takerBuyQuoteVolume", plain(kline.getTakerBuyQuoteVolume()));
        json.addProperty("closedState", kline.getClosedState());
        json.addProperty("sourceInterval", kline.getSourceInterval());
        return json.toString();
    }

    private void fillBaseFields(MarketKline kline) {
        LocalDateTime now = LocalDateTime.now();
        kline.setCreateTime(now);
        kline.setUpdateTime(now);
        kline.setCreateUser("system");
        kline.setUpdateUser("system");
        kline.setDeleteState(0);
    }

    private String idFor(MarketKline kline) {
        String value = String.join(
                "|",
                kline.getExchange(),
                kline.getMarketType(),
                kline.getContractType(),
                kline.getPair(),
                kline.getIntervalCode(),
                String.valueOf(kline.getOpenTimeMs())
        );
        return UUID.nameUUIDFromBytes(value.getBytes(StandardCharsets.UTF_8)).toString();
    }

    private BigDecimal decimal(String value) {
        return StringUtils.hasText(value) ? new BigDecimal(value) : null;
    }

    private String plain(BigDecimal value) {
        return value == null ? null : value.toPlainString();
    }

    private String valueOrDefault(String value, String defaultValue) {
        return StringUtils.hasText(value) ? value : defaultValue;
    }
}
