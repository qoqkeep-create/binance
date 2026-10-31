package com.oovso.market;

import com.oovso.binance.BinanceUsdmMarketDataClient;
import com.oovso.binance.BinanceUsdmSymbol;
import com.oovso.binance.BinanceNetworkExceptionSupport;
import java.time.Duration;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.SmartLifecycle;
import org.springframework.stereotype.Component;

@Component
public class KlineContinuityGuard implements SmartLifecycle {

    private static final Logger log = LoggerFactory.getLogger(KlineContinuityGuard.class);

    private final KlineStorageProperties properties;

    private final MarketKlineMapper marketKlineMapper;

    private final MarketKlineService marketKlineService;

    private final BinanceUsdmMarketDataClient marketDataClient;

    private final AtomicBoolean running = new AtomicBoolean(false);

    private final AtomicBoolean checking = new AtomicBoolean(false);

    private final AtomicBoolean startupRunPending = new AtomicBoolean(true);

    private ScheduledExecutorService executor;

    public KlineContinuityGuard(
            KlineStorageProperties properties,
            MarketKlineMapper marketKlineMapper,
            MarketKlineService marketKlineService,
            BinanceUsdmMarketDataClient marketDataClient
    ) {
        this.properties = properties;
        this.marketKlineMapper = marketKlineMapper;
        this.marketKlineService = marketKlineService;
        this.marketDataClient = marketDataClient;
    }

    @Override
    public void start() {
        if (!isAutoStartup() || !running.compareAndSet(false, true)) {
            return;
        }

        startupRunPending.set(properties.isStartupBackfillEnabled());
        executor = Executors.newSingleThreadScheduledExecutor(task -> {
            Thread thread = new Thread(task, "market-kline-continuity-guard");
            thread.setDaemon(true);
            thread.setPriority(Thread.MIN_PRIORITY);
            return thread;
        });

        long intervalMillis = Math.max(30_000, properties.getContinuityGuardIntervalMillis());
        long initialDelayMillis = properties.isStartupBackfillEnabled() ? 0 : intervalMillis;
        executor.scheduleWithFixedDelay(
                this::runGuardSafely,
                initialDelayMillis,
                intervalMillis,
                TimeUnit.MILLISECONDS
        );
        log.info(
                "Started K line continuity guard, interval={} ms, startupBackfill={}, startupHistoricalBackfill={}",
                intervalMillis,
                properties.isStartupBackfillEnabled(),
                properties.isStartupHistoricalBackfillEnabled()
        );
    }

    @Override
    public void stop() {
        if (!running.getAndSet(false)) {
            return;
        }
        if (executor != null) {
            executor.shutdownNow();
            executor = null;
        }
    }

    @Override
    public void stop(Runnable callback) {
        try {
            stop();
        } finally {
            callback.run();
        }
    }

    @Override
    public boolean isRunning() {
        return running.get();
    }

    @Override
    public boolean isAutoStartup() {
        return properties.isEnabled()
                && properties.isBackfillEnabled()
                && properties.isContinuityGuardEnabled();
    }

    private void runGuardSafely() {
        if (!running.get() || !checking.compareAndSet(false, true)) {
            return;
        }

        boolean startupRun = startupRunPending.getAndSet(false);
        try {
            runGuard(startupRun);
        } catch (InterruptedException ex) {
            Thread.currentThread().interrupt();
        } catch (Exception ex) {
            if (BinanceNetworkExceptionSupport.isTlsCertificateValidationFailure(ex)) {
                log.warn(
                        "Binance REST TLS certificate validation failed during K line continuity check; "
                                + "skipping this run and retrying later: {}",
                        BinanceNetworkExceptionSupport.conciseMessage(ex)
                );
            } else if (BinanceNetworkExceptionSupport.isTransientRestNetworkFailure(ex)) {
                log.warn(
                        "Transient Binance REST network failure during K line continuity check; "
                                + "skipping this run and retrying later: {}",
                        BinanceNetworkExceptionSupport.conciseMessage(ex)
                );
            } else {
                log.warn("K line continuity guard failed; it will retry on the next run", ex);
            }
        } finally {
            checking.set(false);
        }
    }

