import type { Candle } from "./binance.js";

export function mergeCandle(candles: Candle[], candle: Candle): Candle[] {
  if (!candles.length) return [candle];
  const last = candles[candles.length - 1];
  if (candle.time === last.time) return [...candles.slice(0, -1), candle];
  if (candle.time > last.time) return [...candles, candle].slice(-1500);
  return candles;
}

// 尾根随实时报价跳动：kline 推送间隙用 ticker 价格合成 close/high/low。
export function mergeTicker(candles: Candle[], price: number): Candle[] {
  if (!candles.length || !Number.isFinite(price) || price <= 0) return candles;
  const last = candles[candles.length - 1];
  if (last.close === price && last.high >= price && last.low <= price) return candles;
  return [...candles.slice(0, -1), { ...last, close: price, high: Math.max(last.high, price), low: Math.min(last.low, price) }];
}