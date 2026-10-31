package com.oovso.reference;

import com.fasterxml.jackson.databind.JsonNode;
import com.oovso.external.ExternalMessage;
import com.oovso.external.ExternalMessageHandler;
import java.util.List;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

@Component
public class ReferenceTradeMessageHandler implements ExternalMessageHandler {

    private static final Logger log = LoggerFactory.getLogger(
            ReferenceTradeMessageHandler.class
    );

    private final ReferenceTradeNotificationParser parser;

    private final ReferenceTradeNotificationStore store;

    private final List<ReferenceTradeNotificationListener> listeners;

    public ReferenceTradeMessageHandler(
            ReferenceTradeNotificationParser parser,
            ReferenceTradeNotificationStore store,
            List<ReferenceTradeNotificationListener> listeners
    ) {
        this.parser = parser;
        this.store = store;
        this.listeners = List.copyOf(listeners);
    }

    @Override
    public boolean supports(JsonNode payload) {
        return parser.supports(payload);
    }

    @Override
    public void handle(ExternalMessage message, JsonNode payload) {
        ReferenceTradeNotification notification = parser.parse(message, payload);
        if (store.saveIfAbsent(notification)) {
            notifyAfterCommit(notification);
        }
    }

    void notifyAfterCommit(ReferenceTradeNotification notification) {
        if (listeners.isEmpty()) {
            return;
        }
        Runnable notifier = () -> listeners.forEach(listener -> {
            try {
                listener.onNotification(notification);
            } catch (Exception exception) {
                log.warn(
                        "Reference notification listener {} failed for event {}",
                        listener.getClass().getName(),
                        notification.eventId(),
                        exception
                );
            }
        });
        if (!TransactionSynchronizationManager.isSynchronizationActive()) {
            notifier.run();
            return;
        }
        TransactionSynchronizationManager.registerSynchronization(
                new TransactionSynchronization() {
                    @Override
                    public void afterCommit() {
                        notifier.run();
                    }
                }
        );
    }
}
