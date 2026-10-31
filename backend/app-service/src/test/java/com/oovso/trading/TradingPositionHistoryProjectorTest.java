package com.oovso.trading;

import static org.junit.jupiter.api.Assertions.assertEquals;

import com.oovso.trading.TradingPositionHistoryProjector.HistoryPosition;
import com.oovso.trading.TradingPositionHistoryProjector.OpenPosition;
import java.math.BigDecimal;
import java.util.List;
import org.junit.jupiter.api.Test;

class TradingPositionHistoryProjectorTest {

    @Test
    void aggregatesOnePositionCycleIncludingEveryCommission() {
        List<HistoryPosition> history = TradingPositionHistoryProjector.project(
                List.of(
                        fill("1", "BUY", "BOTH", "1", "100", "0.10", "0", 1),
                        fill("2", "BUY", "BOTH", "0.5", "110", "0.05", "0", 2),
                        fill("3", "SELL", "BOTH", "0.4", "120", "0.04", "8", 3),
                        fill("4", "SELL", "BOTH", "1.1", "90", "0.11", "-11", 4)
                ),
                20
        );

        assertEquals(1, history.size());
        HistoryPosition position = history.getFirst();
        assertEquals("LONG", position.direction());
        decimal("1.5", position.maximumQuantity());
        decimal("103.333333333333333333", position.entryPrice());
        decimal("98", position.closePrice());
        decimal("-3", position.realizedPnl());
        assertEquals(1, position.fees().size());
        assertEquals("USDC", position.fees().getFirst().asset());
        decimal("0.30", position.fees().getFirst().amount());
        assertEquals(4, position.fillCount());
        assertEquals(1, position.openedAtMillis());
        assertEquals(4, position.closedAtMillis());
    }

    @Test
    void splitsReversalFillBetweenClosedLongAndNewShort() {
        List<HistoryPosition> history = TradingPositionHistoryProjector.project(
                List.of(
                        fill("1", "BUY", "BOTH", "1", "100", "0.10", "0", 1),
                        fill("2", "SELL", "BOTH", "2", "110", "0.20", "10", 2),
                        fill("3", "BUY", "BOTH", "1", "105", "0.10", "5", 3)
                ),
                20
        );

        assertEquals(2, history.size());
        HistoryPosition shortPosition = history.getFirst();
        assertEquals("SHORT", shortPosition.direction());
        decimal("110", shortPosition.entryPrice());
        decimal("105", shortPosition.closePrice());
        decimal("5", shortPosition.realizedPnl());
        decimal("0.20", shortPosition.fees().getFirst().amount());

        HistoryPosition longPosition = history.get(1);
        assertEquals("LONG", longPosition.direction());
        decimal("10", longPosition.realizedPnl());
        decimal("0.20", longPosition.fees().getFirst().amount());
    }

    @Test
    void usesHedgePositionSideToRecognizeShortLifecycle() {
        List<HistoryPosition> history = TradingPositionHistoryProjector.project(
                List.of(
                        fill("1", "SELL", "SHORT", "2", "100", "0.2", "0", 1),
                        fill("2", "BUY", "SHORT", "2", "90", "0.2", "20", 2)
                ),
                20
        );

        assertEquals(1, history.size());
        assertEquals("SHORT", history.getFirst().direction());
        decimal("20", history.getFirst().realizedPnl());
    }

    @Test
    void ordersFillsAtSameMillisecondByNumericExchangeTradeId() {
        List<HistoryPosition> history = TradingPositionHistoryProjector.project(
                List.of(
                        fill("9", "BUY", "BOTH", "1", "100", "0.1", "0", 1),
                        fill("10", "SELL", "BOTH", "1", "101", "0.1", "1", 1)
                ),
                20
        );

        assertEquals(1, history.size());
        assertEquals("LONG", history.getFirst().direction());
    }

    @Test
    void ignoresClosingFillObservedBeforeItsOpeningLifecycle() {
        List<HistoryPosition> history = TradingPositionHistoryProjector.project(
                List.of(
                        fill("1", "SELL", "BOTH", "1", "100", "0.1", "5", 1),
                        fill("2", "BUY", "BOTH", "1", "90", "0.1", "0", 2)
                ),
                20
        );

        assertEquals(0, history.size());
    }

    @Test
    void projectsCurrentCycleRealizedPnlAndAllocatedFillDetails() {
        List<OpenPosition> open = TradingPositionHistoryProjector.projectOpen(
                List.of(
                        fill("1", "BUY", "BOTH", "1", "100", "0.10", "0", 1),
                        fill("2", "SELL", "BOTH", "0.4", "120", "0.04", "8", 2),
                        fill("3", "BUY", "BOTH", "0.2", "110", "0.02", "0", 3)
                )
        );

        assertEquals(1, open.size());
        OpenPosition position = open.getFirst();
        assertEquals("LONG", position.direction());
        decimal("0.8", position.currentQuantity());
        decimal("8", position.realizedPnl());
        decimal("0.16", position.fees().getFirst().amount());
        assertEquals(3, position.fills().size());
        decimal("0.4", position.fills().get(1).quantity());
        decimal("8", position.fills().get(1).realizedPnl());
    }

    private ExchangeFill fill(
            String id,
            String side,
            String positionSide,
            String quantity,
            String price,
            String commission,
            String realizedPnl,
            long time
    ) {
        ExchangeFill fill = new ExchangeFill();
        fill.setId(id);
        fill.setSymbol("BTCUSDC");
        fill.setTradeId(id);
        fill.setSide(side);
        fill.setPositionSide(positionSide);
        fill.setQuantity(new BigDecimal(quantity));
        fill.setPrice(new BigDecimal(price));
        fill.setCommission(new BigDecimal(commission));
        fill.setCommissionAsset("USDC");
        fill.setRealizedPnl(new BigDecimal(realizedPnl));
        fill.setTradeTimeMs(time);
        return fill;
    }

    private void decimal(String expected, BigDecimal actual) {
        assertEquals(0, new BigDecimal(expected).compareTo(actual));
    }
}
