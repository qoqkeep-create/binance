package com.oovso.strategy;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

import com.oovso.binance.BinanceUsdmMarketDataClient.BookTicker;
import com.oovso.binance.BinanceUsdmMarketDataClient.OpenInterestStats;
import com.oovso.binance.BinanceUsdmMarketDataClient.PremiumIndex;
import com.oovso.binance.BinanceUsdmMarketDataClient.Ticker24h;
import com.oovso.binance.BinanceUsdmSymbol;
import java.math.BigDecimal;
import java.time.Duration;
import org.junit.jupiter.api.Test;

class StrategySymbolEligibilityServiceTest {

    @Test
    void acceptsLiquidMatureSymbolWithNormalDerivativesMetrics() {
        SuperEmaPullbackStrategyProperties.SymbolFilter properties =
                new SuperEmaPullbackStrategyProperties.SymbolFilter();
        long now = System.currentTimeMillis();
        BinanceUsdmSymbol symbol = new BinanceUsdmSymbol(
                "BTCUSDC",
                "PERPETUAL",
                now - Duration.ofDays(365).toMillis()
        );

        String baseReason = StrategySymbolEligibilityService.baseRejectionReason(
                symbol,
                new Ticker24h(
                        "BTCUSDC",
                        new BigDecimal("120000"),
                        new BigDecimal("100000000"),
                        new BigDecimal("0.05"),
                        1_000
                ),
                new BookTicker("BTCUSDC", new BigDecimal("100"), new BigDecimal("100.01")),
                new PremiumIndex("BTCUSDC", new BigDecimal("100"), new BigDecimal("0.0001")),
                properties,
                now
        );
        String openInterestReason = StrategySymbolEligibilityService.openInterestRejectionReason(
                new OpenInterestStats("BTCUSDC", new BigDecimal("50000000"), new BigDecimal("0.10")),
                properties
        );

        assertNull(baseReason);
        assertNull(openInterestReason);
    }

    @Test
    void rejectsNewSymbolAndExtremeOpenInterestChange() {
        SuperEmaPullbackStrategyProperties.SymbolFilter properties =
                new SuperEmaPullbackStrategyProperties.SymbolFilter();
        long now = System.currentTimeMillis();
        BinanceUsdmSymbol symbol = new BinanceUsdmSymbol(
                "NEWUSDC",
                "PERPETUAL",
                now - Duration.ofDays(30).toMillis()
        );

        String baseReason = StrategySymbolEligibilityService.baseRejectionReason(
                symbol,
                new Ticker24h(
                        "NEWUSDC",
                        new BigDecimal("1.25"),
                        new BigDecimal("100000000"),
                        new BigDecimal("0.05"),
                        1_000
                ),
                new BookTicker("NEWUSDC", new BigDecimal("100"), new BigDecimal("100.01")),
                new PremiumIndex("NEWUSDC", new BigDecimal("100"), new BigDecimal("0.0001")),
                properties,
                now
        );
        String openInterestReason = StrategySymbolEligibilityService.openInterestRejectionReason(
                new OpenInterestStats("NEWUSDC", new BigDecimal("50000000"), new BigDecimal("0.50")),
                properties
        );

        assertEquals("LISTING_TOO_NEW", baseReason);
        assertEquals("OPEN_INTEREST_CHANGE_24H_TOO_LARGE", openInterestReason);
    }
}
