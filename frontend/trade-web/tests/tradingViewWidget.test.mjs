import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const source = readFileSync(fileURLToPath(new URL("../src/TradingViewWidget.tsx", import.meta.url)), "utf8");

if (!source.includes('const widgetTag = "tv-advanced-chart"') || !source.includes('const widgetScript = "https://widgets.tradingview-widget.com/w/zh_CN/tv-advanced-chart.js"')) {
  throw new Error("TradingView chart must use the official Web Component loader");
}
if (!source.includes('className="tradingview-widget"') || !source.includes('chart.addEventListener("tv-widget-ready"')) {
  throw new Error("TradingView Web Component must use its official ready event");
}
if (!source.includes('}, [hydrating, options, preference.timeFrame, readOnly, selectedInterval, theme]);')) {
  throw new Error("TradingView symbol changes must reuse the mounted Web Component");
}
if (!source.includes("options.interval !== selectedInterval || options.timeFrame !== preference.timeFrame")) {
  throw new Error("TradingView chart must wait for synchronized preferences before mounting");
}
if (!source.includes('"STD;MACD"') || !source.includes('"StochasticRSI@tv-basicstudies"')) {
  throw new Error("TradingView MACD and StochRSI studies must be configured");
}
if (!source.includes('{ id: "STD;MACD", overlay: false, inputs: {} }') || !source.includes('{ id: "StochasticRSI@tv-basicstudies", overlay: false, inputs: {} }')) {
  throw new Error("TradingView Web Component pane studies must use object descriptors");
}
if (!source.includes('theme === "light" ? "#eef0f3" : "#0c0d0f"') || !source.includes('data-chart-theme={theme}') || !source.includes('"--chart-surface": chartSurface') || !source.includes('chart.setAttribute("theme", theme)')) {
  throw new Error("TradingView chart must keep the Web theme surface");
}
if (!source.includes('chart.setAttribute("hide-top-toolbar", "")') || !source.includes('chart.setAttribute("show-drawing-toolbar", "")')) {
  throw new Error("TradingView official toolbar controls must remain available");
}
if (!source.includes('chart.setAttribute("time-frame", timeFrame || (interval === "D" ? "1y" : "2d"))')) {
  throw new Error("TradingView daily charts must use the Web Component time-frame attribute");
}
if (!source.includes("insightToggle") || !source.includes("createPortal(insightToggle, actionsContainer)")) {
  throw new Error("Chart expansion control must live beside the reset action");
}
if (source.includes("chart-local-toolbar") || source.includes("localIntervals")) {
  throw new Error("The custom interval toolbar must be removed from the chart area");
}
if (source.includes("chart-settings") || source.includes("图表设置")) {
  throw new Error("Chart settings must remain TradingView-owned");
}
if (source.includes("CompactIndicatorStrip")) {
  throw new Error("TradingView should own the MACD and StochRSI panes");
}
if (source.includes("local-kline-chart") || source.includes("<svg")) {
  throw new Error("Web K-line main chart must remain TradingView-only");
}

const strip = readFileSync(fileURLToPath(new URL("../src/CompactIndicatorStrip.tsx", import.meta.url)), "utf8");
const styles = readFileSync(fileURLToPath(new URL("../src/compact-indicators.css", import.meta.url)), "utf8");
const mainStyles = readFileSync(fileURLToPath(new URL("../src/styles.css", import.meta.url)), "utf8");
for (const marker of [".workspace {", "overflow: hidden", "height: 0", "inset: 0; z-index: 2", "--chart-surface: var(--bg-deep)", "background: var(--chart-surface)", ".statusbar { position: relative", "font: 13px var(--font-ui)"]) {
  if (!mainStyles.includes(marker)) throw new Error(`Chart layout boundary is missing ${marker}`);
}
for (const marker of ["crosshairTime", "onCrosshairTimeChange", "compact-crosshair-line"]) {
  if (!strip.includes(marker) && !styles.includes(marker)) throw new Error(`Indicator strip is missing ${marker}`);
}
for (const marker of ["id: \"STD;MA%Ribbon\"", "in_3: 21", "in_7: 55", "in_11: 144", "id: \"STD;Supertrend\""]) {
  if (!source.includes(marker)) throw new Error(`TradingView MA Ribbon/Supertrend preset is missing ${marker}`);
}

console.log("TradingView widget contract tests passed");
