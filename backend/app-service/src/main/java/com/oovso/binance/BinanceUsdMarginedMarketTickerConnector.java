package com.oovso.binance;

import com.binance.connector.client.common.websocket.adapter.stream.StreamConnectionWrapper;
import com.binance.connector.client.common.websocket.configuration.WebSocketClientConfiguration;
import com.binance.connector.client.common.websocket.dtos.RequestWrapperDTO;
import com.binance.connector.client.common.websocket.service.StreamBlockingQueue;
import com.binance.connector.client.derivatives_trading_usds_futures.websocket.stream.DerivativesTradingUsdsFuturesWebSocketStreamsUtil;
import com.binance.connector.client.derivatives_trading_usds_futures.websocket.stream.api.DerivativesTradingUsdsFuturesWebSocketStreams;
import com.binance.connector.client.derivatives_trading_usds_futures.websocket.stream.model.AllMarketTickersStreamsResponse;
import com.oovso.realtime.RealtimeProperties;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.SmartLifecycle;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;

@Component
public class BinanceUsdMarginedMarketTickerConnector implements SmartLifecycle {

    private static final Logger log =
            LoggerFactory.getLogger(BinanceUsdMarginedMarketTickerConnector.class);

    private static final String STREAM_NAME = "!ticker@arr";

    private final BinanceContinuousKlineProperties properties;

    private final BinanceUsdmMarketDataClient marketDataClient;

    private final RealtimeProperties realtimeProperties;

    private final List<MarketTickerHandler> handlers;

    private final AtomicBoolean running = new AtomicBoolean();

    private final AtomicBoolean reconnecting = new AtomicBoolean();

    private final AtomicLong lastEventAtMillis = new AtomicLong();

    private final Object connectionMonitor = new Object();

    private volatile Set<String> targetSymbols = Set.of();

    private ExecutorService consumerExecutor;

    private ScheduledExecutorService monitorExecutor;

    private StreamConnectionWrapper connection;

    private StreamBlockingQueue<String> queue;

    private Future<?> consumerTask;

    private Future<?> symbolRefreshTask;

    public BinanceUsdMarginedMarketTickerConnector(
            BinanceContinuousKlineProperties properties,
            BinanceUsdmMarketDataClient marketDataClient,
            RealtimeProperties realtimeProperties,
            List<MarketTickerHandler> handlers
    ) {
        this.properties = properties;
        this.marketDataClient = marketDataClient;
        this.realtimeProperties = realtimeProperties;
        this.handlers = handlers;
    }

    @Override
    public void start() {
        if (!properties.isEnabled()
                || !realtimeProperties.isEnabled()
                || !realtimeProperties.isMarketTickerEnabled()) {
            log.info("Binance USD-M market ticker connector is disabled");
            return;
        }
        if (!running.compareAndSet(false, true)) {
            return;
        }

        consumerExecutor = Executors.newVirtualThreadPerTaskExecutor();
        monitorExecutor = Executors.newSingleThreadScheduledExecutor(task -> {
            Thread thread = new Thread(task, "binance-market-ticker-monitor");
            thread.setDaemon(true);
            return thread;
        });
        boolean initialSymbolsLoaded = false;
        try {
            refreshTargetSymbols();
            initialSymbolsLoaded = !targetSymbols.isEmpty();
        } catch (InterruptedException ex) {
            Thread.currentThread().interrupt();
            log.warn(
                    "Interrupted while loading Binance market ticker symbols at startup; retrying in background"
            );
        } catch (Exception ex) {
            log.warn(
                    "Failed to load Binance market ticker symbols at startup; retrying in background: {}",
                    BinanceNetworkExceptionSupport.conciseMessage(ex)
            );
        }
        if (initialSymbolsLoaded) {
            try {
                connect();
                log.info(
                        "Subscribed Binance USD-M {} all-market ticker stream for {} target symbols",
                        properties.getQuoteAsset(),
                        targetSymbols.size()
                );
            } catch (InterruptedException ex) {
                Thread.currentThread().interrupt();
                log.warn(
                        "Interrupted while connecting Binance market ticker stream at startup; retrying in background"
                );
            } catch (Exception ex) {
                log.warn(
                        "Failed to connect Binance market ticker stream at startup; retrying in background: {}",
                        BinanceNetworkExceptionSupport.conciseMessage(ex)
                );
            }
        }
        startMonitors(initialSymbolsLoaded);
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
        return properties.isEnabled()
                && realtimeProperties.isEnabled()
                && realtimeProperties.isMarketTickerEnabled();
    }

