package com.oovso.external;

import java.nio.charset.StandardCharsets;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;

@Component
@ConfigurationProperties(prefix = "external-message")
public class ExternalMessageProperties {

    private boolean enabled;

    private String apiKey;

    public boolean isEnabled() {
        return enabled;
    }

    public void setEnabled(boolean enabled) {
        this.enabled = enabled;
    }

    public String getApiKey() {
        return apiKey;
    }

    public void setApiKey(String apiKey) {
        this.apiKey = apiKey;
    }

    public boolean hasStrongApiKey() {
        return StringUtils.hasText(apiKey)
                && apiKey.getBytes(StandardCharsets.UTF_8).length >= 32;
    }
}
