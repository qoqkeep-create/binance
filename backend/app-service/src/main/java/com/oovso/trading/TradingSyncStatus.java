package com.oovso.trading;

public enum TradingSyncStatus {
    STOPPED,
    CONNECTING,
    BUFFERING,
    RECONCILING,
    SYNCED,
    DEGRADED,
    AUTH_FAILED
}
