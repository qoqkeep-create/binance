package com.oovso.strategy;

import com.oovso.indicator.Ta4jKlineSeriesFactory;
import com.oovso.market.MarketKline;
import com.oovso.market.MarketKlineService;
import java.math.BigDecimal;
import java.time.Duration;
import java.util.List;
import org.springframework.stereotype.Component;
import org.ta4j.core.BarSeries;
import org.ta4j.core.indicators.MACDIndicator;
import org.ta4j.core.indicators.averages.EMAIndicator;

/**
 * Detects whether the newest closed MACD histogram bar is closer to zero than
 * the immediately preceding bar.
 */
@Component
public class MacdMomentumDecayDetector {

    private static final String TRIGGER_CODE = "MACD_MOMENTUM_DECAY";

    private static final String TRIGGER_NAME = "MACD能量衰减";

    private final SuperEmaPullbackStrategyProperties properties;

    private final Ta4jKlineSeriesFactory seriesFactory;

    public MacdMomentumDecayDetector(
            SuperEmaPullbackStrategyProperties properties,
            Ta4jKlineSeriesFactory seriesFactory
    ) {
        this.properties = properties;
        this.seriesFactory = seriesFactory;
    }

    public DecayMatch detectDecay(List<MarketKline> klines, int index) {
        if (klines == null || index < 1 || index >= klines.size()) {
            return null;
        }

        SuperEmaPullbackStrategyProperties.IndicatorPeriods periods =
                properties.getIndicatorPeriods();
        int fastPeriod = Math.max(1, periods.getMacdShortPeriod());
        int slowPeriod = Math.max(fastPeriod + 1, periods.getMacdLongPeriod());
        int signalPeriod = Math.max(1, periods.getMacdSignalPeriod());
        double[] latestHistogram = latestHistogram(
                klines,
                index,
                fastPeriod,
                slowPeriod,
                signalPeriod
        );
        if (latestHistogram == null
                || !isCloserToZero(latestHistogram[0], latestHistogram[1])) {
            return null;
        }
        return new DecayMatch(TRIGGER_CODE, TRIGGER_NAME, 76.0);
    }

    boolean isCloserToZero(double previous, double current) {
        return Double.isFinite(previous)
                && Double.isFinite(current)
                && Math.abs(current) < Math.abs(previous);
    }

    private double[] latestHistogram(
            List<MarketKline> klines,
            int endIndex,
            int fastPeriod,
            int slowPeriod,
            int signalPeriod
    ) {
        for (int index = 0; index <= endIndex; index++) {
            BigDecimal close = klines.get(index).getClosePrice();
            if (close == null || close.signum() <= 0) {
                return null;
            }
        }
        BarSeries series = seriesFactory.build(
                "secondary-alert-macd",
                klines.subList(0, endIndex + 1),
                Duration.ofMillis(MarketKlineService.intervalMillis(
                        klines.get(endIndex).getIntervalCode()
                ))
        );
        MACDIndicator macd = new MACDIndicator(
                new org.ta4j.core.indicators.helpers.ClosePriceIndicator(series),
                fastPeriod,
                slowPeriod
        );
        EMAIndicator signal = new EMAIndicator(macd, signalPeriod);
        return new double[] {
            histogramValue(macd, signal, endIndex - 1),
            histogramValue(macd, signal, endIndex)
        };
    }

    private double histogramValue(
            MACDIndicator macd,
            EMAIndicator signal,
            int index
    ) {
        return macd.getValue(index)
                .minus(signal.getValue(index))
                .doubleValue();
    }

    public record DecayMatch(
            String triggerCode,
            String triggerName,
            double score
    ) {
    }
}
