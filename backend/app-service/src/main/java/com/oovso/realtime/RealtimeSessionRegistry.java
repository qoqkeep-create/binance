package com.oovso.realtime;

import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import java.util.Collection;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;
import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.WebSocketSession;

@Component
public class RealtimeSessionRegistry {

    private static final Logger log = LoggerFactory.getLogger(RealtimeSessionRegistry.class);

    private static final CloseStatus CLIENT_TIMEOUT = new CloseStatus(4008, "Client heartbeat timeout");

    private final RealtimeProperties properties;

    private final Map<String, RealtimeClientSession> sessions = new ConcurrentHashMap<>();

    private ScheduledExecutorService timeoutMonitor;

    public RealtimeSessionRegistry(RealtimeProperties properties) {
        this.properties = properties;
    }

    @PostConstruct
    void startTimeoutMonitor() {
        if (!properties.isEnabled()) {
            return;
        }
        timeoutMonitor = Executors.newSingleThreadScheduledExecutor(task -> {
            Thread thread = new Thread(task, "app-websocket-heartbeat");
            thread.setDaemon(true);
            return thread;
        });
        long timeoutMillis = Math.max(2_000, properties.getClientTimeoutMillis());
        long monitorInterval = Math.max(1_000, Math.min(timeoutMillis / 2, 10_000));
        timeoutMonitor.scheduleWithFixedDelay(
                this::closeTimedOutSessions,
                monitorInterval,
                monitorInterval,
                TimeUnit.MILLISECONDS
        );
    }

    RealtimeClientSession register(
            WebSocketSession session,
            String userId,
            String token
    ) {
        RealtimeClientSession client = new RealtimeClientSession(
                session,
                userId,
                token,
                properties
        );
        sessions.put(client.id(), client);
        log.info(
                "APP_WEBSOCKET_CONNECTED connectionId={} userId={} activeConnections={}",
                client.id(),
                userId,
                sessions.size()
        );
        return client;
    }

    RealtimeClientSession get(String sessionId) {
        return sessions.get(sessionId);
    }

    void remove(String sessionId) {
        RealtimeClientSession removed = sessions.remove(sessionId);
        if (removed != null) {
            log.info(
                    "APP_WEBSOCKET_DISCONNECTED connectionId={} userId={} activeConnections={}",
                    removed.id(),
                    removed.userId(),
                    sessions.size()
            );
        }
    }

    void subscribe(
            RealtimeClientSession client,
            List<RealtimeProtocol.SubscriptionRequest> requests
    ) {
        if (requests == null || requests.isEmpty()) {
            throw new RealtimeProtocolException("SUBSCRIPTIONS_REQUIRED", "订阅列表不能为空");
        }
        if (requests.size() > Math.max(1, properties.getMaxSubscriptionsPerSession())) {
            throw new RealtimeProtocolException("TOO_MANY_SUBSCRIPTIONS", "订阅频道数量超过限制");
        }
        List<RealtimeSubscription> subscriptions = requests.stream()
                .map(request -> RealtimeSubscription.from(request, properties))
                .toList();
        HashSet<String> resultingChannels = new HashSet<>();
        client.subscriptions().forEach(subscription ->
                resultingChannels.add(subscription.channel())
        );
        subscriptions.forEach(subscription ->
                resultingChannels.add(subscription.channel())
        );
        if (resultingChannels.size() > Math.max(1, properties.getMaxSubscriptionsPerSession())) {
            throw new RealtimeProtocolException("TOO_MANY_SUBSCRIPTIONS", "订阅频道数量超过限制");
        }
        subscriptions.forEach(client::putSubscription);
    }

    void unsubscribe(
            RealtimeClientSession client,
            List<RealtimeProtocol.SubscriptionRequest> requests
    ) {
        if (requests == null || requests.isEmpty()) {
            throw new RealtimeProtocolException("SUBSCRIPTIONS_REQUIRED", "退订列表不能为空");
        }
        for (RealtimeProtocol.SubscriptionRequest request : requests) {
            if (request == null || !StringUtils.hasText(request.channel())) {
                continue;
            }
            client.removeSubscription(request.channel().trim().toLowerCase(Locale.ROOT));
        }
    }

    Collection<RealtimeSubscription> subscriptions(RealtimeClientSession client) {
        return client.subscriptions();
    }

    List<RealtimeClientSession> matching(
            String channel,
            String symbol,
            String interval,
            String targetUserId
    ) {
        return sessions.values().stream()
                .filter(RealtimeClientSession::isOpen)
                .filter(session -> session.matches(
                        channel,
                        symbol,
                        interval,
                        targetUserId
                ))
                .toList();
    }

    boolean hasSubscribers(String channel, String symbol, String interval) {
        return sessions.values().stream().anyMatch(session ->
                session.isOpen() && session.matches(channel, symbol, interval, null)
        );
    }

    int activeConnectionCount() {
        return sessions.size();
    }

    private void closeTimedOutSessions() {
        long now = System.currentTimeMillis();
        long timeoutMillis = Math.max(2_000, properties.getClientTimeoutMillis());
        for (RealtimeClientSession client : sessions.values()) {
            if (client.idleMillis(now) <= timeoutMillis) {
                continue;
            }
            log.warn(
                    "APP_WEBSOCKET_TIMEOUT connectionId={} userId={} idleMillis={}",
                    client.id(),
                    client.userId(),
                    client.idleMillis(now)
            );
            client.close(CLIENT_TIMEOUT);
            remove(client.id());
        }
    }

    @PreDestroy
    void shutdown() {
        if (timeoutMonitor != null) {
            timeoutMonitor.shutdownNow();
        }
        sessions.values().forEach(client ->
                client.close(CloseStatus.GOING_AWAY)
        );
        sessions.clear();
    }
}
