package com.oovso.trading;

import com.oovso.trading.BinanceUserDataStreamClient.Connection;
import com.oovso.trading.BinanceUserDataStreamClient.EventHandler;
import com.oovso.trading.TradingAccountLeaseService.Lease;
import jakarta.annotation.PreDestroy;
import java.net.URI;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;

@Component
public class TradingAccountSessionManager {

    private static final Logger log = LoggerFactory.getLogger(
            TradingAccountSessionManager.class
    );

    private final TradingProperties properties;
    private final TradingAccountMapper accountMapper;
    private final TradingPositionMapper positionMapper;
    private final ExchangeOrderMapper orderMapper;
    private final TradingCredentialCipher credentialCipher;
    private final BinanceUsdmPrivateGateway gateway;
    private final BinanceUserDataStreamClient streamClient;
    private final TradingUserStreamEventParser eventParser;
    private final TradingExchangeEventReducer eventReducer;
    private final TradingReconciliationService reconciliationService;
    private final TradingAccountLeaseService leaseService;
    private final TradingAccountSyncStateService syncStateService;
    private final TradingExecutionCoordinator executionCoordinator;
    private final Map<String, AccountWorker> workers = new ConcurrentHashMap<>();
    private final AtomicBoolean shuttingDown = new AtomicBoolean();

    public TradingAccountSessionManager(
            TradingProperties properties,
            TradingAccountMapper accountMapper,
            TradingPositionMapper positionMapper,
            ExchangeOrderMapper orderMapper,
            TradingCredentialCipher credentialCipher,
            BinanceUsdmPrivateGateway gateway,
            BinanceUserDataStreamClient streamClient,
            TradingUserStreamEventParser eventParser,
            TradingExchangeEventReducer eventReducer,
            TradingReconciliationService reconciliationService,
            TradingAccountLeaseService leaseService,
            TradingAccountSyncStateService syncStateService,
            TradingExecutionCoordinator executionCoordinator
    ) {
        this.properties = properties;
        this.accountMapper = accountMapper;
        this.positionMapper = positionMapper;
        this.orderMapper = orderMapper;
        this.credentialCipher = credentialCipher;
        this.gateway = gateway;
        this.streamClient = streamClient;
        this.eventParser = eventParser;
        this.eventReducer = eventReducer;
        this.reconciliationService = reconciliationService;
        this.leaseService = leaseService;
        this.syncStateService = syncStateService;
        this.executionCoordinator = executionCoordinator;
    }

    @EventListener(ApplicationReadyEvent.class)
    @Order(30)
    public void restoreSessions() {
        if (!properties.isEnabled() || !properties.getSync().isEnabled()) {
            return;
        }
        validateEnvironmentPair();
        for (TradingAccount account : accountMapper.selectListenableAccounts()) {
            startAccount(account.getId());
        }
    }

    public void startAccount(String accountId) {
        if (shuttingDown.get() || !properties.isEnabled()
                || !properties.getSync().isEnabled()) {
            return;
        }
        workers.compute(accountId, (id, current) -> {
            if (current != null && current.isRunning()) {
                return current;
            }
            AccountWorker created = new AccountWorker(id);
            created.start();
            return created;
        });
    }

    public void restartAccount(String accountId) {
        stopAccount(accountId);
        startAccount(accountId);
    }

    public void stopAccount(String accountId) {
        AccountWorker worker = workers.remove(accountId);
        if (worker != null) {
            worker.stop();
        }
    }

    public boolean requestReconcile(String accountId) {
        AccountWorker worker = workers.get(accountId);
        if (worker == null || !worker.isRunning()) {
            startAccount(accountId);
            worker = workers.get(accountId);
        }
        if (worker == null) {
            return false;
        }
        worker.requestFullReconcile();
        return true;
    }

    public boolean requestExecution(String accountId) {
        AccountWorker worker = workers.get(accountId);
        if (worker == null || !worker.isRunning()) {
            startAccount(accountId);
            worker = workers.get(accountId);
        }
        if (worker == null) {
            return false;
        }
        worker.wake();
        return true;
    }

