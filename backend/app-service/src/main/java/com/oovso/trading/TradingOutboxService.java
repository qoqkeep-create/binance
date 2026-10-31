package com.oovso.trading;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.LocalDateTime;
import java.util.UUID;
import org.springframework.stereotype.Service;

@Service
public class TradingOutboxService {

    private final TradingOutboxMapper outboxMapper;
    private final ObjectMapper objectMapper;

    public TradingOutboxService(
            TradingOutboxMapper outboxMapper,
            ObjectMapper objectMapper
    ) {
        this.outboxMapper = outboxMapper;
        this.objectMapper = objectMapper;
    }

    public void enqueue(
            TradingAccount account,
            String channel,
            String eventName,
            String eventKey,
            String symbol,
            Object payload
    ) {
        try {
            LocalDateTime now = LocalDateTime.now();
            TradingOutbox outbox = new TradingOutbox();
            outbox.setId(UUID.randomUUID().toString());
            outbox.setCreateTime(now);
            outbox.setUpdateTime(now);
            outbox.setTradingAccountId(account.getId());
            outbox.setAppUserId(account.getAppUserId());
            outbox.setChannel(channel);
            outbox.setEventName(eventName);
            outbox.setEventKey(eventKey);
            outbox.setSymbol(symbol);
            outbox.setPayloadJson(objectMapper.writeValueAsString(payload));
            outbox.setStatus("PENDING");
            outbox.setAttempts(0);
            outbox.setAvailableAtMs(System.currentTimeMillis());
            outboxMapper.insertOutbox(outbox);
        } catch (JsonProcessingException exception) {
            throw new IllegalStateException(
                    "Unable to serialize trading outbox payload",
                    exception
            );
        }
    }
}
