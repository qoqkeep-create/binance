package com.oovso.notification;

import com.oovso.notification.StrategyNotificationPreferenceMapper.PreferenceRow;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class StrategyNotificationPreferenceService {

    private final StrategyNotificationPreferenceMapper mapper;

    public StrategyNotificationPreferenceService(
            StrategyNotificationPreferenceMapper mapper
    ) {
        this.mapper = mapper;
    }

    public StrategyNotificationPreference preferences(String userId) {
        PreferenceRow row = mapper.selectByUser(userId);
        if (row == null) {
            return StrategyNotificationPreference.allEnabled();
        }
        return new StrategyNotificationPreference(
                row.fifteenMinuteEnabled() == 1,
                row.oneHourEnabled() == 1,
                row.fourHourEnabled() == 1
        );
    }

    @Transactional
    public StrategyNotificationPreference update(
            String userId,
            boolean fifteenMinuteEnabled,
            boolean oneHourEnabled,
            boolean fourHourEnabled
    ) {
        mapper.upsert(
                userId,
                flag(fifteenMinuteEnabled),
                flag(oneHourEnabled),
                flag(fourHourEnabled),
                System.currentTimeMillis()
        );
        return new StrategyNotificationPreference(
                fifteenMinuteEnabled,
                oneHourEnabled,
                fourHourEnabled
        );
    }

    private int flag(boolean enabled) {
        return enabled ? 1 : 0;
    }

    public record StrategyNotificationPreference(
            boolean fifteenMinuteEnabled,
            boolean oneHourEnabled,
            boolean fourHourEnabled
    ) {
        public boolean enabledForInterval(String intervalCode) {
            return switch (intervalCode == null ? "" : intervalCode) {
                case "15m" -> fifteenMinuteEnabled;
                case "1h" -> oneHourEnabled;
                case "4h" -> fourHourEnabled;
                default -> false;
            };
        }

        static StrategyNotificationPreference allEnabled() {
            return new StrategyNotificationPreference(true, true, true);
        }
    }
}
