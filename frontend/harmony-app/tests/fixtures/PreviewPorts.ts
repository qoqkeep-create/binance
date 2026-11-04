import type { HttpRequest, HttpResponse, Transport, Vault, PreferenceStore, RuntimeClock, SocketPort, SocketCallbacks } from '../../entry/src/main/ets/core/Ports';
import { DataValue } from '../../entry/src/main/ets/core/Json';

export let PREVIEW_SCENE = 'market';
export let PREVIEW_THEME = 'dark';
export let PREVIEW_REGISTRATION = 'open';
const ORIGIN = 'https://preview.example.invalid/';
const USER = { id: 'ui-preview', email: 'qa@example.invalid' };
const SYMBOLS: string[] = ['BTCUSDT', 'ETHUSDT', 'SOLUSDT', 'BNBUSDT', 'XRPUSDT', 'DOGEUSDT', 'ADAUSDT', 'AVAXUSDT', 'LINKUSDT', 'SUIUSDT', '1000SHIBUSDT', 'NEWUSDT'];
const DEFAULTS: string[] = SYMBOLS.slice(0, 11);

export class PreviewVault implements Vault {
  private values: Map<string, string> = new Map();
  constructor() { if (PREVIEW_SCENE !== 'auth') this.values.set('session', JSON.stringify({ origin: ORIGIN, token: 'local-ui-fixture', cookie: '', user: USER })); }
  async read(key: string): Promise<string> { return this.values.get(key) || ''; }
  async write(key: string, value: string): Promise<void> { this.values.set(key, value); }
  async remove(key: string): Promise<void> { this.values.delete(key); }
}
export class PreviewPreferences implements PreferenceStore {
  private values: Map<string, string> = new Map();
  read(key: string, fallback: string): string { return key === 'api-origin' ? ORIGIN : key === 'appearance' ? PREVIEW_THEME : this.values.get(key) || fallback; }
  write(key: string, value: string): void { this.values.set(key, value); }
}
export class PreviewClock implements RuntimeClock {
  private sequence: number = 0;
  now(): number { return Date.now(); }
  delay(ms: number): Promise<void> { return new Promise<void>((resolve: () => void) => { setTimeout(resolve, ms); }); }
  id(): string { return 'ui-fixture-' + ++this.sequence; }
}
export class PreviewTransport implements Transport {
  private scene: string;
  constructor(scene: string = PREVIEW_SCENE) { this.scene = scene; }
  private watchlist: string[] = DEFAULTS.slice();
  async send(request: HttpRequest): Promise<HttpResponse> {
    if (!request.url.startsWith(ORIGIN)) throw new Error('Preview cannot access external origins');
    const route = request.url.slice(ORIGIN.length).split('?')[0];
    if (request.method === 'POST' && route === 'api/market/watchlist') {
      this.watchlist = DataValue.parse(request.body).get('symbols').rows().map((s: DataValue) => s.text());
      return this.response(DataValue.object());
    }
    if (this.scene.startsWith('chart') && request.method === 'POST') {
      if (route === 'v1/trade/capital/precheck') return this.response(DataValue.object({ status: 'ready' }));
      if (route === 'v1/trade/ema-check') return this.response(DataValue.object({ check_id: 'preview-only', symbol: 'BTCUSDT', side: 'long', stop_loss_price: DataValue.parse(request.body).value('stop_loss_price'), has_any_matching_interval: true, expires_at: new Date(Date.now() + 180000).toISOString() }));
    }
    if (request.method !== 'GET') throw new Error('离线界面预览禁止执行账户、交易和资金操作');
    if (route === 'api/auth/me') return this.response(DataValue.object(USER));
    if (route === 'v1/auth/admin-settings') {
      await new PreviewClock().delay(200);
      if (PREVIEW_REGISTRATION === 'unavailable') throw new Error('fixture unavailable');
      return this.response(DataValue.object({ open_registration: PREVIEW_REGISTRATION === 'open' }));
    }
    if (route === 'api/market/watchlist/defaults') return this.response(DataValue.object({ quoteAsset: 'USDT', symbols: this.watchlist, availableSymbols: SYMBOLS, isCustomized: false }));
    if (route === 'api/market/symbols') return this.response(DataValue.object({ quoteAsset: 'USDT', symbols: SYMBOLS }));
    if (route === 'api/market/tickers') return this.response(DataValue.object({ items: SYMBOLS.slice(0, -1).map((symbol: string, index: number) => ({ symbol: symbol, lastPrice: ['93245.67', '3256.789', '158.45', '612.34', '2.3456', '0.123456', '0.6543', '25.345', '14.456', '2.1234', '0.0123456'][index], priceChangePercent24h: index % 3 === 0 ? 2.345 : -1.234, quoteVolume24h: 123456789 / (index + 1), eventTime: 1000 })) }));
    if (route === 'api/market/klines') {
      const query = request.url.split('?')[1] || '';
      const interval = query.split('&').find((v: string) => v.startsWith('interval='))?.slice(9) || '1h';
      const units: Record<string, number> = { 'm': 60000, 'h': 3600000, 'd': 86400000, 'w': 604800000 };
      const step = Number(interval.slice(0, -1)) * units[interval.slice(-1)];
      const end = Math.floor(1793664000000 / step) * step;
      const rows = Array.from({ length: 320 }, (_value: Object, i: number) => {
        const open = 92000 + i * 5 + Math.sin(i * 0.2) * 500; const close = open + Math.cos(i * 0.4) * 90;
        return { openTime: end - (319 - i) * step, openPrice: open, highPrice: Math.max(open, close) + 70, lowPrice: Math.min(open, close) - 60, closePrice: close, volume: 100 + i % 30 * 20, quoteVolume: (100 + i % 30 * 20) * open, closed: i < 319, tradingData: { openInterest: 10000 + i * 10, topLongAccount: 0.56, topShortAccount: 0.44, topLongPosition: 0.6, topShortPosition: 0.4, globalLongAccount: 0.52, globalShortAccount: 0.48, takerBuyVolume: 100 + i, takerSellVolume: 150 + i, basis: i % 20, basisRate: 0.0001 } };
      });
      return this.response(DataValue.object({ items: rows, hasMoreHistory: false, historyPending: false }));
    }
    if (route === 'v1/position/list') {
      if (this.scene === 'chart-error') throw new Error('preview position read failure');
      return this.response(new DataValue(this.scene === 'chart-held' ? [{ id: 'held-fixture', symbol: 'BTCUSDT', status: 0, side: 0, size: '0.01', exchange_size: '0.01', open_price: '93000', stop_loss_price: '92000', position_amount: '930', stop_loss_amount: '10', estimated_total_fee: '0.93', created_at: '2026-11-02T16:00:00Z' }] : []));
    }
    if (route === 'v1/trade/symbol/info') return this.response(DataValue.object({ max_leverage: 125 }));
    if (route === 'v1/trade/leverage-brackets') return this.response(DataValue.object({ symbol: 'BTCUSDT', brackets: [{ leverage: 25, max_open_amount: '250000' }, { leverage: 50, max_open_amount: '125000' }, { leverage: 100, max_open_amount: '50000' }] }));
    if (route === 'v1/strategy/list') return this.response(new DataValue(this.scene.startsWith('chart') ? [{ id: '1', name: '分层止盈', is_active: true, levels: [{ profitRR: '1.5', reducePosition: '50' }, { profitRR: '3', reducePosition: '50' }] }] : []));
    if (route === 'v1/account/profile') return this.response(DataValue.object({ email: USER.email }));
    if (route === 'v1/account/version') return this.response(DataValue.object({ version: 'UI preview' }));
    if (this.scene.startsWith('chart') && route === 'v1/api/info') return this.response(DataValue.object({ alias: 'preview-local-only' }));
    if (this.scene.startsWith('chart') && route === 'v1/account/info') return this.response(DataValue.object({ stop_loss_amount: '20' }));
    if (['v1/api/info', 'v1/account/info'].includes(route)) return this.response(DataValue.object());
    return this.response(DataValue.object({ items: [], data: [] }));
  }
  private response(value: DataValue): HttpResponse { return { status: 200, body: DataValue.object({ code: 200, data: value.raw }).json(), cookies: [] }; }
}
export class PreviewSocket implements SocketPort {
  private callbacks: SocketCallbacks | null = null;
  private timer: number = -1;
  connect(_url: string, _headers: Record<string, string>, callbacks: SocketCallbacks): void {
    this.close(); this.callbacks = callbacks;
    setTimeout(() => {
      if (this.callbacks !== callbacks) return;
      callbacks.opened(); callbacks.message(JSON.stringify({ type: 'ready', data: { capabilities: [] } }));
    }, 50);
    this.timer = setTimeout(() => {
      if (this.callbacks === callbacks) callbacks.message(JSON.stringify({ type: 'event', channel: 'market.ticker', data: { symbol: 'BTCUSDT', lastPrice: '93888.88', quoteVolume24h: 123456789, priceChangePercent24h: 3.456, eventTime: 2000 } }));
    }, 4000);
  }
  send(value: string): void {
    const event = DataValue.parse(value); const callbacks = this.callbacks;
    if (event.value('type') === 'ping') setTimeout(() => { if (callbacks && this.callbacks === callbacks) callbacks.message(JSON.stringify({ type: 'pong', requestId: event.value('requestId') })); }, 28);
  }
  close(): void { this.callbacks = null; if (this.timer >= 0) clearTimeout(this.timer); this.timer = -1; }
}
