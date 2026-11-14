import { Runtime } from '../platform/Runtime';
import { DataValue } from '../core/Json';
import { amount, validPositive } from '../core/Decimal';
import { commandMessage } from '../core/Commands';
import { SectionCard, Metric, Field, ActionButton, ChoiceBar, confirmAction, dateText, GREEN, RED, GOLD } from '../components/Ui';

@Component
export struct PositionDetailPage {
  initial: DataValue = new DataValue();
  historical: boolean = false;
  @State positionData: DataValue = new DataValue();
  @State takeProfit: string = '';
  @State orderType: number = 0;
  @State strategy: number = 0;
  @State busy: boolean = false;
  @State available: boolean = true;
  @State message: string = '';
  openChart: (symbol: string) => void = () => {};
  openLogs: (id: string) => void = () => {};
  private active: boolean = true;
  aboutToAppear(): void { this.active = true; this.positionData = this.initial; if (!this.historical) this.refresh(); }
  aboutToDisappear(): void { this.active = false; }
  private async refresh(): Promise<void> {
    const list = await Runtime.store.session.request('/v1/position/list');
    if (!this.active) return;
    const row = list.items().find((v: DataValue) => v.value('id') === this.initial.value('id'));
    this.available = !!row; if (row) this.positionData = row;
    else this.message = '该仓位已不在当前持仓列表，请查看历史仓位与交易命令。';
  }
  private execute(action: string, title: string, extra: DataValue = DataValue.object()): void {
    const payload = DataValue.parse(extra.json()); payload.fields()['position_id'] = this.positionData.get('id').raw;
    confirmAction(title, this.positionData.value('symbol') + ' #' + this.positionData.value('id') + '\n当前浮盈亏：' + amount(this.positionData.value('pnl')) + ' USDT\n' + extra.json(), async () => {
      if (this.busy || !this.active || !this.available) return; this.busy = true;
      try { const result = await Runtime.store.commands.submit(action, payload); this.message = commandMessage(result); await this.refresh(); await Runtime.store.refreshAccount(); }
      finally { this.busy = false; }
    });
  }
  build() {
    Scroll() {
      Column({ space: 16 }) {
        SectionCard() {
          Row() {
            Text(this.positionData.value('symbol')).fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).layoutWeight(1)
            Text(['0', 'long'].includes(this.positionData.value('side')) ? '多' : '空').fontColor(['0', 'long'].includes(this.positionData.value('side')) ? GREEN : RED)
          }.width('100%')
          Metric({ label: this.historical ? '净盈亏' : '浮动盈亏', value: amount(this.positionData.value('pnl')) + ' USDT', color: this.positionData.get('pnl').number() >= 0 ? GREEN : RED })
          ForEach(['open_price', 'current_price', 'close_price', 'size', 'exchange_size', 'position_amount', 'leverage', 'stop_loss_price', 'initial_stop_price', 'stop_loss_amount', 'stop_loss_pnl', 'estimated_total_fee', 'entry_realized_fee', 'entry_fee_status', 'stop_protection_status', 'manual_take_profit_price', 'strategy_name', 'strategy_status', 'settlement_status', 'settlement_error'], (key: string, index: number) => {
            if (!this.positionData.get(key).empty()) { Metric({ label: ['开仓价', '当前价', '平仓价', '原始数量', '交易所数量', '名义仓位', '杠杆', '当前止损价', '初始止损价', '止损金额', '止损盈亏', '总手续费估算', '开仓实际手续费', '手续费状态', '保护状态', '手动止盈价', '策略名称', '策略状态', '结算状态', '结算说明'][index], value: this.positionData.value(key) }) }
          })
          if (this.positionData.value('stop_protection_error', '')) { Text(this.positionData.value('stop_protection_error')).fontColor(RED).fontSize(13) }
          Metric({ label: '开仓时间', value: dateText(this.positionData.value('created_at')) })
          if (this.historical) { Metric({ label: '平仓时间', value: dateText(this.positionData.value('closed_at')) }) }
          ActionButton({ label: '查看 K 线', secondary: true, action: () => this.openChart(this.positionData.value('symbol')) })
          ActionButton({ label: '策略和执行日志', secondary: true, action: () => this.openLogs(this.positionData.value('id')) })
        }
        if (!this.historical && this.available) {
          if (this.positionData.value('strategy_status') !== 'running') {
          SectionCard() {
            Field({ label: '手动止盈价', value: $takeProfit, numeric: true, interactive: !this.busy })
            ChoiceBar({ labels: ['市价止盈', '限价止盈'], selected: $orderType }).enabled(!this.busy)
            Text('手动止盈仅适用于未绑定策略的持仓；已绑定策略的持仓由策略自动止盈。').fontSize(12).fontColor($r('app.color.text_secondary'))
            ActionButton({ label: '设置止盈', interactive: !this.busy && validPositive(this.takeProfit), action: () => this.execute('take-profit', '设置手动止盈', DataValue.object({ take_profit_price: this.takeProfit, order_type: this.orderType === 0 ? 'market' : 'limit' })) })
            if (this.positionData.get('manual_take_profit_set').flag()) {
              ActionButton({ label: '取消手动止盈', secondary: true, interactive: !this.busy, action: () => {
                const payload = DataValue.object({ position_id: this.positionData.get('id').raw });
                confirmAction('取消手动止盈', '确认取消 ' + this.positionData.value('symbol') + ' 的手动止盈单？', async () => { if (this.busy) return; this.busy = true; try { await Runtime.store.session.request('/v1/position/take-profit', 'DELETE', payload); await this.refresh(); } finally { this.busy = false; } });
              } })
            }
          }
          }
          if (this.positionData.value('strategy_status') !== 'running') {
          SectionCard() {
            Text('保本处理').fontSize(16).fontColor($r('app.color.text_primary')).fontWeight(FontWeight.Bold)
            Text('盈利时移动止损；亏损时按服务器规则设置回价止盈。').fontSize(12).fontColor($r('app.color.text_secondary'))
            ActionButton({ label: '保本（含手续费）', secondary: true, interactive: !this.busy, action: () => this.execute('break-even', '设置保本损（含手续费）', DataValue.object({ mode: 'with_fee' })) })
            ActionButton({ label: '保本（不含手续费）', secondary: true, interactive: !this.busy, action: () => this.execute('break-even', '设置保本损（不含手续费）', DataValue.object({ mode: 'without_fee' })) })
          }
          }
          SectionCard() {
            if (this.positionData.get('can_bind_strategy').flag()) {
              Select(Runtime.store.strategies.map((v: DataValue): SelectOption => { return { value: v.value('name') }; })).selected(this.strategy).value(Runtime.store.strategies[this.strategy]?.value('name') || '选择策略').onSelect((i: number) => { this.strategy = i; }).width('100%')
              ActionButton({ label: '添加自动止盈策略', interactive: !this.busy && Runtime.store.strategies.length > this.strategy, action: () => { const strategy = Runtime.store.strategies[this.strategy]; if (strategy) this.execute('strategy-rebind', '添加自动止盈策略', DataValue.object({ strategy_id: strategy.get('id').raw })); } })
            }
          }
          ActionButton({ label: this.busy ? '处理中…' : '立即平仓', color: RED, interactive: !this.busy, action: () => this.execute('position-close', '立即平仓') })
          ActionButton({ label: '刷新仓位', secondary: true, interactive: !this.busy, action: () => { this.refresh().catch((e: Error) => Runtime.store.report(e)); } })
        }
        if (this.message) { Text(this.message).fontSize(13).fontColor(GOLD) }
      }.padding(16).width('100%').constraintSize({ maxWidth: 600 })
    }.width('100%').height('100%').backgroundColor($r('app.color.page'))
  }
}
