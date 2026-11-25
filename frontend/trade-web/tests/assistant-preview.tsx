/**
 * Development-only visual regression fixture. Open with the Vite dev server:
 * /tests/assistant-preview.html
 *
 * Only Binance Futures REST and stream requests are mocked. Production entry
 * points never import this file. BTC varies across several scales, ETH has a
 * stable short-period range, and SOL provides repeated 2M box-edge touches.
 * Use ?box=pending, ?box=breakout or ?box=empty for SOL box states.
 */
import { createRoot } from "react-dom/client";
import App from "../src/App";

const nativeFetch = window.fetch.bind(window);
const NativeWebSocket = window.WebSocket;
const originTime = Math.floor(Date.now() / 60000) * 60;
const boxScenario = new URLSearchParams(window.location.search).get("box") ?? "active";
const TAU = Math.PI * 2;
const seconds: Record<string, number> = { "1m": 60, "2m": 120, "5m": 300, "10m": 600, "15m": 900, "30m": 1800, "1h": 3600, "2h": 7200, "4h": 14400, "12h": 43200, "1d": 86400 };
const contracts = [
  { symbol: "BTCUSDT", baseAsset: "BTC", base: 97320, tick: "0.10", change: 2.86, quoteVolume: 38_200_000_000 },
  { symbol: "ETHUSDT", baseAsset: "ETH", base: 3328, tick: "0.01", change: 1.42, quoteVolume: 19_800_000_000 },
  { symbol: "SOLUSDT", baseAsset: "SOL", base: 188.74, tick: "0.001", change: -.73, quoteVolume: 8_500_000_000 },
];

function contractFor(symbol: string) {
  return contracts.find((contract) => contract.symbol === symbol) ?? contracts[0];
}

function priceAt(symbol: string, time: number) {
  const contract = contractFor(symbol);
  const minutes = (time - originTime) / 60;
  const wave = symbol === "SOLUSDT"
    ? boxScenario === "empty" ? .012 * Math.tanh(minutes / 600) : .013 * Math.sin(TAU * minutes / 16) + .0006 * Math.sin(TAU * minutes / 240)
    : symbol === "ETHUSDT"
      ? .014 * Math.sin(TAU * minutes / 52) + .001 * Math.sin(TAU * minutes / 9) + .0015 * Math.sin(TAU * minutes / 470)
      : .009 * Math.sin(TAU * minutes / 68) + .019 * Math.sin(TAU * minutes / 420) + .032 * Math.sin(TAU * minutes / 4320) + .006 * Math.sin(TAU * minutes / 17);
  const breakoutStart = Math.floor(originTime / 120) * 120 - (boxScenario === "breakout" ? 240 : 120);
  const boxBreakout = symbol === "SOLUSDT" && (boxScenario === "breakout" || boxScenario === "pending") && time > breakoutStart;
  return Number((contract.base * (1 + (boxBreakout ? .04 : wave))).toFixed(symbol === "BTCUSDT" ? 2 : symbol === "ETHUSDT" ? 3 : 5));
}

function candleAt(symbol: string, interval: string, time: number) {
  const duration = seconds[interval] ?? 60;
  const now = Date.now() / 1000;
  const end = Math.min(time + duration, now);
  const open = priceAt(symbol, time);
  const close = priceAt(symbol, end);
  const samples = Array.from({ length: 17 }, (_, index) => priceAt(symbol, time + (end - time) * index / 16));
  const wick = contractFor(symbol).base * .00017;
  return { time, open, close, high: Math.max(...samples) + wick, low: Math.min(...samples) - wick, volume: 520 + Math.abs(Math.sin(time / duration)) * 180 };
}

function klines(symbol: string, interval: string, limit: number, endTime?: number) {
  const duration = seconds[interval] ?? 60;
  const through = endTime !== undefined && Number.isFinite(endTime) ? Math.min(Date.now(), endTime) / 1000 : Date.now() / 1000;
  const lastOpen = Math.floor(through / duration) * duration;
  return Array.from({ length: limit }, (_, index) => {
    const candle = candleAt(symbol, interval, lastOpen - (limit - 1 - index) * duration);
    return [candle.time * 1000, String(candle.open), String(candle.high), String(candle.low), String(candle.close), String(candle.volume), (candle.time + duration) * 1000 - 1, "0", 123, "0", "0", "0"];
  });
}

function ticker(symbol: string) {
  const contract = contractFor(symbol);
  const price = priceAt(symbol, Date.now() / 1000);
  return {
    symbol, lastPrice: String(price), priceChangePercent: String(contract.change),
    quoteVolume: String(contract.quoteVolume), highPrice: String(price * 1.035), lowPrice: String(price * .962),
    volume: String(contract.quoteVolume / price), count: "523410", closeTime: Date.now(),
  };
}

