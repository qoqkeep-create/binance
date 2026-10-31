package com.oovso.reference;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.oovso.auth.AppUser;
import com.oovso.auth.AppUserMapper;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;

class ReferenceTradeNotificationQueryServiceTest {

    private final AppUserMapper userMapper = mock(AppUserMapper.class);

    private final ReferenceTradeNotificationAccess access = mock(
            ReferenceTradeNotificationAccess.class
    );

    private final ReferenceTradeNotificationMapper mapper = mock(
            ReferenceTradeNotificationMapper.class
    );

    private ReferenceTradeNotificationQueryService queryService;

    @BeforeEach
    void setUp() {
        queryService = new ReferenceTradeNotificationQueryService(
                userMapper,
                access,
                mapper
        );
        AppUser user = new AppUser();
        user.setId("target-user");
        when(userMapper.selectActiveById("target-user")).thenReturn(user);
        when(access.canView(user)).thenReturn(true);
    }

    @Test
    void returnsEnvelopeFieldsAndCursorPagination() {
        List<ReferenceTradeNotificationRow> rows = new ArrayList<>();
        for (int index = 0; index < 21; index++) {
            rows.add(row(index));
        }
        when(mapper.selectPage(
                anyLong(),
                anyString(),
                eq(ReferenceTradeNotificationQueryService.PAGE_SIZE + 1)
        )).thenReturn(rows);

        var page = queryService.query("target-user", null);

        assertEquals(20, page.items().size());
        assertTrue(page.hasNext());
        assertFalse(page.nextCursor().isBlank());
        var first = page.items().getFirst();
        assertEquals("event-0", first.eventId());
        assertEquals(1, first.schemaVersion());
        assertEquals(ReferenceTradeNotificationType.OPEN, first.type());
        assertEquals("标题 0", first.title());
        assertEquals("> **价格**：100", first.content());
        assertEquals(Instant.ofEpochMilli(2_000), first.occurredAt());
    }

    @Test
    void rejectsUnauthorizedUserAndInvalidCursor() {
        AppUser other = new AppUser();
        when(userMapper.selectActiveById("other-user")).thenReturn(other);
        when(access.canView(other)).thenReturn(false);

        ReferenceTradeNotificationApiException forbidden = assertThrows(
                ReferenceTradeNotificationApiException.class,
                () -> queryService.query("other-user", null)
        );
        assertEquals(HttpStatus.FORBIDDEN, forbidden.status());

        ReferenceTradeNotificationApiException invalidCursor = assertThrows(
                ReferenceTradeNotificationApiException.class,
                () -> queryService.query("target-user", "not-a-cursor")
        );
        assertEquals(HttpStatus.BAD_REQUEST, invalidCursor.status());
    }

    private ReferenceTradeNotificationRow row(int index) {
        ReferenceTradeNotificationRow row = new ReferenceTradeNotificationRow();
        row.setId("00000000-0000-0000-0000-%012d".formatted(index));
        row.setExternalMessageId("message-" + index);
        row.setEventId("event-" + index);
        row.setSchemaVersion(1);
        row.setNotificationType("OPEN");
        row.setTitle("标题 " + index);
        row.setContent("> **价格**：100");
        row.setOccurredTimeMs(2_000L + index);
        row.setReceivedTimeMs(1_000L - index);
        return row;
    }
}