    public boolean isRunning(String accountId) {
        AccountWorker worker = workers.get(accountId);
        return worker != null && worker.isRunning();
    }

    private void validateEnvironmentPair() {
        URI rest = URI.create(properties.getBinance().getRestBaseUrl());
        URI stream = URI.create(properties.getSync().getUserStreamBaseUrl());
        BinanceEnvironment restEnvironment = resolveEnvironment(rest);
        BinanceEnvironment streamEnvironment = resolveEnvironment(stream);
        if (restEnvironment != streamEnvironment) {
            throw new IllegalStateException(
                    "Binance private REST and user stream environments do not match"
            );
        }
    }

    private BinanceEnvironment resolveEnvironment(URI endpoint) {
        String host = endpoint.getHost() == null
                ? ""
                : endpoint.getHost().toLowerCase();
        if ("fapi.binance.com".equals(host)
                || "fstream.binance.com".equals(host)) {
            return BinanceEnvironment.MAINNET;
        }
        if ("testnet.binancefuture.com".equals(host)
                || "fstream.binancefuture.com".equals(host)) {
            return BinanceEnvironment.TESTNET;
        }
        throw new IllegalStateException(
                "Only Binance USD-M Mainnet or Futures Testnet endpoints are supported"
        );
    }

    private enum BinanceEnvironment {
        MAINNET,
        TESTNET
    }

    @PreDestroy
    void shutdown() {
        shuttingDown.set(true);
        workers.values().forEach(AccountWorker::stop);
        workers.clear();
    }

    private final class AccountWorker implements Runnable {

        private final String accountId;
        private final AtomicBoolean running = new AtomicBoolean(true);
        private final AtomicBoolean forceFullReconcile = new AtomicBoolean();
        private final AtomicBoolean forcePositionReconcile = new AtomicBoolean();
        private final AtomicLong receivedEventCount = new AtomicLong();
        private final AtomicReference<Connection> currentConnection =
                new AtomicReference<>();
        private final ArrayBlockingQueue<Inbound> queue = new ArrayBlockingQueue<>(
                Math.max(100, properties.getSync().getEventQueueCapacity())
        );
        private volatile Thread thread;

        private AccountWorker(String accountId) {
            this.accountId = accountId;
        }

        void start() {
            thread = Thread.ofVirtual()
                    .name("trading-account-" + accountId)
                    .start(this);
        }

        boolean isRunning() {
            return running.get() && thread != null && thread.isAlive();
        }

        void requestFullReconcile() {
            forceFullReconcile.set(true);
            queue.offer(WakeInbound.INSTANCE);
        }

        void wake() {
            queue.offer(WakeInbound.INSTANCE);
        }

        void stop() {
            running.set(false);
            Connection connection = currentConnection.getAndSet(null);
            if (connection != null) {
                connection.abort();
            }
            Thread current = thread;
            if (current != null) {
                current.interrupt();
            }
        }

        @Override
        public void run() {
            Lease lease = acquireLease();
            if (lease == null || !running.get()) {
                workers.remove(accountId, this);
                return;
            }
            LeaseHeartbeat heartbeat = new LeaseHeartbeat(lease);
            heartbeat.start();
            try {
                if (accountMapper.claimFence(accountId) != 1) {
                    return;
                }
                Long token = accountMapper.selectFenceToken(accountId);
                if (token == null) {
                    return;
                }
                long fenceToken = token;
                TradingAccount account = accountMapper.selectListenableById(
                        accountId
                );
                if (account == null) {
                    return;
                }
                BinanceCredentials credentials;
                try {
                    credentials = credentialCipher.decrypt(
                            account.getAppUserId(),
                            account
                    );
                } catch (TradingApiException exception) {
                    syncStateService.transition(
                            accountId,
                            fenceToken,
                            TradingSyncStatus.DEGRADED,
                            "CREDENTIAL_DECRYPTION_FAILED",
                            true
                    );
                    return;
                }
                runSessions(
                        lease,
                        fenceToken,
                        credentials,
                        account.getLastReconciledAtMs() != null
                );
            } catch (TradingExchangeEventReducer
                     .StaleTradingAccountWorkerException ignored) {
                log.info("Trading account worker lost fence accountId={}", accountId);
            } catch (TradingApiException exception) {
                log.warn(
                        "Trading account worker cannot decrypt credentials accountId={}: {}",
                        accountId,
                        exception.getMessage()
                );
            } catch (RuntimeException exception) {
                log.warn(
                        "Trading account worker stopped accountId={}: {}",
                        accountId,
                        exception.getMessage()
                );
            } finally {
                heartbeat.close();
                leaseService.release(lease);
                workers.remove(accountId, this);
            }
        }

