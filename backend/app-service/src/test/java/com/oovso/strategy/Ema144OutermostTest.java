package com.oovso.strategy;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.math.BigDecimal;
import org.junit.jupiter.api.Test;

class Ema144OutermostTest {

    @Test
    void requiresEma144BelowEma55AndEma21ForLong() {
        assertTrue(SuperEmaPullbackStrategy.isEma144Outermost(
                new BigDecimal("102"),
                new BigDecimal("103"),
                new BigDecimal("100"),
                TrendDirection.LONG
        ));
        assertFalse(SuperEmaPullbackStrategy.isEma144Outermost(
                new BigDecimal("103"),
                new BigDecimal("99"),
                new BigDecimal("100"),
                TrendDirection.LONG
        ));
    }

    @Test
    void requiresEma144AboveEma55AndEma21ForShort() {
        assertTrue(SuperEmaPullbackStrategy.isEma144Outermost(
                new BigDecimal("98"),
                new BigDecimal("97"),
                new BigDecimal("100"),
                TrendDirection.SHORT
        ));
        assertFalse(SuperEmaPullbackStrategy.isEma144Outermost(
                new BigDecimal("101"),
                new BigDecimal("98"),
                new BigDecimal("100"),
                TrendDirection.SHORT
        ));
    }
}
