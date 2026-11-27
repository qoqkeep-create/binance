import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const source = readFileSync(fileURLToPath(new URL("../src/KlineChart.tsx", import.meta.url)), "utf8");
const indicators = readFileSync(fileURLToPath(new URL("../src/lib/chartIndicators.ts", import.meta.url)), "utf8");
const band = readFileSync(fileURLToPath(new URL("../src/lib/supertrendBand.ts", import.meta.url)), "utf8");
const macd = readFileSync(fileURLToPath(new URL("../src/lib/macdHistogram.ts", import.meta.url)), "utf8");
const stline = readFileSync(fileURLToPath(new URL("../src/lib/supertrendLine.ts", import.meta.url)), "utf8");
const positionOverlay = readFileSync(fileURLToPath(new URL("../src/PositionToolOverlay.tsx", import.meta.url)), "utf8");
const positionTools = readFileSync(fileURLToPath(new URL("../src/lib/positionTools.ts", import.meta.url)), "utf8");
const positionCss = readFileSync(fileURLToPath(new URL("../src/position-tools.css", import.meta.url)), "utf8");

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
if (!source.includes("const gen = loadGenRef.current") || !source.includes("gen !== loadGenRef.current || symbolRef.current !== symbol")) {
  throw new Error("Older-history loads must be discarded across symbol/interval changes to avoid cross-symbol cache poisoning");
}
if (!source.includes("Math.round(logical) as Logical") || !source.includes("kline-crosshair-v") || !source.includes("vertLine: { visible: false, labelVisible: false }")) {
  throw new Error("Crosshair must snap at bar midpoints (round) with self-drawn lines, not library ceil-at-center");
}
if (!source.includes("if (!candles.length)") || !source.includes("retryTimer = setTimeout(() => fetchHistory(attemptNo + 1)") || !source.includes("if (retryTimer) clearTimeout(retryTimer)")) {
  throw new Error("Empty cold-start history must keep the veil and retry with backoff, never render/cache empty");
}
const cacheSrc = readFileSync(fileURLToPath(new URL("../src/lib/klineCache.ts", import.meta.url)), "utf8");
if (!cacheSrc.includes("if (candles.length) putCachedKlines")) {
  throw new Error("Prefetch must not cache empty cold-start snapshots");
}
const merge = readFileSync(fileURLToPath(new URL("../src/lib/candleMerge.ts", import.meta.url)), "utf8");
if (!merge.includes("mergeTicker(candles: Candle[], price: number, bucketTime: number)") || !merge.includes("if (bucketTime < last.time) return candles;") || !merge.includes("bucketTime > last.time")) {
  throw new Error("Ticker merge must target the current time bucket only and seed a new bar at roll, never mutate closed history");
}
if (!source.includes("volume: event.closed ? last.volume + incoming.volume : last.volume") || !source.includes("Math.floor(ts / 1000 / width) * width")) {
  throw new Error("Bucket volume must count closed 1m only; ticker bucket must derive from event time");
}
if (!source.includes("last - bars * 0.8 + 0.5") || !source.includes("last + bars * 0.2 - 0.5")) {
  throw new Error("Auto/reset view must leave 1/5 right blank with unchanged bar density");
}
{
  const bars = 131; const last = 299;
  const from = Math.max(0, last - bars * 0.8 + 0.5);
  const to = last + bars * 0.2 - 0.5;
  const fraction = (last - from + 0.5) / (to - from + 1);
  if (Math.abs(fraction - 0.8) > 1e-9 || Math.abs((to - from + 1) - bars) > 1e-9) {
    throw new Error("Auto range math must place last bar at 80% and keep span = bars");
  }
}
if (!source.includes("createPriceLine") || !source.includes("止损 -") || !source.includes("开仓 ") || !source.includes("浮盈") || !source.includes("removePriceLine")) {
  throw new Error("Chart must draw entry/stop(loss box)/live-PnL price lines for open positions");
}
if (!source.includes("const leftEdge = 8") || !source.includes("const base = leftEdge + strip * 2") || !source.includes("base + strip + 8") || !source.includes("container.clientWidth / 6") || !source.includes("pos-label-layer") || !source.includes("axisLabelVisible: false") || !source.includes("tickDirRef.current = close > prevCloseRef.current ? 1 : -1") || !source.includes('order.kind.endsWith("take_profit")')) {
  throw new Error("Entry/stop at left edge+2 strips, PnL one strip right of them, TP at 1/6; tick-colored price line; TP orders drawn");
}
if (!source.includes("kline-attempt-timeout") || !source.includes("Promise.race([getKlines(symbol, selectedInterval, HISTORY_LIMIT, controller.signal), guard])")) {
  throw new Error("Each history attempt must time out (backend sync-thread queue hang) and retry with backoff");
}
if ((source.match(/priceScale\("right", index\).applyOptions\(\{ autoScale: true \}\)/g) || []).length < 2) {
  throw new Error("Symbol switch must restore price-scale autoScale (manual drag freezes old symbol price window => blank chart)");
}
if (source.indexOf("macdDeaRef.current = chart.addSeries") > source.indexOf("macdDifRef.current = chart.addSeries") || source.indexOf("stochDRef.current = chart.addSeries") > source.indexOf("stochKRef.current = chart.addSeries")) {
  throw new Error("Fast MACD line and green Stoch K must render above slow DEA / purple D");
}
if ((source.match(/resetView\(\);/g) || []).length < 2 || !source.includes("kline-click-menu") || !source.includes("复制当前价格") || !source.includes("copyCurrentPrice")) {
  throw new Error("Refresh must fully reset (mode+price axis+viewport); click menu offers 刷新 and 复制当前价格");
}
if (!source.includes('container.addEventListener("contextmenu", onContextMenu)') || !source.includes("event.preventDefault();") || source.includes("downAt") || !klineCss.includes(".kline-click-menu { position: absolute; z-index: 6; display: flex; flex-direction: column;")) {
  throw new Error("Menu must open on right-click only (native context menu suppressed) and stack vertically");
}
if (!source.includes('import PositionToolOverlay from "./PositionToolOverlay"') || !source.includes("<PositionToolOverlay") || source.includes("MeasureKind") || source.includes("FIB_LEVELS") || source.includes("measure-layer") || source.includes("清除测量")) {
  throw new Error("KlineChart must use the shared position tool overlay and remove the old long/short/fib implementation");
}
for (const marker of ["calculatePositionMetrics", "localStorage", "MIN_POSITION_DISTANCE", "setMoveDrag", "position-tool-resize-handle top-left", "position-tool-resize-handle bottom-left", "position-tool-resize-handle middle-left", "position-tool-resize-handle middle-right", "position-tool-edge left-edge", "position-tool-edge right-edge", "const interactive = selected;"]) {
  if (!positionOverlay.includes(marker)) throw new Error(`Position tool overlay is missing ${marker}`);
}
for (const marker of ["position-tool-trigger long", "position-tool-trigger short", "TrendingUp", "TrendingDown", "activePositionTool"]) {
  if (!source.includes(marker)) throw new Error(`KlineChart is missing ${marker}`);
}
for (const marker of ["PositionDirection", "defaultPositionToolDefaults", "priceAtChartY", "riskReward", "profitPnl", "lossPnl"]) {
  if (!positionTools.includes(marker)) throw new Error(`Position tool calculations are missing ${marker}`);
}
for (const marker of [".position-tool-layer", ".position-tool-trigger.long.is-active", ".position-tool-surface", "--position-tool-main-height", "cursor:grab", "pointer-events:none"]) {
  if (!positionCss.includes(marker) && !source.includes(marker)) throw new Error(`Position tool styling is missing ${marker}`);
}
if (positionOverlay.includes('usePreference("positionTools"') || positionOverlay.includes("position-tool-settings-panel")) {
  throw new Error("Position tools must stay in browser cache without the old account settings panel");
}
if (positionOverlay.includes("metrics.profitPercent.toFixed") || positionOverlay.includes("metrics.lossPercent.toFixed")) {
  throw new Error("Position tool annotations must omit target/stop percentages");
}
const pasteSrc = readFileSync(fileURLToPath(new URL("../src/TradePanel.tsx", import.meta.url)), "utf8");
if (!source.includes("price: pRaw === null ? null : Number(pRaw)") || !source.includes("setCopiedPrice(text)") || !pasteSrc.includes("粘贴") || !pasteSrc.includes("getCopiedPrice")) {
  throw new Error("Copy must capture the cursor horizontal-line price; stop-loss input needs a 粘贴 button fed by it");
}
if (!source.includes('from "./lib/priceFormat"') || !source.includes("minMove: minMoveFor(candles[last].close)")) {
  throw new Error("Tiny prices must widen decimals and minMove per symbol or the right scale shows no prices");
}
const pagesSrc = readFileSync(fileURLToPath(new URL("../src/Pages.tsx", import.meta.url)), "utf8");
if (pagesSrc.includes(">止盈</span>") || pagesSrc.indexOf("pg-tp-btn") > pagesSrc.indexOf("pg-close-btn")) {
  throw new Error("Take-profit button must sit left of 立即平仓 without a 止盈 title");
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
const realtime = readFileSync(fileURLToPath(new URL("../src/lib/realtime.ts", import.meta.url)), "utf8");
if (!realtime.includes("sub.tickerSymbols?.length ? sub.tickerSymbols.includes(symbol) : sub.symbol === symbol") || !app.includes("pendingTickersRef")) {
  throw new Error("Left market list must refresh continuously from the shared WS ticker fanout, throttled");
}
if (!styles.includes(".main-nav { align-self: stretch; display: flex; align-items: stretch; gap: 4px; padding: 4px 0; border: 0;") || !styles.includes("white-space: nowrap; }")) {
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
const priceFormatSrc = readFileSync(fileURLToPath(new URL("../src/lib/priceFormat.ts", import.meta.url)), "utf8");
if (!source.includes("priceScaleFormatter") || !priceFormatSrc.includes("abs < 0.0001 ? 8 : abs < 0.01 ? 6 : abs < 1 ? 4")) {
  throw new Error("Right price scale must use tiered decimals incl. tiny-price tiers");
}
if (app.includes("market-rank") || !styles.includes(".nav-item { display: flex; gap: 7px; align-items: center; height: 100%;") || !styles.includes(".market-name strong { overflow-wrap: anywhere; font-weight: 700; }") || !styles.includes("font-size: 9px; font-weight: 500; }")) {
  throw new Error("No rank numbers in market lists; nav chip near-full bar height; coin name bold with smaller USDT");
}
if (!styles.includes(".pg-card footer.pg-times { flex-direction: column; align-items: flex-start;")) {
  throw new Error("History open/close times must sit at the card bottom-left");
}
const positionToolsCss = readFileSync(fileURLToPath(new URL("../src/position-tools.css", import.meta.url)), "utf8");
if (!positionToolsCss.includes("transform:translateY(calc(-100% - 2px))") || !positionToolsCss.includes("width:11px; height:11px;") || !positionToolsCss.includes(".position-tool-line.stop-line span { background:var(--red); color:#ffffff; border-radius:3px; }")) {
  throw new Error("Stats chip right-aligned green/white rounded; stop label red/white; handles half size");
}
const overlaySrc2 = readFileSync(fileURLToPath(new URL("../src/PositionToolOverlay.tsx", import.meta.url)), "utf8");
if (overlaySrc2.includes("浮动盈亏") || !overlaySrc2.includes("入场 {formatPrice(metrics.entryPrice)} · RR") || !overlaySrc2.includes('aria-label="上下移动中线"')) {
  throw new Error("Stats chip must drop direction words, include entry price, and middle handles move the entry line vertically");
}
if (!overlaySrc2.includes("区外点击取消选中") || overlaySrc2.includes("position-tool-empty") || overlaySrc2.includes("hoveredId")) {
  throw new Error("Selection only inside zone; outside click deselects; empty hint and hover-selection removed");
}
const overlaySrc = readFileSync(fileURLToPath(new URL("../src/PositionToolOverlay.tsx", import.meta.url)), "utf8");
if (!overlaySrc.includes('window.addEventListener("pointermove", move)') || !positionToolsCss.includes(".position-tool-drawing { position:absolute; top:0; bottom:0; pointer-events:none; }")) {
  throw new Error("Overlay must not intercept chart mouse events (crosshair survives hover/drag); tool drag via window pointer listeners");
}

console.log("KlineChart self-rendered contract tests passed");
