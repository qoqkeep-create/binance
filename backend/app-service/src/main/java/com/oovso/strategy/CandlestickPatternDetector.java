package com.oovso.strategy;

import com.oovso.market.MarketKline;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import org.springframework.stereotype.Component;

@Component
public class CandlestickPatternDetector {

    private static final double DOJI_BODY_RATE = 0.10;

    private static final double SMALL_BODY_RATE = 0.30;

    private static final double STRONG_BODY_RATE = 0.45;

    public PatternMatch detect(List<MarketKline> klines, int index, TrendDirection direction) {
        if (index < 0 || index >= klines.size()) {
            return null;
        }
        return direction == TrendDirection.LONG
                ? detectBullish(klines, index)
                : detectBearish(klines, index);
    }

    /**
     * Detects only confirmed reversal patterns for a user-requested second
     * alert. Continuation/breakout patterns and neutral doji are deliberately
     * excluded, and the candles before the pattern must move against the
     * requested signal direction.
     */
    public PatternMatch detectConfirmedReversal(
            List<MarketKline> klines,
            int index,
            TrendDirection direction
    ) {
        if (index < 0 || index >= klines.size()) {
            return null;
        }
        return direction == TrendDirection.LONG
                ? detectConfirmedBullishReversal(klines, index)
                : detectConfirmedBearishReversal(klines, index);
    }

    private PatternMatch detectConfirmedBullishReversal(
            List<MarketKline> klines,
            int index
    ) {
        PatternMatch match;
        if ((match = detectMorningStar(klines, index)) != null
                && hasOpposingContext(klines, index - 2, TrendDirection.LONG)) {
            return match;
        }
        if ((match = detectBullishEngulfing(klines, index)) != null
                && hasOpposingContext(klines, index - 1, TrendDirection.LONG)) {
            return match;
        }
        if ((match = detectPiercingLine(klines, index)) != null
                && hasOpposingContext(klines, index - 1, TrendDirection.LONG)) {
            return match;
        }
        if ((match = detectThreeWhiteSoldiers(klines, index)) != null
                && hasOpposingContext(klines, index - 2, TrendDirection.LONG)) {
            return match;
        }

        Candle current = candle(klines.get(index));
        if (!current.valid()
                || !hasOpposingContext(klines, index, TrendDirection.LONG)) {
            return null;
        }
        if (isDragonflyDoji(current)) {
            return match(
                    "DRAGONFLY_DOJI",
                    78,
                    "蜻蜓线",
                    "下影线很长且实体接近十字",
                    "此前存在明确回调"
            );
        }
        if (isHammerLike(current)) {
            return match(
                    "HAMMER",
                    82,
                    "锤形线",
                    "下影线为实体 " + ratio(current.lowerShadow(), current.body()) + " 倍",
                    "此前存在明确回调"
            );
        }
        return null;
    }

    private PatternMatch detectConfirmedBearishReversal(
            List<MarketKline> klines,
            int index
    ) {
        PatternMatch match;
        if ((match = detectEveningStar(klines, index)) != null
                && hasOpposingContext(klines, index - 2, TrendDirection.SHORT)) {
            return match;
        }
        if ((match = detectBearishEngulfing(klines, index)) != null
                && hasOpposingContext(klines, index - 1, TrendDirection.SHORT)) {
            return match;
        }
        if ((match = detectDarkCloudCover(klines, index)) != null
                && hasOpposingContext(klines, index - 1, TrendDirection.SHORT)) {
            return match;
        }
        if ((match = detectThreeBlackCrows(klines, index)) != null
                && hasOpposingContext(klines, index - 2, TrendDirection.SHORT)) {
            return match;
        }

        Candle current = candle(klines.get(index));
        if (!current.valid()
                || !hasOpposingContext(klines, index, TrendDirection.SHORT)) {
            return null;
        }
        if (isGravestoneDoji(current)) {
            return match(
                    "GRAVESTONE_DOJI",
                    78,
                    "墓碑石",
                    "上影线很长且实体接近十字",
                    "此前存在明确反弹"
            );
        }
        if (isHangingManLike(current)) {
            return match(
                    "HANGING_MAN",
                    78,
                    "上吊线",
                    "下影线为实体 " + ratio(current.lowerShadow(), current.body()) + " 倍",
                    "此前存在明确反弹"
            );
        }
        if (isShootingStarLike(current)) {
            return match(
                    "SHOOTING_STAR",
                    82,
                    "射击之星",
                    "上影线为实体 " + ratio(current.upperShadow(), current.body()) + " 倍",
                    "此前存在明确反弹"
            );
        }
        return null;
    }

