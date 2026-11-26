import type { Candle } from "./binance.js";

export function mergeCandle(candles: Candle[], candle: Candle): Candle[] {
  if (!candles.length) return [candle];
  const last = candles[candles.length - 1];
  if (candle.time === last.time) return [...candles.slice(0, -1), candle];
  if (candle.time > last.time) return [...candles, candle].slice(-1500);
  return candles;
}

// 尾根随实时报价跳动：kline 推送间隙用 ticker 价格合成 close/high/low。
// 只允许作用于当前时间桶：桶滚后新桶未生时以 ticker 种子新根，
// 绝不改写已收盘历史根（否则最新根开收盘对不上）。
export function mergeTicker(candles: Candle[], price: number, bucketTime: number): Candle[] {
  if (!Number.isFinite(price) || price <= 0 || !Number.isFinite(bucketTime)) return candles;
  if (!candles.length) return [{ time: bucketTime, open: price, high: price, low: price, close: price, volume: 0 }];
  const last = candles[candles.length - 1];
  if (bucketTime < last.time) return candles;
  if (bucketTime > last.time) return [...candles, { time: bucketTime, open: price, high: price, low: price, close: price, volume: 0 }].slice(-1500);
  if (last.close === price && last.high >= price && last.low <= price) return candles;
  return [...candles.slice(0, -1), { ...last, close: price, high: Math.max(last.high, price), low: Math.min(last.low, price) }];
}