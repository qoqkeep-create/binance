package com.oovso.market;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;

@Component
@ConfigurationProperties(prefix = "market.kline")
public class KlineStorageProperties {

    private boolean enabled = true;

    private String exchange = "BINANCE";

    private String marketType = "USDM";

    private String redisKeyPrefix = "kline:BINANCE:USDM";

    private int cacheSize1m = 3_000;

    private int cacheSize5m = 3_000;

    private int cacheSize15m = 3_000;

    private int cacheSize1h = 3_000;

    private int cacheSize4h = 1_000;

    private int cacheSize1d = 730;

    private long redisKeyExpireDays = 180;

    private boolean aggregationEnabled = true;

    private String aggregationSourceInterval = MarketKlineService.INTERVAL_1M;

    private List<String> aggregationIntervals = new ArrayList<>(List.of(
            MarketKlineService.INTERVAL_5M,
            MarketKlineService.INTERVAL_15M,
            MarketKlineService.INTERVAL_1H,
            MarketKlineService.INTERVAL_4H,
            MarketKlineService.INTERVAL_1D
    ));

    private boolean backfillEnabled = true;

    private List<String> backfillIntervals = new ArrayList<>(List.of(
            MarketKlineService.INTERVAL_1M,
            MarketKlineService.INTERVAL_5M,
            MarketKlineService.INTERVAL_15M,
            MarketKlineService.INTERVAL_1H,
            MarketKlineService.INTERVAL_4H,
            MarketKlineService.INTERVAL_1D
    ));

    private boolean startupBackfillEnabled = true;

    private boolean startupHistoricalBackfillEnabled = false;

    private LocalDate historicalBackfillStartDate = LocalDate.of(2018, 1, 1);

    private int historicalBackfillWindowDays = 10;

    private List<String> historicalBackfillIntervals = new ArrayList<>(List.of(
            MarketKlineService.INTERVAL_1M,
            MarketKlineService.INTERVAL_5M,
            MarketKlineService.INTERVAL_15M,
            MarketKlineService.INTERVAL_1H,
            MarketKlineService.INTERVAL_4H,
            MarketKlineService.INTERVAL_1D
    ));

    private boolean continuityGuardEnabled = true;

    private long continuityGuardIntervalMillis = 60_000;

    private long closedKlineSafetyDelayMillis = 30_000;

    private int backfillRequestLimit = 1_500;

    private long backfillRequestDelayMillis = 300;

    private boolean startupRedisWarmupEnabled = true;

    public boolean isEnabled() {
        return enabled;
    }

    public void setEnabled(boolean enabled) {
        this.enabled = enabled;
    }

    public String getExchange() {
        return exchange;
    }

    public void setExchange(String exchange) {
        this.exchange = exchange;
    }

    public String getMarketType() {
        return marketType;
    }

    public void setMarketType(String marketType) {
        this.marketType = marketType;
    }

    public String getRedisKeyPrefix() {
        return redisKeyPrefix;
    }

    public void setRedisKeyPrefix(String redisKeyPrefix) {
        this.redisKeyPrefix = redisKeyPrefix;
    }

    public int getCacheSize1m() {
        return cacheSize1m;
    }

    public void setCacheSize1m(int cacheSize1m) {
        this.cacheSize1m = cacheSize1m;
    }

    public int getCacheSize5m() {
        return cacheSize5m;
    }

    public void setCacheSize5m(int cacheSize5m) {
        this.cacheSize5m = cacheSize5m;
    }

    public int getCacheSize15m() {
        return cacheSize15m;
    }

    public void setCacheSize15m(int cacheSize15m) {
        this.cacheSize15m = cacheSize15m;
    }

    public int getCacheSize1h() {
        return cacheSize1h;
    }

    public void setCacheSize1h(int cacheSize1h) {
        this.cacheSize1h = cacheSize1h;
    }

    public int getCacheSize4h() {
        return cacheSize4h;
    }

    public void setCacheSize4h(int cacheSize4h) {
        this.cacheSize4h = cacheSize4h;
    }

