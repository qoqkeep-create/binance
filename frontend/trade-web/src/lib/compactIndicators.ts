import type { Candle } from "./binance";

export interface CompactIndicatorPoint {
  time: number;
  macd: number | null;
  signal: number | null;
  histogram: number | null;
  stochK: number | null;
  stochD: number | null;
}

function ema(values: Array<number | null>, length: number): Array<number | null> {
  const result = values.map(() => null as number | null);
  const seed = values.findIndex((value) => value !== null);
  if (seed < 0) return result;
  let count = 0;
  let sum = 0;
  for (let index = seed; index < values.length; index += 1) {
    const value = values[index];
    if (value === null) {
      count = 0;
      sum = 0;
      continue;
    }
    count += 1;
    sum += value;
    if (count === length) {
      let current = sum / length;
      result[index] = current;
      const alpha = 2 / (length + 1);
      for (let next = index + 1; next < values.length; next += 1) {
        const nextValue = values[next];
        if (nextValue === null) {
          count = 0;
          sum = 0;
          break;
        }
        current += alpha * (nextValue - current);
        result[next] = current;
      }
      break;
    }
  }
  return result;
}

function rsi(closes: number[], length = 14): Array<number | null> {
  const result = closes.map(() => null as number | null);
  if (closes.length <= length) return result;
  let gain = 0;
  let loss = 0;
  for (let index = 1; index <= length; index += 1) {
    const delta = closes[index] - closes[index - 1];
    gain += Math.max(0, delta);
    loss += Math.max(0, -delta);
  }
  const value = () => gain === 0 && loss === 0 ? 50 : loss === 0 ? 100 : 100 - 100 / (1 + gain / loss);
  result[length] = value();
  for (let index = length + 1; index < closes.length; index += 1) {
    const delta = closes[index] - closes[index - 1];
    gain = (gain * (length - 1) + Math.max(0, delta)) / length;
    loss = (loss * (length - 1) + Math.max(0, -delta)) / length;
    result[index] = value();
  }
  return result;
}

function rollingMin(values: Array<number | null>, index: number, length: number) {
  const window = values.slice(Math.max(0, index - length + 1), index + 1);
  return window.length === length && window.every((value) => value !== null) ? Math.min(...window as number[]) : null;
}

function rollingMax(values: Array<number | null>, index: number, length: number) {
  const window = values.slice(Math.max(0, index - length + 1), index + 1);
  return window.length === length && window.every((value) => value !== null) ? Math.max(...window as number[]) : null;
}

function rollingAverage(values: Array<number | null>, index: number, length: number) {
  const window = values.slice(Math.max(0, index - length + 1), index + 1);
  return window.length === length && window.every((value) => value !== null)
    ? (window as number[]).reduce((sum, value) => sum + value, 0) / length
    : null;
}

/**
 * Calculate aligned MACD and StochRSI values for a compact chart strip.
 * The main TradingView chart remains responsible for price and overlay studies;
 * these values are deliberately kept local so their pane heights stay compact.
 */
export function buildCompactIndicatorSeries(candles: Candle[]): CompactIndicatorPoint[] {
  const ordered = [...candles].sort((a, b) => a.time - b.time);
  const closes = ordered.map((candle) => candle.close);
  const fast = ema(closes, 12);
  const slow = ema(closes, 26);
  const difference = closes.map((_, index) => fast[index] !== null && slow[index] !== null ? fast[index]! - slow[index]! : null);
  const signal = ema(difference, 9);
  const rsiValues = rsi(closes, 14);
  const stochastic = rsiValues.map((value, index) => {
    if (value === null) return null;
    const low = rollingMin(rsiValues, index, 14);
    const high = rollingMax(rsiValues, index, 14);
    return low === null || high === null ? null : high === low ? 50 : (value - low) / (high - low) * 100;
  });
  const k = stochastic.map((_, index) => rollingAverage(stochastic, index, 3));
  const d = k.map((_, index) => rollingAverage(k, index, 3));
  return ordered.map((candle, index) => ({
    time: candle.time,
    macd: difference[index],
    signal: signal[index],
    histogram: difference[index] !== null && signal[index] !== null ? difference[index]! - signal[index]! : null,
    stochK: k[index],
    stochD: d[index],
  }));
}