        private Lease acquireLease() {
            long backoff = reconnectInitialBackoff();
            while (running.get()) {
                Lease lease = leaseService.tryAcquire(accountId);
                if (lease != null) {
                    return lease;
                }
                sleep(backoff);
                backoff = Math.min(reconnectMaxBackoff(), backoff * 2);
            }
            return null;
        }

        private void runSessions(
                Lease lease,
                long fenceToken,
                BinanceCredentials credentials,
                boolean recoveredExistingState
        ) {
            long backoff = reconnectInitialBackoff();
            boolean gapRecovery = recoveredExistingState;
            boolean hedgeModeConfigured = false;
            while (running.get()) {
                String listenKey = null;
                Connection connection = null;
                long retryAtMillis = 0;
                try {
                    queue.clear();
                    syncStateService.transition(
                            accountId,
                            fenceToken,
                            TradingSyncStatus.CONNECTING,
                            null,
                            false
                    );
                    if (!hedgeModeConfigured) {
                        String positionMode = gateway.enforceHedgeMode(
                                credentials
                        );
                        log.info(
                                "Binance hedge mode verified on startup "
                                        + "accountId={} positionMode={}",
                                accountId,
                                positionMode
                        );
                        hedgeModeConfigured = true;
                    }
                    listenKey = gateway.createListenKey(credentials);
                    connection = connect(listenKey);
                    currentConnection.set(connection);
                    long connectedAt = System.currentTimeMillis();
                    syncStateService.streamConnected(
                            accountId,
                            fenceToken,
                            connectedAt
                    );
                    converge(
                            fenceToken,
                            credentials,
                            true,
                            gapRecovery
                    );
                    syncStateService.transition(
                            accountId,
                            fenceToken,
                            TradingSyncStatus.SYNCED,
                            null,
                            false
                    );
                    gapRecovery = true;
                    backoff = reconnectInitialBackoff();
                    liveLoop(
                            fenceToken,
                            credentials,
                            listenKey,
                            connectedAt
                    );
                    throw new ReconnectRequiredException("STREAM_CLOSED");
                } catch (TradingExchangeEventReducer
                         .StaleTradingAccountWorkerException exception) {
                    throw exception;
                } catch (BinancePrivateApiException exception) {
                    if (BinanceUsdmPrivateRestClient.isAuthenticationError(
                            exception
                    )) {
                        syncStateService.authenticationFailed(
                                accountId,
                                fenceToken,
                                "BINANCE_AUTH_" + exception.code()
                        );
                        return;
                    }
                    retryAtMillis = exception.retryAtMillis();
                    degrade(fenceToken, errorCode(exception));
                } catch (ReconnectRequiredException exception) {
                    degrade(fenceToken, exception.code());
                } catch (RuntimeException exception) {
                    degrade(fenceToken, errorCode(exception));
                } finally {
                    currentConnection.compareAndSet(connection, null);
                    if (connection != null) {
                        connection.close();
                    }
                    if (listenKey != null) {
                        try {
                            gateway.closeListenKey(credentials, listenKey);
                        } catch (RuntimeException exception) {
                            log.warn(
                                    "Failed to close Binance listenKey accountId={}: {}",
                                    accountId,
                                    errorCode(exception)
                            );
                        }
                    }
                }
                if (running.get()) {
                    long normalDelay = withJitter(backoff);
                    long reconnectDelay = reconnectDelayMillis(
                            normalDelay,
                            retryAtMillis,
                            System.currentTimeMillis()
                    );
                    if (reconnectDelay > normalDelay) {
                        log.warn(
                                "Binance REST cooldown is delaying account session reconnect accountId={} retryAtMillis={}",
                                accountId,
                                retryAtMillis
                        );
                    }
                    sleep(reconnectDelay);
                    backoff = Math.min(reconnectMaxBackoff(), backoff * 2);
                }
            }
        }

