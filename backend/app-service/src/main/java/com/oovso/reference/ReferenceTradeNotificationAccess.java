package com.oovso.reference;

import com.oovso.auth.AppUser;
import java.util.Locale;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;

@Component
public class ReferenceTradeNotificationAccess {

    private final ReferenceTradeNotificationProperties properties;

    public ReferenceTradeNotificationAccess(
            ReferenceTradeNotificationProperties properties
    ) {
        this.properties = properties;
    }

    public boolean canView(AppUser user) {
        return user != null
                && StringUtils.hasText(user.getEmail())
                && normalizedTargetEmail().equals(
                        user.getEmail().trim().toLowerCase(Locale.ROOT)
                );
    }

    public String targetEmail() {
        return normalizedTargetEmail();
    }

    private String normalizedTargetEmail() {
        return StringUtils.hasText(properties.getTargetEmail())
                ? properties.getTargetEmail().trim().toLowerCase(Locale.ROOT)
                : "";
    }
}
