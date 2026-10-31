package com.oovso.reference;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.oovso.external.ExternalMessage;
import com.oovso.external.ExternalMessageApiException;
import java.time.Instant;
import java.util.stream.Stream;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import org.springframework.http.HttpStatus;

class ReferenceTradeNotificationParserTest {

    private final ObjectMapper objectMapper = new ObjectMapper();

    private final ReferenceTradeNotificationParser parser =
            new ReferenceTradeNotificationParser();

    @ParameterizedTest
    @MethodSource("supportedTypes")
    void parsesEverySupportedType(ReferenceTradeNotificationType type)
            throws Exception {
        JsonNode payload = objectMapper.readTree(payload(type.name()));

        assertTrue(parser.supports(payload));
        ReferenceTradeNotification notification = parser.parse(
                message(),
                payload
        );

        assertEquals(type, notification.type());
        assertEquals("event-id", notification.eventId());
        assertEquals("标题 🚀", notification.title());
        assertEquals("> **币种**：BTCUSDT", notification.content());
        assertEquals(
                Instant.parse("2026-09-04T04:00:00Z"),
                notification.occurredAt()
        );
        assertEquals(message().receivedAt(), notification.receivedAt());
    }

    @Test
    void ignoresUnknownFieldsAndLeavesUnknownTypesForOtherHandlers()
            throws Exception {
        JsonNode known = objectMapper.readTree(payload("REDUCTION"));
        ((com.fasterxml.jackson.databind.node.ObjectNode) known).put(
                "futureField",
                "ignored"
        );
        assertEquals(
                ReferenceTradeNotificationType.REDUCTION,
                parser.parse(message(), known).type()
        );

        assertFalse(parser.supports(objectMapper.readTree("""
                {"type":"A_FUTURE_MESSAGE_TYPE"}
                """)));
        assertFalse(parser.supports(objectMapper.readTree("[]")));
    }

    @Test
    void rejectsInvalidKnownEnvelope() throws Exception {
        JsonNode invalidVersion = objectMapper.readTree(
                payload("OPEN").replace("\"schemaVersion\":1", "\"schemaVersion\":2")
        );
        ExternalMessageApiException versionException = assertThrows(
                ExternalMessageApiException.class,
                () -> parser.parse(message(), invalidVersion)
        );
        assertEquals(HttpStatus.BAD_REQUEST, versionException.status());

        JsonNode missingOffset = objectMapper.readTree(
                payload("OPEN").replace(
                        "2026-09-04T12:00:00+08:00",
                        "2026-09-04T12:00:00"
                )
        );
        ExternalMessageApiException timeException = assertThrows(
                ExternalMessageApiException.class,
                () -> parser.parse(message(), missingOffset)
        );
        assertEquals(HttpStatus.BAD_REQUEST, timeException.status());
    }

    private static Stream<ReferenceTradeNotificationType> supportedTypes() {
        return Stream.of(ReferenceTradeNotificationType.values());
    }

    private String payload(String type) {
        return """
                {
                  "schemaVersion":1,
                  "eventId":"event-id",
                  "type":"%s",
                  "title":"标题 🚀",
                  "content":"> **币种**：BTCUSDT",
                  "occurredAt":"2026-09-04T12:00:00+08:00"
                }
                """.formatted(type);
    }

    private ExternalMessage message() {
        return new ExternalMessage(
                "external-message-id",
                "{}",
                Instant.parse("2026-09-04T05:00:00Z")
        );
    }
}
