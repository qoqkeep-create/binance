package com.oovso.trading;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import lombok.Data;

@Data
@TableName("trading_order_settings")
public class TradingOrderSettings {

    @TableId(type = IdType.INPUT)
    private String id;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
    private String tradingAccountId;
    private Long revision;
    private String defaultExitStrategyId;
    private String entryOrderType;
    private String takeProfitOrderType;
    private String stopLossOrderType;
    private BigDecimal fallbackMarketStopR;
    private Long version;
}
