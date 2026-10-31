package com.oovso.notification;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.eatthepath.pushy.apns.ApnsClient;
import com.eatthepath.pushy.apns.DeliveryPriority;
import com.eatthepath.pushy.apns.PushNotificationResponse;
import com.eatthepath.pushy.apns.PushType;
import com.eatthepath.pushy.apns.util.SimpleApnsPushNotification;
import com.eatthepath.pushy.apns.util.concurrent.PushNotificationFuture;
import com.oovso.notification.ApnsPushGateway.DeliveryResult;
import com.oovso.notification.PushDeviceMapper.RegisteredPushDevice;
import com.oovso.reference.ReferenceTradeNotification;
import com.oovso.reference.ReferenceTradeNotificationApnsListener;
import com.oovso.reference.ReferenceTradeNotificationType;
import com.oovso.strategy.StrategySignal;
import java.io.IOException;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.KeyPairGenerator;
import java.security.spec.ECGenParameterSpec;
import java.time.Instant;
import java.util.Base64;
import java.util.Map;
import java.util.Optional;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

class ApnsHttp2PushGatewayTest {

    @Test
    void payloadCarriesAlertAndDeepLinkSignal() {
        ApnsHttp2PushGateway gateway = new ApnsHttp2PushGateway(
                new ApnsNotificationProperties(),
                new ObjectMapper()
        );
        StrategySignal signal = new StrategySignal();
        signal.setId("5d9a41ab-5b6a-4e11-94e5-0fee84c784ef");
        signal.setPair("BTCUSDC");
        signal.setIntervalCode("4h");
        signal.setStrategyCode("SUPER_EMA144_PULLBACK_REVERSAL");
        signal.setDirection("LONG");
        signal.setPrice(new BigDecimal("64123.4500"));
        signal.setSignalTimeMs(1_786_156_800_000L);

        Map<String, Object> payload = gateway.payload(
                ApnsStrategySignalHandler.notification(signal)
        );

        assertEquals("strategy.signal", payload.get("route"));
        assertEquals("BTCUSDC", payload.get("symbol"));
        assertEquals("EMA144回踩", payload.get("strategyName"));
        assertEquals("4h", payload.get("interval"));
        assertEquals("LONG", payload.get("direction"));
        assertEquals(1_786_156_800.0, payload.get("triggeredAt"));
        @SuppressWarnings("unchecked")
        Map<String, Object> aps = (Map<String, Object>) payload.get("aps");
        assertEquals("default", aps.get("sound"));
        assertEquals("strategy.signal", aps.get("thread-id"));
        @SuppressWarnings("unchecked")
        Map<String, Object> alert = (Map<String, Object>) aps.get("alert");
        assertEquals(
                "4小时 EMA144回踩 · 触发价 64123.45",
                alert.get("body")
        );
    }

    @Test
    void deliveryResultClassifiesInvalidAndRetryableResponses() {
        DeliveryResult invalid = DeliveryResult.rejected(
                410,
                "Unregistered"
        );
        assertTrue(invalid.invalidDevice());
        assertFalse(invalid.retryable());

        DeliveryResult retryable = DeliveryResult.rejected(
                503,
                "Shutdown"
        );
        assertFalse(retryable.invalidDevice());
        assertTrue(retryable.retryable());
    }

    @Test
    void reversalPayloadUsesPatternAndSeparateThread() {
        ApnsHttp2PushGateway gateway = new ApnsHttp2PushGateway(
                new ApnsNotificationProperties(),
                new ObjectMapper()
        );
        StrategySignal signal = new StrategySignal();
        signal.setId("5d9a41ab-5b6a-4e11-94e5-0fee84c784ef");
        signal.setPair("ETHUSDC");
        signal.setStrategyCode("CANDLESTICK_REVERSAL_ALERT");
        signal.setDirection("SHORT");
        signal.setNotificationName("看跌吞没");
        signal.setPrice(new BigDecimal("3456.70"));
        signal.setSignalTimeMs(1_786_156_800_000L);

        Map<String, Object> payload = gateway.payload(
                ApnsStrategySignalHandler.notification(signal)
        );

        assertEquals("看跌吞没", payload.get("strategyName"));
        @SuppressWarnings("unchecked")
        Map<String, Object> aps = (Map<String, Object>) payload.get("aps");
        assertEquals("strategy.reversal", aps.get("thread-id"));
        @SuppressWarnings("unchecked")
        Map<String, Object> alert = (Map<String, Object>) aps.get("alert");
        assertEquals("ETHUSDC 做空二次提醒", alert.get("title"));
        assertEquals("看跌吞没 · 收盘价 3456.7", alert.get("body"));
    }