window.fetch = async (input, init) => {
  const url = new URL(input instanceof Request ? input.url : String(input), window.location.href);
  if (url.hostname !== "fapi.binance.com") return nativeFetch(input, init);
  if (init?.signal?.aborted) throw new DOMException("Aborted", "AbortError");
  const symbol = url.searchParams.get("symbol")?.toUpperCase() ?? "BTCUSDT";
  let data: unknown;
  if (url.pathname === "/fapi/v1/exchangeInfo") {
    data = { timezone: "UTC", serverTime: Date.now(), symbols: contracts.map((contract) => ({
      symbol: contract.symbol, baseAsset: contract.baseAsset, quoteAsset: "USDT", status: "TRADING", contractType: "PERPETUAL",
      filters: [{ filterType: "PRICE_FILTER", tickSize: contract.tick }],
    })) };
  } else if (url.pathname === "/fapi/v1/klines") {
    data = klines(symbol, url.searchParams.get("interval") ?? "15m", Math.min(1500, Number(url.searchParams.get("limit") ?? 500)), url.searchParams.has("endTime") ? Number(url.searchParams.get("endTime")) : undefined);
  } else if (url.pathname === "/fapi/v1/ticker/24hr") {
    data = url.searchParams.has("symbol") ? ticker(symbol) : contracts.map((contract) => ticker(contract.symbol));
  } else if (url.pathname === "/fapi/v1/ticker/price") {
    data = { symbol, price: String(priceAt(symbol, Date.now() / 1000)), time: Date.now() };
  } else {
    return new Response(JSON.stringify({ code: -1, msg: "Preview fixture endpoint is not implemented" }), { status: 404, headers: { "Content-Type": "application/json" } });
  }
  return new Response(JSON.stringify(data), { status: 200, headers: { "Content-Type": "application/json" } });
};

class PreviewBinanceSocket extends EventTarget {
  readonly url: string;
  readonly protocol = "";
  readonly extensions = "";
  readonly bufferedAmount = 0;
  binaryType: BinaryType = "blob";
  readyState: number = NativeWebSocket.CONNECTING;
  onopen: ((event: Event) => unknown) | null = null;
  onmessage: ((event: MessageEvent) => unknown) | null = null;
  onerror: ((event: Event) => unknown) | null = null;
  onclose: ((event: CloseEvent) => unknown) | null = null;
  private timer?: number;
  private lastKlineTimes = new Map<string, number>();

  constructor(url: string) {
    super();
    this.url = url;
    window.setTimeout(() => {
      if (this.readyState !== NativeWebSocket.CONNECTING) return;
      this.readyState = NativeWebSocket.OPEN;
      const event = new Event("open");
      this.onopen?.(event);
      this.dispatchEvent(event);
      this.publish();
      this.timer = window.setInterval(() => this.publish(), 2000);
    }, 30);
  }

  private publish() {
    if (this.readyState !== NativeWebSocket.OPEN) return;
    const streams = new URL(this.url).searchParams.get("streams")?.split("/") ?? [];
    for (const stream of streams) {
      const [market, channel] = stream.split("@");
      const symbol = market.toUpperCase();
      const now = Date.now();
      let data: object;
      if (channel === "ticker") {
        data = { e: "24hrTicker", E: now, s: symbol, c: String(priceAt(symbol, now / 1000)), P: String(contractFor(symbol).change) };
      } else if (channel?.startsWith("kline_")) {
        const interval = channel.replace("kline_", "");
        const duration = seconds[interval] ?? 60;
        const time = Math.floor(now / 1000 / duration) * duration;
        const previousTime = this.lastKlineTimes.get(stream);
        if (previousTime !== undefined && previousTime < time) {
          // Deliver actual closed OHLC before the new forming candle, as the exchange does.
          for (let closedTime = Math.max(previousTime, time - duration * 3); closedTime < time; closedTime += duration) {
            const closed = candleAt(symbol, interval, closedTime);
            const closedData = { e: "kline", E: now, s: symbol, k: { t: closedTime * 1000, T: (closedTime + duration) * 1000 - 1, s: symbol, i: interval, o: String(closed.open), h: String(closed.high), l: String(closed.low), c: String(closed.close), v: String(closed.volume), x: true } };
            const closedEvent = new MessageEvent("message", { data: JSON.stringify({ stream, data: closedData }) });
            this.onmessage?.(closedEvent);
            this.dispatchEvent(closedEvent);
          }
        }
        this.lastKlineTimes.set(stream, time);
        const candle = candleAt(symbol, interval, time);
        data = { e: "kline", E: now, s: symbol, k: { t: time * 1000, T: (time + duration) * 1000 - 1, s: symbol, i: interval, o: String(candle.open), h: String(candle.high), l: String(candle.low), c: String(candle.close), v: String(candle.volume), x: false } };
      } else continue;
      const event = new MessageEvent("message", { data: JSON.stringify({ stream, data }) });
      this.onmessage?.(event);
      this.dispatchEvent(event);
    }
  }

  send() { /* The public market streams do not send client messages. */ }

  close(code = 1000, reason = "") {
    if (this.readyState === NativeWebSocket.CLOSED) return;
    this.readyState = NativeWebSocket.CLOSED;
    window.clearInterval(this.timer);
    const event = new CloseEvent("close", { code, reason, wasClean: true });
    this.onclose?.(event);
    this.dispatchEvent(event);
  }
}

window.WebSocket = new Proxy(NativeWebSocket, {
  construct(target, args) {
    const url = String(args[0]);
    if (new URL(url, window.location.href).hostname === "fstream.binance.com") return new PreviewBinanceSocket(url);
    return Reflect.construct(target, args);
  },
});

createRoot(document.getElementById("root")!).render(<App />);

const badge = document.createElement("div");
badge.textContent = "交互验收 · 模拟行情";
badge.setAttribute("role", "status");
Object.assign(badge.style, {
  position: "fixed", bottom: "5px", left: "50%", transform: "translateX(-50%)", zIndex: "9999", pointerEvents: "none",
  padding: "4px 9px", border: "1px solid #997031", borderRadius: "3px", color: "#ffd58b", background: "#302719", font: "10px 'PingFang SC', sans-serif",
});
document.body.append(badge);
