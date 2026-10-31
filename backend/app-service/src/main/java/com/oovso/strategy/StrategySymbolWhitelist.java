package com.oovso.strategy;

import com.oovso.binance.BinanceContinuousKlineProperties;
import java.util.Collection;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;

@Component
public class StrategySymbolWhitelist {

    private final SuperEmaPullbackStrategyProperties strategyProperties;

    private final BinanceContinuousKlineProperties marketProperties;

    public StrategySymbolWhitelist(
            SuperEmaPullbackStrategyProperties strategyProperties,
            BinanceContinuousKlineProperties marketProperties
    ) {
        this.strategyProperties = strategyProperties;
        this.marketProperties = marketProperties;
    }

    public String quoteAsset() {
        String quoteAsset = normalize(marketProperties.getQuoteAsset());
        if (!StringUtils.hasText(quoteAsset)) {
            throw new IllegalStateException("Binance quote asset must not be blank");
        }
        return quoteAsset;
    }

    public boolean contains(String pair) {
        return normalizedSymbolsInOrder().contains(normalize(pair));
    }

    public List<String> normalizedSymbolsInOrder() {
        String quoteAsset = quoteAsset();
        return configuredBaseAssetsInOrder().stream()
                .map(baseAsset -> baseAsset + quoteAsset)
                .toList();
    }

    public List<String> activeSymbolsInOrder(
            Collection<String> activeSymbols
    ) {
        Set<String> normalizedActiveSymbols = new HashSet<>();
        if (activeSymbols != null) {
            activeSymbols.stream()
                    .map(StrategySymbolWhitelist::normalize)
                    .filter(StringUtils::hasText)
                    .forEach(normalizedActiveSymbols::add);
        }

        return normalizedSymbolsInOrder().stream()
                .filter(normalizedActiveSymbols::contains)
                .toList();
    }

    private List<String> configuredBaseAssetsInOrder() {
        String quoteAsset = quoteAsset();
        return strategyProperties.getSymbolWhitelist().stream()
                .map(StrategySymbolWhitelist::normalize)
                .filter(StringUtils::hasText)
                .map(symbol -> stripQuoteAsset(symbol, quoteAsset))
                .filter(StringUtils::hasText)
                .distinct()
                .toList();
    }

    private static String stripQuoteAsset(
            String symbol,
            String quoteAsset
    ) {
        if (symbol.endsWith(quoteAsset)
                && symbol.length() > quoteAsset.length()) {
            return symbol.substring(
                    0,
                    symbol.length() - quoteAsset.length()
            );
        }
        return symbol;
    }

    private static String normalize(String value) {
        return value == null
                ? ""
                : value.trim().toUpperCase(Locale.ROOT);
    }
}
