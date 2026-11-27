import { ensureFreshToken } from "./account.js";
import { websocketPath } from "./runtime.js";
import type { StreamEvent } from "./binance.js";

export interface RealtimeSubscription {
  symbol: string;
  interval: string;
  tickerSymbols?: readonly string[] | (() => readonly string[]);
  handler: (event: StreamEvent) => void;
}

type WireEnvelope = { type?: string; channel?: string; sequence?: number; closedSequence?: number; data?: Record<string, unknown> };
type SocketKind = "ticker" | "kline";

interface SocketState {
  socket?: WebSocket;
  reconnectTimer?: ReturnType<typeof setTimeout>;
  pingTimer?: ReturnType<typeof setInterval>;
  generation: number;
  backoff: number;
}

/**
 * One shared Web realtime client backed by two physical sockets. The ticker
 * burst cannot occupy the selected-symbol K-line socket, while subscribers
 * and authentication remain shared at the application level.
 */
class MarketRealtime {
  private subs = new Set<RealtimeSubscription>();
  private sockets: Record<SocketKind, SocketState> = {
    ticker: { generation: 0, backoff: 1000 },
    kline: { generation: 0, backoff: 1000 },
  };
  private restartTimer?: ReturnType<typeof setTimeout>;
  private latencySamples: number[] = [];
  private requestId = 0;
  private klineSequences = new Map<string, number>();
  private closedKlineSequences = new Map<string, number>();

  subscribe(sub: RealtimeSubscription): () => void {
    this.subs.add(sub);
    this.scheduleSync();
    return () => {
      this.subs.delete(sub);
      this.scheduleSync();
    };
  }

  private scheduleSync() {
    if (this.restartTimer) clearTimeout(this.restartTimer);
    this.restartTimer = setTimeout(() => {
      this.restartTimer = undefined;
      if (!this.subs.size) {
        this.teardown("ticker");
        this.teardown("kline");
        return;
      }
      this.syncSocket("ticker");
      this.syncSocket("kline");
    }, 120);
  }

  private syncSocket(kind: SocketKind) {
    const state = this.sockets[kind];
    const socket = state.socket;
    if (socket?.readyState === WebSocket.OPEN) {
      this.sendSubscribe(kind, socket);
      return;
    }
    if (!socket || socket.readyState === WebSocket.CLOSED) void this.connect(kind);
  }

  private sendSubscribe(kind: SocketKind, socket: WebSocket) {
    if (kind === "ticker") {
      socket.send(JSON.stringify({
        version: 1, type: "subscribe", requestId: `web-${++this.requestId}`,
        subscriptions: [{ channel: "market.ticker.batch", filters: { symbols: [], intervals: [] } }],
      }));
      return;
    }
    const klineSymbols = [...new Set([...this.subs]
      .map((sub) => sub.symbol)
      .filter((symbol) => symbol !== "*"))];
    socket.send(JSON.stringify({
      version: 1, type: "subscribe", requestId: `web-${++this.requestId}`,
      subscriptions: [{ channel: "market.kline", filters: { symbols: klineSymbols, intervals: ["1m"] } }],
    }));
  }

  private teardown(kind: SocketKind) {
    const state = this.sockets[kind];
    if (state.reconnectTimer) clearTimeout(state.reconnectTimer);
    if (state.pingTimer) clearInterval(state.pingTimer);
    state.reconnectTimer = undefined;
    state.pingTimer = undefined;
    const socket = state.socket;
    state.socket = undefined;
    if (socket) {
      socket.onopen = null;
      socket.onmessage = null;
      socket.onclose = null;
      socket.onerror = null;
      try { socket.close(); } catch { /* already closed */ }
    }
  }

