package com.oovso.strategy;

import com.oovso.binance.BinanceNetworkExceptionSupport;
import com.oovso.binance.BinanceUsdmMarketDataClient;
import com.oovso.binance.BinanceUsdmMarketDataClient.BookTicker;
import com.oovso.binance.BinanceUsdmMarketDataClient.OpenInterestStats;
import com.oovso.binance.BinanceUsdmMarketDataClient.PremiumIndex;
import com.oovso.binance.BinanceUsdmMarketDataClient.Ticker24h;
import com.oovso.binance.BinanceUsdmSymbol;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.Duration;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.SmartLifecycle;
import org.springframework.stereotype.Component;

@Component
public class StrategySymbolEligibilityService implements SmartLifecycle {

    private static final Logger log = LoggerFactory.getLogger(StrategySymbolEligibilityService.class);

    private final SuperEmaPullbackStrategyProperties strategyProperties;

    private final BinanceUsdmMarketDataClient marketDataClient;

    private final StrategySymbolWhitelist symbolWhitelist;

    private final AtomicBoolean running = new AtomicBoolean(false);

    private final AtomicBoolean refreshing = new AtomicBoolean(false);

    private final AtomicReference<EligibilitySnapshot> snapshot =
            new AtomicReference<>(new EligibilitySnapshot(Set.of(), 0));

    private ScheduledExecutorService executor;

    public StrategySymbolEligibilityService(
            SuperEmaPullbackStrategyProperties strategyProperties,
            BinanceUsdmMarketDataClient marketDataClient,
            StrategySymbolWhitelist symbolWhitelist
    ) {
        this.strategyProperties = strategyProperties;
        this.marketDataClient = marketDataClient;
        this.symbolWhitelist = symbolWhitelist;
    }

    public boolean isEligible(String pair) {
        SuperEmaPullbackStrategyProperties.SymbolFilter properties = filterProperties();
        if (!properties.isEnabled()) {
            return false;
        }

        EligibilitySnapshot current = snapshot.get();
        long maxAgeMillis = Math.max(60_000, properties.getMaxSnapshotAgeMillis());
        if (current.updatedAtMs() <= 0 || System.currentTimeMillis() - current.updatedAtMs() > maxAgeMillis) {
            return false;
        }
        return current.eligiblePairs().contains(normalizePair(pair));
    }

