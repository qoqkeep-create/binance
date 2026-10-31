package com.oovso.indicator;

import com.oovso.market.MarketKline;
import java.math.BigDecimal;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import org.springframework.stereotype.Component;
import org.ta4j.core.BarSeries;
import org.ta4j.core.BaseBarSeriesBuilder;

@Component
public class Ta4jKlineSeriesFactory {

    public BarSeries build(String name, List<MarketKline> klines, Duration timePeriod) {
        BarSeries series = new BaseBarSeriesBuilder()
                .withName(name)
                .build();
        for (MarketKline kline : klines) {
            long beginTimeMs = kline.getOpenTimeMs();
            long endTimeMs = beginTimeMs + timePeriod.toMillis();
            series.barBuilder()
                    .timePeriod(timePeriod)
                    .beginTime(Instant.ofEpochMilli(beginTimeMs))
                    .endTime(Instant.ofEpochMilli(endTimeMs))
                    .openPrice(valueOrZero(kline.getOpenPrice()))
                    .highPrice(valueOrZero(kline.getHighPrice()))
                    .lowPrice(valueOrZero(kline.getLowPrice()))
                    .closePrice(valueOrZero(kline.getClosePrice()))
                    .volume(valueOrZero(kline.getVolume()))
                    .amount(valueOrZero(kline.getQuoteVolume()))
                    .trades(kline.getTradeCount() == null ? 0L : kline.getTradeCount())
                    .add();
        }
        return series;
    }

    private BigDecimal valueOrZero(BigDecimal value) {
        return value == null ? BigDecimal.ZERO : value;
    }
}
