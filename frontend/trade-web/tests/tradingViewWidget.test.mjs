import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const source = readFileSync(fileURLToPath(new URL("../src/TradingViewWidget.tsx", import.meta.url)), "utf8");
const loader = readFileSync(fileURLToPath(new URL("../public/vendor/tradingview-advanced-chart.js", import.meta.url)), "utf8");

if (!source.includes('const widgetScript = "vendor/tradingview-advanced-chart.js"')) {
  throw new Error("TradingView loader must be served by the integrated web package");
}
if (!source.includes('className="tradingview-widget tradingview-widget-container"')) {
  throw new Error("TradingView legacy embed must use the official container class");
}
if (loader.length < 10000 || !loader.includes("www.tradingview-widget.com")) {
  throw new Error("Integrated package is missing the official TradingView legacy loader");
}
if (source.includes("widgets.tradingview-widget.com") || source.includes("tv-advanced-chart")) {
  throw new Error("TradingView chart must not depend on the Web Component loader");
}
if (!source.includes("options.interval !== selectedInterval || options.timeFrame !== preference.timeFrame")) {
  throw new Error("TradingView chart must wait for synchronized preferences before mounting");
}
if (!source.includes('"MACD@tv-basicstudies"') || !source.includes('"StochasticRSI@tv-basicstudies"')) {
  throw new Error("TradingView MACD and StochRSI studies must be configured");
}
if (!source.includes('backgroundColor: "#0c0d0f"') || !source.includes("aria-label=\"图表设置\"")) {
  throw new Error("TradingView chart must expose the Web dark background and settings control");
}
if (source.includes("CompactIndicatorStrip")) {
  throw new Error("TradingView should own the MACD and StochRSI panes");
}
if (source.includes("local-kline-chart") || source.includes("<svg")) {
  throw new Error("Web K-line main chart must remain TradingView-only");
}

const strip = readFileSync(fileURLToPath(new URL("../src/CompactIndicatorStrip.tsx", import.meta.url)), "utf8");
const styles = readFileSync(fileURLToPath(new URL("../src/compact-indicators.css", import.meta.url)), "utf8");
for (const marker of ["crosshairTime", "onCrosshairTimeChange", "compact-crosshair-line"]) {
  if (!strip.includes(marker) && !styles.includes(marker)) throw new Error(`Indicator strip is missing ${marker}`);
}
for (const marker of ["length: 21", "length: 55", "length: 144"]) {
  if (!source.includes(marker)) throw new Error(`TradingView MA Ribbon preset is missing ${marker}`);
}

console.log("TradingView widget contract tests passed");