    public int getCacheSize1d() {
        return cacheSize1d;
    }

    public void setCacheSize1d(int cacheSize1d) {
        this.cacheSize1d = cacheSize1d;
    }

    public long getRedisKeyExpireDays() {
        return redisKeyExpireDays;
    }

    public void setRedisKeyExpireDays(long redisKeyExpireDays) {
        this.redisKeyExpireDays = redisKeyExpireDays;
    }

    public boolean isAggregationEnabled() {
        return aggregationEnabled;
    }

    public void setAggregationEnabled(boolean aggregationEnabled) {
        this.aggregationEnabled = aggregationEnabled;
    }

    public String getAggregationSourceInterval() {
        return aggregationSourceInterval;
    }

    public void setAggregationSourceInterval(String aggregationSourceInterval) {
        this.aggregationSourceInterval = aggregationSourceInterval;
    }

    public List<String> getAggregationIntervals() {
        return aggregationIntervals;
    }

    public void setAggregationIntervals(List<String> aggregationIntervals) {
        this.aggregationIntervals = aggregationIntervals == null ? new ArrayList<>() : new ArrayList<>(aggregationIntervals);
    }

    public boolean isBackfillEnabled() {
        return backfillEnabled;
    }

    public void setBackfillEnabled(boolean backfillEnabled) {
        this.backfillEnabled = backfillEnabled;
    }

    public List<String> getBackfillIntervals() {
        return backfillIntervals;
    }

    public void setBackfillIntervals(List<String> backfillIntervals) {
        this.backfillIntervals = backfillIntervals == null ? new ArrayList<>() : new ArrayList<>(backfillIntervals);
    }

    public boolean isStartupBackfillEnabled() {
        return startupBackfillEnabled;
    }

    public void setStartupBackfillEnabled(boolean startupBackfillEnabled) {
        this.startupBackfillEnabled = startupBackfillEnabled;
    }

    public boolean isStartupHistoricalBackfillEnabled() {
        return startupHistoricalBackfillEnabled;
    }

    public void setStartupHistoricalBackfillEnabled(boolean startupHistoricalBackfillEnabled) {
        this.startupHistoricalBackfillEnabled = startupHistoricalBackfillEnabled;
    }

    public LocalDate getHistoricalBackfillStartDate() {
        return historicalBackfillStartDate;
    }

    public void setHistoricalBackfillStartDate(LocalDate historicalBackfillStartDate) {
        this.historicalBackfillStartDate = historicalBackfillStartDate;
    }

    public int getHistoricalBackfillWindowDays() {
        return historicalBackfillWindowDays;
    }

    public void setHistoricalBackfillWindowDays(int historicalBackfillWindowDays) {
        this.historicalBackfillWindowDays = historicalBackfillWindowDays;
    }

    public List<String> getHistoricalBackfillIntervals() {
        return historicalBackfillIntervals;
    }

    public void setHistoricalBackfillIntervals(List<String> historicalBackfillIntervals) {
        this.historicalBackfillIntervals = historicalBackfillIntervals == null
                ? new ArrayList<>()
                : new ArrayList<>(historicalBackfillIntervals);
    }

    public boolean isContinuityGuardEnabled() {
        return continuityGuardEnabled;
    }

    public void setContinuityGuardEnabled(boolean continuityGuardEnabled) {
        this.continuityGuardEnabled = continuityGuardEnabled;
    }

    public long getContinuityGuardIntervalMillis() {
        return continuityGuardIntervalMillis;
    }

    public void setContinuityGuardIntervalMillis(long continuityGuardIntervalMillis) {
        this.continuityGuardIntervalMillis = continuityGuardIntervalMillis;
    }

    public long getClosedKlineSafetyDelayMillis() {
        return closedKlineSafetyDelayMillis;
    }

    public void setClosedKlineSafetyDelayMillis(long closedKlineSafetyDelayMillis) {
        this.closedKlineSafetyDelayMillis = closedKlineSafetyDelayMillis;
    }

