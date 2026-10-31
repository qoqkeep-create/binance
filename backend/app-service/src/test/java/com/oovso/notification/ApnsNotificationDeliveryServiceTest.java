package com.oovso.notification;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.oovso.notification.ApnsPushGateway.DeliveryResult;
import com.oovso.notification.PushDeviceMapper.RegisteredPushDevice;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;

class ApnsNotificationDeliveryServiceTest {

    @Test
    void createsDeliveryServiceWhenApnsIsEnabled() {
        new ApplicationContextRunner()
                .withPropertyValues("notification.apns.enabled=true")
                .withBean(ApnsPushGateway.class, () -> mock(
                        ApnsPushGateway.class
                ))
                .withBean(PushDeviceService.class, () -> mock(
                        PushDeviceService.class
                ))
                .withBean(
                        ApnsNotificationProperties.class,
                        ApnsNotificationProperties::new
                )
                .withUserConfiguration(ApnsNotificationDeliveryService.class)
                .run(context -> assertThat(context)
                        .hasSingleBean(ApnsNotificationDeliveryService.class));
    }

    @Test
    void retriesTransientFailureAndStopsAfterSuccess() {
        ApnsPushGateway gateway = mock(ApnsPushGateway.class);
        PushDeviceService deviceService = mock(PushDeviceService.class);
        ApnsNotificationProperties properties = properties();
        ExecutorService executor = mock(ExecutorService.class);
        ApnsNotificationDeliveryService service =
                new ApnsNotificationDeliveryService(
                        gateway,
                        deviceService,
                        properties,
                        executor
                );
        RegisteredPushDevice device = device();
        ApnsNotification notification = notification();
        when(gateway.send(device, notification))
                .thenReturn(DeliveryResult.transportFailure("timeout"))
                .thenReturn(DeliveryResult.success());

        service.deliver(List.of(device), notification, "test notification");

        verify(gateway, times(2)).send(device, notification);
        verify(deviceService, never()).invalidate(
                org.mockito.ArgumentMatchers.anyString(),
                org.mockito.ArgumentMatchers.anyString()
        );
    }

    @Test
    void invalidatesRejectedDeviceWithoutRetrying() {
        ApnsPushGateway gateway = mock(ApnsPushGateway.class);
        PushDeviceService deviceService = mock(PushDeviceService.class);
        ApnsNotificationDeliveryService service =
                new ApnsNotificationDeliveryService(
                        gateway,
                        deviceService,
                        properties(),
                        mock(ExecutorService.class)
                );
        RegisteredPushDevice device = device();
        ApnsNotification notification = notification();
        when(gateway.send(device, notification)).thenReturn(
                DeliveryResult.rejected(410, "Unregistered")
        );

        service.deliver(List.of(device), notification, "test notification");

        verify(gateway).send(device, notification);
        verify(deviceService).invalidate(device.id(), "Unregistered");
    }

    private ApnsNotificationProperties properties() {
        ApnsNotificationProperties properties = new ApnsNotificationProperties();
        properties.setMaxAttempts(3);
        properties.setRetryDelayMillis(0);
        return properties;
    }

    private RegisteredPushDevice device() {
        return new RegisteredPushDevice("device-id", "a".repeat(64), "SANDBOX");
    }

    private ApnsNotification notification() {
        return new ApnsNotification(
                "title",
                "body",
                "thread",
                "route",
                Map.of("id", "notification-id")
        );
    }
}