    private void runGuard(boolean startupRun) throws Exception {
        List<BinanceUsdmSymbol> symbols = marketDataClient.loadTargetSymbols();
        if (symbols.isEmpty()) {
            log.warn("K line continuity guard found no active Binance USD-M symbols");
            return;
        }

        int totalBackfilled = 0;
        if (startupRun && properties.isStartupHistoricalBackfillEnabled()) {
            totalBackfilled = backfillHistoricalKlines(symbols);
        } else {
            for (BinanceUsdmSymbol symbol : symbols) {
                int symbolBackfilled = backfillMissingKlines(symbol);
                totalBackfilled += symbolBackfilled;
            }
        }

        if (startupRun && properties.isStartupRedisWarmupEnabled()) {
            for (BinanceUsdmSymbol symbol : symbols) {
                marketKlineService.warmRedisCache(symbol.contractType(), symbol.pair());
            }
        }

        if (startupRun || totalBackfilled > 0) {
            log.info(
                    "K line continuity guard finished: startupRun={}, symbols={}, backfilledKlines={}",
                    startupRun,
                    symbols.size(),
                    totalBackfilled
            );
        }
    }

    private int backfillHistoricalKlines(List<BinanceUsdmSymbol> symbols) throws Exception {
        long sourceIntervalMillis = MarketKlineService.intervalMillis(properties.normalizedAggregationSourceInterval());
        long latestEndOpenTimeExclusive = lastClosedOpenTime(sourceIntervalMillis) + sourceIntervalMillis;
        long historicalStartTime = historicalBackfillStartTime();
        if (latestEndOpenTimeExclusive <= historicalStartTime) {
            return 0;
        }

        long windowMillis = Duration.ofDays(Math.max(1, properties.getHistoricalBackfillWindowDays())).toMillis();
        List<String> intervals = properties.normalizedHistoricalBackfillIntervals();
        int totalBackfilled = 0;
        long windowEnd = latestEndOpenTimeExclusive;
        int windowIndex = 0;
        while (windowEnd > historicalStartTime && running.get()) {
            long windowStart = Math.max(historicalStartTime, windowEnd - windowMillis);
            TimeRange window = new TimeRange(windowStart, windowEnd);
            int windowBackfilled = 0;
            for (BinanceUsdmSymbol symbol : symbols) {
                if (!running.get()) {
                    break;
                }
                windowBackfilled += backfillMissingKlines(symbol, intervals, Optional.of(window));
            }
            totalBackfilled += windowBackfilled;
            windowIndex++;
            log.info(
                    "Historical K line backfill window completed: index={}, start={}, end={}, symbols={}, backfilledKlines={}",
                    windowIndex,
                    Instant.ofEpochMilli(windowStart),
                    Instant.ofEpochMilli(windowEnd),
                    symbols.size(),
                    windowBackfilled
            );
            windowEnd = windowStart;
        }
        return totalBackfilled;
    }

    private int backfillMissingKlines(BinanceUsdmSymbol symbol) throws Exception {
        return backfillMissingKlines(symbol, properties.normalizedBackfillIntervals(), Optional.empty());
    }

    private int backfillMissingKlines(
            BinanceUsdmSymbol symbol,
            List<String> intervals,
            Optional<TimeRange> requestedRange
    ) throws Exception {
        int backfilled = 0;
        for (String intervalCode : intervals) {
            backfilled += backfillMissingIntervalFromRest(symbol, intervalCode, requestedRange);
        }
        return backfilled;
    }

    private int backfillMissingIntervalFromRest(
            BinanceUsdmSymbol symbol,
            String intervalCode,
            Optional<TimeRange> requestedRange
    ) throws Exception {
        Optional<TimeRange> range = inspectionRange(symbol, intervalCode, requestedRange);
        if (range.isEmpty()) {
            return 0;
        }
        return backfillMissingIntervalRangeFromRest(symbol, intervalCode, range.get());
    }

    private Optional<TimeRange> inspectionRange(
            BinanceUsdmSymbol symbol,
            String intervalCode,
            Optional<TimeRange> requestedRange
    ) {
        long intervalMillis = MarketKlineService.intervalMillis(intervalCode);
        long lastClosedOpenTime = lastClosedOpenTime(intervalMillis);
        if (lastClosedOpenTime < 0) {
            return Optional.empty();
        }

        TimeRange baseRange = requestedRange.orElseGet(() -> recentInspectionRange(intervalCode, intervalMillis, lastClosedOpenTime));
        long onboardOpenTime = symbol.onboardDate() > 0 ? alignUp(symbol.onboardDate(), intervalMillis) : baseRange.startOpenTime();
        long startOpenTime = alignUp(Math.max(baseRange.startOpenTime(), onboardOpenTime), intervalMillis);
        long endOpenTimeExclusive = Math.min(alignUp(baseRange.endOpenTimeExclusive(), intervalMillis), lastClosedOpenTime + intervalMillis);

        if (startOpenTime >= endOpenTimeExclusive) {
            return Optional.empty();
        }
        return Optional.of(new TimeRange(startOpenTime, endOpenTimeExclusive));
    }