    @Test
    void secondaryAlertPayloadUsesMacdMomentumDecayName() {
        ApnsHttp2PushGateway gateway = new ApnsHttp2PushGateway(
                new ApnsNotificationProperties(),
                new ObjectMapper()
        );
        StrategySignal signal = new StrategySignal();
        signal.setId("5d9a41ab-5b6a-4e11-94e5-0fee84c784ef");
        signal.setPair("BTCUSDC");
        signal.setStrategyCode("SECONDARY_REVERSAL_ALERT");
        signal.setDirection("LONG");
        signal.setNotificationName("MACD能量衰减");
        signal.setPrice(new BigDecimal("64001.2"));

        Map<String, Object> payload = gateway.payload(
                ApnsStrategySignalHandler.notification(signal)
        );

        assertEquals("MACD能量衰减", payload.get("strategyName"));
        @SuppressWarnings("unchecked")
        Map<String, Object> aps = (Map<String, Object>) payload.get("aps");
        assertEquals("strategy.reversal", aps.get("thread-id"));
        @SuppressWarnings("unchecked")
        Map<String, Object> alert = (Map<String, Object>) aps.get("alert");
        assertEquals("BTCUSDC 做多二次提醒", alert.get("title"));
        assertEquals("MACD能量衰减 · 收盘价 64001.2", alert.get("body"));
    }

    @Test
    void referencePayloadUsesIndependentRouteAndEnvelopeIdentity() {
        ApnsHttp2PushGateway gateway = new ApnsHttp2PushGateway(
                new ApnsNotificationProperties(),
                new ObjectMapper()
        );
        ReferenceTradeNotification notification =
                new ReferenceTradeNotification(
                        "notification-id",
                        "message-id",
                        "trade:close:1002",
                        1,
                        ReferenceTradeNotificationType.STRATEGY_TAKE_PROFIT,
                        "🎯 BTCUSDT 多单 止盈",
                        "> **止盈价**：116020",
                        Instant.parse("2026-09-04T06:00:00Z"),
                        Instant.parse("2026-09-04T06:00:01Z")
                );

        Map<String, Object> payload = gateway.payload(
                ReferenceTradeNotificationApnsListener.apnsNotification(
                        notification
                )
        );

        assertEquals("reference.trade.notification", payload.get("route"));
        assertEquals("trade:close:1002", payload.get("eventId"));
        assertEquals("STRATEGY_TAKE_PROFIT", payload.get("type"));
        @SuppressWarnings("unchecked")
        Map<String, Object> aps = (Map<String, Object>) payload.get("aps");
        assertEquals("reference.trade.notification", aps.get("thread-id"));
        @SuppressWarnings("unchecked")
        Map<String, Object> alert = (Map<String, Object>) aps.get("alert");
        assertEquals("🎯 BTCUSDT 多单 止盈", alert.get("title"));
        assertEquals("策略止盈", alert.get("body"));
    }

