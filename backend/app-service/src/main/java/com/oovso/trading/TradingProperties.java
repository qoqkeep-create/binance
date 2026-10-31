package com.oovso.trading;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

@Component
@ConfigurationProperties(prefix = "trading")
public class TradingProperties {

    private boolean enabled = true;

    private String credentialMasterKey;

    private String credentialKeyVersion = "v1";

    private Binance binance = new Binance();

    private Sync sync = new Sync();

    private Execution execution = new Execution();

    public boolean isEnabled() {
        return enabled;
    }

    public void setEnabled(boolean enabled) {
        this.enabled = enabled;
    }

    public String getCredentialMasterKey() {
        return credentialMasterKey;
    }

    public void setCredentialMasterKey(String credentialMasterKey) {
        this.credentialMasterKey = credentialMasterKey;
    }

    public String getCredentialKeyVersion() {
        return credentialKeyVersion;
    }

    public void setCredentialKeyVersion(String credentialKeyVersion) {
        this.credentialKeyVersion = credentialKeyVersion;
    }

    public Binance getBinance() {
        return binance;
    }

    public void setBinance(Binance binance) {
        this.binance = binance;
    }

    public Sync getSync() {
        return sync;
    }

    public void setSync(Sync sync) {
        this.sync = sync;
    }

    public Execution getExecution() {
        return execution;
    }

    public void setExecution(Execution execution) {
        this.execution = execution;
    }

    public static class Execution {

        private int commandBatchSize = 10;
        private long strategyIntervalMillis = 60_000;
        private long unknownResolutionTimeoutMillis = 30_000;
        private long orderHealthCheckIntervalMillis = 5_000;
        private long orderRepairBackoffMillis = 15_000;

        public int getCommandBatchSize() {
            return commandBatchSize;
        }

        public void setCommandBatchSize(int commandBatchSize) {
            this.commandBatchSize = commandBatchSize;
        }

        public long getStrategyIntervalMillis() {
            return strategyIntervalMillis;
        }

        public void setStrategyIntervalMillis(long value) {
            this.strategyIntervalMillis = value;
        }

        public long getUnknownResolutionTimeoutMillis() {
            return unknownResolutionTimeoutMillis;
        }

        public void setUnknownResolutionTimeoutMillis(long value) {
            this.unknownResolutionTimeoutMillis = value;
        }

        public long getOrderHealthCheckIntervalMillis() {
            return orderHealthCheckIntervalMillis;
        }

        public void setOrderHealthCheckIntervalMillis(long value) {
            this.orderHealthCheckIntervalMillis = value;
        }

        public long getOrderRepairBackoffMillis() {
            return orderRepairBackoffMillis;
        }

        public void setOrderRepairBackoffMillis(long value) {
            this.orderRepairBackoffMillis = value;
        }
    }

    public static class Binance {

        private String restBaseUrl = "https://fapi.binance.com";

        private long recvWindowMillis = 5_000;

        private long requestTimeoutMillis = 12_000;

        private int privateRestWeightBudgetPerMinute = 1_800;

        private boolean diagnosticRestLoggingEnabled;

        public String getRestBaseUrl() {
            return restBaseUrl;
        }

        public void setRestBaseUrl(String restBaseUrl) {
            this.restBaseUrl = restBaseUrl;
        }

        public long getRecvWindowMillis() {
            return recvWindowMillis;
        }

        public void setRecvWindowMillis(long recvWindowMillis) {
            this.recvWindowMillis = recvWindowMillis;
        }

        public long getRequestTimeoutMillis() {
            return requestTimeoutMillis;
        }

        public void setRequestTimeoutMillis(long requestTimeoutMillis) {
            this.requestTimeoutMillis = requestTimeoutMillis;
        }

        public int getPrivateRestWeightBudgetPerMinute() {
            return privateRestWeightBudgetPerMinute;
        }

        public void setPrivateRestWeightBudgetPerMinute(int value) {
            this.privateRestWeightBudgetPerMinute = value;
        }

        public boolean isDiagnosticRestLoggingEnabled() {
            return diagnosticRestLoggingEnabled;
        }

        public void setDiagnosticRestLoggingEnabled(boolean value) {
            this.diagnosticRestLoggingEnabled = value;
        }
    }

    public static class Sync {

