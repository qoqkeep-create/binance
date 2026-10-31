package com.oovso.notification;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.oovso.auth.AuthService;
import com.oovso.auth.SaTokenConfiguration;
import com.oovso.notification.StrategyNotificationPreferenceService.StrategyNotificationPreference;
import com.oovso.web.GlobalApiExceptionHandler;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.context.annotation.Import;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

@ActiveProfiles("test")
@WebMvcTest(StrategyNotificationPreferenceController.class)
@Import({SaTokenConfiguration.class, GlobalApiExceptionHandler.class})
class StrategyNotificationPreferenceControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @MockitoBean
    private StrategyNotificationPreferenceService service;

    @MockitoBean
    private AuthService authService;

    @Test
    void requiresAnAppSession() throws Exception {
        mockMvc.perform(get("/api/strategy/notification-preferences"))
                .andExpect(status().isUnauthorized());
    }

    @Test
    void readsAndUpdatesPreferencesForCurrentUser() {
        StrategyNotificationPreference expected =
                new StrategyNotificationPreference(true, false, true);
        when(service.preferences("user-1")).thenReturn(expected);
        when(service.update("user-1", false, true, false))
                .thenReturn(new StrategyNotificationPreference(
                        false,
                        true,
                        false
                ));
        StrategyNotificationPreferenceController controller =
                new StrategyNotificationPreferenceController(service) {
                    @Override
                    String currentUserId() {
                        return "user-1";
                    }
                };

        var readResponse = controller.preferences();
        var updateResponse = controller.update(
                new StrategyNotificationPreferenceController
                        .StrategyNotificationPreferenceRequest(
                        false,
                        true,
                        false
                )
        );

        assertTrue(readResponse.data().fifteenMinuteEnabled());
        assertFalse(readResponse.data().oneHourEnabled());
        assertFalse(updateResponse.data().fifteenMinuteEnabled());
        assertTrue(updateResponse.data().oneHourEnabled());
        verify(service).preferences("user-1");
        verify(service).update("user-1", false, true, false);
    }
}
