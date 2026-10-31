package com.oovso.trading;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import lombok.Data;

@Data
@TableName("trading_exit_strategy_level")
public class TradingExitStrategyLevel {

    @TableId(type = IdType.INPUT)
    private String id;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
    private String exitStrategyId;
    private Integer levelNo;
    private BigDecimal triggerR;
    private BigDecimal reducePercent;
    private String moveStopMode;
    private BigDecimal moveStopR;
}
