package com.oovso.trading;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import lombok.Data;

@Data
@TableName("trading_account_balance")
public class TradingAccountBalance {

    @TableId(type = IdType.INPUT)
    private String id;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
    private String tradingAccountId;
    private String asset;
    private BigDecimal walletBalance;
    private BigDecimal crossWalletBalance;
    private BigDecimal balanceChange;
    private Long lastEventMs;
    private Long lastReconcileRevision;
    private Long version;
}
