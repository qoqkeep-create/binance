package com.oovso.realtime;

import com.binance.connector.client.derivatives_trading_usds_futures.websocket.stream.model.ContinuousContractKlineCandlestickStreamsResponse;
import com.binance.connector.client.derivatives_trading_usds_futures.websocket.stream.model.ContinuousContractKlineCandlestickStreamsResponseK;
import com.oovso.market.MarketKline;
import java.math.BigDecimal;
import java.util.Locale;

public record RealtimeKlinePayload(
        String symbol,
        String contractType,
        String interval,
        long eventTime,
        long openTime,
        long closeTime,
        BigDecimal openPrice,
        BigDecimal highPrice,
        BigDecimal lowPrice,
        BigDecimal closePrice,
        BigDecimal volume,
        BigDecimal quoteVolume,
        boolean closed
) {

    static RealtimeKlinePayload from(
            ContinuousContractKlineCandlestickStreamsResponse event,
            ContinuousContractKlineCandlestickStreamsResponseK kline
    ) {
        return new RealtimeKlinePayload(
                upper(event.getPs()),
                upper(event.getCt()),
                lower(kline.getiLowerCase()),
                value(event.getE()),
                value(kline.gettLowerCase()),
                value(kline.getT()),
                decimal(kline.getoLowerCase()),
                decimal(kline.gethLowerCase()),
                decimal(kline.getlLowerCase()),
                decimal(kline.getcLowerCase()),
                decimal(kline.getvLowerCase()),
                decimal(kline.getqLowerCase()),
                Boolean.TRUE.equals(kline.getxLowerCase())
        );
    }

    static RealtimeKlinePayload from(MarketKline kline) {
        return new RealtimeKlinePayload(
                upper(kline.getPair()),
                upper(kline.getContractType()),
                lower(kline.getIntervalCode()),
                value(kline.getEventTimeMs()),
                value(kline.getOpenTimeMs()),
                value(kline.getCloseTimeMs()),
                kline.getOpenPrice(),
                kline.getHighPrice(),
                kline.getLowPrice(),
                kline.getClosePrice(),
                kline.getVolume(),
                kline.getQuoteVolume(),
                true
        );
    }

    String streamKey() {
        return symbol + ':' + interval;
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : new BigDecimal(String.valueOf(value));
    }

    private static long value(Long value) {
        return value == null ? 0 : value;
    }

    private static String upper(String value) {
        return value == null ? "" : value.toUpperCase(Locale.ROOT);
    }

    private static String lower(String value) {
        return value == null ? "" : value.toLowerCase(Locale.ROOT);
    }
}
