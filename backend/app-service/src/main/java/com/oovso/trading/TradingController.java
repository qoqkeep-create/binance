package com.oovso.trading;

import cn.dev33.satoken.stp.StpUtil;
import com.oovso.trading.TradingAccountService.AccountView;
import com.oovso.trading.TradingAccountService.LeverageView;
import com.oovso.trading.TradingAccountService.PositionView;
import com.oovso.trading.TradingAccountService.RiskPolicyCommand;
import com.oovso.trading.TradingAccountService.RiskPolicyView;
import com.oovso.trading.TradingConfigurationService.ExitStrategyCommand;
import com.oovso.trading.TradingConfigurationService.ExitStrategyLevelCommand;
import com.oovso.trading.TradingConfigurationService.ExitStrategyView;
import com.oovso.trading.TradingConfigurationService.LossLimitView;
import com.oovso.trading.TradingConfigurationService.OrderSettingsCommand;
import com.oovso.trading.TradingConfigurationService.OrderSettingsView;
import com.oovso.trading.TradingExecutionService.EntryCommand;
import com.oovso.trading.TradingExecutionService.EntryCommandView;
import com.oovso.trading.TradingAccountQueryService.AccountSnapshotView;
import com.oovso.trading.TradingAccountQueryService.FillView;
import com.oovso.trading.TradingAccountQueryService.OrderView;
import com.oovso.trading.TradingAccountQueryService.PositionCenterView;
import com.oovso.trading.TradingAccountQueryService.ReconcileAccepted;
import com.oovso.web.ApiResponse;
import jakarta.validation.Valid;
import jakarta.validation.constraints.DecimalMax;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import java.math.BigDecimal;
import java.util.List;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.http.ResponseEntity;
import org.springframework.http.HttpStatus;
import org.springframework.validation.annotation.Validated;

@RestController
@RequestMapping("/api/trading/accounts")
@Validated
public class TradingController {

    private final TradingAccountService accountService;
    private final TradingConfigurationService configurationService;
    private final TradingAccountQueryService queryService;
    private final TradingExecutionService executionService;

    public TradingController(
            TradingAccountService accountService,
            TradingConfigurationService configurationService,
            TradingAccountQueryService queryService,
            TradingExecutionService executionService
    ) {
        this.accountService = accountService;
        this.configurationService = configurationService;
        this.queryService = queryService;
        this.executionService = executionService;
    }

    @GetMapping
    public ApiResponse<List<AccountView>> accounts() {
        return ApiResponse.success(
                accountService.accounts(currentUserId())
        );
    }

    @PostMapping
    public ApiResponse<AccountView> bind(
            @Valid @RequestBody BindAccountRequest request
    ) {
        return ApiResponse.success(accountService.bind(
                currentUserId(),
                request.apiKey(),
                request.secretKey()
        ));
    }

    @PostMapping("/{accountId}/refresh")
    public ApiResponse<AccountView> refresh(
            @PathVariable @Size(max = 40) String accountId
    ) {
        return ApiResponse.success(accountService.refresh(
                currentUserId(),
                accountId
        ));
    }

    @DeleteMapping("/{accountId}")
    public ApiResponse<Void> unbind(
            @PathVariable @Size(max = 40) String accountId
    ) {
        accountService.unbind(currentUserId(), accountId);
        return ApiResponse.success();
    }

    @GetMapping("/{accountId}/positions")
    public ApiResponse<List<PositionView>> positions(
            @PathVariable @Size(max = 40) String accountId
    ) {
        return ApiResponse.success(accountService.positions(
                currentUserId(),
                accountId
        ));
    }

    @GetMapping("/{accountId}/leverage")
    public ApiResponse<LeverageView> leverage(
            @PathVariable @Size(max = 40) String accountId,
            @RequestParam @NotBlank @Size(max = 32) String symbol
    ) {
        return ApiResponse.success(accountService.leverage(
                currentUserId(),
                accountId,
                symbol
        ));
    }

    @PutMapping("/{accountId}/leverage")
    public ApiResponse<LeverageView> updateLeverage(
            @PathVariable @Size(max = 40) String accountId,
            @Valid @RequestBody LeverageRequest request
    ) {
        return ApiResponse.success(accountService.updateLeverage(
                currentUserId(),
                accountId,
                request.symbol(),
                request.leverage()
        ));
    }

    @GetMapping("/{accountId}/snapshot")
    public ApiResponse<AccountSnapshotView> snapshot(
            @PathVariable @Size(max = 40) String accountId
    ) {
        return ApiResponse.success(queryService.snapshot(
                currentUserId(),
                accountId
        ));
    }

