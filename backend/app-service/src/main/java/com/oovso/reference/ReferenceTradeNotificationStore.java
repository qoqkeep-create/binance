package com.oovso.reference;

import org.springframework.stereotype.Service;

@Service
public class ReferenceTradeNotificationStore {

    private final ReferenceTradeNotificationMapper mapper;

    public ReferenceTradeNotificationStore(
            ReferenceTradeNotificationMapper mapper
    ) {
        this.mapper = mapper;
    }

    public boolean saveIfAbsent(ReferenceTradeNotification notification) {
        ReferenceTradeNotificationRow row = new ReferenceTradeNotificationRow();
        row.setId(notification.id());
        row.setExternalMessageId(notification.externalMessageId());
        row.setEventId(notification.eventId());
        row.setSchemaVersion(notification.schemaVersion());
        row.setNotificationType(notification.type().name());
        row.setTitle(notification.title());
        row.setContent(notification.content());
        row.setOccurredTimeMs(notification.occurredAt().toEpochMilli());
        row.setReceivedTimeMs(notification.receivedAt().toEpochMilli());
        return mapper.insertNotification(row) == 1;
    }
}
