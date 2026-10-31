package com.oovso.indicator;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import lombok.Data;

@Data
@TableName("market_indicator")
public class MarketIndicator {

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

    private String indicatorCode;

    private BigDecimal indicatorValue;

    private String direction;

    private String extraJson;
}
