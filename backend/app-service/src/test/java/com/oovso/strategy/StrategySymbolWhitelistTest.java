package com.oovso.strategy;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.oovso.binance.BinanceContinuousKlineProperties;
import java.util.List;
import org.junit.jupiter.api.Test;

class StrategySymbolWhitelistTest {

    @Test
    void buildsUsdcPairsAndFiltersInactiveContractsInConfiguredOrder() {
        SuperEmaPullbackStrategyProperties strategyProperties =
                new SuperEmaPullbackStrategyProperties();
        strategyProperties.setSymbolWhitelist(
                List.of("eth", "BTC", "ETH", "  sui  ", "ETC")
        );
        BinanceContinuousKlineProperties marketProperties =
                new BinanceContinuousKlineProperties();
        marketProperties.setQuoteAsset("usdc");

        StrategySymbolWhitelist whitelist = new StrategySymbolWhitelist(
                strategyProperties,
                marketProperties
        );

        assertEquals(
                List.of("ETHUSDC", "BTCUSDC", "SUIUSDC", "ETCUSDC"),
                whitelist.normalizedSymbolsInOrder()
        );
        assertEquals(
                List.of("ETHUSDC", "BTCUSDC", "SUIUSDC"),
                whitelist.activeSymbolsInOrder(
                        List.of("BTCUSDC", "SUIUSDC", "ETHUSDC")
                )
        );
        assertTrue(whitelist.contains("ethusdc"));
        assertFalse(whitelist.contains("ETHUSDT"));
    }

    @Test
    void changingQuoteAssetRebuildsEveryPair() {
        SuperEmaPullbackStrategyProperties strategyProperties =
                new SuperEmaPullbackStrategyProperties();
        strategyProperties.setSymbolWhitelist(List.of("BTC", "ETH"));
        BinanceContinuousKlineProperties marketProperties =
                new BinanceContinuousKlineProperties();
        marketProperties.setQuoteAsset("USDT");

        StrategySymbolWhitelist whitelist = new StrategySymbolWhitelist(
                strategyProperties,
                marketProperties
        );

        assertEquals("USDT", whitelist.quoteAsset());
        assertEquals(
                List.of("BTCUSDT", "ETHUSDT"),
                whitelist.normalizedSymbolsInOrder()
        );
    }
}