    @GetMapping("/{accountId}/orders")
    public ApiResponse<List<OrderView>> orders(
            @PathVariable @Size(max = 40) String accountId,
            @RequestParam(defaultValue = "100") @Min(1) @Max(500) int limit
    ) {
        return ApiResponse.success(queryService.orders(
                currentUserId(),
                accountId,
                limit
        ));
    }

    @GetMapping("/{accountId}/position-center")
    public ApiResponse<PositionCenterView> positionCenter(
            @PathVariable @Size(max = 40) String accountId,
            @RequestParam(defaultValue = "100") @Min(1) @Max(200)
            int historyLimit
    ) {
        return ApiResponse.success(queryService.positionCenter(
                currentUserId(),
                accountId,
                historyLimit
        ));
    }

    @PostMapping("/{accountId}/orders")
    public ResponseEntity<ApiResponse<EntryCommandView>> createEntryOrder(
            @PathVariable @Size(max = 40) String accountId,
            @RequestHeader("Idempotency-Key")
            @Size(max = 80) String idempotencyKey,
            @Valid @RequestBody EntryOrderRequest request
    ) {
        EntryCommandView accepted = executionService.createEntry(
                currentUserId(),
                accountId,
                idempotencyKey,
                new EntryCommand(
                        request.symbol(),
                        request.direction(),
                        request.entryPrice(),
                        request.stopPrice()
                )
        );
        return ResponseEntity.status(HttpStatus.ACCEPTED).body(
                ApiResponse.success(accepted)
        );
    }

    @DeleteMapping("/{accountId}/entry-orders/{orderId}")
    public ResponseEntity<ApiResponse<EntryCommandView>> cancelEntryOrder(
            @PathVariable @Size(max = 40) String accountId,
            @PathVariable @Size(max = 40) String orderId,
            @RequestHeader("Idempotency-Key")
            @Size(max = 80) String idempotencyKey
    ) {
        EntryCommandView accepted = executionService.cancelEntryLimitOrder(
                currentUserId(),
                accountId,
                idempotencyKey,
                orderId
        );
        return ResponseEntity.status(HttpStatus.ACCEPTED).body(
                ApiResponse.success(accepted)
        );
    }

    @PostMapping("/{accountId}/positions/{positionId}/close")
    public ResponseEntity<ApiResponse<EntryCommandView>> closePosition(
            @PathVariable @Size(max = 40) String accountId,
            @PathVariable @Size(max = 40) String positionId,
            @RequestHeader("Idempotency-Key")
            @Size(max = 80) String idempotencyKey,
            @Valid @RequestBody ClosePositionRequest request
    ) {
        EntryCommandView accepted = executionService.closePosition(
                currentUserId(),
                accountId,
                idempotencyKey,
                positionId,
                request.orderType()
        );
        return ResponseEntity.status(HttpStatus.ACCEPTED).body(
                ApiResponse.success(accepted)
        );
    }

    @DeleteMapping(
            "/{accountId}/positions/{positionId}/maker-close-orders/{orderId}"
    )
    public ResponseEntity<ApiResponse<EntryCommandView>> cancelMakerClose(
            @PathVariable @Size(max = 40) String accountId,
            @PathVariable @Size(max = 40) String positionId,
            @PathVariable @Size(max = 40) String orderId,
            @RequestHeader("Idempotency-Key")
            @Size(max = 80) String idempotencyKey
    ) {
        EntryCommandView accepted = executionService.cancelMakerClose(
                currentUserId(),
                accountId,
                idempotencyKey,
                positionId,
                orderId
        );
        return ResponseEntity.status(HttpStatus.ACCEPTED).body(
                ApiResponse.success(accepted)
        );
    }

    @GetMapping("/{accountId}/commands/{commandId}")
    public ApiResponse<EntryCommandView> command(
            @PathVariable @Size(max = 40) String accountId,
            @PathVariable @Size(max = 40) String commandId
    ) {
        return ApiResponse.success(executionService.command(
                currentUserId(),
                accountId,
                commandId
        ));
    }

    @GetMapping("/{accountId}/fills")
    public ApiResponse<List<FillView>> fills(
            @PathVariable @Size(max = 40) String accountId,
            @RequestParam(defaultValue = "100") @Min(1) @Max(500) int limit
    ) {
        return ApiResponse.success(queryService.fills(
                currentUserId(),
                accountId,
                limit
        ));
    }

