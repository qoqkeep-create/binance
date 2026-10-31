package com.oovso.external;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Clock;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class ExternalMessageService {

    private final ExternalMessageProperties properties;

    private final ExternalMessageStore messageStore;

    private final ExternalMessageDispatcher messageDispatcher;

    private final ObjectMapper objectMapper;

    private final Clock clock;

    @Autowired
    public ExternalMessageService(
            ExternalMessageProperties properties,
            ExternalMessageStore messageStore,
            ExternalMessageDispatcher messageDispatcher,
            ObjectMapper objectMapper
    ) {
        this(
                properties,
                messageStore,
                messageDispatcher,
                objectMapper,
                Clock.systemUTC()
        );
    }

    ExternalMessageService(
            ExternalMessageProperties properties,
            ExternalMessageStore messageStore,
            ExternalMessageDispatcher messageDispatcher,
            ObjectMapper objectMapper,
            Clock clock
    ) {
        this.properties = properties;
        this.messageStore = messageStore;
        this.messageDispatcher = messageDispatcher;
        this.objectMapper = objectMapper;
        this.clock = clock;
    }

    @Transactional
    public void accept(String providedApiKey, String payloadJson) {
        requireAuthorized(providedApiKey);
        JsonNode payload = requireValidJson(payloadJson);
        ExternalMessage message = messageStore.save(payloadJson, clock.millis());
        messageDispatcher.dispatch(message, payload);
    }

    private void requireAuthorized(String providedApiKey) {
        if (!properties.isEnabled() || !properties.hasStrongApiKey()) {
            throw new ExternalMessageApiException(
                    HttpStatus.SERVICE_UNAVAILABLE,
                    "外部消息接收接口未启用"
            );
        }
        byte[] expected = properties.getApiKey()
                .getBytes(StandardCharsets.UTF_8);
        byte[] provided = providedApiKey == null
                ? new byte[0]
                : providedApiKey.getBytes(StandardCharsets.UTF_8);
        if (!MessageDigest.isEqual(expected, provided)) {
            throw new ExternalMessageApiException(
                    HttpStatus.UNAUTHORIZED,
                    "外部消息密钥无效"
            );
        }
    }

    private JsonNode requireValidJson(String payloadJson) {
        if (payloadJson == null || payloadJson.isBlank()) {
            throw invalidJson();
        }
        try {
            JsonNode payload = objectMapper.reader()
                    .with(DeserializationFeature.FAIL_ON_TRAILING_TOKENS)
                    .readTree(payloadJson);
            if (payload == null) {
                throw invalidJson();
            }
            return payload;
        } catch (JsonProcessingException exception) {
            throw invalidJson();
        }
    }

    private ExternalMessageApiException invalidJson() {
        return new ExternalMessageApiException(
                HttpStatus.BAD_REQUEST,
                "请求体必须是合法 JSON"
        );
    }
}
