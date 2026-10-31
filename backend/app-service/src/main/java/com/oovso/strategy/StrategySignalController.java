package com.oovso.strategy;

import cn.dev33.satoken.stp.StpUtil;
import com.oovso.strategy.StrategySignalQueryService.ReversalAlertMutation;
import com.oovso.strategy.StrategySignalQueryService.StrategySignalPage;
import com.oovso.web.ApiResponse;
import jakarta.validation.constraints.Size;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/strategy/signals")
public class StrategySignalController {

    private final StrategySignalQueryService queryService;

    public StrategySignalController(
            StrategySignalQueryService queryService
    ) {
        this.queryService = queryService;
    }

    @GetMapping
    public ApiResponse<StrategySignalPage> signals(
            @RequestParam(required = false)
            @Size(max = 160, message = "分页游标无效")
            String cursor
    ) {
        return ApiResponse.success(queryService.query(
                StpUtil.getLoginIdAsString(),
                cursor
        ));
    }

    @PutMapping("/{signalId}/read")
    public ApiResponse<Void> markRead(
            @PathVariable String signalId
    ) {
        queryService.markRead(
                StpUtil.getLoginIdAsString(),
                signalId
        );
        return ApiResponse.success();
    }

    @PutMapping("/{signalId}/reversal-alert")
    public ApiResponse<ReversalAlertMutation> activateReversalAlert(
            @PathVariable String signalId
    ) {
        return ApiResponse.success(queryService.activateReversalAlert(
                StpUtil.getLoginIdAsString(),
                signalId
        ));
    }

    @DeleteMapping("/{signalId}")
    public ApiResponse<Void> delete(
            @PathVariable String signalId
    ) {
        queryService.delete(
                StpUtil.getLoginIdAsString(),
                signalId
        );
        return ApiResponse.success();
    }
}
