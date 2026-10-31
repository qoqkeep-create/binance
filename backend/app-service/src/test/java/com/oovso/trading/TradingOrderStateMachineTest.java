package com.oovso.trading;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.math.BigDecimal;
import org.junit.jupiter.api.Test;

class TradingOrderStateMachineTest {

    @Test
    void regularOrderProgressesWithoutAllowingLateStateRegression() {
        TradingOrderStateMachine.MergeDecision partial =
                TradingOrderStateMachine.mergeRegular(
                        "LIVE",
                        BigDecimal.ZERO,
                        100,
                        "PARTIALLY_FILLED",
                        new BigDecimal("0.25"),
                        200
                );
        assertEquals("PARTIALLY_FILLED", partial.state());
        assertTrue(partial.acceptPayload());

        TradingOrderStateMachine.MergeDecision lateNew =
                TradingOrderStateMachine.mergeRegular(
                        partial.state(),
                        new BigDecimal("0.25"),
                        200,
                        "NEW",
                        BigDecimal.ZERO,
                        100
                );
        assertEquals("PARTIALLY_FILLED", lateNew.state());
        assertFalse(lateNew.acceptPayload());
    }

    @Test
    void terminalOrderKeepsStateButAcceptsLateAdditionalFillQuantity() {
        TradingOrderStateMachine.MergeDecision decision =
                TradingOrderStateMachine.mergeRegular(
                        "CANCELED",
                        new BigDecimal("0.25"),
                        300,
                        "PARTIALLY_FILLED",
                        new BigDecimal("0.30"),
                        250
                );

        assertEquals("CANCELED", decision.state());
        assertTrue(decision.acceptPayload());
    }

    @Test
    void algoOrderCannotRegressFromTriggeredToNew() {
        TradingOrderStateMachine.MergeDecision decision =
                TradingOrderStateMachine.mergeAlgo(
                        "TRIGGERED",
                        200,
                        "NEW",
                        100
                );

        assertEquals("TRIGGERED", decision.state());
        assertFalse(decision.acceptPayload());
    }

    @Test
    void algoCanJumpDirectlyFromNewToFinishedAfterStreamGap() {
        TradingOrderStateMachine.MergeDecision decision =
                TradingOrderStateMachine.mergeAlgo(
                        "NEW",
                        100,
                        "FINISHED",
                        200
                );

        assertEquals("FINISHED", decision.state());
        assertTrue(decision.acceptPayload());
    }

    @Test
    void commandStateMachineRejectsBlindUnknownToDispatchRetry() {
        assertThrows(
                IllegalStateException.class,
                () -> TradingCommandStateMachine.requireTransition(
                        "UNKNOWN",
                        "DISPATCHING"
                )
        );
        TradingCommandStateMachine.requireTransition(
                "UNKNOWN",
                "RECONCILING"
        );
    }
}
