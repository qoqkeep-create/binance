package com.oovso.trading;

import java.util.Map;
import java.util.Set;

public final class TradingCommandStateMachine {

    private static final Map<String, Set<String>> TRANSITIONS = Map.of(
            "RECEIVED", Set.of("VALIDATED", "FAILED_KNOWN"),
            "VALIDATED", Set.of("PERSISTED", "FAILED_KNOWN"),
            "PERSISTED", Set.of("DISPATCHING", "FAILED_KNOWN"),
            "DISPATCHING", Set.of("CONFIRMING", "FAILED_KNOWN", "UNKNOWN"),
            "CONFIRMING", Set.of("SUCCEEDED", "FAILED_KNOWN", "UNKNOWN"),
            "UNKNOWN", Set.of("RECONCILING"),
            "RECONCILING", Set.of("SUCCEEDED", "FAILED_KNOWN", "UNRESOLVED")
    );

    private TradingCommandStateMachine() {
    }

    public static void requireTransition(String current, String next) {
        if (current != null && current.equals(next)) {
            return;
        }
        if (!TRANSITIONS.getOrDefault(current, Set.of()).contains(next)) {
            throw new IllegalStateException(
                    "Illegal trading command transition: "
                            + current + " -> " + next
            );
        }
    }
}
