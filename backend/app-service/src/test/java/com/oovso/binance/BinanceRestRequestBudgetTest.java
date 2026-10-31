package com.oovso.binance;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.oovso.market.KlineStorageProperties;
import com.oovso.trading.TradingProperties;
import java.net.http.HttpClient;
import java.net.http.HttpHeaders;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

class BinanceRestRequestBudgetTest {

    @Test
    void banDeadlineOverridesShorterRetryAfterAndBlocksRequests() {
        TradingProperties properties = new TradingProperties();
        BinanceRestRequestBudget budget = new BinanceRestRequestBudget(
                properties
        );
        long bannedUntil = System.currentTimeMillis() + 120_000;
        HttpHeaders headers = HttpHeaders.of(
                Map.of(
                        "Retry-After", List.of("5"),
                        "X-MBX-USED-WEIGHT-1M", List.of("321")
                ),
                (name, value) -> true
        );

        long observed = budget.observeResponse(
                418,
                headers,
                "{\"code\":-1003,\"msg\":\"IP banned until "
                        + bannedUntil + "\"}"
        );

        assertEquals(bannedUntil, observed);
        assertEquals(321, budget.reservedWeight());
        BinanceRestRateLimitException exception = assertThrows(
                BinanceRestRateLimitException.class,
                () -> budget.acquire(1)
        );
        assertEquals(bannedUntil, exception.retryAtMillis());
    }

    @Test
    @SuppressWarnings("unchecked")
    void marketResponseCooldownPreventsAnotherHttpRequest() throws Exception {
        TradingProperties tradingProperties = new TradingProperties();
        BinanceRestRequestBudget budget = new BinanceRestRequestBudget(
                tradingProperties
        );
        HttpClient httpClient = mock(HttpClient.class);
        HttpResponse<String> response = mock(HttpResponse.class);
        long bannedUntil = System.currentTimeMillis() + 120_000;
        when(response.statusCode()).thenReturn(418);
        when(response.body()).thenReturn(
                "{\"code\":-1003,\"msg\":\"IP banned until "
                        + bannedUntil + "\"}"
        );
        when(response.headers()).thenReturn(HttpHeaders.of(
                Map.of("Retry-After", List.of("5")),
                (name, value) -> true
        ));
        when(httpClient.send(
                any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)
        )).thenReturn(response);
        BinanceContinuousKlineProperties binanceProperties =
                new BinanceContinuousKlineProperties();
        binanceProperties.setQuoteAsset("USDC");
        BinanceUsdmMarketDataClient client = new BinanceUsdmMarketDataClient(
                binanceProperties,
                new KlineStorageProperties(),
                budget,
                httpClient
        );

        BinanceRestRateLimitException first = assertThrows(
                BinanceRestRateLimitException.class,
                client::loadTargetSymbols
        );
        BinanceRestRateLimitException second = assertThrows(
                BinanceRestRateLimitException.class,
                client::load24hTickers
        );

        assertEquals(bannedUntil, first.retryAtMillis());
        assertEquals(bannedUntil, second.retryAtMillis());
        assertTrue(budget.cooldownUntilMillis() > System.currentTimeMillis());
        verify(httpClient, times(1)).send(
                any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)
        );
    }
}
