package com.oovso.reference;

import java.util.Arrays;
import java.util.Optional;

public enum ReferenceTradeNotificationType {
    OPEN("开仓"),
    STOP_LOSS("止损"),
    STRATEGY_TAKE_PROFIT("策略止盈"),
    MANUAL_TAKE_PROFIT("手动止盈"),
    REDUCTION("减仓");

    private final String displayName;

    ReferenceTradeNotificationType(String displayName) {
        this.displayName = displayName;
    }

    public String displayName() {
        return displayName;
    }

    public static Optional<ReferenceTradeNotificationType> fromWireValue(
            String value
    ) {
        return Arrays.stream(values())
                .filter(type -> type.name().equals(value))
                .findFirst();
    }
}
