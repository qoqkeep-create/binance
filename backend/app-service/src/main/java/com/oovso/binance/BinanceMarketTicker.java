package com.oovso.binance;

import com.binance.connector.client.derivatives_trading_usds_futures.websocket.stream.model.AllMarketTickersStreamsResponseInner;
import java.math.BigDecimal;
import java.util.Locale;
import org.springframework.util.StringUtils;

public record BinanceMarketTicker(
        String symbol,
        BigDecimal lastPrice,
        BigDecimal quoteVolume24h,
        BigDecimal priceChangePercent24h,
        long eventTime
) {

    static BinanceMarketTicker from(AllMarketTickersStreamsResponseInner ticker) {
        return new BinanceMarketTicker(
                normalize(ticker.getsLowerCase()),
                decimal(ticker.getcLowerCase()),
                decimal(ticker.getqLowerCase()),
                decimal(ticker.getP()),
                ticker.getE() == null ? System.currentTimeMillis() : ticker.getE()
        );
    }

    private static String normalize(String value) {
        return StringUtils.hasText(value)
                ? value.trim().toUpperCase(Locale.ROOT)
                : "";
    }

    private static BigDecimal decimal(String value) {
        return StringUtils.hasText(value)
                ? new BigDecimal(value)
                : BigDecimal.ZERO;
    }
}
