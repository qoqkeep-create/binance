package com.oovso.trading;

import org.springframework.http.HttpStatus;

public class TradingApiException extends RuntimeException {

    private final HttpStatus status;

    public TradingApiException(HttpStatus status, String message) {
        super(message);
        this.status = status;
    }

    public TradingApiException(
            HttpStatus status,
            String message,
            Throwable cause
    ) {
        super(message, cause);
        this.status = status;
    }

    public HttpStatus status() {
        return status;
    }
}
