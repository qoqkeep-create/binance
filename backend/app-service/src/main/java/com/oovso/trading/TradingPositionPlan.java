package com.oovso.trading;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import lombok.Data;

@Data
@TableName("trading_position_plan")
public class TradingPositionPlan {

    @TableId(type = IdType.INPUT)
    private String id;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
    private String tradingAccountId;
    private String tradingCommandId;
    private String tradingPositionId;
    private Long positionGeneration;
    private String symbol;
    private String direction;
    private String positionSide;
    private String entrySide;
    private String status;
    private String entryOrderType;
    private String takeProfitOrderType;
    private String stopLossOrderType;
    private String workingType;
    private Long orderSettingsRevision;
    private String exitStrategyId;
    private Long exitStrategyRevision;
    private String executionSnapshotJson;
    private String executionSnapshotHash;
    private String settlementAsset;
    private BigDecimal configuredRAmount;
    private BigDecimal actualInitialRAmount;
    private BigDecimal referenceEntryPrice;
    private BigDecimal requestedEntryPrice;
    private BigDecimal averageEntryPrice;
    private BigDecimal initialStopPrice;
    private BigDecimal currentStopPrice;
    private BigDecimal riskPerUnit;
    private BigDecimal plannedQuantity;
    private BigDecimal initialFilledQuantity;
    private BigDecimal filledQuantity;
    private BigDecimal protectedQuantity;
    private BigDecimal remainingQuantity;
    private BigDecimal priceTick;
    private BigDecimal quantityStep;
    private BigDecimal marketQuantityStep;
    private BigDecimal minQuantity;
    private BigDecimal minNotional;
    private BigDecimal fallbackMarketStopR;
    private String entryClientOrderId;
    private String primaryStopClientAlgoId;
    private String fallbackStopClientAlgoId;
    private Long stopRevision;
    private Long lastStrategyEvaluatedMs;
    private Long lastOrderHealthCheckMs;
    private Long nextProtectionRepairAtMs;
    private Integer protectionRepairAttempts;
    private Long executionFenceToken;
    private String lastErrorCode;
    private Long version;
}
