package com.oovso.strategy;

import com.oovso.market.MarketKline;
import java.math.BigDecimal;

final class PullbackTouchEvaluator {

    private PullbackTouchEvaluator() {
    }

    static boolean touches(
            MarketKline kline,
            BigDecimal targetValue,
            BigDecimal atrValue,
            TrendDirection direction,
            double atrMultiple,
            double maxRate,
            boolean closeConfirmationRequired,
            double breakAllowRate
    ) {
        BigDecimal allowedDistance = allowedDistance(targetValue, atrValue, atrMultiple, maxRate);

        BigDecimal distanceBelowRange = kline.getLowPrice()
                .subtract(targetValue)
                .max(BigDecimal.ZERO);
        BigDecimal distanceAboveRange = targetValue
                .subtract(kline.getHighPrice())
                .max(BigDecimal.ZERO);
        BigDecimal distance = distanceBelowRange.max(distanceAboveRange);
        if (distance.compareTo(allowedDistance) > 0) {
            return false;
        }
        if (!closeConfirmationRequired) {
            return true;
        }

        BigDecimal breakRate = BigDecimal.valueOf(Math.max(0, breakAllowRate));
        if (direction == TrendDirection.LONG) {
            BigDecimal breakLine = targetValue.multiply(BigDecimal.ONE.subtract(breakRate));
            return kline.getClosePrice().compareTo(breakLine) >= 0;
        }
        BigDecimal breakLine = targetValue.multiply(BigDecimal.ONE.add(breakRate));
        return kline.getClosePrice().compareTo(breakLine) <= 0;
    }

    static BigDecimal allowedDistance(
            BigDecimal targetValue,
            BigDecimal atrValue,
            double atrMultiple,
            double maxRate
    ) {
        BigDecimal atrTolerance = nonNegative(atrValue)
                .multiply(BigDecimal.valueOf(Math.max(0, atrMultiple)));
        BigDecimal rateTolerance = targetValue.abs()
                .multiply(BigDecimal.valueOf(Math.max(0, maxRate)));
        return atrTolerance.min(rateTolerance);
    }

    private static BigDecimal nonNegative(BigDecimal value) {
        return value == null ? BigDecimal.ZERO : value.max(BigDecimal.ZERO);
    }
}
