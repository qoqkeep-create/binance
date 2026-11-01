import { Runtime } from '../platform/Runtime';
import { DataValue } from '../core/Json';
import { Decimal, amount, validPositive } from '../core/Decimal';
import { Ticker } from '../core/Market';
import { commandMessage } from '../core/Commands';
import { ActionButton, ChoiceBar, SectionCard, Field, Metric, EmptyState, confirmAction, GREEN, RED } from '../components/Ui';

@Component
export struct TradePage {
  @Prop revision: number = 0;
  initialStop: string = '';
  initialEntry: string = '';
  @State symbol: string = 'BTCUSDT';
  @State stop: string = '';
  @State limit: string = '';
  @State risk: string = '';
  @State orderType: number = 0;
  @State includeFee: boolean = false;
  @State strategyIndex: number = 0;
  @State ema: DataValue = new DataValue();
  @State busy: boolean = false;
  @State locked: boolean = false;
  @State resultText: string = '';
  private active: boolean = true;
  navigate: (route: string) => void = () => {};
  openChart: (symbol: string) => void = () => {};
  aboutToAppear(): void { this.symbol = Runtime.store.selectedSymbol; this.stop = this.initialStop; this.limit = this.initialEntry; this.orderType = this.limit ? 1 : 0; this.risk = Runtime.store.riskAmount; this.active = true; }
  aboutToDisappear(): void { this.active = false; }
  private strategies(): DataValue[] { this.revision; return Runtime.store.strategies; }
  private strategyOptions(): SelectOption[] {
    const options: SelectOption[] = [{ value: '手动止盈' }];
    return options.concat(this.strategies().map((v: DataValue): SelectOption => { return { value: v.value('name') }; }));
  }
  private price(): string { this.revision; return Runtime.store.tickers.find((v: Ticker) => v.symbol === this.symbol)?.price || '--'; }
  private tradeSide(): string {
    try { return new Decimal(this.stop).compare(new Decimal(this.orderType === 1 ? this.limit : this.price())) < 0 ? 'long' : 'short'; } catch (_) { return ''; }
  }
  private valid(): boolean {
    this.revision;
    return Runtime.store.isBound && /^[A-Z0-9]{2,32}$/.test(this.symbol) && validPositive(this.stop) && validPositive(this.risk || Runtime.store.riskAmount)
      && validPositive(this.orderType === 1 ? this.limit : this.price())
      && this.differentPrices() && !this.locked && !this.busy;
  }
  private differentPrices(): boolean {
    try { return new Decimal(this.stop).compare(new Decimal(this.orderType === 1 ? this.limit : this.price())) !== 0; } catch (_) { return false; }
  }
  private emaValid(): boolean {
    let sameStop = false;
    try { sameStop = new Decimal(this.ema.value('stop_loss_price')).compare(new Decimal(this.stop)) === 0; } catch (_) { return false; }

    return sameStop && this.ema.value('symbol') === this.symbol && this.ema.value('side') === this.tradeSide() && this.ema.get('has_any_matching_interval').flag()
      && Date.parse(this.ema.value('expires_at')) > Date.now();
  }
  private estimate(): string {
    try {
      const price = new Decimal(this.orderType === 1 ? this.limit : this.price()); const distance = price.subtract(new Decimal(this.stop)).abs();
      const ratio = distance.divide(price).add(new Decimal(this.orderType === 0 && this.includeFee ? '0.001' : '0'));
      return new Decimal(this.risk || Runtime.store.riskAmount).divide(ratio).fixed(2);
    } catch (_) { return '--'; }
  }
  private async proceed(): Promise<void> {
    if (!this.valid()) return;
    this.busy = true; const store = Runtime.store; const scope = store.session.scope;
    try {
      await store.preflight('entry');
      if (!this.active || scope !== store.session.scope) return;
      if (this.orderType === 0 && !this.emaValid()) {
        this.ema = await store.session.request('/v1/trade/ema-check', 'POST', DataValue.object({ symbol: this.symbol, stop_loss_price: this.stop }));
        return;
      }
      const fields = DataValue.object({ symbol: this.symbol, stop_loss_price: this.stop, stop_loss_amount: this.risk || store.riskAmount }).fields();
      if (this.orderType === 1) fields['limit_price'] = this.limit;
      else { fields['include_fee'] = this.includeFee; fields['ema_check_id'] = this.ema.get('check_id').raw; }
      if (this.strategyIndex > 0) {
        const strategy = store.strategies[this.strategyIndex - 1];
        if (!strategy) throw new Error('策略已变化，请重新选择');
        fields['strategy_id'] = strategy.get('id').raw; fields['strategy_name'] = strategy.get('name').raw; fields['strategy_config'] = strategy.get('levels').raw;
      }
      const payload = DataValue.object(fields); const action = this.orderType === 1 ? 'limit-create' : 'open';
      const checkedStop = this.stop; const checkedEma = this.ema.value('check_id', '');
      await confirmAction(this.orderType === 1 ? '委托确认' : '开仓确认', this.symbol + ' · ' + (this.tradeSide() === 'long' ? '做多' : '做空') + '\n止损价：' + this.stop + '\n止损金额：' + fields['stop_loss_amount'] + ' USDT' + (this.orderType === 1 ? '\n限价：' + this.limit : ''), async () => {
        if (!this.active || scope !== store.session.scope) return;
        if (this.stop !== checkedStop || this.ema.value('check_id', '') !== checkedEma) throw new Error('表单已变化，请重新确认');
        if (this.orderType === 0 && !this.emaValid()) throw new Error('方向初筛已过期，请重新检测');
        this.locked = true;
        const result = await store.commands.submit(action, payload); this.resultText = commandMessage(result);
        if (['SUCCEEDED', 'FAILED'].includes(result.value('status'))) this.locked = false;
        await store.refreshAccount();
      });
    } catch (e) { store.report(e as Error); }
    finally { this.busy = false; }
  }
  build() {
    Scroll() {
      Column({ space: 16 }) {
        if (!Runtime.store.isBound) { EmptyState({ title: '请先绑定 Binance API', detail: '绑定后可设置止损额和提交交易' }); ActionButton({ label: '绑定 API', action: () => this.navigate('binding') }) }
        SectionCard() {
          Field({ label: '交易对', placeholder: 'BTCUSDT', value: $symbol, interactive: !this.locked && !this.busy })
          ChoiceBar({ labels: ['市价开仓', '限价委托'], selected: $orderType, changed: () => { this.ema = new DataValue(); } }).enabled(!this.locked && !this.busy)
          Row() {
            Text(this.price()).fontSize(24).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).layoutWeight(1)
            Button('K 线').fontSize(13).backgroundColor($r('app.color.input')).fontColor($r('app.color.text_primary')).onClick(() => this.openChart(this.symbol))
          }.width('100%')
          if (this.orderType === 1) { Field({ label: '限价', value: $limit, numeric: true, interactive: !this.locked && !this.busy }) }
          Field({ label: '止损价', value: $stop, numeric: true, interactive: !this.locked && !this.busy })
          Field({ label: '止损金额（USDT）', placeholder: Runtime.store.riskAmount || '请先设置止损金额', value: $risk, numeric: true, interactive: !this.locked && !this.busy })
          Select(this.strategyOptions())
            .selected(this.strategyIndex).value(this.strategyIndex > 0 ? Runtime.store.strategies[this.strategyIndex - 1]?.value('name') || '请选择策略' : '手动止盈')
            .onSelect((index: number) => { this.strategyIndex = index; }).enabled(!this.locked && !this.busy).width('100%')
          if (this.orderType === 0) {
            Row() { Checkbox({ name: 'includeFee' }).select(this.includeFee).onChange((value: boolean) => { this.includeFee = value; }).enabled(!this.locked && !this.busy); Text('止损金额包含手续费估算').fontSize(13).fontColor($r('app.color.text_secondary')) }
          }
          Metric({ label: '方向', value: this.tradeSide() === 'long' ? '做多' : this.tradeSide() === 'short' ? '做空' : '--', color: this.tradeSide() === 'long' ? GREEN : RED })
          Metric({ label: '预估名义仓位（USDT）', value: this.estimate() })
        }
        if (!this.ema.empty() && this.orderType === 0) {
          SectionCard() {
            Text(this.emaValid() ? '方向初筛通过 · 3分钟内有效' : '方向初筛未通过或已过期').fontSize(14).fontColor(this.emaValid() ? GREEN : '#F0B90B')
            ForEach(this.ema.get('items').rows(), (item: DataValue) => { Metric({ label: item.value('label'), value: item.get('supported').flag() ? item.get('matches_direction').flag() ? '支持' : '不支持' : '数据不足', color: item.get('matches_direction').flag() ? GREEN : RED }) })
          }
        }
        if (this.resultText) { Text(this.resultText).fontSize(13).fontColor($r('app.color.text_secondary')) }
        ActionButton({ label: this.locked ? '请求待确认，请查看交易命令' : this.busy ? '处理中…' : this.orderType === 0 && !this.emaValid() ? '方向初筛' : (this.orderType === 1 ? '限价开' : '市价开') + (this.tradeSide() === 'long' ? '多' : '空'), interactive: this.valid(), color: this.tradeSide() === 'short' ? RED : GREEN, action: () => { this.proceed(); } })
        ActionButton({ label: '交易命令', secondary: true, action: () => this.navigate('commands') })
      }.padding(16).width('100%').constraintSize({ maxWidth: 600 })
    }.width('100%').height('100%').backgroundColor($r('app.color.page'))
  }
}
