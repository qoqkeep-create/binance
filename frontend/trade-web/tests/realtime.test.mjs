import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const source = readFileSync(join(root, "src/lib/realtime.ts"), "utf8");

if (!source.includes('type SocketKind = "ticker" | "kline"')) {
  throw new Error("realtime client must model separate ticker and kline sockets");
}
if (!source.includes('private sockets: Record<SocketKind, SocketState>')) {
  throw new Error("realtime client must own independent socket state");
}
if (!source.includes('channel: "market.ticker.batch"') || !source.includes('channel: "market.kline"')) {
  throw new Error("ticker and kline subscriptions must remain explicit");
}
if (!source.includes('this.klineSequences.clear()')) {
  throw new Error("reconnect must reset kline sequence state");
}
if (!source.includes('type: "gap"')) {
  throw new Error("closed kline sequence gaps must be surfaced to the chart");
}
if (!source.includes('closed ? "closed" : "forming"')) {
  throw new Error("forming and closed kline sequences must be tracked independently");
}

console.log("realtime transport contract checks passed");

