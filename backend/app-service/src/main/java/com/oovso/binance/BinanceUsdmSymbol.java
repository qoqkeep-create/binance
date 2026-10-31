package com.oovso.binance;

public record BinanceUsdmSymbol(
        String pair,
        String contractType,
        long onboardDate
) {
}
