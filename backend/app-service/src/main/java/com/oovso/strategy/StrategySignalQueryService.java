package com.oovso.strategy;

import com.fasterxml.jackson.annotation.JsonFormat;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.UUID;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.util.StringUtils;

@Service
public class StrategySignalQueryService {

    static final int PAGE_SIZE = 10;

    private static final String INITIAL_BEFORE_ID = "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz";

    private final StrategySignalMapper signalMapper;

    public StrategySignalQueryService(StrategySignalMapper signalMapper) {
        this.signalMapper = signalMapper;
    }

    public StrategySignalPage query(String userId, String cursor) {
        SignalCursor decodedCursor = decodeCursor(cursor);
        List<StrategySignalFeedRow> rows = new ArrayList<>(
                signalMapper.selectFeedPage(
                        userId,
                        decodedCursor.signalTimeMs(),
                        decodedCursor.id(),
                        PAGE_SIZE + 1
                )
        );
        boolean hasNext = rows.size() > PAGE_SIZE;
        if (hasNext) {
            rows.removeLast();
        }

        List<StrategySignalItem> items = rows.stream()
                .map(this::item)
                .toList();
        String nextCursor = hasNext && !rows.isEmpty()
                ? encodeCursor(rows.getLast())
                : null;
        return new StrategySignalPage(
                PAGE_SIZE,
                hasNext,
                nextCursor,
                items
        );
    }

    @Transactional
    public void markRead(String userId, String signalId) {
        requireUuid(signalId, "信号 ID 格式无效");
        requireVisibleSignal(userId, signalId);
        try {
            signalMapper.insertReadReceipt(
                    userId,
                    signalId,
                    System.currentTimeMillis()
            );
        } catch (DuplicateKeyException ignored) {
            // Idempotent: another request already marked the same signal read.
        }
    }

    @Transactional
    public ReversalAlertMutation activateReversalAlert(
            String userId,
            String signalId
    ) {
        requireUuid(signalId, "信号 ID 格式无效");
        requireVisibleSignal(userId, signalId);
        long now = System.currentTimeMillis();
        signalMapper.insertUserStateIfMissing(userId, signalId, now);
        if (signalMapper.activateReversalAlert(userId, signalId, now) == 0) {
            throw new StrategySignalApiException(
                    HttpStatus.CONFLICT,
                    "该提醒已被删除，无法设置二次提醒"
            );
        }
        return new ReversalAlertMutation("ACTIVE");
    }

    @Transactional
    public void delete(String userId, String signalId) {
        requireUuid(signalId, "信号 ID 格式无效");
        requireVisibleSignal(userId, signalId);
        long now = System.currentTimeMillis();
        signalMapper.insertUserStateIfMissing(userId, signalId, now);
        if (signalMapper.deleteForUser(userId, signalId, now) == 0) {
            throw new StrategySignalApiException(
                    HttpStatus.NOT_FOUND,
                    "策略信号不存在"
            );
        }
    }

    private StrategySignalItem item(StrategySignalFeedRow row) {
        return new StrategySignalItem(
                row.getId(),
                row.getSymbol(),
                row.getIntervalCode(),
                strategyName(row.getStrategyCode()),
                row.getDirection(),
                row.getTriggerPrice(),
                Instant.ofEpochMilli(row.getSignalTimeMs()),
                Integer.valueOf(1).equals(row.getReadState()),
                normalizedReversalState(row.getReversalAlertState()),
                CandlestickPatternNames.displayName(
                        row.getReversalPatternCode()
                )
        );
    }

    private String strategyName(String code) {
        return switch (code) {
            case "EMA21_55_MACD_GOLDEN_CROSS" -> "EMA21/EMA55金叉";
            case "EMA21_55_MACD_DEATH_CROSS" -> "EMA21/EMA55死叉";
            case "SUPER_EMA144_PULLBACK_REVERSAL" -> "EMA144回踩";
            case "SUPER_EMA55_PULLBACK_REVERSAL" -> "EMA55回踩";
            case "SUPER_TREND_PULLBACK_REVERSAL" -> "SuperTrend回踩";
            default -> code;
        };
    }

    private SignalCursor decodeCursor(String cursor) {
        if (!StringUtils.hasText(cursor)) {
            return new SignalCursor(Long.MAX_VALUE, INITIAL_BEFORE_ID);
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
            long signalTimeMs = Long.parseLong(
                    decoded.substring(0, separator)
            );
            String id = decoded.substring(separator + 1);
            if (signalTimeMs < 0) {
                throw invalidCursor();
            }
            requireUuid(id, "分页游标无效");
            return new SignalCursor(signalTimeMs, id);
        } catch (IllegalArgumentException exception) {
            throw invalidCursor();
        }
    }

    private String encodeCursor(StrategySignalFeedRow row) {
        String value = row.getSignalTimeMs() + ":" + row.getId();
        return Base64.getUrlEncoder()
                .withoutPadding()
                .encodeToString(value.getBytes(StandardCharsets.UTF_8));
    }

    private void requireUuid(String value, String message) {
        try {
            UUID.fromString(value);
        } catch (IllegalArgumentException | NullPointerException exception) {
            throw new StrategySignalApiException(
                    HttpStatus.BAD_REQUEST,
                    message
            );
        }
    }

    private void requireVisibleSignal(String userId, String signalId) {
        if (signalMapper.countVisibleById(userId, signalId) == 0) {
            throw new StrategySignalApiException(
                    HttpStatus.NOT_FOUND,
                    "策略信号不存在"
            );
        }
    }

    private String normalizedReversalState(String state) {
        return switch (state == null ? "NONE" : state) {
            case "ACTIVE", "TRIGGERED" -> state;
            default -> "NONE";
        };
    }

    private StrategySignalApiException invalidCursor() {
        return new StrategySignalApiException(
                HttpStatus.BAD_REQUEST,
                "分页游标无效"
        );
    }

    public record StrategySignalPage(
            int size,
            boolean hasNext,
            String nextCursor,
            List<StrategySignalItem> items
    ) {
    }

    public record StrategySignalItem(
            String id,
            String symbol,
            String interval,
            String strategyName,
            String direction,
            BigDecimal triggerPrice,
            @JsonFormat(shape = JsonFormat.Shape.STRING)
            Instant triggeredAt,
            boolean isRead,
            String reversalAlertState,
            String reversalPatternName
    ) {
    }

    public record ReversalAlertMutation(String state) {
    }

    private record SignalCursor(long signalTimeMs, String id) {
    }
}
