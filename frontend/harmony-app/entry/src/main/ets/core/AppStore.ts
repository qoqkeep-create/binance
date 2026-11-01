import { DataValue, ApiError } from './Json';
import { Session, DEFAULT_API } from './Session';
import { CapitalWorkflow, BulkClose } from './Workflows';
import { Commands } from './Commands';
import { Realtime } from './Realtime';
import { Ticker, Candle, CandleStore } from './Market';
import type { PreferenceStore, RuntimeClock } from './Ports';

export class AppStore {
  session: Session;
  commands: Commands;
  capital: CapitalWorkflow;
  bulk: BulkClose;
  realtime: Realtime;
  preferences: PreferenceStore;
  clock: RuntimeClock;
  initialized: boolean = false;
  foreground: boolean = true;
  busy: boolean = false;
  notice: string = '';
  account: DataValue = new DataValue();
  profile: DataValue = new DataValue();
  binding: DataValue = new DataValue();
  version: DataValue = new DataValue();
  strategies: DataValue[] = [];
  tickers: Ticker[] = [];
  watchlist: string[] = [];
  selectedSymbol: string = 'BTCUSDT';
  interval: string = '1h';
  chart: CandleStore = new CandleStore();
  chartPending: boolean = false;
  chartHasNext: boolean = true;
  chartLoading: boolean = false;
  chartRevision: number = 0;
  accountRevision: number = 0;
  signalRevision: number = 0;
  onChange: () => void = () => {};
  private chartGeneration: number = 0;
  private historyRequest: number = 0;
  private accountRefreshPending: boolean = false;
  private chartRefreshPending: boolean = false;
  private tickerPaintPending: boolean = false;
  private accountRequest: number = 0;
  private marketLoadGeneration: number = 0;
  constructor(session: Session, commands: Commands, realtime: Realtime, preferences: PreferenceStore, clock: RuntimeClock, capital: CapitalWorkflow, bulk: BulkClose) {
    this.session = session; this.commands = commands; this.realtime = realtime; this.preferences = preferences; this.clock = clock; this.capital = capital; this.bulk = bulk;
    this.realtime.onChange = (): void => this.changed();
    this.realtime.onEvent = (event: DataValue): void => this.receive(event);
  }
  get isBound(): boolean { return !this.binding.empty(); }
  get riskAmount(): string { return this.account.value('stop_loss_amount', ''); }
  changed(): void { this.onChange(); }
  report(error: Error): void { if (!this.session.authenticated) this.realtime.stop(); if ((error as ApiError).code !== -1) { this.notice = error.message || '请求失败'; this.changed(); } }
  async initialize(): Promise<void> {
    try { await this.session.restore(this.preferences.read('api-origin', DEFAULT_API)); }
    catch (e) { this.report(e as Error); }
    this.initialized = true;
    if (this.session.authenticated) this.start(); this.changed();
  }
  start(): void {
    this.foreground = true;
    if (!this.session.authenticated) return;
    try { this.watchlist = DataValue.parse(this.preferences.read(this.userKey('watchlist'), '[]')).rows().map((v: DataValue) => v.text()); } catch (_) { this.watchlist = []; }
    this.realtime.start(); this.loadTickers(); this.refreshAccount(); this.commands.load().catch((e: Error) => this.report(e));
  }
  background(): void { this.foreground = false; this.realtime.stop(); this.marketLoadGeneration++; this.changed(); }
  async login(account: string, password: string, register: boolean): Promise<void> {
    if (this.busy) return; this.busy = true; this.notice = ''; this.changed();
    try { await this.session.authenticate(account, password, register); this.start(); }
    catch (e) { this.report(e as Error); } finally { this.busy = false; this.changed(); }
  }
  async logout(): Promise<void> { this.realtime.stop(); this.clearAccount(); this.tickers = []; this.chart.clear(); this.chartGeneration++; await this.session.logout(); this.changed(); }
  async changeServer(origin: string): Promise<void> {
    await this.logout(); this.preferences.write('api-origin', origin); await this.session.restore(origin); this.changed();
  }
  switchMode(mode: string): void {
    this.realtime.stop(); this.session.setMode(mode); this.clearAccount(); this.chart.clear(); this.chartGeneration++;
    this.start(); this.changed();
  }
  private clearAccount(): void {
    this.account = new DataValue(); this.profile = new DataValue(); this.binding = new DataValue(); this.strategies = [];
    this.accountRefreshPending = false; this.accountRevision++;
  }
  userKey(key: string): string { return this.session.baseUrl + ':' + this.session.user.value('id', '') + ':' + key; }
  toggleWatch(symbol: string): void {
    this.watchlist = this.watchlist.includes(symbol) ? this.watchlist.filter((v: string) => v !== symbol) : this.watchlist.concat([symbol]);
    this.preferences.write(this.userKey('watchlist'), JSON.stringify(this.watchlist)); this.changed();
  }
  async loadTickers(): Promise<void> {
    const generation = ++this.marketLoadGeneration;
    try {
      const value = await this.session.request('/api/market/tickers');
      if (generation !== this.marketLoadGeneration) return;
      const current = new Map<string, Ticker>(); for (const ticker of this.tickers) current.set(ticker.symbol, ticker);
      for (const row of value.items()) { const ticker = Ticker.from(row); const old = current.get(ticker.symbol); if (!old || old.eventTime <= ticker.eventTime) current.set(ticker.symbol, ticker); }
      this.tickers = Array.from(current.values());
      if (!this.preferences.read(this.userKey('watchlist'), '')) {
        const defaults = await this.session.request('/api/market/watchlist/defaults');
        if (generation !== this.marketLoadGeneration) return;
        this.watchlist = defaults.get('symbols').rows().map((v: DataValue) => v.text());
        this.preferences.write(this.userKey('watchlist'), JSON.stringify(this.watchlist));
      }
      this.changed();
    } catch (e) { this.report(e as Error); }
  }
  async refreshAccount(): Promise<void> {
    const scope = this.session.scope; const request = ++this.accountRequest;
    try {
      const binding = await this.session.request('/v1/api/info');
      if (scope !== this.session.scope || request !== this.accountRequest) return;
      if (await this.session.observeBinding(binding)) { this.clearAccount(); this.realtime.stop(); if (this.foreground) this.realtime.start(); }
      this.binding = binding;
      const freshScope = this.session.scope;
      const values = await Promise.all([this.session.request('/v1/account/info'), this.session.request('/v1/account/profile'), this.session.request('/v1/strategy/list'), this.session.request('/v1/account/version')]);
      if (freshScope !== this.session.scope || request !== this.accountRequest) return;
      this.account = values[0]; this.profile = values[1]; this.strategies = values[2].rows(); this.version = values[3]; this.accountRevision++; this.changed();
    } catch (e) { this.report(e as Error); }
  }
  selectChart(symbol: string, interval: string = '1h'): void {
    this.selectedSymbol = symbol; this.interval = interval; this.chartGeneration++; this.historyRequest++;
    this.chart.clear(); this.chartPending = false; this.chartHasNext = true; this.chartLoading = false;
    this.realtime.setChart(symbol, interval); this.loadHistory(false); this.changed();
  }
  closeChart(): void { this.chartGeneration++; this.historyRequest++; this.chartLoading = false; this.realtime.setChart('', this.interval); }
  async loadHistory(older: boolean): Promise<void> {
    if (this.chartLoading || (older && !this.chartHasNext)) return;
    const generation = this.chartGeneration; const request = ++this.historyRequest; const scope = this.session.scope;
    this.chartLoading = true; this.changed();
    let path = '/api/market/klines?symbol=' + encodeURIComponent(this.selectedSymbol) + '&interval=' + this.interval + '&limit=500&tradingData=openInterest,topAccountRatio,topPositionRatio,globalAccountRatio,buySellVolume,basis';
    if (older && this.chart.candles.length) path += '&beforeOpenTime=' + this.chart.candles[0].time;
    try {
      const value = await this.session.request(path);
      if (generation !== this.chartGeneration || request !== this.historyRequest || scope !== this.session.scope) return;
      const candles = value.items().map((v: DataValue) => Candle.from(v));
      this.chart.merge(candles); this.chartPending = value.get('historyPending').flag();
      this.chartHasNext = value.get('hasMoreHistory').flag() && this.chart.candles.length < 5000;
      this.chartRevision++; this.changed();
    } catch (e) { this.report(e as Error); }
    finally { if (generation === this.chartGeneration && request === this.historyRequest) { this.chartLoading = false; this.changed(); } }
  }
  async preflight(purpose: string): Promise<void> {
    const result = await this.session.request('/v1/trade/capital/precheck', 'POST', DataValue.object({ purpose: purpose }));
    if (!['ready', 'not_required'].includes(result.value('status'))) throw new Error(result.value('message', '请先在我的页面处理开仓资金'));
  }
  private receive(event: DataValue): void {
    const type = event.value('type'); const channel = event.value('channel', ''); const data = event.get('data');
    if (type === 'ready') { this.loadTickers(); this.scheduleAccountRefresh(); if (this.realtime.symbol) this.scheduleChartRefresh(); }
    if (type === 'ack' && this.chartPending && this.realtime.symbol) this.scheduleChartRefresh();
    if (type !== 'event') return;
    if (channel === 'market.ticker') {
      const ticker = Ticker.from(data); const index = this.tickers.findIndex((v: Ticker) => v.symbol === ticker.symbol);
      if (index >= 0 && ticker.eventTime >= this.tickers[index].eventTime) this.tickers[index] = ticker;
      else if (index < 0 && ticker.symbol) this.tickers.push(ticker);
      this.scheduleTickerPaint();
    }
    if (channel === 'market.kline' && data.value('symbol') === this.selectedSymbol && data.value('interval') === this.interval) {
      this.chart.merge([Candle.from(data, true)]); this.chartRevision++; this.changed();
    }
    if (channel === 'market.history' && data.value('symbol') === this.selectedSymbol && data.value('interval') === this.interval) this.scheduleChartRefresh();
    if (channel === 'strategy.signal') { this.signalRevision++; this.changed(); }
    if (channel.startsWith('trading.')) this.scheduleAccountRefresh();
  }
  private async scheduleTickerPaint(): Promise<void> {
    if (this.tickerPaintPending) return;
    this.tickerPaintPending = true; await this.clock.delay(120); this.tickerPaintPending = false;
    if (this.foreground) this.changed();
  }
  async bindingChanged(): Promise<void> {
    this.realtime.stop();
    await this.session.observeBinding(this.binding, true);
    this.clearAccount(); await this.refreshAccount();
  }
  private async scheduleAccountRefresh(): Promise<void> {
    if (this.accountRefreshPending) return;
    this.accountRefreshPending = true; const scope = this.session.scope; await this.clock.delay(350);
    if (scope !== this.session.scope) return; this.accountRefreshPending = false;
    if (this.foreground) await this.refreshAccount();
  }
  private async scheduleChartRefresh(): Promise<void> {
    if (this.chartRefreshPending) return;
    this.chartRefreshPending = true; const generation = this.chartGeneration; await this.clock.delay(350); this.chartRefreshPending = false;
    if (generation === this.chartGeneration && this.foreground) await this.loadHistory(false);
  }
}
