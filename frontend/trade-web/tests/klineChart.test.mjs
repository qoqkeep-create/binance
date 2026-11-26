import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const source = readFileSync(fileURLToPath(new URL("../src/KlineChart.tsx", import.meta.url)), "utf8");
const indicators = readFileSync(fileURLToPath(new URL("../src/lib/chartIndicators.ts", import.meta.url)), "utf8");

if (source.includes("tv-advanced-chart") || source.includes("widgets.tradingview-widget.com") || source.includes("TradingViewWidget")) {
  throw new Error("Web K-line must be self-rendered, not the TradingView iframe widget");
}
for (const marker of ["createChart", "CandlestickSeries", "HistogramSeries", "LineSeries", 'from "lightweight-charts"']) {
  if (!source.includes(marker)) throw new Error(`K-line chart must use lightweight-charts: ${marker}`);
}
if (!source.includes('import { buildChartIndicators } from "./lib/chartIndicators"')) {
  throw new Error("K-line chart must reuse the shared indicator series");
}
for (const marker of ["ema21", "ema55", "ema144", "supertrend", "macd", "stoch"]) {
  if (!indicators.includes(marker)) throw new Error(`Indicator series missing ${marker}`);
}
if (!indicators.includes("2 * (dif[index]! - dea[index]!)")) {
  throw new Error("MACD histogram must follow the iOS 2×(DIF−DEA) convention");
}
if (!indicators.includes("multiplier = 6") || !indicators.includes("length = 10")) {
  throw new Error("Supertrend must mirror the iOS 10/×6 parameters");
}
if (!source.includes("const PANE_STRETCH = { main: 70, sub: 15 }") || !source.includes("panes[1].setStretchFactor(settings.macd.enabled ? PANE_STRETCH.sub : 0)") || !source.includes("panes[2].setStretchFactor(settings.stoch.enabled ? PANE_STRETCH.sub : 0)")) {
  throw new Error("Sub-panes must use the adaptive 70/15/15 stretch layout");
}
if (!source.includes("const INITIAL_VISIBLE_BARS = 64") || !source.includes("candles.length - INITIAL_VISIBLE_BARS")) {
  throw new Error("First paint must show 64 bars");
}
if (!source.includes('from "./lib/supertrendBand"') || !source.includes("bandRef.current?.setData(")) {
  throw new Error("Supertrend must render a configurable fill band");
}
if (!source.includes("const isFlip = (index: number)") || !source.includes("!isFlip(index)")) {
  throw new Error("Supertrend bull/bear segments must break at reversals");
}
if (!source.includes("IndicatorSettingsPanel") || !source.includes("mergeIndicatorSettings(preference.indicators)")) {
  throw new Error("Indicator master settings panel must be wired to preferences");
}
if (!source.includes("}, 1);") || !source.includes("}, 2);")) {
  throw new Error("MACD and StochRSI must render in their own panes");
}
if (!source.includes("const INTERVALS = [\"3m\", \"5m\", \"15m\", \"1h\", \"4h\", \"1d\"]")) {
  throw new Error("Interval picker must mirror the iOS favorites");
}
// The chart instance is created once; symbol switches only fetch + setData, never rebuild.
if (!source.includes("chartRef.current = chart;") || !source.includes("}, []);")) {
  throw new Error("The lightweight-charts instance must mount once");
}
if (!source.includes("}, [hydrating, symbol, selectedInterval, attempt, renderData]);")) {
  throw new Error("Symbol switches must reuse the mounted chart and load once");
}
if (!source.includes("candleRef.current.setData(") || source.includes("createChart(container") === false) {
  throw new Error("Symbol switches must update data on the existing series");
}

console.log("KlineChart self-rendered contract tests passed");