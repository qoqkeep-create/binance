import { DataValue } from './Json';
import { Session } from './Session';
import type { RuntimeClock, SocketPort, SocketCallbacks } from './Ports';

export class Realtime {
  status: string = '未连接';
  latency: number = -1;
  symbol: string = '';
  interval: string = '1h';
  onEvent: (event: DataValue) => void = () => {};
  onChange: () => void = () => {};
  private session: Session;
  private socket: SocketPort;
  private clock: RuntimeClock;
  private generation: number = 0;
  private active: boolean = false;
  private ready: boolean = false;
  private retry: number = 0;
  private lastMessage: number = 0;
  private pendingPing: string = '';
  private pingTime: number = 0;
  private nextPing: number = 0;
  private supportsHistory: boolean = false;
  private reconnectScheduled: boolean = false;
  private samples: number[] = [];
  constructor(session: Session, socket: SocketPort, clock: RuntimeClock) { this.session = session; this.socket = socket; this.clock = clock; }
  start(): void { this.stop(); this.active = true; this.retry = 0; this.connect(); }
  stop(): void {
    this.active = false; this.generation++; this.ready = false; this.reconnectScheduled = false;
    this.pendingPing = ''; this.samples = []; this.latency = -1; this.socket.close(); this.status = '未连接'; this.onChange();
  }
  setChart(symbol: string, interval: string): void {
    this.symbol = symbol; this.interval = interval;
    if (this.ready) this.subscribe();
  }
  testLatency(): void { this.pendingPing = ''; this.samples = []; this.latency = -1; this.nextPing = 0; this.onChange(); }
  private connect(): void {
    if (!this.active || !this.session.authenticated) return;
    const generation = ++this.generation; const scope = this.session.scope;
    this.reconnectScheduled = false; this.status = '连接中'; this.ready = false; this.latency = -1; this.pendingPing = ''; this.samples = []; this.onChange();
    const callbacks: SocketCallbacks = {
      opened: (): void => { if (generation === this.generation) { this.lastMessage = this.clock.now(); } },
      message: (data: string): void => {
        if (generation !== this.generation || scope !== this.session.scope) return;
        try { this.receive(DataValue.parse(data), generation); } catch (_) { /* Invalid data cannot mutate account state. */ }
      },
      closed: (code: number): void => {
        if (generation !== this.generation || scope !== this.session.scope || !this.active || this.reconnectScheduled) return;
        this.reconnectScheduled = true; this.ready = false; this.latency = -1; this.status = '重新连接'; this.onChange();
        this.reconnect(generation, code);
      }
    };
    this.socket.connect(this.session.baseUrl.replace(/^https:/, 'wss:') + 'ws/v1', { Authorization: 'Bearer ' + this.session.token, 'X-Trading-Mode': this.session.mode }, callbacks);
    this.connectionTimeout(generation);
  }
  private async connectionTimeout(generation: number): Promise<void> {
    await this.clock.delay(15000);
    if (generation === this.generation && this.active && !this.ready && !this.reconnectScheduled) {
      this.reconnectScheduled = true; this.socket.close(); this.reconnect(generation, 0);
    }
  }
  private async reconnect(generation: number, code: number): Promise<void> {
    if (code === 4401) {
      try { await this.session.refresh(); } catch (_) { if (generation === this.generation) { this.status = '登录已失效'; this.onChange(); } return; }
    }
    await this.clock.delay(Math.min(30000, 1000 * Math.pow(2, Math.min(this.retry++, 5))));
    if (generation === this.generation && this.active) { this.socket.close(); this.connect(); }
  }
  private receive(event: DataValue, generation: number): void {
    this.lastMessage = this.clock.now();
    const type = event.value('type');
    if (type === 'ready') {
      this.ready = true; this.retry = 0; this.status = '已连接'; this.nextPing = 0;
      this.supportsHistory = event.get('data').get('capabilities').rows().some((v: DataValue) => v.text() === 'market.history');
      this.subscribe(); this.heartbeat(generation); this.onChange();
    }
    if (type === 'pong' && event.value('requestId', '') === this.pendingPing && this.pendingPing) {
      this.samples.push(Math.max(0, this.clock.now() - this.pingTime)); this.samples = this.samples.slice(-5);
      const sorted = this.samples.slice().sort((a: number, b: number) => a - b);
      this.latency = sorted[Math.floor(sorted.length / 2)]; this.pendingPing = ''; this.onChange();
    }
    this.onEvent(event);
  }
  private subscribe(): void {
    const subscriptions: Object[] = [
      { channel: 'market.ticker', filters: {} }, { channel: 'strategy.signal', filters: {} }, { channel: 'trading.account', filters: {} },
      { channel: 'trading.position', filters: {} }, { channel: 'trading.order', filters: {} }, { channel: 'trading.fill', filters: {} }
    ];
    if (this.symbol) {
      subscriptions.push({ channel: 'market.kline', filters: { symbols: [this.symbol], intervals: Array.from(new Set(['1m', this.interval])) } });
      if (this.supportsHistory) subscriptions.push({ channel: 'market.history', filters: { symbols: [this.symbol], intervals: [this.interval] } });
    } else {
      this.socket.send(JSON.stringify({ type: 'unsubscribe', requestId: this.clock.id(), subscriptions: [{ channel: 'market.kline', filters: {} }].concat(this.supportsHistory ? [{ channel: 'market.history', filters: {} }] : []) }));
    }
    this.socket.send(JSON.stringify({ type: 'subscribe', requestId: this.clock.id(), subscriptions: subscriptions }));
  }
  private async heartbeat(generation: number): Promise<void> {
    while (generation === this.generation && this.active && this.ready) {
      const now = this.clock.now();
      if (now - this.lastMessage > 60000) {
        this.ready = false; this.socket.close();
        if (!this.reconnectScheduled) { this.reconnectScheduled = true; this.reconnect(generation, 0); }
        return;
      }
      if (this.pendingPing && now - this.pingTime > 3000) { this.pendingPing = ''; this.latency = -1; this.samples = []; this.onChange(); }
      if (!this.pendingPing && now >= this.nextPing) {
        this.pendingPing = this.clock.id(); this.pingTime = now; this.nextPing = now + 2000;
        this.socket.send(JSON.stringify({ type: 'ping', requestId: this.pendingPing, timestamp: now }));
      }
      await this.clock.delay(250);
    }
  }
}