    @Test
    void sendsThroughProductionHttp2ClientWithExistingApnsMetadata() {
        ApnsClient productionClient = mock(ApnsClient.class);
        ApnsClient sandboxClient = mock(ApnsClient.class);
        ApnsNotificationProperties properties = new ApnsNotificationProperties();
        properties.setTopic("com.oovso.trade");
        properties.setExpirationSeconds(3_600);
        ApnsHttp2PushGateway gateway = new ApnsHttp2PushGateway(
                properties,
                new ObjectMapper(),
                productionClient,
                sandboxClient
        );
        completeWith(productionClient, true, 200, Optional.empty());

        DeliveryResult result = gateway.send(
                device("PRODUCTION"),
                notification()
        );

        assertTrue(result.delivered());
        ArgumentCaptor<SimpleApnsPushNotification> sent =
                ArgumentCaptor.forClass(SimpleApnsPushNotification.class);
        verify(productionClient).sendNotification(sent.capture());
        SimpleApnsPushNotification push = sent.getValue();
        assertEquals(device("PRODUCTION").deviceToken(), push.getToken());
        assertEquals("com.oovso.trade", push.getTopic());
        assertEquals(DeliveryPriority.IMMEDIATE, push.getPriority());
        assertEquals(PushType.ALERT, push.getPushType());
        assertTrue(push.getExpiration().isAfter(Instant.now()));
        assertTrue(push.getPayload().contains("\"route\":\"strategy.signal\""));
    }

    @Test
    void sandboxRejectionRetainsStatusAndInvalidDeviceClassification() {
        ApnsClient sandboxClient = mock(ApnsClient.class);
        ApnsHttp2PushGateway gateway = new ApnsHttp2PushGateway(
                new ApnsNotificationProperties(),
                new ObjectMapper(),
                mock(ApnsClient.class),
                sandboxClient
        );
        completeWith(
                sandboxClient,
                false,
                410,
                Optional.of("Unregistered")
        );

        DeliveryResult result = gateway.send(
                device("SANDBOX"),
                notification()
        );

        assertFalse(result.delivered());
        assertTrue(result.invalidDevice());
        assertEquals(410, result.statusCode());
        assertEquals("Unregistered", result.reason());
        verify(sandboxClient).sendNotification(any(SimpleApnsPushNotification.class));
    }

    @Test
    void transportFailureDoesNotLeakDeviceToken() {
        ApnsClient productionClient = mock(ApnsClient.class);
        ApnsHttp2PushGateway gateway = new ApnsHttp2PushGateway(
                new ApnsNotificationProperties(),
                new ObjectMapper(),
                productionClient,
                mock(ApnsClient.class)
        );
        PushNotificationFuture<SimpleApnsPushNotification,
                PushNotificationResponse<SimpleApnsPushNotification>> future =
                new PushNotificationFuture<>(null);
        future.completeExceptionally(new IOException(
                "request /3/device/" + device("PRODUCTION").deviceToken()
        ));
        when(productionClient.sendNotification(
                any(SimpleApnsPushNotification.class)
        )).thenReturn(future);

        DeliveryResult result = gateway.send(
                device("PRODUCTION"),
                notification()
        );

        assertTrue(result.retryable());
        assertEquals("IOException", result.reason());
        assertFalse(result.reason().contains(device("PRODUCTION").deviceToken()));
    }

    @Test
    void timeoutCancelsPendingSendAndRemainsRetryable() {
        ApnsClient productionClient = mock(ApnsClient.class);
        ApnsNotificationProperties properties = new ApnsNotificationProperties();
        properties.setRequestTimeoutMillis(1);
        ApnsHttp2PushGateway gateway = new ApnsHttp2PushGateway(
                properties,
                new ObjectMapper(),
                productionClient,
                mock(ApnsClient.class)
        );
        PushNotificationFuture<SimpleApnsPushNotification,
                PushNotificationResponse<SimpleApnsPushNotification>> future =
                new PushNotificationFuture<>(null);
        when(productionClient.sendNotification(
                any(SimpleApnsPushNotification.class)
        )).thenReturn(future);

        DeliveryResult result = gateway.send(
                device("PRODUCTION"),
                notification()
        );

        assertTrue(result.retryable());
        assertEquals("Timeout", result.reason());
        assertTrue(future.isCancelled());
    }

