package com.oovso.notification;

import com.oovso.notification.PushDeviceMapper.RegisteredPushDevice;
import java.time.Clock;
import java.util.List;
import java.util.Locale;
import java.util.UUID;
import java.util.regex.Pattern;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.util.StringUtils;

@Service
public class PushDeviceService {

    private static final Pattern DEVICE_TOKEN = Pattern.compile(
            "^[0-9a-f]{64,256}$"
    );

    private final PushDeviceMapper mapper;

    private final ApnsNotificationProperties properties;

    private final Clock clock;

    @Autowired
    public PushDeviceService(
            PushDeviceMapper mapper,
            ApnsNotificationProperties properties
    ) {
        this(mapper, properties, Clock.systemUTC());
    }

    PushDeviceService(
            PushDeviceMapper mapper,
            ApnsNotificationProperties properties,
            Clock clock
    ) {
        this.mapper = mapper;
        this.properties = properties;
        this.clock = clock;
    }

    @Transactional
    public void register(
            String userId,
            String installationId,
            String deviceToken,
            String environment,
            String bundleIdentifier
    ) {
        String normalizedInstallation = UUID.fromString(
                installationId.trim()
        ).toString();
        String normalizedToken = deviceToken.trim()
                .toLowerCase(Locale.ROOT);
        if (!DEVICE_TOKEN.matcher(normalizedToken).matches()) {
            throw new IllegalArgumentException("APNs device token 格式无效");
        }
        String normalizedEnvironment = normalizeEnvironment(environment);
        String normalizedBundleIdentifier = requireMatchingBundleIdentifier(
                bundleIdentifier
        );
        long now = clock.millis();
        mapper.disableOtherInstallationTokens(
                normalizedInstallation,
                normalizedToken,
                normalizedEnvironment,
                now
        );
        mapper.upsert(
                UUID.randomUUID().toString(),
                userId,
                normalizedInstallation,
                normalizedToken,
                normalizedEnvironment,
                normalizedBundleIdentifier,
                now
        );
    }

    public void unregister(
            String userId,
            String installationId
    ) {
        mapper.disableOwnedInstallation(
                userId,
                UUID.fromString(installationId.trim()).toString(),
                clock.millis()
        );
    }

    public List<RegisteredPushDevice> activeDevices() {
        return mapper.selectActive();
    }

    public List<RegisteredPushDevice> activeDevices(String userId) {
        return mapper.selectActiveByUser(userId);
    }

    public List<RegisteredPushDevice> activeDevicesForStrategyInterval(
            String intervalCode
    ) {
        return mapper.selectActiveForStrategyInterval(intervalCode);
    }

    public List<RegisteredPushDevice> activeDevicesForStrategyInterval(
            String userId,
            String intervalCode
    ) {
        return mapper.selectActiveByUserForStrategyInterval(
                userId,
                intervalCode
        );
    }

    public void invalidate(String id, String reason) {
        String normalizedReason = StringUtils.hasText(reason)
                ? reason.trim()
                : "Unknown";
        if (normalizedReason.length() > 64) {
            normalizedReason = normalizedReason.substring(0, 64);
        }
        mapper.disableById(id, normalizedReason, clock.millis());
    }

    private String requireMatchingBundleIdentifier(String bundleIdentifier) {
        String normalized = bundleIdentifier == null
                ? ""
                : bundleIdentifier.trim();
        String expected = properties.getTopic() == null
                ? ""
                : properties.getTopic().trim();
        if (!StringUtils.hasText(expected)) {
            throw new IllegalStateException("服务器 APNs Topic 未配置");
        }
        if (!normalized.equals(expected)) {
            throw new IllegalArgumentException(
                    "当前 App 与服务器推送配置不一致，请更新 App"
            );
        }
        return normalized;
    }

    static String normalizeEnvironment(String environment) {
        String normalized = environment == null
                ? ""
                : environment.trim().toUpperCase(Locale.ROOT);
        if (!normalized.equals("SANDBOX")
                && !normalized.equals("PRODUCTION")) {
            throw new IllegalArgumentException("APNs environment 格式无效");
        }
        return normalized;
    }
}
