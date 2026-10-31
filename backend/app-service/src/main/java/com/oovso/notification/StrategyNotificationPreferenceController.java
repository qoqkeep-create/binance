package com.oovso.notification;

import cn.dev33.satoken.stp.StpUtil;
import com.oovso.notification.StrategyNotificationPreferenceService.StrategyNotificationPreference;
import com.oovso.web.ApiResponse;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/strategy/notification-preferences")
public class StrategyNotificationPreferenceController {

    private final StrategyNotificationPreferenceService service;

    public StrategyNotificationPreferenceController(
            StrategyNotificationPreferenceService service
    ) {
        this.service = service;
    }

    @GetMapping
    public ApiResponse<StrategyNotificationPreference> preferences() {
        return ApiResponse.success(service.preferences(currentUserId()));
    }

    @PutMapping
    public ApiResponse<StrategyNotificationPreference> update(
            @Valid @RequestBody StrategyNotificationPreferenceRequest request
    ) {
        return ApiResponse.success(service.update(
                currentUserId(),
                request.fifteenMinuteEnabled(),
                request.oneHourEnabled(),
                request.fourHourEnabled()
        ));
    }

    String currentUserId() {
        return StpUtil.getLoginIdAsString();
    }

    public record StrategyNotificationPreferenceRequest(
            @NotNull(message = "15分钟提醒开关不能为空")
            Boolean fifteenMinuteEnabled,
            @NotNull(message = "1小时提醒开关不能为空")
            Boolean oneHourEnabled,
            @NotNull(message = "4小时提醒开关不能为空")
            Boolean fourHourEnabled
    ) {
    }
}
