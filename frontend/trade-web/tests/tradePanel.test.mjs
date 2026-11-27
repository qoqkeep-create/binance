import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const panel = readFileSync(fileURLToPath(new URL("../src/TradePanel.tsx", import.meta.url)), "utf8");
const api = readFileSync(fileURLToPath(new URL("../src/lib/tradeApi.ts", import.meta.url)), "utf8");
const app = readFileSync(fileURLToPath(new URL("../src/App.tsx", import.meta.url)), "utf8");

if (!panel.includes("const FEE_RATE = 0.001") || !panel.includes("risk / (ratio + (includeFee ? FEE_RATE : 0))")) {
  throw new Error("Position estimate must mirror iOS: risk / (ratio + fee only when include-fee on)");
}
if (!panel.includes("const isLong = stop < entry")) {
  throw new Error("Side must auto-derive: stop below entry = long, above = short");
}
if (!panel.includes("include_fee: includeFee") || !panel.includes("止损含手续费") || !panel.includes("ratio + (includeFee ? FEE_RATE : 0)") || !panel.includes("return raw === null ? false : raw === \"true\";")) {
  throw new Error("Include-fee toggle must default off (iOS parity) and drive both preview sizing and payload");
}
if (!panel.includes("trade-risk-box") || !panel.includes("setStopDialogOpen(true)") || !panel.includes("<StopLossDialog") || !panel.includes("<StrategyDialog") || !panel.includes('onNavigate("strategy")')) {
  throw new Error("Stop-loss box and strategy row must open the shared dialogs; create scrolls to account form");
}
const pages = readFileSync(fileURLToPath(new URL("../src/Pages.tsx", import.meta.url)), "utf8");
if (!pages.includes('id="account-stop-loss"') || !pages.includes('id="account-strategy"') || !pages.includes('id="account-strategy-editor"')) {
  throw new Error("Account page must host the 50-300 step-1 stop-loss slider and strategy list anchors");
}
if (!panel.includes("输入止损价") || panel.indexOf("trade-settings-btn") < panel.indexOf("trade-submit")) {
  throw new Error("Open button must read 输入止损价 before stop entry; settings button sits below it");
}
if (!panel.includes("trade-paste-icon") || !panel.includes("trade-input-wrap") || panel.includes("pg-notice") || !panel.includes("stopPriceRequest")) {
  throw new Error("Paste icon inside stop input; no notices in right panel; stop price injectable from chart right-click");
}
const apiSrc = readFileSync(fileURLToPath(new URL("../src/lib/tradeApi.ts", import.meta.url)), "utf8");
if (!apiSrc.includes('setStopLoss: (amount: number) => post<unknown>("/account/stop-loss", { amount: String(amount) })')) {
  throw new Error("Stop-loss save must post the backend-required amount field, not stop_loss_amount");
}
const cssSrc = readFileSync(fileURLToPath(new URL("../src/styles.css", import.meta.url)), "utf8");
if (!panel.includes("trade-info") || !panel.includes("trade-fee-row") || panel.indexOf("trade-input-wrap") > panel.indexOf("trade-strategy\">") || panel.indexOf("trade-strategy\">") > panel.indexOf("trade-risk-box") || panel.indexOf("trade-risk-box") > panel.indexOf("trade-fee-row") || panel.indexOf("trade-info") > panel.indexOf("trade-submit") || !panel.includes('settingsOpen && <div className="pg-confirm-backdrop"') || !panel.includes("priceScaleFormatter(price)") || !cssSrc.includes(".insight-panel, .pg-scroll { scrollbar-width: none; }") || !cssSrc.includes(".trade-info > div { display: flex; flex-direction: row; align-items: center; justify-content: space-between;") || !cssSrc.includes(".pd-actions { display: flex; gap: 6px; justify-content: flex-end; }")) {
  throw new Error("Fee row under stop price; estimates block above submit; settings in dialog; tiered prices; hidden scrollbars");
}
const dialogsSrc = readFileSync(fileURLToPath(new URL("../src/AccountDialogs.tsx", import.meta.url)), "utf8");
const pagesSrc2 = readFileSync(fileURLToPath(new URL("../src/Pages.tsx", import.meta.url)), "utf8");
if (!dialogsSrc.includes("单笔止损金额") || !dialogsSrc.includes("确认后止损额立即生效") || !dialogsSrc.includes("pending_amount") || !dialogsSrc.includes("step={1}") || !dialogsSrc.includes("min={minimum} max={maximum}") || !pagesSrc2.includes("<AccountRow label=\"止损金额\"") || !pagesSrc2.includes("<AccountRow label=\"止盈策略\"") || !pagesSrc2.includes("<StopLossDialog") || !pagesSrc2.includes("<StrategyDialog") || !panel.includes("<StopLossDialog") || !panel.includes("<StrategyDialog") || !cssSrc.includes(".acct-dialog { width: min(420px, 92vw);") || !cssSrc.includes("padding: 7px 0;")) {
  throw new Error("Account rows open iOS-parity stop-loss / strategy dialogs reused by trade panel; nav chip slightly shorter");
}
if (panel.includes("trade-side-row") || panel.includes("止损价低于现价为多") || !panel.includes('className={`trade-submit ${isLong ? "is-long" : "is-short"}`}') || !cssSrc.includes(".trade-submit.is-short { background: var(--red); color: #ffffff; }")) {
  throw new Error("No long/short hint row; submit button itself shows 市价开多/开空 and colors green/red");
}
if (!cssSrc.includes(".trade-field > span:first-child { flex: none; white-space: nowrap; }")) {
  throw new Error("Stop-price label must stay on one line");
}
if (!cssSrc.includes(".trade-field { display: flex; flex-direction: column; align-items: stretch; gap: 6px; color: var(--muted); font: 13px var(--font-ui); }") || !cssSrc.includes(".trade-field input { width: 100%; height: 34px;") || !cssSrc.includes(".trade-risk-box { display: flex; align-items: center; justify-content: space-between; gap: 6px; width: 100%; height: 34px;") || !cssSrc.includes(".trade-strategy .trade-strategy-link { display: flex; align-items: center; justify-content: space-between; gap: 4px; width: 100%; height: 34px;") || !cssSrc.includes(".trade-panel { display: flex; flex-direction: column; gap: 14px;")) {
  throw new Error("Trade panel must use stacked labels with uniform full-width 40px controls and looser rhythm");
}
const styles = readFileSync(fileURLToPath(new URL("../src/styles.css", import.meta.url)), "utf8");
if (!styles.includes(".trade-type-row button.active::after { content: ''; position: absolute; left: 10px; right: 10px; bottom: 2px; height: 2px; border-radius: 1px; background: var(--green); }")) {
  throw new Error("Market/limit selection must use the timeframe-style green underline, not a bordered chip");
}
if (!pages.includes("pg-tp-btn") || !pages.includes("自动止盈") || !pages.includes("TpLevels") || !pages.includes("strategy_config")) {
  throw new Error("Position card footer must expose 自动止盈 button (left of 立即平仓) showing the bound strategy levels");
}
if (!pages.includes("marginOpen") || !styles.includes(".pg-card footer { justify-content: flex-end; }") || !styles.includes(".pg-close-btn { padding: 2px 6px; border: 0; border-radius: 0; background: transparent; color: var(--green); font: 700 11px")) {
  throw new Error("Margin ratio needs a detail modal; 立即平仓 sits bottom-right in green");
}
if (!styles.includes(".nav-item.active .nav-pos-count { background: color-mix(in srgb, var(--text) 92%, transparent); color: var(--green); }")) {
  throw new Error("Position count badge must invert when the nav item is selected");
}
for (const marker of ["strategy_id", "strategy_name", "strategy_config", "include_fee: includeFee", "payload, attemptKeyRef.current)", "pollCommand(id)"]) {
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
if (!app.includes('useState<"trade" | "pulse">("pulse")') || !app.includes("pulse-mode-toggle") || !app.includes("<TradePanel symbol={selectedSymbol}") || !app.includes('role="group" aria-label="面板模式"') || app.includes("market-pulse-title") || app.indexOf("盘面</button>") > app.indexOf("交易</button>") || !app.includes("<LayoutDashboard size={13}") || !app.includes("<ArrowLeftRight size={13}") || !styles.includes(".pulse-mode-toggle button.active { color: var(--green); border-color: var(--green)")) {
  throw new Error("Insight panel must default to 盘面, keep 盘面 before 交易 as big icon buttons, and drop the duplicated panel title");
}

console.log("TradePanel v1 contract tests passed");