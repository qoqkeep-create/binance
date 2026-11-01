import { DataValue, ApiError } from './Json';
import { Session } from './Session';
import type { RuntimeClock, Vault } from './Ports';

export class PendingCommand {
  identity: string = '';
  key: string = '';
  action: string = '';
  payload: DataValue = DataValue.object();
  id: string = '';
  status: string = 'PREPARED';
  createdAt: number = 0;
  toValue(): DataValue { return DataValue.object({ identity: this.identity, key: this.key, action: this.action, payload: this.payload.raw, id: this.id, status: this.status, createdAt: this.createdAt }); }
  static from(value: DataValue): PendingCommand {
    const item = new PendingCommand(); item.identity = value.value('identity', ''); item.key = value.value('key', '');
    item.action = value.value('action', ''); item.payload = value.get('payload'); item.id = value.value('id', '');
    item.status = value.value('status', 'UNKNOWN'); item.createdAt = value.get('createdAt').number(); return item;
  }
  terminal(): boolean { return this.status === 'SUCCEEDED' || this.status === 'FAILED'; }
}

export class Commands {
  private session: Session;
  private vault: Vault;
  private clock: RuntimeClock;
  private entries: PendingCommand[] = [];
  private busy: boolean = false;
  private loadFlight: Promise<void> | null = null;
  private loaded: boolean = false;
  constructor(session: Session, vault: Vault, clock: RuntimeClock) { this.session = session; this.vault = vault; this.clock = clock; }
  private identity(): string { return this.session.baseUrl + ':' + this.session.user.value('id') + ':' + this.session.mode + ':' + this.session.bindingIdentity; }
  async load(): Promise<void> {
    if (this.loaded) return;
    if (this.loadFlight) return this.loadFlight;
    const flight = this.readEntries(); this.loadFlight = flight;
    try { await flight; } finally { this.loadFlight = null; }
  }
  private async readEntries(): Promise<void> {
    const saved = await this.vault.read('pending-commands');
    this.entries = saved ? DataValue.parse(saved).rows().map((v: DataValue) => PendingCommand.from(v)) : [];
    this.loaded = true;
  }
  pending(): PendingCommand[] { return this.entries.filter((v: PendingCommand) => v.identity === this.identity() && !v.terminal()); }
  private persist(): Promise<void> {
    return this.vault.write('pending-commands', new DataValue(this.entries.map((v: PendingCommand) => v.toValue().raw) as Object).json());
  }
  async submit(action: string, payload: DataValue, stableKey: string = ''): Promise<DataValue> {
    if (this.busy) throw new Error('请求正在处理中');
    if (!this.session.authenticated || !this.session.bindingIdentity || this.session.bindingIdentity === 'unbound') throw new Error('请先绑定当前模式的 API');
    this.busy = true; const scope = this.session.scope;
    try {
      await this.load();
      if (scope !== this.session.scope) throw new ApiError('账户已切换', -1);
      const prior = stableKey ? this.entries.find((v: PendingCommand) => v.key === stableKey && v.identity === this.identity()) : undefined;
      if (prior && prior.terminal()) {
        if (prior.action !== action || prior.payload.json() !== payload.json()) throw new Error('请求标识和参数不一致');
        if (!prior.id) return DataValue.object({ status: 'FAILED', result: { message: '原请求已被服务器拒绝，请核对交易命令' } });
        return await this.session.request('/api/commands/' + prior.id);
      }
      const unresolved = this.pending();
      let entry: PendingCommand;
      if (unresolved.length > 0) {
        entry = unresolved[0];
        if (stableKey && entry.key !== stableKey) throw new Error('已有另一笔请求待确认，请先核对原请求');
        if (entry.action !== action || entry.payload.json() !== payload.json()) throw new Error('有结果待确认的请求，请先到交易命令核对原请求');
      } else {
        entry = new PendingCommand(); entry.identity = this.identity(); entry.key = stableKey || this.clock.id(); entry.action = action;
        entry.payload = DataValue.parse(payload.json()); entry.createdAt = this.clock.now(); this.entries.push(entry);
        await this.persist(); // No request is sent if durable secure storage fails.
      }
      return await this.execute(entry, scope);
    } finally { this.busy = false; }
  }
  async resume(key: string): Promise<DataValue> {
    if (this.busy) throw new Error('请求正在处理中');
    this.busy = true; const scope = this.session.scope;
    try {
      await this.load();
      const entry = this.pending().find((v: PendingCommand) => v.key === key);
      if (!entry) throw new Error('当前账户下没有此待确认请求');
      return await this.execute(entry, scope);
    } finally { this.busy = false; }
  }
  private async execute(entry: PendingCommand, scope: string): Promise<DataValue> {
    const check = (): void => { if (scope !== this.session.scope || entry.identity !== this.identity()) throw new ApiError('账户已切换', -1); };
    let result = new DataValue();
    try {
      check(); await this.persist(); check();
      result = entry.id ? await this.session.request('/api/commands/' + entry.id)
        : await this.session.request('/api/commands', 'POST', DataValue.object({ action: entry.action, payload: entry.payload.raw }), { 'Idempotency-Key': entry.key });
      check(); entry.id = result.value('id', ''); entry.status = result.value('status', 'UNKNOWN'); await this.persist();
      for (let i = 0; i < 40 && ['QUEUED', 'PENDING', 'RUNNING'].includes(entry.status); i++) {
        await this.clock.delay(500); check();
        result = await this.session.request('/api/commands/' + entry.id); check();
        entry.status = result.value('status', 'UNKNOWN'); await this.persist();
      }
      return result;
    } catch (e) {
      const error = e as ApiError;
      if (!entry.id && error.code >= 400 && error.code < 500 && ![408, 429].includes(error.code)) entry.status = 'FAILED';
      else if (!entry.terminal()) entry.status = 'UNKNOWN';
      await this.persist(); throw e;
    }
  }
}

export function commandMessage(result: DataValue): string {
  if (result.value('status') === 'SUCCEEDED') return '操作成功';
  if (result.value('status') === 'FAILED') return result.get('result').value('message', '操作失败');
  return '请求已保存，结果仍在核对。请查看交易命令。';
}
