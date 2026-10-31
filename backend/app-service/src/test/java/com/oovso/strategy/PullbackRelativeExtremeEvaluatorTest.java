package com.oovso.strategy;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.oovso.market.MarketKline;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;

class PullbackRelativeExtremeEvaluatorTest {

    @Test
    void keepsLongTouchNearRecentLow() {
        var result = evaluate(
                TrendDirection.LONG,
                candles("103", "102", "101", "100.5", "100", "100.3")
        );

        assertTrue(result.eligible());
    }

    @Test
    void rejectsLongTouchThatIsAboveMostRecentLows() {
        var result = evaluate(
                TrendDirection.LONG,
                candles("100", "101", "102", "104", "105", "103")
        );

        assertFalse(result.eligible());
    }

    @Test
    void keepsShortTouchNearRecentHigh() {
        var result = evaluate(
                TrendDirection.SHORT,
                candles("100", "101", "102", "103", "104", "103.7")
        );

        assertTrue(result.eligible());
    }

    @Test
    void rejectsShortTouchThatIsBelowMostRecentHighs() {
        var result = evaluate(
                TrendDirection.SHORT,
                candles("105", "104", "103", "101", "100", "102")
        );

        assertFalse(result.eligible());
    }

    @Test
    void oneOldWickDoesNotRejectUsefulHigherLow() {
        var result = evaluate(
                TrendDirection.LONG,
                candles("95", "101", "102", "103", "104", "100.8")
        );

        assertTrue(result.eligible());
    }

    @Test
    void allowsEarlyTouchWhenTrendHasTooLittleHistory() {
        List<MarketKline> values = candles("101", "100.8", "102");
        var result = PullbackRelativeExtremeEvaluator.evaluate(
                values,
                2,
                1,
                TrendDirection.LONG,
                BigDecimal.ONE,
                5,
                3,
                0.6,
                0.5,
                0.005
        );

        assertTrue(result.eligible());
        assertTrue(result.comparisonBars() < 3);
    }

    private PullbackRelativeExtremeEvaluator.Result evaluate(
            TrendDirection direction,
            List<MarketKline> klines
    ) {
        return PullbackRelativeExtremeEvaluator.evaluate(
                klines,
                klines.size() - 1,
                0,
                direction,
                BigDecimal.ONE,
                5,
                3,
                0.6,
                0.5,
                0.005
        );
    }

    private List<MarketKline> candles(String... extremes) {
        List<MarketKline> result = new ArrayList<>();
        for (String extreme : extremes) {
            BigDecimal value = new BigDecimal(extreme);
            MarketKline kline = new MarketKline();
            kline.setLowPrice(value);
            kline.setHighPrice(value);
            result.add(kline);
        }
        return result;
    }
}
