package com.oovso.notification;

import cn.dev33.satoken.stp.StpUtil;
import com.oovso.web.ApiResponse;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/push/devices")
public class PushNotificationController {

    private final PushDeviceService deviceService;

    public PushNotificationController(PushDeviceService deviceService) {
        this.deviceService = deviceService;
    }

    @PostMapping("/register")
    public ApiResponse<Void> register(
            @Valid @RequestBody DeviceRequest request
    ) {
        deviceService.register(
                StpUtil.getLoginIdAsString(),
                request.installationId(),
                request.deviceToken(),
                request.environment(),
                request.bundleIdentifier()
        );
        return ApiResponse.success();
    }

    @PostMapping("/unregister")
    public ApiResponse<Void> unregister(
            @Valid @RequestBody DeviceIdentityRequest request
    ) {
        deviceService.unregister(
                StpUtil.getLoginIdAsString(),
                request.installationId()
        );
        return ApiResponse.success();
    }

    public record DeviceRequest(
            @NotBlank(message = "installationId 不能为空")
            @Pattern(
                    regexp = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
                    message = "installationId 格式无效"
            )
            String installationId,

            @NotBlank(message = "deviceToken 不能为空")
            @Size(min = 64, max = 256, message = "deviceToken 长度无效")
            @Pattern(
                    regexp = "^[0-9a-fA-F]+$",
                    message = "deviceToken 格式无效"
            )
            String deviceToken,

            @NotBlank(message = "environment 不能为空")
            @Pattern(
                    regexp = "(?i)^(sandbox|production)$",
                    message = "environment 格式无效"
            )
            String environment,

            @NotBlank(message = "bundleIdentifier 不能为空")
            @Size(max = 255, message = "bundleIdentifier 长度无效")
            String bundleIdentifier
    ) {
    }

    public record DeviceIdentityRequest(
            @NotBlank(message = "installationId 不能为空")
            @Pattern(
                    regexp = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
                    message = "installationId 格式无效"
            )
            String installationId
    ) {
    }
}
