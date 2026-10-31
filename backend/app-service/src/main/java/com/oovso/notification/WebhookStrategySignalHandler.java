package com.oovso.notification;

import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.oovso.strategy.StrategySignal;
import com.oovso.strategy.StrategySignalHandler;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import java.io.IOException;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

@Component
@ConditionalOnProperty(prefix = "notification.webhook", name = "enabled", havingValue = "true")
public class WebhookStrategySignalHandler implements StrategySignalHandler {

    private static final Logger log = LoggerFactory.getLogger(WebhookStrategySignalHandler.class);

    private final WebhookNotificationProperties properties;

    private final StrategySignalTextFormatter formatter;

    private final HttpClient httpClient;

    private final ExecutorService executor;

    @Autowired
    public WebhookStrategySignalHandler(
            WebhookNotificationProperties properties,
            StrategySignalTextFormatter formatter
    ) {
        this(
                properties,
                formatter,
                HttpClient.newBuilder()
                        .connectTimeout(Duration.ofMillis(Math.max(1_000, properties.getConnectTimeoutMillis())))
                        .followRedirects(HttpClient.Redirect.NEVER)
                        .build(),
                Executors.newThreadPerTaskExecutor(
                        Thread.ofVirtual().name("strategy-webhook-", 0).factory()
                )
        );
    }

    WebhookStrategySignalHandler(
            WebhookNotificationProperties properties,
            StrategySignalTextFormatter formatter,
            HttpClient httpClient,
            ExecutorService executor
    ) {
        this.properties = properties;
        this.formatter = formatter;
        this.httpClient = httpClient;
        this.executor = executor;
    }

    @PostConstruct
    void validateConfiguration() {
        properties.endpointUri();
    }

    @Override
    public void onSignal(StrategySignal signal) {
        executor.submit(() -> sendWithRetry(signal));
    }

    boolean sendWithRetry(StrategySignal signal) {
        String outboundSymbol = webhookSymbol(signal.getPair());
        String text = formatter.format(signal, properties.getZoneId(), outboundSymbol);
        HttpRequest request = request(payload(signal, text));
        int maxAttempts = Math.max(1, properties.getMaxAttempts());
        for (int attempt = 1; attempt <= maxAttempts && !Thread.currentThread().isInterrupted(); attempt++) {
            try {
                HttpResponse<String> response = httpClient.send(
                        request,
                        HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8)
                );
                int status = response.statusCode();
                if (status >= 200 && status < 300) {
                    log.info(
                            "Sent strategy signal webhook for {} {} {}",
                            signal.getPair(),
                            signal.getIntervalCode(),
                            signal.getDirection()
                    );
                    return true;
                }
                if (!retryable(status) || attempt >= maxAttempts) {
                    log.warn(
                            "Failed to send strategy signal webhook for {} after {} attempt(s): HTTP {}",
                            signal.getPair(),
                            attempt,
                            status
                    );
                    return false;
                }
                log.warn(
                        "Failed to send strategy signal webhook for {}, retrying ({}/{}): HTTP {}",
                        signal.getPair(),
                        attempt,
                        maxAttempts,
                        status
                );
            } catch (InterruptedException exception) {
                Thread.currentThread().interrupt();
                return false;
            } catch (IOException exception) {
                if (attempt >= maxAttempts) {
                    log.warn(
                            "Failed to send strategy signal webhook for {} after {} attempt(s): {}",
                            signal.getPair(),
                            attempt,
                            exception.getClass().getSimpleName()
                    );
                    return false;
                }
                log.warn(
                        "Failed to send strategy signal webhook for {}, retrying ({}/{}): {}",
                        signal.getPair(),
                        attempt,
                        maxAttempts,
                        exception.getClass().getSimpleName()
                );
            }
            if (!sleepBeforeRetry()) {
                return false;
            }
        }
        return false;
    }

    HttpRequest request(String body) {
        return HttpRequest.newBuilder()
                .uri(properties.endpointUri())
                .timeout(Duration.ofMillis(Math.max(1_000, properties.getRequestTimeoutMillis())))
                .header("Content-Type", "application/json; charset=UTF-8")
                .header("Accept", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(body, StandardCharsets.UTF_8))
                .build();
    }

    String payload(StrategySignal signal, String text) {
        JsonObject payload = new JsonObject();
        add(payload, "eventId", signal.getId());
        payload.addProperty("sourceName", "Trade Tool");
        payload.addProperty("symbol", webhookSymbol(signal.getPair()));
        payload.addProperty("signal", webhookSignal(signal.getDirection()));
        add(payload, "strategy", signal.getStrategyCode());
        add(payload, "interval", signal.getIntervalCode());
        if (signal.getPrice() != null) {
            payload.addProperty("price", signal.getPrice());
        }
        Long timestamp = signal.getSignalTimeMs() != null
                ? signal.getSignalTimeMs()
                : signal.getTriggerOpenTimeMs();
        if (timestamp != null) {
            payload.addProperty("timestamp", timestamp);
        }
        payload.addProperty("comment", text);
        JsonObject indicators = indicators(signal);
        if (indicators.size() > 0) {
            payload.add("indicators", indicators);
        }
        return payload.toString();
    }

    private JsonObject indicators(StrategySignal signal) {
        JsonObject indicators = new JsonObject();
        if (signal.getScore() != null) {
            indicators.addProperty("score", signal.getScore());
        }
        add(indicators, "pattern", signal.getPatternCode());
        if (signal.getReasonJson() != null && !signal.getReasonJson().isBlank()) {
            try {
                JsonElement details = JsonParser.parseString(signal.getReasonJson());
                if (details.isJsonObject()) {
                    indicators.add("details", details);
                }
            } catch (RuntimeException ignored) {
                // The readable comment still carries the signal when optional details are malformed.
            }
        }
        return indicators;
    }

    private void add(JsonObject payload, String name, String value) {
        if (value != null && !value.isBlank()) {
            payload.addProperty(name, value);
        }
    }

    private String webhookSignal(String direction) {
        return "LONG".equalsIgnoreCase(direction)
                ? "BUY"
                : "SHORT".equalsIgnoreCase(direction) ? "SELL" : "INFO";
    }

    private String webhookSymbol(String symbol) {
        if (symbol == null || symbol.length() < 4) {
            return symbol;
        }
        int suffixStart = symbol.length() - 4;
        return symbol.regionMatches(true, suffixStart, "USDC", 0, 4)
                ? symbol.substring(0, suffixStart) + "USDT"
                : symbol;
    }

    private boolean retryable(int status) {
        return status == 429 || status >= 500;
    }

    private boolean sleepBeforeRetry() {
        try {
            Thread.sleep(Math.max(0, properties.getRetryDelayMillis()));
            return true;
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            return false;
        }
    }

    @PreDestroy
    public void shutdown() {
        executor.shutdownNow();
    }
}
