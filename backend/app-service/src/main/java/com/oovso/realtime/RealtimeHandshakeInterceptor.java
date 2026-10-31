package com.oovso.realtime;

import cn.dev33.satoken.stp.StpLogic;
import cn.dev33.satoken.stp.StpUtil;
import com.oovso.auth.AuthService;
import java.util.Map;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.server.ServerHttpRequest;
import org.springframework.http.server.ServerHttpResponse;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;
import org.springframework.web.socket.WebSocketHandler;
import org.springframework.web.socket.server.HandshakeInterceptor;

@Component
public class RealtimeHandshakeInterceptor implements HandshakeInterceptor {

    static final String ATTRIBUTE_USER_ID = "realtimeUserId";

    static final String ATTRIBUTE_TOKEN = "realtimeToken";

    private static final Logger log = LoggerFactory.getLogger(RealtimeHandshakeInterceptor.class);

    private static final String BEARER_PREFIX = "Bearer ";

    private final AuthService authService;

    public RealtimeHandshakeInterceptor(AuthService authService) {
        this.authService = authService;
    }

    @Override
    public boolean beforeHandshake(
            ServerHttpRequest request,
            ServerHttpResponse response,
            WebSocketHandler wsHandler,
            Map<String, Object> attributes
    ) {
        String token = bearerToken(request.getHeaders().getFirst("Authorization"));
        if (!StringUtils.hasText(token)) {
            response.setStatusCode(HttpStatus.UNAUTHORIZED);
            return false;
        }

        try {
            StpLogic stpLogic = StpUtil.getStpLogic();
            Object loginId = stpLogic.getLoginIdByToken(token);
            if (!stpLogic.isValidLoginId(loginId)) {
                response.setStatusCode(HttpStatus.UNAUTHORIZED);
                return false;
            }
            stpLogic.checkActiveTimeout(token);
            String userId = String.valueOf(loginId);
            authService.requireActiveUser(userId);
            stpLogic.updateLastActiveToNow(token);
            attributes.put(ATTRIBUTE_USER_ID, userId);
            attributes.put(ATTRIBUTE_TOKEN, token);
            return true;
        } catch (Exception exception) {
            log.debug("Rejected APP WebSocket handshake: {}", exception.getMessage());
            response.setStatusCode(HttpStatus.UNAUTHORIZED);
            return false;
        }
    }

    @Override
    public void afterHandshake(
            ServerHttpRequest request,
            ServerHttpResponse response,
            WebSocketHandler wsHandler,
            Exception exception
    ) {
        // No post-handshake work is required.
    }

    static String bearerToken(String authorization) {
        if (!StringUtils.hasText(authorization)
                || authorization.length() <= BEARER_PREFIX.length()
                || !authorization.regionMatches(true, 0, BEARER_PREFIX, 0, BEARER_PREFIX.length())) {
            return null;
        }
        String token = authorization.substring(BEARER_PREFIX.length()).trim();
        return StringUtils.hasText(token) ? token : null;
    }
}
