package com.oovso.reference;

import com.oovso.auth.AppUser;
import com.oovso.auth.AppUserMapper;
import com.oovso.notification.ApnsNotification;
import com.oovso.notification.ApnsNotificationDeliveryService;
import com.oovso.notification.PushDeviceService;
import java.util.LinkedHashMap;
import java.util.Map;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

@Component
@ConditionalOnProperty(
        prefix = "notification.apns",
        name = "enabled",
        havingValue = "true"
)
public class ReferenceTradeNotificationApnsListener
        implements ReferenceTradeNotificationListener {

    private static final Logger log = LoggerFactory.getLogger(
            ReferenceTradeNotificationApnsListener.class
    );

    private final ReferenceTradeNotificationAccess access;

    private final AppUserMapper userMapper;

    private final PushDeviceService deviceService;

    private final ApnsNotificationDeliveryService deliveryService;

    public ReferenceTradeNotificationApnsListener(
            ReferenceTradeNotificationAccess access,
            AppUserMapper userMapper,
            PushDeviceService deviceService,
            ApnsNotificationDeliveryService deliveryService
    ) {
        this.access = access;
        this.userMapper = userMapper;
        this.deviceService = deviceService;
        this.deliveryService = deliveryService;
    }

    @Override
    public void onNotification(ReferenceTradeNotification notification) {
        AppUser targetUser = userMapper.selectActiveByEmail(access.targetEmail());
        if (targetUser == null) {
            log.warn(
                    "Reference notification target user is unavailable for event {}",
                    notification.eventId()
            );
            return;
        }
        deliveryService.submit(
                deviceService.activeDevices(targetUser.getId()),
                apnsNotification(notification),
                "reference notification " + notification.eventId()
        );
    }

    public static ApnsNotification apnsNotification(
            ReferenceTradeNotification notification
    ) {
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("id", notification.id());
        data.put("eventId", notification.eventId());
        data.put("type", notification.type().name());
        data.put(
                "occurredAt",
                notification.occurredAt().toEpochMilli() / 1_000.0
        );
        return new ApnsNotification(
                notification.title(),
                notification.type().displayName(),
                "reference.trade.notification",
                "reference.trade.notification",
                data
        );
    }
}
