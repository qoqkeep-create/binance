package com.oovso.strategy;

import lombok.Data;

@Data
public class StrategySignalReversalWatch {

    private String userId;

    private String signalId;

    private String exchange;

    private String marketType;

    private String contractType;

    private String symbol;

    private String sourceIntervalCode;

    private String direction;

    private Long requestedTimeMs;
}
