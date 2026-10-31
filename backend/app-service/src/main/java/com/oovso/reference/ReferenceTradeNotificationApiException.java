package com.oovso.reference;

import org.springframework.http.HttpStatus;

public class ReferenceTradeNotificationApiException extends RuntimeException {

    private final HttpStatus status;

    public ReferenceTradeNotificationApiException(
            HttpStatus status,
            String message
    ) {
        super(message);
        this.status = status;
    }

    public HttpStatus status() {
        return status;
    }
}