  private async connect(kind: SocketKind) {
    const state = this.sockets[kind];
    this.teardown(kind);
    const generation = ++state.generation;
    if (!this.subs.size) return;
    const token = await ensureFreshToken();
    if (generation !== state.generation || !this.subs.size) return;
    const socket = token ? new WebSocket(websocketPath(), [`bearer.${token}`]) : new WebSocket(websocketPath());
    state.socket = socket;
    socket.onopen = () => {
      if (generation !== state.generation) return;
      state.backoff = 1000;
      if (kind === "kline") {
        this.klineSequences.clear();
        this.closedKlineSequences.clear();
      }
      this.sendSubscribe(kind, socket);
      state.pingTimer = window.setInterval(() => {
        socket.send(JSON.stringify({ type: "ping", requestId: `ping-${++this.requestId}`, timestamp: Date.now() }));
      }, 2000);
    };
    socket.onmessage = (message) => {
      if (generation !== state.generation) return;
      try {
        const envelope = JSON.parse(message.data as string) as WireEnvelope;
        const data = envelope.data ?? {};
        if (envelope.type === "pong") {
          if (kind === "ticker") this.receiveLatency(data);
          return;
        }
        if (envelope.type !== "event") return;
        if (kind === "ticker" && envelope.channel === "market.ticker.batch") {
          this.dispatchTickerBatch(data);
        } else if (kind === "kline" && envelope.channel === "market.kline") {
          this.dispatchKline(envelope, data);
        }
      } catch { /* ignore malformed frame */ }
    };
    socket.onclose = () => {
      if (generation !== state.generation) return;
      state.socket = undefined;
      state.pingTimer = undefined;
      if (kind === "kline") {
        this.klineSequences.clear();
        this.closedKlineSequences.clear();
      }
      if (kind === "ticker") this.latencySamples = [];
      this.broadcast({ type: "disconnected" });
      const delay = state.backoff;
      state.backoff = Math.min(15_000, state.backoff * 2);
      state.reconnectTimer = setTimeout(() => {
        state.reconnectTimer = undefined;
        void this.connect(kind);
      }, delay);
    };
    socket.onerror = () => { /* onclose follows */ };
  }

  private receiveLatency(data: Record<string, unknown>) {
    const sent = Number(data.clientTimestamp);
    if (!Number.isFinite(sent) || sent <= 0) return;
    this.latencySamples.push(Date.now() - sent);
    if (this.latencySamples.length > 3) this.latencySamples.shift();
    const sorted = [...this.latencySamples].sort((a, b) => a - b);
    this.broadcast({ type: "latency", ms: sorted[Math.floor(sorted.length / 2)] });
  }

  private dispatchTicker(data: Record<string, unknown>) {
    const symbol = String(data.symbol ?? "");
    const price = Number(data.lastPrice);
    const change = Number(data.priceChangePercent24h);
    for (const sub of this.subs) {
      const filter = typeof sub.tickerSymbols === "function" ? sub.tickerSymbols() : sub.tickerSymbols;
      const wanted = filter?.length ? filter.includes(symbol) : sub.symbol === symbol || sub.symbol === "*";
      if (wanted) sub.handler({ type: "ticker", symbol, price, changePercent: change, eventTime: Number(data.eventTime) });
    }
  }

  private dispatchTickerBatch(data: Record<string, unknown>) {
    const eventTime = Number(data.eventTime);
    const items = Array.isArray(data.items) ? data.items : [];
    for (const item of items) {
      if (!item || typeof item !== "object") continue;
      this.dispatchTicker({ ...(item as Record<string, unknown>), eventTime: Number((item as Record<string, unknown>).eventTime ?? eventTime) });
    }
  }

  private dispatchKline(envelope: WireEnvelope, data: Record<string, unknown>) {
    const symbol = String(data.symbol ?? "");
    const interval = String(data.interval ?? "1m");
    const closed = data.closed === true;
    const sequence = Number(envelope.sequence);
    const sequenceKey = `${symbol}:${interval}`;
    const previous = this.klineSequences.get(sequenceKey);
    if (Number.isFinite(sequence) && sequence > 0) {
      if (previous !== undefined && sequence <= previous) return;
      this.klineSequences.set(sequenceKey, sequence);
    }
    const closedSequence = Number(envelope.closedSequence);
    const previousClosed = this.closedKlineSequences.get(sequenceKey);
    if (closed && Number.isFinite(closedSequence) && closedSequence > 0) {
      if (previousClosed !== undefined && closedSequence > previousClosed + 1) {
        this.broadcast({ type: "gap", symbol, interval, expected: previousClosed + 1, received: closedSequence });
      }
      if (previousClosed === undefined || closedSequence > previousClosed) {
        this.closedKlineSequences.set(sequenceKey, closedSequence);
      }
    }
    for (const sub of this.subs) {
      if (sub.symbol !== "*" && sub.symbol !== symbol) continue;
      sub.handler({
        type: "kline", symbol,
        candle: {
          time: Math.floor(Number(data.openTime) / 1000),
          open: Number(data.openPrice), high: Number(data.highPrice),
          low: Number(data.lowPrice), close: Number(data.closePrice), volume: Number(data.volume),
        },
        closed, eventTime: Number(data.eventTime),
      });
    }
  }

  private broadcast(event: StreamEvent) {
    for (const sub of this.subs) sub.handler(event);
  }
}

export const marketRealtime = new MarketRealtime();
