package com.oovso.external;

import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.verify;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.oovso.auth.AuthService;
import com.oovso.auth.SaTokenConfiguration;
import com.oovso.web.GlobalApiExceptionHandler;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.context.annotation.Import;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

@ActiveProfiles("test")
@WebMvcTest(ExternalMessageController.class)
@Import({SaTokenConfiguration.class, GlobalApiExceptionHandler.class})
class ExternalMessageControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @MockitoBean
    private ExternalMessageService messageService;

    @MockitoBean
    private AuthService authService;

    @Test
    void acceptsArbitraryJsonWithoutAppSession() throws Exception {
        String payload = """
                {
                  "schemaVersion": 1,
                  "type": "SENDER_DEFINED_EVENT",
                  "nested": {"anything": [1, true, null]}
                }
                """;

        mockMvc.perform(post("/api/external/messages")
                        .contentType(MediaType.APPLICATION_JSON)
                        .header("X-External-Message-Key", "test-api-key")
                        .content(payload))
                .andExpect(status().isAccepted())
                .andExpect(jsonPath("$.code").value(202))
                .andExpect(jsonPath("$.message").value("accepted"));

        verify(messageService).accept("test-api-key", payload);
    }

    @Test
    void returnsUnauthorizedWhenApiKeyIsRejected() throws Exception {
        doThrow(new ExternalMessageApiException(
                HttpStatus.UNAUTHORIZED,
                "外部消息密钥无效"
        )).when(messageService).accept("wrong-key", "{}");

        mockMvc.perform(post("/api/external/messages")
                        .contentType(MediaType.APPLICATION_JSON)
                        .header("X-External-Message-Key", "wrong-key")
                        .content("{}"))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.code").value(401))
                .andExpect(jsonPath("$.message").value("外部消息密钥无效"));
    }
}
