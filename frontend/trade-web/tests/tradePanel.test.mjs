import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const panel = readFileSync(fileURLToPath(new URL("../src/TradePanel.tsx", import.meta.url)), "utf8");
const api = readFileSync(fileURLToPath(new URL("../src/lib/tradeApi.ts", import.meta.url)), "utf8");
const app = readFileSync(fileURLToPath(new URL("../src/App.tsx", import.meta.url)), "utf8");

if (!panel.includes("const FEE_RATE = 0.001") || !panel.includes("risk / (ratio + FEE_RATE)")) {
  throw new Error("Position estimate must mirror iOS: risk / (|entry-stop|/entry + 0.001)");
}
if (!panel.includes("const isLong = stop < entry")) {
  throw new Error("Side must auto-derive: stop below entry = long, above = short");
}
if (!panel.includes('onNavigate("stop-loss")') || !panel.includes("trade-risk-box") || !panel.includes('onNavigate("strategy")')) {
  throw new Error("Stop-loss amount box and strategy row must navigate to the real account settings sections");
}
const pages = readFileSync(fileURLToPath(new URL("../src/Pages.tsx", import.meta.url)), "utf8");
if (!pages.includes('min={50} max={300} step={1}') || !pages.includes('id="account-stop-loss"') || !pages.includes('id="account-strategy"')) {
  throw new Error("Account page must host the 50-300 step-1 stop-loss slider and strategy list anchors");
}
if (!panel.includes("输入止损价") || panel.indexOf("trade-settings-btn") < panel.indexOf("trade-submit")) {
  throw new Error("Open button must read 输入止损价 before stop entry; settings button sits below it");
}
if (!panel.includes("trade-paste-icon") || !panel.includes("trade-input-wrap") || panel.includes("pg-notice") || !panel.includes("stopPriceRequest")) {
  throw new Error("Paste icon inside stop input; no notices in right panel; stop price injectable from chart right-click");
}
const cssSrc = readFileSync(fileURLToPath(new URL("../src/styles.css", import.meta.url)), "utf8");
if (!cssSrc.includes(".trade-field > span:first-child { flex: none; white-space: nowrap; }")) {
  throw new Error("Stop-price label must stay on one line");
}
const styles = readFileSync(fileURLToPath(new URL("../src/styles.css", import.meta.url)), "utf8");
if (!styles.includes(".trade-type-row button.active { color: var(--green); font-weight: 600; border-color: var(--green)")) {
  throw new Error("Market/limit selection must use the same rounded green chip as auto/manual");
}
if (!pages.includes("pg-tp-btn") || !pages.includes("自动止盈") || !pages.includes("TpLevels") || !pages.includes("strategy_config")) {
  throw new Error("Position card footer must expose 自动止盈 button (left of 立即平仓) showing the bound strategy levels");
}
if (!pages.includes("marginOpen") || !styles.includes(".pg-card footer { justify-content: flex-end; }") || !styles.includes(".pg-close-btn { padding: 7px 14px; border: 0; border-radius: 6px; background: var(--green)")) {
  throw new Error("Margin ratio needs a detail modal; 立即平仓 sits bottom-right in green");
}
if (!styles.includes(".nav-item.active .nav-pos-count { background: color-mix(in srgb, var(--text) 92%, transparent); color: var(--green); }")) {
  throw new Error("Position count badge must invert when the nav item is selected");
}
for (const marker of ["strategy_id", "strategy_name", "strategy_config", "include_fee: true", "payload, attemptKeyRef.current)", "pollCommand(id)"]) {
  if (!panel.includes(marker)) throw new Error(`Open command payload/flow missing ${marker}`);
}
if ((panel.match(/void submitOpen\(\)/g) || []).length !== 1) {
  throw new Error("UNKNOWN open outcome must not auto-resubmit (submit only via confirm button)");
}
if (!panel.includes("确认继续？") || !panel.includes("pg-confirm-backdrop")) {
  throw new Error("Real open submission requires a second confirmation dialog");
}
if (!api.includes("idempotencyKey?: string") || !api.includes('"/strategy/list"')) {
  throw new Error("tradeApi must support stable idempotency keys and the strategy list");
}
if (!app.includes('useState<"trade" | "pulse">("trade")') || !app.includes("pulse-mode-toggle") || !app.includes("<TradePanel symbol={selectedSymbol}")) {
  throw new Error("Insight panel must default to trade mode with a 交易/盘面 toggle");
}

console.log("TradePanel v1 contract tests passed");