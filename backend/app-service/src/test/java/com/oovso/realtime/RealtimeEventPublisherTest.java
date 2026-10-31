package com.oovso.realtime;

import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.json.JsonMapper;
import com.oovso.notification.StrategyNotificationPreferenceMapper;
import com.oovso.notification.StrategyNotificationPreferenceMapper.PreferenceRow;
import com.oovso.notification.StrategyNotificationPreferenceService;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.web.socket.WebSocketMessage;
import org.springframework.web.socket.WebSocketSession;

class RealtimeEventPublisherTest {

    private final RealtimeProperties properties = new RealtimeProperties();
    private final RealtimeSessionRegistry registry = mock(RealtimeSessionRegistry.class);
    private final StrategyNotificationPreferenceMapper preferenceMapper =
            mock(StrategyNotificationPreferenceMapper.class);
    private final RealtimeEventPublisher publisher = new RealtimeEventPublisher(
            properties,
            registry,
            JsonMapper.builder().build(),
            new StrategyNotificationPreferenceService(preferenceMapper)
    );

    @AfterEach
    void shutdown() {
        publisher.shutdown();
    }

    @Test
    void filtersSignalsPerRecipientAndDefaultsMissingPreferencesToEnabled() throws Exception {
        // A single dispatcher keeps the allowed delivery behind both skipped recipients.
        properties.setDispatcherThreads(1);
        publisher.startDispatcher();
        Recipient disabled = recipient("disabled");
        Recipient otherInterval = recipient("one-hour-only");
        Recipient defaultEnabled = recipient("no-settings");
        when(preferenceMapper.selectByUser("disabled"))
                .thenReturn(new PreferenceRow(0, 0, 0));
        when(preferenceMapper.selectByUser("one-hour-only"))
                .thenReturn(new PreferenceRow(0, 1, 0));
        when(registry.matching("strategy.signal", "ETHUSDC", "4h", null))
                .thenReturn(List.of(disabled.client(), otherInterval.client(), defaultEnabled.client()));
        CountDownLatch delivered = sentLatch(defaultEnabled);

        publisher.publishPublic("strategy.signal", "created", "ETHUSDC", "ETHUSDC", "4h", Map.of());

        assertTrue(delivered.await(5, TimeUnit.SECONDS));
        verify(disabled.transport(), never()).sendMessage(any());
        verify(otherInterval.transport(), never()).sendMessage(any());
        verify(defaultEnabled.transport()).sendMessage(any());
    }

    @Test
    void suppressesSecondarySignalsAfterPreferenceChangesAndKeepsMarketUpdates() throws Exception {
        properties.setDispatcherThreads(1);
        publisher.startDispatcher();
        Recipient recipient = recipient("user-a");
        when(preferenceMapper.selectByUser("user-a"))
                .thenReturn(new PreferenceRow(1, 1, 1));
        when(registry.matching("strategy.signal", "ETHUSDC", "4h", "user-a"))
                .thenReturn(List.of(recipient.client()));
        CountDownLatch firstSignal = sentLatch(recipient);
        publisher.publishToUser("user-a", "strategy.signal", "created", "signal-1", "ETHUSDC", "4h", Map.of());
        assertTrue(firstSignal.await(5, TimeUnit.SECONDS));

        when(preferenceMapper.selectByUser("user-a"))
                .thenReturn(new PreferenceRow(0, 0, 0));
        CountDownLatch marketDelivered = sentLatch(recipient);
        when(registry.matching("market.kline", "ETHUSDC", "4h", null))
                .thenReturn(List.of(recipient.client()));
        publisher.publishToUser("user-a", "strategy.signal", "reversalTriggered", "signal-1", "ETHUSDC", "4h", Map.of());
        publisher.publishPublic("market.kline", "updated", "ETHUSDC", "ETHUSDC", "4h", Map.of());

        assertTrue(marketDelivered.await(5, TimeUnit.SECONDS));
        verify(recipient.transport(), never()).sendMessage(argThat(
                message -> message.getPayload().toString().contains("reversalTriggered")
        ));
        verify(recipient.transport()).sendMessage(argThat(
                message -> message.getPayload().toString().contains("market.kline")
        ));
    }

    private Recipient recipient(String userId) {
        WebSocketSession transport = mock(WebSocketSession.class);
        when(transport.getId()).thenReturn(userId + "-connection");
        when(transport.isOpen()).thenReturn(true);
        return new Recipient(
                new RealtimeClientSession(transport, userId, "test-token", properties),
                transport
        );
    }

    private CountDownLatch sentLatch(Recipient recipient) throws Exception {
        CountDownLatch delivered = new CountDownLatch(1);
        doAnswer(invocation -> {
            delivered.countDown();
            return null;
        }).when(recipient.transport()).sendMessage(any(WebSocketMessage.class));
        return delivered;
    }

    private record Recipient(RealtimeClientSession client, WebSocketSession transport) {
    }
}
