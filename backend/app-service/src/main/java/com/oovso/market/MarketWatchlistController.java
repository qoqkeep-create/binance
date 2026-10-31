package com.oovso.market;

import com.oovso.binance.BinanceUsdmMarketDataClient;
import com.oovso.binance.BinanceUsdmSymbol;
import com.oovso.strategy.StrategySymbolWhitelist;
import com.oovso.web.ApiResponse;
import java.io.IOException;
import java.util.List;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/market/watchlist")
public class MarketWatchlistController {

    private final StrategySymbolWhitelist symbolWhitelist;

    private final BinanceUsdmMarketDataClient marketDataClient;

    public MarketWatchlistController(
            StrategySymbolWhitelist symbolWhitelist,
            BinanceUsdmMarketDataClient marketDataClient
    ) {
        this.symbolWhitelist = symbolWhitelist;
        this.marketDataClient = marketDataClient;
    }

    @GetMapping("/defaults")
    public ApiResponse<DefaultWatchlistResponse> defaults()
            throws IOException, InterruptedException {
        List<String> activeSymbols = marketDataClient.loadTargetSymbols()
                .stream()
                .map(BinanceUsdmSymbol::pair)
                .toList();
        return ApiResponse.success(new DefaultWatchlistResponse(
                symbolWhitelist.quoteAsset(),
                symbolWhitelist.activeSymbolsInOrder(activeSymbols),
                activeSymbols));
    }

    public record DefaultWatchlistResponse(
            String quoteAsset,
            List<String> symbols,
            List<String> availableSymbols
    ) {
    }
}
