package com.oovso.notification;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.oovso.strategy.StrategySignal;
import java.io.ByteArrayOutputStream;
import java.math.BigDecimal;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Flow;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

@SuppressWarnings("unchecked")
class WebhookStrategySignalHandlerTest {

    private final ExecutorService executor = Executors.newSingleThreadExecutor();

    @AfterEach
    void shutdown() {
        executor.shutdownNow();
    }

    @Test
    void postsDocumentedPayloadWithUsdtSymbolAndAcceptsAnySuccessfulStatus() throws Exception {
        WebhookNotificationProperties properties = properties();
        HttpClient client = mock(HttpClient.class);
        HttpResponse<String> response = mock(HttpResponse.class);
        when(response.statusCode()).thenReturn(204);
        when(client.send(any(HttpRequest.class), anyStringBodyHandler())).thenReturn(response);
        WebhookStrategySignalHandler handler = handler(properties, client);
        StrategySignal signal = signal();

        assertTrue(handler.sendWithRetry(signal));

        ArgumentCaptor<HttpRequest> requestCaptor = ArgumentCaptor.forClass(HttpRequest.class);
        verify(client).send(requestCaptor.capture(), anyStringBodyHandler());
        HttpRequest request = requestCaptor.getValue();
        assertEquals("POST", request.method());
        assertEquals("https://example.com/webhook?key=test", request.uri().toString());
        assertEquals(
                "application/json; charset=UTF-8",
                request.headers().firstValue("Content-Type").orElseThrow()
        );
        JsonObject payload = JsonParser.parseString(requestBody(request)).getAsJsonObject();
        assertEquals("signal-123", payload.get("eventId").getAsString());
        assertEquals("Trade Tool", payload.get("sourceName").getAsString());
        assertEquals("BTCUSDT", payload.get("symbol").getAsString());
        assertEquals("BUY", payload.get("signal").getAsString());
        assertEquals("SUPER_EMA144_PULLBACK_REVERSAL", payload.get("strategy").getAsString());
        assertEquals("1h", payload.get("interval").getAsString());
        assertEquals(new BigDecimal("64123.45"), payload.get("price").getAsBigDecimal());
        assertEquals(1_788_488_400_000L, payload.get("timestamp").getAsLong());
        assertEquals(
                new StrategySignalTextFormatter().format(signal, "Asia/Shanghai", "BTCUSDT"),
                payload.get("comment").getAsString()
        );
        assertTrue(payload.get("comment").getAsString().contains("交易对: BTCUSDT"));
        JsonObject indicators = payload.getAsJsonObject("indicators");
        assertEquals(BigDecimal.ZERO, indicators.get("score").getAsBigDecimal());
        assertEquals("NO_REVERSAL_PATTERN", indicators.get("pattern").getAsString());
        assertEquals("EMA144", indicators.getAsJsonObject("details").get("pullbackTarget").getAsString());
        assertFalse(payload.has("event_id"));
        assertFalse(payload.has("provider"));
        assertFalse(payload.has("title"));
    }

    @Test
    void mapsShortToSellAndLeavesExistingUsdtSymbolUnchanged() {
        WebhookStrategySignalHandler handler = handler(properties(), mock(HttpClient.class));
        StrategySignal signal = signal();
        signal.setPair("ETHUSDT");
        signal.setDirection("SHORT");

        JsonObject payload = JsonParser.parseString(handler.payload(signal, "message")).getAsJsonObject();

        assertEquals("ETHUSDT", payload.get("symbol").getAsString());
        assertEquals("SELL", payload.get("signal").getAsString());
    }

    @Test
    void retriesServerFailureAndStopsAfterSuccess() throws Exception {
        WebhookNotificationProperties properties = properties();
        properties.setMaxAttempts(3);
        HttpClient client = mock(HttpClient.class);
        HttpResponse<String> unavailable = mock(HttpResponse.class);
        HttpResponse<String> success = mock(HttpResponse.class);
        when(unavailable.statusCode()).thenReturn(503);
        when(success.statusCode()).thenReturn(200);
        when(client.send(any(HttpRequest.class), anyStringBodyHandler()))
                .thenReturn(unavailable, success);
        WebhookStrategySignalHandler handler = handler(properties, client);

        assertTrue(handler.sendWithRetry(signal()));
        verify(client, times(2)).send(any(HttpRequest.class), anyStringBodyHandler());
    }

