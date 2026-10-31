package com.oovso.notification;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.oovso.notification.PushDeviceMapper.RegisteredPushDevice;
import com.oovso.strategy.ReversalAlert;
import com.oovso.strategy.StrategySignal;
import java.math.BigDecimal;
import java.util.List;
import org.junit.jupiter.api.Test;

class ApnsStrategySignalHandlerTest {

    private final PushDeviceService deviceService = mock(
            PushDeviceService.class
    );
    private final ApnsNotificationDeliveryService deliveryService = mock(
            ApnsNotificationDeliveryService.class
    );
    private final ApnsStrategySignalHandler handler =
            new ApnsStrategySignalHandler(deviceService, deliveryService);

    @Test
    void primarySignalUsesItsSourceIntervalPreference() {
        StrategySignal signal = signal("signal-1", "15m");
        List<RegisteredPushDevice> devices = List.of(device("device-1"));
        when(deviceService.activeDevicesForStrategyInterval("15m"))
                .thenReturn(devices);

        handler.onSignal(signal);

        verify(deliveryService).submit(
                eq(devices),
                any(ApnsNotification.class),
                eq("strategy signal signal-1")
        );
    }

    @Test
    void secondaryAlertUsesUserAndOriginalSignalIntervalPreference() {
        ReversalAlert alert = new ReversalAlert(
                "user-1",
                "signal-2",
                "BTCUSDC",
                "PERPETUAL",
                "4h",
                "LONG",
                1_000,
                900,
                new BigDecimal("64000"),
                "MACD_MOMENTUM_DECAY",
                "MACD能量衰减",
                BigDecimal.ONE
        );
        List<RegisteredPushDevice> devices = List.of(device("device-2"));
        when(deviceService.activeDevicesForStrategyInterval("user-1", "4h"))
                .thenReturn(devices);

        handler.onReversalAlert(alert);

        verify(deliveryService).submit(
                eq(devices),
                any(ApnsNotification.class),
                eq("strategy reversal signal-2")
        );
    }

    private StrategySignal signal(String id, String interval) {
        StrategySignal signal = new StrategySignal();
        signal.setId(id);
        signal.setPair("BTCUSDC");
        signal.setIntervalCode(interval);
        signal.setStrategyCode("SUPER_EMA144_PULLBACK_REVERSAL");
        signal.setDirection("LONG");
        signal.setPrice(new BigDecimal("64000"));
        signal.setSignalTimeMs(1_000L);
        return signal;
    }

    private RegisteredPushDevice device(String id) {
        return new RegisteredPushDevice(id, "a".repeat(64), "SANDBOX");
    }
}
