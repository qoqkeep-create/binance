package com.oovso.trading;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertThrows;

import org.junit.jupiter.api.Test;

class TradingCommandStateMachineTest {

    @Test
    void acceptedCommandCanReachSuccessOnlyThroughConfirmation() {
        assertDoesNotThrow(() -> {
            TradingCommandStateMachine.requireTransition(
                    "PERSISTED",
                    "DISPATCHING"
            );
            TradingCommandStateMachine.requireTransition(
                    "DISPATCHING",
                    "CONFIRMING"
            );
            TradingCommandStateMachine.requireTransition(
                    "CONFIRMING",
                    "SUCCEEDED"
            );
        });
        assertThrows(IllegalStateException.class, () ->
                TradingCommandStateMachine.requireTransition(
                        "PERSISTED",
                        "SUCCEEDED"
                )
        );
    }

    @Test
    void unknownOutcomeMustReconcileAndCannotBeBlindlyRedispatched() {
        assertDoesNotThrow(() -> {
            TradingCommandStateMachine.requireTransition(
                    "CONFIRMING",
                    "UNKNOWN"
            );
            TradingCommandStateMachine.requireTransition(
                    "UNKNOWN",
                    "RECONCILING"
            );
            TradingCommandStateMachine.requireTransition(
                    "RECONCILING",
                    "UNRESOLVED"
            );
        });
        assertThrows(IllegalStateException.class, () ->
                TradingCommandStateMachine.requireTransition(
                        "UNKNOWN",
                        "DISPATCHING"
                )
        );
    }
}
