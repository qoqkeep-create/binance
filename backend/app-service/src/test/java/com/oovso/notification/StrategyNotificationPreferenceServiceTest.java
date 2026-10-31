package com.oovso.notification;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.oovso.notification.StrategyNotificationPreferenceMapper.PreferenceRow;
import org.junit.jupiter.api.Test;

class StrategyNotificationPreferenceServiceTest {

    private final StrategyNotificationPreferenceMapper mapper = mock(
            StrategyNotificationPreferenceMapper.class
    );

    private final StrategyNotificationPreferenceService service =
            new StrategyNotificationPreferenceService(mapper);

    @Test
    void defaultsEveryIntervalToEnabledForExistingUsers() {
        var preferences = service.preferences("user-1");

        assertTrue(preferences.fifteenMinuteEnabled());
        assertTrue(preferences.oneHourEnabled());
        assertTrue(preferences.fourHourEnabled());
    }

    @Test
    void mapsStoredFlagsAndPersistsCompletePreferenceSet() {
        when(mapper.selectByUser("user-1"))
                .thenReturn(new PreferenceRow(0, 1, 0));

        var stored = service.preferences("user-1");

        assertFalse(stored.fifteenMinuteEnabled());
        assertTrue(stored.oneHourEnabled());
        assertFalse(stored.fourHourEnabled());

        var updated = service.update("user-1", true, false, true);

        assertTrue(updated.fifteenMinuteEnabled());
        assertFalse(updated.oneHourEnabled());
        assertTrue(updated.fourHourEnabled());
        verify(mapper).upsert(
                org.mockito.ArgumentMatchers.eq("user-1"),
                org.mockito.ArgumentMatchers.eq(1),
                org.mockito.ArgumentMatchers.eq(0),
                org.mockito.ArgumentMatchers.eq(1),
                anyLong()
        );
    }
}