    private void connect() throws Exception {
        synchronized (connectionMonitor) {
            closeConnection("replace market ticker websocket");

            StreamConnectionWrapper nextConnection =
                    new StreamConnectionWrapper(streamConfiguration());
            new DerivativesTradingUsdsFuturesWebSocketStreams(nextConnection);
            RequestWrapperDTO<Set<String>, Object> request =
                    new RequestWrapperDTO.Builder<Set<String>, Object>()
                            .id(UUID.randomUUID().toString())
                            .method("SUBSCRIBE")
                            .params(Set.of(STREAM_NAME))
                            .build();
            try {
                Map<String, StreamBlockingQueue<String>> queues =
                        nextConnection.subscribe(request);
                StreamBlockingQueue<String> nextQueue = queues.get(STREAM_NAME);
                if (nextQueue == null) {
                    throw new IllegalStateException(
                            "Binance SDK did not create the all-market ticker stream queue"
                    );
                }
                request.getResponseCallback().get(10, TimeUnit.SECONDS);

                connection = nextConnection;
                queue = nextQueue;
                lastEventAtMillis.set(System.currentTimeMillis());
                consumerTask = consumerExecutor.submit(
                        () -> consume(nextConnection, nextQueue)
                );
            } catch (Exception ex) {
                stopConnection(nextConnection, "market ticker subscription failed");
                throw ex;
            }
        }
    }

    private WebSocketClientConfiguration streamConfiguration() {
        WebSocketClientConfiguration configuration =
                DerivativesTradingUsdsFuturesWebSocketStreamsUtil.getClientConfiguration();
        if (StringUtils.hasText(properties.getStreamBaseUrl())) {
            configuration.setUrl(properties.getStreamBaseUrl());
        }
        configuration.setUsePool(false);
        configuration.setMessageMaxSize(
                Math.max(65_536L, realtimeProperties.getMarketTickerMessageMaxBytes())
        );
        return configuration;
    }

    private void consume(
            StreamConnectionWrapper expectedConnection,
            StreamBlockingQueue<String> expectedQueue
    ) {
        while (running.get()
                && connection == expectedConnection
                && !Thread.currentThread().isInterrupted()) {
            try {
                String payload = expectedQueue.take();
                if (!StringUtils.hasText(payload)) {
                    continue;
                }
                AllMarketTickersStreamsResponse response =
                        AllMarketTickersStreamsResponse.fromJson(payload);
                lastEventAtMillis.set(System.currentTimeMillis());
                for (var ticker : response) {
                    BinanceMarketTicker marketTicker = BinanceMarketTicker.from(ticker);
                    if (!targetSymbols.contains(marketTicker.symbol())) {
                        continue;
                    }
                    dispatch(marketTicker);
                }
            } catch (InterruptedException ex) {
                Thread.currentThread().interrupt();
            } catch (Exception ex) {
                if (running.get() && connection == expectedConnection) {
                    log.warn("Failed to consume Binance all-market ticker event", ex);
                }
            }
        }
    }

    private void dispatch(BinanceMarketTicker ticker) {
        for (MarketTickerHandler handler : handlers) {
            try {
                handler.onTicker(ticker);
            } catch (Exception ex) {
                log.error(
                        "Binance market ticker handler {} failed for {}",
                        handler.getClass().getName(),
                        ticker.symbol(),
                        ex
                );
            }
        }
    }

    private void startMonitors(boolean initialSymbolsLoaded) {
        long reconnectInterval = Math.max(
                1_000,
                properties.getReconnectMonitorIntervalMillis()
        );
        monitorExecutor.scheduleWithFixedDelay(
                this::monitorConnection,
                reconnectInterval,
                reconnectInterval,
                TimeUnit.MILLISECONDS
        );

        if (properties.isSymbolRefreshEnabled() || !initialSymbolsLoaded) {
            long refreshInterval = properties.isSymbolRefreshEnabled()
                    ? Math.max(
                            30_000,
                            properties.getSymbolRefreshIntervalMillis()
                    )
                    : 30_000;
            long initialDelay = initialSymbolsLoaded
                    ? refreshInterval
                    : Math.min(30_000, refreshInterval);
            symbolRefreshTask = monitorExecutor.scheduleWithFixedDelay(
                    this::refreshTargetSymbolsSafely,
                    initialDelay,
                    refreshInterval,
                    TimeUnit.MILLISECONDS
            );
        }
    }