    @Test
    void doesNotRetryClientFailure() throws Exception {
        WebhookNotificationProperties properties = properties();
        properties.setMaxAttempts(3);
        HttpClient client = mock(HttpClient.class);
        HttpResponse<String> response = mock(HttpResponse.class);
        when(response.statusCode()).thenReturn(400);
        when(client.send(any(HttpRequest.class), anyStringBodyHandler())).thenReturn(response);
        WebhookStrategySignalHandler handler = handler(properties, client);

        assertFalse(handler.sendWithRetry(signal()));
        verify(client).send(any(HttpRequest.class), anyStringBodyHandler());
    }

    @Test
    void requiresAbsoluteHttpsEndpoint() {
        WebhookNotificationProperties properties = properties();
        properties.setUrl("http://example.com/webhook");

        assertThrows(IllegalStateException.class, properties::endpointUri);
    }

    @Test
    void requiresKeySeparatelyFromEndpointUrl() {
        WebhookNotificationProperties properties = properties();
        properties.setKey(" ");

        assertThrows(IllegalStateException.class, properties::endpointUri);
    }

    @Test
    void rejectsEndpointUrlContainingQueryParameters() {
        WebhookNotificationProperties properties = properties();
        properties.setUrl("https://example.com/webhook?key=embedded");

        assertThrows(IllegalStateException.class, properties::endpointUri);
    }

    @Test
    void encodesKeyAsAQueryParameterValue() {
        WebhookNotificationProperties properties = properties();
        properties.setKey("a+b/c=");

        assertEquals(
                "https://example.com/webhook?key=a%2Bb%2Fc%3D",
                properties.endpointUri().toString()
        );
    }

    private WebhookStrategySignalHandler handler(
            WebhookNotificationProperties properties,
            HttpClient client
    ) {
        return new WebhookStrategySignalHandler(
                properties,
                new StrategySignalTextFormatter(),
                client,
                executor
        );
    }

    private WebhookNotificationProperties properties() {
        WebhookNotificationProperties properties = new WebhookNotificationProperties();
        properties.setUrl("https://example.com/webhook");
        properties.setKey("test");
        properties.setMaxAttempts(1);
        properties.setRetryDelayMillis(0);
        return properties;
    }

    private StrategySignal signal() {
        StrategySignal signal = new StrategySignal();
        signal.setPair("BTCUSDC");
        signal.setId("signal-123");
        signal.setIntervalCode("1h");
        signal.setDirection("LONG");
        signal.setStrategyCode("SUPER_EMA144_PULLBACK_REVERSAL");
        signal.setPatternCode("NO_REVERSAL_PATTERN");
        signal.setSignalTimeMs(1_788_488_400_000L);
        signal.setPrice(new BigDecimal("64123.45"));
        signal.setScore(BigDecimal.ZERO);
        signal.setReasonJson("{\"pullbackTarget\":\"EMA144\",\"ema55\":\"64500.1\"}");
        return signal;
    }

    private HttpResponse.BodyHandler<String> anyStringBodyHandler() {
        return any(HttpResponse.BodyHandler.class);
    }

    private String requestBody(HttpRequest request) {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        CompletableFuture<Void> completed = new CompletableFuture<>();
        request.bodyPublisher().orElseThrow().subscribe(new Flow.Subscriber<>() {
            @Override
            public void onSubscribe(Flow.Subscription subscription) {
                subscription.request(Long.MAX_VALUE);
            }

            @Override
            public void onNext(ByteBuffer item) {
                byte[] bytes = new byte[item.remaining()];
                item.get(bytes);
                output.writeBytes(bytes);
            }

            @Override
            public void onError(Throwable throwable) {
                completed.completeExceptionally(throwable);
            }

            @Override
            public void onComplete() {
                completed.complete(null);
            }
        });
        completed.join();
        return output.toString(StandardCharsets.UTF_8);
    }
}
