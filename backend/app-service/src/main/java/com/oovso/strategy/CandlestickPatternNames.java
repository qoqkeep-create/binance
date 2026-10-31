package com.oovso.strategy;

public final class CandlestickPatternNames {

    private CandlestickPatternNames() {
    }

    public static String displayName(String code) {
        if (code == null || code.isBlank()) {
            return null;
        }
        return switch (code) {
            case "DRAGONFLY_DOJI" -> "蜻蜓线";
            case "HAMMER" -> "锤形线";
            case "INVERTED_HAMMER" -> "倒锤形线";
            case "DOJI_BULLISH_REVERSAL", "DOJI_BEARISH_REVERSAL" -> "十字星";
            case "GRAVESTONE_DOJI" -> "墓碑石";
            case "HANGING_MAN" -> "上吊线";
            case "SHOOTING_STAR" -> "射击之星";
            case "BULLISH_ENGULFING" -> "看涨吞没";
            case "BEARISH_ENGULFING" -> "看跌吞没";
            case "PIERCING_LINE" -> "刺透";
            case "DARK_CLOUD_COVER" -> "乌云盖顶";
            case "MORNING_STAR" -> "启明星";
            case "EVENING_STAR" -> "黄昏之星";
            case "BULLISH_CANNON" -> "多方炮";
            case "BEARISH_CANNON" -> "空方炮";
            case "THREE_WHITE_SOLDIERS" -> "三兵";
            case "THREE_BLACK_CROWS" -> "三鸦";
            case "RISING_THREE_METHODS" -> "上升三法";
            case "FALLING_THREE_METHODS" -> "下跌三法";
            case "BULLISH_FAIRY_GUIDE" -> "仙人指路";
            case "ONE_YANG_FINGER" -> "一阳指";
            case "HEAD_CUTTING_YIN" -> "断头阴";
            case "MACD_NEGATIVE_PEAK" -> "MACD负向峰值";
            case "MACD_POSITIVE_PEAK" -> "MACD正向峰值";
            case "MACD_MOMENTUM_DECAY" -> "MACD能量衰减";
            case "NO_REVERSAL_PATTERN" -> "未识别反转形态";
            default -> code;
        };
    }
}
