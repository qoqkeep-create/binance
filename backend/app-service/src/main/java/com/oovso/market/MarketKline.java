package com.oovso.market;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import lombok.Data;

@Data
@TableName("market_kline")
public class MarketKline {

    @TableId(type = IdType.INPUT)
    private String id;

    private LocalDateTime createTime;

    private LocalDateTime updateTime;

    private String createUser;

    private String updateUser;

    private Integer deleteState;

    private String exchange;

    private String marketType;

    private String contractType;

    private String pair;

    private String intervalCode;

    private Long openTimeMs;

    private Long closeTimeMs;

    private Long eventTimeMs;

    private BigDecimal openPrice;

    private BigDecimal highPrice;

    private BigDecimal lowPrice;

    private BigDecimal closePrice;

    private BigDecimal volume;

    private BigDecimal quoteVolume;

    private Long tradeCount;

    private BigDecimal takerBuyVolume;

    private BigDecimal takerBuyQuoteVolume;

    private Integer closedState;

    private String sourceInterval;
}
