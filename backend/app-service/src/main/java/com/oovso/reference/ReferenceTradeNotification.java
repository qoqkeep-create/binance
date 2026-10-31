package com.oovso.reference;

import java.time.Instant;

public record ReferenceTradeNotification(
        String id,
        String externalMessageId,
        String eventId,
        int schemaVersion,
        ReferenceTradeNotificationType type,
        String title,
        String content,
        Instant occurredAt,
        Instant receivedAt
) {
}
