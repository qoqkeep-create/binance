package com.oovso.notification;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.oovso.notification.PushDeviceMapper.RegisteredPushDevice;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.transaction.annotation.Transactional;

@ActiveProfiles("test")
@SpringBootTest
@Transactional
class PushDeviceMapperIntegrationTest {

    private static final String INSTALLATION_ID =
            "5d9a41ab-5b6a-4e11-94e5-0fee84c784ef";

    @Autowired
    private PushDeviceService service;

    @Autowired
    private JdbcTemplate jdbcTemplate;

    @Autowired
    private StrategyNotificationPreferenceService preferenceService;

    @Test
    void invalidTokenStaysDisabledUntilApnsIssuesANewToken() {
        String invalidToken = "a1".repeat(32);
        service.register(
                "user-1",
                INSTALLATION_ID,
                invalidToken,
                "production",
                "com.oovso.trade"
        );
        RegisteredPushDevice registered = service.activeDevices().getFirst();
        service.invalidate(registered.id(), "BadDeviceToken");

        service.register(
                "user-1",
                INSTALLATION_ID,
                invalidToken,
                "production",
                "com.oovso.trade"
        );

        assertTrue(service.activeDevices().isEmpty());
        assertEquals(
                "BadDeviceToken",
                jdbcTemplate.queryForObject(
                        "select invalid_reason from app_push_device "
                                + "where device_token = ?",
                        String.class,
                        invalidToken
                )
        );

        String replacementToken = "b2".repeat(32);
        service.register(
                "user-1",
                INSTALLATION_ID,
                replacementToken,
                "production",
                "com.oovso.trade"
        );

        List<RegisteredPushDevice> active = service.activeDevices();
        assertEquals(1, active.size());
        assertEquals(replacementToken, active.getFirst().deviceToken());
        assertEquals(1, service.activeDevices("user-1").size());
        assertTrue(service.activeDevices("user-2").isEmpty());
    }

    @Test
    void unregisterDisablesEveryEnvironmentForOwnedInstallation() {
        service.register(
                "user-1",
                INSTALLATION_ID,
                "c3".repeat(32),
                "sandbox",
                "com.oovso.trade"
        );
        service.register(
                "user-1",
                INSTALLATION_ID,
                "d4".repeat(32),
                "production",
                "com.oovso.trade"
        );

        service.unregister("user-1", INSTALLATION_ID);

        assertTrue(service.activeDevices().isEmpty());
    }

    @Test
    void strategyDevicesAreFilteredByUserIntervalPreference() {
        service.register(
                "user-1",
                INSTALLATION_ID,
                "e5".repeat(32),
                "production",
                "com.oovso.trade"
        );

        assertEquals(
                1,
                service.activeDevicesForStrategyInterval("15m").size()
        );

        preferenceService.update("user-1", false, true, false);

        assertTrue(
                service.activeDevicesForStrategyInterval("15m").isEmpty()
        );
        assertEquals(
                1,
                service.activeDevicesForStrategyInterval("1h").size()
        );
        assertTrue(
                service.activeDevicesForStrategyInterval(
                        "user-1",
                        "4h"
                ).isEmpty()
        );
    }
}