    boolean hasOpposingContext(
            List<MarketKline> klines,
            int patternStartIndex,
            TrendDirection direction
    ) {
        int endIndex = patternStartIndex - 1;
        int startIndex = endIndex - 2;
        if (startIndex < 0 || endIndex >= klines.size()) {
            return false;
        }

        Candle first = candle(klines.get(startIndex));
        Candle last = candle(klines.get(endIndex));
        if (!first.valid() || !last.valid()) {
            return false;
        }
        int opposingCandles = 0;
        for (int index = startIndex; index <= endIndex; index++) {
            Candle candle = candle(klines.get(index));
            if (!candle.valid()) {
                return false;
            }
            if (direction == TrendDirection.LONG
                    ? candle.bearish()
                    : candle.bullish()) {
                opposingCandles++;
            }
        }
        boolean movedAgainstSignal = direction == TrendDirection.LONG
                ? last.close() < first.close()
                : last.close() > first.close();
        return movedAgainstSignal && opposingCandles >= 2;
    }

    private PatternMatch detectBullish(List<MarketKline> klines, int index) {
        PatternMatch match;
        if ((match = detectRisingThreeMethods(klines, index)) != null) {
            return match;
        }
        if ((match = detectThreeWhiteSoldiers(klines, index)) != null) {
            return match;
        }
        if ((match = detectMorningStar(klines, index)) != null) {
            return match;
        }
        if ((match = detectBullishCannon(klines, index)) != null) {
            return match;
        }
        if ((match = detectBullishEngulfing(klines, index)) != null) {
            return match;
        }
        if ((match = detectPiercingLine(klines, index)) != null) {
            return match;
        }
        if ((match = detectBullishFairyGuide(klines, index)) != null) {
            return match;
        }
        if ((match = detectOneYangFinger(klines, index)) != null) {
            return match;
        }

        Candle candle = candle(klines.get(index));
        if (!candle.valid()) {
            return null;
        }

        if (isDragonflyDoji(candle)) {
            return match(
                    "DRAGONFLY_DOJI",
                    78,
                    "蜻蜓线",
                    "下影线很长且实体接近十字",
                    "收盘位于K线相对高位"
            );
        }
        if (isHammerLike(candle)) {
            return match(
                    "HAMMER",
                    82,
                    "锤形线",
                    "下影线为实体 " + ratio(candle.lowerShadow(), candle.body()) + " 倍",
                    "收盘位于K线相对高位"
            );
        }
        if (isInvertedHammerLike(candle)) {
            return match(
                    "INVERTED_HAMMER",
                    76,
                    "倒锤形线",
                    "上影线为实体 " + ratio(candle.upperShadow(), candle.body()) + " 倍",
                    "实体处于K线相对低位"
            );
        }
        if (isNeutralDoji(candle)) {
            return match(
                    "DOJI_BULLISH_REVERSAL",
                    62,
                    "十字星",
                    "实体很小，代表回调动能开始犹豫"
            );
        }
        return null;
    }

