package com.oovso.binance;

import com.binance.connector.client.common.ApiException;
import com.binance.connector.client.common.websocket.adapter.stream.StreamConnectionWrapper;
import com.binance.connector.client.common.websocket.configuration.WebSocketClientConfiguration;
import com.binance.connector.client.common.websocket.dtos.RequestWrapperDTO;
import com.binance.connector.client.common.websocket.service.StreamBlockingQueue;
import com.binance.connector.client.derivatives_trading_usds_futures.websocket.stream.DerivativesTradingUsdsFuturesWebSocketStreamsUtil;
import com.binance.connector.client.derivatives_trading_usds_futures.websocket.stream.api.DerivativesTradingUsdsFuturesWebSocketStreams;
import com.binance.connector.client.derivatives_trading_usds_futures.websocket.stream.model.ContinuousContractKlineCandlestickStreamsResponse;
import java.io.IOException;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Future;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.UUID;
import org.eclipse.jetty.websocket.api.Session;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.SmartLifecycle;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;

@Component
public class BinanceUsdMarginedPerpetualContinuousKlineConnector implements SmartLifecycle {

    private static final Logger log =
            LoggerFactory.getLogger(BinanceUsdMarginedPerpetualContinuousKlineConnector.class);

    private final BinanceContinuousKlineProperties properties;

    private final BinanceUsdmMarketDataClient marketDataClient;

    private final List<ContinuousKlineHandler> handlers;

    private final AtomicBoolean running = new AtomicBoolean(false);

    private final ConcurrentMap<String, Subscription> subscriptions = new ConcurrentHashMap<>();

    private final List<StreamGroup> streamGroups = new CopyOnWriteArrayList<>();

    private final AtomicInteger nextGroupIndex = new AtomicInteger();

    private final Object subscriptionThrottleMonitor = new Object();

    private long nextSubscriptionAtMillis;

    private ExecutorService consumerExecutor;

    private ScheduledExecutorService reconnectMonitorExecutor;

    private ScheduledExecutorService symbolRefreshExecutor;

    public BinanceUsdMarginedPerpetualContinuousKlineConnector(
            BinanceContinuousKlineProperties properties,
            BinanceUsdmMarketDataClient marketDataClient,
            List<ContinuousKlineHandler> handlers
    ) {
        this.properties = properties;
        this.marketDataClient = marketDataClient;
        this.handlers = handlers;
    }

    @Override
    public void start() {
        if (!properties.isEnabled()) {
            log.info("Binance USD-M continuous kline connector is disabled");
            return;
        }
        if (!running.compareAndSet(false, true)) {
            return;
        }

        logHandlerRegistration();
        initializeExecutors();
        startReconnectMonitor();
        boolean initialSubscriptionSucceeded = false;
        try {
            List<String> pairs = loadTargetPerpetualPairs();
            if (pairs.isEmpty()) {
                log.warn(
                        "No Binance USD-M {} {} symbols found at startup; retrying in background",
                        properties.getQuoteAsset(),
                        properties.getContractType()
                );
            } else {
                initializeStreamGroups(partitionPairs(pairs));
                subscribeInitialGroups();
                initialSubscriptionSucceeded = true;

                log.info(
                        "Subscribed {} Binance USD-M {} {} continuous kline streams at interval {} across {} websocket connections",
                        subscriptions.size(),
                        properties.getQuoteAsset(),
                        properties.getContractType(),
                        properties.getInterval(),
                        streamGroups.size()
                );
            }
        } catch (InterruptedException ex) {
            Thread.currentThread().interrupt();
            log.warn(
                    "Interrupted while initializing Binance USD-M continuous kline subscriptions; retrying in background"
            );
        } catch (Exception ex) {
            log.warn(
                    "Failed to initialize Binance USD-M continuous kline subscriptions; retrying in background: {}",
                    BinanceNetworkExceptionSupport.conciseMessage(ex)
            );
        }
        startSymbolRefreshMonitor(initialSubscriptionSucceeded);
    }

