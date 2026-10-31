package com.oovso.notification;

import com.oovso.notification.PushDeviceMapper.RegisteredPushDevice;

public interface ApnsPushGateway {

    DeliveryResult send(
            RegisteredPushDevice device,
            ApnsNotification notification
    );

    record DeliveryResult(
            boolean delivered,
            boolean retryable,
            boolean invalidDevice,
            int statusCode,
            String reason
    ) {

        static DeliveryResult success() {
            return new DeliveryResult(true, false, false, 200, "Success");
        }

        static DeliveryResult rejected(
                int statusCode,
                String reason
        ) {
            boolean invalid = statusCode == 410
                    || reason.equals("BadDeviceToken")
                    || reason.equals("DeviceTokenNotForTopic")
                    || reason.equals("Unregistered");
            boolean retryable = statusCode == 429
                    || statusCode == 500
                    || statusCode == 503;
            return new DeliveryResult(
                    false,
                    retryable,
                    invalid,
                    statusCode,
                    reason
            );
        }

        static DeliveryResult transportFailure(String reason) {
            return new DeliveryResult(false, true, false, 0, reason);
        }
    }
}
