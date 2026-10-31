package com.oovso.notification;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

public record ApnsNotification(
        String title,
        String body,
        String threadId,
        String route,
        Map<String, Object> data
) {

    public ApnsNotification {
        data = data == null
                ? Map.of()
                : Collections.unmodifiableMap(new LinkedHashMap<>(data));
    }
}
