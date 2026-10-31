package com.oovso.trading;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import lombok.Data;

@Data
@TableName("trading_position_plan_level")
public class TradingPositionPlanLevel {

    @TableId(type = IdType.INPUT)
    private String id;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
    private String tradingPositionPlanId;
    private String sourceLevelId;
    private Integer levelNo;
    private BigDecimal triggerR;
    private BigDecimal reducePercent;
    private String moveStopMode;
    private BigDecimal moveStopR;
    private String status;
    private String reductionStatus;
    private String reductionClientOrderId;
    private Long reductionRevision;
    private BigDecimal plannedReductionQuantity;
    private BigDecimal executedReductionQuantity;
    private BigDecimal reductionOrderBaseExecutedQuantity;
    private Long reductionNextRetryAtMs;
    private Integer reductionRepairAttempts;
    private BigDecimal triggeredPrice;
    private Long triggeredAtMs;
    private Integer stopMoveActivated;
    private String lastErrorCode;
    private Long version;
}
