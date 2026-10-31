package com.oovso.trading;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.core.read.ListAppender;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.oovso.binance.BinanceRestRequestBudget;
import com.oovso.trading.BinanceUsdmPrivateGateway.AlgoOrderRequest;
import com.oovso.trading.BinanceUsdmPrivateGateway.RegularOrderRequest;
import java.math.BigDecimal;
import java.net.URLDecoder;
import java.net.http.HttpClient;
import java.net.http.HttpHeaders;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.stream.Collectors;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.slf4j.LoggerFactory;

class BinanceUsdmPrivateRestClientTest {

    @Test
    @SuppressWarnings("unchecked")
    void privateRateLimitCarriesDeadlineAndStopsFurtherHttpCalls()
            throws Exception {
        TradingProperties properties = new TradingProperties();
        properties.getBinance().setRestBaseUrl("https://unit.test");
        BinanceRestRequestBudget budget = new BinanceRestRequestBudget(
                properties
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
        BinanceUsdmPrivateRestClient client =
                new BinanceUsdmPrivateRestClient(
                        properties,
                        new ObjectMapper(),
                        budget,
                        httpClient
                );

        BinancePrivateApiException first = assertThrows(
                BinancePrivateApiException.class,
                () -> client.createListenKey(credentials())
        );
        BinancePrivateApiException second = assertThrows(
                BinancePrivateApiException.class,
                () -> client.createListenKey(credentials())
        );

        assertEquals(-1003, first.code());
        assertEquals(bannedUntil, first.retryAtMillis());
        assertEquals(bannedUntil, second.retryAtMillis());
        verify(httpClient, times(1)).send(
                any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)
        );
    }

    @Test
    void signerMatchesKnownHmacSha256Vector() {
        assertEquals(
                "f7bc83f430538424b13298e6aa6fb143"
                        + "ef4d59a14946175997479dbc2d1a3cd8",
                BinanceUsdmPrivateRestClient.signature(
                        "The quick brown fox jumps over the lazy dog",
                        "key"
                )
        );
    }

    @Test
    void makerEntryUsesLimitGtxAndDeterministicClientId() throws Exception {
        CapturingClient fixture = clientRespondingWith("""
                {
                  "symbol":"BTCUSDC",
                  "side":"BUY",
                  "positionSide":"BOTH",
                  "type":"LIMIT",
                  "timeInForce":"GTX",
                  "clientOrderId":"tt-entry-123",
                  "orderId":42,
                  "origQty":"0.10",
                  "price":"64000",
                  "executedQty":"0",
                  "status":"NEW"
                }
                """);

        fixture.client().placeRegularOrder(
                credentials(),
                new RegularOrderRequest(
                        "BTCUSDC",
                        "BUY",
                        "BOTH",
                        "LIMIT",
                        "GTX",
                        bd("0.10"),
                        bd("64000"),
                        false,
                        "tt-entry-123"
                )
        );

        HttpRequest request = fixture.request();
        Map<String, String> query = query(request);
        assertEquals("POST", request.method());
        assertEquals("test-api-key", request.headers()
                .firstValue("X-MBX-APIKEY").orElseThrow());
        assertEquals("/fapi/v1/order", request.uri().getPath());
        assertEquals("LIMIT", query.get("type"));
        assertEquals("GTX", query.get("timeInForce"));
        assertEquals("0.1", query.get("quantity"));
        assertEquals("64000", query.get("price"));
        assertEquals("tt-entry-123", query.get("newClientOrderId"));
        assertEquals("RESULT", query.get("newOrderRespType"));
        assertFalse(query.containsKey("positionSide"));
        assertFalse(query.containsKey("reduceOnly"));
        assertTrue(query.containsKey("signature"));
    }