    private PatternMatch detectBearish(List<MarketKline> klines, int index) {
        PatternMatch match;
        if ((match = detectFallingThreeMethods(klines, index)) != null) {
            return match;
        }
        if ((match = detectThreeBlackCrows(klines, index)) != null) {
            return match;
        }
        if ((match = detectEveningStar(klines, index)) != null) {
            return match;
        }
        if ((match = detectBearishCannon(klines, index)) != null) {
            return match;
        }
        if ((match = detectBearishEngulfing(klines, index)) != null) {
            return match;
        }
        if ((match = detectDarkCloudCover(klines, index)) != null) {
            return match;
        }
        if ((match = detectHeadCuttingYin(klines, index)) != null) {
            return match;
        }

        Candle candle = candle(klines.get(index));
        if (!candle.valid()) {
            return null;
        }

        if (isGravestoneDoji(candle)) {
            return match(
                    "GRAVESTONE_DOJI",
                    78,
                    "墓碑石",
                    "上影线很长且实体接近十字",
                    "收盘位于K线相对低位"
            );
        }
        if (isHangingManLike(candle)) {
            return match(
                    "HANGING_MAN",
                    78,
                    "上吊线",
                    "下影线为实体 " + ratio(candle.lowerShadow(), candle.body()) + " 倍",
                    "实体处于K线相对高位"
            );
        }
        if (isShootingStarLike(candle)) {
            return match(
                    "SHOOTING_STAR",
                    82,
                    "射击之星",
                    "上影线为实体 " + ratio(candle.upperShadow(), candle.body()) + " 倍",
                    "收盘位于K线相对低位"
            );
        }
        if (isNeutralDoji(candle)) {
            return match(
                    "DOJI_BEARISH_REVERSAL",
                    62,
                    "十字星",
                    "实体很小，代表反弹动能开始犹豫"
            );
        }
        return null;
    }

    private PatternMatch detectBullishEngulfing(List<MarketKline> klines, int index) {
        if (index < 1) {
            return null;
        }
        Candle previous = candle(klines.get(index - 1));
        Candle current = candle(klines.get(index));
        if (previous.valid()
                && current.valid()
                && previous.bearish()
                && current.bullish()
                && current.bodyBottom() <= previous.bodyBottom()
                && current.bodyTop() >= previous.bodyTop()
                && current.body() >= previous.body() * 0.8) {
            return match(
                    "BULLISH_ENGULFING",
                    88,
                    "看涨吞没",
                    "当前阳线实体吞没前一根阴线实体"
            );
        }
        return null;
    }

    private PatternMatch detectBearishEngulfing(List<MarketKline> klines, int index) {
        if (index < 1) {
            return null;
        }
        Candle previous = candle(klines.get(index - 1));
        Candle current = candle(klines.get(index));
        if (previous.valid()
                && current.valid()
                && previous.bullish()
                && current.bearish()
                && current.bodyTop() >= previous.bodyTop()
                && current.bodyBottom() <= previous.bodyBottom()
                && current.body() >= previous.body() * 0.8) {
            return match(
                    "BEARISH_ENGULFING",
                    88,
                    "看跌吞没",
                    "当前阴线实体吞没前一根阳线实体"
            );
        }
        return null;
    }

    private PatternMatch detectPiercingLine(List<MarketKline> klines, int index) {
        if (index < 1) {
            return null;
        }
        Candle previous = candle(klines.get(index - 1));
        Candle current = candle(klines.get(index));
        if (previous.valid()
                && current.valid()
                && previous.bearish()
                && current.bullish()
                && previous.strongBody()
                && current.open() <= previous.close() + previous.body() * 0.15
                && current.close() > previous.midBody()
                && current.close() < previous.open()) {
            return match(
                    "PIERCING_LINE",
                    84,
                    "刺透",
                    "阳线从前阴线低位附近反攻",
                    "收盘刺入前阴线实体中位以上"
            );
        }
        return null;
    }

    private PatternMatch detectDarkCloudCover(List<MarketKline> klines, int index) {
        if (index < 1) {
            return null;
        }
        Candle previous = candle(klines.get(index - 1));
        Candle current = candle(klines.get(index));
        if (previous.valid()
                && current.valid()
                && previous.bullish()
                && current.bearish()
                && previous.strongBody()
                && current.open() >= previous.close() - previous.body() * 0.15
                && current.close() < previous.midBody()
                && current.close() > previous.open()) {
            return match(
                    "DARK_CLOUD_COVER",
                    84,
                    "乌云盖顶",
                    "阴线从前阳线高位附近回落",
                    "收盘跌入前阳线实体中位以下"
            );
        }
        return null;
    }