        private Connection connect(String listenKey) {
            CompletableFuture<Connection> future = streamClient.connect(
                    listenKey,
                    new EventHandler() {
                        @Override
                        public void onMessage(
                                String message,
                                long receivedAtMillis
                        ) {
                            receivedEventCount.incrementAndGet();
                            offer(new EventInbound(message, receivedAtMillis));
                        }

                        @Override
                        public void onClosed(int statusCode, String reason) {
                            offer(new FailureInbound(
                                    new IllegalStateException(
                                            "User stream closed with status "
                                                    + statusCode
                                    )
                            ));
                        }

                        @Override
                        public void onFailure(Throwable failure) {
                            offer(new FailureInbound(failure));
                        }
                    }
            );
            try {
                return future.get(
                        properties.getBinance().getRequestTimeoutMillis(),
                        TimeUnit.MILLISECONDS
                );
            } catch (InterruptedException exception) {
                if (!running.get()) {
                    Thread.currentThread().interrupt();
                    throw new ReconnectRequiredException("WORKER_STOPPED");
                }
                return future.join();
            } catch (Exception exception) {
                throw new ReconnectRequiredException("STREAM_CONNECT_FAILED");
            }
        }

        private void offer(Inbound inbound) {
            if (queue.offer(inbound)) {
                return;
            }
            Connection connection = currentConnection.get();
            if (connection != null) {
                connection.abort();
            }
            queue.clear();
            queue.offer(new FailureInbound(
                    new IllegalStateException("User stream event queue overflow")
            ));
        }

        private void converge(
                long fenceToken,
                BinanceCredentials credentials,
                boolean fullDiscovery,
                boolean gapRecovery
        ) {
            int passes = Math.max(
                    1,
                    properties.getSync().getMaxConvergencePasses()
            );
            for (int pass = 1; pass <= passes; pass++) {
                syncStateService.transition(
                        accountId,
                        fenceToken,
                        TradingSyncStatus.RECONCILING,
                        null,
                        false
                );
                long before = receivedEventCount.get();
                reconciliationService.reconcile(
                        accountId,
                        fenceToken,
                        credentials,
                        fullDiscovery,
                        gapRecovery
                );
                int drained = drainCurrentQueue(fenceToken);
                long after = receivedEventCount.get();
                if (drained == 0 && after == before) {
                    return;
                }
            }
            throw new ReconnectRequiredException("CONVERGENCE_EXHAUSTED");
        }

