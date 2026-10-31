package com.oovso.external;

import java.time.Instant;

public record ExternalMessage(
        String id,
        String payloadJson,
        Instant receivedAt
) {
}