    private PatternMatch detectMorningStar(List<MarketKline> klines, int index) {
        if (index < 2) {
            return null;
        }
        Candle first = candle(klines.get(index - 2));
        Candle middle = candle(klines.get(index - 1));
        Candle current = candle(klines.get(index));
        if (first.valid()
                && middle.valid()
                && current.valid()
                && first.bearish()
                && current.bullish()
                && first.strongBody()
                && middle.smallBody()
                && current.close() >= first.midBody()) {
            return match(
                    "MORNING_STAR",
                    92,
                    "启明星",
                    "下跌实体后出现小实体停顿",
                    "随后阳线收回前阴线实体中位"
            );
        }
        return null;
    }

    private PatternMatch detectEveningStar(List<MarketKline> klines, int index) {
        if (index < 2) {
            return null;
        }
        Candle first = candle(klines.get(index - 2));
        Candle middle = candle(klines.get(index - 1));
        Candle current = candle(klines.get(index));
        if (first.valid()
                && middle.valid()
                && current.valid()
                && first.bullish()
                && current.bearish()
                && first.strongBody()
                && middle.smallBody()
                && current.close() <= first.midBody()) {
            return match(
                    "EVENING_STAR",
                    92,
                    "黄昏之星",
                    "上涨实体后出现小实体停顿",
                    "随后阴线跌回前阳线实体中位"
            );
        }
        return null;
    }

    private PatternMatch detectBullishCannon(List<MarketKline> klines, int index) {
        if (index < 2) {
            return null;
        }
        Candle first = candle(klines.get(index - 2));
        Candle middle = candle(klines.get(index - 1));
        Candle current = candle(klines.get(index));
        if (first.valid()
                && middle.valid()
                && current.valid()
                && first.bullish()
                && middle.bearish()
                && current.bullish()
                && current.close() > first.close()
                && current.body() >= middle.body()
                && current.closePosition() >= 0.60) {
            return match(
                    "BULLISH_CANNON",
                    80,
                    "多方炮",
                    "阳-阴-阳组合",
                    "后一根阳线突破第一根阳线收盘"
            );
        }
        return null;
    }

    private PatternMatch detectBearishCannon(List<MarketKline> klines, int index) {
        if (index < 2) {
            return null;
        }
        Candle first = candle(klines.get(index - 2));
        Candle middle = candle(klines.get(index - 1));
        Candle current = candle(klines.get(index));
        if (first.valid()
                && middle.valid()
                && current.valid()
                && first.bearish()
                && middle.bullish()
                && current.bearish()
                && current.close() < first.close()
                && current.body() >= middle.body()
                && current.closePosition() <= 0.40) {
            return match(
                    "BEARISH_CANNON",
                    80,
                    "空方炮",
                    "阴-阳-阴组合",
                    "后一根阴线跌破第一根阴线收盘"
            );
        }
        return null;
    }

    private PatternMatch detectThreeWhiteSoldiers(List<MarketKline> klines, int index) {
        if (index < 2) {
            return null;
        }
        Candle first = candle(klines.get(index - 2));
        Candle second = candle(klines.get(index - 1));
        Candle current = candle(klines.get(index));
        if (first.valid()
                && second.valid()
                && current.valid()
                && first.bullish()
                && second.bullish()
                && current.bullish()
                && first.bodyRate() >= 0.32
                && second.bodyRate() >= 0.32
                && current.bodyRate() >= 0.32
                && second.close() > first.close()
                && current.close() > second.close()
                && opensInsideBody(second, first)
                && opensInsideBody(current, second)
                && second.upperShadow() <= second.body()
                && current.upperShadow() <= current.body()) {
            return match(
                    "THREE_WHITE_SOLDIERS",
                    86,
                    "三兵",
                    "连续三根阳线逐步抬高",
                    "后两根开盘位于前一根实体内部"
            );
        }
        return null;
    }

