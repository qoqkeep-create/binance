package com.oovso.trading;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import lombok.Data;

@Data
@TableName("exchange_order")
public class ExchangeOrder {

    @TableId(type = IdType.INPUT)
    private String id;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
    private String tradingAccountId;
    private String tradingPositionId;
    private Long positionGeneration;
    private String orderClass;
    private String origin;
    private String purpose;
    private String symbol;
    private String side;
    private String positionSide;
    private String orderType;
    private String timeInForce;
    private String workingType;
    private String clientOrderId;
    private String exchangeOrderId;
    private String clientAlgoId;
    private String exchangeAlgoId;
    private String actualOrderId;
    private BigDecimal quantity;
    private BigDecimal price;
    private BigDecimal triggerPrice;
    private BigDecimal executedQuantity;
    private BigDecimal cumulativeQuote;
    private BigDecimal averagePrice;
    private Integer reduceOnly;
    private Integer closePosition;
    private String status;
    private String exchangeStatus;
    private String executionType;
    private String rejectReason;
    private Long exchangeCreateMs;
    private Long exchangeUpdateMs;
    private Long lastEventMs;
    private Long lastReconcileRevision;
    private Long version;
}
