import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const source = readFileSync(fileURLToPath(new URL("../src/KlineChart.tsx", import.meta.url)), "utf8");
const indicators = readFileSync(fileURLToPath(new URL("../src/lib/chartIndicators.ts", import.meta.url)), "utf8");

if (source.includes("tv-advanced-chart") || source.includes("widgets.tradingview-widget.com") || source.includes("TradingViewWidget")) {
  throw new Error("Web K-line must be self-rendered, not the TradingView iframe widget");
}
for (const marker of ["createChart", "CandlestickSeries", "LineSeries", 'from "lightweight-charts"', 'from "./lib/macdHistogram"', 'from "./lib/supertrendBand"']) {
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
if (!source.includes("const isFlip = (index: number)") || !source.includes("isFlip(index) || isFlip(index - 1)")) {
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

const band = readFileSync(fileURLToPath(new URL("../src/lib/supertrendBand.ts", import.meta.url)), "utf8");
const macd = readFileSync(fileURLToPath(new URL("../src/lib/macdHistogram.ts", import.meta.url)), "utf8");
if (!band.includes("data.visibleRange") || !band.includes("range.from - 1")) {
  throw new Error("Supertrend band must clip to the visible range to avoid edge stacking");
}
if (!macd.includes("strokeRect") || !macd.includes("fillRect")) {
  throw new Error("MACD histogram must render solid positive and hollow negative bars");
}
if (!source.includes("renderData(candlesRef.current, false, true)") || !source.includes("candleRef.current.update(")) {
  throw new Error("Live ticks must update only the tail bar, not rebuild all series");
}
if (!source.includes("kline-loading") || !source.includes("kline-spinner")) {
  throw new Error("An iOS-style loading overlay must cover the chart while loading");
}
if (!source.includes('from "./lib/klineCache"') || !source.includes("getCachedKlines(symbol, selectedInterval)")) {
  throw new Error("Symbol switches must use the shared client SWR cache for instant revisits");
}
const app = readFileSync(fileURLToPath(new URL("../src/App.tsx", import.meta.url)), "utf8");
if (!app.includes("prefetchKlines(row.symbol, chartPreference.interval)")) {
  throw new Error("Market rows must prefetch klines on hover for instant switches");
}
if (!source.includes("candlesSymbolRef.current !== symbol") || !source.includes("candlesSymbolRef.current = null")) {
  throw new Error("New-symbol ticks must never merge into the previous symbol's candles");
}
const stline = readFileSync(fileURLToPath(new URL("../src/lib/supertrendLine.ts", import.meta.url)), "utf8");
if (!source.includes('from "./lib/supertrendLine"') || !stline.includes("b.index !== a.index + 1")) {
  throw new Error("Supertrend support/resistance must break across opposite-direction regions");
}
if (!source.includes("priceScaleFormatter") || !source.includes("abs < 1 ? 4 : abs < 100 ? 3 : abs < 10000 ? 2 : 1")) {
  throw new Error("Right price scale must use tiered decimals (4/3/2/1)");
}

console.log("KlineChart self-rendered contract tests passed");