package com.oovso.strategy;

import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.oovso.indicator.MarketIndicator;
import com.oovso.indicator.MarketIndicatorMapper;
import com.oovso.indicator.Ta4jKlineSeriesFactory;
import com.oovso.market.MarketClosedKlineEvent;
import com.oovso.market.MarketKline;
import com.oovso.market.MarketKlineMapper;
import com.oovso.market.MarketKlineService;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.LocalDateTime;
import java.util.Comparator;
import java.util.List;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.event.EventListener;
import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.ta4j.core.BarSeries;
import org.ta4j.core.indicators.ATRIndicator;
import org.ta4j.core.indicators.MACDIndicator;
import org.ta4j.core.indicators.adx.ADXIndicator;
import org.ta4j.core.indicators.averages.EMAIndicator;
import org.ta4j.core.indicators.helpers.ClosePriceIndicator;
import org.ta4j.core.indicators.supertrend.SuperTrendIndicator;

@Component
public class SuperEmaPullbackStrategy {

    private static final Logger log = LoggerFactory.getLogger(SuperEmaPullbackStrategy.class);

    private static final String STRATEGY_FAMILY_CODE = "SUPER_PULLBACK_REVERSAL";

    private static final String EMA21_INDICATOR_CODE = "EMA21";

    private static final String EMA55_INDICATOR_CODE = "EMA55";

    private static final String EMA144_INDICATOR_CODE = "EMA144";

    private static final String MACD_INDICATOR_CODE = "MACD";

    private static final String SUPER_TREND_INDICATOR_CODE = "SUPER_TREND";

    private final SuperEmaPullbackStrategyProperties properties;

    private final MarketKlineMapper marketKlineMapper;

    private final MarketIndicatorMapper marketIndicatorMapper;

    private final StrategySignalMapper strategySignalMapper;

    private final Ta4jKlineSeriesFactory ta4jKlineSeriesFactory;

    private final CandlestickPatternDetector candlestickPatternDetector;

    private final StrategySymbolEligibilityService symbolEligibilityService;

    private final StrategySymbolWhitelist symbolWhitelist;

    private final DynamicSymbolKlineFilter dynamicSymbolKlineFilter;

    private final List<StrategySignalHandler> signalHandlers;

    private final FourHourEmaPullbackStateService fourHourStateService;

    public SuperEmaPullbackStrategy(
            SuperEmaPullbackStrategyProperties properties,
            MarketKlineMapper marketKlineMapper,
            MarketIndicatorMapper marketIndicatorMapper,
            StrategySignalMapper strategySignalMapper,
            Ta4jKlineSeriesFactory ta4jKlineSeriesFactory,
            CandlestickPatternDetector candlestickPatternDetector,
            StrategySymbolEligibilityService symbolEligibilityService,
            StrategySymbolWhitelist symbolWhitelist,
            DynamicSymbolKlineFilter dynamicSymbolKlineFilter,
            List<StrategySignalHandler> signalHandlers,
            FourHourEmaPullbackStateService fourHourStateService
    ) {
        this.properties = properties;
        this.marketKlineMapper = marketKlineMapper;
        this.marketIndicatorMapper = marketIndicatorMapper;
        this.strategySignalMapper = strategySignalMapper;
        this.ta4jKlineSeriesFactory = ta4jKlineSeriesFactory;
        this.candlestickPatternDetector = candlestickPatternDetector;
        this.symbolEligibilityService = symbolEligibilityService;
        this.symbolWhitelist = symbolWhitelist;
        this.dynamicSymbolKlineFilter = dynamicSymbolKlineFilter;
        this.signalHandlers = signalHandlers;
        this.fourHourStateService = fourHourStateService;
    }

    @Async("marketKlineEventExecutor")
    @EventListener
    public void onMarketClosedKline(MarketClosedKlineEvent event) {
        MarketKline kline = event.kline();
        if (!properties.isEnabled() || !isStrategyInterval(kline.getIntervalCode())) {
            return;
        }

        boolean whitelisted = symbolWhitelist.contains(kline.getPair());
        if (!whitelisted && !symbolEligibilityService.isEligible(kline.getPair())) {
            return;
        }

        try {
            analyze(kline, whitelisted);
        } catch (Exception ex) {
            log.error(
                    "Failed to analyze {} for {} {} {}",
                    STRATEGY_FAMILY_CODE,
                    kline.getPair(),
                    kline.getContractType(),
                    kline.getIntervalCode(),
                    ex
            );
        }
    }

    void onFourHourIntrabar(FourHourIntrabarKlineAggregator.Snapshot snapshot) {
        if (!properties.isEnabled()
                || !properties.getFourHour().isEnabled()
                || !properties.getFourHour().isIntrabarAlertEnabled()) {
            return;
        }

        MarketKline provisional = snapshot.provisional();
        boolean whitelisted = symbolWhitelist.contains(provisional.getPair());
        if (!whitelisted && !symbolEligibilityService.isEligible(provisional.getPair())) {
            return;
        }

        try {
            analyzeKlines(provisional, snapshot.klines(), whitelisted, false, snapshot.sourceOneMinute());
        } catch (Exception ex) {
            log.error(
                    "Failed to analyze intrabar {} for {} {} 4h",
                    STRATEGY_FAMILY_CODE,
                    provisional.getPair(),
                    provisional.getContractType(),
                    ex
            );
        }
    }

