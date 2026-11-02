"""自有趋势信号引擎：AICoin SuperTrend + EMA 状态机移植。

规则（与原 Pine 脚本对齐）：
- 趋势基准：SuperTrend（ATR 系数 6、ATR 长度 10，源价 (high+low)/2，Wilder 平滑）。
  direction=1 为下跌趋势，direction=-1 为上涨趋势。
- 趋势切换：direction 由 1→-1（翻多）进入"等待做多"；由 -1→1（翻空）进入"等待做空"，
  并清空反向等待状态；趋势切换本身不产生提醒。
- 多头过滤：EMA21 > EMA55；15m 级别放宽为 EMA55 > EMA144 亦可。
- 空头过滤：EMA55 < EMA144；15m 级别放宽为 EMA21 < EMA55 亦可。
- 做多入场：等待做多期间，出现阳线且整根K线（含影线）触碰/穿过 EMA55 或 EMA144，
  收盘确认后触发，对应等待随即消耗；做空入场镜像对称。
- 仅在收盘确认的K线上判定；翻转当根不允许触发入场。

每次扫描只评估各序列「最后一根已收盘K线」，通过信号入库记录按
(symbol, interval, 收盘时间) 去重，避免重复提醒。
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime, timezone
from statistics import mean

from django.conf import settings
from django.core.cache import cache

from common.binance import BinanceApiError, binance_get_historical_candles
from common.errors import safe_error_summary
from trading.constants import PINNED_TRADING_SYMBOLS

logger = logging.getLogger(__name__)

TREND_INTERVALS = ("15m", "1h", "4h", "1d")
KLINE_WINDOW = 1000
SUPERTREND_FACTOR = 6.0
SUPERTREND_ATR_LENGTH = 10
EMA_FAST = 21
EMA_MID = 55
EMA_SLOW = 144
SIGNAL_TITLE = "趋势信号"
STRATEGY_NAME = "SuperTrend+EMA"

_KIND_TEXT = {
    ("entry_ema55", "long"): "做多入场EMA55",
    ("entry_ema55", "short"): "做空入场EMA55",
    ("entry_ema144", "long"): "做多入场EMA144",
    ("entry_ema144", "short"): "做空入场EMA144",
}


@dataclass(frozen=True)
class Candle:
    open_time: int
    close_time: int
    open: float
    high: float
    low: float
    close: float
    volume: float


def parse_closed_candles(rows: list[dict[str, str]], now_ms: int | None = None) -> list[Candle]:
    """只保留已收盘确认的K线（未收盘的当前K线不参与判定）。"""
    now_ms = now_ms or int(datetime.now(tz=timezone.utc).timestamp() * 1000)
    return [
        Candle(int(row["open_time"]), int(row["close_time"]), float(row["open"]), float(row["high"]), float(row["low"]), float(row["close"]), float(row["volume"]))
        for row in rows
        if int(row["close_time"]) < now_ms
    ]


@dataclass(frozen=True)
class TrendEvent:
    symbol: str
    interval: str
    kind: str  # entry_ema55 | entry_ema144
    direction: str  # long | short
    price: float
    candle_close_time_ms: int

    @property
    def text(self) -> str:
        return _KIND_TEXT[(self.kind, self.direction)]


def _ema_stream(closes: list[float], period: int) -> list[float | None]:
    result: list[float | None] = [None] * len(closes)
    if len(closes) < period:
        return result
    current = mean(closes[:period])
    result[period - 1] = current
    multiplier = 2 / (period + 1)
    for index in range(period, len(closes)):
        current = (closes[index] - current) * multiplier + current
        result[index] = current
    return result


def _wilder_atr(candles, period: int) -> list[float | None]:
    """与 Pine ta.atr 一致的 Wilder(RMA) 平滑真实波幅。"""
    result: list[float | None] = [None] * len(candles)
    if len(candles) <= period:
        return result
    true_ranges = [candles[0].high - candles[0].low]
    for current, previous in zip(candles[1:], candles):
        true_ranges.append(
            max(current.high - current.low, abs(current.high - previous.close), abs(current.low - previous.close))
        )
    current_atr = mean(true_ranges[:period])
    result[period - 1] = current_atr
    for index in range(period, len(true_ranges)):
        current_atr = (current_atr * (period - 1) + true_ranges[index]) / period
        result[index] = current_atr
    return result


def evaluate_trend(symbol: str, interval: str) -> list[TrendEvent]:
    """回放最近K线状态机，返回最后一根已收盘K线上触发的全部入场事件。

    趋势翻转只建立等待状态，不产生提醒，也不会与入场同根触发；EMA55 与
    EMA144 入场可在同一根K线上同时触发，由调用方合并为一条提醒。
    """
    rows = binance_get_historical_candles(symbol, interval, limit=KLINE_WINDOW)
    candles = parse_closed_candles(rows)
    if len(candles) < EMA_SLOW + SUPERTREND_ATR_LENGTH + 20:
        logger.warning("趋势信号扫描跳过 %s %s：已收盘K线不足（%s 根）", symbol, interval, len(candles))
        return []

    closes = [row.close for row in candles]
    ema_fast = _ema_stream(closes, EMA_FAST)
    ema_mid = _ema_stream(closes, EMA_MID)
    ema_slow = _ema_stream(closes, EMA_SLOW)
    atr = _wilder_atr(candles, SUPERTREND_ATR_LENGTH)

    is_15m = interval == "15m"
    direction = 0  # 1=下跌趋势 -1=上涨趋势 0=未初始化
    wait_long_55 = wait_long_144 = False
    wait_short_55 = wait_short_144 = False
    trend_flip_index = -1
    last_events: list[TrendEvent] = []
    upper_prev = lower_prev = None

    last = len(candles) - 1
    for index in range(len(candles)):
        atr_value = atr[index]
        if atr_value is None:
            continue
        candle = candles[index]
        src = (candle.high + candle.low) / 2
        basic_upper = src + SUPERTREND_FACTOR * atr_value
        basic_lower = src - SUPERTREND_FACTOR * atr_value
        if upper_prev is None:
            upper, lower = basic_upper, basic_lower
        else:
            upper = basic_upper if (basic_upper < upper_prev or candles[index - 1].close > upper_prev) else upper_prev
            lower = basic_lower if (basic_lower > lower_prev or candles[index - 1].close < lower_prev) else lower_prev
        upper_prev, lower_prev = upper, lower

        prev_direction = direction
        if direction == 0:
            direction = 1
        elif direction == -1 and candle.close < lower:
            direction = 1
        elif direction == 1 and candle.close > upper:
            direction = -1

        flip_bull = direction == -1 and prev_direction == 1
        flip_bear = direction == 1 and prev_direction == -1
        if flip_bull:
            wait_long_55 = wait_long_144 = True
            wait_short_55 = wait_short_144 = False
            trend_flip_index = index
        elif flip_bear:
            wait_short_55 = wait_short_144 = True
            wait_long_55 = wait_long_144 = False
            trend_flip_index = index
        elif index > trend_flip_index and ema_fast[index] is not None and ema_mid[index] is not None and ema_slow[index] is not None:
            ema_f, ema_m, ema_s = ema_fast[index], ema_mid[index], ema_slow[index]
            if direction == -1:
                bull_filter = ema_f > ema_m or (is_15m and ema_m > ema_s)
                if bull_filter and candle.close > candle.open:
                    if wait_long_55 and candle.low <= ema_m <= candle.high:
                        wait_long_55 = False
                        if index == last:
                            last_events.append(TrendEvent(symbol, interval, "entry_ema55", "long", candle.close, candle.close_time))
                    if wait_long_144 and candle.low <= ema_s <= candle.high:
                        wait_long_144 = False
                        if index == last:
                            last_events.append(TrendEvent(symbol, interval, "entry_ema144", "long", candle.close, candle.close_time))
            else:
                bear_filter = ema_m < ema_s or (is_15m and ema_f < ema_m)
                if bear_filter and candle.close < candle.open:
                    if wait_short_55 and candle.low <= ema_m <= candle.high:
                        wait_short_55 = False
                        if index == last:
                            last_events.append(TrendEvent(symbol, interval, "entry_ema55", "short", candle.close, candle.close_time))
                    if wait_short_144 and candle.low <= ema_s <= candle.high:
                        wait_short_144 = False
                        if index == last:
                            last_events.append(TrendEvent(symbol, interval, "entry_ema144", "short", candle.close, candle.close_time))

    return last_events


def _already_alerted(symbol: str, interval: str, time_str: str) -> bool:
    from trading.models import TradingViewMessage

    return TradingViewMessage.objects.filter(
        normalized_payload__symbol=symbol,
        normalized_payload__interval=interval,
        normalized_payload__time=time_str,
        normalized_payload__title=SIGNAL_TITLE,
    ).exists()


def _store_trend_signal(events):
    from django.db import transaction
    from trading.models import TradingViewMessage
    from mobile.push import enqueue_signal
    first = events[0]
    payload = {'title': SIGNAL_TITLE, 'symbol': first.symbol, 'strategy': STRATEGY_NAME,
        'signal': 'BUY' if first.direction == 'long' else 'SELL', 'price': first.price,
        'timestamp': first.candle_close_time_ms, 'interval': first.interval,
        'time': datetime.fromtimestamp(first.candle_close_time_ms / 1000, tz=timezone.utc).strftime('%Y-%m-%d %H:%M:%S'),
        'price_display': format(first.price, '.12g'),
        'comment': f"{first.symbol} {first.interval} 触发信号：{' '.join(event.text for event in events)}"}
    key = f'trend:{first.symbol}:{first.interval}:{first.candle_close_time_ms}'
    with transaction.atomic():
        message, _ = TradingViewMessage.objects.get_or_create(source='internal', event_id=key,
            defaults={'raw_payload': payload, 'normalized_payload': payload})
        enqueue_signal(message)
    return message


_TREND_PERIOD_SECONDS = {"15m": 900, "1h": 3600, "4h": 14400, "1d": 86400}


def _latest_closed_candle_time_ms(interval: str, now: datetime) -> int:
    """理论上最新一根已收盘K线的收盘时间戳（毫秒，币安K线按 UTC 对齐）。

    收盘后留 10 秒宽限再推进，避免币安K线接口短暂滞后时评到旧K线却打了新标记。
    """
    period_ms = _TREND_PERIOD_SECONDS.get(interval, 3600) * 1000
    now_ms = int(now.timestamp() * 1000)
    open_time = (now_ms // period_ms) * period_ms
    if now_ms < open_time + 10_000:
        return open_time
    return open_time + period_ms


def _trend_last_close_ms(symbol: str, interval: str) -> int:
    try:
        value = cache.get(f"trend:last_close:{symbol}:{interval}")
        return int(value or 0)
    except Exception:  # noqa: BLE001
        return 0


def _trend_mark_close(symbol: str, interval: str, close_ms: int) -> None:
    period = _TREND_PERIOD_SECONDS.get(interval, 3600)
    try:
        cache.set(f"trend:last_close:{symbol}:{interval}", int(close_ms), timeout=min(period * 3, 86400))
    except Exception:  # noqa: BLE001
        pass


def scan_trend_signals() -> dict[str, int]:
    """扫描全部币种×周期，最后一根已收盘K线触发信号时推送并入库（带去重）。"""
    now = datetime.now(timezone.utc)
    evaluated = alerted = failed = 0
    for symbol in PINNED_TRADING_SYMBOLS:
        for interval in TREND_INTERVALS:
            # 无新收盘K线则跳过（上次评估过的收盘时间 == 理论最新收盘时间）；
            # 服务重启/错过窗口后记录丢失或落后，会自然补评最新一根
            latest_close_ms = _latest_closed_candle_time_ms(interval, now)
            if _trend_last_close_ms(symbol, interval) >= latest_close_ms:
                continue
            evaluated += 1
            try:
                events = evaluate_trend(symbol, interval)
            except BinanceApiError as exc:
                logger.warning(
                    "趋势信号扫描失败 %s %s: %s",
                    symbol,
                    interval,
                    safe_error_summary(exc),
                )
                failed += 1
                continue
            except Exception as exc:  # noqa: BLE001
                logger.error(
                    "趋势信号扫描异常 %s %s: %s",
                    symbol,
                    interval,
                    safe_error_summary(exc),
                )
                failed += 1
                continue
            if not events:
                _trend_mark_close(symbol, interval, latest_close_ms)
                continue
            time_str = datetime.fromtimestamp(events[0].candle_close_time_ms / 1000, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
            try:
                if _already_alerted(symbol, interval, time_str):
                    _trend_mark_close(symbol, interval, latest_close_ms)
                    continue
                _store_trend_signal(events)
                _trend_mark_close(symbol, interval, latest_close_ms)
                alerted += 1
                logger.info("趋势信号已入库并排队: %s", events)
            except Exception as exc:  # noqa: BLE001
                logger.error(
                    "趋势信号入库失败 %s %s: %s",
                    symbol,
                    interval,
                    safe_error_summary(exc),
                )
                failed += 1
    return {"evaluated": evaluated, "alerted": alerted, "failed": failed}
