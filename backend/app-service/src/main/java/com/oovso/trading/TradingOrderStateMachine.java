package com.oovso.trading;

import java.math.BigDecimal;
import java.util.Locale;
import java.util.Set;

public final class TradingOrderStateMachine {

    private static final Set<String> REGULAR_TERMINAL = Set.of(
            "FILLED", "CANCELED", "REJECTED", "EXPIRED"
    );

    private static final Set<String> ALGO_TERMINAL = Set.of(
            "FINISHED", "CANCELED", "REJECTED", "EXPIRED"
    );

    private TradingOrderStateMachine() {
    }

    public static MergeDecision mergeRegular(
            String currentStatus,
            BigDecimal currentExecutedQuantity,
            long currentEventMillis,
            String exchangeStatus,
            BigDecimal incomingExecutedQuantity,
            long incomingEventMillis
    ) {
        String incoming = normalizeRegular(exchangeStatus);
        return merge(
                normalizeNullable(currentStatus),
                nonNull(currentExecutedQuantity),
                currentEventMillis,
                incoming,
                nonNull(incomingExecutedQuantity),
                incomingEventMillis,
                REGULAR_TERMINAL,
                false
        );
    }

    public static MergeDecision mergeAlgo(
            String currentStatus,
            long currentEventMillis,
            String exchangeStatus,
            long incomingEventMillis
    ) {
        return merge(
                normalizeNullable(currentStatus),
                BigDecimal.ZERO,
                currentEventMillis,
                normalizeAlgo(exchangeStatus),
                BigDecimal.ZERO,
                incomingEventMillis,
                ALGO_TERMINAL,
                true
        );
    }

    public static String normalizeRegular(String exchangeStatus) {
        String status = normalizeNullable(exchangeStatus);
        if (status == null) {
            return "UNKNOWN";
        }
        return switch (status) {
            case "NEW" -> "LIVE";
            case "PARTIALLY_FILLED" -> "PARTIALLY_FILLED";
            case "FILLED" -> "FILLED";
            case "CANCELED" -> "CANCELED";
            case "REJECTED" -> "REJECTED";
            case "EXPIRED", "EXPIRED_IN_MATCH" -> "EXPIRED";
            default -> status;
        };
    }

    public static String normalizeAlgo(String exchangeStatus) {
        String status = normalizeNullable(exchangeStatus);
        if (status == null) {
            return "UNKNOWN";
        }
        return switch (status) {
            case "NEW", "TRIGGERING", "TRIGGERED", "FINISHED",
                 "CANCELED", "REJECTED", "EXPIRED" -> status;
            default -> status;
        };
    }

    public static boolean isRegularActive(String status) {
        String normalized = normalizeNullable(status);
        return normalized == null || !REGULAR_TERMINAL.contains(normalized);
    }

    public static boolean isAlgoActive(String status) {
        String normalized = normalizeNullable(status);
        return normalized == null || !ALGO_TERMINAL.contains(normalized);
    }

    private static MergeDecision merge(
            String current,
            BigDecimal currentExecuted,
            long currentEvent,
            String incoming,
            BigDecimal incomingExecuted,
            long incomingEvent,
            Set<String> terminal,
            boolean algo
    ) {
        if (current == null || "INTENT".equals(current)
                || "SUBMITTING".equals(current) || "UNKNOWN".equals(current)
                || "UNRESOLVED".equals(current)) {
            return new MergeDecision(incoming, true);
        }

        boolean quantityAdvanced = incomingExecuted.compareTo(currentExecuted) > 0;
        if (terminal.contains(current)) {
            if ("FILLED".equals(incoming) && !"FILLED".equals(current)) {
                return new MergeDecision("FILLED", true);
            }
            return new MergeDecision(
                    current,
                    quantityAdvanced || current.equals(incoming)
                            && incomingEvent >= currentEvent
            );
        }

        if (incomingEvent < currentEvent && !quantityAdvanced
                && !terminal.contains(incoming)) {
            return new MergeDecision(current, false);
        }

        boolean legal = algo
                ? legalAlgoTransition(current, incoming)
                : legalRegularTransition(current, incoming);
        if (!legal) {
            return new MergeDecision(current, quantityAdvanced);
        }
        return new MergeDecision(incoming, true);
    }

    private static boolean legalRegularTransition(
            String current,
            String incoming
    ) {
        if (current.equals(incoming)) {
            return true;
        }
        return switch (current) {
            case "LIVE" -> Set.of(
                    "PARTIALLY_FILLED", "FILLED", "CANCEL_PENDING",
                    "CANCELED", "REJECTED", "EXPIRED"
            ).contains(incoming);
            case "PARTIALLY_FILLED" -> Set.of(
                    "FILLED", "CANCEL_PENDING", "CANCELED", "EXPIRED"
            ).contains(incoming);
            case "CANCEL_PENDING" -> Set.of(
                    "PARTIALLY_FILLED", "FILLED", "CANCELED", "UNKNOWN"
            ).contains(incoming);
            default -> true;
        };
    }

    private static boolean legalAlgoTransition(
            String current,
            String incoming
    ) {
        if (current.equals(incoming)) {
            return true;
        }
        return switch (current) {
            case "NEW" -> Set.of(
                    "TRIGGERING", "TRIGGERED", "FINISHED",
                    "CANCELED", "REJECTED", "EXPIRED"
            ).contains(incoming);
            case "TRIGGERING" -> Set.of(
                    "TRIGGERED", "FINISHED", "CANCELED",
                    "REJECTED", "EXPIRED"
            ).contains(incoming);
            case "TRIGGERED" -> Set.of(
                    "FINISHED", "CANCELED", "REJECTED", "EXPIRED"
            ).contains(incoming);
            default -> true;
        };
    }

    private static String normalizeNullable(String status) {
        return status == null || status.isBlank()
                ? null
                : status.trim().toUpperCase(Locale.ROOT);
    }

    private static BigDecimal nonNull(BigDecimal value) {
        return value == null ? BigDecimal.ZERO : value;
    }

    public record MergeDecision(String state, boolean acceptPayload) {
    }
}
