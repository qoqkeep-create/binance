import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const source = readFileSync(fileURLToPath(new URL("../src/TradingViewWidget.tsx", import.meta.url)), "utf8");

if (!source.includes("https://s3.tradingview.com/external-embedding/embed-widget-advanced-chart.js")) {
  throw new Error("TradingView chart must use the legacy Advanced Chart iframe embed");
}
if (source.includes("widgets.tradingview-widget.com") || source.includes("tv-advanced-chart")) {
  throw new Error("TradingView chart must not depend on the Web Component loader");
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
