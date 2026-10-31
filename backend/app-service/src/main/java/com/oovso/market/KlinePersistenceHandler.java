package com.oovso.market;

import com.binance.connector.client.derivatives_trading_usds_futures.websocket.stream.model.ContinuousContractKlineCandlestickStreamsResponse;
import com.oovso.binance.ContinuousKlineHandler;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

@Component
public class KlinePersistenceHandler implements ContinuousKlineHandler {

    private static final Logger log = LoggerFactory.getLogger(KlinePersistenceHandler.class);

    private final MarketKlineService marketKlineService;

    public KlinePersistenceHandler(MarketKlineService marketKlineService) {
        this.marketKlineService = marketKlineService;
    }

    @Override
    public void onKline(ContinuousContractKlineCandlestickStreamsResponse event) {
        try {
            marketKlineService.saveClosedKline(event);
        } catch (Exception ex) {
            log.error("Failed to persist Binance closed kline for {}", event.getPs(), ex);
        }
    }
}
