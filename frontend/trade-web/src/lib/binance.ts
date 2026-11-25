/** Data adapters for the integrated Django market service. */

import { getAccessToken, accountApi } from "./account.js";
import { apiPath, websocketPath } from "./runtime.js";

export type MarketGroup = "top20" | "alts";

export interface FuturesSymbol { symbol: string; baseAsset: string; quoteAsset: string; status: string; contractType: string; onboardDate?: number }
export interface Ticker24h { symbol: string; lastPrice: number; priceChangePercent: number; quoteVolume: number; highPrice: number; lowPrice: number; volume: number; count?: number; eventTime?: number }
export interface Candle { time: number; open: number; high: number; low: number; close: number; volume: number }
export interface MarketRow extends Ticker24h { baseAsset: string; rank?: number }
interface Envelope<T> { code: number; message?: string; data: T }
interface TickerPayload { symbol: string; lastPrice: number | string; quoteVolume24h: number | string; priceChangePercent24h: number | string; eventTime?: number }
interface KlinePayload { symbol: string; interval: string; items: Array<Record<string, unknown>> }

const toNumber = (value: unknown) => { const parsed = typeof value === "number" ? value : Number(value); return Number.isFinite(parsed) ? parsed : 0; };
const mapTicker = (row: TickerPayload): Ticker24h => ({ symbol: row.symbol, lastPrice: toNumber(row.lastPrice), priceChangePercent: toNumber(row.priceChangePercent24h), quoteVolume: toNumber(row.quoteVolume24h), highPrice: 0, lowPrice: 0, volume: 0, eventTime: row.eventTime });
const mapCandle = (row: Record<string, unknown>): Candle => ({ time: Math.floor(toNumber(row.openTime) / 1000), open: toNumber(row.openPrice), high: toNumber(row.highPrice), low: toNumber(row.lowPrice), close: toNumber(row.closePrice), volume: toNumber(row.volume) });

async function request<T>(path: string, init: RequestInit = {}, retry = true): Promise<T> {
  const headers = new Headers(init.headers);
  headers.set("accept", "application/json");
  const token = getAccessToken();
  if (token) headers.set("Authorization", `Bearer ${token}`);
  const response = await fetch(apiPath(path.replace(/^\/api/, "")), { ...init, headers, credentials: "include", signal: init.signal ?? AbortSignal.timeout(15_000) });
  if (response.status === 401 && retry) {
    try { await accountApi.session(init.signal ?? undefined); return request<T>(path, init, false); } catch { /* report the original failure below */ }
  }
  let payload: unknown;
  try { payload = await response.json(); } catch { throw new Error(`行情服务 ${response.status}`); }
  if (!response.ok || !payload || typeof payload !== "object" || (payload as Envelope<unknown>).code !== 200) {
    const message = payload && typeof payload === "object" && typeof (payload as { message?: unknown }).message === "string" ? (payload as { message: string }).message : `行情服务 ${response.status}`;
    throw new Error(message);
  }
  return (payload as Envelope<T>).data;
}

