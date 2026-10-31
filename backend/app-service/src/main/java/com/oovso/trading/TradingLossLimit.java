package com.oovso.trading;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import lombok.Data;

@Data
@TableName("trading_loss_limit")
public class TradingLossLimit {

    @TableId(type = IdType.INPUT)
    private String id;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
    private String tradingAccountId;
    private Long revision;
    private Integer currentPercentage;
    private BigDecimal currentAmount;
    private Integer pendingPercentage;
    private BigDecimal pendingAmount;
    private Long pendingEffectiveAtMs;
    private BigDecimal balanceSnapshot;
    private String settlementAsset;
    private Long version;
}