    private PatternMatch detectThreeBlackCrows(List<MarketKline> klines, int index) {
        if (index < 2) {
            return null;
        }
        Candle first = candle(klines.get(index - 2));
        Candle second = candle(klines.get(index - 1));
        Candle current = candle(klines.get(index));
        if (first.valid()
                && second.valid()
                && current.valid()
                && first.bearish()
                && second.bearish()
                && current.bearish()
                && first.bodyRate() >= 0.32
                && second.bodyRate() >= 0.32
                && current.bodyRate() >= 0.32
                && second.close() < first.close()
                && current.close() < second.close()
                && opensInsideBody(second, first)
                && opensInsideBody(current, second)
                && second.lowerShadow() <= second.body()
                && current.lowerShadow() <= current.body()) {
            return match(
                    "THREE_BLACK_CROWS",
                    86,
                    "三鸦",
                    "连续三根阴线逐步压低",
                    "后两根开盘位于前一根实体内部"
            );
        }
        return null;
    }

    private PatternMatch detectRisingThreeMethods(List<MarketKline> klines, int index) {
        if (index < 4) {
            return null;
        }
        Candle first = candle(klines.get(index - 4));
        Candle second = candle(klines.get(index - 3));
        Candle third = candle(klines.get(index - 2));
        Candle fourth = candle(klines.get(index - 1));
        Candle current = candle(klines.get(index));
        if (first.valid()
                && second.valid()
                && third.valid()
                && fourth.valid()
                && current.valid()
                && first.bullish()
                && current.bullish()
                && first.strongBody()
                && current.strongBody()
                && withinRange(second, first)
                && withinRange(third, first)
                && withinRange(fourth, first)
                && smallConsolidation(second, third, fourth)
                && bearishCount(second, third, fourth) >= 2
                && current.close() > first.close()) {
            return match(
                    "RISING_THREE_METHODS",
                    84,
                    "上升三法",
                    "强阳后出现三根小K线整理",
                    "最后强阳突破前高位收盘"
            );
        }
        return null;
    }

    private PatternMatch detectFallingThreeMethods(List<MarketKline> klines, int index) {
        if (index < 4) {
            return null;
        }
        Candle first = candle(klines.get(index - 4));
        Candle second = candle(klines.get(index - 3));
        Candle third = candle(klines.get(index - 2));
        Candle fourth = candle(klines.get(index - 1));
        Candle current = candle(klines.get(index));
        if (first.valid()
                && second.valid()
                && third.valid()
                && fourth.valid()
                && current.valid()
                && first.bearish()
                && current.bearish()
                && first.strongBody()
                && current.strongBody()
                && withinRange(second, first)
                && withinRange(third, first)
                && withinRange(fourth, first)
                && smallConsolidation(second, third, fourth)
                && bullishCount(second, third, fourth) >= 2
                && current.close() < first.close()) {
            return match(
                    "FALLING_THREE_METHODS",
                    84,
                    "下跌三法",
                    "强阴后出现三根小K线整理",
                    "最后强阴跌破前低位收盘"
            );
        }
        return null;
    }

    private PatternMatch detectBullishFairyGuide(List<MarketKline> klines, int index) {
        if (index < 1) {
            return null;
        }
        Candle guide = candle(klines.get(index - 1));
        Candle current = candle(klines.get(index));
        if (guide.valid()
                && current.valid()
                && isInvertedHammerLike(guide)
                && current.bullish()
                && current.bodyRate() >= 0.35
                && current.close() >= guide.bodyTop()
                && current.closePosition() >= 0.60) {
            return match(
                    "BULLISH_FAIRY_GUIDE",
                    76,
                    "仙人指路",
                    "前一根长上影试探上方压力",
                    "当前阳线重新收回并确认进攻"
            );
        }
        return null;
    }

