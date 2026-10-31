package com.oovso.realtime;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

import org.junit.jupiter.api.Test;

class RealtimeHandshakeInterceptorTest {

    @Test
    void extractsBearerTokenWithoutLeakingPrefix() {
        assertEquals(
                "token-value",
                RealtimeHandshakeInterceptor.bearerToken(
                        "Bearer token-value"
                )
        );
        assertEquals(
                "token-value",
                RealtimeHandshakeInterceptor.bearerToken(
                        "bearer   token-value  "
                )
        );
    }

    @Test
    void rejectsMissingOrUnsupportedAuthorization() {
        assertNull(RealtimeHandshakeInterceptor.bearerToken(null));
        assertNull(RealtimeHandshakeInterceptor.bearerToken(""));
        assertNull(RealtimeHandshakeInterceptor.bearerToken("Basic token-value"));
        assertNull(RealtimeHandshakeInterceptor.bearerToken("Bearer "));
    }
}
