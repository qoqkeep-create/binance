package com.oovso.binance;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.EOFException;
import java.io.IOException;
import javax.net.ssl.SSLHandshakeException;
import org.junit.jupiter.api.Test;

class BinanceNetworkExceptionSupportTest {

    @Test
    void recognizesWrappedPkixCertificateFailure() {
        SSLHandshakeException handshakeException =
                new SSLHandshakeException("PKIX path building failed: unable to find valid certification path");
        IOException wrapped = new IOException("Binance request failed", handshakeException);

        assertTrue(BinanceNetworkExceptionSupport.isTlsCertificateValidationFailure(wrapped));
    }

    @Test
    void doesNotHideUnrelatedNetworkFailure() {
        IOException timeout = new IOException("request timed out");

        assertFalse(BinanceNetworkExceptionSupport.isTlsCertificateValidationFailure(timeout));
    }

    @Test
    void recognizesWrappedTransientEofFailure() {
        IOException wrapped = new IOException(
                "Binance request failed",
                new EOFException("EOF reached while reading")
        );

        assertTrue(BinanceNetworkExceptionSupport.isTransientRestNetworkFailure(wrapped));
    }

    @Test
    void doesNotTreatGenericIOExceptionAsTransientNetworkFailure() {
        IOException unknown = new IOException("unexpected response shape");

        assertFalse(BinanceNetworkExceptionSupport.isTransientRestNetworkFailure(unknown));
    }
}
