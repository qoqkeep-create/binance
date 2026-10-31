package com.oovso.trading;

import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.WebSocket;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Objects;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionStage;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;

@Component
public class BinanceUserDataStreamClient {

    private final TradingProperties properties;
    private final HttpClient httpClient;
    private final URI baseUri;

    @Autowired
    public BinanceUserDataStreamClient(TradingProperties properties) {
        this(
                properties,
                HttpClient.newBuilder()
                        .connectTimeout(Duration.ofMillis(
                                properties.getBinance()
                                        .getRequestTimeoutMillis()
                        ))
                        .build()
        );
    }

    BinanceUserDataStreamClient(
            TradingProperties properties,
            HttpClient httpClient
    ) {
        this.properties = properties;
        this.httpClient = httpClient;
        this.baseUri = normalizeBaseUri(
                properties.getSync().getUserStreamBaseUrl()
        );
    }

    public CompletableFuture<Connection> connect(
            String listenKey,
            EventHandler handler
    ) {
        Objects.requireNonNull(handler, "handler");
        URI target = streamUri(listenKey);
        StreamListener listener = new StreamListener(
                handler,
                Math.max(1_024, properties.getSync().getMaxMessageBytes())
        );
        return httpClient.newWebSocketBuilder()
                .connectTimeout(Duration.ofMillis(
                        properties.getBinance().getRequestTimeoutMillis()
                ))
                .buildAsync(target, listener)
                .thenApply(socket -> new Connection(socket, listener));
    }

    URI streamUri(String listenKey) {
        if (!StringUtils.hasText(listenKey)) {
            throw new IllegalArgumentException("listenKey is required");
        }
        return URI.create(
                baseUri + "/ws/"
                        + URLEncoder.encode(
                                listenKey.trim(),
                                StandardCharsets.UTF_8
                        )
        );
    }

    private URI normalizeBaseUri(String value) {
        URI uri = URI.create(value);
        if (!"wss".equalsIgnoreCase(uri.getScheme()) || uri.getHost() == null) {
            throw new IllegalArgumentException(
                    "trading.sync.user-stream-base-url must be a WSS origin/path"
            );
        }
        String normalized = uri.toString();
        while (normalized.endsWith("/")) {
            normalized = normalized.substring(0, normalized.length() - 1);
        }
        return URI.create(normalized);
    }

    public interface EventHandler {

        void onMessage(String message, long receivedAtMillis);

        void onClosed(int statusCode, String reason);

        void onFailure(Throwable failure);
    }

    public static final class Connection implements AutoCloseable {

        private final WebSocket socket;
        private final StreamListener listener;
        private final AtomicBoolean closed = new AtomicBoolean();

        private Connection(WebSocket socket, StreamListener listener) {
            this.socket = socket;
            this.listener = listener;
        }

        public boolean isOpen() {
            return !closed.get() && !listener.isTerminal();
        }

        public void abort() {
            if (closed.compareAndSet(false, true)) {
                socket.abort();
            }
        }

        @Override
        public void close() {
            if (!closed.compareAndSet(false, true)) {
                return;
            }
            try {
                socket.sendClose(WebSocket.NORMAL_CLOSURE, "rollover")
                        .get(2, TimeUnit.SECONDS);
            } catch (Exception ignored) {
                socket.abort();
            }
        }
    }

    private static final class StreamListener implements WebSocket.Listener {

        private final EventHandler handler;
        private final int maxMessageBytes;
        private final StringBuilder currentMessage = new StringBuilder();
        private final AtomicBoolean terminal = new AtomicBoolean();
        private int currentBytes;

        private StreamListener(EventHandler handler, int maxMessageBytes) {
            this.handler = handler;
            this.maxMessageBytes = maxMessageBytes;
        }

        @Override
        public void onOpen(WebSocket webSocket) {
            webSocket.request(1);
        }

        @Override
        public synchronized CompletionStage<?> onText(
                WebSocket webSocket,
                CharSequence data,
                boolean last
        ) {
            if (terminal.get()) {
                return CompletableFuture.completedFuture(null);
            }
            currentBytes += data.toString()
                    .getBytes(StandardCharsets.UTF_8).length;
            if (currentBytes > maxMessageBytes) {
                IllegalStateException failure = new IllegalStateException(
                        "Binance user stream message exceeds configured limit"
                );
                terminal.set(true);
                handler.onFailure(failure);
                webSocket.abort();
                return CompletableFuture.failedFuture(failure);
            }
            currentMessage.append(data);
            if (last) {
                String message = currentMessage.toString();
                currentMessage.setLength(0);
                currentBytes = 0;
                handler.onMessage(message, System.currentTimeMillis());
            }
            webSocket.request(1);
            return CompletableFuture.completedFuture(null);
        }

        @Override
        public CompletionStage<?> onBinary(
                WebSocket webSocket,
                ByteBuffer data,
                boolean last
        ) {
            IllegalStateException failure = new IllegalStateException(
                    "Unexpected binary Binance user stream message"
            );
            if (terminal.compareAndSet(false, true)) {
                handler.onFailure(failure);
            }
            webSocket.abort();
            return CompletableFuture.failedFuture(failure);
        }

        @Override
        public CompletionStage<?> onClose(
                WebSocket webSocket,
                int statusCode,
                String reason
        ) {
            if (terminal.compareAndSet(false, true)) {
                handler.onClosed(statusCode, reason == null ? "" : reason);
            }
            return CompletableFuture.completedFuture(null);
        }

        @Override
        public void onError(WebSocket webSocket, Throwable error) {
            if (terminal.compareAndSet(false, true)) {
                handler.onFailure(error);
            }
        }

        boolean isTerminal() {
            return terminal.get();
        }
    }
}
