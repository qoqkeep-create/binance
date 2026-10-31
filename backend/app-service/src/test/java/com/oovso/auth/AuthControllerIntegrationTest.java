package com.oovso.auth;

import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import cn.dev33.satoken.dao.SaTokenDao;
import cn.dev33.satoken.dao.SaTokenDaoDefaultImpl;
import com.jayway.jsonpath.JsonPath;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.Primary;
import org.springframework.http.MediaType;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;

@ActiveProfiles("test")
@SpringBootTest
@AutoConfigureMockMvc
@Import(AuthControllerIntegrationTest.InMemorySaTokenConfiguration.class)
class AuthControllerIntegrationTest {

    @Autowired
    private MockMvc mockMvc;

    @MockitoBean
    private AuthService authService;

    @Test
    void loginAccessProtectedEndpointAndLogout() throws Exception {
        AppUser user = user();
        when(authService.authenticate("admin", "secure-password"))
                .thenReturn(user);
        when(authService.requireActiveUser("user-id"))
                .thenReturn(user);

        MvcResult loginResult = mockMvc.perform(post("/api/auth/login")
                        .contentType(MediaType.APPLICATION_JSON)
                        .header("X-Platform", "ios")
                        .content("""
                                {
                                  "account": "admin",
                                  "password": "secure-password"
                                }
                                """))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.code").value(200))
                .andExpect(jsonPath("$.data.user.id").value("user-id"))
                .andExpect(jsonPath("$.data.user.email").value("admin@example.com"))
                .andExpect(jsonPath(
                        "$.data.user.canViewReferenceNotifications"
                ).value(false))
                .andExpect(jsonPath("$.data.accessToken").isNotEmpty())
                .andReturn();

        String token = JsonPath.read(
                loginResult.getResponse().getContentAsString(),
                "$.data.accessToken"
        );
        String authorization = "Bearer " + token;

        mockMvc.perform(get("/api/auth/me")
                        .header("Authorization", authorization))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.data.displayName").value("Administrator"))
                .andExpect(jsonPath(
                        "$.data.canViewReferenceNotifications"
                ).value(false));

        mockMvc.perform(post("/api/auth/logout")
                        .header("Authorization", authorization))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.code").value(200));

        mockMvc.perform(get("/api/auth/me")
                        .header("Authorization", authorization))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.code").value(401));
    }

    @Test
    void registerCreatesSessionAndReturnsUser() throws Exception {
        AppUser user = registeredUser();
        when(authService.register("new-user", "secure-password", null))
                .thenReturn(user);
        when(authService.requireActiveUser("new-user-id"))
                .thenReturn(user);

        MvcResult registerResult = mockMvc.perform(post("/api/auth/register")
                        .contentType(MediaType.APPLICATION_JSON)
                        .header("X-Platform", "ios")
                        .content("""
                                {
                                  "account": "new-user",
                                  "password": "secure-password"
                                }
                                """))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.code").value(200))
                .andExpect(jsonPath("$.data.user.id").value("new-user-id"))
                .andExpect(jsonPath("$.data.user.email").value("new-user@local.invalid"))
                .andExpect(jsonPath("$.data.user.displayName").value("new-user"))
                .andExpect(jsonPath("$.data.accessToken").isNotEmpty())
                .andReturn();

        String token = JsonPath.read(
                registerResult.getResponse().getContentAsString(),
                "$.data.accessToken"
        );

        mockMvc.perform(get("/api/auth/me")
                        .header("Authorization", "Bearer " + token))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.data.id").value("new-user-id"));
    }

    private AppUser user() {
        AppUser user = new AppUser();
        user.setId("user-id");
        user.setAccount("admin");
        user.setEmail("admin@example.com");
        user.setDisplayName("Administrator");
        user.setEnabledState(1);
        return user;
    }

    private AppUser registeredUser() {
        AppUser user = new AppUser();
        user.setId("new-user-id");
        user.setAccount("new-user");
        user.setEmail("new-user@local.invalid");
        user.setDisplayName("new-user");
        user.setEnabledState(1);
        return user;
    }

    static class InMemorySaTokenConfiguration {

        @Bean
        @Primary
        SaTokenDao inMemorySaTokenDao() {
            return new SaTokenDaoDefaultImpl();
        }
    }
}