    private boolean isStrategyInterval(String intervalCode) {
        if (MarketKlineService.INTERVAL_15M.equals(intervalCode)) {
            return properties.getFifteenMinute().isEnabled();
        }
        if (MarketKlineService.INTERVAL_1H.equals(intervalCode)
                && properties.getInterval().equals(intervalCode)) {
            return true;
        }
        return properties.getFourHour().isEnabled()
                && MarketKlineService.INTERVAL_4H.equals(intervalCode);
    }

    private void analyze(MarketKline triggerKline, boolean whitelisted) {
        int historySize = requiredHistorySize(triggerKline.getIntervalCode());
        List<MarketKline> klines = marketKlineMapper.selectLatestClosed(
                        triggerKline.getExchange(),
                        triggerKline.getMarketType(),
                        triggerKline.getContractType(),
                        triggerKline.getPair(),
                        triggerKline.getIntervalCode(),
                        historySize
                ).stream()
                .sorted(Comparator.comparing(MarketKline::getOpenTimeMs))
                .toList();

        if (klines.size() < historySize) {
            log.debug(
                    "Skip {} for {} because only {}/{} closed {} klines are ready",
                    STRATEGY_FAMILY_CODE,
                    triggerKline.getPair(),
                    klines.size(),
                    historySize,
                    triggerKline.getIntervalCode()
            );
            return;
        }

        analyzeKlines(triggerKline, klines, whitelisted, true, null);
    }

    private void analyzeKlines(
            MarketKline triggerKline,
            List<MarketKline> klines,
            boolean whitelisted,
            boolean persistIndicators,
            MarketKline sourceOneMinute
    ) {
        int historySize = requiredHistorySize(triggerKline.getIntervalCode());
        if (klines.size() < historySize) {
            return;
        }

        MarketKline latest = klines.getLast();
        if (!latest.getOpenTimeMs().equals(triggerKline.getOpenTimeMs())) {
            return;
        }

        BarSeries series = ta4jKlineSeriesFactory.build(
                triggerKline.getPair()
                        + "-"
                        + triggerKline.getIntervalCode()
                        + "-strategy",
                klines,
                Duration.ofMillis(MarketKlineService.intervalMillis(
                        triggerKline.getIntervalCode()
                ))
        );
        int lastIndex = series.getEndIndex();
        ClosePriceIndicator closePrice = new ClosePriceIndicator(series);
        SuperEmaPullbackStrategyProperties.IndicatorPeriods indicatorPeriods =
                properties.getIndicatorPeriods();
        EMAIndicator ema21 = new EMAIndicator(
                closePrice,
                Math.max(1, indicatorPeriods.getEmaFastPeriod())
        );
        EMAIndicator ema55 = new EMAIndicator(closePrice, properties.getEmaMiddlePeriod());
        EMAIndicator ema144 = new EMAIndicator(closePrice, properties.getEmaPeriod());
        MACDIndicator macd = new MACDIndicator(
                closePrice,
                Math.max(1, indicatorPeriods.getMacdShortPeriod()),
                Math.max(1, indicatorPeriods.getMacdLongPeriod())
        );
        ATRIndicator atr = new ATRIndicator(series, properties.getSuperAtrPeriod());
        ADXIndicator adx = new ADXIndicator(series, Math.max(1, properties.getSymbolFilter().getAdxPeriod()));
        SuperTrendIndicator superTrend = new SuperTrendIndicator(
                series,
                properties.getSuperAtrPeriod(),
                properties.getSuperMultiplier()
        );

        BigDecimal ema55Value = value(ema55.getValue(lastIndex));
        BigDecimal ema21Value = value(ema21.getValue(lastIndex));
        BigDecimal ema144Value = value(ema144.getValue(lastIndex));
        BigDecimal superTrendValue = value(superTrend.getValue(lastIndex));
        TrendDirection direction = directionAt(superTrend, lastIndex);
        boolean fourHour = MarketKlineService.INTERVAL_4H.equals(latest.getIntervalCode());
        TrendDirection signalDirection = fourHour
                ? fourHourDirection(ema21Value, ema55Value, ema144Value)
                : direction;
        boolean trendChanged = isTrendChanged(superTrend, lastIndex);

        if (!whitelisted && signalDirection != null) {
            DynamicSymbolKlineFilter.Decision decision = dynamicSymbolKlineFilter.evaluate(
                    klines,
                    ema144,
                    atr,
                    adx,
                    lastIndex,
                    signalDirection,
                    triggerKline.getIntervalCode()
            );
            if (!decision.eligible()) {
                log.debug(
                        "Skip {} for dynamically selected symbol {} because {}",
                        STRATEGY_FAMILY_CODE,
                        triggerKline.getPair(),
                        decision.rejectionReason()
                );
                return;
            }
        }

        if (persistIndicators) {
            persistEma(
                    latest,
                    EMA21_INDICATOR_CODE,
                    indicatorPeriods.getEmaFastPeriod(),
                    value(ema21.getValue(lastIndex))
            );
            persistEma(latest, EMA55_INDICATOR_CODE, properties.getEmaMiddlePeriod(), ema55Value);
            persistEma(latest, EMA144_INDICATOR_CODE, properties.getEmaPeriod(), ema144Value);
            persistMacd(latest, value(macd.getValue(lastIndex)));
            persistSuperTrend(latest, superTrend, lastIndex, superTrendValue, direction, trendChanged);
        }
        if (fourHour) {
            analyzeFourHourSignal(
                    klines, atr, superTrend, lastIndex,
                    ema21Value, ema55Value, ema144Value, superTrendValue, signalDirection,
                    sourceOneMinute
            );
            return;
        }
        analyzeSignal(
                klines,
                ema21,
                ema55,
                ema144,
                atr,
                superTrend,
                lastIndex,
                ema21Value,
                ema55Value,
                ema144Value,
                superTrendValue,
                direction
        );
    }