    private PatternMatch detectOneYangFinger(List<MarketKline> klines, int index) {
        if (index < 3) {
            return null;
        }
        Candle current = candle(klines.get(index));
        if (!current.valid() || !current.bullish() || current.bodyRate() < 0.55 || current.closePosition() < 0.70) {
            return null;
        }

        double previousHigh = maxHigh(klines, index - 3, index - 1);
        double previousAverageBody = averageBody(klines, index - 3, index - 1);
        if (current.close() > previousHigh
                && current.open() <= previousHigh
                && current.body() >= previousAverageBody * 1.2) {
            return match(
                    "ONE_YANG_FINGER",
                    78,
                    "一阳指",
                    "强阳线突破前三根K线整理高点",
                    "收盘位于K线相对高位"
            );
        }
        return null;
    }

    private PatternMatch detectHeadCuttingYin(List<MarketKline> klines, int index) {
        if (index < 3) {
            return null;
        }
        Candle current = candle(klines.get(index));
        if (!current.valid() || !current.bearish() || current.bodyRate() < 0.55 || current.closePosition() > 0.30) {
            return null;
        }

        double previousLow = minLow(klines, index - 3, index - 1);
        double previousAverageBody = averageBody(klines, index - 3, index - 1);
        if (current.close() < previousLow
                && current.open() >= previousLow
                && current.body() >= previousAverageBody * 1.2) {
            return match(
                    "HEAD_CUTTING_YIN",
                    78,
                    "断头阴",
                    "强阴线跌破前三根K线整理低点",
                    "收盘位于K线相对低位"
            );
        }
        return null;
    }

    private boolean isNeutralDoji(Candle candle) {
        return candle.doji()
                && candle.upperShadow() >= candle.range() * 0.20
                && candle.lowerShadow() >= candle.range() * 0.20;
    }

    private boolean isDragonflyDoji(Candle candle) {
        return candle.doji()
                && candle.lowerShadow() >= candle.range() * 0.60
                && candle.upperShadow() <= candle.range() * 0.18
                && candle.closePosition() >= 0.65;
    }

    private boolean isGravestoneDoji(Candle candle) {
        return candle.doji()
                && candle.upperShadow() >= candle.range() * 0.60
                && candle.lowerShadow() <= candle.range() * 0.18
                && candle.closePosition() <= 0.35;
    }

    private boolean isHammerLike(Candle candle) {
        return candle.lowerShadow() >= candle.body() * 2.5
                && candle.upperShadow() <= candle.range() * 0.25
                && candle.bodyRate() <= 0.45
                && candle.closePosition() >= 0.55;
    }

    private boolean isHangingManLike(Candle candle) {
        return candle.lowerShadow() >= candle.body() * 2.5
                && candle.upperShadow() <= candle.range() * 0.25
                && candle.bodyRate() <= 0.45
                && candle.bodyTopPosition() >= 0.55;
    }

    private boolean isInvertedHammerLike(Candle candle) {
        return candle.upperShadow() >= candle.body() * 2.5
                && candle.lowerShadow() <= candle.range() * 0.25
                && candle.bodyRate() <= 0.45
                && candle.bodyBottomPosition() <= 0.45;
    }

    private boolean isShootingStarLike(Candle candle) {
        return candle.upperShadow() >= candle.body() * 2.5
                && candle.lowerShadow() <= candle.range() * 0.25
                && candle.bodyRate() <= 0.45
                && candle.closePosition() <= 0.45;
    }

    private boolean opensInsideBody(Candle current, Candle previous) {
        return current.open() >= previous.bodyBottom()
                && current.open() <= previous.bodyTop();
    }

    private boolean withinRange(Candle candle, Candle rangeCandle) {
        return candle.high() <= rangeCandle.high()
                && candle.low() >= rangeCandle.low();
    }

    private boolean smallConsolidation(Candle first, Candle second, Candle third) {
        return first.smallBody()
                && second.smallBody()
                && third.smallBody();
    }

    private int bullishCount(Candle... candles) {
        int count = 0;
        for (Candle candle : candles) {
            if (candle.bullish()) {
                count++;
            }
        }
        return count;
    }

