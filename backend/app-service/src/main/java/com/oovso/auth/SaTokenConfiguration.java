package com.oovso.auth;

import cn.dev33.satoken.interceptor.SaInterceptor;
import cn.dev33.satoken.stp.StpUtil;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.servlet.config.annotation.InterceptorRegistry;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;

@Configuration
public class SaTokenConfiguration implements WebMvcConfigurer {

    private final AuthService authService;

    public SaTokenConfiguration(AuthService authService) {
        this.authService = authService;
    }

    @Override
    public void addInterceptors(InterceptorRegistry registry) {
        registry.addInterceptor(new SaInterceptor(handler -> {
                    StpUtil.checkLogin();
                    try {
                        authService.requireActiveUser(
                                StpUtil.getLoginIdAsString()
                        );
                    } catch (SessionInvalidException exception) {
                        StpUtil.logout();
                        throw exception;
                    }
                }))
                .addPathPatterns("/api/**")
                .excludePathPatterns(
                        "/api/auth/login",
                        "/api/auth/register",
                        "/api/external/messages"
                );
    }
}