    @Override
    public void start() {
        if (!isAutoStartup() || !running.compareAndSet(false, true)) {
            return;
        }

        executor = Executors.newSingleThreadScheduledExecutor(task -> {
            Thread thread = new Thread(task, "strategy-symbol-filter");
            thread.setDaemon(true);
            return thread;
        });

        SuperEmaPullbackStrategyProperties.SymbolFilter properties = filterProperties();
        long initialDelayMillis = Math.max(5_000, properties.getInitialDelayMillis());
        long refreshIntervalMillis = Math.max(300_000, properties.getRefreshIntervalMillis());
        executor.scheduleWithFixedDelay(
                this::refreshSafely,
                initialDelayMillis,
                refreshIntervalMillis,
                TimeUnit.MILLISECONDS
        );
        log.info(
                "Started strategy symbol filter, initialDelay={} ms, refreshInterval={} ms",
                initialDelayMillis,
                refreshIntervalMillis
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
        return strategyProperties.isEnabled() && filterProperties().isEnabled();
    }

    private void refreshSafely() {
        if (!running.get() || !refreshing.compareAndSet(false, true)) {
            return;
        }
        try {
            refresh();
        } catch (InterruptedException ex) {
            Thread.currentThread().interrupt();
        } catch (Exception ex) {
            if (BinanceNetworkExceptionSupport.isTlsCertificateValidationFailure(ex)) {
                log.warn(
                        "Binance REST TLS certificate validation failed during strategy symbol filter refresh; "
                                + "keeping the previous snapshot and retrying later: {}",
                        BinanceNetworkExceptionSupport.conciseMessage(ex)
                );
            } else {
                log.warn("Strategy symbol filter refresh failed; keeping the previous snapshot", ex);
            }
        } finally {
            refreshing.set(false);
        }
    }

    private void refresh() throws Exception {
        List<BinanceUsdmSymbol> symbols = marketDataClient.loadTargetSymbols();
        Map<String, Ticker24h> tickers = marketDataClient.load24hTickers();
        Map<String, BookTicker> bookTickers = marketDataClient.loadBookTickers();
        Map<String, PremiumIndex> premiumIndexes = marketDataClient.loadPremiumIndexes();
        SuperEmaPullbackStrategyProperties.SymbolFilter properties = filterProperties();
        long now = System.currentTimeMillis();
        Set<String> eligiblePairs = new HashSet<>();
        Map<String, Integer> rejectionCounts = new LinkedHashMap<>();
        Set<String> baseEligiblePairs = new HashSet<>();

        for (BinanceUsdmSymbol symbol : symbols) {
            String pair = normalizePair(symbol.pair());
            if (symbolWhitelist.contains(pair)) {
                continue;
            }
            String reason = baseRejectionReason(
                    symbol,
                    tickers.get(pair),
                    bookTickers.get(pair),
                    premiumIndexes.get(pair),
                    properties,
                    now
            );
            if (reason == null) {
                baseEligiblePairs.add(pair);
            } else {
                rejectionCounts.merge(reason, 1, Integer::sum);
            }
        }

        for (String pair : baseEligiblePairs.stream().sorted().toList()) {
            if (properties.getOpenInterestRequestDelayMillis() > 0) {
                Thread.sleep(properties.getOpenInterestRequestDelayMillis());
            }
            try {
                OpenInterestStats openInterest = marketDataClient.loadOpenInterestStats(pair);
                String reason = openInterestRejectionReason(openInterest, properties);
                if (reason == null) {
                    eligiblePairs.add(pair);
                } else {
                    rejectionCounts.merge(reason, 1, Integer::sum);
                }
            } catch (InterruptedException ex) {
                throw ex;
            } catch (Exception ex) {
                if (BinanceNetworkExceptionSupport.isTlsCertificateValidationFailure(ex)) {
                    throw ex;
                }
                rejectionCounts.merge("OPEN_INTEREST_UNAVAILABLE", 1, Integer::sum);
                log.debug("Failed to load open interest metrics for {}", pair, ex);
            }
        }

        EligibilitySnapshot updated = new EligibilitySnapshot(Set.copyOf(eligiblePairs), now);
        snapshot.set(updated);
        log.info(
                "Refreshed strategy symbol filter: targetSymbols={}, baseCandidates={}, eligible={}, "
                        + "eligiblePairs={}, rejectedByReason={}",
                symbols.size(),
                baseEligiblePairs.size(),
                eligiblePairs.size(),
                eligiblePairs.stream().sorted().toList(),
                rejectionCounts
        );
    }

    static String baseRejectionReason(
            BinanceUsdmSymbol symbol,
            Ticker24h ticker,
            BookTicker bookTicker,
            PremiumIndex premiumIndex,
            SuperEmaPullbackStrategyProperties.SymbolFilter properties,
            long nowMs
    ) {
        if (symbol == null || ticker == null || bookTicker == null || premiumIndex == null) {
            return "MARKET_DATA_UNAVAILABLE";
        }

        long minListingMillis = Duration.ofDays(Math.max(0, properties.getMinListingDays())).toMillis();
        if (symbol.onboardDate() <= 0 || nowMs - symbol.onboardDate() < minListingMillis) {
            return "LISTING_TOO_NEW";
        }
        if (ticker.quoteVolume().compareTo(nonNull(properties.getMinQuoteVolume24h())) < 0) {
            return "QUOTE_VOLUME_24H_TOO_LOW";
        }
        if (ticker.priceChangeRate().abs()
                .compareTo(BigDecimal.valueOf(properties.getMaxAbsPriceChangeRate24h())) > 0) {
            return "PRICE_CHANGE_24H_TOO_LARGE";
        }
        if (bookTicker.bidPrice().signum() <= 0
                || bookTicker.askPrice().signum() <= 0
                || bookTicker.askPrice().compareTo(bookTicker.bidPrice()) < 0) {
            return "INVALID_BOOK_TICKER";
        }

        BigDecimal midpoint = bookTicker.askPrice()
                .add(bookTicker.bidPrice())
                .divide(BigDecimal.valueOf(2), 16, RoundingMode.HALF_UP);
        BigDecimal spreadRate = bookTicker.askPrice()
                .subtract(bookTicker.bidPrice())
                .divide(midpoint, 16, RoundingMode.HALF_UP);
        if (spreadRate.compareTo(BigDecimal.valueOf(properties.getMaxSpreadRate())) > 0) {
            return "SPREAD_TOO_WIDE";
        }
        if (premiumIndex.fundingRate().abs()
                .compareTo(BigDecimal.valueOf(properties.getMaxAbsFundingRate())) > 0) {
            return "FUNDING_RATE_TOO_EXTREME";
        }
        return null;
    }

    static String openInterestRejectionReason(
            OpenInterestStats openInterest,
            SuperEmaPullbackStrategyProperties.SymbolFilter properties
    ) {
        if (openInterest == null) {
            return "OPEN_INTEREST_UNAVAILABLE";
        }
        if (openInterest.openInterestValue().compareTo(nonNull(properties.getMinOpenInterestValue())) < 0) {
            return "OPEN_INTEREST_TOO_LOW";
        }
        if (openInterest.changeRate24h().abs()
                .compareTo(BigDecimal.valueOf(properties.getMaxAbsOpenInterestChangeRate24h())) > 0) {
            return "OPEN_INTEREST_CHANGE_24H_TOO_LARGE";
        }
        return null;
    }

    private SuperEmaPullbackStrategyProperties.SymbolFilter filterProperties() {
        return strategyProperties.getSymbolFilter();
    }

    private static BigDecimal nonNull(BigDecimal value) {
        return value == null ? BigDecimal.ZERO : value;
    }

    private static String normalizePair(String pair) {
        return pair == null ? "" : pair.trim().toUpperCase(Locale.ROOT);
    }

    private record EligibilitySnapshot(Set<String> eligiblePairs, long updatedAtMs) {
    }
}
