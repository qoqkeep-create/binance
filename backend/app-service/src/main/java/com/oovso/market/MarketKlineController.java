package com.oovso.market;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.oovso.binance.BinanceUsdmMarketDataClient;
import com.oovso.binance.BinanceUsdmMarketDataClient.ChartTradingData;
import com.oovso.binance.BinanceUsdmMarketDataClient.ChartTradingDataSeries;
import com.oovso.strategy.StrategySymbolWhitelist;
import com.oovso.web.ApiResponse;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Positive;
import java.io.IOException;
import java.math.BigDecimal;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.stream.Collectors;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

@RestController
@RequestMapping("/api/market")
public class MarketKlineController {

    private static final Logger log =
            LoggerFactory.getLogger(MarketKlineController.class);

    private final MarketKlineMapper marketKlineMapper;

    private final KlineStorageProperties storageProperties;

    private final MarketKlineService marketKlineService;

    private final KlineAggregationService klineAggregationService;

    private final StrategySymbolWhitelist symbolWhitelist;

    private final BinanceUsdmMarketDataClient marketDataClient;

    public MarketKlineController(
            MarketKlineMapper marketKlineMapper,
            KlineStorageProperties storageProperties,
            MarketKlineService marketKlineService,
            KlineAggregationService klineAggregationService,
            StrategySymbolWhitelist symbolWhitelist,
            BinanceUsdmMarketDataClient marketDataClient
    ) {
        this.marketKlineMapper = marketKlineMapper;
        this.storageProperties = storageProperties;
        this.marketKlineService = marketKlineService;
        this.klineAggregationService = klineAggregationService;
        this.symbolWhitelist = symbolWhitelist;
        this.marketDataClient = marketDataClient;
    }

    @GetMapping("/klines")
    public ApiResponse<KlineHistoryResponse> klines(
            @RequestParam
            @Pattern(
                    regexp = "(?i)[A-Z0-9]{2,30}",
                    message = "交易对格式不正确"
            )
            String symbol,

            @RequestParam(defaultValue = MarketKlineService.INTERVAL_1H)
            @Pattern(
                    regexp = "1m|5m|15m|1h|4h|1d",
                    message = "K线周期不支持"
            )
            String interval,

            @RequestParam(defaultValue = "300")
            @Min(value = 50, message = "K线数量不能少于 50")
            @Max(value = 1_500, message = "K线数量不能超过 1500")
            int limit,

            @RequestParam(required = false)
            @Positive(message = "历史分页时间必须大于 0")
            Long beforeOpenTime,

            @RequestParam(name = "tradingData", required = false)
            String tradingDataQuery
    ) throws InterruptedException {
        String normalizedSymbol = normalizeSymbol(symbol);
        String normalizedInterval = interval.toLowerCase(Locale.ROOT);
        Set<ChartTradingDataSeries> requestedTradingData =
                parseTradingData(tradingDataQuery);
        List<MarketKline> stored = storedKlines(
                normalizedSymbol,
                normalizedInterval,
                limit,
                beforeOpenTime
        );
        List<MarketKline> recentKlines = stored;
        if (stored.size() < limit) {
            try {
                List<MarketKline> fallback = beforeOpenTime == null
                        ? marketDataClient.loadRecentContinuousKlines(
                                normalizedSymbol,
                                normalizedInterval,
                                limit
                        )
                        : marketDataClient.loadContinuousKlinesBefore(
                                normalizedSymbol,
                                normalizedInterval,
                                beforeOpenTime,
                                limit
                        );
                persistMissingClosedKlines(stored, fallback);
                recentKlines = mergeKlines(
                        stored,
                        fallback,
                        limit,
                        beforeOpenTime
                );
            } catch (IOException | RuntimeException ex) {
                log.warn(
                        "Failed to fill missing {} {} klines from Binance: {}",
                        normalizedSymbol,
                        normalizedInterval,
                        ex.getMessage()
                );
            }
        }
        if (beforeOpenTime == null) {
            recentKlines = appendLocalCurrentKline(
                    recentKlines,
                    normalizedSymbol,
                    normalizedInterval,
                    limit
            );
        }
        Map<Long, ChartTradingData> tradingData = Map.of();
        if (beforeOpenTime == null && !requestedTradingData.isEmpty()) {
            try {
                Map<Long, ChartTradingData> loaded =
                        marketDataClient.loadChartTradingData(
                                normalizedSymbol,
                                normalizedInterval,
                                requestedTradingData
                        );
                if (loaded != null) {
                    tradingData = loaded;
                }
            } catch (RuntimeException ex) {
                log.warn(
                        "Failed to load {} {} chart trading data: {}",
                        normalizedSymbol,
                        normalizedInterval,
                        ex.getMessage()
                );
            }
        }
        Map<Long, ChartTradingData> chartTradingData = tradingData;
        List<KlineItem> items = recentKlines.stream()
                .sorted(Comparator.comparing(MarketKline::getOpenTimeMs))
                .map(kline -> KlineItem.from(
                        kline,
                        chartTradingData.get(kline.getOpenTimeMs())
                ))
                .toList();
        return ApiResponse.success(new KlineHistoryResponse(
                normalizedSymbol,
                normalizedInterval,
                items
        ));
    }

