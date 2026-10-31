package com.oovso.trading;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.time.LocalDateTime;
import lombok.Data;

@Data
@TableName("trading_outbox")
public class TradingOutbox {

    @TableId(type = IdType.INPUT)
    private String id;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
    private String tradingAccountId;
    private String appUserId;
    private String channel;
    private String eventName;
    private String eventKey;
    private String symbol;
    private String payloadJson;
    private String status;
    private Integer attempts;
    private Long availableAtMs;
    private Long lockedAtMs;
    private Long publishedAtMs;
}
