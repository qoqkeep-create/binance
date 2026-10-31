package com.oovso.notification;

import java.net.URI;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;
import org.springframework.web.util.UriComponentsBuilder;

@Component
@ConfigurationProperties(prefix = "notification.webhook")
public class WebhookNotificationProperties {

    private boolean enabled;

    private String url;

    private String key;

    private String zoneId = "Asia/Shanghai";

    private long connectTimeoutMillis = 5_000;

    private long requestTimeoutMillis = 10_000;

    private int maxAttempts = 3;

    private long retryDelayMillis = 1_000;

    public boolean isEnabled() {
        return enabled;
    }

    public void setEnabled(boolean enabled) {
        this.enabled = enabled;
    }

    public String getUrl() {
        return url;
    }

    public void setUrl(String url) {
        this.url = url;
    }

    public String getKey() {
        return key;
    }

    public void setKey(String key) {
        this.key = key;
    }

    public String getZoneId() {
        return zoneId;
    }

    public void setZoneId(String zoneId) {
        this.zoneId = zoneId;
    }

    public long getConnectTimeoutMillis() {
        return connectTimeoutMillis;
    }

    public void setConnectTimeoutMillis(long connectTimeoutMillis) {
        this.connectTimeoutMillis = connectTimeoutMillis;
    }

    public long getRequestTimeoutMillis() {
        return requestTimeoutMillis;
    }

    public void setRequestTimeoutMillis(long requestTimeoutMillis) {
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

    URI endpointUri() {
        if (!StringUtils.hasText(url)) {
            throw new IllegalStateException(
                    "STRATEGY_SIGNAL_WEBHOOK_URL must be configured when webhook notification is enabled"
            );
        }
        URI endpoint;
        try {
            endpoint = URI.create(url.trim());
        } catch (IllegalArgumentException exception) {
            throw new IllegalStateException("STRATEGY_SIGNAL_WEBHOOK_URL must be a valid HTTPS URL", exception);
        }
        if (!"https".equalsIgnoreCase(endpoint.getScheme()) || !StringUtils.hasText(endpoint.getHost())) {
            throw new IllegalStateException("STRATEGY_SIGNAL_WEBHOOK_URL must be an absolute HTTPS URL");
        }
        if (endpoint.getRawQuery() != null || endpoint.getRawFragment() != null) {
            throw new IllegalStateException(
                    "STRATEGY_SIGNAL_WEBHOOK_URL must not contain query parameters or a fragment"
            );
        }
        if (!StringUtils.hasText(key)) {
            throw new IllegalStateException(
                    "STRATEGY_SIGNAL_WEBHOOK_KEY must be configured when webhook notification is enabled"
            );
        }
        return UriComponentsBuilder.fromUri(endpoint)
                .queryParam("key", "{webhookKey}")
                .encode()
                .buildAndExpand(key.trim())
                .toUri();
    }
}
