package com.oovso.reference;

import lombok.Data;

@Data
public class ReferenceTradeNotificationRow {

    private String id;

    private String externalMessageId;

    private String eventId;

    private Integer schemaVersion;

    private String notificationType;

    private String title;

    private String content;

    private Long occurredTimeMs;

    private Long receivedTimeMs;
}
