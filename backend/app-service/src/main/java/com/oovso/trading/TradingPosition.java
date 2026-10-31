package com.oovso.trading;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import lombok.Data;

@Data
@TableName("trading_position")
public class TradingPosition {

    @TableId(type = IdType.INPUT)
    private String id;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
    private String tradingAccountId;
    private String symbol;
    private String positionSide;
    private Long generation;
    private BigDecimal quantity;
    private BigDecimal entryPrice;
    private BigDecimal breakEvenPrice;
    private BigDecimal markPrice;
    private BigDecimal liquidationPrice;
    private Integer leverage;
    private String marginType;
    private BigDecimal isolatedMargin;
    private BigDecimal unrealizedProfit;
    private String status;
    private Long exchangeUpdateMs;
    private Long lastEventMs;
    private Long lastReconcileRevision;
    private String continuityStatus;
    private String source;
    private Long version;
}
