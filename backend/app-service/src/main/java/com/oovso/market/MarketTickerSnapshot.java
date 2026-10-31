package com.oovso.market;

import com.oovso.binance.BinanceUsdmMarketDataClient.Ticker24h;
import java.math.BigDecimal;

public record MarketTickerSnapshot(
        String symbol,
        BigDecimal lastPrice,
        BigDecimal quoteVolume24h,
        BigDecimal priceChangePercent24h,
        long eventTime
) {

    public static MarketTickerSnapshot from(Ticker24h ticker) {
        return new MarketTickerSnapshot(
                ticker.pair(),
                ticker.lastPrice(),
                ticker.quoteVolume(),
                ticker.priceChangeRate().movePointRight(2),
                ticker.eventTime()
        );
    }
}