        private boolean enabled;
        private String userStreamBaseUrl = "wss://fstream.binance.com/private";
        private long keepaliveIntervalMillis = 1_800_000;
        private long connectionRolloverMillis = 82_800_000;
        private int eventQueueCapacity = 10_000;
        private int maxMessageBytes = 1_048_576;
        private long reconnectInitialBackoffMillis = 1_000;
        private long reconnectMaxBackoffMillis = 60_000;
        private long activeReconcileIntervalMillis = 60_000;
        private long idleReconcileIntervalMillis = 300_000;
        private long fullDiscoveryIntervalMillis = 1_800_000;
        private int maxConvergencePasses = 3;
        private long unresolvedOrderTimeoutMillis = 30_000;
        private long leaseTtlMillis = 30_000;
        private long leaseRenewIntervalMillis = 10_000;
        private int outboxBatchSize = 100;
        private long outboxPollIntervalMillis = 250;

        public boolean isEnabled() {
            return enabled;
        }

        public void setEnabled(boolean enabled) {
            this.enabled = enabled;
        }

        public String getUserStreamBaseUrl() {
            return userStreamBaseUrl;
        }

        public void setUserStreamBaseUrl(String userStreamBaseUrl) {
            this.userStreamBaseUrl = userStreamBaseUrl;
        }

        public long getKeepaliveIntervalMillis() {
            return keepaliveIntervalMillis;
        }

        public void setKeepaliveIntervalMillis(long value) {
            this.keepaliveIntervalMillis = value;
        }

        public long getConnectionRolloverMillis() {
            return connectionRolloverMillis;
        }

        public void setConnectionRolloverMillis(long value) {
            this.connectionRolloverMillis = value;
        }

        public int getEventQueueCapacity() {
            return eventQueueCapacity;
        }

        public void setEventQueueCapacity(int eventQueueCapacity) {
            this.eventQueueCapacity = eventQueueCapacity;
        }

        public int getMaxMessageBytes() {
            return maxMessageBytes;
        }

        public void setMaxMessageBytes(int maxMessageBytes) {
            this.maxMessageBytes = maxMessageBytes;
        }

        public long getReconnectInitialBackoffMillis() {
            return reconnectInitialBackoffMillis;
        }

        public void setReconnectInitialBackoffMillis(long value) {
            this.reconnectInitialBackoffMillis = value;
        }

        public long getReconnectMaxBackoffMillis() {
            return reconnectMaxBackoffMillis;
        }

        public void setReconnectMaxBackoffMillis(long value) {
            this.reconnectMaxBackoffMillis = value;
        }

        public long getActiveReconcileIntervalMillis() {
            return activeReconcileIntervalMillis;
        }

        public void setActiveReconcileIntervalMillis(long value) {
            this.activeReconcileIntervalMillis = value;
        }

        public long getIdleReconcileIntervalMillis() {
            return idleReconcileIntervalMillis;
        }

        public void setIdleReconcileIntervalMillis(long value) {
            this.idleReconcileIntervalMillis = value;
        }

        public long getFullDiscoveryIntervalMillis() {
            return fullDiscoveryIntervalMillis;
        }

        public void setFullDiscoveryIntervalMillis(long value) {
            this.fullDiscoveryIntervalMillis = value;
        }

        public int getMaxConvergencePasses() {
            return maxConvergencePasses;
        }

        public void setMaxConvergencePasses(int value) {
            this.maxConvergencePasses = value;
        }

        public long getUnresolvedOrderTimeoutMillis() {
            return unresolvedOrderTimeoutMillis;
        }

        public void setUnresolvedOrderTimeoutMillis(long value) {
            this.unresolvedOrderTimeoutMillis = value;
        }

        public long getLeaseTtlMillis() {
            return leaseTtlMillis;
        }

        public void setLeaseTtlMillis(long leaseTtlMillis) {
            this.leaseTtlMillis = leaseTtlMillis;
        }

        public long getLeaseRenewIntervalMillis() {
            return leaseRenewIntervalMillis;
        }

        public void setLeaseRenewIntervalMillis(long value) {
            this.leaseRenewIntervalMillis = value;
        }

        public int getOutboxBatchSize() {
            return outboxBatchSize;
        }

        public void setOutboxBatchSize(int outboxBatchSize) {
            this.outboxBatchSize = outboxBatchSize;
        }

        public long getOutboxPollIntervalMillis() {
            return outboxPollIntervalMillis;
        }

        public void setOutboxPollIntervalMillis(long value) {
            this.outboxPollIntervalMillis = value;
        }
    }
}
