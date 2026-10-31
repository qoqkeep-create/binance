package com.oovso.realtime;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.mockito.Mockito.when;

import cn.dev33.satoken.dao.SaTokenDao;
import cn.dev33.satoken.dao.SaTokenDaoDefaultImpl;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.oovso.auth.AppUser;
import com.oovso.auth.AuthService;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.http.WebSocket;
import java.time.Duration;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionStage;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.SpringBootTest.WebEnvironment;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.Primary;
import org.springframework.http.MediaType;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.bean.override.mockito.MockitoBean;

@ActiveProfiles("test")
@SpringBootTest(webEnvironment = WebEnvironment.RANDOM_PORT)
@Import(RealtimeWebSocketIntegrationTest.InMemorySaTokenConfiguration.class)
class RealtimeWebSocketIntegrationTest {

    @LocalServerPort
    private int port;

    @Autowired
    private ObjectMapper objectMapper;

    @MockitoBean
    private AuthService authService;

    @Test
    void authenticatesSubscribesAndRespondsToHeartbeat() throws Exception {
        AppUser user = user();
        when(authService.authenticate("ws-user", "secure-password"))
                .thenReturn(user);
        when(authService.requireActiveUser("ws-user-id"))
                .thenReturn(user);

        String token = login();
        MessageListener listener = new MessageListener();
        WebSocket socket = HttpClient.newHttpClient()
                .newWebSocketBuilder()
                .connectTimeout(Duration.ofSeconds(5))
                .header("Authorization", "Bearer " + token)
                .header("X-Platform", "integration-test")
                .buildAsync(
                        URI.create("ws://127.0.0.1:" + port + "/ws/v1"),
                        listener
                )
                .get(5, TimeUnit.SECONDS);

        JsonNode ready = listener.awaitType("ready", objectMapper);
        assertNotNull(ready.path("data").path("connectionId").textValue());

        socket.sendText("""
                {
                  "version": 1,
                  "type": "subscribe",
                  "requestId": "subscribe-1",
                  "subscriptions": [
                    {
                      "channel": "market.kline",
                      "filters": {
                        "symbols": ["BTCUSDC"],
                        "intervals": ["1m"]
                      }
                    }
                  ],
                  "timestamp": 1785231000000
                }
                """, true).get(5, TimeUnit.SECONDS);

        JsonNode ack = listener.awaitType("ack", objectMapper);
        assertEquals("subscribe-1", ack.path("requestId").asText());
        assertEquals(
                "market.kline",
                ack.path("data").path("subscriptions").get(0)
                        .path("channel").asText()
        );

        socket.sendText("""
                {
                  "version": 1,
                  "type": "ping",
                  "requestId": "ping-1",
                  "timestamp": 1785231000000
                }
                """, true).get(5, TimeUnit.SECONDS);

        JsonNode pong = listener.awaitType("pong", objectMapper);
        assertEquals("ping-1", pong.path("requestId").asText());
        socket.sendClose(WebSocket.NORMAL_CLOSURE, "test complete")
                .get(5, TimeUnit.SECONDS);
    }

    private String login() throws Exception {
        HttpRequest request = HttpRequest.newBuilder(
                        URI.create("http://127.0.0.1:" + port + "/api/auth/login")
                )
                .header("Content-Type", MediaType.APPLICATION_JSON_VALUE)
                .header("X-Platform", "integration-test")
                .POST(HttpRequest.BodyPublishers.ofString("""
                        {
                          "account": "ws-user",
                          "password": "secure-password"
                        }
                        """))
                .build();
        HttpResponse<String> response = HttpClient.newHttpClient().send(
                request,
                HttpResponse.BodyHandlers.ofString()
        );

        assertEquals(200, response.statusCode());
        return objectMapper.readTree(response.body())
                .path("data")
                .path("accessToken")
                .asText();
    }

    private AppUser user() {
        AppUser user = new AppUser();
        user.setId("ws-user-id");
        user.setAccount("ws-user");
        user.setEmail("ws-user@example.com");
        user.setDisplayName("WebSocket User");
        user.setEnabledState(1);
        return user;
    }

    @TestConfiguration
    static class InMemorySaTokenConfiguration {

        @Bean
        @Primary
        SaTokenDao inMemorySaTokenDao() {
            return new SaTokenDaoDefaultImpl();
        }
    }

    private static final class MessageListener implements WebSocket.Listener {

        private final BlockingQueue<String> messages = new LinkedBlockingQueue<>();

        private final StringBuilder currentMessage = new StringBuilder();

        @Override
        public void onOpen(WebSocket webSocket) {
            webSocket.request(1);
        }

        @Override
        public CompletionStage<?> onText(
                WebSocket webSocket,
                CharSequence data,
                boolean last
        ) {
            currentMessage.append(data);
            if (last) {
                messages.offer(currentMessage.toString());
                currentMessage.setLength(0);
            }
            webSocket.request(1);
            return CompletableFuture.completedFuture(null);
        }

        JsonNode awaitType(String type, ObjectMapper objectMapper) throws Exception {
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
            while (System.nanoTime() < deadline) {
                String message = messages.poll(250, TimeUnit.MILLISECONDS);
                if (message == null) {
                    continue;
                }
                JsonNode json = objectMapper.readTree(message);
                if (type.equals(json.path("type").asText())) {
                    return json;
                }
            }
            throw new AssertionError("Timed out waiting for WebSocket message type " + type);
        }
    }
}
