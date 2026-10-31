package com.oovso.strategy;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableField;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import lombok.Data;

@Data
@TableName("strategy_signal")
public class StrategySignal {

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

    private String strategyCode;

    private String direction;

    private Long signalTimeMs;

    private Long triggerOpenTimeMs;

    private Long flipOpenTimeMs;

    private Long touchEventTimeMs = 0L;

    private BigDecimal price;

    private BigDecimal score;

    private String patternCode;

    private String reasonJson;

    @TableField(exist = false)
    private String notificationName;
}