    static TrendDirection fourHourDirection(
            BigDecimal ema21,
            BigDecimal ema55,
            BigDecimal ema144
    ) {
        if (ema21 == null || ema55 == null || ema144 == null) {
            return null;
        }
        if (ema21.compareTo(ema55) > 0 && ema55.compareTo(ema144) > 0) {
            return TrendDirection.LONG;
        }
        return ema21.compareTo(ema55) < 0 && ema55.compareTo(ema144) < 0
                ? TrendDirection.SHORT : null;
    }

    private void analyzeFourHourSignal(
            List<MarketKline> klines,
            ATRIndicator atr,
            SuperTrendIndicator superTrend,
            int lastIndex,
            BigDecimal ema21,
            BigDecimal ema55,
            BigDecimal ema144,
            BigDecimal superTrendValue,
            TrendDirection direction,
            MarketKline sourceOneMinute
    ) {
        MarketKline latest = klines.get(lastIndex);
        BigDecimal atrValue = value(atr.getValue(lastIndex));
        BigDecimal tolerance = PullbackTouchEvaluator.allowedDistance(
                ema144,
                atrValue,
                properties.getPullbackTouchToleranceAtrMultiple(),
                properties.getPullbackTouchToleranceMaxRate()
        );
        fourHourStateService.evaluate(latest, direction, ema144, tolerance, sourceOneMinute, touchEventTime -> {
            int flipIndex = latestFlipIndex(superTrend, lastIndex);
            MarketKline flip = flipIndex < 0 ? null : klines.get(flipIndex);
            boolean provisional = Integer.valueOf(0).equals(latest.getClosedState());
            CandlestickPatternDetector.PatternMatch pattern = provisional ? null
                    : candlestickPatternDetector.detect(klines, lastIndex, direction);
            if (pattern == null) {
                pattern = new CandlestickPatternDetector.PatternMatch(
                        "NO_REVERSAL_PATTERN", 50,
                        List.of(provisional ? "4h盘中EMA144回踩，形态仅在收线后确认"
                                : "4h EMA排列与EMA144回踩触发，形态仅记录")
                );
            }
            StrategySignal signal = signal(
                    latest, flip, direction, latest.getClosePrice(),
                    BigDecimal.valueOf(pattern.score()).setScale(4, RoundingMode.HALF_UP),
                    pattern, PullbackTarget.EMA144, ema144,
                    ema21, ema55, ema144, superTrendValue, latest,
                    postTouchMove(klines, lastIndex, lastIndex, direction, atrValue),
                    PullbackRelativeExtremeEvaluator.evaluate(
                            klines, lastIndex, lastIndex, direction, atrValue,
                            0, 0, 0, 0, 0
                    )
            );
            signal.setId(idFor(
                    "strategy", latest.getExchange(), latest.getMarketType(),
                    latest.getContractType(), latest.getPair(), latest.getIntervalCode(),
                    PullbackTarget.EMA144.strategyCode(), "touch", touchEventTime.toString(),
                    direction.name()
            ));
            signal.setTouchEventTimeMs(touchEventTime);
            JsonObject reasons = JsonParser.parseString(signal.getReasonJson())
                    .getAsJsonObject();
            reasons.addProperty("triggerMode", "FOUR_HOUR_EMA144_RETOUCH");
            reasons.addProperty("touchEventTimeMs", touchEventTime);
            reasons.addProperty("touchTolerance", plain(tolerance));
            JsonArray triggerReasons = new JsonArray();
            triggerReasons.add("4h EMA排列满足，价格首次触达或离开后重新触达EMA144容差区");
            pattern.reasons().forEach(triggerReasons::add);
            reasons.add("reasons", triggerReasons);
            signal.setReasonJson(reasons.toString());
            if (strategySignalMapper.insertIgnore(signal) > 0) {
                log.info(
                        "STRATEGY_SIGNAL_CREATED strategy={} pair={} interval=4h direction={} price={} target=EMA144 targetValue={} ema21={} ema55={} superTrend={} touchEventTime={} triggerOpenTime={}",
                        signal.getStrategyCode(), signal.getPair(), direction,
                        plain(signal.getPrice()), plain(ema144), plain(ema21), plain(ema55),
                        plain(superTrendValue), touchEventTime, latest.getOpenTimeMs()
                );
                notifySignalHandlersAfterCommit(signal);
            }
        });
    }