export async function getPerpetualSymbols(): Promise<FuturesSymbol[]> {
  const data = await request<{ symbols: string[] }>("/api/market/symbols");
  return (data.symbols ?? []).map((symbol) => ({ symbol, baseAsset: symbol.replace(/USDT$/, ""), quoteAsset: "USDT", status: "TRADING", contractType: "PERPETUAL" }));
}
export async function get24hTickers(signal?: AbortSignal): Promise<Ticker24h[]> {
  const data = await request<{ tickers?: TickerPayload[]; items?: TickerPayload[] }>("/api/market/tickers", { signal });
  return (data.tickers ?? data.items ?? []).map(mapTicker);
}
export async function getMarketGroups(): Promise<{ top20: MarketRow[]; alts: MarketRow[]; all: MarketRow[] }> {
  const [symbols, tickers] = await Promise.all([getPerpetualSymbols(), get24hTickers()]);
  const available = new Set(symbols.map((item) => item.symbol));
  const all = tickers.filter((ticker) => available.has(ticker.symbol)).map((ticker) => ({ ...ticker, baseAsset: ticker.symbol.replace(/USDT$/, "") })).sort((a, b) => b.quoteVolume - a.quoteVolume);
  const top20 = all.slice(0, 20).map((row, index) => ({ ...row, rank: index + 1 }));
  const topSymbols = new Set(top20.map((row) => row.symbol));
  return { top20, alts: all.filter((row) => !topSymbols.has(row.symbol)), all };
}
export async function getKlines(symbol: string, interval = "15m", limit = 500, signal?: AbortSignal, beforeOpenTime?: number): Promise<Candle[]> {
  const query = new URLSearchParams({ symbol: symbol.toUpperCase(), interval, limit: String(Math.min(1500, Math.max(1, limit))) });
  if (beforeOpenTime !== undefined) query.set("beforeOpenTime", String(Math.floor(beforeOpenTime)));
  const data = await request<KlinePayload>(`/api/market/klines?${query}`, { signal });
  return (data.items ?? []).map(mapCandle).filter((candle) => candle.time > 0 && candle.close > 0 && candle.high >= candle.low);
}

export type StreamEvent =
  | { type: "ticker"; symbol: string; price: number; changePercent: number; eventTime?: number }
  | { type: "kline"; symbol: string; candle: Candle; closed: boolean; eventTime?: number }
  | { type: "disconnected" }
  | { type: "error"; error: Event | Error };

/** Reconnecting subscription to the integrated market fanout. */
export class BinanceStream {
  private socket?: WebSocket;
  private reconnectTimer?: ReturnType<typeof setTimeout>;
  private stopped = false;
  private requestId = 0;
  constructor(private readonly symbol: string, private readonly interval: string, private readonly onEvent: (event: StreamEvent) => void) {}
  connect() { this.stopped = false; this.open(); }
  private open() {
    if (this.stopped) return;
    const token = getAccessToken();
    this.socket = token ? new WebSocket(websocketPath(), [`bearer.${token}`]) : new WebSocket(websocketPath());
    this.socket.onopen = () => {
      const id = `web-${++this.requestId}`;
      this.socket?.send(JSON.stringify({ version: 1, type: "subscribe", requestId: id, subscriptions: [
        { channel: "market.ticker", filters: { symbols: [this.symbol], intervals: [] } },
        { channel: "market.kline", filters: { symbols: [this.symbol], intervals: [this.interval] } },
      ] }));
    };
    this.socket.onmessage = (message) => {
      try {
        const envelope = JSON.parse(message.data as string) as { type?: string; channel?: string; data?: Record<string, unknown> };
        const data = envelope.data ?? {};
        const symbol = String(data.symbol ?? "");
        if (envelope.type !== "event" || symbol !== this.symbol) return;
        if (envelope.channel === "market.ticker") this.onEvent({ type: "ticker", symbol, price: toNumber(data.lastPrice), changePercent: toNumber(data.priceChangePercent24h), eventTime: toNumber(data.eventTime) });
        else if (envelope.channel === "market.kline") this.onEvent({ type: "kline", symbol, candle: mapCandle(data), closed: data.closed === true, eventTime: toNumber(data.eventTime) });
      } catch (error) { this.onEvent({ type: "error", error: error as Error }); }
    };
    this.socket.onerror = (error) => this.onEvent({ type: "error", error });
    this.socket.onclose = (event) => {
      if (this.stopped) return;
      this.onEvent({ type: "disconnected" });
      const recover = event.code === 4401 ? accountApi.session().catch(() => undefined) : Promise.resolve();
      void recover.finally(() => { if (!this.stopped) this.reconnectTimer = setTimeout(() => this.open(), 2000); });
    };
  }
  close() { this.stopped = true; if (this.reconnectTimer) clearTimeout(this.reconnectTimer); this.socket?.close(); }
}
