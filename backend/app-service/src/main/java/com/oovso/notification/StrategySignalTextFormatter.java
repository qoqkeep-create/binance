package com.oovso.notification;

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.oovso.strategy.StrategySignal;
import java.math.BigDecimal;
import java.time.Instant;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.List;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;

@Component
public class StrategySignalTextFormatter {

    private static final DateTimeFormatter TIME_FORMATTER =
            DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");

    public String format(StrategySignal signal, String configuredZoneId) {
        return format(signal, configuredZoneId, signal.getPair());
    }

    String format(StrategySignal signal, String configuredZoneId, String displayPair) {
        ZoneId zoneId = zoneId(configuredZoneId);
        SignalDetails details = details(signal.getReasonJson());
        String target = pullbackTarget(signal.getStrategyCode(), details.target());
        String targetValue = targetValue(target, details);
        List<String> lines = new ArrayList<>();
        lines.add("策略信号提醒");
        lines.add("交易对: " + value(displayPair));
        lines.add("方向: " + direction(signal.getDirection()) + " (" + value(signal.getDirection()) + ")");
        lines.add("周期: " + value(signal.getIntervalCode()));
        Long touchTime = signal.getTouchEventTimeMs();
        boolean intrabarTouch = touchTime != null && touchTime > 0;
        lines.add("触发时间: " + time(intrabarTouch ? touchTime : signal.getTriggerOpenTimeMs(), zoneId));
        lines.add("触发价格: " + decimal(signal.getPrice()));
        lines.add("回踩目标: " + target + " @ " + targetValue);
        lines.add("反转形态: " + pattern(signal.getPatternCode())
                + " (" + value(signal.getPatternCode()) + ")");
        lines.add("信号评分: " + decimal(signal.getScore()));
        lines.add("EMA55: " + details.ema55());
        lines.add("EMA144: " + details.ema144());
        lines.add("SuperTrend: " + details.superTrend());
        Long flipTime = signal.getFlipOpenTimeMs();
        lines.add("SuperTrend 翻转时间: " + time(flipTime != null && flipTime > 0 ? flipTime : null, zoneId));
        lines.add("首次回踩/回抽时间: " + time(intrabarTouch ? touchTime : details.firstTouchOpenTimeMs(), zoneId));
        lines.add("策略编码: " + value(signal.getStrategyCode()));
        if (!details.reasons().isEmpty()) {
            lines.add("触发原因:");
            details.reasons().forEach(reason -> lines.add("- " + reason));
        }
        return String.join("\n", lines);
    }

    private SignalDetails details(String reasonJson) {
        if (!StringUtils.hasText(reasonJson)) {
            return SignalDetails.empty();
        }
        try {
            JsonObject root = JsonParser.parseString(reasonJson).getAsJsonObject();
            List<String> reasons = new ArrayList<>();
            JsonArray reasonArray = root.getAsJsonArray("reasons");
            if (reasonArray != null) {
                for (JsonElement reason : reasonArray) {
                    if (reason != null && !reason.isJsonNull()) {
                        reasons.add(reason.getAsString());
                    }
                }
            }
            return new SignalDetails(
                    string(root, "pullbackTarget"),
                    string(root, "pullbackTargetValue"),
                    string(root, "ema55"),
                    string(root, "ema144"),
                    string(root, "superTrend"),
                    longValue(root, "firstTouchOpenTimeMs"),
                    reasons
            );
        } catch (Exception ignored) {
            return SignalDetails.empty();
        }
    }

    private String string(JsonObject object, String key) {
        JsonElement element = object.get(key);
        return element == null || element.isJsonNull() ? "-" : element.getAsString();
    }

    private Long longValue(JsonObject object, String key) {
        JsonElement element = object.get(key);
        return element == null || element.isJsonNull() ? null : element.getAsLong();
    }

    private String pullbackTarget(String strategyCode, String configuredTarget) {
        if (!"-".equals(configuredTarget)) {
            return configuredTarget;
        }
        return switch (value(strategyCode)) {
            case "SUPER_EMA55_PULLBACK_REVERSAL" -> "EMA55";
            case "SUPER_TREND_PULLBACK_REVERSAL" -> "SuperTrend";
            default -> "EMA144";
        };
    }

    private String targetValue(String target, SignalDetails details) {
        if (!"-".equals(details.targetValue())) {
            return details.targetValue();
        }
        return switch (target) {
            case "EMA55" -> details.ema55();
            case "SuperTrend" -> details.superTrend();
            default -> details.ema144();
        };
    }

    private ZoneId zoneId(String configured) {
        try {
            return ZoneId.of(StringUtils.hasText(configured) ? configured : "Asia/Shanghai");
        } catch (Exception ignored) {
            return ZoneId.of("Asia/Shanghai");
        }
    }

    private String time(Long timestamp, ZoneId zoneId) {
        return timestamp == null
                ? "-"
                : TIME_FORMATTER.withZone(zoneId).format(Instant.ofEpochMilli(timestamp));
    }

    private String decimal(BigDecimal number) {
        return number == null ? "-" : number.stripTrailingZeros().toPlainString();
    }

    private String direction(String value) {
        return "LONG".equalsIgnoreCase(value)
                ? "做多"
                : "SHORT".equalsIgnoreCase(value) ? "做空" : value(value);
    }

    private String pattern(String code) {
        return switch (value(code)) {
            case "DOJI_BULLISH_REVERSAL", "DOJI_BEARISH_REVERSAL" -> "十字星";
            case "DRAGONFLY_DOJI" -> "蜻蜓线";
            case "GRAVESTONE_DOJI" -> "墓碑石";
            case "HAMMER" -> "锤形线";
            case "HANGING_MAN" -> "上吊线";
            case "INVERTED_HAMMER" -> "倒锤形线";
            case "SHOOTING_STAR" -> "射击之星";
            case "BULLISH_ENGULFING" -> "看涨吞没";
            case "BEARISH_ENGULFING" -> "看跌吞没";
            case "PIERCING_LINE" -> "刺透";
            case "DARK_CLOUD_COVER" -> "乌云盖顶";
            case "MORNING_STAR" -> "启明星";
            case "EVENING_STAR" -> "黄昏之星";
            case "THREE_WHITE_SOLDIERS" -> "三兵";
            case "THREE_BLACK_CROWS" -> "三鸦";
            case "NO_REVERSAL_PATTERN" -> "无反转形态";
            default -> value(code);
        };
    }

    private String value(String text) {
        return StringUtils.hasText(text) ? text : "-";
    }

    private record SignalDetails(
            String target,
            String targetValue,
            String ema55,
            String ema144,
            String superTrend,
            Long firstTouchOpenTimeMs,
            List<String> reasons
    ) {
        private static SignalDetails empty() {
            return new SignalDetails("-", "-", "-", "-", "-", null, List.of());
        }
    }
}
