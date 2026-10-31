package com.oovso.notification;

import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.inOrder;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import org.junit.jupiter.api.Test;
import org.mockito.InOrder;
import org.mockito.Mockito;

class PushDeviceServiceTest {

    private static final long NOW = 1_786_156_800_000L;

    private final PushDeviceMapper mapper = Mockito.mock(
            PushDeviceMapper.class
    );

    private final ApnsNotificationProperties properties = properties();

    private final PushDeviceService service = new PushDeviceService(
            mapper,
            properties,
            Clock.fixed(Instant.ofEpochMilli(NOW), ZoneOffset.UTC)
    );

    @Test
    void registerNormalizesAndReplacesInstallationToken() {
        String installation = "5D9A41AB-5B6A-4E11-94E5-0FEE84C784EF";
        String token = "A1".repeat(32);

        service.register(
                "user-1",
                installation,
                token,
                "sandbox",
                "com.oovso.trade"
        );

        InOrder order = inOrder(mapper);
        order.verify(mapper).disableOtherInstallationTokens(
                installation.toLowerCase(),
                token.toLowerCase(),
                "SANDBOX",
                NOW
        );
        order.verify(mapper).upsert(
                anyString(),
                eq("user-1"),
                eq(installation.toLowerCase()),
                eq(token.toLowerCase()),
                eq("SANDBOX"),
                eq("com.oovso.trade"),
                eq(NOW)
        );
    }

    @Test
    void invalidDeviceTokenIsRejectedBeforeDatabaseWrite() {
        assertThrows(
                IllegalArgumentException.class,
                () -> service.register(
                        "user-1",
                        "5d9a41ab-5b6a-4e11-94e5-0fee84c784ef",
                        "not-a-token",
                        "sandbox",
                        "com.oovso.trade"
                )
        );
    }

    @Test
    void mismatchedBundleIdentifierIsRejectedBeforeDatabaseWrite() {
        assertThrows(
                IllegalArgumentException.class,
                () -> service.register(
                        "user-1",
                        "5d9a41ab-5b6a-4e11-94e5-0fee84c784ef",
                        "a1".repeat(32),
                        "production",
                        "com.oovso.tradetool"
                )
        );
        Mockito.verifyNoInteractions(mapper);
    }

    @Test
    void unregisterOnlyDisablesOwnedInstallation() {
        service.unregister(
                "user-1",
                "5d9a41ab-5b6a-4e11-94e5-0fee84c784ef"
        );

        Mockito.verify(mapper).disableOwnedInstallation(
                "user-1",
                "5d9a41ab-5b6a-4e11-94e5-0fee84c784ef",
                NOW
        );
    }

    @Test
    void invalidationPersistsReason() {
        service.invalidate("device-1", "BadDeviceToken");

        Mockito.verify(mapper).disableById(
                "device-1",
                "BadDeviceToken",
                NOW
        );
    }

    private static ApnsNotificationProperties properties() {
        ApnsNotificationProperties properties =
                new ApnsNotificationProperties();
        properties.setTopic("com.oovso.trade");
        return properties;
    }
}
