package com.oovso.strategy;

import com.oovso.market.MarketKline;
import com.oovso.market.MarketKlineMapper;
import com.oovso.market.MarketKlineService;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.Function;
import org.springframework.stereotype.Component;

/**
 * Builds the currently forming 4h candle from persisted closed 1m candles plus
 * the latest provisional 1m update. Provisional candles are never persisted.
 */
@Component
class FourHourIntrabarKlineAggregator {

    private static final long ONE_MINUTE_MILLIS = MarketKlineService.intervalMillis(
            MarketKlineService.INTERVAL_1M
    );

    private static final long FOUR_HOUR_MILLIS = MarketKlineService.intervalMillis(
            MarketKlineService.INTERVAL_4H
    );

    private static final long INCOMPLETE_HISTORY_RETRY_MILLIS = 60_000;

    private static final long INCOMPLETE_SOURCE_RETRY_MILLIS = 5_000;

    private final MarketKlineMapper marketKlineMapper;

    private final ConcurrentHashMap<SeriesKey, SourceState> sourceStates = new ConcurrentHashMap<>();

    private final ConcurrentHashMap<SeriesKey, HistoryState> historyStates = new ConcurrentHashMap<>();

    FourHourIntrabarKlineAggregator(MarketKlineMapper marketKlineMapper) {
        this.marketKlineMapper = marketKlineMapper;
    }

    Optional<Snapshot> aggregate(MarketKline liveOneMinute, int historySize) {
        if (!isUsableLiveOneMinute(liveOneMinute)) {
            return Optional.empty();
        }

        SeriesKey key = SeriesKey.from(liveOneMinute);
        long liveMinuteOpen = liveOneMinute.getOpenTimeMs();
        long bucketOpen = alignDown(liveMinuteOpen, FOUR_HOUR_MILLIS);
        SourceState existing = sourceStates.get(key);
        if (existing != null && (bucketOpen < existing.bucketOpen()
                || (bucketOpen == existing.bucketOpen()
                && liveMinuteOpen < existing.liveMinuteOpen()))) {
            return Optional.empty();
        }

        SourceState state = sourceStates.compute(key, (ignored, current) -> {
            if (current != null
                    && current.bucketOpen() == bucketOpen
                    && current.liveMinuteOpen() == liveMinuteOpen
                    && (current.complete()
                    || System.currentTimeMillis() - current.loadedAtMillis()
                    < INCOMPLETE_SOURCE_RETRY_MILLIS)) {
                return current;
            }
            return loadClosedMinutes(liveOneMinute, bucketOpen, liveMinuteOpen);
        });
        if (!state.complete()) {
            return Optional.empty();
        }

        List<MarketKline> sources = new ArrayList<>(state.closedMinutes().size() + 1);
        sources.addAll(state.closedMinutes());
        sources.add(liveOneMinute);
        MarketKline provisional = aggregateSources(sources, liveOneMinute, bucketOpen);

        int requiredClosedHistory = Math.max(0, historySize - 1);
        HistoryState history = historyStates.compute(key, (ignored, current) -> {
            if (current != null
                    && current.bucketOpen() == bucketOpen
                    && (current.complete()
                    || System.currentTimeMillis() - current.loadedAtMillis()
                    < INCOMPLETE_HISTORY_RETRY_MILLIS)) {
                return current;
            }
            List<MarketKline> closedKlines = requiredClosedHistory == 0
                    ? List.of()
                    : marketKlineMapper.selectClosedBefore(
                                    liveOneMinute.getExchange(),
                                    liveOneMinute.getMarketType(),
                                    liveOneMinute.getContractType(),
                                    liveOneMinute.getPair(),
                                    MarketKlineService.INTERVAL_4H,
                                    bucketOpen,
                                    requiredClosedHistory
                            ).stream()
                            .sorted(Comparator.comparing(MarketKline::getOpenTimeMs))
                            .toList();
            boolean complete = closedKlines.size() == requiredClosedHistory
                    && isContinuous(
                            closedKlines,
                            bucketOpen - requiredClosedHistory * FOUR_HOUR_MILLIS,
                            FOUR_HOUR_MILLIS
                    );
            return new HistoryState(
                    bucketOpen,
                    closedKlines,
                    complete,
                    System.currentTimeMillis()
            );
        });
        if (!history.complete()) {
            return Optional.empty();
        }

        List<MarketKline> klines = new ArrayList<>(historySize);
        klines.addAll(history.closedKlines());
        klines.add(provisional);
        return Optional.of(new Snapshot(provisional, List.copyOf(klines), liveOneMinute));
    }

    private SourceState loadClosedMinutes(
            MarketKline liveOneMinute,
            long bucketOpen,
            long liveMinuteOpen
    ) {
        List<MarketKline> closedMinutes = marketKlineMapper.selectClosedInRange(
                        liveOneMinute.getExchange(),
                        liveOneMinute.getMarketType(),
                        liveOneMinute.getContractType(),
                        liveOneMinute.getPair(),
                        MarketKlineService.INTERVAL_1M,
                        bucketOpen,
                        liveMinuteOpen
                ).stream()
                .sorted(Comparator.comparing(MarketKline::getOpenTimeMs))
                .toList();
        long expectedCount = (liveMinuteOpen - bucketOpen) / ONE_MINUTE_MILLIS;
        boolean complete = closedMinutes.size() == expectedCount
                && isContinuous(closedMinutes, bucketOpen);
        return new SourceState(
                bucketOpen,
                liveMinuteOpen,
                closedMinutes,
                complete,
                System.currentTimeMillis()
        );
    }

