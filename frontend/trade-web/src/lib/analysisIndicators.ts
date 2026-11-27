import type { Candle } from "./binance";
import type { BollingerLevels, IndicatorRow } from "./analysisTypes";

// 前端认识的周期全集：任何"按周期取桶宽"的代码只能查这张表。
// 缺条目是编译错误，不再是静默按 60 秒聚合（那会把 1m 根追加进大周期图＝蜡烛挤成一片）。
export const knownIntervals = ["1m", "2m", "3m", "5m", "10m", "15m", "30m", "1h", "2h", "4h", "12h", "1d"] as const;
export type KnownInterval = typeof knownIntervals[number];

export const intervalSeconds: Record<KnownInterval, number> = {
  "1m": 60, "2m": 120, "3m": 180, "5m": 300, "10m": 600, "15m": 900,
  "30m": 1800, "1h": 3600, "2h": 7200, "4h": 14400,
  "12h": 43200, "1d": 86400,
};

/** 后端 INTERVAL_MS 原生支持、可在图表切换的周期；工具条按钮必须是它的子集。 */
export const chartIntervals = ["1m", "3m", "5m", "15m", "30m", "1h", "2h", "4h", "1d"] as const satisfies readonly KnownInterval[];
export type ChartInterval = typeof chartIntervals[number];

export function isChartInterval(value: unknown): value is ChartInterval {
  return typeof value === "string" && (chartIntervals as readonly string[]).includes(value);
}

/** A gap starts a new observation history; unfinished candles cannot confirm indicators. */
export function continuousClosedCandles(candles: Candle[], seconds: number, now: number): Candle[] {
  const ordered = [...new Map(candles.filter((candle) =>
    candle.time + seconds <= now &&
    candle.time % seconds === 0 &&
    [candle.time, candle.open, candle.high, candle.low, candle.close, candle.volume].every(Number.isFinite) &&
    candle.low > 0 && candle.high >= candle.low &&
    candle.open >= candle.low && candle.open <= candle.high &&
    candle.close >= candle.low && candle.close <= candle.high,
  ).map((candle) => [candle.time, candle])).values()].sort((a, b) => a.time - b.time);
  let start = 0;
  for (let index = 1; index < ordered.length; index++) {
    if (ordered[index].time - ordered[index - 1].time !== seconds) start = index;
  }
  return ordered.slice(start);
}

function ema(values: number[], length: number): Array<number | null> {
  const result: Array<number | null> = values.map(() => null);
  if (values.length < length) return result;
  let current = values.slice(0, length).reduce((sum, value) => sum + value, 0) / length;
  result[length - 1] = current;
  const alpha = 2 / (length + 1);
  for (let index = length; index < values.length; index++) {
    current += alpha * (values[index] - current);
    result[index] = current;
  }
  return result;
}

function last<T>(values: T[]): T | null {
  return values.length ? values[values.length - 1] : null;
}

export function bollingerLevels(candles: Candle[], label: string): BollingerLevels | null {
  if (candles.length < 20) return null;
  const closes = candles.slice(-20).map((candle) => candle.close);
  const middle = closes.reduce((sum, close) => sum + close, 0) / closes.length;
  const deviation = Math.sqrt(closes.reduce((sum, close) => sum + (close - middle) ** 2, 0) / closes.length);
  return { upper: middle + 2 * deviation, middle, lower: middle - 2 * deviation, label };
}

function stochRsi(closes: number[]): { k: number | null; d: number | null } {
  if (closes.length < 32) return { k: null, d: null };
  const rsi: number[] = [];
  let gain = 0;
  let loss = 0;
  for (let index = 1; index <= 14; index++) {
    const delta = closes[index] - closes[index - 1];
    gain += Math.max(0, delta) / 14;
    loss += Math.max(0, -delta) / 14;
  }
  const value = () => gain === 0 && loss === 0 ? 50 : loss === 0 ? 100 : 100 - 100 / (1 + gain / loss);
  rsi.push(value());
  for (let index = 15; index < closes.length; index++) {
    const delta = closes[index] - closes[index - 1];
    gain = (gain * 13 + Math.max(0, delta)) / 14;
    loss = (loss * 13 + Math.max(0, -delta)) / 14;
    rsi.push(value());
  }
  const stochastic: number[] = [];
  for (let index = 13; index < rsi.length; index++) {
    const window = rsi.slice(index - 13, index + 1);
    const low = Math.min(...window);
    const high = Math.max(...window);
    stochastic.push(high === low ? 50 : (rsi[index] - low) / (high - low) * 100);
  }
  const kValues: number[] = [];
  for (let index = 2; index < stochastic.length; index++) {
    kValues.push((stochastic[index - 2] + stochastic[index - 1] + stochastic[index]) / 3);
  }
  return { k: last(kValues), d: kValues.length >= 3 ? kValues.slice(-3).reduce((sum, number) => sum + number, 0) / 3 : null };
}

export function buildIndicatorRow(interval: KnownInterval, candles: Candle[], now: number): IndicatorRow {
  const seconds = intervalSeconds[interval];
  const closed = continuousClosedCandles(candles, seconds, now);
  const closes = closed.map((candle) => candle.close);
  const current = last(closes);
  const previous = closes.length > 1 ? closes[closes.length - 2] : null;
  const ema21 = last(ema(closes, 21));
  const ema55 = last(ema(closes, 55));
  const ema144 = last(ema(closes, 144));
  const fast = ema(closes, 12);
  const slow = ema(closes, 26);
  const differences = closes.flatMap((_, index) => {
    const a = fast[index];
    const b = slow[index];
    return a !== null && b !== null ? [a - b] : [];
  });
  const signal = last(ema(differences, 9));
  const difference = last(differences);
  const stochastic = stochRsi(closes);
  const latestClose = closed.length ? closed[closed.length - 1].time + seconds : null;
  const stale = latestClose !== null && latestClose < Math.floor(now / seconds) * seconds;
  const sufficient = ema144 !== null && signal !== null && stochastic.d !== null;
  return {
    interval,
    label: interval === "1d" ? "24H" : interval.toUpperCase(),
    price: current,
    change: current !== null && previous !== null && previous > 0 ? (current / previous - 1) * 100 : null,
    ema21, ema55, ema144,
    macd: difference !== null && signal !== null ? difference - signal : null,
    stochK: stochastic.k,
    stochD: stochastic.d,
    boll: bollingerLevels(closed, interval === "1d" ? "24H" : interval.toUpperCase()),
    trend: ema21 !== null && ema55 !== null && ema144 !== null
      ? ema21 > ema55 && ema55 > ema144 ? "up" : ema21 < ema55 && ema55 < ema144 ? "down" : "neutral"
      : "neutral",
    status: !sufficient ? "waiting" : stale ? "stale" : "ready",
  };
}
