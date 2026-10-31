package com.oovso.binance;

public final class BinanceRestRateLimitException extends RuntimeException {

    private final long retryAtMillis;

    BinanceRestRateLimitException(String message, long retryAtMillis) {
        super(message);
        this.retryAtMillis = retryAtMillis;
    }

    public long retryAtMillis() {
        return retryAtMillis;
    }
}
