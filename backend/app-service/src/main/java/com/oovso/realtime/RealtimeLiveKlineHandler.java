package com.oovso.realtime;

import com.binance.connector.client.derivatives_trading_usds_futures.websocket.stream.model.ContinuousContractKlineCandlestickStreamsResponse;
import com.binance.connector.client.derivatives_trading_usds_futures.websocket.stream.model.ContinuousContractKlineCandlestickStreamsResponseK;
import com.oovso.binance.ContinuousKlineHandler;
import org.springframework.stereotype.Component;

@Component
public class RealtimeLiveKlineHandler implements ContinuousKlineHandler {

    private final RealtimeEventPublisher eventPublisher;

    public RealtimeLiveKlineHandler(RealtimeEventPublisher eventPublisher) {
        this.eventPublisher = eventPublisher;
    }

    @Override
    public void onKline(ContinuousContractKlineCandlestickStreamsResponse event) {
        ContinuousContractKlineCandlestickStreamsResponseK kline = event.getkLowerCase();
        if (kline == null || Boolean.TRUE.equals(kline.getxLowerCase())) {
            return;
        }
        String symbol = event.getPs();
        String interval = kline.getiLowerCase();
        if (!eventPublisher.hasSubscribers(
                RealtimeProtocol.CHANNEL_MARKET_KLINE,
                symbol,
                interval
        )) {
            return;
        }

        RealtimeKlinePayload payload = RealtimeKlinePayload.from(event, kline);
        eventPublisher.publishPublic(
                RealtimeProtocol.CHANNEL_MARKET_KLINE,
                "upsert",
                payload.streamKey(),
                payload.symbol(),
                payload.interval(),
                payload
        );
    }
}