    @PostMapping("/{accountId}/reconcile")
    public ResponseEntity<ApiResponse<ReconcileAccepted>> reconcile(
            @PathVariable @Size(max = 40) String accountId
    ) {
        return ResponseEntity.status(HttpStatus.ACCEPTED).body(
                ApiResponse.success(queryService.requestReconcile(
                        currentUserId(),
                        accountId
                ))
        );
    }

    @GetMapping("/{accountId}/risk-policy")
    public ApiResponse<RiskPolicyView> riskPolicy(
            @PathVariable @Size(max = 40) String accountId
    ) {
        return ApiResponse.success(accountService.riskPolicy(
                currentUserId(),
                accountId
        ));
    }

    @PutMapping("/{accountId}/risk-policy")
    public ApiResponse<RiskPolicyView> updateRiskPolicy(
            @PathVariable @Size(max = 40) String accountId,
            @Valid @RequestBody RiskPolicyRequest request
    ) {
        return ApiResponse.success(accountService.updateRiskPolicy(
                currentUserId(),
                accountId,
                new RiskPolicyCommand(
                        request.enabled(),
                        request.takeProfitEnabled(),
                        request.stopLossEnabled(),
                        request.takeProfitPercent(),
                        request.stopLossPercent(),
                        request.maxLossAmount()
                )
        ));
    }

    @GetMapping("/{accountId}/exit-strategies")
    public ApiResponse<List<ExitStrategyView>> exitStrategies(
            @PathVariable @Size(max = 40) String accountId
    ) {
        return ApiResponse.success(configurationService.strategies(
                currentUserId(),
                accountId
        ));
    }

    @PostMapping("/{accountId}/exit-strategies")
    public ApiResponse<ExitStrategyView> createExitStrategy(
            @PathVariable @Size(max = 40) String accountId,
            @Valid @RequestBody ExitStrategyRequest request
    ) {
        return ApiResponse.success(configurationService.createStrategy(
                currentUserId(),
                accountId,
                request.toCommand()
        ));
    }

    @PutMapping("/{accountId}/exit-strategies/{strategyId}")
    public ApiResponse<ExitStrategyView> updateExitStrategy(
            @PathVariable @Size(max = 40) String accountId,
            @PathVariable @Size(max = 40) String strategyId,
            @Valid @RequestBody ExitStrategyRequest request
    ) {
        return ApiResponse.success(configurationService.updateStrategy(
                currentUserId(),
                accountId,
                strategyId,
                request.toCommand()
        ));
    }

    @DeleteMapping("/{accountId}/exit-strategies/{strategyId}")
    public ApiResponse<Void> deleteExitStrategy(
            @PathVariable @Size(max = 40) String accountId,
            @PathVariable @Size(max = 40) String strategyId
    ) {
        configurationService.deleteStrategy(
                currentUserId(),
                accountId,
                strategyId
        );
        return ApiResponse.success();
    }

    @GetMapping("/{accountId}/loss-limit")
    public ApiResponse<LossLimitView> lossLimit(
            @PathVariable @Size(max = 40) String accountId
    ) {
        return ApiResponse.success(configurationService.lossLimit(
                currentUserId(),
                accountId
        ));
    }

    @PutMapping("/{accountId}/loss-limit")
    public ApiResponse<LossLimitView> updateLossLimit(
            @PathVariable @Size(max = 40) String accountId,
            @Valid @RequestBody LossLimitRequest request
    ) {
        return ApiResponse.success(configurationService.updateLossLimit(
                currentUserId(),
                accountId,
                request.percentage()
        ));
    }

    @GetMapping("/{accountId}/order-settings")
    public ApiResponse<OrderSettingsView> orderSettings(
            @PathVariable @Size(max = 40) String accountId
    ) {
        return ApiResponse.success(configurationService.orderSettings(
                currentUserId(),
                accountId
        ));
    }

    @PutMapping("/{accountId}/order-settings")
    public ApiResponse<OrderSettingsView> updateOrderSettings(
            @PathVariable @Size(max = 40) String accountId,
            @Valid @RequestBody OrderSettingsRequest request
    ) {
        return ApiResponse.success(configurationService.updateOrderSettings(
                currentUserId(),
                accountId,
                request.toCommand()
        ));
    }

    private String currentUserId() {
        return StpUtil.getLoginIdAsString();
    }

    public record BindAccountRequest(
            @NotBlank(message = "请输入API Key")
            @Size(max = 256, message = "API Key长度不能超过256位")
            String apiKey,

            @NotBlank(message = "请输入Secret Key")
            @Size(max = 256, message = "Secret Key长度不能超过256位")
            String secretKey
    ) {
    }

