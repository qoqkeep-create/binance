import { buildCompactIndicatorSeries } from "../src/lib/compactIndicators.js";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

const flat = Array.from({ length: 80 }, (_, index) => ({
  time: index * 900, open: 100, high: 100, low: 100, close: 100, volume: 1,
}));
const flatSeries = buildCompactIndicatorSeries(flat);
const flatLast = flatSeries[flatSeries.length - 1];
assert(flatSeries.length === flat.length, "compact indicators preserve candle alignment");
assert(flatLast.macd === 0 && flatLast.signal === 0 && flatLast.histogram === 0, "flat prices settle MACD at zero");
assert(flatLast.stochK === 50 && flatLast.stochD === 50, "flat prices keep StochRSI neutral");

const wave = Array.from({ length: 120 }, (_, index) => {
  const close = 100 + Math.sin(index / 5) * 6 + index * .03;
  return { time: index * 900, open: close, high: close + 1, low: close - 1, close, volume: 1 };
});
const waveSeries = buildCompactIndicatorSeries(wave);
const ready = waveSeries.filter((point) => point.histogram !== null && point.stochK !== null && point.stochD !== null);
assert(ready.length > 0, "oscillating prices produce compact indicator values");
assert(ready.every((point) => point.stochK! >= 0 && point.stochK! <= 100 && point.stochD! >= 0 && point.stochD! <= 100), "StochRSI values stay in bounds");
console.log("compactIndicators: aligned MACD and StochRSI checks passed");
