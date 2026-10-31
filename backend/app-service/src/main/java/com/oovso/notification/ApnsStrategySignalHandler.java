package com.oovso.notification;

import com.oovso.strategy.ReversalAlert;
import com.oovso.strategy.ReversalAlertHandler;
import com.oovso.strategy.StrategySignal;
import com.oovso.strategy.StrategySignalHandler;
import java.math.BigDecimal;
import java.util.LinkedHashMap;
import java.util.Map;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

@Component
@ConditionalOnProperty(
        prefix = "notification.apns",
        name = "enabled",
        havingValue = "true"
)
public class ApnsStrategySignalHandler
        implements StrategySignalHandler, ReversalAlertHandler {

    private final PushDeviceService deviceService;

    private final ApnsNotificationDeliveryService deliveryService;

    public ApnsStrategySignalHandler(
            PushDeviceService deviceService,
            ApnsNotificationDeliveryService deliveryService
    ) {
        this.deviceService = deviceService;
        this.deliveryService = deliveryService;
    }

    @Override
    public void onSignal(StrategySignal signal) {
        deliveryService.submit(
                deviceService.activeDevicesForStrategyInterval(
                        signal.getIntervalCode()
                ),
                notification(signal),
                "strategy signal " + signal.getId()
        );
    }

    @Override
    public void onReversalAlert(ReversalAlert alert) {
        StrategySignal signal = alert.notificationSignal();
        deliveryService.submit(
                deviceService.activeDevicesForStrategyInterval(
                        alert.userId(),
                        signal.getIntervalCode()
                ),
                notification(signal),
                "strategy reversal " + signal.getId()
        );
    }

    static ApnsNotification notification(StrategySignal signal) {
        boolean secondaryAlert = isSecondaryAlert(signal);
        String strategyName = strategyName(signal);
        String displayStrategyName = !secondaryAlert
                && "4h".equals(signal.getIntervalCode())
                ? "4小时 " + strategyName
                : strategyName;
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("id", signal.getId());
        data.put("symbol", signal.getPair());
        data.put("interval", signal.getIntervalCode());
        data.put("strategyName", strategyName);
        data.put("direction", signal.getDirection());
        data.put("triggerPrice", signal.getPrice());
        data.put(
                "triggeredAt",
                signal.getSignalTimeMs() == null
                        ? 0
                        : signal.getSignalTimeMs() / 1_000.0
        );
        return new ApnsNotification(
                signal.getPair()
                        + " "
                        + direction(signal)
                        + (secondaryAlert ? "二次提醒" : "信号"),
                displayStrategyName
                        + " · "
                        + (secondaryAlert ? "收盘价 " : "触发价 ")
                        + price(signal.getPrice()),
                secondaryAlert ? "strategy.reversal" : "strategy.signal",
                "strategy.signal",
                data
        );
    }

    private static String direction(StrategySignal signal) {
        return "SHORT".equals(signal.getDirection()) ? "做空" : "做多";
    }

    private static String strategyName(StrategySignal signal) {
        if (isSecondaryAlert(signal)
                && signal.getNotificationName() != null
                && !signal.getNotificationName().isBlank()) {
            return signal.getNotificationName();
        }
        return switch (signal.getStrategyCode()) {
            case "EMA21_55_MACD_GOLDEN_CROSS" -> "EMA21/EMA55金叉";
            case "EMA21_55_MACD_DEATH_CROSS" -> "EMA21/EMA55死叉";
            case "SUPER_EMA144_PULLBACK_REVERSAL" -> "EMA144回踩";
            default -> signal.getStrategyCode();
        };
    }

    private static boolean isSecondaryAlert(StrategySignal signal) {
        return "CANDLESTICK_REVERSAL_ALERT".equals(signal.getStrategyCode())
                || "SECONDARY_REVERSAL_ALERT".equals(
                        signal.getStrategyCode()
                );
    }

    private static String price(BigDecimal value) {
        return value == null ? "--" : value.stripTrailingZeros().toPlainString();
    }
}
