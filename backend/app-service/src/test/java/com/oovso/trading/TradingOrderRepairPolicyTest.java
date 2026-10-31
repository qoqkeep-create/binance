package com.oovso.trading;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.math.BigDecimal;
import org.junit.jupiter.api.Test;

class TradingOrderRepairPolicyTest {

    @Test
    void classifiesKnownFailuresForRepairAndUnknownWritesForReconciliation() {
        assertEquals(
                TradingOrderRepairPolicy.Health.REPAIR,
                TradingOrderRepairPolicy.algoHealth("REJECTED")
        );
        assertEquals(
                TradingOrderRepairPolicy.Health.REPAIR,
                TradingOrderRepairPolicy.regularHealth("CANCELED")
        );
        assertEquals(
                TradingOrderRepairPolicy.Health.RECONCILE,
                TradingOrderRepairPolicy.algoHealth("UNKNOWN")
        );
        assertEquals(
                TradingOrderRepairPolicy.Health.RECONCILE,
                TradingOrderRepairPolicy.regularHealth("SUBMITTING")
        );
    }

    @Test
    void healthCheckAndRetryBackoffAreBounded() {
        assertTrue(TradingOrderRepairPolicy.checkDue(null, 5_000, 10_000));
        assertFalse(TradingOrderRepairPolicy.checkDue(8_000L, 5_000, 10_000));
        assertEquals(
                25_000,
                TradingOrderRepairPolicy.nextRetryMillis(10_000, 15_000, 1)
        );
        assertEquals(
                250_000,
                TradingOrderRepairPolicy.nextRetryMillis(10_000, 15_000, 99)
        );
    }

    @Test
    void replacementReductionSubtractsEarlierPartialFills() {
        BigDecimal cumulative = TradingOrderRepairPolicy.cumulativeExecuted(
                bd("2.5"),
                bd("1.25")
        );
        assertDecimal("3.75", cumulative);
        assertDecimal(
                "1.2",
                TradingOrderRepairPolicy.remainingReduction(
                        bd("5"),
                        cumulative,
                        bd("9"),
                        bd("0.1")
                )
        );
        assertDecimal(
                "0.7",
                TradingOrderRepairPolicy.remainingReduction(
                        bd("5"),
                        cumulative,
                        bd("0.78"),
                        bd("0.1")
                )
        );
    }

    private BigDecimal bd(String value) {
        return new BigDecimal(value);
    }

    private void assertDecimal(String expected, BigDecimal actual) {
        assertEquals(0, bd(expected).compareTo(actual));
    }
}
