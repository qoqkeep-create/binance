import { mergeTicker, mergeCandle, mergeBucketKline, sourceClosesBucket } from "../src/lib/candleMerge.js";
import { chartIntervals, intervalSeconds, type ChartInterval } from "../src/lib/analysisIndicators.js";
import type { Candle } from "../src/lib/binance.js";

const closed: Candle[] = [
  { time: 0, open: 10, high: 12, low: 9, close: 11, volume: 100 },
  { time: 900, open: 11, high: 13, low: 10, close: 12, volume: 200 },
];

// 桶滚后新桶未生：ticker 必须种子新根，不得改写已收盘根；种子 open＝前根收盘保连续。
const rolled = mergeTicker(closed, 12.5, 1800);
if (rolled.length !== 3) throw new Error("roll must append a seeded bar");
if (rolled[1].close !== 12 || rolled[1].open !== 11 || rolled[1].high !== 13) throw new Error("closed bar mutated at roll");
if (rolled[2].time !== 1800 || rolled[2].open !== 12 || rolled[2].close !== 12.5 || !rolled[2].seeded) throw new Error("seed bar must open at previous close and carry seeded flag");
if (rolled[2].high !== 12.5 || rolled[2].low !== 12) throw new Error("seed body must span previous close and price (zero-height body renders as a dash)");

// 当前桶内：只改尾根 close/high/low。
const live = mergeTicker(closed, 12.8, 900);
if (live[1].close !== 12.8 || live[1].high !== 13 || live[1].open !== 11) throw new Error("live merge wrong");
if (live[0] !== closed[0]) throw new Error("history touched");

// 过期桶：完全不动。
const stale = mergeTicker(closed, 99, 0);
if (stale !== closed) throw new Error("stale bucket must be ignored");

// 空列表种子。
const seeded = mergeTicker([], 5, 900);
if (seeded.length !== 1 || seeded[0].open !== 5) throw new Error("empty seed wrong");

// mergeCandle 同桶替换/新桶追加/旧桶忽略。
const same = mergeCandle(closed, { time: 900, open: 11, high: 14, low: 10, close: 13, volume: 250 });
if (same[1].close !== 13 || same.length !== 2) throw new Error("mergeCandle same-bucket wrong");
const next = mergeCandle(closed, { time: 1800, open: 12, high: 12, low: 12, close: 12, volume: 1 });
if (next.length !== 3) throw new Error("mergeCandle append wrong");
const old = mergeCandle(closed, { time: 0, open: 1, high: 1, low: 1, close: 1, volume: 1 });
if (old !== closed) throw new Error("mergeCandle old bucket must ignore");

// 种子根首根真实 1m：整体接管 open/high/low（开收盘对齐前根收盘），forming 不累计成交量。
const first1m: Candle = { time: 1800, open: 12, high: 12.6, low: 11.9, close: 12.4, volume: 50 };
const taken = mergeBucketKline(rolled, first1m, 1800, false);
if (taken[2].open !== 12 || taken[2].high !== 12.6 || taken[2].low !== 11.9 || taken[2].close !== 12.4) throw new Error("seeded bucket must take first real 1m open/high/low");
if (taken[2].volume !== 0 || taken[2].seeded) throw new Error("forming first 1m must not add volume and must clear seeded");
const takenClosed = mergeBucketKline(rolled, first1m, 1800, true);
if (takenClosed[2].volume !== 50) throw new Error("closed first 1m volume must count");

// 已有真实 1m 的桶：open 保持首根 1m open，high/low 取并集，仅收盘 1m 累加成交量。
const second1m: Candle = { time: 1860, open: 12.4, high: 12.9, low: 12.3, close: 12.7, volume: 30 };
const merged = mergeBucketKline(takenClosed, second1m, 1800, true);
if (merged[2].open !== 12 || merged[2].high !== 12.9 || merged[2].low !== 11.9 || merged[2].volume !== 80) throw new Error("bucket merge must keep open and union extremes");
const forming = mergeBucketKline(takenClosed, second1m, 1800, false);
if (forming[2].volume !== 50 || forming[2].close !== 12.7) throw new Error("forming 1m must not double-count volume");

// 新桶由真实 1m 建立：open＝该 1m open；旧桶忽略。
const fresh = mergeBucketKline(closed, { time: 1800, open: 12, high: 12.2, low: 11.8, close: 12.1, volume: 10 }, 1800, false);
if (fresh.length !== 3 || fresh[2].open !== 12 || fresh[2].seeded) throw new Error("real-1m new bucket wrong");
const ignored = mergeBucketKline(closed, { time: 0, open: 1, high: 1, low: 1, close: 1, volume: 1 }, 0, true);
if (ignored !== closed) throw new Error("old bucket must be ignored");

// 开收盘连续不变量：种子→首根 1m 后 open 必须等于前根收盘。
if (taken[2].open !== taken[1].close) throw new Error("open/close continuity broken across bucket roll");