    public record LeverageRequest(
            @NotBlank(message = "请选择交易对")
            @Size(max = 32, message = "交易对无效")
            String symbol,

            @Min(value = 1, message = "杠杆倍数不能低于1倍")
            @Max(value = 125, message = "杠杆倍数不能超过125倍")
            int leverage
    ) {
    }

    public record EntryOrderRequest(
            @NotBlank(message = "请选择交易对")
            @Size(max = 32, message = "交易对无效")
            String symbol,

            @NotBlank(message = "请选择做多或做空")
            @Size(max = 8, message = "交易方向无效")
            String direction,

            @DecimalMin(value = "0", inclusive = false, message = "建仓价格必须大于0")
            BigDecimal entryPrice,

            @NotNull(message = "请选择止损价格")
            @DecimalMin(value = "0", inclusive = false, message = "止损价格必须大于0")
            BigDecimal stopPrice
    ) {
    }

    public record ClosePositionRequest(
            @NotBlank(message = "请选择平仓方式")
            @Size(max = 16, message = "平仓方式无效")
            String orderType
    ) {
    }

    public record RiskPolicyRequest(
            boolean enabled,
            boolean takeProfitEnabled,
            boolean stopLossEnabled,

            @NotNull(message = "请输入止盈比例")
            @DecimalMin(value = "0.1", message = "止盈比例不能低于0.1%")
            @DecimalMax(value = "100", message = "止盈比例不能超过100%")
            BigDecimal takeProfitPercent,

            @NotNull(message = "请输入止损比例")
            @DecimalMin(value = "0.1", message = "止损比例不能低于0.1%")
            @DecimalMax(value = "100", message = "止损比例不能超过100%")
            BigDecimal stopLossPercent,

            @NotNull(message = "请输入单笔止损额")
            @DecimalMin(value = "1", message = "单笔止损额不能低于1")
            @DecimalMax(value = "1000000", message = "单笔止损额不能超过1,000,000")
            BigDecimal maxLossAmount
    ) {
    }

    public record ExitStrategyRequest(
            @NotBlank(message = "请输入策略名称")
            @Size(max = 32, message = "策略名称不能超过32个字符")
            String name,

            @NotNull(message = "请配置止盈止损级别")
            @Size(min = 1, max = 5, message = "策略必须包含1到5级")
            List<@Valid ExitStrategyLevelRequest> levels
    ) {
        ExitStrategyCommand toCommand() {
            return new ExitStrategyCommand(
                    name,
                    levels.stream()
                            .map(ExitStrategyLevelRequest::toCommand)
                            .toList()
            );
        }
    }

    public record ExitStrategyLevelRequest(
            @NotNull(message = "请输入盈利触发倍数")
            @DecimalMin(value = "0.1", message = "盈利触发倍数不能低于0.1R")
            @DecimalMax(value = "1000", message = "盈利触发倍数不能超过1000R")
            BigDecimal triggerR,

            @DecimalMin(value = "0", message = "减仓比例不能低于0%")
            @DecimalMax(value = "100", message = "减仓比例不能超过100%")
            BigDecimal reducePercent,

            @Size(max = 32, message = "移动止损方式无效")
            String moveStopMode,

            BigDecimal moveStopR
    ) {
        ExitStrategyLevelCommand toCommand() {
            return new ExitStrategyLevelCommand(
                    triggerR,
                    reducePercent,
                    moveStopMode,
                    moveStopR
            );
        }
    }

    public record LossLimitRequest(
            @NotNull(message = "请选择止损比例")
            @Min(value = 1, message = "止损比例不能低于1%")
            @Max(value = 25, message = "止损比例不能超过25%")
            Integer percentage
    ) {
    }

    public record OrderSettingsRequest(
            @Size(max = 40, message = "默认止盈止损策略无效")
            String defaultExitStrategyId,

            @NotBlank(message = "请选择建仓方式")
            @Size(max = 32, message = "建仓方式无效")
            String entryOrderType,

            @NotBlank(message = "请选择止盈方式")
            @Size(max = 32, message = "止盈方式无效")
            String takeProfitOrderType,

            @NotBlank(message = "请选择止损方式")
            @Size(max = 32, message = "止损方式无效")
            String stopLossOrderType,

            @DecimalMin(
                    value = "1",
                    inclusive = false,
                    message = "保底市价止损必须大于1R"
            )
            BigDecimal fallbackMarketStopR
    ) {
        OrderSettingsCommand toCommand() {
            return new OrderSettingsCommand(
                    defaultExitStrategyId,
                    entryOrderType,
                    takeProfitOrderType,
                    stopLossOrderType,
                    fallbackMarketStopR
            );
        }
    }
}
