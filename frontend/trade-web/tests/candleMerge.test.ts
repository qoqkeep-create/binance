import { mergeTicker, mergeCandle, mergeBucketKline } from "../src/lib/candleMerge.js";
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
if (rolled[2].high !== 12.5 || rolled[2].low !== 12.5) throw new Error("seed extremes must stay at current price until first real 1m");

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

console.log("candleMerge bucket-guard tests passed");