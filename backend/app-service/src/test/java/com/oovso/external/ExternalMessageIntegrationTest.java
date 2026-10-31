package com.oovso.external;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.reset;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;

import com.oovso.reference.ReferenceTradeNotificationListener;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.bean.override.mockito.MockitoBean;

@ActiveProfiles("test")
@SpringBootTest(properties = {
        "external-message.enabled=true",
        "external-message.api-key=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
})
class ExternalMessageIntegrationTest {

    @Autowired
    private ExternalMessageService messageService;

    @Autowired
    private JdbcTemplate jdbcTemplate;

    @MockitoBean
    private ReferenceTradeNotificationListener notificationListener;

    @BeforeEach
    void clearMessages() {
        jdbcTemplate.update("delete from reference_trade_notification");
        jdbcTemplate.update("delete from external_message");
        reset(notificationListener);
    }

    @Test
    void storesJsonBodyVerbatim() {
        String payload = """
                {
                  "schemaVersion": 1,
                  "type": "SENDER_DEFINED_EVENT",
                  "title": "sender-owned title",
                  "content": {"unparsed": true}
                }
                """;

        messageService.accept(
                "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                payload
        );

        assertEquals(
                payload,
                jdbcTemplate.queryForObject(
                        "select payload_json from external_message",
                        String.class
                )
        );
        assertEquals(
                1,
                jdbcTemplate.queryForObject(
                        "select count(1) from external_message",
                        Integer.class
                )
        );
    }

    @Test
    void projectsKnownReferenceNotificationAndNotifiesAfterCommitOnce() {
        String payload = """
                {
                  "schemaVersion": 1,
                  "eventId": "trade:open:1001:123456789",
                  "type": "OPEN",
                  "title": "🚀 BTCUSDT 多单 开仓",
                  "content": "> **币种**：BTCUSDT\\n> **成交价**：110000",
                  "occurredAt": "2026-09-04T12:00:00+08:00",
                  "futureField": {"ignored": true}
                }
                """;

        messageService.accept(
                "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                payload
        );
        messageService.accept(
                "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                payload
        );

        assertEquals(
                2,
                jdbcTemplate.queryForObject(
                        "select count(1) from external_message",
                        Integer.class
                )
        );
        assertEquals(
                1,
                jdbcTemplate.queryForObject(
                        "select count(1) from reference_trade_notification",
                        Integer.class
                )
        );
        assertEquals(
                "> **币种**：BTCUSDT\n> **成交价**：110000",
                jdbcTemplate.queryForObject(
                        "select content from reference_trade_notification",
                        String.class
                )
        );
        verify(notificationListener, times(1)).onNotification(
                org.mockito.ArgumentMatchers.argThat(notification ->
                        notification.eventId().equals(
                                "trade:open:1001:123456789"
                        )
                )
        );
    }

    @Test
    void rollsBackInboxWhenKnownReferencePayloadIsInvalid() {
        ExternalMessageApiException exception = assertThrows(
                ExternalMessageApiException.class,
                () -> messageService.accept(
                        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                        """
                        {
                          "schemaVersion": 1,
                          "eventId": "broken-event",
                          "type": "STOP_LOSS"
                        }
                        """
                )
        );

        assertEquals(
                org.springframework.http.HttpStatus.BAD_REQUEST,
                exception.status()
        );
        assertEquals(
                0,
                jdbcTemplate.queryForObject(
                        "select count(1) from external_message",
                        Integer.class
                )
        );
        assertEquals(
                0,
                jdbcTemplate.queryForObject(
                        "select count(1) from reference_trade_notification",
                        Integer.class
                )
        );
    }

    @Test
    void invalidKeyDoesNotWriteToDatabase() {
        ExternalMessageApiException exception = assertThrows(
                ExternalMessageApiException.class,
                () -> messageService.accept("wrong-key", "{}")
        );

        assertEquals(
                0,
                jdbcTemplate.queryForObject(
                        "select count(1) from external_message",
                        Integer.class
                )
        );
        assertEquals(
                org.springframework.http.HttpStatus.UNAUTHORIZED,
                exception.status()
        );
    }
}