    private void monitorConnection() {
        if (!running.get() || targetSymbols.isEmpty()) {
            return;
        }
        StreamConnectionWrapper current = connection;
        long silentMillis = System.currentTimeMillis() - lastEventAtMillis.get();
        boolean silent = properties.getSilentReconnectTimeoutMillis() > 0
                && silentMillis > properties.getSilentReconnectTimeoutMillis();
        if (current == null || !current.isConnected() || silent) {
            scheduleReconnect(silent
                    ? "no ticker events received for " + silentMillis + " ms"
                    : "connection unhealthy");
        }
    }

    private void scheduleReconnect(String reason) {
        if (!running.get() || !reconnecting.compareAndSet(false, true)) {
            return;
        }
        log.warn("Scheduling Binance market ticker reconnect: {}", reason);
        consumerExecutor.submit(this::reconnectWithRetry);
    }

    private void reconnectWithRetry() {
        int attempt = 1;
        try {
            while (running.get()) {
                try {
                    connect();
                    log.info("Reconnected Binance all-market ticker stream");
                    return;
                } catch (InterruptedException ex) {
                    Thread.currentThread().interrupt();
                    return;
                } catch (Exception ex) {
                    long delay = reconnectBackoffMillis(attempt++);
                    log.warn(
                            "Failed to reconnect Binance market ticker stream, retrying in {} ms",
                            delay,
                            ex
                    );
                    try {
                        Thread.sleep(delay);
                    } catch (InterruptedException interrupted) {
                        Thread.currentThread().interrupt();
                        return;
                    }
                }
            }
        } finally {
            reconnecting.set(false);
        }
    }

    private long reconnectBackoffMillis(int attempt) {
        long initial = Math.max(100, properties.getReconnectInitialBackoffMillis());
        long maximum = Math.max(initial, properties.getReconnectMaxBackoffMillis());
        int exponent = Math.min(attempt - 1, 10);
        return Math.min(initial * (1L << exponent), maximum);
    }

    private void refreshTargetSymbolsSafely() {
        try {
            refreshTargetSymbols();
            if (!targetSymbols.isEmpty() && connection == null) {
                scheduleReconnect("target symbols became available");
            }
            if (!properties.isSymbolRefreshEnabled()
                    && !targetSymbols.isEmpty()) {
                Future<?> task = symbolRefreshTask;
                symbolRefreshTask = null;
                if (task != null) {
                    task.cancel(false);
                }
            }
        } catch (InterruptedException ex) {
            Thread.currentThread().interrupt();
        } catch (Exception ex) {
            if (BinanceNetworkExceptionSupport.isTlsCertificateValidationFailure(ex)) {
                log.warn(
                        "Binance REST TLS certificate validation failed during ticker symbol refresh; "
                                + "keeping current symbols and retrying later: {}",
                        BinanceNetworkExceptionSupport.conciseMessage(ex)
                );
            } else {
                log.warn("Failed to refresh Binance market ticker symbols; keeping current symbols", ex);
            }
        }
    }

    private void refreshTargetSymbols() throws java.io.IOException, InterruptedException {
        Set<String> refreshed = marketDataClient.loadTargetSymbols()
                .stream()
                .map(BinanceUsdmSymbol::pair)
                .collect(java.util.stream.Collectors.toUnmodifiableSet());
        if (!refreshed.isEmpty()) {
            targetSymbols = refreshed;
        }
    }

    private void stopInternal() {
        if (monitorExecutor != null) {
            monitorExecutor.shutdownNow();
            monitorExecutor = null;
        }
        symbolRefreshTask = null;
        synchronized (connectionMonitor) {
            closeConnection("application stopping");
        }
        if (consumerExecutor != null) {
            consumerExecutor.shutdownNow();
            consumerExecutor = null;
        }
        targetSymbols = Set.of();
        reconnecting.set(false);
    }

    private void closeConnection(String reason) {
        if (consumerTask != null) {
            consumerTask.cancel(true);
            consumerTask = null;
        }
        StreamConnectionWrapper current = connection;
        connection = null;
        queue = null;
        stopConnection(current, reason);
    }

    private void stopConnection(
            StreamConnectionWrapper current,
            String reason
    ) {
        if (current == null) {
            return;
        }
        try {
            current.stop();
        } catch (Exception ex) {
            log.warn(
                    "Failed to stop Binance market ticker websocket cleanly: {}",
                    reason,
                    ex
            );
        }
    }
}