    @Test
    void hedgeEntryIncludesExplicitPositionSide() throws Exception {
        CapturingClient fixture = clientRespondingWith("""
                {
                  "symbol":"BTCUSDC",
                  "side":"BUY",
                  "positionSide":"LONG",
                  "type":"LIMIT",
                  "timeInForce":"GTC",
                  "clientOrderId":"tt-entry-hedge",
                  "orderId":43,
                  "origQty":"0.10",
                  "price":"64000",
                  "executedQty":"0",
                  "status":"NEW"
                }
                """);

        fixture.client().placeRegularOrder(
                credentials(),
                new RegularOrderRequest(
                        "BTCUSDC",
                        "BUY",
                        "LONG",
                        "LIMIT",
                        "GTC",
                        bd("0.10"),
                        bd("64000"),
                        false,
                        "tt-entry-hedge"
                )
        );

        assertEquals("LONG", query(fixture.request()).get("positionSide"));
    }

    @Test
    @SuppressWarnings("unchecked")
    void diagnosticLogShowsOrderParametersAndResponseWithoutSecrets()
            throws Exception {
        TradingProperties properties = new TradingProperties();
        properties.getBinance().setRestBaseUrl("https://unit.test");
        properties.getBinance().setDiagnosticRestLoggingEnabled(true);
        HttpClient httpClient = mock(HttpClient.class);
        HttpResponse<String> response = jsonResponse("""
                {
                  "symbol":"BTCUSDC",
                  "side":"BUY",
                  "positionSide":"LONG",
                  "type":"LIMIT",
                  "timeInForce":"GTC",
                  "clientOrderId":"tt-entry-log",
                  "orderId":45,
                  "origQty":"0.10",
                  "price":"64000",
                  "executedQty":"0",
                  "status":"NEW",
                  "apiKey":"response-secret"
                }
                """);
        when(httpClient.send(
                any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)
        )).thenReturn(response);
        BinanceUsdmPrivateRestClient client =
                new BinanceUsdmPrivateRestClient(
                        properties,
                        new ObjectMapper(),
                        new BinanceRestRequestBudget(properties),
                        httpClient
                );
        ch.qos.logback.classic.Logger logger =
                (ch.qos.logback.classic.Logger) LoggerFactory.getLogger(
                        BinanceUsdmPrivateRestClient.class
                );
        ListAppender<ILoggingEvent> appender = new ListAppender<>();
        appender.start();
        logger.addAppender(appender);
        try {
            client.placeRegularOrder(
                    credentials(),
                    new RegularOrderRequest(
                            "BTCUSDC",
                            "BUY",
                            "LONG",
                            "LIMIT",
                            "GTC",
                            bd("0.10"),
                            bd("64000"),
                            false,
                            "tt-entry-log"
                    )
            );
        } finally {
            logger.detachAppender(appender);
            appender.stop();
        }

