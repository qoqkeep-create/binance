package com.oovso.realtime;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.socket.config.annotation.EnableWebSocket;
import org.springframework.web.socket.config.annotation.WebSocketConfigurer;
import org.springframework.web.socket.config.annotation.WebSocketHandlerRegistry;

@Configuration
@EnableWebSocket
@ConditionalOnProperty(
        prefix = "app.realtime",
        name = "enabled",
        havingValue = "true",
        matchIfMissing = true
)
public class RealtimeWebSocketConfiguration implements WebSocketConfigurer {

    private final RealtimeProperties properties;

    private final RealtimeWebSocketHandler handler;

    private final RealtimeHandshakeInterceptor handshakeInterceptor;

    public RealtimeWebSocketConfiguration(
            RealtimeProperties properties,
            RealtimeWebSocketHandler handler,
            RealtimeHandshakeInterceptor handshakeInterceptor
    ) {
        this.properties = properties;
        this.handler = handler;
        this.handshakeInterceptor = handshakeInterceptor;
    }

    @Override
    public void registerWebSocketHandlers(WebSocketHandlerRegistry registry) {
        registry.addHandler(handler, properties.getEndpoint())
                .addInterceptors(handshakeInterceptor);
    }
}
