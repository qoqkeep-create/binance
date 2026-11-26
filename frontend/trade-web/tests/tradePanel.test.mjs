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
if (!panel.includes('min={50} max={300} step={1}') || !panel.includes("tradeApi.setStopLoss(draftRisk)")) {
  throw new Error("Stop-loss amount must adjust via 50-300 slider and persist through /account/stop-loss");
}
for (const marker of ["strategy_id", "strategy_name", "strategy_config", "include_fee: true", 'submitCommand("open", payload, attemptKeyRef.current)', "pollCommand(id)"]) {
  if (!panel.includes(marker)) throw new Error(`Open command payload/flow missing ${marker}`);
}
if (!panel.includes("开仓结果待确认，请勿重复提交")) {
  throw new Error("UNKNOWN open outcome must not auto-resubmit");
}
if (!panel.includes("确认开仓") || !panel.includes("pg-confirm-backdrop")) {
  throw new Error("Real open submission requires a second confirmation dialog");
}
if (!api.includes("idempotencyKey?: string") || !api.includes('"/strategy/list"')) {
  throw new Error("tradeApi must support stable idempotency keys and the strategy list");
}
if (!app.includes('useState<"trade" | "pulse">("trade")') || !app.includes("pulse-mode-toggle") || !app.includes("<TradePanel symbol={selectedSymbol}")) {
  throw new Error("Insight panel must default to trade mode with a 交易/盘面 toggle");
}

console.log("TradePanel v1 contract tests passed");