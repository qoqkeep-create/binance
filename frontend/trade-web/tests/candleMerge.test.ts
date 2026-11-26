import { mergeTicker, mergeCandle } from "../src/lib/candleMerge.js";
import type { Candle } from "../src/lib/binance.js";

const closed: Candle[] = [
  { time: 0, open: 10, high: 12, low: 9, close: 11, volume: 100 },
  { time: 900, open: 11, high: 13, low: 10, close: 12, volume: 200 },
];

// 桶滚后新桶未生：ticker 必须种子新根，不得改写已收盘根。
const rolled = mergeTicker(closed, 12.5, 1800);
if (rolled.length !== 3) throw new Error("roll must append a seeded bar");
if (rolled[1].close !== 12 || rolled[1].open !== 11 || rolled[1].high !== 13) throw new Error("closed bar mutated at roll");
if (rolled[2].time !== 1800 || rolled[2].open !== 12.5 || rolled[2].close !== 12.5) throw new Error("seed bar wrong");

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

console.log("candleMerge bucket-guard tests passed");