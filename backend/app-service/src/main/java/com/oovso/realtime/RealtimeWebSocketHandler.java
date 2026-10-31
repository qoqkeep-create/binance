package com.oovso.realtime;

import cn.dev33.satoken.stp.StpLogic;
import cn.dev33.satoken.stp.StpUtil;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.util.Locale;
import java.util.Map;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;
import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.handler.TextWebSocketHandler;

@Component
public class RealtimeWebSocketHandler extends TextWebSocketHandler {

    private static final Logger log = LoggerFactory.getLogger(RealtimeWebSocketHandler.class);

    private static final CloseStatus UNAUTHORIZED = new CloseStatus(4401, "Session expired");

    private final RealtimeProperties properties;

    private final RealtimeSessionRegistry registry;

    private final ObjectMapper objectMapper;

    public RealtimeWebSocketHandler(
            RealtimeProperties properties,
            RealtimeSessionRegistry registry,
            ObjectMapper objectMapper
    ) {
        this.properties = properties;
        this.registry = registry;
        this.objectMapper = objectMapper;
    }

    @Override
    public void afterConnectionEstablished(WebSocketSession session) throws Exception {
        String userId = attribute(session, RealtimeHandshakeInterceptor.ATTRIBUTE_USER_ID);
        String token = attribute(session, RealtimeHandshakeInterceptor.ATTRIBUTE_TOKEN);
        if (!StringUtils.hasText(userId) || !StringUtils.hasText(token)) {
            session.close(UNAUTHORIZED);
            return;
        }
        session.setTextMessageSizeLimit(Math.max(1_024, properties.getMaxTextMessageBytes()));
        RealtimeClientSession client = registry.register(session, userId, token);
        send(client, RealtimeProtocol.ServerMessage.ready(client.id(), properties));
    }

    @Override
    protected void handleTextMessage(WebSocketSession session, TextMessage message) throws Exception {
        RealtimeClientSession client = registry.get(session.getId());
        if (client == null) {
            session.close(CloseStatus.SERVER_ERROR);
            return;
        }
        if (!isSessionValid(client)) {
            client.close(UNAUTHORIZED);
            registry.remove(client.id());
            return;
        }
        client.touch();

        RealtimeProtocol.ClientMessage request;
        try {
            request = objectMapper.readValue(
                    message.getPayload(),
                    RealtimeProtocol.ClientMessage.class
            );
        } catch (JsonProcessingException exception) {
            send(client, RealtimeProtocol.ServerMessage.error(
                    null,
                    "INVALID_JSON",
                    "消息不是有效的 JSON"
            ));
            return;
        }

        try {
            handleRequest(client, request);
        } catch (RealtimeProtocolException exception) {
            send(client, RealtimeProtocol.ServerMessage.error(
                    request.requestId(),
                    exception.getCode(),
                    exception.getMessage()
            ));
        }
    }

    private void handleRequest(
            RealtimeClientSession client,
            RealtimeProtocol.ClientMessage request
    ) throws IOException {
        if (request.version() == null || request.version() != RealtimeProtocol.VERSION) {
            throw new RealtimeProtocolException(
                    "UNSUPPORTED_VERSION",
                    "仅支持 WebSocket 协议版本 " + RealtimeProtocol.VERSION
            );
        }
        if (!StringUtils.hasText(request.type())) {
            throw new RealtimeProtocolException("TYPE_REQUIRED", "消息类型不能为空");
        }

        switch (request.type().trim().toLowerCase(Locale.ROOT)) {
            case "ping" -> send(client, RealtimeProtocol.ServerMessage.pong(
                    request.requestId(),
                    request.timestamp()
            ));
            case "subscribe" -> {
                registry.subscribe(client, request.subscriptions());
                send(client, RealtimeProtocol.ServerMessage.ack(
                        request.requestId(),
                        Map.of("subscriptions", registry.subscriptions(client))
                ));
            }
            case "unsubscribe" -> {
                registry.unsubscribe(client, request.subscriptions());
                send(client, RealtimeProtocol.ServerMessage.ack(
                        request.requestId(),
                        Map.of("subscriptions", registry.subscriptions(client))
                ));
            }
            default -> throw new RealtimeProtocolException(
                    "UNSUPPORTED_TYPE",
                    "不支持的消息类型: " + request.type()
            );
        }
    }

    private boolean isSessionValid(RealtimeClientSession client) {
        try {
            StpLogic stpLogic = StpUtil.getStpLogic();
            Object loginId = stpLogic.getLoginIdByToken(client.token());
            if (!stpLogic.isValidLoginId(loginId)
                    || !client.userId().equals(String.valueOf(loginId))) {
                return false;
            }
            stpLogic.checkActiveTimeout(client.token());
            stpLogic.updateLastActiveToNow(client.token());
            return true;
        } catch (Exception exception) {
            return false;
        }
    }

    private void send(
            RealtimeClientSession client,
            RealtimeProtocol.ServerMessage message
    ) throws IOException {
        client.send(objectMapper.writeValueAsString(message));
    }

    private String attribute(WebSocketSession session, String key) {
        Object value = session.getAttributes().get(key);
        return value == null ? null : String.valueOf(value);
    }

    @Override
    public void handleTransportError(WebSocketSession session, Throwable exception) {
        log.debug(
                "APP WebSocket transport error connectionId={}: {}",
                session.getId(),
                exception.getMessage()
        );
        RealtimeClientSession client = registry.get(session.getId());
        if (client != null) {
            client.close(CloseStatus.SERVER_ERROR);
        }
        registry.remove(session.getId());
    }

    @Override
    public void afterConnectionClosed(WebSocketSession session, CloseStatus status) {
        registry.remove(session.getId());
    }
}