    private int requiredHistorySize(String intervalCode) {
        if (MarketKlineService.INTERVAL_15M.equals(intervalCode)) {
            return Math.max(
                    1_500,
                    Math.max(
                            properties.getHistorySize(),
                            properties.getFifteenMinute().getHistorySize()
                    )
            );
        }
        if (MarketKlineService.INTERVAL_4H.equals(intervalCode)) {
            return Math.max(500, properties.getFourHour().getHistorySize());
        }
        return Math.max(1_500, properties.getHistorySize());
    }

    private void analyzeSignal(
            List<MarketKline> klines,
            EMAIndicator ema21,
            EMAIndicator ema55,
            EMAIndicator ema144,
            ATRIndicator atr,
            SuperTrendIndicator superTrend,
            int lastIndex,
            BigDecimal latestEma21,
            BigDecimal latestEma55,
            BigDecimal latestEma144,
            BigDecimal latestSuperTrend,
            TrendDirection currentDirection
    ) {
        int flipIndex = latestFlipIndex(superTrend, lastIndex);
        if (flipIndex < 0 || lastIndex - flipIndex > properties.getMaxWaitPullbackBars()) {
            return;
        }

        MarketKline flipKline = klines.get(flipIndex);
        CandlestickPatternDetector.PatternMatch pattern = candlestickPatternDetector.detect(
                klines,
                lastIndex,
                currentDirection
        );
        boolean provisional = Integer.valueOf(0).equals(klines.get(lastIndex).getClosedState());
        if (properties.isReversalPatternRequired() && provisional && pattern != null) {
            pattern = null;
        }
        if (properties.isReversalPatternRequired() && pattern == null) {
            return;
        }
        if (pattern == null) {
            pattern = new CandlestickPatternDetector.PatternMatch(
                    "NO_REVERSAL_PATTERN",
                    50,
                    provisional
                            ? List.of("4h盘中回踩触发，形态仅在收线后确认")
                            : List.of("当前配置不要求反转K线形态")
            );
        }

        analyzeTargetSignal(
                klines,
                ema144,
                ema21,
                ema55,
                atr,
                lastIndex,
                latestEma21,
                latestEma55,
                latestEma144,
                latestSuperTrend,
                currentDirection,
                flipKline,
                flipIndex,
                PullbackTarget.EMA144,
                pattern
        );
    }

    private void analyzeTargetSignal(
            List<MarketKline> klines,
            EMAIndicator targetIndicator,
            EMAIndicator ema21,
            EMAIndicator ema55,
            ATRIndicator atr,
            int lastIndex,
            BigDecimal latestEma21,
            BigDecimal latestEma55,
            BigDecimal latestEma144,
            BigDecimal latestSuperTrend,
            TrendDirection currentDirection,
            MarketKline flipKline,
            int flipIndex,
            PullbackTarget target,
            CandlestickPatternDetector.PatternMatch pattern
    ) {
        MarketKline latest = klines.get(lastIndex);
        if (strategySignalMapper.countByFlip(
                latest.getExchange(),
                latest.getMarketType(),
                latest.getContractType(),
                latest.getPair(),
                latest.getIntervalCode(),
                target.strategyCode(),
                flipKline.getOpenTimeMs(),
                currentDirection.name()
        ) > 0) {
            return;
        }

        PullbackTouchCandidate firstTouch = firstTargetTouch(
                klines,
                targetIndicator,
                ema21,
                ema55,
                targetIndicator,
                atr,
                flipIndex + 1,
                lastIndex,
                currentDirection
        );
        if (firstTouch == null) {
            return;
        }
        int firstTouchIndex = firstTouch.index();
        if (firstTouchIndex < 0 || lastIndex - firstTouchIndex > properties.getReversalLookaheadBars()) {
            return;
        }

        PostTouchMove postTouchMove = postTouchMove(
                klines,
                firstTouchIndex,
                lastIndex,
                currentDirection,
                value(atr.getValue(lastIndex))
        );
        if (properties.getMaxPostTouchMoveAwayAtr() > 0
                && postTouchMove.moveAwayAtr() > properties.getMaxPostTouchMoveAwayAtr()) {
            log.debug(
                    "Skip {} for {} because price moved too far after {} touch by ATR: direction={}, atrMove={}, maxAtrMove={}, priceMove={}, atr={}, extremeOpenTime={}, triggerOpenTime={}",
                    target.strategyCode(),
                    latest.getPair(),
                    target.displayName(),
                    currentDirection,
                    postTouchMove.moveAwayAtr(),
                    properties.getMaxPostTouchMoveAwayAtr(),
                    plain(postTouchMove.moveAwayPrice()),
                    plain(postTouchMove.atrValue()),
                    postTouchMove.extremeOpenTimeMs(),
                    latest.getOpenTimeMs()
            );
            return;
        }
        if (properties.getMaxPostTouchMoveAwayRate() > 0
                && postTouchMove.moveAwayRate() > properties.getMaxPostTouchMoveAwayRate()) {
            log.debug(
                    "Skip {} for {} because price moved too far after {} touch: direction={}, rate={}, max={}, extremeOpenTime={}, triggerOpenTime={}",
                    target.strategyCode(),
                    latest.getPair(),
                    target.displayName(),
                    currentDirection,
                    postTouchMove.moveAwayRate(),
                    properties.getMaxPostTouchMoveAwayRate(),
                    postTouchMove.extremeOpenTimeMs(),
                    latest.getOpenTimeMs()
            );
            return;
        }

        if (pattern != null
                && properties.isReversalPatternRequired()
                && isTerminalSingleCandlePattern(pattern.patternCode())
                && properties.getMaxTerminalPatternExtremeDistanceAtr() > 0
                && postTouchMove.triggerExtremeDistanceAtr() > properties.getMaxTerminalPatternExtremeDistanceAtr()) {
            log.debug(
                    "Skip {} for {} because terminal pattern is too far from post-touch extreme: pattern={}, direction={}, distanceAtr={}, maxDistanceAtr={}, distancePrice={}, extremeOpenTime={}, triggerOpenTime={}",
                    target.strategyCode(),
                    latest.getPair(),
                    pattern.patternCode(),
                    currentDirection,
                    postTouchMove.triggerExtremeDistanceAtr(),
                    properties.getMaxTerminalPatternExtremeDistanceAtr(),
                    plain(postTouchMove.triggerExtremeDistancePrice()),
                    postTouchMove.extremeOpenTimeMs(),
                    latest.getOpenTimeMs()
            );
            return;
        }
        BigDecimal closePrice = latest.getClosePrice();
        MarketKline firstTouchKline = klines.get(firstTouchIndex);
        BigDecimal firstTouchTargetValue = value(targetIndicator.getValue(firstTouchIndex));
        BigDecimal score = BigDecimal.valueOf(pattern.score())
                .setScale(4, RoundingMode.HALF_UP);
        StrategySignal signal = signal(
                latest,
                flipKline,
                currentDirection,
                closePrice,
                score,
                pattern,
                target,
                firstTouchTargetValue,
                latestEma21,
                latestEma55,
                latestEma144,
                latestSuperTrend,
                firstTouchKline,
                postTouchMove,
                firstTouch.relativeExtreme()
        );
        if (strategySignalMapper.insertIgnore(signal) > 0) {
            log.info(
                    "STRATEGY_SIGNAL_CREATED strategy={} pair={} interval={} direction={} price={} target={} targetValue={} ema21={} ema55={} ema144={} superTrend={} pattern={} score={} flipOpenTime={} touchOpenTime={} triggerOpenTime={} extremeQualifying={}/{}",
                    signal.getStrategyCode(),
                    signal.getPair(),
                    signal.getIntervalCode(),
                    signal.getDirection(),
                    plain(signal.getPrice()),
                    target.displayName(),
                    plain(firstTouchTargetValue),
                    plain(latestEma21),
                    plain(latestEma55),
                    plain(latestEma144),
                    plain(latestSuperTrend),
                    signal.getPatternCode(),
                    plain(signal.getScore()),
                    signal.getFlipOpenTimeMs(),
                    firstTouchKline.getOpenTimeMs(),
                    signal.getTriggerOpenTimeMs(),
                    firstTouch.relativeExtreme().qualifyingBars(),
                    firstTouch.relativeExtreme().requiredBars()
            );
            notifySignalHandlersAfterCommit(signal);
        }
    }

