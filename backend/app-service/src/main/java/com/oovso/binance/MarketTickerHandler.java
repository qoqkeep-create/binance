package com.oovso.binance;

@FunctionalInterface
public interface MarketTickerHandler {

    void onTicker(BinanceMarketTicker ticker);
}
