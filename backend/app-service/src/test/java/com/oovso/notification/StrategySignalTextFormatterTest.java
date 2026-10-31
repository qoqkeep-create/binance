package com.oovso.notification;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.oovso.strategy.StrategySignal;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.time.ZoneId;
import org.junit.jupiter.api.Test;

class StrategySignalTextFormatterTest {

    private final StrategySignalTextFormatter formatter = new StrategySignalTextFormatter();

    @Test
    void formatsSignalAsPlainText() {
        StrategySignal signal = new StrategySignal();
        signal.setPair("BTCUSDC");
        signal.setIntervalCode("1h");
        signal.setDirection("LONG");
        signal.setStrategyCode("SUPER_EMA144_PULLBACK_REVERSAL");
        signal.setPatternCode("NO_REVERSAL_PATTERN");
        signal.setPrice(new BigDecimal("64123.4500"));
        signal.setScore(new BigDecimal("0"));
        signal.setTriggerOpenTimeMs(timestamp("2026-09-04T08:00:00"));
        signal.setFlipOpenTimeMs(timestamp("2026-09-03T18:00:00"));
        signal.setReasonJson("""
                {
                  "pullbackTarget": "EMA144",
                  "pullbackTargetValue": "64080.25",
                  "ema55": "64500.1",
                  "ema144": "64080.25",
                  "superTrend": "63880.4",
                  "firstTouchOpenTimeMs": %d,
                  "reasons": ["首次进入 EMA144 容差区", "反转形态仅记录"]
                }
                """.formatted(timestamp("2026-09-04T07:00:00")));

        String text = formatter.format(signal, "Asia/Shanghai");

        assertEquals("""
                策略信号提醒
                交易对: BTCUSDC
                方向: 做多 (LONG)
                周期: 1h
                触发时间: 2026-09-04 08:00:00
                触发价格: 64123.45
                回踩目标: EMA144 @ 64080.25
                反转形态: 无反转形态 (NO_REVERSAL_PATTERN)
                信号评分: 0
                EMA55: 64500.1
                EMA144: 64080.25
                SuperTrend: 63880.4
                SuperTrend 翻转时间: 2026-09-03 18:00:00
                首次回踩/回抽时间: 2026-09-04 07:00:00
                策略编码: SUPER_EMA144_PULLBACK_REVERSAL
                触发原因:
                - 首次进入 EMA144 容差区
                - 反转形态仅记录""", text);
    }

    @Test
    void formatsFourHourRetouchWithActualEventTimeAndNoInventedFlip() {
        StrategySignal signal = new StrategySignal();
        signal.setPair("ETHUSDC");
        signal.setIntervalCode("4h");
        signal.setDirection("SHORT");
        signal.setStrategyCode("SUPER_EMA144_PULLBACK_REVERSAL");
        signal.setTriggerOpenTimeMs(timestamp("2026-10-22T20:00:00"));
        signal.setTouchEventTimeMs(timestamp("2026-10-22T21:51:00"));
        signal.setFlipOpenTimeMs(0L);

        String text = formatter.format(signal, "Asia/Shanghai");

        assertTrue(text.contains("触发时间: 2026-10-22 21:51:00"));
        assertTrue(text.contains("首次回踩/回抽时间: 2026-10-22 21:51:00"));
        assertTrue(text.contains("SuperTrend 翻转时间: -"));
    }

    private long timestamp(String value) {
        return LocalDateTime.parse(value)
                .atZone(ZoneId.of("Asia/Shanghai"))
                .toInstant()
                .toEpochMilli();
    }
}
