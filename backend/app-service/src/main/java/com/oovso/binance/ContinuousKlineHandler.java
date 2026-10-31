package com.oovso.binance;

import com.binance.connector.client.derivatives_trading_usds_futures.websocket.stream.model.ContinuousContractKlineCandlestickStreamsResponse;

@FunctionalInterface
public interface ContinuousKlineHandler {

    void onKline(ContinuousContractKlineCandlestickStreamsResponse event);
}
