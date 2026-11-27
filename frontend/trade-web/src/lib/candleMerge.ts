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
// 种子 open 取前根收盘保证开收盘连续；seeded 标记待首根真实 1m 接管 open/high/low。
export function mergeTicker(candles: Candle[], price: number, bucketTime: number): Candle[] {
  if (!Number.isFinite(price) || price <= 0 || !Number.isFinite(bucketTime)) return candles;
  if (!candles.length) return [{ time: bucketTime, open: price, high: price, low: price, close: price, volume: 0 }];
  const last = candles[candles.length - 1];
  if (bucketTime < last.time) return candles;
  if (bucketTime > last.time) {
    // 种子根实体必须有效：high/low 张开到前根收盘与现价之间，否则零高度实体渲染成
    // 一条横线＝视觉上的"重合/碎蜡烛"。首根真实 1m 到达后整体接管（seeded 标记）。
    return [...candles, { time: bucketTime, open: last.close, high: Math.max(last.close, price), low: Math.min(last.close, price), close: price, volume: 0, seeded: true }].slice(-1500);
  }
  if (last.close === price && last.high >= price && last.low <= price) return candles;
  return [...candles.slice(0, -1), { ...last, close: price, high: Math.max(last.high, price), low: Math.min(last.low, price) }];
}

// 大周期尾根：后端只推 1m，客户端聚合到桶。seeded 根（ticker 种子、尚无真实 1m）
// 首根 1m 到达时整体接管 open/high/low，否则 open 停在种子价＝开收盘错位、实体互相重叠。
export function mergeBucketKline(candles: Candle[], incoming: Candle, bucket: number, closed: boolean): Candle[] {
  const last = candles[candles.length - 1];
  if (last && last.time === bucket) {
    if (last.seeded) {
      return [...candles.slice(0, -1), { time: bucket, open: incoming.open, high: incoming.high, low: incoming.low, close: incoming.close, volume: closed ? incoming.volume : 0 }];
    }
    return [...candles.slice(0, -1), {
      ...last,
      high: Math.max(last.high, incoming.high),
      low: Math.min(last.low, incoming.low),
      close: incoming.close,
      volume: closed ? last.volume + incoming.volume : last.volume,
    }];
  }
  if (!last || bucket > last.time) {
    return [...candles, { time: bucket, open: incoming.open, high: incoming.high, low: incoming.low, close: incoming.close, volume: incoming.volume }].slice(-1500);
  }
  return candles;
}