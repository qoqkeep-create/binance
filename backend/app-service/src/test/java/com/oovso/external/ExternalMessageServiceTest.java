package com.oovso.external;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;

class ExternalMessageServiceTest {

    private static final String API_KEY = "a".repeat(32);

    private static final long RECEIVED_TIME_MS = 1_788_480_000_000L;

    @Test
    void storesOriginalJsonWithoutInspectingBusinessFields() {
        ExternalMessageProperties properties = enabledProperties();
        ExternalMessageStore store = org.mockito.Mockito.mock(
                ExternalMessageStore.class
        );
        ExternalMessageDispatcher dispatcher = org.mockito.Mockito.mock(
                ExternalMessageDispatcher.class
        );
        ExternalMessageService service = service(properties, store, dispatcher);
        String payload = """
                { "type": "unknown-to-receiver", "content": [1, 2, 3] }
                """;
        ExternalMessage message = new ExternalMessage(
                "message-id",
                payload,
                Instant.ofEpochMilli(RECEIVED_TIME_MS)
        );
        when(store.save(payload, RECEIVED_TIME_MS)).thenReturn(message);

        service.accept(API_KEY, payload);

        verify(store).save(payload, RECEIVED_TIME_MS);
        verify(dispatcher).dispatch(
                org.mockito.ArgumentMatchers.eq(message),
                org.mockito.ArgumentMatchers.any(JsonNode.class)
        );
    }

    @Test
    void rejectsWrongKeyBeforeJsonValidationAndDoesNotStore() {
        ExternalMessageStore store = org.mockito.Mockito.mock(
                ExternalMessageStore.class
        );
        ExternalMessageDispatcher dispatcher = org.mockito.Mockito.mock(
                ExternalMessageDispatcher.class
        );
        ExternalMessageService service = service(
                enabledProperties(),
                store,
                dispatcher
        );

        ExternalMessageApiException exception = assertThrows(
                ExternalMessageApiException.class,
                () -> service.accept("wrong", "not-json")
        );

        assertEquals(HttpStatus.UNAUTHORIZED, exception.status());
        verifyNoInteractions(store);
        verifyNoInteractions(dispatcher);
    }

    @Test
    void rejectsMalformedJsonAfterAuthorizationAndDoesNotStore() {
        ExternalMessageStore store = org.mockito.Mockito.mock(
                ExternalMessageStore.class
        );
        ExternalMessageDispatcher dispatcher = org.mockito.Mockito.mock(
                ExternalMessageDispatcher.class
        );
        ExternalMessageService service = service(
                enabledProperties(),
                store,
                dispatcher
        );

        ExternalMessageApiException exception = assertThrows(
                ExternalMessageApiException.class,
                () -> service.accept(API_KEY, "{not-json}")
        );

        assertEquals(HttpStatus.BAD_REQUEST, exception.status());
        verifyNoInteractions(store);
        verifyNoInteractions(dispatcher);
    }

    @Test
    void rejectsDisabledReceiverAndDoesNotStore() {
        ExternalMessageProperties properties = enabledProperties();
        properties.setEnabled(false);
        ExternalMessageStore store = org.mockito.Mockito.mock(
                ExternalMessageStore.class
        );
        ExternalMessageDispatcher dispatcher = org.mockito.Mockito.mock(
                ExternalMessageDispatcher.class
        );
        ExternalMessageService service = service(properties, store, dispatcher);

        ExternalMessageApiException exception = assertThrows(
                ExternalMessageApiException.class,
                () -> service.accept(API_KEY, "{}")
        );

        assertEquals(HttpStatus.SERVICE_UNAVAILABLE, exception.status());
        verifyNoInteractions(store);
        verifyNoInteractions(dispatcher);
    }

    private ExternalMessageService service(
            ExternalMessageProperties properties,
            ExternalMessageStore store,
            ExternalMessageDispatcher dispatcher
    ) {
        return new ExternalMessageService(
                properties,
                store,
                dispatcher,
                new ObjectMapper(),
                Clock.fixed(
                        Instant.ofEpochMilli(RECEIVED_TIME_MS),
                        ZoneOffset.UTC
                )
        );
    }

    private ExternalMessageProperties enabledProperties() {
        ExternalMessageProperties properties = new ExternalMessageProperties();
        properties.setEnabled(true);
        properties.setApiKey(API_KEY);
        return properties;
    }
}
