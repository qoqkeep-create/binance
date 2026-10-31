package com.oovso.realtime;

import java.io.IOException;
import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;
import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.handler.ConcurrentWebSocketSessionDecorator;

final class RealtimeClientSession {

    private final WebSocketSession session;

    private final String userId;

    private final String token;

    private final Map<String, RealtimeSubscription> subscriptions = new ConcurrentHashMap<>();

    private final AtomicLong lastClientActivityAt = new AtomicLong(System.currentTimeMillis());

    RealtimeClientSession(
            WebSocketSession session,
            String userId,
            String token,
            RealtimeProperties properties
    ) {
        this.session = new ConcurrentWebSocketSessionDecorator(
                session,
                Math.max(1_000, properties.getSendTimeLimitMillis()),
                Math.max(65_536, properties.getSendBufferBytes())
        );
        this.userId = userId;
        this.token = token;
    }

    String id() {
        return session.getId();
    }

    String userId() {
        return userId;
    }

    String token() {
        return token;
    }

    boolean isOpen() {
        return session.isOpen();
    }

    void touch() {
        lastClientActivityAt.set(System.currentTimeMillis());
    }

    long idleMillis(long now) {
        return Math.max(0, now - lastClientActivityAt.get());
    }

    void putSubscription(RealtimeSubscription subscription) {
        subscriptions.put(subscription.channel(), subscription);
    }

    void removeSubscription(String channel) {
        subscriptions.remove(channel);
    }

    Collection<RealtimeSubscription> subscriptions() {
        return List.copyOf(subscriptions.values());
    }

    boolean matches(
            String channel,
            String symbol,
            String interval,
            String targetUserId
    ) {
        if (targetUserId != null && !targetUserId.equals(userId)) {
            return false;
        }
        RealtimeSubscription subscription = subscriptions.get(channel);
        return subscription != null && subscription.matches(symbol, interval);
    }

    void send(String payload) throws IOException {
        if (session.isOpen()) {
            session.sendMessage(new TextMessage(payload));
        }
    }

    void close(CloseStatus status) {
        try {
            if (session.isOpen()) {
                session.close(status);
            }
        } catch (IOException ignored) {
            // The transport is already being discarded.
        }
    }
}
