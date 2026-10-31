package com.oovso.binance;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

@Component
@ConfigurationProperties(prefix = "binance.usdm.continuous-kline")
public class BinanceContinuousKlineProperties {

    private boolean enabled;

    private String interval = "1h";

    private String contractType = "PERPETUAL";

    private String quoteAsset;

    private String status = "TRADING";

    private String restBaseUrl = "https://fapi.binance.com";

    private String streamBaseUrl = "wss://fstream.binance.com/market/stream";

    private int streamsPerConnection = 50;

    private long subscribeDelayMillis = 250;

    private boolean reconnectEnabled = true;

    private long reconnectMonitorIntervalMillis = 15_000;

    private long silentReconnectTimeoutMillis = 120_000;

    private long reconnectInitialBackoffMillis = 1_000;

    private long reconnectMaxBackoffMillis = 60_000;

    private boolean symbolRefreshEnabled = true;

    private long symbolRefreshIntervalMillis = 300_000;

    private Long messageMaxSize;

    public boolean isEnabled() {
        return enabled;
    }

    public void setEnabled(boolean enabled) {
        this.enabled = enabled;
    }

    public String getInterval() {
        return interval;
    }

    public void setInterval(String interval) {
        this.interval = interval;
    }

    public String getContractType() {
        return contractType;
    }

    public void setContractType(String contractType) {
        this.contractType = contractType;
    }

    public String getQuoteAsset() {
        return quoteAsset;
    }

    public void setQuoteAsset(String quoteAsset) {
        this.quoteAsset = quoteAsset;
    }

    public String getStatus() {
        return status;
    }

    public void setStatus(String status) {
        this.status = status;
    }

    public String getRestBaseUrl() {
        return restBaseUrl;
    }

    public void setRestBaseUrl(String restBaseUrl) {
        this.restBaseUrl = restBaseUrl;
    }

    public String getStreamBaseUrl() {
        return streamBaseUrl;
    }

    public void setStreamBaseUrl(String streamBaseUrl) {
        this.streamBaseUrl = streamBaseUrl;
    }

    public int getStreamsPerConnection() {
        return streamsPerConnection;
    }

    public void setStreamsPerConnection(int streamsPerConnection) {
        this.streamsPerConnection = streamsPerConnection;
    }

    public long getSubscribeDelayMillis() {
        return subscribeDelayMillis;
    }

    public void setSubscribeDelayMillis(long subscribeDelayMillis) {
        this.subscribeDelayMillis = subscribeDelayMillis;
    }

    public boolean isReconnectEnabled() {
        return reconnectEnabled;
    }

    public void setReconnectEnabled(boolean reconnectEnabled) {
        this.reconnectEnabled = reconnectEnabled;
    }

    public long getReconnectMonitorIntervalMillis() {
        return reconnectMonitorIntervalMillis;
    }

    public void setReconnectMonitorIntervalMillis(long reconnectMonitorIntervalMillis) {
        this.reconnectMonitorIntervalMillis = reconnectMonitorIntervalMillis;
    }

    public long getSilentReconnectTimeoutMillis() {
        return silentReconnectTimeoutMillis;
    }

    public void setSilentReconnectTimeoutMillis(long silentReconnectTimeoutMillis) {
        this.silentReconnectTimeoutMillis = silentReconnectTimeoutMillis;
    }

    public long getReconnectInitialBackoffMillis() {
        return reconnectInitialBackoffMillis;
    }

    public void setReconnectInitialBackoffMillis(long reconnectInitialBackoffMillis) {
        this.reconnectInitialBackoffMillis = reconnectInitialBackoffMillis;
    }

    public long getReconnectMaxBackoffMillis() {
        return reconnectMaxBackoffMillis;
    }

    public void setReconnectMaxBackoffMillis(long reconnectMaxBackoffMillis) {
        this.reconnectMaxBackoffMillis = reconnectMaxBackoffMillis;
    }

    public boolean isSymbolRefreshEnabled() {
        return symbolRefreshEnabled;
    }

    public void setSymbolRefreshEnabled(boolean symbolRefreshEnabled) {
        this.symbolRefreshEnabled = symbolRefreshEnabled;
    }

    public long getSymbolRefreshIntervalMillis() {
        return symbolRefreshIntervalMillis;
    }

    public void setSymbolRefreshIntervalMillis(long symbolRefreshIntervalMillis) {
        this.symbolRefreshIntervalMillis = symbolRefreshIntervalMillis;
    }

    public Long getMessageMaxSize() {
        return messageMaxSize;
    }

    public void setMessageMaxSize(Long messageMaxSize) {
        this.messageMaxSize = messageMaxSize;
    }

}
