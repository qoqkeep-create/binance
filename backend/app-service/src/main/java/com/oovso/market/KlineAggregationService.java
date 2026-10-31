package com.oovso.market;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.Optional;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.util.StringUtils;

@Service
public class KlineAggregationService {

    private static final Logger log = LoggerFactory.getLogger(KlineAggregationService.class);

    private final KlineStorageProperties properties;

    private final MarketKlineMapper marketKlineMapper;

    public KlineAggregationService(
            KlineStorageProperties properties,
            MarketKlineMapper marketKlineMapper
    ) {
        this.properties = properties;
        this.marketKlineMapper = marketKlineMapper;
    }

    public List<MarketKline> aggregateClosedSourceKline(MarketKline sourceKline) {
        if (!properties.isAggregationEnabled() || sourceKline == null) {
            return List.of();
        }

        String sourceInterval = properties.normalizedAggregationSourceInterval();
        if (!sourceInterval.equals(normalizeInterval(sourceKline.getIntervalCode()))) {
            return List.of();
        }

        long sourceIntervalMillis = MarketKlineService.intervalMillis(sourceInterval);
        long sourceCloseOpenTimeExclusive = sourceKline.getOpenTimeMs() + sourceIntervalMillis;
        List<MarketKline> aggregatedKlines = new ArrayList<>();
        for (String targetInterval : properties.normalizedAggregationIntervals()) {
            long targetIntervalMillis = MarketKlineService.intervalMillis(targetInterval);
            if (!canAggregate(sourceIntervalMillis, targetIntervalMillis)) {
                continue;
            }

            long targetOpenTime = alignDown(sourceKline.getOpenTimeMs(), targetIntervalMillis);
            long targetEndTimeExclusive = targetOpenTime + targetIntervalMillis;
            if (sourceCloseOpenTimeExclusive != targetEndTimeExclusive) {
                continue;
            }

            aggregateClosedBucket(
                    sourceKline.getExchange(),
                    sourceKline.getMarketType(),
                    sourceKline.getContractType(),
                    sourceKline.getPair(),
                    sourceInterval,
                    targetInterval,
                    targetOpenTime
            )
                    .ifPresent(aggregatedKlines::add);
        }
        return aggregatedKlines;
    }

    public Optional<MarketKline> aggregateClosedBucket(
            String exchange,
            String marketType,
            String contractType,
            String pair,
            String sourceInterval,
            String targetInterval,
            long targetOpenTime
    ) {
        long sourceIntervalMillis = MarketKlineService.intervalMillis(sourceInterval);
        long targetIntervalMillis = MarketKlineService.intervalMillis(targetInterval);
        long targetEndTimeExclusive = targetOpenTime + targetIntervalMillis;
        List<MarketKline> sourceKlines = marketKlineMapper.selectClosedInRange(
                exchange,
                marketType,
                contractType,
                pair,
                sourceInterval,
                targetOpenTime,
                targetEndTimeExclusive
        ).stream()
                .sorted(Comparator.comparing(MarketKline::getOpenTimeMs))
                .toList();

        long expectedCount = (targetEndTimeExclusive - targetOpenTime) / sourceIntervalMillis;
        if (sourceKlines.size() != expectedCount || !isContinuous(sourceKlines, targetOpenTime, sourceIntervalMillis)) {
            log.debug(
                    "Skip {} aggregation for {} because source {} klines are incomplete, expected={}, actual={}, bucketOpen={}",
                    targetInterval,
                    pair,
                    sourceInterval,
                    expectedCount,
                    sourceKlines.size(),
                    targetOpenTime
            );
            return Optional.empty();
        }

        return Optional.of(aggregate(
                sourceKlines,
                sourceInterval,
                targetInterval,
                targetOpenTime,
                sourceKlines.getLast().getCloseTimeMs(),
                1
        ));
    }

