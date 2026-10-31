package com.oovso.trading;

import java.math.BigDecimal;
import java.util.Locale;

/** Pure decisions shared by persisted stop-loss and take-profit repair loops. */
public final class TradingOrderRepairPolicy {

    private static final long MAX_BACKOFF_MULTIPLIER = 16;

    private TradingOrderRepairPolicy() {
    }

    public static Health regularHealth(String status) {
        String value = normalized(status);
        if (value == null) {
            return Health.REPAIR;
        }
        return switch (value) {
            case "LIVE", "PARTIALLY_FILLED", "NEW" -> Health.HEALTHY;
            case "FILLED" -> Health.COMPLETED;
            case "CANCELED", "REJECTED", "EXPIRED" -> Health.REPAIR;
            default -> Health.RECONCILE;
        };
    }

    public static Health algoHealth(String status) {
        String value = normalized(status);
        if (value == null) {
            return Health.REPAIR;
        }
        return switch (value) {
            case "NEW", "TRIGGERING", "TRIGGERED" -> Health.HEALTHY;
            case "FINISHED" -> Health.COMPLETED;
            case "CANCELED", "REJECTED", "EXPIRED" -> Health.REPAIR;
            default -> Health.RECONCILE;
        };
    }

    public static boolean checkDue(
            Long lastCheckMillis,
            long intervalMillis,
            long nowMillis
    ) {
        return lastCheckMillis == null
                || nowMillis - lastCheckMillis >= Math.max(1_000, intervalMillis);
    }

    public static long nextRetryMillis(
            long nowMillis,
            long baseBackoffMillis,
            int attempts
    ) {
        int shift = Math.max(0, Math.min(4, attempts - 1));
        long multiplier = Math.min(
                MAX_BACKOFF_MULTIPLIER,
                1L << shift
        );
        long base = Math.max(1_000, baseBackoffMillis);
        try {
            return Math.addExact(nowMillis, Math.multiplyExact(base, multiplier));
        } catch (ArithmeticException ignored) {
            return Long.MAX_VALUE;
        }
    }

    public static BigDecimal cumulativeExecuted(
            BigDecimal attemptBase,
            BigDecimal currentOrderExecuted
    ) {
        return nonNull(attemptBase).add(nonNull(currentOrderExecuted));
    }

    public static BigDecimal remainingReduction(
            BigDecimal planned,
            BigDecimal cumulativeExecuted,
            BigDecimal remainingPosition,
            BigDecimal quantityStep
    ) {
        BigDecimal outstanding = nonNull(planned)
                .subtract(nonNull(cumulativeExecuted));
        if (outstanding.signum() <= 0
                || remainingPosition == null
                || remainingPosition.signum() <= 0) {
            return BigDecimal.ZERO;
        }
        return TradingRiskEngine.floorToStep(
                outstanding.min(remainingPosition),
                quantityStep
        );
    }

    private static BigDecimal nonNull(BigDecimal value) {
        return value == null ? BigDecimal.ZERO : value;
    }

    private static String normalized(String status) {
        return status == null || status.isBlank()
                ? null
                : status.trim().toUpperCase(Locale.ROOT);
    }

    public enum Health {
        HEALTHY,
        RECONCILE,
        COMPLETED,
        REPAIR
    }
}
