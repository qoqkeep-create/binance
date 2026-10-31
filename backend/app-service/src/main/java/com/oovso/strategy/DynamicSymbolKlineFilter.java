package com.oovso.strategy;

import com.oovso.market.MarketKline;
import com.oovso.market.MarketKlineService;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import org.springframework.stereotype.Component;
import org.ta4j.core.indicators.ATRIndicator;
import org.ta4j.core.indicators.adx.ADXIndicator;
import org.ta4j.core.indicators.averages.EMAIndicator;

@Component
public class DynamicSymbolKlineFilter {

    private static final int HOURS_PER_DAY = 24;

    private final SuperEmaPullbackStrategyProperties properties;

    public DynamicSymbolKlineFilter(SuperEmaPullbackStrategyProperties properties) {
        this.properties = properties;
    }

    public Decision evaluate(
            List<MarketKline> klines,
            EMAIndicator ema,
            ATRIndicator atr,
            ADXIndicator adx,
            int lastIndex,
            TrendDirection direction,
            String intervalCode
    ) {
        SuperEmaPullbackStrategyProperties.SymbolFilter filter = properties.getSymbolFilter();
        int lookbackDays = Math.max(1, filter.getKlineQualityLookbackDays());
        int barsPerDay = barsPerDay(intervalCode);
        int lookbackBars = lookbackDays * barsPerDay;
        if (klines.size() < lookbackBars || lastIndex < lookbackBars - 1) {
            return Decision.rejected("INSUFFICIENT_30D_KLINE_HISTORY");
        }

        BigDecimal medianDailyQuoteVolume = medianDailyQuoteVolume(
                klines,
                lookbackDays,
                barsPerDay
        );
        BigDecimal minimumMedian = filter.getMinMedianDailyQuoteVolume30d() == null
                ? BigDecimal.ZERO
                : filter.getMinMedianDailyQuoteVolume30d();
        if (medianDailyQuoteVolume.compareTo(minimumMedian) < 0) {
            return Decision.rejected("MEDIAN_DAILY_QUOTE_VOLUME_30D_TOO_LOW");
        }

        int abnormalCandles = abnormalCandleCount(
                klines,
                atr,
                lastIndex,
                lookbackBars,
                filter.getMaxAbnormalCandleAtrMultiple()
        );
        if (abnormalCandles > Math.max(0, filter.getMaxAbnormalCandleCount())) {
            return Decision.rejected("TOO_MANY_ABNORMAL_CANDLES");
        }

        int slopeLookbackBars = Math.max(1, filter.getEmaSlopeLookbackBars());
        if (lastIndex < slopeLookbackBars) {
            return Decision.rejected("INSUFFICIENT_EMA_SLOPE_HISTORY");
        }
        BigDecimal currentEma = decimal(ema.getValue(lastIndex).doubleValue());
        BigDecimal previousEma = decimal(ema.getValue(lastIndex - slopeLookbackBars).doubleValue());
        if (direction == TrendDirection.LONG && currentEma.compareTo(previousEma) <= 0) {
            return Decision.rejected("EMA144_SLOPE_NOT_LONG");
        }
        if (direction == TrendDirection.SHORT && currentEma.compareTo(previousEma) >= 0) {
            return Decision.rejected("EMA144_SLOPE_NOT_SHORT");
        }

        BigDecimal currentAdx = decimal(adx.getValue(lastIndex).doubleValue());
        if (currentAdx.compareTo(BigDecimal.valueOf(filter.getMinAdx())) < 0) {
            return Decision.rejected("ADX_TOO_LOW");
        }
        return Decision.accepted(medianDailyQuoteVolume, abnormalCandles, currentAdx);
    }

    static BigDecimal medianDailyQuoteVolume(List<MarketKline> klines, int lookbackDays) {
        return medianDailyQuoteVolume(klines, lookbackDays, HOURS_PER_DAY);
    }

    static BigDecimal medianDailyQuoteVolume(
            List<MarketKline> klines,
            int lookbackDays,
            int barsPerDay
    ) {
        int days = Math.max(1, lookbackDays);
        int dailyBars = Math.max(1, barsPerDay);
        List<BigDecimal> dailyVolumes = new ArrayList<>(days);
        for (int day = 0; day < days; day++) {
            int endExclusive = klines.size() - day * dailyBars;
            int startInclusive = endExclusive - dailyBars;
            if (startInclusive < 0) {
                break;
            }
            BigDecimal dailyVolume = klines.subList(startInclusive, endExclusive).stream()
                    .map(MarketKline::getQuoteVolume)
                    .filter(value -> value != null)
                    .reduce(BigDecimal.ZERO, BigDecimal::add);
            dailyVolumes.add(dailyVolume);
        }
        if (dailyVolumes.isEmpty()) {
            return BigDecimal.ZERO;
        }
        dailyVolumes.sort(Comparator.naturalOrder());
        int middle = dailyVolumes.size() / 2;
        if (dailyVolumes.size() % 2 == 1) {
            return dailyVolumes.get(middle);
        }
        return dailyVolumes.get(middle - 1)
                .add(dailyVolumes.get(middle))
                .divide(BigDecimal.valueOf(2), 8, RoundingMode.HALF_UP);
    }

    static int barsPerDay(String intervalCode) {
        long intervalMillis = MarketKlineService.intervalMillis(intervalCode);
        return (int) (Duration.ofDays(1).toMillis() / intervalMillis);
    }

    private int abnormalCandleCount(
            List<MarketKline> klines,
            ATRIndicator atr,
            int lastIndex,
            int lookbackBars,
            double atrMultiple
    ) {
        if (atrMultiple <= 0) {
            return 0;
        }
        int startIndex = Math.max(0, lastIndex - lookbackBars + 1);
        int count = 0;
        BigDecimal multiple = BigDecimal.valueOf(atrMultiple);
        for (int index = startIndex; index <= lastIndex; index++) {
            MarketKline kline = klines.get(index);
            if (kline.getHighPrice() == null || kline.getLowPrice() == null) {
                continue;
            }
            BigDecimal atrValue = decimal(atr.getValue(index).doubleValue());
            if (atrValue.signum() <= 0) {
                continue;
            }
            BigDecimal range = kline.getHighPrice().subtract(kline.getLowPrice());
            if (range.compareTo(atrValue.multiply(multiple)) > 0) {
                count++;
            }
        }
        return count;
    }

    private static BigDecimal decimal(double value) {
        return BigDecimal.valueOf(value).setScale(12, RoundingMode.HALF_UP);
    }

    public record Decision(
            boolean eligible,
            String rejectionReason,
            BigDecimal medianDailyQuoteVolume,
            int abnormalCandleCount,
            BigDecimal adx
    ) {

        private static Decision rejected(String reason) {
            return new Decision(false, reason, null, 0, null);
        }

        private static Decision accepted(
                BigDecimal medianDailyQuoteVolume,
                int abnormalCandleCount,
                BigDecimal adx
        ) {
            return new Decision(true, null, medianDailyQuoteVolume, abnormalCandleCount, adx);
        }
    }
}
