import { buildChartIndicators } from "../src/lib/chartIndicators.js";

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

console.log("chartIndicators: EMA/Supertrend/MACD/StochRSI checks passed");