    @Override
    public void stop() {
        if (!running.getAndSet(false)) {
            return;
        }
        stopInternal();
    }

    @Override
    public void stop(Runnable callback) {
        try {
            stop();
        } finally {
            callback.run();
        }
    }

    @Override
    public boolean isRunning() {
        return running.get();
    }

    @Override
    public boolean isAutoStartup() {
        return properties.isEnabled();
    }

    public List<String> subscribedPairs() {
        return subscriptions.keySet().stream().sorted().toList();
    }

    private void logHandlerRegistration() {
        if (handlers.isEmpty()) {
            log.warn("No Binance continuous kline handlers registered; websocket events will be consumed but not processed");
            return;
        }
        log.info(
                "Registered {} Binance continuous kline handlers: {}",
                handlers.size(),
                handlers.stream().map(handler -> handler.getClass().getSimpleName()).toList()
        );
    }

    private void initializeExecutors() {
        consumerExecutor = Executors.newVirtualThreadPerTaskExecutor();
    }

    private void initializeStreamGroups(List<List<String>> pairGroups) {
        streamGroups.clear();
        nextGroupIndex.set(0);
        for (List<String> pairGroup : pairGroups) {
            streamGroups.add(new StreamGroup(nextGroupIndex.getAndIncrement(), pairGroup));
        }
    }

    private void subscribeInitialGroups() {
        AtomicInteger submitted = new AtomicInteger();
        List<CompletableFuture<Void>> futures = streamGroups.stream()
                .map(group -> CompletableFuture.runAsync(
                        () -> connectAndSubscribeGroup(group, submitted),
                        consumerExecutor
                ))
                .toList();
        CompletableFuture.allOf(futures.toArray(CompletableFuture[]::new)).join();
    }

    private WebSocketClientConfiguration streamConfiguration() {
        WebSocketClientConfiguration streamConfiguration =
                DerivativesTradingUsdsFuturesWebSocketStreamsUtil.getClientConfiguration();
        if (StringUtils.hasText(properties.getStreamBaseUrl())) {
            streamConfiguration.setUrl(properties.getStreamBaseUrl());
        }
        streamConfiguration.setUsePool(false);
        if (properties.getMessageMaxSize() != null) {
            streamConfiguration.setMessageMaxSize(properties.getMessageMaxSize());
        }
        return streamConfiguration;
    }

    private List<String> loadTargetPerpetualPairs() throws IOException, InterruptedException {
        return marketDataClient.loadTargetSymbols().stream()
                .map(BinanceUsdmSymbol::pair)
                .map(pair -> pair.toLowerCase(Locale.ROOT))
                .toList();
    }

    private List<List<String>> partitionPairs(List<String> pairs) {
        int streamsPerConnection = Math.max(1, properties.getStreamsPerConnection());
        List<List<String>> groups = new ArrayList<>();
        for (int start = 0; start < pairs.size(); start += streamsPerConnection) {
            groups.add(pairs.subList(start, Math.min(start + streamsPerConnection, pairs.size())));
        }
        return groups;
    }

