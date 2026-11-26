import { getKlines, type Candle } from "./binance.js";

// 跨组件共享的 K 线 SWR 缓存：KlineChart 回切瞬时出图，列表悬停/空闲预取命中同一份。
const cache = new Map<string, Candle[]>();
const inflight = new Map<string, Promise<Candle[]>>();
const MAX_ENTRIES = 12;

export const klineCacheKey = (symbol: string, interval: string) => `${symbol}|${interval}`;

export function getCachedKlines(symbol: string, interval: string): Candle[] | undefined {
  return cache.get(klineCacheKey(symbol, interval));
}

export function putCachedKlines(symbol: string, interval: string, candles: Candle[]) {
  const key = klineCacheKey(symbol, interval);
  if (cache.size > MAX_ENTRIES && !cache.has(key)) cache.delete(cache.keys().next().value as string);
  cache.set(key, candles);
}

export function prefetchKlines(symbol: string, interval: string, limit = 300) {
  const key = klineCacheKey(symbol, interval);
  if (cache.has(key) || inflight.has(key)) return;
  const promise = getKlines(symbol, interval, limit)
    .then((candles) => {
      putCachedKlines(symbol, interval, candles);
      inflight.delete(key);
      return candles;
    })
    .catch(() => {
      inflight.delete(key);
      return [] as Candle[];
    });
  inflight.set(key, promise);
}