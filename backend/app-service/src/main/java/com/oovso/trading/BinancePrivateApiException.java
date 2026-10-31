package com.oovso.trading;

final class BinancePrivateApiException extends RuntimeException {

    private final Integer code;
    private final Integer httpStatus;
    private final long retryAtMillis;

    BinancePrivateApiException(Integer code, String message) {
        this(null, code, message);
    }

    BinancePrivateApiException(Integer httpStatus, Integer code, String message) {
        this(httpStatus, code, message, 0);
    }

    BinancePrivateApiException(
            Integer httpStatus,
            Integer code,
            String message,
            long retryAtMillis
    ) {
        super(message);
        this.httpStatus = httpStatus;
        this.code = code;
        this.retryAtMillis = retryAtMillis;
    }

    BinancePrivateApiException(String message, Throwable cause) {
        super(message, cause);
        this.code = null;
        this.httpStatus = null;
        this.retryAtMillis = 0;
    }

    Integer code() {
        return code;
    }

    long retryAtMillis() {
        return retryAtMillis;
    }

    boolean outcomeUnknown() {
        return httpStatus == null
                || httpStatus >= 500
                || Integer.valueOf(-1007).equals(code)
                || Integer.valueOf(-1001).equals(code);
    }
}
