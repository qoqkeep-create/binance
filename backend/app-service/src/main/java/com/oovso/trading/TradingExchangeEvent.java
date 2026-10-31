package com.oovso.trading;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.time.LocalDateTime;
import lombok.Data;

@Data
@TableName("trading_exchange_event")
public class TradingExchangeEvent {

    @TableId(type = IdType.INPUT)
    private String id;
    private LocalDateTime createTime;
    private String tradingAccountId;
    private String eventType;
    private String eventHash;
    private Long exchangeEventMs;
    private Long transactionMs;
    private Long receivedAtMs;
    private String entityKey;
    private String normalizedSummary;
    private String appliedState;
}