    public Optional<MarketKline> aggregatePartialBucket(
            String exchange,
            String marketType,
            String contractType,
            String pair,
            String targetInterval,
            long targetOpenTime
    ) {
        String sourceInterval = properties.normalizedAggregationSourceInterval();
        long sourceIntervalMillis = MarketKlineService.intervalMillis(sourceInterval);
        long targetIntervalMillis = MarketKlineService.intervalMillis(targetInterval);
        if (!canAggregate(sourceIntervalMillis, targetIntervalMillis)) {
            return Optional.empty();
        }

        long targetEndTimeExclusive = targetOpenTime + targetIntervalMillis;
        List<MarketKline> sourceKlines = marketKlineMapper.selectClosedInRange(
                exchange,
                marketType,
                contractType,
                pair,
                sourceInterval,
                targetOpenTime,
                targetEndTimeExclusive
        ).stream()
                .sorted(Comparator.comparing(MarketKline::getOpenTimeMs))
                .toList();
        if (sourceKlines.isEmpty()
                || !isContinuous(
                        sourceKlines,
                        targetOpenTime,
                        sourceIntervalMillis
                )) {
            return Optional.empty();
        }

        return Optional.of(aggregate(
                sourceKlines,
                sourceInterval,
                targetInterval,
                targetOpenTime,
                targetEndTimeExclusive - 1,
                0
        ));
    }

    private MarketKline aggregate(
            List<MarketKline> sourceKlines,
            String sourceInterval,
            String targetInterval,
            long targetOpenTime,
            long closeTime,
            int closedState
    ) {
        MarketKline first = sourceKlines.getFirst();
        MarketKline last = sourceKlines.getLast();
        MarketKline aggregated = new MarketKline();
        aggregated.setExchange(first.getExchange());
        aggregated.setMarketType(first.getMarketType());
        aggregated.setContractType(first.getContractType());
        aggregated.setPair(first.getPair());
        aggregated.setIntervalCode(targetInterval);
        aggregated.setOpenTimeMs(targetOpenTime);
        aggregated.setCloseTimeMs(closeTime);
        aggregated.setEventTimeMs(last.getEventTimeMs());
        aggregated.setOpenPrice(first.getOpenPrice());
        aggregated.setHighPrice(max(sourceKlines, MarketKline::getHighPrice));
        aggregated.setLowPrice(min(sourceKlines, MarketKline::getLowPrice));
        aggregated.setClosePrice(last.getClosePrice());
        aggregated.setVolume(sum(sourceKlines, MarketKline::getVolume));
        aggregated.setQuoteVolume(sum(sourceKlines, MarketKline::getQuoteVolume));
        aggregated.setTradeCount(sumTradeCount(sourceKlines));
        aggregated.setTakerBuyVolume(sum(sourceKlines, MarketKline::getTakerBuyVolume));
        aggregated.setTakerBuyQuoteVolume(sum(sourceKlines, MarketKline::getTakerBuyQuoteVolume));
        aggregated.setClosedState(closedState);
        aggregated.setSourceInterval(sourceInterval);
        return aggregated;
    }

    private boolean canAggregate(long sourceIntervalMillis, long targetIntervalMillis) {
        return targetIntervalMillis > sourceIntervalMillis && targetIntervalMillis % sourceIntervalMillis == 0;
    }

    private boolean isContinuous(List<MarketKline> klines, long expectedOpenTime, long intervalMillis) {
        for (MarketKline kline : klines) {
            if (kline.getOpenTimeMs() != expectedOpenTime) {
                return false;
            }
            expectedOpenTime += intervalMillis;
        }
        return true;
    }

    private long alignDown(long value, long intervalMillis) {
        return value - (value % intervalMillis);
    }

    private BigDecimal max(List<MarketKline> klines, java.util.function.Function<MarketKline, BigDecimal> getter) {
        return klines.stream()
                .map(getter)
                .filter(java.util.Objects::nonNull)
                .max(BigDecimal::compareTo)
                .orElse(BigDecimal.ZERO);
    }

    private BigDecimal min(List<MarketKline> klines, java.util.function.Function<MarketKline, BigDecimal> getter) {
        return klines.stream()
                .map(getter)
                .filter(java.util.Objects::nonNull)
                .min(BigDecimal::compareTo)
                .orElse(BigDecimal.ZERO);
    }

    private BigDecimal sum(List<MarketKline> klines, java.util.function.Function<MarketKline, BigDecimal> getter) {
        return klines.stream()
                .map(getter)
                .filter(java.util.Objects::nonNull)
                .reduce(BigDecimal.ZERO, BigDecimal::add);
    }

    private long sumTradeCount(List<MarketKline> klines) {
        return klines.stream()
                .map(MarketKline::getTradeCount)
                .filter(java.util.Objects::nonNull)
                .mapToLong(Long::longValue)
                .sum();
    }

    private String normalizeInterval(String intervalCode) {
        return StringUtils.hasText(intervalCode) ? intervalCode.trim().toLowerCase(Locale.ROOT) : "";
    }
}
