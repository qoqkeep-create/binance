package com.oovso.notification;

import com.oovso.notification.ApnsPushGateway.DeliveryResult;
import com.oovso.notification.PushDeviceMapper.RegisteredPushDevice;
import jakarta.annotation.PreDestroy;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Service;

@Service
@ConditionalOnProperty(
        prefix = "notification.apns",
        name = "enabled",
        havingValue = "true"
)
public class ApnsNotificationDeliveryService {

    private static final Logger log = LoggerFactory.getLogger(
            ApnsNotificationDeliveryService.class
    );

    private final ApnsPushGateway gateway;

    private final PushDeviceService deviceService;

    private final ApnsNotificationProperties properties;

    private final ExecutorService executor;

    @Autowired
    public ApnsNotificationDeliveryService(
            ApnsPushGateway gateway,
            PushDeviceService deviceService,
            ApnsNotificationProperties properties
    ) {
        this(
                gateway,
                deviceService,
                properties,
                Executors.newVirtualThreadPerTaskExecutor()
        );
    }

    ApnsNotificationDeliveryService(
            ApnsPushGateway gateway,
            PushDeviceService deviceService,
            ApnsNotificationProperties properties,
            ExecutorService executor
    ) {
        this.gateway = gateway;
        this.deviceService = deviceService;
        this.properties = properties;
        this.executor = executor;
    }

    public void submit(
            List<RegisteredPushDevice> devices,
            ApnsNotification notification,
            String context
    ) {
        if (devices.isEmpty()) {
            return;
        }
        try {
            executor.submit(() -> deliver(devices, notification, context));
        } catch (RejectedExecutionException exception) {
            log.warn("APNs delivery queue rejected {}", context);
        }
    }

    void deliver(
            List<RegisteredPushDevice> devices,
            ApnsNotification notification,
            String context
    ) {
        for (RegisteredPushDevice device : devices) {
            if (Thread.currentThread().isInterrupted()) {
                return;
            }
            deliver(device, notification, context);
        }
    }

    private void deliver(
            RegisteredPushDevice device,
            ApnsNotification notification,
            String context
    ) {
        int maxAttempts = Math.max(1, properties.getMaxAttempts());
        DeliveryResult result = null;
        for (int attempt = 1; attempt <= maxAttempts; attempt++) {
            result = gateway.send(device, notification);
            if (result.delivered()) {
                log.info("Sent {} to APNs device {}", context, device.id());
                return;
            }
            if (result.invalidDevice()) {
                deviceService.invalidate(device.id(), result.reason());
                return;
            }
            if (!result.retryable()
                    || attempt >= maxAttempts
                    || !sleepBeforeRetry()) {
                break;
            }
        }
        if (result != null) {
            log.warn(
                    "Failed {} APNs delivery device={} status={} reason={}",
                    context,
                    device.id(),
                    result.statusCode(),
                    result.reason()
            );
        }
    }

    private boolean sleepBeforeRetry() {
        try {
            Thread.sleep(Math.max(0, properties.getRetryDelayMillis()));
            return true;
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            return false;
        }
    }

    @PreDestroy
    public void shutdown() {
        executor.shutdownNow();
    }
}