    private void connectAndSubscribeGroup(StreamGroup group, AtomicInteger submitted) {
        try {
            doConnectAndSubscribeGroup(group, submitted);
        } catch (InterruptedException ex) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("Interrupted while subscribing Binance stream group " + group.index(), ex);
        } catch (ApiException ex) {
            throw new IllegalStateException("Failed to subscribe Binance stream group " + group.index(), ex);
        }
    }

    private void doConnectAndSubscribeGroup(StreamGroup group, AtomicInteger submitted)
            throws ApiException, InterruptedException {
        synchronized (group) {
            cleanupGroup(group, "replace websocket connection");
            if (group.pairs().isEmpty() || !streamGroups.contains(group)) {
                return;
            }

            int generation = group.nextGeneration();
            StreamConnectionWrapper connection = new StreamConnectionWrapper(streamConfiguration());
            DerivativesTradingUsdsFuturesWebSocketStreams client =
                    new DerivativesTradingUsdsFuturesWebSocketStreams(connection);

            group.connection(connection);
            group.client(client);
            group.markEventReceived(System.currentTimeMillis());

            subscribePairs(group, List.copyOf(group.pairs()), generation, submitted);
        }
    }

    private void subscribePairs(
            StreamGroup group,
            List<String> pairs,
            int generation,
            AtomicInteger submitted
    ) throws ApiException, InterruptedException {
        if (pairs.isEmpty() || !running.get()) {
            return;
        }
        for (String pair : pairs) {
            if (!running.get() || group.generation() != generation) {
                return;
            }
            throttleSubscription();

            String stream = streamName(pair);
            RequestWrapperDTO<Set<String>, Object> request = new RequestWrapperDTO.Builder<Set<String>, Object>()
                    .id(UUID.randomUUID().toString())
                    .method("SUBSCRIBE")
                    .params(Set.of(stream))
                    .build();
            Map<String, StreamBlockingQueue<String>> queues = group.connection().subscribe(request);
            StreamBlockingQueue<String> queue = queues.get(stream);
            if (queue == null) {
                throw new IllegalStateException("Binance SDK did not create a stream queue for " + stream);
            }
            awaitSubscriptionAck(request, stream);

            Future<?> consumerTask = consumerExecutor.submit(() -> consume(group, pair, queue, generation));
            StreamSubscription streamSubscription = new StreamSubscription(pair, queue, consumerTask, generation);
            group.subscriptions().put(pair, streamSubscription);
            subscriptions.put(pair, new Subscription(queue, group.connection()));
            submitted.incrementAndGet();
        }

        log.info(
                "Submitted {} Binance continuous kline subscriptions in websocket group {} (total submitted={})",
                pairs.size(),
                group.index(),
                submitted.get()
        );
    }

    private String streamName(String pair) {
        return pair
                + "_"
                + properties.getContractType().toLowerCase(Locale.ROOT)
                + "@continuousKline_"
                + properties.getInterval();
    }

    private void awaitSubscriptionAck(RequestWrapperDTO<Set<String>, Object> request, String stream)
            throws InterruptedException {
        try {
            request.getResponseCallback().get(10, TimeUnit.SECONDS);
        } catch (ExecutionException | TimeoutException ex) {
            throw new IllegalStateException("Binance did not acknowledge stream subscription " + stream, ex);
        }
    }

    private void throttleSubscription() throws InterruptedException {
        long delayMillis = properties.getSubscribeDelayMillis();
        if (delayMillis <= 0) {
            return;
        }
        synchronized (subscriptionThrottleMonitor) {
            long now = System.currentTimeMillis();
            long waitMillis = nextSubscriptionAtMillis - now;
            if (waitMillis > 0) {
                Thread.sleep(waitMillis);
                now = System.currentTimeMillis();
            }
            nextSubscriptionAtMillis = now + delayMillis;
        }
    }

    private void consume(
            StreamGroup group,
            String pair,
            StreamBlockingQueue<String> queue,
            int generation
    ) {
        while (running.get()
                && group.generation() == generation
                && !Thread.currentThread().isInterrupted()) {
            try {
                ContinuousContractKlineCandlestickStreamsResponse event = parseEvent(queue);
                if (event == null) {
                    continue;
                }
                group.markEventReceived(System.currentTimeMillis());
                if (event.getError() != null) {
                    log.warn("Binance continuous kline stream error for {}: {}", pair, event.getError());
                    continue;
                }
                dispatch(event);
            } catch (InterruptedException ex) {
                Thread.currentThread().interrupt();
            } catch (Exception ex) {
                if (running.get() && group.generation() == generation) {
                    log.error("Failed to consume Binance continuous kline event for {}", pair, ex);
                }
            }
        }
    }

    private ContinuousContractKlineCandlestickStreamsResponse parseEvent(StreamBlockingQueue<String> queue)
            throws IOException, InterruptedException {
        String payload = queue.take();
        if (!StringUtils.hasText(payload)) {
            return null;
        }
        return ContinuousContractKlineCandlestickStreamsResponse.fromJson(payload);
    }

    private void dispatch(ContinuousContractKlineCandlestickStreamsResponse event) {
        for (ContinuousKlineHandler handler : handlers) {
            try {
                handler.onKline(event);
            } catch (Exception ex) {
                log.error("Binance continuous kline handler {} failed", handler.getClass().getName(), ex);
            }
        }
    }

    private void startReconnectMonitor() {
        if (!properties.isReconnectEnabled()) {
            return;
        }

        reconnectMonitorExecutor = Executors.newSingleThreadScheduledExecutor(task -> {
            Thread thread = new Thread(task, "binance-kline-reconnect-monitor");
            thread.setDaemon(true);
            return thread;
        });
        long intervalMillis = Math.max(1_000, properties.getReconnectMonitorIntervalMillis());
        reconnectMonitorExecutor.scheduleWithFixedDelay(
                this::monitorConnections,
                intervalMillis,
                intervalMillis,
                TimeUnit.MILLISECONDS
        );
    }

    private void monitorConnections() {
        if (!running.get()) {
            return;
        }
        long now = System.currentTimeMillis();
        long silentTimeoutMillis = properties.getSilentReconnectTimeoutMillis();
        for (StreamGroup group : streamGroups) {
            if (!group.pairs().isEmpty() && !group.healthy()) {
                submitGroupReconnect(group, "connection unhealthy");
                continue;
            }
            if (!group.pairs().isEmpty()
                    && silentTimeoutMillis > 0
                    && group.silentMillis(now) > silentTimeoutMillis) {
                submitGroupReconnect(group, "no websocket events received for "
                        + group.silentMillis(now)
                        + " ms");
            }
        }
    }

    private void startSymbolRefreshMonitor(
            boolean initialSubscriptionSucceeded
    ) {
        if (!properties.isSymbolRefreshEnabled()
                && initialSubscriptionSucceeded) {
            return;
        }

        symbolRefreshExecutor = Executors.newSingleThreadScheduledExecutor(task -> {
            Thread thread = new Thread(task, "binance-kline-symbol-refresh");
            thread.setDaemon(true);
            return thread;
        });
        long intervalMillis = properties.isSymbolRefreshEnabled()
                ? Math.max(30_000, properties.getSymbolRefreshIntervalMillis())
                : 30_000;
        long initialDelayMillis = initialSubscriptionSucceeded
                ? intervalMillis
                : Math.min(30_000, intervalMillis);
        symbolRefreshExecutor.scheduleWithFixedDelay(
                this::refreshSymbolsSafely,
                initialDelayMillis,
                intervalMillis,
                TimeUnit.MILLISECONDS
        );
    }

    private void refreshSymbolsSafely() {
        if (!running.get()) {
            return;
        }
        try {
            refreshSymbols();
            if (!properties.isSymbolRefreshEnabled()
                    && !currentPairs().isEmpty()) {
                ScheduledExecutorService executor = symbolRefreshExecutor;
                symbolRefreshExecutor = null;
                if (executor != null) {
                    executor.shutdown();
                }
            }
        } catch (InterruptedException ex) {
            Thread.currentThread().interrupt();
        } catch (Exception ex) {
            if (BinanceNetworkExceptionSupport.isTlsCertificateValidationFailure(ex)) {
                log.warn(
                        "Binance REST TLS certificate validation failed during symbol refresh; "
                                + "keeping current subscriptions and retrying later: {}",
                        BinanceNetworkExceptionSupport.conciseMessage(ex)
                );
            } else {
                log.warn("Failed to refresh Binance USD-M continuous kline symbols; keeping current subscriptions", ex);
            }
        }
    }

    private void refreshSymbols() throws IOException, InterruptedException {
        List<String> latestPairs = loadTargetPerpetualPairs();
        if (latestPairs.isEmpty()) {
            log.warn("Binance exchangeInfo returned no target symbols during refresh; keeping current subscriptions");
            return;
        }

        Set<String> latest = new HashSet<>(latestPairs);
        Set<String> current = currentPairs();
        List<String> removedPairs = current.stream()
                .filter(pair -> !latest.contains(pair))
                .sorted()
                .toList();
        List<String> addedPairs = latestPairs.stream()
                .filter(pair -> !current.contains(pair))
                .toList();

        if (addedPairs.isEmpty() && removedPairs.isEmpty()) {
            return;
        }

        for (String pair : removedPairs) {
            removePair(pair);
        }
        for (String pair : addedPairs) {
            addPair(pair);
        }

        log.info(
                "Refreshed Binance USD-M continuous kline symbols: added={}, removed={}, totalPairs={}, websocketConnections={}",
                addedPairs.size(),
                removedPairs.size(),
                currentPairs().size(),
                streamGroups.size()
        );
    }

    private Set<String> currentPairs() {
        Set<String> current = new HashSet<>();
        for (StreamGroup group : streamGroups) {
            current.addAll(group.pairs());
        }
        return current;
    }

    private void addPair(String pair) {
        if (currentPairs().contains(pair)) {
            return;
        }

        StreamGroup group = selectGroupForNewPair();
        synchronized (group) {
            if (group.pairs().contains(pair)) {
                return;
            }
            group.pairs().add(pair);

            if (group.client() == null || group.connection() == null || !group.connection().isConnected()) {
                log.info("Queued newly listed Binance continuous kline stream {} in websocket group {}", pair, group.index());
                submitGroupReconnect(group);
                return;
            }

            try {
                subscribePairs(group, List.of(pair), group.generation(), new AtomicInteger());
                log.info("Subscribed newly listed Binance continuous kline stream {} in websocket group {}", pair, group.index());
            } catch (InterruptedException ex) {
                Thread.currentThread().interrupt();
                log.warn("Interrupted while subscribing newly listed Binance continuous kline stream {}", pair);
            } catch (ApiException ex) {
                subscriptions.remove(pair);
                group.subscriptions().remove(pair);
                log.warn("Failed to subscribe newly listed Binance continuous kline stream {}", pair, ex);
                submitGroupReconnect(group);
            }
        }
    }

    private StreamGroup selectGroupForNewPair() {
        int streamsPerConnection = Math.max(1, properties.getStreamsPerConnection());
        StreamGroup selected = null;
        for (StreamGroup group : streamGroups) {
            if (group.pairs().size() >= streamsPerConnection) {
                continue;
            }
            if (selected == null || group.pairs().size() < selected.pairs().size()) {
                selected = group;
            }
        }
        if (selected != null) {
            return selected;
        }

        StreamGroup group = new StreamGroup(nextGroupIndex.getAndIncrement(), List.of());
        streamGroups.add(group);
        return group;
    }

    private void removePair(String pair) {
        for (StreamGroup group : streamGroups) {
            synchronized (group) {
                if (!group.pairs().remove(pair)) {
                    continue;
                }

                StreamSubscription streamSubscription = group.subscriptions().remove(pair);
                if (streamSubscription != null) {
                    streamSubscription.consumerTask().cancel(true);
                }
                Subscription subscription = subscriptions.remove(pair);
                unsubscribe(subscription, pair);

                if (group.pairs().isEmpty()) {
                    cleanupGroup(group, "empty websocket group after symbol refresh");
                    streamGroups.remove(group);
                }

                log.info("Unsubscribed removed Binance continuous kline stream {} from websocket group {}",
                        pair, group.index());
                return;
            }
        }
    }

    private void unsubscribe(Subscription subscription, String pair) {
        if (subscription == null || subscription.connection() == null) {
            return;
        }
        try {
            subscription.connection().unsubscribe(subscription.queue());
        } catch (Exception ex) {
            log.debug("Failed to unsubscribe Binance continuous kline stream {}", pair, ex);
        }
    }

    private void submitGroupReconnect(StreamGroup group) {
        submitGroupReconnect(group, "connection unhealthy");
    }

    private void submitGroupReconnect(StreamGroup group, String reason) {
        ExecutorService executor = consumerExecutor;
        if (executor == null || executor.isShutdown()) {
            return;
        }
        if (group.markReconnecting()) {
            log.warn(
                    "Scheduling Binance continuous kline websocket group {} reconnect: {}",
                    group.index(),
                    reason
            );
            executor.submit(() -> reconnectGroupWithRetry(group));
        }
    }

    private void reconnectGroupWithRetry(StreamGroup group) {
        int attempt = 1;
        try {
            while (running.get()) {
                if (group.pairs().isEmpty() || !streamGroups.contains(group)) {
                    return;
                }
                try {
                    log.warn("Reconnecting Binance continuous kline websocket group {} with {} streams, attempt {}",
                            group.index(), group.pairs().size(), attempt);
                    doConnectAndSubscribeGroup(group, new AtomicInteger());
                    log.info("Reconnected Binance continuous kline websocket group {} with {} streams",
                            group.index(), group.pairs().size());
                    return;
                } catch (InterruptedException ex) {
                    Thread.currentThread().interrupt();
                    return;
                } catch (Exception ex) {
                    cleanupGroup(group, "failed reconnect cleanup");
                    long backoffMillis = reconnectBackoffMillis(attempt++);
                    log.warn(
                            "Failed to reconnect Binance continuous kline websocket group {}, retrying in {} ms",
                            group.index(),
                            backoffMillis,
                            ex
                    );
                    sleepQuietly(backoffMillis);
                    if (Thread.currentThread().isInterrupted()) {
                        return;
                    }
                }
            }
        } finally {
            group.clearReconnecting();
        }
    }

    private long reconnectBackoffMillis(int attempt) {
        long initialBackoff = Math.max(100L, properties.getReconnectInitialBackoffMillis());
        long maxBackoff = Math.max(initialBackoff, properties.getReconnectMaxBackoffMillis());
        int exponent = Math.min(attempt - 1, 10);
        long backoff = initialBackoff * (1L << exponent);
        return Math.min(backoff, maxBackoff);
    }

    private void sleepQuietly(long backoffMillis) {
        try {
            Thread.sleep(backoffMillis);
        } catch (InterruptedException ex) {
            Thread.currentThread().interrupt();
        }
    }

    private void stopInternal() {
        if (symbolRefreshExecutor != null) {
            symbolRefreshExecutor.shutdownNow();
            symbolRefreshExecutor = null;
        }

        if (reconnectMonitorExecutor != null) {
            reconnectMonitorExecutor.shutdownNow();
            reconnectMonitorExecutor = null;
        }

        for (StreamGroup group : streamGroups) {
            cleanupGroup(group, "application stopping");
        }
        streamGroups.clear();
        subscriptions.clear();

        if (consumerExecutor != null) {
            consumerExecutor.shutdownNow();
            consumerExecutor = null;
        }

        nextGroupIndex.set(0);
        synchronized (subscriptionThrottleMonitor) {
            nextSubscriptionAtMillis = 0;
        }
    }

    private void cleanupGroup(StreamGroup group, String reason) {
        synchronized (group) {
            group.nextGeneration();
            for (StreamSubscription subscription : group.subscriptions().values()) {
                subscription.consumerTask().cancel(true);
                subscriptions.remove(subscription.pair());
            }
            group.subscriptions().clear();

            StreamConnectionWrapper connection = group.connection();
            group.connection(null);
            group.client(null);
            closeConnection(connection, reason);
        }
    }

    private void closeConnection(StreamConnectionWrapper connection, String reason) {
        if (connection == null) {
            return;
        }
        try {
            connection.stop();
        } catch (Exception ex) {
            log.warn("Failed to stop Binance websocket connection cleanly; using fallback cleanup", ex);
            closeSession(connection, reason);
            stopWebSocketClient(connection);
        }
    }

    private void closeSession(StreamConnectionWrapper connection, String reason) {
        try {
            Field sessionField = findField(connection.getClass(), "session");
            if (sessionField == null) {
                return;
            }
            sessionField.setAccessible(true);
            Object value = sessionField.get(connection);
            if (value instanceof Session session && session.isOpen()) {
                session.close(1000, reason);
            }
        } catch (Exception ex) {
            log.debug("Failed to close Binance websocket session", ex);
        }
    }

    private void stopWebSocketClient(StreamConnectionWrapper connection) {
        try {
            Field clientField = findField(connection.getClass(), "webSocketClient");
            if (clientField == null) {
                return;
            }
            clientField.setAccessible(true);
            Object webSocketClient = clientField.get(connection);
            if (webSocketClient == null) {
                return;
            }
            Method stop = webSocketClient.getClass().getMethod("stop");
            stop.invoke(webSocketClient);
        } catch (Exception ex) {
            log.debug("Failed to stop Binance websocket client", ex);
        }
    }

    private Field findField(Class<?> type, String fieldName) {
        Class<?> current = type;
        while (current != null) {
            try {
                return current.getDeclaredField(fieldName);
            } catch (NoSuchFieldException ex) {
                current = current.getSuperclass();
            }
        }
        return null;
    }

    private record Subscription(
            StreamBlockingQueue<String> queue,
            StreamConnectionWrapper connection
    ) {
    }

    private record StreamSubscription(
            String pair,
            StreamBlockingQueue<String> queue,
            Future<?> consumerTask,
            int generation
    ) {
    }

    private static final class StreamGroup {

        private final int index;

        private final List<String> pairs;

        private final ConcurrentMap<String, StreamSubscription> subscriptions = new ConcurrentHashMap<>();

        private final AtomicInteger generation = new AtomicInteger();

        private final AtomicBoolean reconnecting = new AtomicBoolean(false);

        private final AtomicLong lastEventAtMillis = new AtomicLong();

        private volatile StreamConnectionWrapper connection;

        private volatile DerivativesTradingUsdsFuturesWebSocketStreams client;

        private StreamGroup(int index, List<String> pairs) {
            this.index = index;
            this.pairs = new CopyOnWriteArrayList<>(pairs);
        }

        private int index() {
            return index;
        }

        private List<String> pairs() {
            return pairs;
        }

        private ConcurrentMap<String, StreamSubscription> subscriptions() {
            return subscriptions;
        }

        private StreamConnectionWrapper connection() {
            return connection;
        }

        private void connection(StreamConnectionWrapper connection) {
            this.connection = connection;
        }

        private DerivativesTradingUsdsFuturesWebSocketStreams client() {
            return client;
        }

        private void client(DerivativesTradingUsdsFuturesWebSocketStreams client) {
            this.client = client;
        }

        private int generation() {
            return generation.get();
        }

        private int nextGeneration() {
            return generation.incrementAndGet();
        }

        private boolean healthy() {
            return connection != null
                    && connection.isConnected()
                    && subscriptions.size() == pairs.size();
        }

        private void markEventReceived(long nowMillis) {
            lastEventAtMillis.set(nowMillis);
        }

        private long silentMillis(long nowMillis) {
            long last = lastEventAtMillis.get();
            return last <= 0 ? 0 : nowMillis - last;
        }

        private boolean markReconnecting() {
            return reconnecting.compareAndSet(false, true);
        }

        private void clearReconnecting() {
            reconnecting.set(false);
        }
    }
}