    private MarketKline aggregateSources(
            List<MarketKline> sources,
            MarketKline liveOneMinute,
            long bucketOpen
    ) {
        MarketKline first = sources.getFirst();
        MarketKline aggregate = new MarketKline();
        aggregate.setExchange(liveOneMinute.getExchange());
        aggregate.setMarketType(liveOneMinute.getMarketType());
        aggregate.setContractType(liveOneMinute.getContractType());
        aggregate.setPair(liveOneMinute.getPair());
        aggregate.setIntervalCode(MarketKlineService.INTERVAL_4H);
        aggregate.setOpenTimeMs(bucketOpen);
        aggregate.setCloseTimeMs(bucketOpen + FOUR_HOUR_MILLIS - 1);
        aggregate.setEventTimeMs(liveOneMinute.getEventTimeMs());
        aggregate.setOpenPrice(first.getOpenPrice());
        aggregate.setHighPrice(max(sources, MarketKline::getHighPrice));
        aggregate.setLowPrice(min(sources, MarketKline::getLowPrice));
        aggregate.setClosePrice(liveOneMinute.getClosePrice());
        aggregate.setVolume(sum(sources, MarketKline::getVolume));
        aggregate.setQuoteVolume(sum(sources, MarketKline::getQuoteVolume));
        aggregate.setTradeCount(sources.stream()
                .map(MarketKline::getTradeCount)
                .filter(java.util.Objects::nonNull)
                .mapToLong(Long::longValue)
                .sum());
        aggregate.setTakerBuyVolume(sum(sources, MarketKline::getTakerBuyVolume));
        aggregate.setTakerBuyQuoteVolume(sum(sources, MarketKline::getTakerBuyQuoteVolume));
        aggregate.setClosedState(0);
        aggregate.setSourceInterval(MarketKlineService.INTERVAL_1M);
        return aggregate;
    }

    private boolean isUsableLiveOneMinute(MarketKline kline) {
        return kline != null
                && MarketKlineService.INTERVAL_1M.equals(normalize(kline.getIntervalCode()))
                && (Integer.valueOf(0).equals(kline.getClosedState())
                    || Integer.valueOf(1).equals(kline.getClosedState()))
                && kline.getOpenTimeMs() != null
                && kline.getOpenPrice() != null
                && kline.getHighPrice() != null
                && kline.getLowPrice() != null
                && kline.getClosePrice() != null;
    }

    private boolean isContinuous(List<MarketKline> klines, long expectedOpenTime) {
        return isContinuous(klines, expectedOpenTime, ONE_MINUTE_MILLIS);
    }

    private boolean isContinuous(
            List<MarketKline> klines,
            long expectedOpenTime,
            long intervalMillis
    ) {
        for (MarketKline kline : klines) {
            if (kline.getOpenTimeMs() == null || kline.getOpenTimeMs() != expectedOpenTime) {
                return false;
            }
            expectedOpenTime += intervalMillis;
        }
        return true;
    }

    private long alignDown(long value, long intervalMillis) {
        return value - Math.floorMod(value, intervalMillis);
    }

    private BigDecimal max(List<MarketKline> klines, Function<MarketKline, BigDecimal> getter) {
        return klines.stream()
                .map(getter)
                .filter(java.util.Objects::nonNull)
                .max(BigDecimal::compareTo)
                .orElse(BigDecimal.ZERO);
    }

    private BigDecimal min(List<MarketKline> klines, Function<MarketKline, BigDecimal> getter) {
        return klines.stream()
                .map(getter)
                .filter(java.util.Objects::nonNull)
                .min(BigDecimal::compareTo)
                .orElse(BigDecimal.ZERO);
    }

    private BigDecimal sum(List<MarketKline> klines, Function<MarketKline, BigDecimal> getter) {
        return klines.stream()
                .map(getter)
                .filter(java.util.Objects::nonNull)
                .reduce(BigDecimal.ZERO, BigDecimal::add);
    }

    private String normalize(String value) {
        return value == null ? "" : value.trim().toLowerCase(Locale.ROOT);
    }

    private record SeriesKey(
            String exchange,
            String marketType,
            String contractType,
            String pair
    ) {

        private static SeriesKey from(MarketKline kline) {
            return new SeriesKey(
                    kline.getExchange(),
                    kline.getMarketType(),
                    kline.getContractType(),
                    kline.getPair()
            );
        }
    }

    private record SourceState(
            long bucketOpen,
            long liveMinuteOpen,
            List<MarketKline> closedMinutes,
            boolean complete,
            long loadedAtMillis
    ) {
    }

    private record HistoryState(
            long bucketOpen,
            List<MarketKline> closedKlines,
            boolean complete,
            long loadedAtMillis
    ) {
    }

    record Snapshot(
            MarketKline provisional,
            List<MarketKline> klines,
            MarketKline sourceOneMinute
    ) {
        Snapshot(MarketKline provisional, List<MarketKline> klines) {
            this(provisional, klines, null);
        }
    }
}
