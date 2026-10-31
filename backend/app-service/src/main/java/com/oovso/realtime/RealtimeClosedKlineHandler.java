package com.oovso.realtime;

import com.oovso.market.MarketClosedKlineEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;

@Component
public class RealtimeClosedKlineHandler {

    private final RealtimeEventPublisher eventPublisher;

    public RealtimeClosedKlineHandler(RealtimeEventPublisher eventPublisher) {
        this.eventPublisher = eventPublisher;
    }

    @EventListener
    public void onClosedKline(MarketClosedKlineEvent event) {
        RealtimeKlinePayload payload = RealtimeKlinePayload.from(event.kline());
        if (!eventPublisher.hasSubscribers(
                RealtimeProtocol.CHANNEL_MARKET_KLINE,
                payload.symbol(),
                payload.interval()
        )) {
            return;
        }
        eventPublisher.publishPublic(
                RealtimeProtocol.CHANNEL_MARKET_KLINE,
                "closed",
                payload.streamKey(),
                payload.symbol(),
                payload.interval(),
                payload
        );
    }
}
