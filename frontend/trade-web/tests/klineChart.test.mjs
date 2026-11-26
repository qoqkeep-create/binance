import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const source = readFileSync(fileURLToPath(new URL("../src/KlineChart.tsx", import.meta.url)), "utf8");
const indicators = readFileSync(fileURLToPath(new URL("../src/lib/chartIndicators.ts", import.meta.url)), "utf8");
const band = readFileSync(fileURLToPath(new URL("../src/lib/supertrendBand.ts", import.meta.url)), "utf8");
const macd = readFileSync(fileURLToPath(new URL("../src/lib/macdHistogram.ts", import.meta.url)), "utf8");
const stline = readFileSync(fileURLToPath(new URL("../src/lib/supertrendLine.ts", import.meta.url)), "utf8");

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
if (!source.includes("const AUTO_BAR_SPACING = 7.6") || !source.includes("autoVisibleBars()")) {
  throw new Error("Auto view must size visible bars by bar spacing (iOS-like), not a fixed count");
}
if (!source.includes("autoscaleInfoProvider: () => visiblePriceScale(")) {
  throw new Error("Custom series must autoscale from the visible range only");
}
if (!indicators.includes("prevUpper !== null && candle.close > prevUpper")) {
  throw new Error("Supertrend flip must use the previous final band (TradingView ta.supertrend)");
}
if (!source.includes('from "./lib/supertrendBand"') || !source.includes("bandRef.current?.setData(")) {
  throw new Error("Supertrend must render a configurable fill band");
}
if (!band.includes("a.direction !== b.direction") || !stline.includes("style_linebr")) {
  throw new Error("Supertrend bull/bear segments must break at reversals and show the tail bar");
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

if (!band.includes("data.visibleRange") || !band.includes("range.from - 1")) {
  throw new Error("Supertrend band must clip to the visible range to avoid edge stacking");
}
if (!macd.includes("strokeRect") || !macd.includes("fillRect")) {
  throw new Error("MACD histogram must render solid positive and hollow negative bars");
}
if (!source.includes("renderData(candlesRef.current, false, true)") || !source.includes("candleRef.current.update(")) {
  throw new Error("Live ticks must update only the tail bar, not rebuild all series");
}
if (!source.includes("kline-loading") || !source.includes("kline-bars")) {
  throw new Error("An iOS-style equalizer-bar loading overlay must cover the chart while loading");
}
if (!source.includes('from "./lib/klineCache"') || !source.includes("getCachedKlines(symbol, selectedInterval)")) {
  throw new Error("Symbol switches must use the shared client SWR cache for instant revisits");
}
const app = readFileSync(fileURLToPath(new URL("../src/App.tsx", import.meta.url)), "utf8");
if (!app.includes("prefetchKlines(row.symbol, chartPreference.interval)")) {
  throw new Error("Market rows must prefetch klines on hover for instant switches");
}
if (!app.includes('(["行情", "信号", "引擎", "持仓", "历史", "账户"] as NavItem[])') || app.includes("nav-index")) {
  throw new Error("Main nav must follow the user's order (行情/信号/引擎/持仓/历史/账户) without index numbers");
}
const pages = readFileSync(fileURLToPath(new URL("../src/Pages.tsx", import.meta.url)), "utf8");
if (pages.includes("颜色模式") || pages.includes("onToggleTheme")) {
  throw new Error("Account page must not duplicate the outer theme toggle");
}
const styles = readFileSync(fileURLToPath(new URL("../src/styles.css", import.meta.url)), "utf8");
const klineCss = readFileSync(fileURLToPath(new URL("../src/kline-chart.css", import.meta.url)), "utf8");
if (!styles.includes(".timeframe.active::after") || styles.includes(".timeframe.active { font-weight: 600; background: #2DBD85")) {
  throw new Error("Timeframe selection must use a green short underline + bold text, not the solid nav chip");
}
if (!klineCss.includes(".view-mode button.active { color: var(--green)")) {
  throw new Error("Auto/manual view-mode selection must be green");
}
if (!klineCss.includes(".view-mode button.active { color: var(--green); font-weight: 600; border-color: var(--green)")) {
  throw new Error("Auto/manual selection must show a rounded rectangle chip, not just text color");
}
if (source.includes("createPortal(") || source.includes(">重置</button>") || !source.includes('vertTouchDrag: mode === "manual"') || !source.includes("</button>\n          {insightToggle}")) {
  throw new Error("Reset button removed; auto locks vertical drag/price-axis zoom while manual allows all; insight toggle right of 指标");
}
if (!source.includes('chart.priceScale("right", index).applyOptions({ autoScale: true })')) {
  throw new Error("Switching manual->auto must reset price-axis zoom too");
}
if (!source.includes("scale.setAutoScale(false)") || !source.includes("setVisibleRange({ from: vdrag.from + shift, to: vdrag.to + shift })") || !source.includes("axisPressedMouseMove: true") || !source.includes("rect.width - axisWidth")) {
  throw new Error("Manual pane drag pans without zoom; right price scale must keep mouse drag-zoom in both modes");
}
if (!source.includes("subscribeVisibleLogicalRangeChange(onRange)") || !source.includes("current[0].time * 1000") || !source.includes("preserveView")) {
  throw new Error("Scrolling left must load older history via beforeOpenTime without jumping the viewport");
}
if (!klineCss.includes("font: 12px var(--font-ui);") || !klineCss.includes("font: 13px var(--font-ui);")) {
  throw new Error("自动/手动/指标 labels must be one font level larger");
}
if (!styles.includes(".market-row.selected { background: color-mix(in srgb, var(--green) 26%, transparent)") || !styles.includes(".market-tabs button.active { color: var(--green); font-weight: 600; border-color: var(--green)")) {
  throw new Error("Selected market row must be a full green bar; group tabs must use chip-strength selection");
}
if (!app.includes("navRef") || !app.includes("chartRect.left - nav.getBoundingClientRect().left")) {
  throw new Error("Main nav first item must align vertically with the chart left edge");
}
if (!styles.includes(".main-nav .nav-item { flex: 1; justify-content: center; }") || !styles.includes("width: clamp(320px, calc((100vw - 480px) / 2), 860px)")) {
  throw new Error("Nav items must stay stretched long (half-width clamp), not shrink to natural width");
}
const binance = readFileSync(fileURLToPath(new URL("../src/lib/binance.ts", import.meta.url)), "utf8");
if (!binance.includes("this.tickerSymbols?.length ? [...this.tickerSymbols] : [this.symbol]") || !app.includes("pendingTickersRef")) {
  throw new Error("Left market list must refresh continuously from the WS ticker fanout, throttled");
}
if (!styles.includes(".main-nav { align-self: center; display: flex; align-items: center; gap: 4px; padding: 0; border: 0;") || !styles.includes("white-space: nowrap; }")) {
  throw new Error("Main nav must sit on the topbar background without its own box and keep buttons single-line");
}
if (!klineCss.includes("background: rgba(240, 243, 247, 0.1)") || !klineCss.includes('.kline-stage[data-chart-theme="light"] .kline-loading')) {
  throw new Error("Symbol-switch loading must veil the old chart with a translucent light-gray overlay, not clear it");
}
if (!source.includes("pane-legend") || !source.includes("getHTMLElement()") || !klineCss.includes(".pane-legend")) {
  throw new Error("Sub-panes must show TradingView-style name+params legends at their top-left");
}
if (!source.includes('grid: "rgba(240, 244, 250, 0.045)"')) {
  throw new Error("Chart grid must stay finer than the pane separators");
}
if (!app.includes("price-card-coin") || !app.includes("price-card-label") || !app.includes("price-card-top") || app.includes("price-card-right") || app.includes("price-card-row") || app.includes(">24H<")) {
  throw new Error("Price card must put the two-line change top-right aligned with the coin, then label, then number");
}
if (!styles.includes(".price-card-top") || !styles.includes(".price-card-label")) {
  throw new Error("Price card top row must fit inside the card (change column flex-none, number nowrap)");
}
if (!source.includes("candlesSymbolRef.current !== symbol") || !source.includes("candlesSymbolRef.current = null")) {
  throw new Error("New-symbol ticks must never merge into the previous symbol's candles");
}
if (!source.includes('from "./lib/supertrendLine"') || !stline.includes("b.direction === a.direction") || !stline.includes("段末")) {
  throw new Error("Supertrend support/resistance must break across opposite-direction regions and show the tail bar");
}
if (!stline.includes("(config.visibleRange ? config.visibleRange() : null) || range") || !source.includes("stLineConfigRef.current.visibleRange = liveRange")) {
  throw new Error("Supertrend line must clip against the live logical visible range; update-time item indices drop the tail bars");
}
if (!source.includes("priceScaleFormatter") || !source.includes("abs < 1 ? 4 : abs < 100 ? 3 : abs < 10000 ? 2 : 1")) {
  throw new Error("Right price scale must use tiered decimals (4/3/2/1)");
}

console.log("KlineChart self-rendered contract tests passed");