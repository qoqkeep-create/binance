package com.oovso.notification;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.eatthepath.pushy.apns.ApnsClient;
import com.eatthepath.pushy.apns.ApnsClientBuilder;
import com.eatthepath.pushy.apns.DeliveryPriority;
import com.eatthepath.pushy.apns.PushNotificationResponse;
import com.eatthepath.pushy.apns.PushType;
import com.eatthepath.pushy.apns.auth.ApnsSigningKey;
import com.eatthepath.pushy.apns.util.SimpleApnsPushNotification;
import com.oovso.notification.PushDeviceMapper.RegisteredPushDevice;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.security.KeyFactory;
import java.security.interfaces.ECPrivateKey;
import java.security.spec.PKCS8EncodedKeySpec;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

@Component
@ConditionalOnProperty(
        prefix = "notification.apns",
        name = "enabled",
        havingValue = "true"
)
public class ApnsHttp2PushGateway implements ApnsPushGateway {

    private final ApnsNotificationProperties properties;

    private final ObjectMapper objectMapper;

    private ApnsClient productionClient;

    private ApnsClient sandboxClient;

    @Autowired
    public ApnsHttp2PushGateway(
            ApnsNotificationProperties properties,
            ObjectMapper objectMapper
    ) {
        this(properties, objectMapper, null, null);
    }

    ApnsHttp2PushGateway(
            ApnsNotificationProperties properties,
            ObjectMapper objectMapper,
            ApnsClient productionClient,
            ApnsClient sandboxClient
    ) {
        this.properties = properties;
        this.objectMapper = objectMapper;
        this.productionClient = productionClient;
        this.sandboxClient = sandboxClient;
    }

    @PostConstruct
    void validateConfiguration() {
        properties.requireCompleteConfiguration();
        try {
            ApnsSigningKey signingKey = signingKey();
            productionClient = client(
                    ApnsClientBuilder.PRODUCTION_APNS_HOST,
                    signingKey
            );
            sandboxClient = client(
                    ApnsClientBuilder.DEVELOPMENT_APNS_HOST,
                    signingKey
            );
        } catch (Exception exception) {
            shutdown();
            throw new IllegalStateException(
                    "Unable to initialize APNs HTTP/2 clients",
                    exception
            );
        }
    }

    @PreDestroy
    public void shutdown() {
        if (productionClient != null) {
            productionClient.close();
        }
        if (sandboxClient != null) {
            sandboxClient.close();
        }
    }

    @Override
    public DeliveryResult send(
            RegisteredPushDevice device,
            ApnsNotification notification
    ) {
        return send(device, payload(notification));
    }

    private DeliveryResult send(
            RegisteredPushDevice device,
            Map<String, Object> payload
    ) {
        try {
            byte[] payloadBytes = objectMapper.writeValueAsBytes(payload);
            if (payloadBytes.length > 4_096) {
                return DeliveryResult.rejected(0, "PayloadTooLarge");
            }
            SimpleApnsPushNotification push = new SimpleApnsPushNotification(
                    device.deviceToken(),
                    properties.getTopic().trim(),
                    new String(payloadBytes, StandardCharsets.UTF_8),
                    Instant.now().plusSeconds(Math.max(
                            60,
                            properties.getExpirationSeconds()
                    )),
                    DeliveryPriority.IMMEDIATE,
                    PushType.ALERT
            );
            var future = clientFor(device).sendNotification(push);
            PushNotificationResponse<SimpleApnsPushNotification> response;
            try {
                response = future.get(
                        Math.max(1_000, properties.getRequestTimeoutMillis()),
                        TimeUnit.MILLISECONDS
                );
            } catch (TimeoutException exception) {
                future.cancel(true);
                return DeliveryResult.transportFailure("Timeout");
            }
            if (response.isAccepted()) {
                return DeliveryResult.success();
            }
            return DeliveryResult.rejected(
                    response.getStatusCode(),
                    response.getRejectionReason().orElse("HTTPError")
            );
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            return DeliveryResult.transportFailure("Interrupted");
        } catch (ExecutionException exception) {
            Throwable cause = exception.getCause();
            return DeliveryResult.transportFailure(
                    cause == null
                            ? "ExecutionException"
                            : cause.getClass().getSimpleName()
            );
        } catch (Exception exception) {
            return DeliveryResult.transportFailure(
                    exception.getClass().getSimpleName()
            );
        }
    }

    private ApnsClient clientFor(RegisteredPushDevice device) {
        return "PRODUCTION".equals(device.environment())
                ? productionClient
                : sandboxClient;
    }

    private ApnsClient client(String host, ApnsSigningKey signingKey)
            throws Exception {
        return new ApnsClientBuilder()
                .setApnsServer(host)
                .setSigningKey(signingKey)
                .setUseAlpn(true)
                .setConnectionTimeout(Duration.ofMillis(Math.max(
                        1_000,
                        properties.getRequestTimeoutMillis()
                )))
                .build();
    }

    private ApnsSigningKey signingKey() throws Exception {
        byte[] decoded = Base64.getDecoder().decode(
                properties.getPrivateKeyBase64().replaceAll("\\s", "")
        );
        if (new String(decoded, StandardCharsets.US_ASCII)
                .startsWith("-----BEGIN PRIVATE KEY-----")) {
            return ApnsSigningKey.loadFromInputStream(
                    new ByteArrayInputStream(decoded),
                    properties.getTeamId().trim(),
                    properties.getKeyId().trim()
            );
        }
        ECPrivateKey key = (ECPrivateKey) KeyFactory.getInstance("EC")
                .generatePrivate(new PKCS8EncodedKeySpec(decoded));
        return new ApnsSigningKey(
                properties.getKeyId().trim(),
                properties.getTeamId().trim(),
                key
        );
    }

    Map<String, Object> payload(ApnsNotification notification) {
        Map<String, Object> alert = Map.of(
                "title", notification.title(),
                "body", notification.body()
        );
        Map<String, Object> aps = new LinkedHashMap<>();
        aps.put("alert", alert);
        aps.put("sound", "default");
        aps.put("thread-id", notification.threadId());

        Map<String, Object> payload = new LinkedHashMap<>();
        payload.putAll(notification.data());
        payload.put("aps", aps);
        payload.put("route", notification.route());
        return payload;
    }

}