        String messages = appender.list.stream()
                .map(ILoggingEvent::getFormattedMessage)
                .collect(Collectors.joining("\n"));
        assertTrue(messages.contains("BINANCE_PRIVATE_REST"));
        assertTrue(messages.contains("method=POST"));
        assertTrue(messages.contains("path=/fapi/v1/order"));
        assertTrue(messages.contains("positionSide=LONG"));
        assertTrue(messages.contains("status=200"));
        assertTrue(messages.contains("\"positionSide\":\"LONG\""));
        assertTrue(messages.contains("\"apiKey\":\"<redacted>\""));
        assertFalse(messages.contains("test-api-key"));
        assertFalse(messages.contains("test-secret"));
        assertFalse(messages.contains("response-secret"));
        assertFalse(messages.contains("signature="));
    }

    @Test
    void closePositionStopMarketOmitsQuantityAndReduceOnly() throws Exception {
        CapturingClient fixture = clientRespondingWith("""
                {
                  "algoId":99,
                  "clientAlgoId":"tt-stop-123",
                  "algoStatus":"NEW"
                }
                """);

        fixture.client().placeAlgoOrder(
                credentials(),
                new AlgoOrderRequest(
                        "BTCUSDC",
                        "SELL",
                        "LONG",
                        "STOP_MARKET",
                        null,
                        "MARK_PRICE",
                        null,
                        null,
                        bd("62000"),
                        false,
                        true,
                        "tt-stop-123"
                )
        );

        HttpRequest request = fixture.request();
        Map<String, String> query = query(request);
        assertEquals("POST", request.method());
        assertEquals("/fapi/v1/algoOrder", request.uri().getPath());
        assertEquals("CONDITIONAL", query.get("algoType"));
        assertEquals("STOP_MARKET", query.get("type"));
        assertEquals("MARK_PRICE", query.get("workingType"));
        assertEquals("62000", query.get("triggerPrice"));
        assertEquals("true", query.get("closePosition"));
        assertEquals("tt-stop-123", query.get("clientAlgoId"));
        assertFalse(query.containsKey("quantity"));
        assertFalse(query.containsKey("reduceOnly"));
    }

    @Test
    void partialTakeProfitMarketUsesConditionalAlgoQuantity() throws Exception {
        CapturingClient fixture = clientRespondingWith("""
                {
                  "algoId":100,
                  "clientAlgoId":"tt-take-profit-1",
                  "algoStatus":"NEW"
                }
                """);

        fixture.client().placeAlgoOrder(
                credentials(),
                new AlgoOrderRequest(
                        "BTCUSDC",
                        "SELL",
                        "BOTH",
                        "TAKE_PROFIT_MARKET",
                        null,
                        "MARK_PRICE",
                        bd("0.25"),
                        null,
                        bd("66000"),
                        true,
                        false,
                        "tt-take-profit-1"
                )
        );

        Map<String, String> query = query(fixture.request());
        assertEquals("/fapi/v1/algoOrder", fixture.request().uri().getPath());
        assertEquals("CONDITIONAL", query.get("algoType"));
        assertEquals("TAKE_PROFIT_MARKET", query.get("type"));
        assertEquals("0.25", query.get("quantity"));
        assertEquals("66000", query.get("triggerPrice"));
        assertEquals("true", query.get("reduceOnly"));
        assertFalse(query.containsKey("closePosition"));
        assertFalse(query.containsKey("price"));
    }

    @Test
    @SuppressWarnings("unchecked")
    void startupHedgeModeCheckDoesNotChangeAnyLeverage()
            throws Exception {
        TradingProperties properties = new TradingProperties();
        properties.getBinance().setRestBaseUrl("https://unit.test");
        HttpClient httpClient = mock(HttpClient.class);
        ArgumentCaptor<HttpRequest> captor =
                ArgumentCaptor.forClass(HttpRequest.class);
        AtomicBoolean hedgeMode = new AtomicBoolean(false);
        when(httpClient.send(
                captor.capture(),
                any(HttpResponse.BodyHandler.class)
        )).thenAnswer(invocation -> {
            HttpRequest request = invocation.getArgument(0);
            String path = request.uri().getPath();
            if ("/fapi/v1/positionSide/dual".equals(path)
                    && "POST".equals(request.method())) {
                hedgeMode.set(true);
                return jsonResponse("{\"code\":200,\"msg\":\"success\"}");
            }
            assertTrue("/fapi/v1/positionSide/dual".equals(path)
                    || "/fapi/v1/accountConfig".equals(path));
            return jsonResponse(
                    "{\"dualSidePosition\":" + hedgeMode.get() + "}"
            );
        });
        BinanceUsdmPrivateRestClient client =
                new BinanceUsdmPrivateRestClient(
                        properties,
                        new ObjectMapper(),
                        new BinanceRestRequestBudget(properties),
                        httpClient
                );

        assertEquals("HEDGE", client.enforceHedgeMode(credentials()));

        List<HttpRequest> requests = captor.getAllValues();
        assertEquals(5, requests.size());
        assertEquals(2, requests.stream().filter(request ->
                "/fapi/v1/accountConfig".equals(request.uri().getPath())
        ).count());
        assertTrue(requests.stream().noneMatch(request ->
                "/fapi/v1/leverage".equals(request.uri().getPath())
        ));
    }

    @Test
    @SuppressWarnings("unchecked")
    void accountSetupEnablesHedgeAndUsesMaximumAccountLeverage()
            throws Exception {
        TradingProperties properties = new TradingProperties();
        properties.getBinance().setRestBaseUrl("https://unit.test");
        HttpClient httpClient = mock(HttpClient.class);
        ArgumentCaptor<HttpRequest> captor =
                ArgumentCaptor.forClass(HttpRequest.class);
        AtomicBoolean hedgeMode = new AtomicBoolean(false);
        when(httpClient.send(
                captor.capture(),
                any(HttpResponse.BodyHandler.class)
        )).thenAnswer(invocation -> {
            HttpRequest request = invocation.getArgument(0);
            String path = request.uri().getPath();
            String body;
            if ("/fapi/v1/positionSide/dual".equals(path)
                    && "GET".equals(request.method())) {
                body = "{\"dualSidePosition\":" + hedgeMode.get() + "}";
            } else if ("/fapi/v1/accountConfig".equals(path)) {
                body = "{\"dualSidePosition\":" + hedgeMode.get() + "}";
            } else if ("/fapi/v1/positionSide/dual".equals(path)) {
                hedgeMode.set(true);
                body = "{\"code\":200,\"msg\":\"success\"}";
            } else if ("/fapi/v1/exchangeInfo".equals(path)) {
                body = """
                        {"symbols":[
                          {"symbol":"BTCUSDC","status":"TRADING",
                           "contractType":"PERPETUAL","quoteAsset":"USDC"},
                          {"symbol":"ETHUSDC","status":"CLOSE",
                           "contractType":"PERPETUAL","quoteAsset":"USDC"},
                          {"symbol":"BTCUSDT","status":"TRADING",
                           "contractType":"PERPETUAL","quoteAsset":"USDT"}
                        ]}
                        """;
            } else if ("/fapi/v1/leverageBracket".equals(path)) {
                body = """
                        [
                          {"symbol":"BTCUSDC","brackets":[
                            {"bracket":1,"initialLeverage":125},
                            {"bracket":2,"initialLeverage":50}
                          ]},
                          {"symbol":"BTCUSDT","brackets":[
                            {"bracket":1,"initialLeverage":100}
                          ]}
                        ]
                        """;
            } else if ("/fapi/v1/leverage".equals(path)) {
                body = """
                        {"symbol":"BTCUSDC","leverage":125,
                         "maxNotionalValue":"50000"}
                        """;
            } else {
                throw new AssertionError("Unexpected request " + request);
            }
            return jsonResponse(body);
        });
        BinanceUsdmPrivateRestClient client =
                new BinanceUsdmPrivateRestClient(
                        properties,
                        new ObjectMapper(),
                        new BinanceRestRequestBudget(properties),
                        httpClient
                );

        BinanceUsdmPrivateGateway.AccountSetupResult result =
                client.enforceHedgeModeAndMaximumLeverage(
                        credentials(),
                        "USDC"
                );

        assertEquals("HEDGE", result.positionMode());
        assertEquals(1, result.configuredSymbolCount());
        List<HttpRequest> requests = captor.getAllValues();
        HttpRequest positionModeChange = requests.stream()
                .filter(request -> "/fapi/v1/positionSide/dual".equals(
                        request.uri().getPath()
                ))
                .filter(request -> "POST".equals(request.method()))
                .findFirst()
                .orElseThrow();
        assertEquals("true", query(positionModeChange).get("dualSidePosition"));
        List<HttpRequest> leverageChanges = requests.stream()
                .filter(request -> "/fapi/v1/leverage".equals(
                        request.uri().getPath()
                ))
                .toList();
        assertEquals(1, leverageChanges.size());
        assertEquals("BTCUSDC", query(leverageChanges.getFirst()).get("symbol"));
        assertEquals("125", query(leverageChanges.getFirst()).get("leverage"));
    }

    @Test
    @SuppressWarnings("unchecked")
    void positionSideMismatchReturnsFirstFailureWithoutRetry()
            throws Exception {
        FailedRegularOrderFixture fixture = failedRegularOrderFixture(-4061);

        BinancePrivateApiException exception = assertThrows(
                BinancePrivateApiException.class,
                () -> fixture.client().placeRegularOrder(
                        credentials(),
                        regularEntryRequest("tt-entry-position-mode")
                )
        );

        assertEquals(-4061, exception.code());
        assertFalse(exception.outcomeUnknown());
        assertSingleOrderRequest(fixture.requests());
    }

    @Test
    @SuppressWarnings("unchecked")
    void otherKnownOrderFailureAlsoReturnsWithoutRetry()
            throws Exception {
        FailedRegularOrderFixture fixture = failedRegularOrderFixture(-2027);

        BinancePrivateApiException exception = assertThrows(
                BinancePrivateApiException.class,
                () -> fixture.client().placeRegularOrder(
                        credentials(),
                        regularEntryRequest("tt-entry-margin-ratio")
                )
        );

        assertEquals(-2027, exception.code());
        assertFalse(exception.outcomeUnknown());
        assertSingleOrderRequest(fixture.requests());
    }

    @Test
    @SuppressWarnings("unchecked")
    void readsAndChangesSingleSymbolLeverageWithBracketLimits()
            throws Exception {
        TradingProperties properties = new TradingProperties();
        properties.getBinance().setRestBaseUrl("https://unit.test");
        HttpClient httpClient = mock(HttpClient.class);
        ArgumentCaptor<HttpRequest> captor =
                ArgumentCaptor.forClass(HttpRequest.class);
        when(httpClient.send(
                captor.capture(),
                any(HttpResponse.BodyHandler.class)
        )).thenAnswer(invocation -> {
            HttpRequest request = invocation.getArgument(0);
            String path = request.uri().getPath();
            if ("/fapi/v1/symbolConfig".equals(path)) {
                return jsonResponse("""
                        [{"symbol":"BTCUSDC","marginType":"CROSSED",
                          "leverage":20,"maxNotionalValue":"1000000"}]
                        """);
            }
            if ("/fapi/v1/leverageBracket".equals(path)) {
                return jsonResponse("""
                        [{"symbol":"BTCUSDC","brackets":[
                          {"bracket":1,"initialLeverage":125,
                           "notionalFloor":"0","notionalCap":"50000"},
                          {"bracket":2,"initialLeverage":50,
                           "notionalFloor":"50000","notionalCap":"250000"}
                        ]}]
                        """);
            }
            if ("/fapi/v1/leverage".equals(path)) {
                return jsonResponse("""
                        {"symbol":"BTCUSDC","leverage":50,
                         "maxNotionalValue":"250000"}
                        """);
            }
            throw new AssertionError("Unexpected request " + request);
        });
        BinanceUsdmPrivateRestClient client =
                new BinanceUsdmPrivateRestClient(
                        properties,
                        new ObjectMapper(),
                        new BinanceRestRequestBudget(properties),
                        httpClient
                );

        var current = client.leverage(credentials(), "btcusdc");
        var updated = client.changeLeverage(credentials(), "BTCUSDC", 50);

        assertEquals("BTCUSDC", current.symbol());
        assertEquals(20, current.leverage());
        assertEquals(125, current.maxLeverage());
        assertEquals(new BigDecimal("1000000"), current.maxNotionalValue());
        assertEquals(2, current.brackets().size());
        assertEquals(50, updated.leverage());
        assertEquals(new BigDecimal("250000"), updated.maxNotionalValue());
        HttpRequest change = captor.getAllValues().stream()
                .filter(request -> "/fapi/v1/leverage".equals(
                        request.uri().getPath()
                ))
                .findFirst()
                .orElseThrow();
        assertEquals("POST", change.method());
        assertEquals("BTCUSDC", query(change).get("symbol"));
        assertEquals("50", query(change).get("leverage"));
    }

    @SuppressWarnings("unchecked")
    private FailedRegularOrderFixture failedRegularOrderFixture(int code)
            throws Exception {
        TradingProperties properties = new TradingProperties();
        properties.getBinance().setRestBaseUrl("https://unit.test");
        HttpClient httpClient = mock(HttpClient.class);
        ArgumentCaptor<HttpRequest> captor =
                ArgumentCaptor.forClass(HttpRequest.class);
        HttpResponse<String> response = jsonResponse(
                400,
                "{\"code\":" + code + ",\"msg\":\"order rejected\"}"
        );
        when(httpClient.send(
                captor.capture(),
                any(HttpResponse.BodyHandler.class)
        )).thenReturn(response);
        return new FailedRegularOrderFixture(
                new BinanceUsdmPrivateRestClient(
                        properties,
                        new ObjectMapper(),
                        new BinanceRestRequestBudget(properties),
                        httpClient
                ),
                captor
        );
    }

    private RegularOrderRequest regularEntryRequest(String clientOrderId) {
        return new RegularOrderRequest(
                "BTCUSDC",
                "BUY",
                "LONG",
                "LIMIT",
                "GTC",
                bd("0.10"),
                bd("64000"),
                false,
                clientOrderId
        );
    }

    private void assertSingleOrderRequest(List<HttpRequest> requests) {
        assertEquals(1, requests.size());
        assertEquals("POST", requests.getFirst().method());
        assertEquals("/fapi/v1/order", requests.getFirst().uri().getPath());
    }

    @SuppressWarnings("unchecked")
    private CapturingClient clientRespondingWith(String body) throws Exception {
        TradingProperties properties = new TradingProperties();
        properties.getBinance().setRestBaseUrl("https://unit.test");
        HttpClient httpClient = mock(HttpClient.class);
        HttpResponse<String> response = mock(HttpResponse.class);
        when(response.statusCode()).thenReturn(200);
        when(response.body()).thenReturn(body);
        when(response.headers()).thenReturn(HttpHeaders.of(Map.of(),
                (name, value) -> true));
        ArgumentCaptor<HttpRequest> captor =
                ArgumentCaptor.forClass(HttpRequest.class);
        when(httpClient.send(
                captor.capture(),
                any(HttpResponse.BodyHandler.class)
        )).thenReturn(response);
        BinanceUsdmPrivateRestClient client =
                new BinanceUsdmPrivateRestClient(
                        properties,
                        new ObjectMapper(),
                        new BinanceRestRequestBudget(properties),
                        httpClient
                );
        return new CapturingClient(client, captor);
    }

    private Map<String, String> query(HttpRequest request) {
        return Arrays.stream(request.uri().getRawQuery().split("&"))
                .map(pair -> pair.split("=", 2))
                .collect(Collectors.toMap(
                        pair -> decode(pair[0]),
                        pair -> pair.length == 2 ? decode(pair[1]) : ""
                ));
    }

    private String decode(String value) {
        return URLDecoder.decode(value, StandardCharsets.UTF_8);
    }

    private BinanceCredentials credentials() {
        return new BinanceCredentials("test-api-key", "test-secret");
    }

    private BigDecimal bd(String value) {
        return new BigDecimal(value);
    }

    @SuppressWarnings("unchecked")
    private HttpResponse<String> jsonResponse(String body) {
        return jsonResponse(200, body);
    }

    @SuppressWarnings("unchecked")
    private HttpResponse<String> jsonResponse(int statusCode, String body) {
        HttpResponse<String> response = mock(HttpResponse.class);
        when(response.statusCode()).thenReturn(statusCode);
        when(response.body()).thenReturn(body);
        when(response.headers()).thenReturn(HttpHeaders.of(
                Map.of(),
                (name, value) -> true
        ));
        return response;
    }

    private record CapturingClient(
            BinanceUsdmPrivateRestClient client,
            ArgumentCaptor<HttpRequest> captor
    ) {

        private HttpRequest request() {
            return captor.getValue();
        }
    }

    private record FailedRegularOrderFixture(
            BinanceUsdmPrivateRestClient client,
            ArgumentCaptor<HttpRequest> captor
    ) {
        private List<HttpRequest> requests() {
            return captor.getAllValues();
        }
    }
}