    @Test
    void serverUnavailableResponseRemainsRetryable() {
        ApnsClient productionClient = mock(ApnsClient.class);
        ApnsHttp2PushGateway gateway = new ApnsHttp2PushGateway(
                new ApnsNotificationProperties(),
                new ObjectMapper(),
                productionClient,
                mock(ApnsClient.class)
        );
        completeWith(productionClient, false, 503, Optional.of("Shutdown"));

        DeliveryResult result = gateway.send(
                device("PRODUCTION"),
                notification()
        );

        assertFalse(result.delivered());
        assertTrue(result.retryable());
        assertFalse(result.invalidDevice());
        assertEquals(503, result.statusCode());
    }

    @Test
    void shutdownClosesBothApnsClients() {
        ApnsClient productionClient = mock(ApnsClient.class);
        ApnsClient sandboxClient = mock(ApnsClient.class);
        ApnsHttp2PushGateway gateway = new ApnsHttp2PushGateway(
                new ApnsNotificationProperties(),
                new ObjectMapper(),
                productionClient,
                sandboxClient
        );

        gateway.shutdown();

        verify(productionClient).close();
        verify(sandboxClient).close();
    }

    @Test
    void acceptsExistingBase64DerSigningKeyWithoutWritingAFile()
            throws Exception {
        KeyPairGenerator generator = KeyPairGenerator.getInstance("EC");
        generator.initialize(new ECGenParameterSpec("secp256r1"));
        ApnsNotificationProperties properties = new ApnsNotificationProperties();
        properties.setTeamId("TEAM123456");
        properties.setKeyId("KEY1234567");
        properties.setPrivateKeyBase64(Base64.getEncoder().encodeToString(
                generator.generateKeyPair().getPrivate().getEncoded()
        ));
        ApnsHttp2PushGateway gateway = new ApnsHttp2PushGateway(
                properties,
                new ObjectMapper()
        );

        try {
            gateway.validateConfiguration();
        } finally {
            gateway.shutdown();
        }
    }

    @Test
    void acceptsBase64EncodedApplePemSigningKey() throws Exception {
        KeyPairGenerator generator = KeyPairGenerator.getInstance("EC");
        generator.initialize(new ECGenParameterSpec("secp256r1"));
        byte[] encoded = generator.generateKeyPair().getPrivate().getEncoded();
        String pem = "-----BEGIN PRIVATE KEY-----\n"
                + Base64.getMimeEncoder(64, new byte[]{'\n'})
                        .encodeToString(encoded)
                + "\n-----END PRIVATE KEY-----\n";
        ApnsNotificationProperties properties = new ApnsNotificationProperties();
        properties.setTeamId("TEAM123456");
        properties.setKeyId("KEY1234567");
        properties.setPrivateKeyBase64(Base64.getEncoder().encodeToString(
                pem.getBytes(StandardCharsets.US_ASCII)
        ));
        ApnsHttp2PushGateway gateway = new ApnsHttp2PushGateway(
                properties,
                new ObjectMapper()
        );

        try {
            gateway.validateConfiguration();
        } finally {
            gateway.shutdown();
        }
    }

    private void completeWith(
            ApnsClient client,
            boolean accepted,
            int status,
            Optional<String> reason
    ) {
        @SuppressWarnings("unchecked")
        PushNotificationResponse<SimpleApnsPushNotification> response =
                mock(PushNotificationResponse.class);
        when(response.isAccepted()).thenReturn(accepted);
        when(response.getStatusCode()).thenReturn(status);
        when(response.getRejectionReason()).thenReturn(reason);
        PushNotificationFuture<SimpleApnsPushNotification,
                PushNotificationResponse<SimpleApnsPushNotification>> future =
                new PushNotificationFuture<>(null);
        future.complete(response);
        when(client.sendNotification(any(SimpleApnsPushNotification.class)))
                .thenReturn(future);
    }

    private RegisteredPushDevice device(String environment) {
        return new RegisteredPushDevice(
                "device-id",
                "a1".repeat(32),
                environment
        );
    }

    private ApnsNotification notification() {
        return new ApnsNotification(
                "BTCUSDC 做多信号",
                "EMA144回踩 · 触发价 64000",
                "strategy.signal",
                "strategy.signal",
                Map.of("id", "signal-id")
        );
    }
}