    private TimeRange recentInspectionRange(String intervalCode, long intervalMillis, long lastClosedOpenTime) {
        int targetSize = Math.max(1, properties.cacheSize(intervalCode));
        long targetStartOpenTime = lastClosedOpenTime - ((long) targetSize - 1L) * intervalMillis;
        long endOpenTimeExclusive = lastClosedOpenTime + intervalMillis;
        return new TimeRange(targetStartOpenTime, endOpenTimeExclusive);
    }

    private int backfillMissingIntervalRangeFromRest(
            BinanceUsdmSymbol symbol,
            String intervalCode,
            TimeRange range
    ) throws Exception {
        long intervalMillis = MarketKlineService.intervalMillis(intervalCode);
        List<Long> existingOpenTimes = marketKlineMapper.selectClosedOpenTimesInRange(
                properties.getExchange(),
                properties.getMarketType(),
                symbol.contractType(),
                symbol.pair(),
                intervalCode,
                range.startOpenTime(),
                range.endOpenTimeExclusive()
        );
        List<TimeRange> missingRanges = missingRanges(
                range.startOpenTime(),
                range.endOpenTimeExclusive(),
                intervalMillis,
                new HashSet<>(existingOpenTimes)
        );
        if (missingRanges.isEmpty()) {
            return 0;
        }

        int backfilled = 0;
        for (TimeRange missingRange : missingRanges) {
            backfilled += backfillRangeFromRest(symbol, intervalCode, intervalMillis, missingRange);
        }
        if (backfilled > 0) {
            log.info(
                    "Backfilled {} missing {} klines for {} {} directly from Binance REST",
                    backfilled,
                    intervalCode,
                    symbol.pair(),
                    symbol.contractType()
            );
        }
        return backfilled;
    }

    private int backfillRangeFromRest(
            BinanceUsdmSymbol symbol,
            String intervalCode,
            long intervalMillis,
            TimeRange range
    ) throws Exception {
        int limit = Math.max(1, Math.min(1_500, properties.getBackfillRequestLimit()));
        long maxChunkMillis = intervalMillis * limit;
        long chunkStart = range.startOpenTime();
        int saved = 0;

        while (chunkStart < range.endOpenTimeExclusive() && running.get()) {
            long chunkEnd = Math.min(range.endOpenTimeExclusive(), chunkStart + maxChunkMillis);
            List<MarketKline> klines = marketDataClient.loadContinuousKlines(
                    symbol,
                    intervalCode,
                    chunkStart,
                    chunkEnd,
                    limit
            );
            for (MarketKline kline : klines) {
                marketKlineService.saveBackfilledClosedKline(kline);
                saved++;
            }
            sleepAfterBackfillRequest();
            chunkStart = chunkEnd;
        }
        return saved;
    }

    private List<TimeRange> missingRanges(
            long startOpenTime,
            long endOpenTimeExclusive,
            long intervalMillis,
            Set<Long> existingOpenTimes
    ) {
        List<TimeRange> ranges = new ArrayList<>();
        Long rangeStart = null;
        long rangeEnd = startOpenTime;

        for (long openTime = startOpenTime; openTime < endOpenTimeExclusive; openTime += intervalMillis) {
            if (existingOpenTimes.contains(openTime)) {
                if (rangeStart != null) {
                    ranges.add(new TimeRange(rangeStart, rangeEnd));
                    rangeStart = null;
                }
                rangeEnd = openTime + intervalMillis;
                continue;
            }

            if (rangeStart == null) {
                rangeStart = openTime;
            }
            rangeEnd = openTime + intervalMillis;
        }

        if (rangeStart != null) {
            ranges.add(new TimeRange(rangeStart, rangeEnd));
        }
        return ranges;
    }

    private long lastClosedOpenTime(long intervalMillis) {
        long safeNow = System.currentTimeMillis() - Math.max(0, properties.getClosedKlineSafetyDelayMillis());
        return alignDown(safeNow, intervalMillis) - intervalMillis;
    }

    private long historicalBackfillStartTime() {
        LocalDate startDate = properties.getHistoricalBackfillStartDate();
        if (startDate == null) {
            startDate = LocalDate.of(2018, 1, 1);
        }
        return startDate.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli();
    }

    private long alignDown(long value, long intervalMillis) {
        return value - (value % intervalMillis);
    }

    private long alignUp(long value, long intervalMillis) {
        long aligned = alignDown(value, intervalMillis);
        return aligned == value ? value : aligned + intervalMillis;
    }

    private void sleepAfterBackfillRequest() throws InterruptedException {
        long delayMillis = properties.getBackfillRequestDelayMillis();
        if (delayMillis > 0) {
            Thread.sleep(delayMillis);
        }
    }

    private record TimeRange(long startOpenTime, long endOpenTimeExclusive) {
    }
}