// 桶宽必须由 intervalSeconds 派生：3m 曾因缺配静默回退 60 秒，把整段 1m 根追加进 3m 图＝蜡烛挤成一片。
const minutes: Record<ChartInterval, number> = { "1m": 1, "3m": 3, "5m": 5, "15m": 15, "30m": 30, "1h": 60, "2h": 120, "4h": 240, "1d": 1440 };
for (const interval of chartIntervals) {
  if (intervalSeconds[interval] !== minutes[interval] * 60) throw new Error(`${interval} must map to ${minutes[interval] * 60}s, got ${intervalSeconds[interval]}`);
}
const bucketOf = (interval: ChartInterval, time: number) => Math.floor(time / intervalSeconds[interval]) * intervalSeconds[interval];

// 同一 3m 桶内的 540/600 两根 1m 只能长成一根 540，尾根取首根 open 并并集极值。
if (bucketOf("3m", 540) !== 540 || bucketOf("3m", 600) !== 540) throw new Error("540 and 600 must share the 540 three-minute bucket");
const threeMinute: Candle[] = [
  { time: 0, open: 10, high: 11, low: 9, close: 10.5, volume: 10 },
  { time: 180, open: 10.5, high: 12, low: 10, close: 11, volume: 20 },
  { time: 360, open: 11, high: 11.5, low: 10.5, close: 11.2, volume: 30 },
];
const inside3m = mergeBucketKline(
  mergeBucketKline(threeMinute, { time: 540, open: 11.2, high: 12.2, low: 10.8, close: 11.8, volume: 5 }, bucketOf("3m", 540), false),
  { time: 600, open: 11.8, high: 12.9, low: 10.6, close: 12.5, volume: 7 }, bucketOf("3m", 600), false,
);
if (inside3m.length !== 4) throw new Error(`two 1m events inside one 3m bucket must stay a single bar, got ${inside3m.length - 3}`);
if (inside3m[3].open !== 11.2 || inside3m[3].high !== 12.9 || inside3m[3].low !== 10.6 || inside3m[3].close !== 12.5) throw new Error("3m tail bar must keep the first 1m open and union extremes");

// A closed 1m source inside a 1h bucket must keep the 1h bucket forming until
// the final source minute closes. This guards the missing latest 1h candle.
if (sourceClosesBucket(3_600, 3_600, 3_660, 60, true)) throw new Error("early 1m close must not close the 1h bucket");
if (!sourceClosesBucket(3_600, 3_600, 7_140, 60, true)) throw new Error("final 1m close must close the 1h bucket");

// 每个大周期：整桶 1m 事件只加一根蜡烛，且全部落在周期边界、时间严格递增。
for (const interval of ["3m", "5m", "15m"] as ChartInterval[]) {
  const seconds = intervalSeconds[interval];
  const start = Math.floor(1_800_000 / seconds) * seconds;
  let candles: Candle[] = [{ time: start - seconds, open: 10, high: 11, low: 9, close: 10.5, volume: 10 }];
  for (let offset = 0; offset < seconds; offset += 60) {
    candles = mergeBucketKline(candles, {
      time: start + offset, open: 10 + offset / 1000, high: 11 + offset / 1000, low: 9, close: 10.5 + offset / 1000, volume: 1,
    }, bucketOf(interval, start + offset), false);
  }
  if (candles.length !== 2) throw new Error(`${interval}: ${seconds / 60} one-minute events must stay one bar, got ${candles.length - 1}`);
  if (candles[1].time !== start) throw new Error(`${interval}: the new bar must open at the bucket start ${start}`);
  if (candles.some((candle) => candle.time % seconds !== 0)) throw new Error(`${interval}: every candle must sit on a ${seconds}s boundary`);
  for (let index = 1; index < candles.length; index++) {
    if (candles[index].time <= candles[index - 1].time) throw new Error(`${interval}: candle times must stay strictly increasing`);
  }
}

// ticker 种子根同样必须落在周期边界：桶滚间隙按 180 取桶，种子与后续 1m 共用一根。
const rolled3m = mergeTicker(threeMinute, 11.9, bucketOf("3m", 600));
if (rolled3m.length !== 4 || rolled3m[3].time !== 540 || !rolled3m[3].seeded) throw new Error("3m ticker seed must land on the 540 bucket");
const seededThen1m = mergeBucketKline(rolled3m, { time: 540, open: 11.9, high: 12.4, low: 11.7, close: 12.1, volume: 4 }, bucketOf("3m", 540), false);
if (seededThen1m.length !== 4 || seededThen1m[3].seeded || seededThen1m[3].open !== 11.9) throw new Error("first real 1m must take over the seeded 3m bar without adding one");
for (const candle of seededThen1m) if (candle.time % 180 !== 0) throw new Error("3m series must never hold an off-boundary candle");

console.log("candleMerge bucket-guard tests passed");
