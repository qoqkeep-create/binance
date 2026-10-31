package com.oovso.auth;

import cn.dev33.satoken.stp.StpUtil;
import cn.dev33.satoken.stp.parameter.SaLoginParameter;
import com.oovso.notification.PushDeviceService;
import com.oovso.reference.ReferenceTradeNotificationAccess;
import com.oovso.web.ApiResponse;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/auth")
public class AuthController {

    private final AuthService authService;

    private final PushDeviceService pushDeviceService;

    private final ReferenceTradeNotificationAccess referenceNotificationAccess;

    public AuthController(
            AuthService authService,
            PushDeviceService pushDeviceService,
            ReferenceTradeNotificationAccess referenceNotificationAccess
    ) {
        this.authService = authService;
        this.pushDeviceService = pushDeviceService;
        this.referenceNotificationAccess = referenceNotificationAccess;
    }

    @PostMapping("/login")
    public ApiResponse<LoginResponse> login(
            @Valid @RequestBody LoginRequest request,
            @RequestHeader(value = "X-Platform", defaultValue = "unknown")
            String platform
    ) {
        AppUser user = authService.authenticate(
                request.account(),
                request.password()
        );
        StpUtil.login(
                user.getId(),
                new SaLoginParameter()
                        .setDeviceType(normalizeDevice(platform))
                        .setIsLastingCookie(false)
        );

        return ApiResponse.success(
                buildLoginResponse(user)
        );
    }

    @PostMapping("/register")
    public ApiResponse<LoginResponse> register(
            @Valid @RequestBody RegisterRequest request,
            @RequestHeader(value = "X-Platform", defaultValue = "unknown")
            String platform
    ) {
        AppUser user = authService.register(
                request.account(),
                request.password(),
                request.displayName()
        );
        StpUtil.login(
                user.getId(),
                new SaLoginParameter()
                        .setDeviceType(normalizeDevice(platform))
                        .setIsLastingCookie(false)
        );

        return ApiResponse.success(buildLoginResponse(user));
    }

    @PostMapping("/logout")
    public ApiResponse<Void> logout(
            @RequestHeader(
                    value = "X-Push-Installation-ID",
                    required = false
            )
            String installationId
    ) {
        String userId = StpUtil.getLoginIdAsString();
        try {
            if (installationId != null) {
                pushDeviceService.unregister(
                        userId,
                        installationId
                );
            }
        } finally {
            StpUtil.logout();
        }
        return ApiResponse.success();
    }

    @GetMapping("/me")
    public ApiResponse<UserResponse> me() {
        AppUser user = authService.requireActiveUser(
                StpUtil.getLoginIdAsString()
        );
        return ApiResponse.success(userResponse(user));
    }

    private String normalizeDevice(String platform) {
        String normalized = AuthService.normalize(platform);
        if (normalized.isEmpty() || normalized.length() > 24) {
            return "unknown";
        }
        return normalized;
    }

    private LoginResponse buildLoginResponse(AppUser user) {
        return new LoginResponse(
                StpUtil.getTokenValue(),
                userResponse(user)
        );
    }

    private UserResponse userResponse(AppUser user) {
        return new UserResponse(
                user.getId(),
                user.getEmail(),
                user.getDisplayName(),
                referenceNotificationAccess.canView(user)
        );
    }

    public record LoginRequest(
            @NotBlank(message = "请输入邮箱或账号")
            @Size(max = 128, message = "账号长度不能超过 128 位")
            String account,

            @NotBlank(message = "请输入密码")
            @Size(min = 6, max = 256, message = "密码长度必须为 6 到 256 位")
            String password
    ) {
    }

    public record RegisterRequest(
            @NotBlank(message = "请输入邮箱或账号")
            @Size(max = 64, message = "账号长度不能超过 64 位")
            String account,

            @NotBlank(message = "请输入密码")
            @Size(min = 6, max = 256, message = "密码长度必须为 6 到 256 位")
            String password,

            @Size(max = 64, message = "昵称长度不能超过 64 位")
            String displayName
    ) {
    }

    public record LoginResponse(
            String accessToken,
            UserResponse user
    ) {
    }

    public record UserResponse(
            String id,
            String email,
            String displayName,
            boolean canViewReferenceNotifications
    ) {
    }
}
