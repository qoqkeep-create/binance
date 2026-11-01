import { Runtime } from '../platform/Runtime';
import { DataValue } from '../core/Json';
import { amount, Decimal } from '../core/Decimal';
import { commandMessage } from '../core/Commands';
import { SectionCard, Metric, ActionButton, ChoiceBar, EmptyState, confirmAction, dateText, GREEN, RED } from '../components/Ui';

@Component
export struct PositionsPage {
  @Prop @Watch('liveRefresh') revision: number = 0;
  @State segment: number = 0;
  @State items: DataValue[] = [];
  @State loading: boolean = false;
  @State hasNext: boolean = false;
  @State error: string = '';
  @State range: number = 0;
  private page: number = 1;
  private generation: number = 0;
  private lastAccountRevision: number = -1;
  private active: boolean = true;
  openDetail: (item: DataValue, historical: boolean) => void = () => {};
  navigate: (route: string) => void = () => {};
  aboutToAppear(): void { this.active = true; this.load(false); }
  aboutToDisappear(): void { this.active = false; this.generation++; }
  private liveRefresh(): void {
    if (this.lastAccountRevision === Runtime.store.accountRevision) return;
    this.lastAccountRevision = Runtime.store.accountRevision; if (this.active) this.load(false);
  }
  private async load(append: boolean): Promise<void> {
    if (append && this.loading) return;
    const generation = ++this.generation; this.loading = true; this.error = '';
    const page = append ? this.page + 1 : 1;
    try {
      const path = this.segment === 1 ? '/v1/trade/limit-order/list' : this.segment === 2 ? '/v1/position/history' : '/v1/position/list';
      const value = await Runtime.store.session.request(path + '?page=' + page + '&page_size=20&filter=' + ['all', 'day', 'three-days', 'week'][this.range]);
      if (generation !== this.generation || !this.active) return;
      this.items = append ? this.items.concat(value.items()) : value.items(); this.page = page; this.hasNext = value.get('pagination').get('has_next').flag();
    } catch (e) { if (generation === this.generation) this.error = (e as Error).message; }
    finally { if (generation === this.generation) this.loading = false; }
  }
  private command(row: DataValue, action: string, title: string): void {
    const payload = DataValue.object({ limit_order_id: row.get('id').raw });
    confirmAction(title, row.value('symbol') + '\n确认' + title + '这笔限价委托？', async () => {
      if (action === 'limit-chase') await Runtime.store.preflight('chase');
      const result = await Runtime.store.commands.submit(action, payload); Runtime.store.notice = commandMessage(result); Runtime.store.changed(); await this.load(false);
    });
  }
  private closeAll(): void {
    const positions = this.items.map((v: DataValue) => DataValue.parse(v.json()));
    confirmAction('全部平仓', positions.map((v: DataValue) => v.value('symbol') + ' #' + v.value('id') + '：' + amount(v.value('pnl')) + ' USDT').join('\n') + '\n确认平仓以上所有仓位？', async () => {
      await Runtime.store.bulk.prepare(positions);
      const result = await Runtime.store.bulk.run(); Runtime.store.notice = commandMessage(result); Runtime.store.changed(); await this.load(false);
    });
  }
  build() {
    Column() {
      ChoiceBar({ labels: ['持仓', '限价委托', '历史仓位'], selected: $segment, changed: () => { this.items = []; this.load(false); } }).padding({ left: 16, right: 16 })
      if (this.segment === 2) { ChoiceBar({ labels: ['全部', '一天内', '三天', '一周'], selected: $range, changed: () => { this.load(false); } }).padding({ left: 16, right: 16 }) }
      Scroll() {
        Column({ space: 12 }) {
          if (!Runtime.store.isBound) { EmptyState({ title: '请先绑定 Binance API' }); ActionButton({ label: '绑定 API', action: () => this.navigate('binding') }) }
          if (this.error) { Text(this.error).fontColor(RED).fontSize(13) }
          if (this.segment === 0 && this.items.length) { ActionButton({ label: '全部平仓', color: RED, interactive: !this.loading, action: () => this.closeAll() }) }
          ForEach(this.items, (row: DataValue) => {
            SectionCard() {
              Row({ space: 8 }) {
                Text(row.value('symbol')).fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).layoutWeight(1)
                Text(['0', 'long', 'buy'].includes(row.value('side')) ? '多' : '空').fontColor(['0', 'long', 'buy'].includes(row.value('side')) ? GREEN : RED).fontSize(14)
                Text('x' + row.value('leverage')).fontSize(12).fontColor($r('app.color.text_secondary'))
                if (row.value('position_origin') === 'exchange_external') { Text('手动仓').fontSize(12).fontColor('#F0B90B') }
              }.width('100%')
              Metric({ label: this.segment === 2 ? '净盈亏（USDT）' : '浮动盈亏（USDT）', value: amount(row.value(this.segment === 2 ? 'pnl' : 'pnl', '')), color: row.get(this.segment === 2 ? 'pnl' : 'pnl').number() >= 0 ? GREEN : RED })
              Metric({ label: '开仓价', value: row.value('open_price', row.value('limit_price')) })
              if (this.segment !== 2) { Metric({ label: '当前价', value: row.value('current_price') }); Metric({ label: '止损价', value: row.value('stop_loss_price') }) }
              Metric({ label: '数量', value: row.value('quantity', row.value('size')) })
              Metric({ label: '止损金额', value: row.value('stop_loss_amount') + ' USDT' })
              if (this.segment === 2) {
                Metric({ label: '结算状态', value: row.value('settlement_status') === 'settled' ? '已结算' : row.value('settlement_status') === 'estimated' ? '估算 · 待核对' : '结算中' })
                Metric({ label: '平仓时间', value: dateText(row.value('closed_at')) })
              }
              if (this.segment === 1) {
                Metric({ label: '已成交金额 / 数量', value: row.value('filled_amount', row.value('filled_size')) })
                Row({ space: 12 }) {
                  ActionButton({ label: '追单', secondary: true, interactive: row.get('can_chase').flag(), action: () => this.command(row, 'limit-chase', '追单') }).layoutWeight(1)
                  ActionButton({ label: '撤单', action: () => this.command(row, 'limit-cancel', '撤单') }).layoutWeight(1)
                }.width('100%')
              } else { ActionButton({ label: this.segment === 2 ? '查看详情' : '管理持仓', secondary: true, action: () => this.openDetail(row, this.segment === 2) }) }
            }
          }, (row: DataValue) => row.value('id') + ':' + row.json())
          if (this.loading) { LoadingProgress().width(28).height(28) }
          if (!this.loading && !this.error && this.items.length === 0 && Runtime.store.isBound) { EmptyState({ title: this.segment === 0 ? '暂无持仓' : this.segment === 1 ? '暂无限价委托' : '暂无历史仓位记录' }) }
          if (this.hasNext) { ActionButton({ label: '加载更多', secondary: true, interactive: !this.loading, action: () => { this.load(true); } }) }
          ActionButton({ label: '刷新', secondary: true, interactive: !this.loading, action: () => { this.load(false); } })
        }.padding(16).width('100%').constraintSize({ maxWidth: 600 })
      }.layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor($r('app.color.page'))
  }
}