        private void liveLoop(
                long fenceToken,
                BinanceCredentials credentials,
                String listenKey,
                long connectedAt
        ) {
            long now = System.currentTimeMillis();
            long nextKeepalive = now + Math.max(
                    60_000,
                    properties.getSync().getKeepaliveIntervalMillis()
            );
            long nextLightReconcile = now + reconcileInterval();
            long nextFullDiscovery = now + Math.max(
                    60_000,
                    properties.getSync().getFullDiscoveryIntervalMillis()
            );
            long rolloverAt = connectedAt + Math.max(
                    60_000,
                    properties.getSync().getConnectionRolloverMillis()
            );
            long nextStrategyEvaluation = now;

            while (running.get()) {
                Inbound inbound = pollInbound();
                if (inbound != null) {
                    processInbound(inbound, fenceToken);
                }
                now = System.currentTimeMillis();
                boolean strategyDue = now >= nextStrategyEvaluation;
                executionCoordinator.tick(
                        accountId,
                        fenceToken,
                        credentials,
                        strategyDue
                );
                if (strategyDue) {
                    nextStrategyEvaluation = now + Math.max(
                            1_000,
                            properties.getExecution()
                                    .getStrategyIntervalMillis()
                    );
                }
                if (now >= nextKeepalive) {
                    gateway.keepAliveListenKey(credentials, listenKey);
                    nextKeepalive = now + Math.max(
                            60_000,
                            properties.getSync().getKeepaliveIntervalMillis()
                    );
                }
                boolean forced = forceFullReconcile.getAndSet(false);
                boolean positionForced = forcePositionReconcile.getAndSet(
                        false
                );
                if (forced || now >= nextFullDiscovery) {
                    converge(fenceToken, credentials, true, false);
                    syncStateService.transition(
                            accountId,
                            fenceToken,
                            TradingSyncStatus.SYNCED,
                            null,
                            false
                    );
                    nextFullDiscovery = now + Math.max(
                            60_000,
                            properties.getSync().getFullDiscoveryIntervalMillis()
                    );
                    nextLightReconcile = now + reconcileInterval();
                } else if (positionForced || now >= nextLightReconcile) {
                    converge(fenceToken, credentials, false, false);
                    syncStateService.transition(
                            accountId,
                            fenceToken,
                            TradingSyncStatus.SYNCED,
                            null,
                            false
                    );
                    nextLightReconcile = now + reconcileInterval();
                }
                if (now >= rolloverAt) {
                    throw new ReconnectRequiredException("CONTROLLED_ROLLOVER");
                }
            }
        }

        private long reconcileInterval() {
            boolean active = !positionMapper.selectOpenByAccount(accountId).isEmpty()
                    || !orderMapper.selectActiveByAccount(accountId).isEmpty();
            return Math.max(
                    10_000,
                    active
                            ? properties.getSync()
                                    .getActiveReconcileIntervalMillis()
                            : properties.getSync()
                                    .getIdleReconcileIntervalMillis()
            );
        }

        private Inbound pollInbound() {
            try {
                return queue.poll(500, TimeUnit.MILLISECONDS);
            } catch (InterruptedException exception) {
                if (!running.get()) {
                    Thread.currentThread().interrupt();
                    throw new ReconnectRequiredException("WORKER_STOPPED");
                }
                return null;
            }
        }

        private int drainCurrentQueue(long fenceToken) {
            int available = queue.size();
            int drained = 0;
            for (int index = 0; index < available; index++) {
                Inbound inbound = queue.poll();
                if (inbound == null) {
                    return drained;
                }
                processInbound(inbound, fenceToken);
                drained++;
            }
            return drained;
        }

        private void processInbound(Inbound inbound, long fenceToken) {
            if (inbound instanceof WakeInbound) {
                return;
            }
            if (inbound instanceof FailureInbound failure) {
                throw new ReconnectRequiredException(
                        failure.failure() == null
                                ? "STREAM_FAILURE"
                                : errorCode(failure.failure())
                );
            }
            EventInbound message = (EventInbound) inbound;
            TradingUserStreamEvent event = eventParser.parse(
                    message.message(),
                    message.receivedAtMillis()
            );
            eventReducer.apply(accountId, fenceToken, event);
            if (event.kind() == TradingUserStreamEvent.Kind.ACCOUNT_UPDATE
                    && event.positions() != null
                    && !event.positions().isEmpty()) {
                forcePositionReconcile.set(true);
            }
            if (event.kind()
                    == TradingUserStreamEvent.Kind.LISTEN_KEY_EXPIRED) {
                throw new ReconnectRequiredException("LISTEN_KEY_EXPIRED");
            }
            if (event.kind() == TradingUserStreamEvent.Kind.RISK_OR_CONFIG) {
                forceFullReconcile.set(true);
            }
        }

