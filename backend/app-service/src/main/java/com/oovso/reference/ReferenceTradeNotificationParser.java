package com.oovso.reference;

import com.fasterxml.jackson.databind.JsonNode;
import com.oovso.external.ExternalMessage;
import com.oovso.external.ExternalMessageApiException;
import java.time.OffsetDateTime;
import java.time.format.DateTimeParseException;
import java.util.UUID;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;

@Component
public class ReferenceTradeNotificationParser {

    static final int SUPPORTED_SCHEMA_VERSION = 1;

    public boolean supports(JsonNode payload) {
        if (!payload.isObject()) {
            return false;
        }
        JsonNode type = payload.get("type");
        return type != null
                && type.isTextual()
                && ReferenceTradeNotificationType.fromWireValue(type.textValue())
                        .isPresent();
    }

    public ReferenceTradeNotification parse(
            ExternalMessage message,
            JsonNode payload
    ) {
        int schemaVersion = requiredSchemaVersion(payload);
        String eventId = requiredText(payload, "eventId", 191);
        ReferenceTradeNotificationType type = requiredType(payload);
        String title = requiredText(payload, "title", 255);
        String content = requiredText(payload, "content", Integer.MAX_VALUE);
        String occurredAt = requiredText(payload, "occurredAt", 64);

        try {
            return new ReferenceTradeNotification(
                    UUID.randomUUID().toString(),
                    message.id(),
                    eventId,
                    schemaVersion,
                    type,
                    title,
                    content,
                    OffsetDateTime.parse(occurredAt).toInstant(),
                    message.receivedAt()
            );
        } catch (DateTimeParseException exception) {
            throw invalid("occurredAt 必须是包含时区的 ISO 8601 时间");
        }
    }

    private int requiredSchemaVersion(JsonNode payload) {
        JsonNode value = payload.get("schemaVersion");
        if (value == null
                || !value.isIntegralNumber()
                || !value.canConvertToInt()
                || value.intValue() != SUPPORTED_SCHEMA_VERSION) {
            throw invalid("schemaVersion 当前只支持 1");
        }
        return value.intValue();
    }

    private ReferenceTradeNotificationType requiredType(JsonNode payload) {
        JsonNode value = payload.get("type");
        if (value == null || !value.isTextual()) {
            throw invalid("type 缺失或格式不正确");
        }
        return ReferenceTradeNotificationType.fromWireValue(value.textValue())
                .orElseThrow(() -> invalid("type 不是支持的参考通知类型"));
    }

    private String requiredText(
            JsonNode payload,
            String field,
            int maxCodePoints
    ) {
        JsonNode value = payload.get(field);
        if (value == null || !value.isTextual() || value.textValue().isBlank()) {
            throw invalid(field + " 缺失或格式不正确");
        }
        String text = value.textValue();
        if (text.codePointCount(0, text.length()) > maxCodePoints) {
            throw invalid(field + " 长度超出限制");
        }
        return text;
    }

    private ExternalMessageApiException invalid(String reason) {
        return new ExternalMessageApiException(
                HttpStatus.BAD_REQUEST,
                "参考通知格式错误：" + reason
        );
    }
}