    private int bearishCount(Candle... candles) {
        int count = 0;
        for (Candle candle : candles) {
            if (candle.bearish()) {
                count++;
            }
        }
        return count;
    }

    private double maxHigh(List<MarketKline> klines, int startIndex, int endIndex) {
        double result = Double.NEGATIVE_INFINITY;
        for (int index = startIndex; index <= endIndex; index++) {
            result = Math.max(result, candle(klines.get(index)).high());
        }
        return result;
    }

    private double minLow(List<MarketKline> klines, int startIndex, int endIndex) {
        double result = Double.POSITIVE_INFINITY;
        for (int index = startIndex; index <= endIndex; index++) {
            result = Math.min(result, candle(klines.get(index)).low());
        }
        return result;
    }

    private double averageBody(List<MarketKline> klines, int startIndex, int endIndex) {
        double total = 0.0;
        int count = 0;
        for (int index = startIndex; index <= endIndex; index++) {
            Candle candle = candle(klines.get(index));
            if (candle.valid()) {
                total += candle.body();
                count++;
            }
        }
        return count == 0 ? 0.0 : total / count;
    }

    private Candle candle(MarketKline kline) {
        if (kline == null) {
            return invalidCandle();
        }
        return new Candle(
                value(kline.getOpenPrice()),
                value(kline.getHighPrice()),
                value(kline.getLowPrice()),
                value(kline.getClosePrice())
        );
    }

    private double value(BigDecimal value) {
        return value == null ? Double.NaN : value.doubleValue();
    }

    private Candle invalidCandle() {
        return new Candle(
                Double.NaN,
                Double.NaN,
                Double.NaN,
                Double.NaN
        );
    }

    private PatternMatch match(String code, double score, String... reasons) {
        return new PatternMatch(code, score, List.of(reasons));
    }

    private String ratio(double numerator, double denominator) {
        double value = numerator / Math.max(denominator, 0.00000001);
        return String.format("%.2f", value);
    }

    public record PatternMatch(
            String patternCode,
            double score,
            List<String> reasons
    ) {
        public List<String> reasonsWith(String reason) {
            List<String> result = new ArrayList<>(reasons);
            result.add(reason);
            return result;
        }
    }

    private record Candle(
            double open,
            double high,
            double low,
            double close
    ) {
        private boolean valid() {
            return Double.isFinite(open)
                    && Double.isFinite(high)
                    && Double.isFinite(low)
                    && Double.isFinite(close)
                    && open > 0
                    && high > 0
                    && low > 0
                    && close > 0
                    && high > low
                    && high >= Math.max(open, close)
                    && low <= Math.min(open, close);
        }

        private boolean bullish() {
            return close > open;
        }

        private boolean bearish() {
            return close < open;
        }

        private boolean doji() {
            return rawBodyRate() <= DOJI_BODY_RATE;
        }

        private boolean smallBody() {
            return bodyRate() <= SMALL_BODY_RATE;
        }

        private boolean strongBody() {
            return bodyRate() >= STRONG_BODY_RATE;
        }

        private double rawBody() {
            return Math.abs(close - open);
        }

        private double body() {
            return Math.max(rawBody(), range() * 0.03);
        }

        private double range() {
            return high - low;
        }

        private double bodyTop() {
            return Math.max(open, close);
        }

        private double bodyBottom() {
            return Math.min(open, close);
        }

        private double upperShadow() {
            return high - bodyTop();
        }

        private double lowerShadow() {
            return bodyBottom() - low;
        }

        private double bodyRate() {
            return body() / range();
        }

        private double rawBodyRate() {
            return rawBody() / range();
        }

        private double closePosition() {
            return (close - low) / range();
        }

        private double bodyTopPosition() {
            return (bodyTop() - low) / range();
        }

        private double bodyBottomPosition() {
            return (bodyBottom() - low) / range();
        }

        private double midBody() {
            return (open + close) / 2.0;
        }
    }
}