    private List<MarketKline> storedKlines(
            String symbol,
            String interval,
            int limit,
            Long beforeOpenTime
    ) {
        if (beforeOpenTime != null) {
            return marketKlineMapper.selectClosedBefore(
                    storageProperties.getExchange(),
                    storageProperties.getMarketType(),
                    "PERPETUAL",
                    symbol,
                    interval,
                    beforeOpenTime,
                    limit
            );
        }
        return marketKlineMapper.selectLatestClosed(
                storageProperties.getExchange(),
                storageProperties.getMarketType(),
                "PERPETUAL",
                symbol,
                interval,
                limit
        );
    }

    private void persistMissingClosedKlines(
            List<MarketKline> stored,
            List<MarketKline> fallback
    ) {
        if (fallback == null || fallback.isEmpty()) {
            return;
        }
        Set<Long> storedOpenTimes = stored.stream()
                .map(MarketKline::getOpenTimeMs)
                .filter(java.util.Objects::nonNull)
                .collect(Collectors.toUnmodifiableSet());
        long now = System.currentTimeMillis();
        List<MarketKline> missingClosed = fallback.stream()
                .filter(kline -> kline.getOpenTimeMs() != null)
                .filter(kline -> kline.getCloseTimeMs() != null)
                .filter(kline -> kline.getCloseTimeMs() < now)
                .filter(kline -> !storedOpenTimes.contains(
                        kline.getOpenTimeMs()
                ))
                .toList();
        if (missingClosed.isEmpty()) {
            return;
        }
        try {
            marketKlineService.saveBackfilledClosedKlines(missingClosed);
        } catch (RuntimeException exception) {
            log.warn(
                    "Failed to persist {} Binance fallback klines: {}",
                    missingClosed.size(),
                    exception.getMessage()
            );
        }
    }

    private List<MarketKline> appendLocalCurrentKline(
            List<MarketKline> klines,
            String symbol,
            String interval,
            int limit
    ) {
        long intervalMillis = MarketKlineService.intervalMillis(interval);
        long now = System.currentTimeMillis();
        long bucketOpenTime = now - Math.floorMod(now, intervalMillis);
        return klineAggregationService.aggregatePartialBucket(
                        storageProperties.getExchange(),
                        storageProperties.getMarketType(),
                        "PERPETUAL",
                        symbol,
                        interval,
                        bucketOpenTime
                )
                .map(current -> mergeKlines(
                        klines,
                        List.of(current),
                        limit,
                        null
                ))
                .orElse(klines);
    }

    private List<MarketKline> mergeKlines(
            List<MarketKline> stored,
            List<MarketKline> fallback,
            int limit,
            Long beforeOpenTime
    ) {
        Map<Long, MarketKline> byOpenTime = new HashMap<>();
        stored.stream()
                .filter(kline -> kline.getOpenTimeMs() != null)
                .forEach(kline -> byOpenTime.put(
                        kline.getOpenTimeMs(),
                        kline
                ));
        if (fallback != null) {
            fallback.stream()
                    .filter(kline -> kline.getOpenTimeMs() != null)
                    .filter(kline -> beforeOpenTime == null
                            || kline.getOpenTimeMs() < beforeOpenTime)
                    .forEach(kline -> byOpenTime.putIfAbsent(
                            kline.getOpenTimeMs(),
                            kline
                    ));
        }
        List<MarketKline> merged = byOpenTime.values().stream()
                .sorted(Comparator.comparing(MarketKline::getOpenTimeMs))
                .toList();
        return merged.size() <= limit
                ? merged
                : merged.subList(merged.size() - limit, merged.size());
    }

    private String normalizeSymbol(String value) {
        String normalized = value.trim().toUpperCase(Locale.ROOT);
        String quoteAsset = symbolWhitelist.quoteAsset();
        if (normalized.endsWith(quoteAsset)) {
            return normalized;
        }
        return normalized + quoteAsset;
    }

    private Set<ChartTradingDataSeries> parseTradingData(String value) {
        if (value == null || value.isBlank()) {
            return Set.of();
        }
        try {
            return Arrays.stream(value.split(",", -1))
                    .map(ChartTradingDataSeries::fromQueryValue)
                    .collect(Collectors.toUnmodifiableSet());
        } catch (IllegalArgumentException exception) {
            throw new ResponseStatusException(
                    HttpStatus.BAD_REQUEST,
                    "K线统计数据类型不支持"
            );
        }
    }

    public record KlineHistoryResponse(
            String symbol,
            String interval,
            List<KlineItem> items
    ) {
    }

    public record KlineItem(
            long openTime,
            long closeTime,
            BigDecimal openPrice,
            BigDecimal highPrice,
            BigDecimal lowPrice,
            BigDecimal closePrice,
            BigDecimal volume,
            BigDecimal quoteVolume,
            @JsonInclude(JsonInclude.Include.NON_NULL)
            ChartTradingData tradingData
    ) {

        static KlineItem from(
                MarketKline kline,
                ChartTradingData tradingData
        ) {
            return new KlineItem(
                    value(kline.getOpenTimeMs()),
                    value(kline.getCloseTimeMs()),
                    kline.getOpenPrice(),
                    kline.getHighPrice(),
                    kline.getLowPrice(),
                    kline.getClosePrice(),
                    kline.getVolume(),
                    kline.getQuoteVolume(),
                    tradingData
            );
        }

        private static long value(Long value) {
            return value == null ? 0 : value;
        }
    }
}