    public int getBackfillRequestLimit() {
        return backfillRequestLimit;
    }

    public void setBackfillRequestLimit(int backfillRequestLimit) {
        this.backfillRequestLimit = backfillRequestLimit;
    }

    public long getBackfillRequestDelayMillis() {
        return backfillRequestDelayMillis;
    }

    public void setBackfillRequestDelayMillis(long backfillRequestDelayMillis) {
        this.backfillRequestDelayMillis = backfillRequestDelayMillis;
    }

    public boolean isStartupRedisWarmupEnabled() {
        return startupRedisWarmupEnabled;
    }

    public void setStartupRedisWarmupEnabled(boolean startupRedisWarmupEnabled) {
        this.startupRedisWarmupEnabled = startupRedisWarmupEnabled;
    }

    public int cacheSize(String intervalCode) {
        return switch (intervalCode) {
            case "1m" -> cacheSize1m;
            case "5m" -> cacheSize5m;
            case "15m" -> cacheSize15m;
            case "1h" -> cacheSize1h;
            case "4h" -> cacheSize4h;
            case "1d" -> cacheSize1d;
            default -> cacheSize1h;
        };
    }

    public String normalizedAggregationSourceInterval() {
        String interval = normalizeInterval(aggregationSourceInterval, MarketKlineService.INTERVAL_1M);
        return MarketKlineService.isSupportedInterval(interval) ? interval : MarketKlineService.INTERVAL_1M;
    }

    public List<String> normalizedAggregationIntervals() {
        return normalizeIntervals(aggregationIntervals);
    }

    public List<String> normalizedBackfillIntervals() {
        List<String> intervals = normalizeIntervals(backfillIntervals);
        return intervals.isEmpty() ? defaultBackfillIntervals() : intervals;
    }

    public List<String> normalizedHistoricalBackfillIntervals() {
        List<String> intervals = normalizeIntervals(historicalBackfillIntervals);
        return intervals.isEmpty() ? defaultHistoricalBackfillIntervals() : intervals;
    }

    public List<String> normalizedCacheIntervals() {
        Set<String> intervals = new LinkedHashSet<>();
        intervals.add(normalizedAggregationSourceInterval());
        intervals.addAll(normalizedAggregationIntervals());
        intervals.addAll(normalizedBackfillIntervals());
        intervals.addAll(normalizedHistoricalBackfillIntervals());
        intervals.add(MarketKlineService.INTERVAL_1H);
        return intervals.stream()
                .filter(MarketKlineService::isSupportedInterval)
                .toList();
    }

    private List<String> normalizeIntervals(List<String> intervals) {
        if (intervals == null || intervals.isEmpty()) {
            return List.of();
        }
        Set<String> normalized = new LinkedHashSet<>();
        for (String interval : intervals) {
            String value = normalizeInterval(interval, "");
            if (MarketKlineService.isSupportedInterval(value)) {
                normalized.add(value);
            }
        }
        return List.copyOf(normalized);
    }

    private String normalizeInterval(String interval, String defaultValue) {
        String value = StringUtils.hasText(interval) ? interval.trim() : defaultValue;
        return value.toLowerCase(Locale.ROOT);
    }

    private List<String> defaultBackfillIntervals() {
        return List.of(
                MarketKlineService.INTERVAL_1M,
                MarketKlineService.INTERVAL_5M,
                MarketKlineService.INTERVAL_15M,
                MarketKlineService.INTERVAL_1H,
                MarketKlineService.INTERVAL_4H,
                MarketKlineService.INTERVAL_1D
        );
    }

    private List<String> defaultHistoricalBackfillIntervals() {
        return List.of(
                MarketKlineService.INTERVAL_1M,
                MarketKlineService.INTERVAL_5M,
                MarketKlineService.INTERVAL_15M,
                MarketKlineService.INTERVAL_1H,
                MarketKlineService.INTERVAL_4H,
                MarketKlineService.INTERVAL_1D
        );
    }
}
