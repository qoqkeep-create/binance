package com.oovso.notification;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;

@Component
@ConfigurationProperties(prefix = "notification.apns")
public class ApnsNotificationProperties {

    private boolean enabled;

    private String teamId;

    private String keyId;

    private String privateKeyBase64;

    private String topic = "com.oovso.trade";

    private int requestTimeoutMillis = 10_000;

    private long expirationSeconds = 21_600;

    private int maxAttempts = 3;

    private long retryDelayMillis = 1_000;

    public void requireCompleteConfiguration() {
        if (!StringUtils.hasText(teamId)
                || !StringUtils.hasText(keyId)
                || !StringUtils.hasText(privateKeyBase64)
                || !StringUtils.hasText(topic)) {
            throw new IllegalStateException(
                    "APNs is enabled but TEAM_ID, KEY_ID, PRIVATE_KEY_BASE64 or TOPIC is missing"
            );
        }
    }

    public boolean isEnabled() {
        return enabled;
    }

    public void setEnabled(boolean enabled) {
        this.enabled = enabled;
    }

    public String getTeamId() {
        return teamId;
    }

    public void setTeamId(String teamId) {
        this.teamId = teamId;
    }

    public String getKeyId() {
        return keyId;
    }

    public void setKeyId(String keyId) {
        this.keyId = keyId;
    }

    public String getPrivateKeyBase64() {
        return privateKeyBase64;
    }

    public void setPrivateKeyBase64(String privateKeyBase64) {
        this.privateKeyBase64 = privateKeyBase64;
    }

    public String getTopic() {
        return topic;
    }

    public void setTopic(String topic) {
        this.topic = topic;
    }

    public int getRequestTimeoutMillis() {
        return requestTimeoutMillis;
    }

    public void setRequestTimeoutMillis(int requestTimeoutMillis) {
        this.requestTimeoutMillis = requestTimeoutMillis;
    }

    public int getMaxAttempts() {
        return maxAttempts;
    }

    public void setMaxAttempts(int maxAttempts) {
        this.maxAttempts = maxAttempts;
    }

    public long getRetryDelayMillis() {
        return retryDelayMillis;
    }

    public void setRetryDelayMillis(long retryDelayMillis) {
        this.retryDelayMillis = retryDelayMillis;
    }

    public long getExpirationSeconds() {
        return expirationSeconds;
    }

    public void setExpirationSeconds(long expirationSeconds) {
        this.expirationSeconds = expirationSeconds;
    }
}
