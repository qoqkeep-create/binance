package com.oovso.trading;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import lombok.Data;

@Data
@TableName("exchange_fill")
public class ExchangeFill {

    @TableId(type = IdType.INPUT)
    private String id;
    private LocalDateTime createTime;
    private String tradingAccountId;
    private String exchangeOrderRowId;
    private String symbol;
    private String tradeId;
    private String orderId;
    private String side;
    private String positionSide;
    private BigDecimal price;
    private BigDecimal quantity;
    private BigDecimal quoteQuantity;
    private BigDecimal commission;
    private String commissionAsset;
    private BigDecimal realizedPnl;
    private Integer maker;
    private Long tradeTimeMs;
}
