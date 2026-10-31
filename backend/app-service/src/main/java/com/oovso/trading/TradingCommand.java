package com.oovso.trading;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.time.LocalDateTime;
import lombok.Data;

@Data
@TableName("trading_command")
public class TradingCommand {

    @TableId(type = IdType.INPUT)
    private String id;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
    private String tradingAccountId;
    private String appUserId;
    private String idempotencyKey;
    private String requestHash;
    private String requestJson;
    private String commandType;
    private String status;
    private String clientOrderId;
    private String clientAlgoId;
    private String resultJson;
    private String errorCode;
    private Long dispatchedAtMs;
    private Long completedAtMs;
    private Long version;
}
