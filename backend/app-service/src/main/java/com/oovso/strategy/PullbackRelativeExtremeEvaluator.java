package com.oovso.strategy;

import com.oovso.market.MarketKline;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.List;

/**
 * Keeps EMA pullback touches that are near a recent directional extreme.
 * A rank test is intentionally used instead of requiring an absolute new
 * low/high, so a useful higher-low or lower-high is not rejected by one old
 * wick.
 */
final class PullbackRelativeExtremeEvaluator {

    private static final int SCALE = 18;

    private PullbackRelativeExtremeEvaluator() {
    }

    static Result evaluate(
            List<MarketKline> klines,
            int candidateIndex,
            int trendStartIndex,
            TrendDirection direction,
            BigDecimal atrValue,
            int lookbackBars,
            int minComparisonBars,
            double minQualifyingRatio,
            double toleranceAtrMultiple,
            double toleranceMaxRate
    ) {
        if (klines == null
                || candidateIndex < 0
                || candidateIndex >= klines.size()) {
            return Result.rejected();
        }

        BigDecimal candidateExtreme = extreme(
                klines.get(candidateIndex),
                direction
        );
        if (!positive(candidateExtreme)) {
            return Result.rejected();
        }

        int normalizedLookback = Math.max(0, lookbackBars);
        if (normalizedLookback == 0 || minQualifyingRatio <= 0) {
            return Result.unfiltered(candidateExtreme);
        }

        int startIndex = Math.max(
                Math.max(0, trendStartIndex),
                candidateIndex - normalizedLookback
        );
        BigDecimal tolerance = tolerance(
                candidateExtreme,
                atrValue,
                toleranceAtrMultiple,
                toleranceMaxRate
        );

        int comparisonBars = 0;
        int qualifyingBars = 0;
        for (int index = startIndex; index < candidateIndex; index++) {
            BigDecimal previousExtreme = extreme(
                    klines.get(index),
                    direction
            );
            if (!positive(previousExtreme)) {
                continue;
            }
            comparisonBars++;
            if (qualifies(
                    candidateExtreme,
                    previousExtreme,
                    tolerance,
                    direction
            )) {
                qualifyingBars++;
            }
        }

        int normalizedMinimum = Math.max(0, minComparisonBars);
        if (comparisonBars == 0 || comparisonBars < normalizedMinimum) {
            return new Result(
                    true,
                    candidateExtreme,
                    tolerance,
                    comparisonBars,
                    qualifyingBars,
                    0
            );
        }

        double normalizedRatio = Math.min(1.0, minQualifyingRatio);
        int requiredBars = Math.max(
                1,
                (int) Math.ceil(comparisonBars * normalizedRatio)
        );
        return new Result(
                qualifyingBars >= requiredBars,
                candidateExtreme,
                tolerance,
                comparisonBars,
                qualifyingBars,
                requiredBars
        );
    }

    private static boolean qualifies(
            BigDecimal candidate,
            BigDecimal previous,
            BigDecimal tolerance,
            TrendDirection direction
    ) {
        if (direction == TrendDirection.LONG) {
            return candidate.compareTo(previous.add(tolerance)) <= 0;
        }
        return candidate.compareTo(previous.subtract(tolerance)) >= 0;
    }

    private static BigDecimal tolerance(
            BigDecimal candidateExtreme,
            BigDecimal atrValue,
            double atrMultiple,
            double maxRate
    ) {
        BigDecimal atrTolerance = nonNegative(atrValue)
                .multiply(BigDecimal.valueOf(Math.max(0, atrMultiple)));
        BigDecimal rateTolerance = candidateExtreme
                .abs()
                .multiply(BigDecimal.valueOf(Math.max(0, maxRate)));
        return atrTolerance.min(rateTolerance)
                .setScale(SCALE, RoundingMode.HALF_UP)
                .stripTrailingZeros();
    }

    private static BigDecimal extreme(
            MarketKline kline,
            TrendDirection direction
    ) {
        if (kline == null || direction == null) {
            return null;
        }
        return direction == TrendDirection.LONG
                ? kline.getLowPrice()
                : kline.getHighPrice();
    }

    private static boolean positive(BigDecimal value) {
        return value != null && value.signum() > 0;
    }

    private static BigDecimal nonNegative(BigDecimal value) {
        return value == null ? BigDecimal.ZERO : value.max(BigDecimal.ZERO);
    }

    record Result(
            boolean eligible,
            BigDecimal candidateExtreme,
            BigDecimal tolerance,
            int comparisonBars,
            int qualifyingBars,
            int requiredBars
    ) {

        private static Result rejected() {
            return new Result(
                    false,
                    null,
                    BigDecimal.ZERO,
                    0,
                    0,
                    0
            );
        }

        private static Result unfiltered(BigDecimal candidateExtreme) {
            return new Result(
                    true,
                    candidateExtreme,
                    BigDecimal.ZERO,
                    0,
                    0,
                    0
            );
        }
    }
}
