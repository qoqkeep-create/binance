package com.oovso.strategy;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.oovso.strategy.StrategySignalQueryService.StrategySignalPage;
import com.oovso.strategy.StrategySignalQueryService.StrategySignalItem;
import com.fasterxml.jackson.databind.json.JsonMapper;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.http.HttpStatus;

class StrategySignalQueryServiceTest {

    @Test
    void serializesReadStateWithIosFieldName() throws Exception {
        StrategySignalItem item = new StrategySignalItem(
                "00000000-0000-0000-0000-000000000001",
                "BTCUSDC",
                "4h",
                "EMA144回踩",
                "LONG",
                new BigDecimal("64000.25"),
                Instant.parse("2026-08-09T04:00:00.123Z"),
                true,
                "NONE",
                null
        );

        var json = JsonMapper.builder()
                .findAndAddModules()
                .build()
                .valueToTree(item);

        assertTrue(json.path("isRead").asBoolean());
        assertEquals("4h", json.path("interval").asText());
        assertEquals(
                "2026-08-09T04:00:00.123Z",
                json.path("triggeredAt").asText()
        );
    }

    @Test
    void returnsTenItemsAndUsesStableCursorForNextPage() {
        StrategySignalMapper mapper = mock(StrategySignalMapper.class);
        StrategySignalQueryService service =
                new StrategySignalQueryService(mapper);
        List<StrategySignalFeedRow> rows = java.util.stream.IntStream
                .rangeClosed(0, 10)
                .mapToObj(index -> row(
                        100 - index,
                        index == 0,
                        index
                ))
                .toList();
        when(mapper.selectFeedPage(
                "user-a",
                Long.MAX_VALUE,
                "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz",
                11
        )).thenReturn(rows);

        StrategySignalPage firstPage = service.query("user-a", null);

        assertEquals(10, firstPage.size());
        assertEquals(10, firstPage.items().size());
        assertTrue(firstPage.hasNext());
        assertNotNull(firstPage.nextCursor());
        assertTrue(firstPage.items().getFirst().isRead());
        assertEquals(
                "EMA144回踩",
                firstPage.items().getFirst().strategyName()
        );

        StrategySignalFeedRow lastIncluded = rows.get(9);
        when(mapper.selectFeedPage(
                "user-a",
                lastIncluded.getSignalTimeMs(),
                lastIncluded.getId(),
                11
        )).thenReturn(List.of());

        StrategySignalPage secondPage = service.query(
                "user-a",
                firstPage.nextCursor()
        );

        assertFalse(secondPage.hasNext());
        assertTrue(secondPage.items().isEmpty());
        verify(mapper).selectFeedPage(
                "user-a",
                lastIncluded.getSignalTimeMs(),
                lastIncluded.getId(),
                11
        );
    }

    @Test
    void rejectsInvalidCursor() {
        StrategySignalQueryService service =
                new StrategySignalQueryService(
                        mock(StrategySignalMapper.class)
                );

        StrategySignalApiException exception = assertThrows(
                StrategySignalApiException.class,
                () -> service.query("user-a", "not-a-cursor")
        );

        assertEquals(HttpStatus.BAD_REQUEST, exception.status());
    }

    @Test
    void markReadIsIdempotentWhenReceiptAlreadyExists() {
        StrategySignalMapper mapper = mock(StrategySignalMapper.class);
        StrategySignalQueryService service =
                new StrategySignalQueryService(mapper);
        String signalId = "00000000-0000-0000-0000-000000000001";
        when(mapper.countVisibleById("user-a", signalId)).thenReturn(1);
        doThrow(new DuplicateKeyException("duplicate"))
                .when(mapper)
                .insertReadReceipt(
                        org.mockito.ArgumentMatchers.eq("user-a"),
                        org.mockito.ArgumentMatchers.eq(signalId),
                        anyLong()
                );

        assertDoesNotThrow(() -> service.markRead("user-a", signalId));
    }

    @Test
    void markReadRejectsMissingSignal() {
        StrategySignalMapper mapper = mock(StrategySignalMapper.class);
        StrategySignalQueryService service =
                new StrategySignalQueryService(mapper);
        String signalId = "00000000-0000-0000-0000-000000000001";
        when(mapper.countVisibleById("user-a", signalId)).thenReturn(0);

        StrategySignalApiException exception = assertThrows(
                StrategySignalApiException.class,
                () -> service.markRead("user-a", signalId)
        );

        assertEquals(HttpStatus.NOT_FOUND, exception.status());
        assertEquals("策略信号不存在", exception.getMessage());
    }

    @Test
    void activatesOrReactivatesOneShotSecondaryAlert() {
        StrategySignalMapper mapper = mock(StrategySignalMapper.class);
        StrategySignalQueryService service =
                new StrategySignalQueryService(mapper);
        String signalId = "00000000-0000-0000-0000-000000000001";
        when(mapper.countVisibleById("user-a", signalId)).thenReturn(1);
        when(mapper.activateReversalAlert(
                org.mockito.ArgumentMatchers.eq("user-a"),
                org.mockito.ArgumentMatchers.eq(signalId),
                anyLong()
        )).thenReturn(1);

        var result = service.activateReversalAlert("user-a", signalId);

        assertEquals("ACTIVE", result.state());
        verify(mapper).insertUserStateIfMissing(
                org.mockito.ArgumentMatchers.eq("user-a"),
                org.mockito.ArgumentMatchers.eq(signalId),
                anyLong()
        );
    }

    @Test
    void deletesSignalOnlyForCurrentUser() {
        StrategySignalMapper mapper = mock(StrategySignalMapper.class);
        StrategySignalQueryService service =
                new StrategySignalQueryService(mapper);
        String signalId = "00000000-0000-0000-0000-000000000001";
        when(mapper.countVisibleById("user-a", signalId)).thenReturn(1);
        when(mapper.deleteForUser(
                org.mockito.ArgumentMatchers.eq("user-a"),
                org.mockito.ArgumentMatchers.eq(signalId),
                anyLong()
        )).thenReturn(1);

        service.delete("user-a", signalId);

        verify(mapper).deleteForUser(
                org.mockito.ArgumentMatchers.eq("user-a"),
                org.mockito.ArgumentMatchers.eq(signalId),
                anyLong()
        );
    }

    private StrategySignalFeedRow row(
            long signalTimeMs,
            boolean isRead,
            int suffix
    ) {
        StrategySignalFeedRow row = new StrategySignalFeedRow();
        row.setId(String.format(
                "00000000-0000-0000-0000-%012d",
                suffix
        ));
        row.setSymbol("BTCUSDC");
        row.setIntervalCode("1h");
        row.setStrategyCode("SUPER_EMA144_PULLBACK_REVERSAL");
        row.setDirection("LONG");
        row.setTriggerPrice(new BigDecimal("64000.25"));
        row.setSignalTimeMs(signalTimeMs);
        row.setReadState(isRead ? 1 : 0);
        row.setReversalAlertState("NONE");
        return row;
    }
}
