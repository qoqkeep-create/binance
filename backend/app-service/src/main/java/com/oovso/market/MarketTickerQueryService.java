package com.oovso.market;

import com.oovso.binance.BinanceUsdmMarketDataClient;
import com.oovso.binance.BinanceUsdmMarketDataClient.Ticker24h;
import com.oovso.binance.BinanceUsdmSymbol;
import com.oovso.strategy.StrategySymbolWhitelist;
import java.io.IOException;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import org.springframework.stereotype.Service;
import org.springframework.util.StringUtils;

@Service
public class MarketTickerQueryService {

    private static final long SNAPSHOT_TTL_MILLIS = 5_000;

    private static final Comparator<MarketTickerSnapshot> VOLUME_ORDER =
            Comparator.comparing(
                            MarketTickerSnapshot::quoteVolume24h,
                            Comparator.nullsFirst(Comparator.naturalOrder())
                    )
                    .reversed()
                    .thenComparing(MarketTickerSnapshot::symbol);

    private final BinanceUsdmMarketDataClient marketDataClient;

    private final StrategySymbolWhitelist symbolWhitelist;

    private final Object snapshotMonitor = new Object();

    private volatile CachedSnapshot cachedSnapshot = CachedSnapshot.empty();

    public MarketTickerQueryService(
            BinanceUsdmMarketDataClient marketDataClient,
            StrategySymbolWhitelist symbolWhitelist
    ) {
        this.marketDataClient = marketDataClient;
        this.symbolWhitelist = symbolWhitelist;
    }

    public MarketTickerCollection all()
            throws IOException, InterruptedException {
        CachedSnapshot snapshot = snapshot();
        return new MarketTickerCollection(
                snapshot.quoteAsset(),
                snapshot.tickers()
        );
    }

    public MarketTickerPage query(
            String rawQuery,
            int page,
            int size
    ) throws IOException, InterruptedException {
        CachedSnapshot snapshot = snapshot();
        String query = normalizeQuery(rawQuery);
        List<MarketTickerSnapshot> matched = snapshot.tickers()
                .stream()
                .filter(ticker -> query.isEmpty()
                        || ticker.symbol().contains(query))
                .sorted(VOLUME_ORDER)
                .toList();

        int totalElements = matched.size();
        int fromIndex = (int) Math.min(
                (long) page * size,
                totalElements
        );
        int toIndex = Math.min(fromIndex + size, totalElements);
        int totalPages = totalElements == 0
                ? 0
                : (totalElements + size - 1) / size;

        return new MarketTickerPage(
                snapshot.quoteAsset(),
                query,
                page,
                size,
                totalElements,
                totalPages,
                toIndex < totalElements,
                matched.subList(fromIndex, toIndex)
        );
    }

    private CachedSnapshot snapshot()
            throws IOException, InterruptedException {
        long now = System.currentTimeMillis();
        CachedSnapshot current = cachedSnapshot;
        if (current.expiresAtMillis() > now) {
            return current;
        }

        synchronized (snapshotMonitor) {
            current = cachedSnapshot;
            if (current.expiresAtMillis() > now) {
                return current;
            }

            Map<String, Ticker24h> tickersBySymbol =
                    marketDataClient.load24hTickers();
            List<MarketTickerSnapshot> tickers =
                    marketDataClient.loadTargetSymbols()
                            .stream()
                            .map(BinanceUsdmSymbol::pair)
                            .map(tickersBySymbol::get)
                            .filter(java.util.Objects::nonNull)
                            .map(MarketTickerSnapshot::from)
                            .toList();
            CachedSnapshot refreshed = new CachedSnapshot(
                    symbolWhitelist.quoteAsset(),
                    tickers,
                    System.currentTimeMillis() + SNAPSHOT_TTL_MILLIS
            );
            cachedSnapshot = refreshed;
            return refreshed;
        }
    }

    static String normalizeQuery(String rawQuery) {
        if (!StringUtils.hasText(rawQuery)) {
            return "";
        }

        String uppercased = rawQuery
                .trim()
                .toUpperCase(Locale.ROOT);
        StringBuilder normalized = new StringBuilder(uppercased.length());
        for (int index = 0; index < uppercased.length(); index++) {
            char value = uppercased.charAt(index);
            if (Character.isLetterOrDigit(value)) {
                normalized.append(value);
            }
        }
        return normalized.toString();
    }

    public record MarketTickerCollection(
            String quoteAsset,
            List<MarketTickerSnapshot> tickers
    ) {
    }

    public record MarketTickerPage(
            String quoteAsset,
            String query,
            int page,
            int size,
            int totalElements,
            int totalPages,
            boolean hasNext,
            List<MarketTickerSnapshot> items
    ) {
    }

    private record CachedSnapshot(
            String quoteAsset,
            List<MarketTickerSnapshot> tickers,
            long expiresAtMillis
    ) {

        private static CachedSnapshot empty() {
            return new CachedSnapshot("", List.of(), 0);
        }
    }
}
