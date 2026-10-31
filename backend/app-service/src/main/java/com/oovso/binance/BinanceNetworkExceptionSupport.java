package com.oovso.binance;

import java.io.EOFException;
import java.net.SocketException;
import java.net.SocketTimeoutException;
import java.net.http.HttpTimeoutException;
import javax.net.ssl.SSLHandshakeException;

public final class BinanceNetworkExceptionSupport {

    private BinanceNetworkExceptionSupport() {
    }

    public static boolean isTlsCertificateValidationFailure(Throwable error) {
        for (Throwable current = error; current != null; current = current.getCause()) {
            String message = current.getMessage();
            if (current instanceof SSLHandshakeException
                    && containsCertificateValidationMessage(message)) {
                return true;
            }
            if (containsCertificateValidationMessage(message)) {
                return true;
            }
        }
        return false;
    }

    public static boolean isTransientRestNetworkFailure(Throwable error) {
        for (Throwable current = error; current != null; current = current.getCause()) {
            if (current instanceof EOFException
                    || current instanceof SocketException
                    || current instanceof SocketTimeoutException
                    || current instanceof HttpTimeoutException) {
                return true;
            }
            if (containsTransientNetworkMessage(current.getMessage())) {
                return true;
            }
        }
        return false;
    }

    public static String conciseMessage(Throwable error) {
        Throwable current = error;
        Throwable last = error;
        while (current != null) {
            last = current;
            current = current.getCause();
        }
        String message = last == null ? null : last.getMessage();
        if (message == null || message.isBlank()) {
            return error == null ? "unknown TLS certificate validation failure" : error.getClass().getSimpleName();
        }
        return message;
    }

    private static boolean containsCertificateValidationMessage(String message) {
        return message != null
                && (message.contains("PKIX path building failed")
                || message.contains("unable to find valid certification path"));
    }

    private static boolean containsTransientNetworkMessage(String message) {
        if (message == null) {
            return false;
        }
        String normalized = message.toLowerCase();
        return normalized.contains("eof reached while reading")
                || normalized.contains("connection reset")
                || normalized.contains("connection closed")
                || normalized.contains("broken pipe")
                || normalized.contains("premature eof")
                || normalized.contains("timeout");
    }
}
