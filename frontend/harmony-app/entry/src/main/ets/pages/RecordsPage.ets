import { Runtime } from '../platform/Runtime';
import { DataValue } from '../core/Json';
import { PendingCommand, commandMessage } from '../core/Commands';
import { amount } from '../core/Decimal';
import { SectionCard, Metric, ActionButton, EmptyState, confirmAction, dateText, GOLD, GREEN, RED } from '../components/Ui';

@Component
export struct RecordsPage {
  @Prop @Watch('refreshLive') revision: number = 0;
  kind: string = 'signals';
  positionId: string = '';
  openChart: (symbol: string, interval: string) => void = () => {};
  @State rows: DataValue[] = [];
  @State summary: DataValue = new DataValue();
  @State pending: PendingCommand[] = [];
  @State batch: DataValue = new DataValue();
  @State loading: boolean = false;
  @State message: string = '';
  @State hasNext: boolean = false;
  private lastLive: number = -1;
  private page: number = 1;
  private cursor: string = '';
  private generation: number = 0;
  private active: boolean = true;
  aboutToAppear(): void { this.active = true; this.load(false); }
  aboutToDisappear(): void { this.active = false; this.generation++; }
  private refreshLive(): void {
    const live = this.kind === 'signals' ? Runtime.store.signalRevision : Runtime.store.accountRevision;
    if (this.lastLive === live) return; this.lastLive = live;
    if (this.active && !this.loading) this.load(false);
  }
  private async load(append: boolean): Promise<void> {
    if (this.loading && append) return;
    const generation = ++this.generation; this.loading = true; this.message = '';
    const page = append ? this.page + 1 : 1;
    let path = '/v1/trade/tradingview/signals?source=internal';
    if (this.kind === 'commands') path = '/api/commands';
    if (this.kind === 'transfers') path = '/v1/account/transfer-history?page=' + page + '&page_size=20';
    if (this.kind === 'operations') path = '/v1/account/operation-logs?limit=20&cursor=' + encodeURIComponent(append ? this.cursor : '');
    if (this.kind === 'strategy-log') path = '/v1/strategy/log?position_id=' + encodeURIComponent(this.positionId);
    try {
      const result = await Runtime.store.session.request(path);
      if (!this.active || generation !== this.generation) return;
      this.summary = result; this.rows = append ? this.rows.concat(result.items()) : result.items(); this.page = page;
      this.cursor = result.value('next_cursor', ''); this.hasNext = result.get('has_more').flag() || result.get('pagination').get('has_next').flag();
      if (this.kind === 'commands') { await Runtime.store.commands.load(); this.pending = Runtime.store.commands.pending(); this.batch = await Runtime.store.bulk.pending(); }
    } catch (e) { if (this.active && generation === this.generation) this.message = (e as Error).message; }
    finally { if (generation === this.generation) this.loading = false; }
  }
  private resume(command: PendingCommand): void {
    confirmAction('继续核对原请求', command.action + '\n' + command.payload.json() + '\n请求标识：' + command.key, async () => {
      const result = await Runtime.store.commands.resume(command.key); this.message = commandMessage(result); await this.load(false); await Runtime.store.refreshAccount();
    });
  }
  private status(value: string): string {
    const labels = new Map<string, string>([
      ['SUCCEEDED', '成功'], ['FAILED', '失败'], ['UNKNOWN', '结果待确认'], ['QUEUED', '排队中'], ['RUNNING', '执行中'],
      ['PENDING', '待处理'], ['success', '已执行'], ['failed', '失败'], ['pending', '待确认'], ['info', '记录']
    ]);
    return labels.get(value) || value;
  }
  build() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.kind === 'signals') {
          Text('内部信号 · 北京时间').fontSize(13).fontColor($r('app.color.text_secondary'))
        }
        if (this.kind === 'transfers') {
          SectionCard() {
            Metric({ label: '累计净转出', value: amount(this.summary.value('net_amount')) + ' USDT' })
            Metric({ label: '累计转出', value: amount(this.summary.value('outgoing_total')) })
            Metric({ label: '累计收到', value: amount(this.summary.value('incoming_total')) })
            Metric({ label: '起始时间', value: dateText(this.summary.value('start_at')) })
          }
          ActionButton({ label: '同步转账历史', secondary: true, interactive: !this.loading, action: () => { confirmAction('同步转账历史', '读取交易所历史转账记录。', async () => { await Runtime.store.session.request('/v1/account/transfer-history/sync', 'POST'); await this.load(false); }); } })
        }
        if (!this.batch.empty()) {
          SectionCard() {
            Text('批量平仓待核对').fontSize(16).fontColor(GOLD)
            Metric({ label: '已完成 / 总数', value: this.batch.value('cursor') + ' / ' + this.batch.get('targets').rows().length })
            ActionButton({ label: '继续核对原批次', action: () => {
              confirmAction('继续批量平仓', this.batch.get('targets').rows().map((v: DataValue) => v.value('symbol') + ' #' + v.value('id')).join('\n'), async () => { const result = await Runtime.store.bulk.run(); this.message = commandMessage(result); await this.load(false); });
            } })
          }
        }
        ForEach(this.pending, (command: PendingCommand) => {
          SectionCard() {
            Text('本机待确认 · ' + command.action).fontSize(16).fontColor(GOLD)
            Metric({ label: '状态', value: this.status(command.status) })
            Metric({ label: '请求标识', value: command.key })
            Text(command.payload.json()).fontSize(12).fontColor($r('app.color.text_secondary'))
            ActionButton({ label: '继续核对原请求', action: () => this.resume(command) })
          }
        }, (command: PendingCommand) => command.key)
        ForEach(this.rows, (row: DataValue) => {
          SectionCard() {
            if (this.kind === 'signals') {
              Row({ space: 8 }) {
                Text(['0', 'long', 'LONG'].includes(row.value('direction')) ? '多' : '空').fontColor(['0', 'long', 'LONG'].includes(row.value('direction')) ? GREEN : RED).fontSize(16)
                Text(row.value('symbol')).fontWeight(FontWeight.Bold).fontSize(18).fontColor($r('app.color.text_primary')).layoutWeight(1)
                Text(row.value('score') + '分').fontSize(13).fontColor(GOLD)
              }.width('100%')
              Metric({ label: row.value('interval'), value: dateText(row.value('signal_time', row.value('received_at'))) })
              Text(row.value('strategy', '') + ' · ' + row.value('final_action', '')).fontSize(14).fontColor($r('app.color.text_secondary'))
              if (row.value('comment', '')) { Text(row.value('comment')).fontSize(14).fontColor($r('app.color.text_primary')) }
              if (row.value('entry_condition', '')) { Text('触发条件：' + row.value('entry_condition')).fontSize(12).fontColor($r('app.color.text_secondary')) }
              if (row.get('risk_points').rows().length) { Text('风险：' + row.get('risk_points').rows().map((v: DataValue) => v.text()).join('；')).fontSize(12).fontColor($r('app.color.text_secondary')) }
              ActionButton({ label: '查看 K 线', secondary: true, action: () => this.openChart(row.value('symbol'), row.value('interval', '1h')) })
            } else if (this.kind === 'commands') {
              Metric({ label: row.value('action'), value: this.status(row.value('status')) })
              Metric({ label: '命令 ID', value: row.value('id') })
              Metric({ label: '创建时间', value: dateText(row.value('createdAt', row.value('created_at'))) })
              Text(row.get('result').value('message', '')).fontSize(13).fontColor($r('app.color.text_secondary'))
              if (!row.get('payload').empty()) { Text(row.get('payload').json()).fontSize(12).fontColor($r('app.color.text_secondary')) }
            } else if (this.kind === 'transfers') {
              Metric({ label: row.value('route'), value: (row.value('direction') === 'outgoing' ? '+' : '-') + amount(row.value('amount')) + ' USDT', color: row.value('direction') === 'outgoing' ? GREEN : GOLD })
              Metric({ label: row.value('channel'), value: dateText(row.value('occurred_at')) })
              Metric({ label: '状态', value: this.status(row.value('status')) })
            } else {
              Metric({ label: row.value('symbol', row.value('action')), value: this.status(row.value('status')) })
              Metric({ label: '仓位 #' + row.value('order_id', this.positionId), value: dateText(row.value('occurred_at', row.value('created_at'))) })
              Text(row.value('message', row.value('content', row.value('behavior_desc', '')))).fontSize(14).fontColor($r('app.color.text_primary'))
            }
          }
        })
        if (this.message) { Text(this.message).fontSize(13).fontColor(GOLD) }
        if (this.loading) { LoadingProgress().width(30).height(30) }
        if (!this.rows.length && !this.loading && !this.message) { EmptyState({ title: this.kind === 'signals' ? '暂无内部信号' : '暂无记录' }) }
        if (this.hasNext) { ActionButton({ label: '加载更多', secondary: true, interactive: !this.loading, action: () => { this.load(true); } }) }
        ActionButton({ label: '刷新', secondary: true, interactive: !this.loading, action: () => { this.load(false); } })
      }.padding(16).width('100%').constraintSize({ maxWidth: 600 })
    }.height('100%').width('100%').backgroundColor($r('app.color.page'))
  }
}
