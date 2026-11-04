import { DataValue } from './Json';
import { Decimal, validPositive } from './Decimal';
import { Session } from './Session';
import { Commands, commandMessage } from './Commands';
import type { RuntimeClock } from './Ports';

export class EntryDraft {
  symbol: string = ''; orderType: string = 'market'; stop: string = ''; limit: string = ''; price: string = ''; risk: string = '';
  includeFee: boolean = false; strategy: DataValue = new DataValue(); leverage: number = 0;
  reference(): string { return this.orderType === 'limit' ? this.limit : this.price; }
  valid(): boolean { return /^[A-Z0-9]{2,32}$/.test(this.symbol) && ['market', 'limit'].includes(this.orderType) && validPositive(this.reference()) && validPositive(this.stop) && validPositive(this.risk) && new Decimal(this.stop).compare(new Decimal(this.reference())) !== 0 && Number.isInteger(this.leverage) && this.leverage >= 0; }
  side(): string { return validPositive(this.stop) && validPositive(this.reference()) ? new Decimal(this.stop).compare(new Decimal(this.reference())) < 0 ? 'long' : 'short' : ''; }
  estimate(): string {
    if (!this.valid()) return '--';
    const reference = new Decimal(this.reference()); const ratio = reference.subtract(new Decimal(this.stop)).abs().divide(reference, 32).add(new Decimal(this.includeFee ? '0.001' : '0'));
    return new Decimal(this.risk).divide(ratio, 24).toString();
  }
  fee(): string { return this.valid() ? new Decimal(this.estimate()).multiply(new Decimal('0.001')).toString() : '--'; }
  copy(): EntryDraft {
    const d = new EntryDraft(); d.symbol = this.symbol; d.orderType = this.orderType; d.stop = this.stop; d.limit = this.limit; d.price = this.price; d.risk = this.risk;
    d.includeFee = this.includeFee; d.strategy = DataValue.parse(this.strategy.json()); d.leverage = this.leverage; return d;
  }
  matches(other: EntryDraft): boolean {
    return this.symbol === other.symbol && this.orderType === other.orderType && this.stop === other.stop && this.limit === other.limit && this.risk === other.risk
      && this.includeFee === other.includeFee && this.strategy.json() === other.strategy.json() && this.leverage === other.leverage && this.side() === other.side();
  }
  emaValid(ema: DataValue, now: number): boolean {
    return this.valid() && ema.value('check_id', '') !== '' && ema.value('symbol') === this.symbol && ema.value('side') === this.side()
      && ema.get('has_any_matching_interval').flag() && Date.parse(ema.value('expires_at')) > now
      && validPositive(ema.value('stop_loss_price')) && new Decimal(this.stop).compare(new Decimal(ema.value('stop_loss_price'))) === 0;
  }
  payload(ema: DataValue): DataValue {
    const value = DataValue.object({ symbol: this.symbol, stop_loss_price: this.stop, stop_loss_amount: this.risk }); const fields = value.fields();
    if (this.leverage > 0) fields['leverage'] = this.leverage;
    if (this.orderType === 'limit') fields['limit_price'] = this.limit;
    else { fields['include_fee'] = this.includeFee; fields['ema_check_id'] = ema.get('check_id').raw; }
    // Omitted strategy_id explicitly means manual take profit in the current server resolver.
    if (!this.strategy.empty()) { fields['strategy_id'] = this.strategy.get('id').raw; fields['strategy_name'] = this.strategy.get('name').raw; fields['strategy_config'] = this.strategy.get('levels').raw; }
    return value;
  }
}
export function heldPositions(rows: DataValue[], symbol: string): DataValue[] {
  return rows.filter((row: DataValue) => {
    if (row.value('symbol', '').toUpperCase() !== symbol.toUpperCase() || (!row.get('status').empty() && row.value('status') !== '0')) return false;
    const size = row.get('exchange_size').empty() ? row.get('size') : row.get('exchange_size');
    try { return !size.empty() && new Decimal(size.text()).compare(new Decimal('0')) !== 0; } catch (_) { return false; }
  });
}
export function leverageOptions(value: DataValue): DataValue[] {
  return value.get('brackets').rows().filter((row: DataValue) => {
    const leverage = row.get('leverage').number();
    try { return Number.isInteger(leverage) && leverage > 0 && new Decimal(row.value('max_open_amount')).compare(new Decimal('0')) >= 0; } catch (_) { return false; }
  }).sort((a: DataValue, b: DataValue) => new Decimal(b.value('max_open_amount')).compare(new Decimal(a.value('max_open_amount'))) || a.get('leverage').number() - b.get('leverage').number()).slice(0, 3);
}
export class ChartAccount {
  rows: DataValue[] = []; ready: boolean = false; error: string = ''; owner: string = ''; private request: number = 0;
  private flight: Promise<void> | null = null;
  reset(scope: string = ''): void { this.request++; this.owner = scope; this.rows = []; this.ready = false; this.error = ''; this.flight = null; }
  positions(symbol: string, scope: string): DataValue[] { return scope === this.owner ? heldPositions(this.rows, symbol) : []; }
  async refresh(session: Session, bound: boolean): Promise<void> {
    const scope = session.scope; if (scope !== this.owner) this.reset(scope);
    if (this.flight) return this.flight;
    const id = ++this.request;
    if (!bound) { this.rows = []; this.ready = true; this.error = ''; return; }
    const flight = this.read(session, scope, id); this.flight = flight;
    try { await flight; } finally { if (this.flight === flight) this.flight = null; }
  }
  private async read(session: Session, scope: string, id: number): Promise<void> {
    try {
      const value = await session.request('/v1/position/list');
      if (id !== this.request || scope !== session.scope) return;
      if (!Array.isArray(value.raw)) throw new Error('Invalid positions response');
      const rows = value.rows();
      for (const row of rows) {
        if (!/^[A-Z0-9]{2,32}$/.test(row.value('symbol', ''))) throw new Error('Invalid position symbol');
        const size = row.get('exchange_size').empty() ? row.value('size', '') : row.value('exchange_size', '');
        new Decimal(size); // Missing/nonfinite quantities cannot prove the account has no position.
      }
      this.rows = rows; this.ready = true; this.error = '';
    } catch (_) { if (id === this.request && scope === session.scope) { this.ready = false; this.error = '持仓状态暂时无法确认，请稍后重试'; } }
  }
}
export interface EntryContext { active: boolean; bound: boolean; }
export class EntryFlow {
  busy: boolean = false; confirming: boolean = false; submitted: boolean = false; notice: string = ''; ema: DataValue = new DataValue();
  changed: () => void = () => {};
  private session: Session; private commands: Commands; private clock: RuntimeClock; private account: ChartAccount;
  constructor(session: Session, commands: Commands, clock: RuntimeClock, account: ChartAccount) { this.session = session; this.commands = commands; this.clock = clock; this.account = account; }
  private guard(draft: EntryDraft, current: () => EntryDraft, context: () => EntryContext, scope: string): void {
    if (!context().active || scope !== this.session.scope || !draft.matches(current()) || !current().valid()) throw new Error('开仓参数或账户已变化，请重新确认');
    if (!context().bound || this.account.owner !== scope || !this.account.ready || this.account.positions(draft.symbol, scope).length) throw new Error('请先确认当前账户持仓状态');
  }
  async advance(current: () => EntryDraft, context: () => EntryContext, confirm: (draft: EntryDraft) => Promise<boolean>): Promise<void> {
    if (this.busy || this.confirming || this.submitted || !context().active || !context().bound || !current().valid()) return;
    const draft = current().copy(); const scope = this.session.scope; this.busy = true; this.notice = ''; this.changed();
    try {
      await this.commands.load(); await this.account.refresh(this.session, context().bound); this.guard(draft, current, context, scope);
      if (this.commands.pending().length) { this.submitted = true; throw new Error('已有请求待确认，请查看交易命令'); }
      if (draft.orderType === 'market' && !draft.emaValid(this.ema, this.clock.now())) {
        const ema = await this.session.request('/v1/trade/ema-check', 'POST', DataValue.object({ symbol: draft.symbol, stop_loss_price: draft.stop }));
        this.guard(draft, current, context, scope); this.ema = ema;
        this.notice = draft.emaValid(ema, this.clock.now()) ? '方向初筛通过，再次点击确认开仓' : '方向初筛未通过或已过期'; return;
      }
      const preflight = await this.session.request('/v1/trade/capital/precheck', 'POST', DataValue.object({ purpose: 'entry' }));
      if (!['ready', 'not_required'].includes(preflight.value('status'))) throw new Error(preflight.value('message', '请先在我的页面处理开仓资金'));
      this.guard(draft, current, context, scope); this.confirming = true; this.changed();
      const accepted = await confirm(draft.copy()); this.confirming = false;
      if (!accepted) return;
      await this.account.refresh(this.session, context().bound); this.guard(draft, current, context, scope);
      if (draft.orderType === 'market' && !draft.emaValid(this.ema, this.clock.now())) throw new Error('方向初筛已过期，请重新初筛');
      const payload = draft.payload(this.ema); const key = this.clock.id();
      this.submitted = true; this.changed();
      const result = await this.commands.submit(draft.orderType === 'limit' ? 'trade.open-limit' : 'trade.open-market', payload, key);
      if (scope !== this.session.scope || !context().active) return;
      this.notice = commandMessage(result); if (result.value('status') === 'FAILED') this.submitted = false;
      await this.account.refresh(this.session, context().bound);
    } catch (e) { if (scope === this.session.scope && context().active) this.notice = (e as Error).message; }
    finally { this.busy = false; this.confirming = false; this.changed(); }
  }
}
