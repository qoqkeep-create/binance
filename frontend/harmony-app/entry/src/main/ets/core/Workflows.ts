import { DataValue, ApiError } from './Json';
import { Session } from './Session';
import { Commands } from './Commands';
import type { Vault, RuntimeClock } from './Ports';

export function tradingIdentity(session: Session): string {
  return session.baseUrl + ':' + session.user.value('id') + ':' + session.mode + ':' + session.bindingIdentity;
}
export class CapitalWorkflow {
  private session: Session;
  private vault: Vault;
  private busy: boolean = false;
  constructor(session: Session, vault: Vault) { this.session = session; this.vault = vault; }
  private key(): string { return 'capital:' + tradingIdentity(this.session); }
  async preview(): Promise<DataValue> {
    const scope = this.session.scope; const key = this.key();
    const result = await this.session.request('/v1/trade/capital/precheck', 'POST', DataValue.object({ purpose: 'manual_sweep' }));
    if (scope !== this.session.scope) throw new ApiError('账户已切换', -1);
    const collection = result.value('status') === 'collection_pending' ? result : result.get('pending_collection');
    if (!collection.empty() && collection.value('collection_id', '')) {
      await this.vault.write(key, DataValue.object({ id: collection.get('collection_id').raw, preview: result.raw }).json());
    } else if (['ready', 'not_required'].includes(result.value('status'))) await this.vault.remove(key);
    return result;
  }
  async pending(): Promise<DataValue> { const saved = await this.vault.read(this.key()); return saved ? DataValue.parse(saved) : new DataValue(); }
  async confirm(preview: DataValue): Promise<DataValue> {
    if (this.busy) throw new Error('资金请求正在处理中');
    this.busy = true; const scope = this.session.scope; const key = this.key();
    try {
      const saved = await this.pending();
      if (scope !== this.session.scope) throw new ApiError('账户已切换', -1);
      const id = saved.get('id');
      if (!saved.empty() && id.empty()) throw new Error('上次资金请求结果未知，请重新预览核对；不会重复发起原计划');
      const payload = DataValue.object({ purpose: 'manual_sweep', expected_status: id.empty() ? 'normalization_required' : 'collection_pending' });
      if (!id.empty()) payload.fields()['collection_id'] = id.raw;
      else {
        if (preview.value('status') !== 'normalization_required' || !preview.value('plan_token', '')) throw new Error('资金预览已失效，请重新预览');
        payload.fields()['expected_plan'] = preview.get('plan_token').raw;
        // Persist uncertainty BEFORE a transfer can leave this device.
        await this.vault.write(key, DataValue.object({ preview: preview.raw, state: 'UNKNOWN' }).json());
      }
      if (scope !== this.session.scope) throw new ApiError('账户已切换', -1);
      const result = await this.session.request('/v1/trade/capital/normalize', 'POST', payload);
      if (scope !== this.session.scope) throw new ApiError('账户已切换', -1);
      if (result.value('status') === 'collection_pending') {
        const next = result.get('collection_id');
        if (next.empty() || (!id.empty() && next.text() !== id.text())) throw new Error('归集流水身份已变化，请重新预览核对');
        await this.vault.write(key, DataValue.object({ id: next.raw, preview: result.raw }).json());
      } else if (['ready', 'not_required'].includes(result.value('status')) || result.value('reason') === 'normalization_completed') await this.vault.remove(key);
      return result;
    } finally { this.busy = false; }
  }
}

export class BulkClose {
  private session: Session;
  private commands: Commands;
  private vault: Vault;
  private clock: RuntimeClock;
  private busy: boolean = false;
  constructor(session: Session, commands: Commands, vault: Vault, clock: RuntimeClock) { this.session = session; this.commands = commands; this.vault = vault; this.clock = clock; }
  private key(): string { return 'bulk-close:' + tradingIdentity(this.session); }
  async pending(): Promise<DataValue> { const saved = await this.vault.read(this.key()); return saved ? DataValue.parse(saved) : new DataValue(); }
  async prepare(positions: DataValue[]): Promise<void> {
    if (this.busy) throw new Error('批量请求正在处理中');
    this.busy = true; const scope = this.session.scope; const key = this.key();
    try {
      await this.commands.load();
      if (this.commands.pending().length) throw new Error('有交易请求待确认，请先核对原请求');
      if (!(await this.pending()).empty()) throw new Error('有未完成的批量平仓，请先核对原批次');
      if (scope !== this.session.scope) throw new ApiError('账户已切换', -1);
      const targets = positions.map((v: DataValue) => DataValue.object({ id: v.get('id').raw, symbol: v.get('symbol').raw, key: this.clock.id() }).raw);
      if (!targets.length || targets.some((v: Object | null) => new DataValue(v).get('id').empty())) throw new Error('批量目标为空或无效');
      await this.vault.write(key, DataValue.object({ targets: targets, cursor: 0 }).json());
      if (scope !== this.session.scope) throw new ApiError('账户已切换', -1);
    } finally { this.busy = false; }
  }
  async run(): Promise<DataValue> {
    if (this.busy) throw new Error('批量平仓正在处理中');
    this.busy = true; const scope = this.session.scope; const key = this.key();
    try {
      const batch = await this.pending(); const targets = batch.get('targets').rows();
      for (let i = batch.get('cursor').number(); i < targets.length; i++) {
        if (scope !== this.session.scope) throw new ApiError('账户已切换，已停止后续平仓', -1);
        const target = targets[i];
        const result = await this.commands.submit('position-close', DataValue.object({ position_id: target.get('id').raw }), target.value('key'));
        if (scope !== this.session.scope) throw new ApiError('账户已切换', -1);
        if (!['SUCCEEDED', 'FAILED'].includes(result.value('status'))) return result;
        if (result.value('status') === 'FAILED') batch.fields()['failed'] = batch.get('failed').number() + 1;
        batch.fields()['cursor'] = i + 1; await this.vault.write(key, batch.json());
      }
      if (targets.length) await this.vault.remove(key);
      return DataValue.object({ status: batch.get('failed').number() > 0 ? 'FAILED' : 'SUCCEEDED', result: { message: '本批处理完成，失败 ' + batch.get('failed').number() + ' 笔。请核对交易命令与历史仓位。' } });
    } finally { this.busy = false; }
  }
}
