package com.oovso.realtime;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.oovso.notification.StrategyNotificationPreferenceService;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

@Component
public class RealtimeEventPublisher {

    private static final Logger log = LoggerFactory.getLogger(RealtimeEventPublisher.class);

    private final RealtimeProperties properties;

    private final RealtimeSessionRegistry registry;

    private final ObjectMapper objectMapper;

    private final StrategyNotificationPreferenceService notificationPreferences;

    private final Map<String, AtomicLong> streamSequences = new ConcurrentHashMap<>();

    private final AtomicLong droppedDispatchTasks = new AtomicLong();

    private ThreadPoolExecutor dispatcher;

    public RealtimeEventPublisher(
            RealtimeProperties properties,
            RealtimeSessionRegistry registry,
            ObjectMapper objectMapper,
            StrategyNotificationPreferenceService notificationPreferences
    ) {
        this.properties = properties;
        this.registry = registry;
        this.objectMapper = objectMapper;
        this.notificationPreferences = notificationPreferences;
    }

    @PostConstruct
    void startDispatcher() {
        int threads = Math.max(1, properties.getDispatcherThreads());
        int queueCapacity = Math.max(100, properties.getDispatcherQueueCapacity());
        dispatcher = new ThreadPoolExecutor(
                threads,
                threads,
                0,
                TimeUnit.MILLISECONDS,
                new ArrayBlockingQueue<>(queueCapacity),
                task -> {
                    Thread thread = new Thread(task, "app-websocket-dispatch");
                    thread.setDaemon(true);
                    return thread;
                },
                (task, executor) -> {
                    long dropped = droppedDispatchTasks.incrementAndGet();
                    if (dropped == 1 || dropped % 1_000 == 0) {
                        log.warn(
                                "Dropped {} APP WebSocket dispatch tasks because the bounded queue is full",
                                dropped
                        );
                    }
                }
        );
    }

    public boolean hasSubscribers(String channel, String symbol, String interval) {
        return properties.isEnabled() && registry.hasSubscribers(channel, symbol, interval);
    }

    public void publishPublic(
            String channel,
            String event,
            String key,
            String symbol,
            String interval,
            Object data
    ) {
        publish(channel, event, key, symbol, interval, null, data);
    }

    public void publishToUser(
            String userId,
            String channel,
            String event,
            String key,
            String symbol,
            String interval,
            Object data
    ) {
        publish(channel, event, key, symbol, interval, userId, data);
    }

    private void publish(
            String channel,
            String event,
            String key,
            String symbol,
            String interval,
            String targetUserId,
            Object data
    ) {
        if (!properties.isEnabled() || dispatcher == null) {
            return;
        }
        List<RealtimeClientSession> recipients = registry.matching(
                channel,
                symbol,
                interval,
                targetUserId
        );
        if (recipients.isEmpty()) {
            return;
        }

        long sequence = streamSequences
                .computeIfAbsent(sequenceKey(channel, key), ignored -> new AtomicLong())
                .incrementAndGet();
        String payload;
        try {
            payload = objectMapper.writeValueAsString(
                    RealtimeProtocol.ServerMessage.event(
                            channel,
                            event,
                            key,
                            sequence,
                            data
                    )
            );
        } catch (JsonProcessingException exception) {
            log.warn("Failed to serialize APP WebSocket event channel={} key={}", channel, key, exception);
            return;
        }

        for (RealtimeClientSession recipient : recipients) {
            dispatcher.execute(() -> send(recipient, payload, channel, key, interval));
        }
    }

    private void send(
            RealtimeClientSession recipient,
            String payload,
            String channel,
            String key,
            String interval
    ) {
        if (RealtimeProtocol.CHANNEL_STRATEGY_SIGNAL.equals(channel)) {
            try {
                if (!notificationPreferences.preferences(recipient.userId())
                        .enabledForInterval(interval)) {
                    return;
                }
            } catch (RuntimeException exception) {
                log.warn(
                        "Skipped APP strategy event because preferences could not be read userId={} interval={}: {}",
                        recipient.userId(),
                        interval,
                        exception.getMessage()
                );
                return;
            }
        }
        try {
            recipient.send(payload);
        } catch (Exception exception) {
            log.warn(
                    "Failed to send APP WebSocket event connectionId={} channel={} key={}: {}",
                    recipient.id(),
                    channel,
                    key,
                    exception.getMessage()
            );
            recipient.close(CloseStatuses.SERVER_ERROR);
            registry.remove(recipient.id());
        }
    }

    private String sequenceKey(String channel, String key) {
        return channel + ':' + (key == null ? "" : key);
    }

    @PreDestroy
    void shutdown() {
        if (dispatcher != null) {
            dispatcher.shutdownNow();
        }
    }

    private static final class CloseStatuses {

        private static final org.springframework.web.socket.CloseStatus SERVER_ERROR =
                new org.springframework.web.socket.CloseStatus(1011, "Realtime delivery failed");

        private CloseStatuses() {
        }
    }
}
