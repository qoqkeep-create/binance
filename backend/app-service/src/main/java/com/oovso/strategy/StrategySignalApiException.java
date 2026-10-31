package com.oovso.strategy;

import org.springframework.http.HttpStatus;

public class StrategySignalApiException extends RuntimeException {

    private final HttpStatus status;

    public StrategySignalApiException(HttpStatus status, String message) {
        super(message);
        this.status = status;
    }

    public HttpStatus status() {
        return status;
    }
}