    private void notifySignalHandlersAfterCommit(StrategySignal signal) {
        if (signalHandlers.isEmpty()) {
            return;
        }
        Runnable notifier = () -> {
            for (StrategySignalHandler handler : signalHandlers) {
                try {
                    handler.onSignal(signal);
                } catch (Exception ex) {
                    log.warn(
                            "Strategy signal handler {} failed for {} {} {}",
                            handler.getClass().getName(),
                            signal.getPair(),
                            signal.getIntervalCode(),
                            signal.getDirection(),
                            ex
                    );
                }
            }
        };
        if (!TransactionSynchronizationManager.isSynchronizationActive()) {
            notifier.run();
            return;
        }
        TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
            @Override
            public void afterCommit() {
                notifier.run();
            }
        });
    }

    private int latestFlipIndex(SuperTrendIndicator superTrend, int lastIndex) {
        for (int index = lastIndex; index > 0; index--) {
            if (isTrendChanged(superTrend, index)) {
                return index;
            }
        }
        return -1;
    }

    private PullbackTouchCandidate firstTargetTouch(
            List<MarketKline> klines,
            EMAIndicator targetIndicator,
            EMAIndicator ema21,
            EMAIndicator ema55,
            EMAIndicator ema144,
            ATRIndicator atr,
            int startIndex,
            int endIndex,
            TrendDirection direction
    ) {
        boolean requireEma144Outermost = properties.getFourHour()
                .isEma144OutermostRequired()
                && MarketKlineService.INTERVAL_4H.equals(
                        klines.get(endIndex).getIntervalCode()
                );
        for (int index = Math.max(0, startIndex); index <= endIndex; index++) {
            BigDecimal atrValue = value(atr.getValue(index));
            if (!PullbackTouchEvaluator.touches(
                        klines.get(index),
                        value(targetIndicator.getValue(index)),
                        atrValue,
                        direction,
                        properties.getPullbackTouchToleranceAtrMultiple(),
                        properties.getPullbackTouchToleranceMaxRate(),
                        properties.isEmaCloseConfirmationRequired(),
                        properties.getEmaBreakAllowRate()
                )) {
                continue;
            }

            if (requireEma144Outermost && !isEma144Outermost(
                    ema21,
                    ema55,
                    ema144,
                    index,
                    direction
            )) {
                log.debug(
                        "Skip 4h EMA144 touch because EMA144 is not outermost: pair={}, direction={}, openTime={}, ema21={}, ema55={}, ema144={}",
                        klines.get(index).getPair(),
                        direction,
                        klines.get(index).getOpenTimeMs(),
                        plain(value(ema21.getValue(index))),
                        plain(value(ema55.getValue(index))),
                        plain(value(ema144.getValue(index)))
                );
                continue;
            }

            PullbackRelativeExtremeEvaluator.Result extreme =
                    PullbackRelativeExtremeEvaluator.evaluate(
                            klines,
                            index,
                            startIndex,
                            direction,
                            atrValue,
                            properties.getRelativeExtremeLookbackBars(),
                            properties.getRelativeExtremeMinComparisonBars(),
                            properties.getRelativeExtremeMinQualifyingRatio(),
                            properties.getRelativeExtremeToleranceAtrMultiple(),
                            properties.getRelativeExtremeToleranceMaxRate()
                    );
            if (extreme.eligible()) {
                return new PullbackTouchCandidate(index, extreme);
            }
            log.debug(
                    "Skip EMA144 touch because it is not near a recent directional extreme: pair={}, direction={}, openTime={}, candidateExtreme={}, tolerance={}, comparisonBars={}, qualifyingBars={}, requiredBars={}",
                    klines.get(index).getPair(),
                    direction,
                    klines.get(index).getOpenTimeMs(),
                    plain(extreme.candidateExtreme()),
                    plain(extreme.tolerance()),
                    extreme.comparisonBars(),
                    extreme.qualifyingBars(),
                    extreme.requiredBars()
            );
        }
        return null;
    }

    static boolean isEma144Outermost(
            BigDecimal ema21,
            BigDecimal ema55,
            BigDecimal ema144,
            TrendDirection direction
    ) {
        if (ema21 == null || ema55 == null || ema144 == null) {
            return false;
        }
        if (direction == TrendDirection.LONG) {
            return ema144.compareTo(ema21) < 0
                    && ema144.compareTo(ema55) < 0;
        }
        return ema144.compareTo(ema21) > 0
                && ema144.compareTo(ema55) > 0;
    }

    private boolean isEma144Outermost(
            EMAIndicator ema21,
            EMAIndicator ema55,
            EMAIndicator ema144,
            int index,
            TrendDirection direction
    ) {
        return isEma144Outermost(
                value(ema21.getValue(index)),
                value(ema55.getValue(index)),
                value(ema144.getValue(index)),
                direction
        );
    }

    private PostTouchMove postTouchMove(
            List<MarketKline> klines,
            int firstTouchIndex,
            int lastIndex,
            TrendDirection direction,
            BigDecimal atrValue
    ) {
        MarketKline latest = klines.get(lastIndex);
        if (direction == TrendDirection.LONG) {
            MarketKline lowest = klines.subList(firstTouchIndex, lastIndex + 1).stream()
                    .min(Comparator.comparing(MarketKline::getLowPrice))
                    .orElse(latest);
            BigDecimal moveAwayPrice = latest.getClosePrice().subtract(lowest.getLowPrice()).max(BigDecimal.ZERO);
            BigDecimal triggerExtremeDistancePrice = latest.getLowPrice()
                    .subtract(lowest.getLowPrice())
                    .max(BigDecimal.ZERO);
            double base = lowest.getLowPrice().doubleValue();
            double moveAwayRate = base <= 0 ? 0 : moveAwayPrice.doubleValue() / base;
            return new PostTouchMove(
                    lowest.getOpenTimeMs(),
                    lowest.getLowPrice(),
                    moveAwayPrice,
                    atrValue,
                    moveAwayAtr(moveAwayPrice, atrValue),
                    triggerExtremeDistancePrice,
                    moveAwayAtr(triggerExtremeDistancePrice, atrValue),
                    moveAwayRate
            );
        }

        MarketKline highest = klines.subList(firstTouchIndex, lastIndex + 1).stream()
                .max(Comparator.comparing(MarketKline::getHighPrice))
                .orElse(latest);
        BigDecimal moveAwayPrice = highest.getHighPrice().subtract(latest.getClosePrice()).max(BigDecimal.ZERO);
        BigDecimal triggerExtremeDistancePrice = highest.getHighPrice()
                .subtract(latest.getHighPrice())
                .max(BigDecimal.ZERO);
        double base = highest.getHighPrice().doubleValue();
        double moveAwayRate = base <= 0 ? 0 : moveAwayPrice.doubleValue() / base;
        return new PostTouchMove(
                highest.getOpenTimeMs(),
                highest.getHighPrice(),
                moveAwayPrice,
                atrValue,
                moveAwayAtr(moveAwayPrice, atrValue),
                triggerExtremeDistancePrice,
                moveAwayAtr(triggerExtremeDistancePrice, atrValue),
                moveAwayRate
        );
    }

    private double moveAwayAtr(BigDecimal moveAwayPrice, BigDecimal atrValue) {
        double atr = atrValue == null ? 0 : atrValue.doubleValue();
        return atr <= 0 ? 0 : moveAwayPrice.doubleValue() / atr;
    }

    private boolean isTerminalSingleCandlePattern(String patternCode) {
        return switch (patternCode) {
            case "DOJI_BULLISH_REVERSAL",
                 "DOJI_BEARISH_REVERSAL",
                 "DRAGONFLY_DOJI",
                 "GRAVESTONE_DOJI",
                 "HAMMER",
                 "HANGING_MAN",
                 "INVERTED_HAMMER",
                 "SHOOTING_STAR" -> true;
            default -> false;
        };
    }

    private void persistEma(MarketKline kline, String indicatorCode, int period, BigDecimal emaValue) {
        JsonObject extra = new JsonObject();
        extra.addProperty("period", period);
        extra.addProperty("historySize", requiredHistorySize(kline.getIntervalCode()));
        marketIndicatorMapper.upsert(indicator(
                kline,
                indicatorCode,
                emaValue,
                null,
                extra.toString()
        ));
    }

    private void persistMacd(MarketKline kline, BigDecimal macdValue) {
        SuperEmaPullbackStrategyProperties.IndicatorPeriods periods =
                properties.getIndicatorPeriods();
        JsonObject extra = new JsonObject();
        extra.addProperty("shortPeriod", periods.getMacdShortPeriod());
        extra.addProperty("longPeriod", periods.getMacdLongPeriod());
        extra.addProperty("signalPeriod", periods.getMacdSignalPeriod());
        extra.addProperty("zeroAxis", "0");
        marketIndicatorMapper.upsert(indicator(
                kline,
                MACD_INDICATOR_CODE,
                macdValue,
                null,
                extra.toString()
        ));
    }

    private void persistSuperTrend(
            MarketKline kline,
            SuperTrendIndicator superTrend,
            int index,
            BigDecimal superTrendValue,
            TrendDirection direction,
            boolean trendChanged
    ) {
        JsonObject extra = new JsonObject();
        extra.addProperty("atrPeriod", properties.getSuperAtrPeriod());
        extra.addProperty("multiplier", properties.getSuperMultiplier());
        extra.addProperty("trendChanged", trendChanged);
        extra.addProperty("upperBand", plain(value(superTrend.getSuperTrendUpperBandIndicator().getValue(index))));
        extra.addProperty("lowerBand", plain(value(superTrend.getSuperTrendLowerBandIndicator().getValue(index))));
        marketIndicatorMapper.upsert(indicator(
                kline,
                SUPER_TREND_INDICATOR_CODE,
                superTrendValue,
                direction.name(),
                extra.toString()
        ));
    }

    private MarketIndicator indicator(
            MarketKline kline,
            String indicatorCode,
            BigDecimal indicatorValue,
            String direction,
            String extraJson
    ) {
        MarketIndicator indicator = new MarketIndicator();
        indicator.setId(idFor("indicator",
                kline.getExchange(),
                kline.getMarketType(),
                kline.getContractType(),
                kline.getPair(),
                kline.getIntervalCode(),
                indicatorCode,
                String.valueOf(kline.getOpenTimeMs())));
        fillBaseFields(indicator);
        indicator.setExchange(kline.getExchange());
        indicator.setMarketType(kline.getMarketType());
        indicator.setContractType(kline.getContractType());
        indicator.setPair(kline.getPair());
        indicator.setIntervalCode(kline.getIntervalCode());
        indicator.setOpenTimeMs(kline.getOpenTimeMs());
        indicator.setCloseTimeMs(kline.getCloseTimeMs());
        indicator.setIndicatorCode(indicatorCode);
        indicator.setIndicatorValue(indicatorValue);
        indicator.setDirection(direction);
        indicator.setExtraJson(extraJson);
        return indicator;
    }

    private StrategySignal signal(
            MarketKline latest,
            MarketKline flipKline,
            TrendDirection direction,
            BigDecimal price,
            BigDecimal score,
            CandlestickPatternDetector.PatternMatch pattern,
            PullbackTarget target,
            BigDecimal firstTouchTargetValue,
            BigDecimal ema21Value,
            BigDecimal ema55Value,
            BigDecimal ema144Value,
            BigDecimal superTrendValue,
            MarketKline firstTouchKline,
            PostTouchMove postTouchMove,
            PullbackRelativeExtremeEvaluator.Result relativeExtreme
    ) {
        StrategySignal signal = new StrategySignal();
        signal.setId(idFor("strategy",
                latest.getExchange(),
                latest.getMarketType(),
                latest.getContractType(),
                latest.getPair(),
                latest.getIntervalCode(),
                target.strategyCode(),
                String.valueOf(flipKline == null ? 0L : flipKline.getOpenTimeMs()),
                direction.name()));
        fillBaseFields(signal);
        signal.setExchange(latest.getExchange());
        signal.setMarketType(latest.getMarketType());
        signal.setContractType(latest.getContractType());
        signal.setPair(latest.getPair());
        signal.setIntervalCode(latest.getIntervalCode());
        signal.setStrategyCode(target.strategyCode());
        signal.setDirection(direction.name());
        signal.setSignalTimeMs(System.currentTimeMillis());
        signal.setTriggerOpenTimeMs(latest.getOpenTimeMs());
        signal.setFlipOpenTimeMs(flipKline == null ? 0L : flipKline.getOpenTimeMs());
        signal.setPrice(price);
        signal.setScore(score);
        signal.setPatternCode(pattern.patternCode());
        signal.setReasonJson(reasonJson(
                pattern,
                target,
                firstTouchTargetValue,
                ema21Value,
                ema55Value,
                ema144Value,
                superTrendValue,
                firstTouchKline,
                postTouchMove,
                relativeExtreme
        ));
        return signal;
    }

    private String reasonJson(
            CandlestickPatternDetector.PatternMatch pattern,
            PullbackTarget target,
            BigDecimal firstTouchTargetValue,
            BigDecimal ema21Value,
            BigDecimal ema55Value,
            BigDecimal ema144Value,
            BigDecimal superTrendValue,
            MarketKline firstTouchKline,
            PostTouchMove postTouchMove,
            PullbackRelativeExtremeEvaluator.Result relativeExtreme
    ) {
        JsonObject root = new JsonObject();
        root.addProperty("pullbackTarget", target.displayName());
        root.addProperty("pullbackTargetValue", plain(firstTouchTargetValue));
        root.addProperty("ema21", plain(ema21Value));
        root.addProperty("ema55", plain(ema55Value));
        root.addProperty("ema144", plain(ema144Value));
        root.addProperty("superTrend", plain(superTrendValue));
        root.addProperty("firstTouchOpenTimeMs", firstTouchKline.getOpenTimeMs());
        root.addProperty("postTouchExtremeOpenTimeMs", postTouchMove.extremeOpenTimeMs());
        root.addProperty("postTouchExtremePrice", plain(postTouchMove.extremePrice()));
        root.addProperty("postTouchMoveAwayPrice", plain(postTouchMove.moveAwayPrice()));
        root.addProperty("postTouchAtr", plain(postTouchMove.atrValue()));
        root.addProperty("postTouchMoveAwayAtr", postTouchMove.moveAwayAtr());
        root.addProperty("postTouchMoveAwayRate", postTouchMove.moveAwayRate());
        root.addProperty("terminalPatternExtremeDistancePrice", plain(postTouchMove.triggerExtremeDistancePrice()));
        root.addProperty("terminalPatternExtremeDistanceAtr", postTouchMove.triggerExtremeDistanceAtr());
        root.addProperty(
                "relativeExtremePrice",
                plain(relativeExtreme.candidateExtreme())
        );
        root.addProperty(
                "relativeExtremeTolerance",
                plain(relativeExtreme.tolerance())
        );
        root.addProperty(
                "relativeExtremeComparisonBars",
                relativeExtreme.comparisonBars()
        );
        root.addProperty(
                "relativeExtremeQualifyingBars",
                relativeExtreme.qualifyingBars()
        );
        root.addProperty(
                "relativeExtremeRequiredBars",
                relativeExtreme.requiredBars()
        );
        JsonArray reasons = new JsonArray();
        pattern.reasonsWith("首次回踩/回抽 " + target.displayName() + " 后出现反转形态").forEach(reasons::add);
        root.add("reasons", reasons);
        return root.toString();
    }

    private TrendDirection directionAt(SuperTrendIndicator superTrend, int index) {
        return superTrend.isUpTrend(index) ? TrendDirection.LONG : TrendDirection.SHORT;
    }

    private boolean isTrendChanged(SuperTrendIndicator superTrend, int index) {
        return index > 0 && directionAt(superTrend, index) != directionAt(superTrend, index - 1);
    }

    private BigDecimal value(org.ta4j.core.num.Num value) {
        return value.bigDecimalValue().setScale(18, RoundingMode.HALF_UP).stripTrailingZeros();
    }

    private void fillBaseFields(MarketIndicator indicator) {
        LocalDateTime now = LocalDateTime.now();
        indicator.setCreateTime(now);
        indicator.setUpdateTime(now);
        indicator.setCreateUser("system");
        indicator.setUpdateUser("system");
        indicator.setDeleteState(0);
    }

    private void fillBaseFields(StrategySignal signal) {
        LocalDateTime now = LocalDateTime.now();
        signal.setCreateTime(now);
        signal.setUpdateTime(now);
        signal.setCreateUser("system");
        signal.setUpdateUser("system");
        signal.setDeleteState(0);
    }

    private String idFor(String... values) {
        String value = String.join("|", values);
        return UUID.nameUUIDFromBytes(value.getBytes(StandardCharsets.UTF_8)).toString();
    }

    private String plain(BigDecimal value) {
        return value == null ? null : value.toPlainString();
    }

    private record PostTouchMove(
            Long extremeOpenTimeMs,
            BigDecimal extremePrice,
            BigDecimal moveAwayPrice,
            BigDecimal atrValue,
            double moveAwayAtr,
            BigDecimal triggerExtremeDistancePrice,
            double triggerExtremeDistanceAtr,
            double moveAwayRate
    ) {
    }

    private record PullbackTouchCandidate(
            int index,
            PullbackRelativeExtremeEvaluator.Result relativeExtreme
    ) {
    }

    private enum PullbackTarget {
        EMA144("EMA144", "SUPER_EMA144_PULLBACK_REVERSAL");

        private final String displayName;

        private final String strategyCode;

        PullbackTarget(String displayName, String strategyCode) {
            this.displayName = displayName;
            this.strategyCode = strategyCode;
        }

        private String displayName() {
            return displayName;
        }

        private String strategyCode() {
            return strategyCode;
        }
    }

}
