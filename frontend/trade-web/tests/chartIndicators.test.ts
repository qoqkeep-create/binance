import { buildChartIndicators } from "../src/lib/chartIndicators.js";
import { DEFAULT_INDICATORS, mergeIndicatorSettings } from "../src/lib/indicatorSettings.js";
import { mergeCandle, mergeTicker } from "../src/lib/candleMerge.js";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}
const near = (a: number, b: number) => Math.abs(a - b) < 1e-9;

const flat = Array.from({ length: 200 }, (_, index) => ({
  time: index * 900, open: 100, high: 100, low: 100, close: 100, volume: 1,
}));
const flatSeries = buildChartIndicators(flat);
assert(flatSeries.times.length === flat.length, "chart indicators preserve candle alignment");
assert(flatSeries.ema21.length === flat.length && flatSeries.ema144.length === flat.length, "EMA arrays stay aligned");
const flatLast = flat.length - 1;
assert(near(flatSeries.ema21[flatLast]!, 100) && near(flatSeries.ema144[flatLast]!, 100), "flat prices settle EMA at the constant");
assert(near(flatSeries.macd[flatLast].dif!, 0) && near(flatSeries.macd[flatLast].histogram!, 0), "flat prices settle MACD at zero");
assert(flatSeries.stoch[flatLast].k === 50 && flatSeries.stoch[flatLast].d === 50, "flat prices keep StochRSI neutral");

const wave = Array.from({ length: 240 }, (_, index) => {
  const close = 100 + Math.sin(index / 5) * 6 + index * .03;
  return { time: index * 900, open: close, high: close + 1, low: close - 1, close, volume: 1 };
});
const waveSeries = buildChartIndicators(wave);
const ready = waveSeries.macd.map((point, index) => ({ ...point, k: waveSeries.stoch[index].k, d: waveSeries.stoch[index].d }))
  .filter((point) => point.dif !== null && point.dea !== null && point.histogram !== null && point.k !== null && point.d !== null);
assert(ready.length > 0, "oscillating prices produce indicator values");
assert(ready.every((point) => near(point.histogram!, 2 * (point.dif! - point.dea!))), "MACD histogram follows the iOS 2×(DIF−DEA) convention");
assert(ready.every((point) => point.k! >= 0 && point.k! <= 100 && point.d! >= 0 && point.d! <= 100), "StochRSI values stay in bounds");

const uptrend = Array.from({ length: 200 }, (_, index) => {
  const close = 100 + index * .5;
  return { time: index * 900, open: close - .25, high: close + 1, low: close - 1, close, volume: 1 };
});
const upSeries = buildChartIndicators(uptrend);
const upLast = upSeries.supertrend[uptrend.length - 1];
assert(upLast.direction === 1, "a steady uptrend keeps Supertrend bullish");
assert(upLast.value !== null && upLast.value < uptrend[uptrend.length - 1].close, "bullish Supertrend trails below price");

const merged = mergeIndicatorSettings({ ema: { periods: [5, 10, 20] }, supertrend: { fillOpacity: 0.4 } });
assert(merged.ema.periods[0] === 5 && merged.ema.periods[2] === 20, "custom EMA periods merge");
assert(merged.ema.colors[0] === DEFAULT_INDICATORS.ema.colors[0], "missing colors fall back to defaults");
assert(merged.supertrend.fillOpacity === 0.4, "fill opacity merges");
assert(mergeIndicatorSettings(null).macd.fast === 12, "null settings fall back to defaults");
const custom = buildChartIndicators(wave, merged);
assert(custom.ema21.length === wave.length && custom.supertrend.length === wave.length, "custom parameters keep alignment");

const baseCandles = [
  { time: 900, open: 10, high: 12, low: 9, close: 11, volume: 1 },
  { time: 1800, open: 11, high: 13, low: 10, close: 12, volume: 1 },
];
const updated = mergeCandle(baseCandles, { time: 1800, open: 11, high: 14, low: 10, close: 13, volume: 2 });
assert(updated.length === 2 && updated[1].close === 13 && updated[1].high === 14, "same-time kline replaces the last candle");
const appended = mergeCandle(baseCandles, { time: 2700, open: 13, high: 15, low: 12, close: 14, volume: 1 });
assert(appended.length === 3 && appended[2].time === 2700, "newer kline appends");
assert(mergeCandle(baseCandles, { time: 0, open: 1, high: 1, low: 1, close: 1, volume: 1 }) === baseCandles, "older kline is ignored");
const ticked = mergeTicker(baseCandles, 15, 1800);
assert(ticked[1].close === 15 && ticked[1].high === 15 && ticked[1].low === 10, "ticker lifts the last candle close/high");
const tickedDown = mergeTicker(baseCandles, 8, 1800);
assert(tickedDown[1].close === 8 && tickedDown[1].low === 8 && tickedDown[1].high === 13, "ticker drops the last candle close/low");
assert(mergeTicker(baseCandles, 0, 1800) === baseCandles && mergeTicker(baseCandles, NaN, 1800) === baseCandles, "invalid ticker price is ignored");
assert(mergeTicker(baseCandles, 12, 1800) === baseCandles, "unchanged ticker price is a no-op");

console.log("chartIndicators: EMA/Supertrend/MACD/StochRSI checks passed");