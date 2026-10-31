package com.oovso.strategy;

import java.math.BigDecimal;
import lombok.Data;

@Data
public class StrategySignalFeedRow {

    private String id;

    private String symbol;

    private String intervalCode;

    private String strategyCode;

    private String direction;

    private BigDecimal triggerPrice;

    private Long signalTimeMs;

    private Integer readState;

    private String reversalAlertState;

    private String reversalPatternCode;
}
