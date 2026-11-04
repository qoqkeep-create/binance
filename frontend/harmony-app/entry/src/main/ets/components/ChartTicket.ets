import { Runtime } from '../platform/Runtime';
import { DataValue } from '../core/Json';
import { Decimal } from '../core/Decimal';
import { marketNumber } from '../core/MarketList';
import { EntryDraft, EntryFlow, ChartAccount, EntryContext } from '../core/ChartTrading';

@Component
export struct ChartTicket {
  @Prop @Watch('sync') revision: number = 0;
  @Prop @Watch('sync') symbol: string = '';
  @Prop @Watch('visibilityChanged') visible: boolean = true;
  @Prop stop: string = '';
  @Prop entry: string = '';
  @Prop orderType: string = 'market';
  @Prop leverage: number = 0;
  @State version: number = 0;
  @State includeFee: boolean = false;
  @State strategyId: string = '';
  @State strategyEnabled: boolean = true;
  @State showingStrategies: boolean = false;
  @State heldId: string = '';
  private account: ChartAccount = new ChartAccount();
  private flow: EntryFlow = new EntryFlow(Runtime.store.session, Runtime.store.commands, Runtime.store.clock, this.account);
  private active: boolean = false;
  private timer: number = -1;
  private lastAccountRevision: number = -1;
  private owner: string = '';
  private ticketSymbol: string = '';
  private strategyInitialized: boolean = false;
  navigate: (route: string) => void = () => {};
  showPositions: () => void = () => {};
  changeType: (value: string) => void = () => {};
  holdingsChanged: (value: string) => void = () => {};
  lockChanged: (value: boolean) => void = () => {};
  aboutToAppear(): void {
    this.active = true; this.owner = Runtime.store.session.scope;
    this.flow.changed = () => { if (this.active) { this.sync(); this.version++; this.publish(); this.lockChanged(this.locked()); } };
    this.sync(); this.schedule();
  }
  aboutToDisappear(): void { this.active = false; this.account.reset(); if (this.timer >= 0) clearTimeout(this.timer); this.timer = -1; }
  private visibilityChanged(): void { if (this.visible) { this.sync(); this.refresh(); } }
  private schedule(): void {
    if (!this.active) return;
    this.timer = setTimeout(() => { this.timer = -1; if (this.visible && Runtime.store.foreground) this.refresh(); this.schedule(); }, 10000);
  }
  private sync(): void {
    if (!this.active) return; const store = Runtime.store;
    if (this.owner !== store.session.scope) { this.owner = store.session.scope; this.account.reset(); this.strategyInitialized = false; this.strategyId = ''; this.strategyEnabled = true; this.flow.ema = new DataValue(); this.flow.submitted = false; }
    if (this.ticketSymbol !== this.symbol && !this.flow.busy) {
      this.ticketSymbol = this.symbol; this.flow.submitted = store.commands.pending().length > 0; this.flow.ema = new DataValue(); this.includeFee = false;
    }
    if (!this.strategyInitialized && store.strategies.length) { this.strategyId = store.strategies.find((s: DataValue) => s.get('is_active').flag())?.value('id', '') || ''; this.strategyInitialized = true; }
    if (this.lastAccountRevision !== store.accountRevision || this.account.owner !== store.session.scope) { this.lastAccountRevision = store.accountRevision; this.refresh(); }
    this.publish(); this.lockChanged(this.locked());
  }
  private async refresh(): Promise<void> {
    const store = Runtime.store; await this.account.refresh(store.session, store.isBound);
    if (!this.active) return; this.version++; this.publish(); this.lockChanged(this.locked());
  }
  private noticeText(): string { this.version; return this.flow.notice; }
  private accountError(): string { this.version; return this.account.error; }
  private isSubmitted(): boolean { this.version; return this.flow.submitted || Runtime.store.commands.pending().length > 0; }
  private publish(): void { this.holdingsChanged(JSON.stringify(this.positions().map((row: DataValue) => row.raw))); }
  private positions(): DataValue[] { this.version; return this.account.positions(this.symbol, Runtime.store.session.scope); }
  private held(): DataValue { return this.positions().find((r: DataValue) => r.value('id') === this.heldId) || this.positions()[0] || new DataValue(); }
  private hasPosition(): boolean { return this.positions().length > 0; }
  private locked(): boolean { this.version; return this.flow.busy || this.flow.confirming || this.flow.submitted || this.hasPosition(); }
  private currentPrice(): string {
    this.revision; const candles = Runtime.store.chart.candles; return candles.length ? new Decimal(candles[candles.length - 1].close.toFixed(12)).toString() : Runtime.store.tickers.find((t) => t.symbol === this.symbol)?.price || '';
  }
  private draft(): EntryDraft {
    this.revision; const d = new EntryDraft(); d.symbol = this.symbol; d.orderType = this.orderType; d.stop = this.stop; d.limit = this.entry; d.price = this.currentPrice();
    d.risk = Runtime.store.riskAmount; d.includeFee = this.includeFee; d.leverage = this.leverage;
    if (this.strategyEnabled) d.strategy = Runtime.store.strategies.find((s: DataValue) => s.value('id') === this.strategyId) || new DataValue(); return d;
  }
  private strategyValid(): boolean { return !this.strategyEnabled || !this.draft().strategy.empty(); }
  private bound(): boolean { this.revision; return Runtime.store.isBound; }
  private availableStrategies(): DataValue[] { this.revision; return Runtime.store.strategies; }
  private context(): EntryContext { return { active: this.active && this.visible && Runtime.store.foreground, bound: Runtime.store.isBound }; }
  private canSubmit(): boolean {
    this.version; return this.hasPosition() || (!this.locked() && Runtime.store.isBound && this.draft().valid() && this.strategyValid() && this.account.ready && this.account.owner === Runtime.store.session.scope);
  }
  private label(): string {
    this.version;
    if (this.hasPosition()) return '正在持仓中  ›';
    if (Runtime.store.isBound && !this.account.ready) return this.account.error ? '持仓读取失败，点击重试' : '正在确认持仓…';
    if (this.flow.submitted) return '已提交'; if (this.flow.busy) return '处理中…';
    return this.draft().valid() ? this.draft().side() === 'long' ? '开多' : '开空' : '在 K 线图上选择止损价开仓';
  }
  private value(key: string): string { return marketNumber(this.held().value(key, '')); }
  private heldStop(): string { const r = this.held(); return marketNumber(r.get('market_stop_set').flag() ? r.value('market_stop_price', r.value('stop_loss_price')) : r.value('stop_loss_price')); }
  private heldFee(): string {
    const r = this.held(); if (r.value('entry_fee_status') === 'confirmed') return this.value('entry_realized_fee') + ' ' + r.value('entry_fee_asset', 'USDT');
    try { return '≈' + marketNumber(new Decimal(r.value('estimated_total_fee')).abs().divide(new Decimal('2')).toString()) + ' U'; } catch (_) { return '-'; }
  }
  private strategyName(): string {
    if (this.hasPosition()) { const r = this.held(); return r.get('manual_take_profit_set').flag() ? this.value('manual_take_profit_price') : r.value('strategy_status') === '1' ? r.value('strategy_name', '策略止盈') : '手动止盈'; }
    return this.strategyEnabled ? this.draft().strategy.value('name', '选择策略') : '手动止盈';
  }
  private async advance(): Promise<void> {
    if (this.hasPosition()) { this.showPositions(); return; }
    if (!this.account.ready) { await this.refresh(); return; }
    if (!this.canSubmit()) return;
    await this.flow.advance(() => this.draft(), () => this.context(), async (draft: EntryDraft): Promise<boolean> => {
      try {
        const result = await this.getUIContext().getPromptAction().showDialog({ title: draft.orderType === 'limit' ? '确认限价开仓' : '确认市价开仓',
          message: draft.symbol + ' · ' + (draft.side() === 'long' ? '做多' : '做空') + '\n开仓价：' + (draft.orderType === 'market' ? '市价' : draft.limit) + '\n止损价：' + draft.stop + '\n止损金额：' + marketNumber(draft.risk) + ' U\n预估仓位：' + marketNumber(draft.estimate()) + ' U\n杠杆：' + (draft.leverage ? '×' + draft.leverage : '自动') + '\n止盈：' + draft.strategy.value('name', '手动止盈'),
          buttons: [{ text: '取消', color: $r('app.color.text_secondary') }, { text: '确认开仓', color: $r('app.color.auth_link') }] }); return result.index === 1;
      } catch (_) { return false; }
    });
  }
  private metricTitle(kind: number): string { return kind === 0 ? '开仓价' : kind === 1 ? '止损价' : this.hasPosition() ? '仓位' : '预估仓位'; }
  private metricValue(kind: number): string {
    if (this.hasPosition()) return kind === 0 ? this.value('open_price') : kind === 1 ? this.heldStop() : this.value('position_amount') + ' U';
    if (!this.draft().valid()) return '-';
    return kind === 0 ? this.orderType === 'market' ? '市价' : marketNumber(this.entry) : kind === 1 ? marketNumber(this.stop) : marketNumber(this.draft().estimate()) + ' U';
  }
  @Builder
  private metric(kind: number) {
    Column({ space: 4 }) { Text(this.metricTitle(kind)).fontSize(12).fontColor($r('app.color.text_secondary')).maxLines(1); Text(this.metricValue(kind)).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).maxLines(1).minFontSize(10).id('ticket.metric.' + this.metricTitle(kind)) }.alignItems(HorizontalAlign.Start).layoutWeight(1)
  }
  @Builder
  private strategies() {
    Column({ space: 0 }) {
      Row() { Text('止盈止损策略').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).layoutWeight(1); Text('×').fontSize(26).fontColor($r('app.color.text_primary')).width(44).height(44).textAlign(TextAlign.Center).onClick(() => { this.showingStrategies = false; }).id('ticket.strategy.close') }.padding(16).width('100%')
      Scroll() {
        Column({ space: 12 }) {
          Text('手动止盈').fontSize(16).fontColor($r('app.color.text_primary')).width('100%').padding(20).borderRadius(12).border({ width: 1, color: !this.strategyEnabled ? $r('app.color.auth_accent') : $r('app.color.border') }).onClick(() => { this.strategyEnabled = false; this.strategyId = ''; this.flow.ema = new DataValue(); this.showingStrategies = false; }).id('ticket.strategy.manual')
          ForEach(this.availableStrategies(), (s: DataValue) => {
            Column({ space: 10 }) {
              Text(s.value('name')).fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).width('100%')
              ForEach(s.get('levels').rows(), (level: DataValue, i: number) => { Text('L' + (i + 1) + '   ' + level.value('profitRR') + ' R  ·  减仓 ' + level.value('reducePosition') + '%').fontSize(13).fontColor($r('app.color.text_secondary')).width('100%') })
            }.width('100%').padding(16).borderRadius(12).border({ width: 1, color: this.strategyEnabled && this.strategyId === s.value('id') ? $r('app.color.auth_accent') : $r('app.color.border') })
              .onClick(() => { this.strategyEnabled = true; this.strategyId = s.value('id'); this.flow.ema = new DataValue(); this.showingStrategies = false; }).id('ticket.strategy.' + s.value('id'))
          }, (s: DataValue) => s.value('id'))
        }.padding(16).width('100%')
      }.align(Alignment.Top).layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor($r('app.color.background'))
  }
  build() {
    Column({ space: 14 }) {
      if (this.positions().length > 1) {
        Select(this.positions().map((r: DataValue): SelectOption => ({ value: r.value('side') === '0' ? '多仓' : '空仓' }))).value(this.held().value('side') === '0' ? '多仓' : '空仓').onSelect((i: number) => { this.heldId = this.positions()[i].value('id'); }).id('ticket.held-side')
      }
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          this.metric(0)
          this.metric(1)
          this.metric(2)
        }.width('100%')
        Divider().strokeWidth(0.5).color($r('app.color.border'))
        Row({ space: 8 }) {
          Column({ space: 5 }) {
            Text('止损金额').fontSize(12).fontColor($r('app.color.text_secondary')).height(24)
            Text(this.hasPosition() ? this.value('stop_loss_amount') + ' U' : this.draft().valid() ? marketNumber(Runtime.store.riskAmount) + ' U  ›' : '-')
              .fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).maxLines(1).minFontSize(10).height(28).onClick(() => { if (!this.locked()) this.navigate('stop-loss'); }).id('ticket.risk')
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Column({ space: 5 }) {
            Row({ space: 4 }) {
              Text(this.hasPosition() ? '手续费' : '含手续费').fontSize(12).fontColor($r('app.color.text_secondary'))
              if (!this.hasPosition()) { Toggle({ type: ToggleType.Switch, isOn: this.includeFee }).width(30).height(18).selectedColor($r('app.color.auth_accent')).onChange((v: boolean) => { this.includeFee = v; this.flow.ema = new DataValue(); }).enabled(!this.locked()).id('ticket.fee') }
            }.height(24)
            Text(this.hasPosition() ? this.heldFee() : this.draft().valid() ? marketNumber(this.draft().fee()) + ' U' : '-').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).maxLines(1).minFontSize(10).height(28).id('ticket.fee-value')
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Column({ space: 5 }) {
            Text('止盈').fontSize(12).fontColor($r('app.color.text_secondary')).height(24)
            Text(this.strategyName()).fontSize(13).fontWeight(FontWeight.Medium).fontColor('#181A20').height(28).maxLines(1).minFontSize(9).padding({ left: 8, right: 8 }).backgroundColor($r('app.color.auth_accent')).borderRadius(6).onClick(() => { if (!this.locked()) this.showingStrategies = true; }).id('ticket.strategy')
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        }.width('100%')
      }.padding({ left: 10, right: 10, top: 12, bottom: 12 }).width('100%').backgroundColor($r('app.color.chart_ticket')).borderRadius(10)
      Row({ space: 12 }) {
        Row() {
          ForEach(['market', 'limit'], (v: string) => { Text(v === 'market' ? '市价' : '限价').fontSize(13).fontColor($r('app.color.text_primary')).height(30).width(54).borderRadius(6).textAlign(TextAlign.Center).backgroundColor(this.orderType === v ? $r('app.color.surface') : Color.Transparent).onClick(() => { if (!this.locked()) { this.flow.ema = new DataValue(); this.changeType(v); } }).id('ticket.type.' + v) })
        }.width(112).height(34).padding(2).borderRadius(8).backgroundColor($r('app.color.input')).opacity(this.locked() ? 0.5 : 1)
        Button(this.label(), { type: ButtonType.Normal }).layoutWeight(1).height(44).borderRadius(8).fontSize(this.draft().valid() || this.hasPosition() ? 16 : 12).fontWeight(FontWeight.Medium)
          .fontColor(this.hasPosition() ? '#181A20' : '#FFFFFF').backgroundColor(this.hasPosition() ? $r('app.color.auth_accent') : this.draft().valid() && this.draft().side() === 'short' ? $r('app.color.chart_negative') : $r('app.color.chart_positive'))
          .onClick(() => this.advance()).id('ticket.submit')
      }.width('100%')
      if (!this.bound()) { Text('请先在我的页面绑定 API').fontSize(11).fontColor($r('app.color.text_secondary')).width('100%') }
      if (this.noticeText()) { Text(this.noticeText()).fontSize(11).fontColor($r('app.color.auth_link')).width('100%').id('ticket.notice') }
      if (this.accountError()) { Text(this.accountError()).fontSize(11).fontColor($r('app.color.negative')).width('100%') }
      if (this.isSubmitted()) { Text('查看交易命令').fontSize(12).fontColor($r('app.color.auth_link')).width('100%').onClick(() => this.navigate('commands')).id('ticket.commands') }
    }.padding({ left: 16, right: 16, top: 14, bottom: 12 }).width('100%').backgroundColor($r('app.color.surface')).border({ width: { top: 1 }, color: $r('app.color.chart_ticket_border') })
      .bindSheet($$this.showingStrategies, this.strategies, { height: '80%', dragBar: true, showClose: false, preferType: SheetType.BOTTOM, backgroundColor: $r('app.color.background') })
  }
}
