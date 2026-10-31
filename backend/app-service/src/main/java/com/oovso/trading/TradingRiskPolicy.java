package com.oovso.trading;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import lombok.Data;

@Data
@TableName("trading_risk_policy")
public class TradingRiskPolicy {

    @TableId(type = IdType.INPUT)
    private String id;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
    private String tradingAccountId;
    private Long policyRevision;
    private Integer enabledState;
    private Integer takeProfitEnabled;
    private Integer stopLossEnabled;
    private BigDecimal takeProfitPercent;
    private BigDecimal stopLossPercent;
    private BigDecimal maxLossAmount;
    private String settlementAsset;
    private String workingType;
    private Long version;
}
