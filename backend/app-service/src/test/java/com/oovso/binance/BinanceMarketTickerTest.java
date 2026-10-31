package com.oovso.binance;

import static org.junit.jupiter.api.Assertions.assertEquals;

import com.binance.connector.client.derivatives_trading_usds_futures.websocket.stream.model.AllMarketTickersStreamsResponseInner;
import java.math.BigDecimal;
import org.junit.jupiter.api.Test;

class BinanceMarketTickerTest {

    @Test
    void mapsAllMarketTickerFieldsWithoutChangingPercentUnits() {
        AllMarketTickersStreamsResponseInner source =
                new AllMarketTickersStreamsResponseInner();
        source.setsLowerCase("btcusdc");
        source.setcLowerCase("118425.50");
        source.setqLowerCase("1468362.20");
        source.setP("-1.08");
        source.setE(1_785_231_000_100L);

        BinanceMarketTicker ticker = BinanceMarketTicker.from(source);

        assertEquals("BTCUSDC", ticker.symbol());
        assertEquals(new BigDecimal("118425.50"), ticker.lastPrice());
        assertEquals(new BigDecimal("1468362.20"), ticker.quoteVolume24h());
        assertEquals(new BigDecimal("-1.08"), ticker.priceChangePercent24h());
        assertEquals(1_785_231_000_100L, ticker.eventTime());
    }
}
