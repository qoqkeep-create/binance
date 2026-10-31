package com.oovso.reference;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.oovso.auth.AppUser;
import org.junit.jupiter.api.Test;

class ReferenceTradeNotificationAccessTest {

    @Test
    void matchesConfiguredEmailWithoutCaseOrWhitespaceCoupling() {
        ReferenceTradeNotificationProperties properties =
                new ReferenceTradeNotificationProperties();
        properties.setTargetEmail("  Reference@Example.COM ");
        ReferenceTradeNotificationAccess access =
                new ReferenceTradeNotificationAccess(properties);
        AppUser user = new AppUser();
        user.setEmail("reference@example.com");

        assertTrue(access.canView(user));

        user.setEmail("other@example.com");
        assertFalse(access.canView(user));
    }
}
