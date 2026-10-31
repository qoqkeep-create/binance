package com.oovso.realtime;

import com.oovso.binance.BinanceMarketTicker;
import com.oovso.binance.MarketTickerHandler;
import com.oovso.market.MarketTickerSnapshot;
import org.springframework.stereotype.Component;

@Component
public class RealtimeMarketTickerHandler implements MarketTickerHandler {

    private final RealtimeEventPublisher eventPublisher;

    public RealtimeMarketTickerHandler(RealtimeEventPublisher eventPublisher) {
        this.eventPublisher = eventPublisher;
    }

    @Override
    public void onTicker(BinanceMarketTicker ticker) {
        if (!eventPublisher.hasSubscribers(
                RealtimeProtocol.CHANNEL_MARKET_TICKER,
                ticker.symbol(),
                null
        )) {
            return;
        }

        MarketTickerSnapshot payload = new MarketTickerSnapshot(
                ticker.symbol(),
                ticker.lastPrice(),
                ticker.quoteVolume24h(),
                ticker.priceChangePercent24h(),
                ticker.eventTime()
        );
        eventPublisher.publishPublic(
                RealtimeProtocol.CHANNEL_MARKET_TICKER,
                "update",
                ticker.symbol(),
                ticker.symbol(),
                null,
                payload
        );
    }
}
