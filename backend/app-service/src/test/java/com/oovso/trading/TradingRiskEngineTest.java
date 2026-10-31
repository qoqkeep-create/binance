package com.oovso.trading;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.oovso.trading.BinanceUsdmPrivateGateway.SymbolRules;
import java.math.BigDecimal;
import org.junit.jupiter.api.Test;

class TradingRiskEngineTest {

    @Test
    void sizesLinearLongPositionFromConfiguredRAndRoundsDown() {
        TradingRiskEngine.EntrySizing sizing = TradingRiskEngine.sizeEntry(
                "LONG",
                "LIMIT",
                bd("100.07"),
                bd("101"),
                bd("95.01"),
                bd("50"),
                rules()
        );

        assertDecimal("100", sizing.referenceEntryPrice());
        assertDecimal("95.1", sizing.initialStopPrice());
        assertDecimal("4.9", sizing.riskPerUnit());
        assertDecimal("10.2", sizing.quantity());
        assertDecimal("49.98", sizing.plannedRiskAmount());
    }

    @Test
    void marketSizingUsesServerPriceAndMarketLotStep() {
        TradingRiskEngine.EntrySizing sizing = TradingRiskEngine.sizeEntry(
                "SHORT",
                "MARKET",
                null,
                bd("100"),
                bd("105.09"),
                bd("25"),
                rules()
        );

        assertDecimal("100", sizing.referenceEntryPrice());
        assertEquals(null, sizing.normalizedRequestedEntryPrice());
        assertDecimal("105", sizing.initialStopPrice());
        assertDecimal("5", sizing.riskPerUnit());
        assertDecimal("5", sizing.quantity());
    }

    @Test
    void rejectsStopOnWrongSide() {
        assertThrows(IllegalArgumentException.class, () ->
                TradingRiskEngine.sizeEntry(
                        "LONG",
                        "MARKET",
                        null,
                        bd("100"),
                        bd("101"),
                        bd("10"),
                        rules()
                )
        );
    }

    @Test
    void ratchetNeverWidensAndNeverCrossesCurrentPrice() {
        assertDecimal(
                "98",
                TradingRiskEngine.ratchetStop(
                        "LONG",
                        bd("98"),
                        bd("97"),
                        bd("105"),
                        bd("0.1")
                )
        );
        assertDecimal(
                "104.9",
                TradingRiskEngine.ratchetStop(
                        "LONG",
                        bd("98"),
                        bd("110"),
                        bd("105"),
                        bd("0.1")
                )
        );
        assertDecimal(
                "102",
                TradingRiskEngine.ratchetStop(
                        "SHORT",
                        bd("102"),
                        bd("104"),
                        bd("95"),
                        bd("0.1")
                )
        );

        for (int index = -999; index <= 1_000; index++) {
            BigDecimal candidate = bd("100").add(
                    bd("0.1").multiply(BigDecimal.valueOf(index))
            );
            BigDecimal longStop = TradingRiskEngine.ratchetStop(
                    "LONG",
                    bd("98"),
                    candidate,
                    bd("105"),
                    bd("0.1")
            );
            BigDecimal shortStop = TradingRiskEngine.ratchetStop(
                    "SHORT",
                    bd("102"),
                    candidate,
                    bd("95"),
                    bd("0.1")
            );
            assertTrue(longStop.compareTo(bd("98")) >= 0);
            assertTrue(longStop.compareTo(bd("105")) < 0);
            assertTrue(shortStop.compareTo(bd("102")) <= 0);
            assertTrue(shortStop.compareTo(bd("95")) > 0);
        }
    }

    @Test
    void computesTrailingFallbackAndReductionFromInitialRGeometry() {
        assertDecimal(
                "108",
                TradingRiskEngine.trailingStop(
                        "LONG",
                        bd("110"),
                        bd("2"),
                        bd("1")
                )
        );
        assertDecimal(
                "96",
                TradingRiskEngine.fallbackStop(
                        "LONG",
                        bd("98"),
                        bd("2"),
                        bd("2"),
                        bd("0.1")
                )
        );
        assertDecimal(
                "2.5",
                TradingRiskEngine.reductionQuantity(
                        bd("10"),
                        bd("25"),
                        bd("8"),
                        bd("0.1")
                )
        );
        assertDecimal(
                "2.5",
                TradingRiskEngine.plannedReductionQuantity(
                        bd("10"),
                        bd("25"),
                        bd("0.1")
                )
        );
        assertDecimal(
                "1",
                TradingRiskEngine.reductionQuantity(
                        bd("10"),
                        bd("25"),
                        bd("1"),
                        bd("0.1")
                )
        );
        assertDecimal(
                "5",
                TradingRiskEngine.profitR(
                        "LONG",
                        bd("100"),
                        bd("110"),
                        bd("2")
                )
        );
    }

    private SymbolRules rules() {
        return new SymbolRules(
                "BTCUSDC",
                "TRADING",
                "BTC",
                "USDC",
                bd("0.1"),
                bd("0.1"),
                bd("1000"),
                bd("0.1"),
                bd("0.01"),
                bd("1000"),
                bd("0.01"),
                bd("5")
        );
    }

    private BigDecimal bd(String value) {
        return new BigDecimal(value);
    }

    private void assertDecimal(String expected, BigDecimal actual) {
        assertEquals(0, bd(expected).compareTo(actual));
    }
}
