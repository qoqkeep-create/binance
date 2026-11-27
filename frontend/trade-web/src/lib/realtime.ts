import { ensureFreshToken } from "./account.js";
import { websocketPath } from "./runtime.js";
import type { StreamEvent } from "./binance.js";

export interface RealtimeSubscription {
  symbol: string;
  interval: string;
  tickerSymbols?: readonly string[] | (() => readonly string[]);
  handler: (event: StreamEvent) => void;
}

type WireEnvelope = { type?: string; channel?: string; data?: Record<string, unknown> };

/**
 * Single shared market WebSocket. One connection carries the union of all
 * subscriptions; token is refreshed proactively and attached at connect;
 * reconnect uses capped backoff. Removes per-component stream lifecycle races.
 */
class MarketRealtime {
  private subs = new Set<RealtimeSubscription>();
  private socket?: WebSocket;
  private reconnectTimer?: ReturnType<typeof setTimeout>;
  private pingTimer?: ReturnType<typeof setInterval>;
  private restartTimer?: ReturnType<typeof setTimeout>;
  private latencySamples: number[] = [];
  private backoff = 1000;
  private requestId = 0;
  private generation = 0;

  subscribe(sub: RealtimeSubscription): () => void {
    this.subs.add(sub);
    this.scheduleSync();
    return () => {
      this.subs.delete(sub);
      this.scheduleSync();
    };
  }

  // 订阅集合变化只在活连接上重发 subscribe 帧（后端按通道替换 filters），
  // 不再整条重连——重连会造成行情断档（用户报"断断续续经常断开"的根因）。
  private scheduleSync() {
    if (this.restartTimer) clearTimeout(this.restartTimer);
    this.restartTimer = setTimeout(() => {
      if (!this.subs.size) { this.teardown(); return; }
      const socket = this.socket;
      if (socket && socket.readyState === WebSocket.OPEN) this.sendSubscribe(socket);
      else void this.connect();
    }, 120);
  }

  private sendSubscribe(socket: WebSocket) {
    // 通配 "*" 仅客户端分发用；后端 symbols 校验 [A-Z0-9]{2,32}，混入 "*" 会整条订阅被拒。
    const klineSymbols = [...new Set([...this.subs].map((s) => s.symbol).filter((symbol) => symbol !== "*"))];
    // ticker 用空 symbols＝后端通配单 topic 收全量；kline 订阅 1m 实时 feed，
    // 大周期由客户端聚合到对应桶（后端仅推 1m 实时 K 线）。
    socket.send(JSON.stringify({
      version: 1, type: "subscribe", requestId: `web-${++this.requestId}`,
      subscriptions: [
        { channel: "market.ticker", filters: { symbols: [], intervals: [] } },
        { channel: "market.kline", filters: { symbols: klineSymbols, intervals: ["1m"] } },
      ],
    }));
  }

  private teardown() {
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    if (this.pingTimer) clearInterval(this.pingTimer);
    this.pingTimer = undefined;
    const socket = this.socket;
    this.socket = undefined;
    if (socket) {
      socket.onopen = null;
      socket.onmessage = null;
      socket.onclose = null;
      socket.onerror = null;
      try { socket.close(); } catch { /* already closed */ }
    }
  }

  private async connect() {
    this.teardown();
    const generation = ++this.generation;
    if (!this.subs.size) return;
    const token = await ensureFreshToken();
    if (generation !== this.generation || !this.subs.size) return;
    const socket = token ? new WebSocket(websocketPath(), [`bearer.${token}`]) : new WebSocket(websocketPath());
    this.socket = socket;
    socket.onopen = () => {
      if (generation !== this.generation) return;
      this.backoff = 1000;
      this.sendSubscribe(socket);
      this.pingTimer = window.setInterval(() => {
        socket.send(JSON.stringify({ version: 1, type: "ping", requestId: `ping-${++this.requestId}`, timestamp: Date.now() }));
      }, 2000);
    };
    socket.onmessage = (message) => {
      if (generation !== this.generation) return;
      try {
        const envelope = JSON.parse(message.data as string) as WireEnvelope;
        const data = envelope.data ?? {};
        if (envelope.type === "pong") {
          const sent = Number(data.clientTimestamp);
          if (Number.isFinite(sent) && sent > 0) {
            this.latencySamples.push(Date.now() - sent);
            if (this.latencySamples.length > 3) this.latencySamples.shift();
            const sorted = [...this.latencySamples].sort((a, b) => a - b);
            this.broadcast({ type: "latency", ms: sorted[Math.floor(sorted.length / 2)] });
          }
          return;
        }
        if (envelope.type !== "event") return;
        const symbol = String(data.symbol ?? "");
        if (envelope.channel === "market.ticker") {
          const price = Number(data.lastPrice);
          const change = Number(data.priceChangePercent24h);
          for (const sub of this.subs) {
            const filter = typeof sub.tickerSymbols === "function" ? sub.tickerSymbols() : sub.tickerSymbols;
            const wanted = filter?.length ? filter.includes(symbol) : sub.symbol === symbol || sub.symbol === "*";
            if (wanted) sub.handler({ type: "ticker", symbol, price, changePercent: change, eventTime: Number(data.eventTime) });
          }
        } else if (envelope.channel === "market.kline") {
          for (const sub of this.subs) {
            if (sub.symbol !== "*" && sub.symbol !== symbol) continue;
            sub.handler({
              type: "kline", symbol,
              candle: {
                time: Math.floor(Number(data.openTime) / 1000),
                open: Number(data.openPrice), high: Number(data.highPrice),
                low: Number(data.lowPrice), close: Number(data.closePrice), volume: Number(data.volume),
              },
              closed: data.closed === true, eventTime: Number(data.eventTime),
            });
          }
        }
      } catch { /* ignore malformed frame */ }
    };
    socket.onclose = () => {
      if (generation !== this.generation) return;
      this.latencySamples = [];
      this.broadcast({ type: "disconnected" });
      const delay = this.backoff;
      this.backoff = Math.min(15_000, this.backoff * 2);
      this.reconnectTimer = setTimeout(() => void this.connect(), delay);
    };
    socket.onerror = () => { /* onclose follows */ };
  }

  private broadcast(event: StreamEvent) {
    for (const sub of this.subs) sub.handler(event);
  }
}

export const marketRealtime = new MarketRealtime();