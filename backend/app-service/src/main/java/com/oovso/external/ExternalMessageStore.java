package com.oovso.external;

import java.util.UUID;
import org.springframework.stereotype.Service;

@Service
public class ExternalMessageStore {

    private final ExternalMessageMapper messageMapper;

    public ExternalMessageStore(ExternalMessageMapper messageMapper) {
        this.messageMapper = messageMapper;
    }

    public ExternalMessage save(String payloadJson, long receivedTimeMs) {
        ExternalMessageRow row = new ExternalMessageRow();
        row.setId(UUID.randomUUID().toString());
        row.setPayloadJson(payloadJson);
        row.setReceivedTimeMs(receivedTimeMs);
        messageMapper.insertMessage(row);
        return new ExternalMessage(
                row.getId(),
                payloadJson,
                java.time.Instant.ofEpochMilli(receivedTimeMs)
        );
    }
}
