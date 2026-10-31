package com.oovso.strategy;

import com.oovso.market.MarketKline;
import java.math.BigDecimal;
import java.math.RoundingMode;

public record ReversalAlert(
        String userId,
        String sourceSignalId,
        String symbol,
        String contractType,
        String intervalCode,
        String direction,
        long triggeredTimeMs,
        long triggerOpenTimeMs,
        BigDecimal triggerPrice,
        String patternCode,
        String patternName,
        BigDecimal score
) {

    static ReversalAlert from(
            StrategySignalReversalWatch watch,
            MarketKline kline,
            CandlestickPatternDetector.PatternMatch pattern
    ) {
        return from(
                watch,
                kline,
                pattern.patternCode(),
                CandlestickPatternNames.displayName(pattern.patternCode()),
                pattern.score()
        );
    }

    static ReversalAlert from(
            StrategySignalReversalWatch watch,
            MarketKline kline,
            MacdMomentumDecayDetector.DecayMatch decay
    ) {
        return from(
                watch,
                kline,
                decay.triggerCode(),
                decay.triggerName(),
                decay.score()
        );
    }

    private static ReversalAlert from(
            StrategySignalReversalWatch watch,
            MarketKline kline,
            String triggerCode,
            String triggerName,
            double score
    ) {
        long triggeredTime = kline.getCloseTimeMs() == null
                ? System.currentTimeMillis()
                : kline.getCloseTimeMs();
        return new ReversalAlert(
                watch.getUserId(),
                watch.getSignalId(),
                watch.getSymbol(),
                watch.getContractType(),
                watch.getSourceIntervalCode(),
                watch.getDirection(),
                triggeredTime,
                kline.getOpenTimeMs(),
                kline.getClosePrice(),
                triggerCode,
                triggerName,
                BigDecimal.valueOf(score)
                        .setScale(4, RoundingMode.HALF_UP)
        );
    }

    public StrategySignal notificationSignal() {
        StrategySignal signal = new StrategySignal();
        signal.setId(sourceSignalId);
        signal.setPair(symbol);
        signal.setContractType(contractType);
        signal.setIntervalCode(intervalCode);
        signal.setStrategyCode("SECONDARY_REVERSAL_ALERT");
        signal.setDirection(direction);
        signal.setSignalTimeMs(triggeredTimeMs);
        signal.setTriggerOpenTimeMs(triggerOpenTimeMs);
        signal.setPrice(triggerPrice);
        signal.setScore(score);
        signal.setPatternCode(patternCode);
        signal.setNotificationName(patternName);
        return signal;
    }
}