        private void degrade(long fenceToken, String errorCode) {
            if (!running.get() || "WORKER_STOPPED".equals(errorCode)) {
                return;
            }
            try {
                syncStateService.transition(
                        accountId,
                        fenceToken,
                        TradingSyncStatus.DEGRADED,
                        errorCode,
                        true
                );
            } catch (TradingExchangeEventReducer
                     .StaleTradingAccountWorkerException exception) {
                throw exception;
            } catch (RuntimeException stateFailure) {
                log.warn(
                        "Failed to persist degraded trading sync state accountId={}",
                        accountId
                );
            }
        }

        private void sleep(long millis) {
            try {
                Thread.sleep(Math.max(1, millis));
            } catch (InterruptedException exception) {
                if (!running.get()) {
                    Thread.currentThread().interrupt();
                }
            }
        }

        private long withJitter(long value) {
            long jitter = Math.max(1, value / 5);
            return value - jitter
                    + java.util.concurrent.ThreadLocalRandom.current()
                    .nextLong(jitter * 2 + 1);
        }

        private long reconnectInitialBackoff() {
            return Math.max(
                    100,
                    properties.getSync().getReconnectInitialBackoffMillis()
            );
        }

        private long reconnectMaxBackoff() {
            return Math.max(
                    reconnectInitialBackoff(),
                    properties.getSync().getReconnectMaxBackoffMillis()
            );
        }

        private final class LeaseHeartbeat implements AutoCloseable {

            private final Lease lease;
            private final AtomicBoolean active = new AtomicBoolean(true);
            private volatile Thread heartbeatThread;

            private LeaseHeartbeat(Lease lease) {
                this.lease = lease;
            }

            void start() {
                heartbeatThread = Thread.ofVirtual()
                        .name("trading-lease-" + accountId)
                        .start(() -> {
                            long interval = Math.max(
                                    1_000,
                                    properties.getSync()
                                            .getLeaseRenewIntervalMillis()
                            );
                            while (active.get() && running.get()) {
                                try {
                                    Thread.sleep(interval);
                                } catch (InterruptedException exception) {
                                    Thread.currentThread().interrupt();
                                    return;
                                }
                                if (!active.get() || !running.get()) {
                                    return;
                                }
                                if (!leaseService.renew(lease)) {
                                    running.set(false);
                                    Connection connection = currentConnection
                                            .getAndSet(null);
                                    if (connection != null) {
                                        connection.abort();
                                    }
                                    Thread workerThread = thread;
                                    if (workerThread != null) {
                                        workerThread.interrupt();
                                    }
                                    return;
                                }
                            }
                        });
            }

            @Override
            public void close() {
                active.set(false);
                Thread current = heartbeatThread;
                if (current != null) {
                    current.interrupt();
                }
            }
        }
    }

    static long reconnectDelayMillis(
            long normalDelayMillis,
            long retryAtMillis,
            long nowMillis
    ) {
        return Math.max(
                Math.max(1, normalDelayMillis),
                Math.max(0, retryAtMillis - nowMillis)
        );
    }

    private String errorCode(Throwable failure) {
        if (failure instanceof BinancePrivateApiException api
                && api.code() != null) {
            return "BINANCE_" + api.code();
        }
        String name = failure == null
                ? "UNKNOWN"
                : failure.getClass().getSimpleName();
        if (name == null || name.isBlank()) {
            name = "UNKNOWN";
        }
        return name.replaceAll("[^A-Za-z0-9_.-]", "_");
    }

    private sealed interface Inbound permits EventInbound, FailureInbound,
            WakeInbound {
    }

    private record EventInbound(
            String message,
            long receivedAtMillis
    ) implements Inbound {
    }

    private record FailureInbound(Throwable failure) implements Inbound {
    }

    private enum WakeInbound implements Inbound {
        INSTANCE
    }

    private static final class ReconnectRequiredException
            extends RuntimeException {

        private final String code;

        private ReconnectRequiredException(String code) {
            super(code);
            this.code = Objects.requireNonNullElse(code, "RECONNECT_REQUIRED");
        }

        String code() {
            return code;
        }
    }
}
