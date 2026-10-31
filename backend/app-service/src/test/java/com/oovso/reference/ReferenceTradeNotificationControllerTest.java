package com.oovso.reference;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.oovso.auth.AuthService;
import com.oovso.auth.SaTokenConfiguration;
import com.oovso.reference.ReferenceTradeNotificationQueryService.ReferenceTradeNotificationPage;
import com.oovso.web.GlobalApiExceptionHandler;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.context.annotation.Import;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

@ActiveProfiles("test")
@WebMvcTest(ReferenceTradeNotificationController.class)
@Import({SaTokenConfiguration.class, GlobalApiExceptionHandler.class})
class ReferenceTradeNotificationControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @MockitoBean
    private ReferenceTradeNotificationQueryService queryService;

    @MockitoBean
    private AuthService authService;

    @Test
    void requiresAnAppSession() throws Exception {
        mockMvc.perform(get("/api/reference/trade-notifications"))
                .andExpect(status().isUnauthorized());
    }

    @Test
    void passesCurrentUserAndCursorToQueryService() {
        when(queryService.query("target-user", "next-page"))
                .thenReturn(new ReferenceTradeNotificationPage(
                        20,
                        false,
                        null,
                        List.of()
                ));
        ReferenceTradeNotificationController controller =
                new ReferenceTradeNotificationController(queryService) {
                    @Override
                    String currentUserId() {
                        return "target-user";
                    }
                };

        var response = controller.notifications("next-page");

        assertEquals(200, response.code());
        assertEquals(20, response.data().size());
        verify(queryService).query("target-user", "next-page");
    }
}
