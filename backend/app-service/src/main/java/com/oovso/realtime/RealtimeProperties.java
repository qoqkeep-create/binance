package com.oovso.realtime;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

@Component
@ConfigurationProperties(prefix = "app.realtime")
public class RealtimeProperties {

    private boolean enabled = true;

    private String endpoint = "/ws/v1";

    private long heartbeatIntervalMillis = 20_000;

    private long clientTimeoutMillis = 60_000;

    private int maxTextMessageBytes = 65_536;

    private int sendTimeLimitMillis = 10_000;

    private int sendBufferBytes = 1_048_576;

    private int maxSubscriptionsPerSession = 16;

    private int maxSymbolsPerSubscription = 200;

    private int dispatcherThreads = 4;

    private int dispatcherQueueCapacity = 5_000;

    private boolean marketTickerEnabled = true;

    private long marketTickerMessageMaxBytes = 1_048_576;

    public boolean isEnabled() {
        return enabled;
    }

    public void setEnabled(boolean enabled) {
        this.enabled = enabled;
    }

    public String getEndpoint() {
        return endpoint;
    }

    public void setEndpoint(String endpoint) {
        this.endpoint = endpoint;
    }

    public long getHeartbeatIntervalMillis() {
        return heartbeatIntervalMillis;
    }

    public void setHeartbeatIntervalMillis(long heartbeatIntervalMillis) {
        this.heartbeatIntervalMillis = heartbeatIntervalMillis;
    }

    public long getClientTimeoutMillis() {
        return clientTimeoutMillis;
    }

    public void setClientTimeoutMillis(long clientTimeoutMillis) {
        this.clientTimeoutMillis = clientTimeoutMillis;
    }

    public int getMaxTextMessageBytes() {
        return maxTextMessageBytes;
    }

    public void setMaxTextMessageBytes(int maxTextMessageBytes) {
        this.maxTextMessageBytes = maxTextMessageBytes;
    }

    public int getSendTimeLimitMillis() {
        return sendTimeLimitMillis;
    }

    public void setSendTimeLimitMillis(int sendTimeLimitMillis) {
        this.sendTimeLimitMillis = sendTimeLimitMillis;
    }

    public int getSendBufferBytes() {
        return sendBufferBytes;
    }

    public void setSendBufferBytes(int sendBufferBytes) {
        this.sendBufferBytes = sendBufferBytes;
    }

    public int getMaxSubscriptionsPerSession() {
        return maxSubscriptionsPerSession;
    }

    public void setMaxSubscriptionsPerSession(int maxSubscriptionsPerSession) {
        this.maxSubscriptionsPerSession = maxSubscriptionsPerSession;
    }

    public int getMaxSymbolsPerSubscription() {
        return maxSymbolsPerSubscription;
    }

    public void setMaxSymbolsPerSubscription(int maxSymbolsPerSubscription) {
        this.maxSymbolsPerSubscription = maxSymbolsPerSubscription;
    }

    public int getDispatcherThreads() {
        return dispatcherThreads;
    }

    public void setDispatcherThreads(int dispatcherThreads) {
        this.dispatcherThreads = dispatcherThreads;
    }

    public int getDispatcherQueueCapacity() {
        return dispatcherQueueCapacity;
    }

    public void setDispatcherQueueCapacity(int dispatcherQueueCapacity) {
        this.dispatcherQueueCapacity = dispatcherQueueCapacity;
    }

    public boolean isMarketTickerEnabled() {
        return marketTickerEnabled;
    }

    public void setMarketTickerEnabled(boolean marketTickerEnabled) {
        this.marketTickerEnabled = marketTickerEnabled;
    }

    public long getMarketTickerMessageMaxBytes() {
        return marketTickerMessageMaxBytes;
    }

    public void setMarketTickerMessageMaxBytes(long marketTickerMessageMaxBytes) {
        this.marketTickerMessageMaxBytes = marketTickerMessageMaxBytes;
    }
}
