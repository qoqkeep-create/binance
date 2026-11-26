import type { Candle } from "./binance";

export interface SupertrendPoint { value: number | null; direction: 1 | -1 | null }
export interface MacdPoint { dif: number | null; dea: number | null; histogram: number | null }
export interface StochPoint { k: number | null; d: number | null }

export interface ChartIndicatorSeries {
  times: number[];
  ema21: Array<number | null>;
  ema55: Array<number | null>;
  ema144: Array<number | null>;
  supertrend: SupertrendPoint[];
  macd: MacdPoint[];
  stoch: StochPoint[];
}

function ema(values: Array<number | null>, length: number): Array<number | null> {
  const result = values.map(() => null as number | null);
  let count = 0;
  let sum = 0;
  let current: number | null = null;
  const alpha = 2 / (length + 1);
  for (let index = 0; index < values.length; index += 1) {
    const value = values[index];
    if (value === null) { count = 0; sum = 0; current = null; continue; }
    if (current === null) {
      count += 1;
      sum += value;
      if (count === length) { current = sum / length; result[index] = current; }
      continue;
    }
    current += alpha * (value - current);
    result[index] = current;
  }
  return result;
}

function wilderAtr(candles: Candle[], length: number): Array<number | null> {
  const result = candles.map(() => null as number | null);
  const trs: number[] = [];
  let atr: number | null = null;
  for (let index = 0; index < candles.length; index += 1) {
    const candle = candles[index];
    const previousClose = index > 0 ? candles[index - 1].close : candle.close;
    const tr = Math.max(candle.high - candle.low, Math.abs(candle.high - previousClose), Math.abs(candle.low - previousClose));
    if (atr === null) {
      trs.push(tr);
      if (trs.length === length) { atr = trs.reduce((sum, value) => sum + value, 0) / length; result[index] = atr; }
      continue;
    }
    atr = (atr * (length - 1) + tr) / length;
    result[index] = atr;
  }
  return result;
}

function supertrend(candles: Candle[], length = 10, multiplier = 6): SupertrendPoint[] {
  const atr = wilderAtr(candles, length);
  const result: SupertrendPoint[] = candles.map(() => ({ value: null, direction: null }));
  let upper: number | null = null;
  let lower: number | null = null;
  let direction: 1 | -1 = 1;
  for (let index = 0; index < candles.length; index += 1) {
    const candle = candles[index];
    const atrValue = atr[index];
    if (atrValue === null) continue;
    const mid = (candle.high + candle.low) / 2;
    const basicUpper = mid + multiplier * atrValue;
    const basicLower = mid - multiplier * atrValue;
    const previousClose = index > 0 ? candles[index - 1].close : candle.close;
    upper = upper === null || basicUpper < upper || previousClose > upper ? basicUpper : upper;
    lower = lower === null || basicLower > lower || previousClose < lower ? basicLower : lower;
    if (candle.close > upper) direction = 1;
    else if (candle.close < lower) direction = -1;
    result[index] = { value: direction === 1 ? lower : upper, direction };
  }
  return result;
}

function macd(closes: Array<number | null>, fast = 12, slow = 26, signal = 9): MacdPoint[] {
  const fastEma = ema(closes, fast);
  const slowEma = ema(closes, slow);
  const dif = closes.map((_, index) => fastEma[index] !== null && slowEma[index] !== null ? fastEma[index]! - slowEma[index]! : null);
  const dea = ema(dif, signal);
  return closes.map((_, index) => ({
    dif: dif[index],
    dea: dea[index],
    // iOS/中国惯例 MACD 柱为 2×(DIF−DEA)。
    histogram: dif[index] !== null && dea[index] !== null ? 2 * (dif[index]! - dea[index]!) : null,
  }));
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

function rollingAverage(values: Array<number | null>, index: number, length: number) {
  const window = values.slice(Math.max(0, index - length + 1), index + 1);
  return window.length === length && window.every((value) => value !== null)
    ? (window as number[]).reduce((sum, value) => sum + value, 0) / length
    : null;
}

function stochRsi(closes: number[], rsiLength = 14, stochLength = 14, kLength = 3, dLength = 3): StochPoint[] {
  const rsiValues = rsi(closes, rsiLength);
  const stochastic = rsiValues.map((value, index) => {
    if (value === null) return null;
    const window = rsiValues.slice(Math.max(0, index - stochLength + 1), index + 1);
    if (window.length !== stochLength || window.some((item) => item === null)) return null;
    const low = Math.min(...(window as number[]));
    const high = Math.max(...(window as number[]));
    return high === low ? 50 : (value - low) / (high - low) * 100;
  });
  const k = stochastic.map((_, index) => rollingAverage(stochastic, index, kLength));
  const d = k.map((_, index) => rollingAverage(k, index, dLength));
  return closes.map((_, index) => ({ k: k[index], d: d[index] }));
}

/** Aligned EMA/Supertrend/MACD/StochRSI series mirroring the iOS chart parameters. */
export function buildChartIndicators(candles: Candle[]): ChartIndicatorSeries {
  const ordered = [...candles].sort((a, b) => a.time - b.time);
  const closes = ordered.map((candle) => candle.close);
  const macdPoints = macd(closes);
  const stochPoints = stochRsi(closes);
  const supertrendPoints = supertrend(ordered);
  return {
    times: ordered.map((candle) => candle.time),
    ema21: ema(closes, 21),
    ema55: ema(closes, 55),
    ema144: ema(closes, 144),
    supertrend: supertrendPoints,
    macd: macdPoints,
    stoch: stochPoints,
  };
}