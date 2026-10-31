package com.oovso.strategy;

import java.math.BigDecimal;
import lombok.Data;

/** Durable cursor for rearming a four-hour EMA144 pullback after price leaves it. */
@Data
public class FourHourEmaPullbackState {

    private String exchange;

    private String marketType;

    private String contractType;

    private String pair;

    private String direction;

    private String phase;

    private Long lastEventMs;

    private Long lastAlertTimeMs;

    private Long lastBucketOpenMs;

    private Long lastIntrabarBucketOpenMs;

    private BigDecimal lastPrice;

    private Long lastSourceOpenMs;

    private BigDecimal lastSourceHigh;

    private BigDecimal lastSourceLow;
}
