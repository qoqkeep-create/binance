package com.oovso.trading;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.oovso.realtime.RealtimeEventPublisher;
import jakarta.annotation.PreDestroy;
import java.util.List;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;

@Component
public class TradingOutboxPublisher {

    private static final Logger log = LoggerFactory.getLogger(
            TradingOutboxPublisher.class
    );

    private final TradingProperties properties;
    private final TradingOutboxMapper outboxMapper;
    private final RealtimeEventPublisher realtimePublisher;
    private final ObjectMapper objectMapper;
    private ScheduledExecutorService executor;

    public TradingOutboxPublisher(
            TradingProperties properties,
            TradingOutboxMapper outboxMapper,
            RealtimeEventPublisher realtimePublisher,
            ObjectMapper objectMapper
    ) {
        this.properties = properties;
        this.outboxMapper = outboxMapper;
        this.realtimePublisher = realtimePublisher;
        this.objectMapper = objectMapper;
    }

    @EventListener(ApplicationReadyEvent.class)
    @Order(20)
    public void start() {
        if (!properties.getSync().isEnabled() || executor != null) {
            return;
        }
        executor = Executors.newSingleThreadScheduledExecutor(task -> {
            Thread thread = new Thread(task, "trading-outbox-publisher");
            thread.setDaemon(true);
            return thread;
        });
        long interval = Math.max(
                100,
                properties.getSync().getOutboxPollIntervalMillis()
        );
        executor.scheduleWithFixedDelay(
                this::publishBatchSafely,
                0,
                interval,
                TimeUnit.MILLISECONDS
        );
    }

    private void publishBatchSafely() {
        try {
            long now = System.currentTimeMillis();
            outboxMapper.releaseStaleClaims(now - 60_000, now);
            List<TradingOutbox> batch = outboxMapper.selectPending(
                    now,
                    Math.max(1, properties.getSync().getOutboxBatchSize())
            );
            for (TradingOutbox outbox : batch) {
                publish(outbox);
            }
        } catch (Exception exception) {
            log.warn("Trading outbox polling failed: {}", exception.getMessage());
        }
    }

    private void publish(TradingOutbox outbox) {
        long claimedAt = System.currentTimeMillis();
        if (outboxMapper.claim(outbox.getId(), claimedAt) != 1) {
            return;
        }
        try {
            JsonNode payload = objectMapper.readTree(outbox.getPayloadJson());
            realtimePublisher.publishToUser(
                    outbox.getAppUserId(),
                    outbox.getChannel(),
                    outbox.getEventName(),
                    outbox.getEventKey(),
                    outbox.getSymbol(),
                    null,
                    payload
            );
            outboxMapper.markPublished(outbox.getId(), System.currentTimeMillis());
        } catch (Exception exception) {
            long attempts = outbox.getAttempts() == null
                    ? 0
                    : outbox.getAttempts();
            long delay = Math.min(60_000, 1_000L << Math.min(6, attempts));
            outboxMapper.markRetry(
                    outbox.getId(),
                    System.currentTimeMillis() + delay
            );
            log.warn(
                    "Trading outbox publish failed id={} channel={}: {}",
                    outbox.getId(),
                    outbox.getChannel(),
                    exception.getMessage()
            );
        }
    }

    @PreDestroy
    void stop() {
        if (executor != null) {
            executor.shutdownNow();
        }
    }
}
