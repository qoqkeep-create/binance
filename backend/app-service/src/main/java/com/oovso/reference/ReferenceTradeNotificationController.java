package com.oovso.reference;

import cn.dev33.satoken.stp.StpUtil;
import com.oovso.reference.ReferenceTradeNotificationQueryService.ReferenceTradeNotificationPage;
import com.oovso.web.ApiResponse;
import jakarta.validation.constraints.Size;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/reference/trade-notifications")
public class ReferenceTradeNotificationController {

    private final ReferenceTradeNotificationQueryService queryService;

    public ReferenceTradeNotificationController(
            ReferenceTradeNotificationQueryService queryService
    ) {
        this.queryService = queryService;
    }

    @GetMapping
    public ApiResponse<ReferenceTradeNotificationPage> notifications(
            @RequestParam(required = false)
            @Size(max = 160, message = "分页游标无效")
            String cursor
    ) {
        return ApiResponse.success(queryService.query(
                currentUserId(),
                cursor
        ));
    }

    String currentUserId() {
        return StpUtil.getLoginIdAsString();
    }
}
