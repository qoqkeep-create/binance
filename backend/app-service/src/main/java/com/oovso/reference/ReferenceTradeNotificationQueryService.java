package com.oovso.reference;

import com.fasterxml.jackson.annotation.JsonFormat;
import com.oovso.auth.AppUser;
import com.oovso.auth.AppUserMapper;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.UUID;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.util.StringUtils;

@Service
public class ReferenceTradeNotificationQueryService {

    static final int PAGE_SIZE = 20;

    private static final String INITIAL_BEFORE_ID =
            "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz";

    private final AppUserMapper userMapper;

    private final ReferenceTradeNotificationAccess access;

    private final ReferenceTradeNotificationMapper notificationMapper;

    public ReferenceTradeNotificationQueryService(
            AppUserMapper userMapper,
            ReferenceTradeNotificationAccess access,
            ReferenceTradeNotificationMapper notificationMapper
    ) {
        this.userMapper = userMapper;
        this.access = access;
        this.notificationMapper = notificationMapper;
    }

    public ReferenceTradeNotificationPage query(String userId, String cursor) {
        requireAuthorizedUser(userId);
        NotificationCursor decodedCursor = decodeCursor(cursor);
        List<ReferenceTradeNotificationRow> rows = new ArrayList<>(
                notificationMapper.selectPage(
                        decodedCursor.receivedTimeMs(),
                        decodedCursor.id(),
                        PAGE_SIZE + 1
                )
        );
        boolean hasNext = rows.size() > PAGE_SIZE;
        if (hasNext) {
            rows.removeLast();
        }
        String nextCursor = hasNext && !rows.isEmpty()
                ? encodeCursor(rows.getLast())
                : null;
        return new ReferenceTradeNotificationPage(
                PAGE_SIZE,
                hasNext,
                nextCursor,
                rows.stream().map(this::item).toList()
        );
    }

    private void requireAuthorizedUser(String userId) {
        AppUser user = userMapper.selectActiveById(userId);
        if (!access.canView(user)) {
            throw new ReferenceTradeNotificationApiException(
                    HttpStatus.FORBIDDEN,
                    "当前账号不能查看参考通知"
            );
        }
    }

    private ReferenceTradeNotificationItem item(
            ReferenceTradeNotificationRow row
    ) {
        return new ReferenceTradeNotificationItem(
                row.getId(),
                row.getEventId(),
                row.getSchemaVersion(),
                ReferenceTradeNotificationType.valueOf(
                        row.getNotificationType()
                ),
                row.getTitle(),
                row.getContent(),
                Instant.ofEpochMilli(row.getOccurredTimeMs()),
                Instant.ofEpochMilli(row.getReceivedTimeMs())
        );
    }

    private NotificationCursor decodeCursor(String cursor) {
        if (!StringUtils.hasText(cursor)) {
            return new NotificationCursor(Long.MAX_VALUE, INITIAL_BEFORE_ID);
        }
        if (cursor.length() > 160) {
            throw invalidCursor();
        }
        try {
            String decoded = new String(
                    Base64.getUrlDecoder().decode(cursor),
                    StandardCharsets.UTF_8
            );
            int separator = decoded.indexOf(':');
            if (separator <= 0 || separator == decoded.length() - 1) {
                throw invalidCursor();
            }
            long receivedTimeMs = Long.parseLong(
                    decoded.substring(0, separator)
            );
            String id = decoded.substring(separator + 1);
            if (receivedTimeMs < 0) {
                throw invalidCursor();
            }
            UUID.fromString(id);
            return new NotificationCursor(receivedTimeMs, id);
        } catch (IllegalArgumentException exception) {
            throw invalidCursor();
        }
    }

    private String encodeCursor(ReferenceTradeNotificationRow row) {
        String value = row.getReceivedTimeMs() + ":" + row.getId();
        return Base64.getUrlEncoder()
                .withoutPadding()
                .encodeToString(value.getBytes(StandardCharsets.UTF_8));
    }

    private ReferenceTradeNotificationApiException invalidCursor() {
        return new ReferenceTradeNotificationApiException(
                HttpStatus.BAD_REQUEST,
                "分页游标无效"
        );
    }

    public record ReferenceTradeNotificationPage(
            int size,
            boolean hasNext,
            String nextCursor,
            List<ReferenceTradeNotificationItem> items
    ) {
    }

    public record ReferenceTradeNotificationItem(
            String id,
            String eventId,
            int schemaVersion,
            ReferenceTradeNotificationType type,
            String title,
            String content,
            @JsonFormat(shape = JsonFormat.Shape.STRING)
            Instant occurredAt,
            @JsonFormat(shape = JsonFormat.Shape.STRING)
            Instant receivedAt
    ) {
    }

    private record NotificationCursor(long receivedTimeMs, String id) {
    }
}
