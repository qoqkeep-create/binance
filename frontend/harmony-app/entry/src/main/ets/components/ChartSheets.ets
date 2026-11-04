import { Runtime } from '../platform/Runtime';
import { DataValue } from '../core/Json';
import { INTERVALS, INTERVAL_LABELS } from '../core/Market';
import { favoriteIntervals, visibleIntervals, toggleFavorite, DEFAULT_FAVORITES } from '../core/ChartSettings';
import { leverageOptions } from '../core/ChartTrading';
import { marketNumber } from '../core/MarketList';

@Component
export struct IntervalSheet {
  @Prop selected: string = '1h';
  @State favorites: string = DEFAULT_FAVORITES;
  close: () => void = () => {};
  select: (value: string) => void = () => {};
  changed: () => void = () => {};
  aboutToAppear(): void { this.favorites = Runtime.store.preferences.read('chart-favorites-v1', DEFAULT_FAVORITES); }
  private toggle(interval: string): void {
    const next = toggleFavorite(this.favorites, interval);
    if (next === favoriteIntervals(this.favorites).join(',')) { Runtime.store.report(new Error(favoriteIntervals(this.favorites).includes(interval) ? '至少保留一个快捷周期' : '最多保留六个快捷周期')); return; }
    this.favorites = next; Runtime.store.preferences.write('chart-favorites-v1', next); this.changed();
  }
  private gridIntervals(primary: boolean): string[] {
    const visible = visibleIntervals(this.favorites, this.selected); return primary ? visible : INTERVALS.filter((v: string) => !visible.includes(v));
  }
  @Builder
  private grid(primary: boolean) {
    Grid() {
      ForEach(this.gridIntervals(primary), (v: string) => {
        GridItem() {
          Row({ space: 0 }) {
            Text(INTERVAL_LABELS[INTERVALS.indexOf(v)]).fontSize(13).maxLines(1).minFontSize(10).fontColor(v === this.selected ? $r('app.color.auth_link') : $r('app.color.text_primary')).layoutWeight(1).height(44).textAlign(TextAlign.Center).onClick(() => { this.select(v); this.close(); }).id('interval.select.' + v)
            Column() { Image(favoriteIntervals(this.favorites).includes(v) ? $r('app.media.ui_star_filled') : $r('app.media.ui_star')).width(11).height(11).fillColor(favoriteIntervals(this.favorites).includes(v) ? $r('app.color.auth_accent') : $r('app.color.text_secondary')) }.width(27).height(44).justifyContent(FlexAlign.Center).onClick(() => this.toggle(v)).id('interval.favorite.' + v)
          }.width('100%').height(32).borderRadius(8).backgroundColor(v === this.selected ? $r('app.color.chart_interval_selected') : Color.Transparent).border({ width: v === this.selected ? 1 : 0, color: $r('app.color.auth_accent') })
        }.height(44)
      }, (v: string) => v)
    }.columnsTemplate('1fr 1fr 1fr 1fr').columnsGap(8).rowsGap(4).height(Math.ceil(this.gridIntervals(primary).length / 4) * 48).width('100%')
  }
  build() {
    Column({ space: 16 }) {
      Row() { Text('时间周期').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).layoutWeight(1); Text('×').fontSize(26).width(44).height(44).textAlign(TextAlign.Center).fontColor($r('app.color.text_primary')).onClick(this.close).id('interval.close') }.width('100%')
      Text('点击周期切换图表，点击星标设置快捷周期（最多6个）。').fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
      Text('图表周期').fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).width('100%')
      this.grid(true)
      Text('备选周期').fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).width('100%')
      this.grid(false)
      Text('恢复默认快捷周期').fontSize(12).fontColor($r('app.color.auth_link')).height(32).onClick(() => { this.favorites = DEFAULT_FAVORITES; Runtime.store.preferences.write('chart-favorites-v1', this.favorites); this.changed(); }).id('interval.reset')
      Blank()
    }.width('100%').height('100%').padding({ left: 20, right: 20, top: 12, bottom: 20 }).backgroundColor($r('app.color.background'))
  }
}
@Component
export struct LeverageSheet {
  @Prop symbol: string = '';
  @Prop current: number = 0;
  @State selected: number = 0;
  @State options: DataValue[] = [];
  @State loading: boolean = true;
  @State error: string = '';
  private active: boolean = false;
  private owner: string = '';
  close: () => void = () => {};
  save: (value: number) => void = () => {};
  aboutToAppear(): void { this.active = true; this.owner = Runtime.store.session.scope; this.selected = this.current; this.load(); }
  aboutToDisappear(): void { this.active = false; }
  private async load(): Promise<void> {
    this.loading = true; this.error = '';
    if (!Runtime.store.isBound) { this.loading = false; this.error = '请先在我的页面绑定 API'; return; }
    try {
      const result = await Runtime.store.session.request('/v1/trade/leverage-brackets?symbol=' + encodeURIComponent(this.symbol));
      if (!this.active || this.owner !== Runtime.store.session.scope) return;
      if (result.value('symbol') !== this.symbol) throw new Error('杠杆数据不匹配'); this.options = leverageOptions(result);
      if (!this.options.length) this.error = '暂无可用杠杆档位';
    } catch (_) { if (this.active) this.error = '杠杆档位加载失败，请重试'; }
    finally { if (this.active) this.loading = false; }
  }
  build() {
    Column({ space: 16 }) {
      Row() { Column({ space: 4 }) { Text('杠杆').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')); Text(this.symbol + ' · 当前 ' + (this.current ? '×' + this.current : '自动')).fontSize(12).fontColor($r('app.color.text_secondary')) }.alignItems(HorizontalAlign.Start).layoutWeight(1); Text('×').fontSize(26).width(44).height(44).textAlign(TextAlign.Center).fontColor($r('app.color.text_primary')).onClick(this.close).id('leverage.close') }.width('100%')
      Text('按当前账户可用保证金估算最大可开仓金额。所选杠杆仅用于下一次开仓。').fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
      if (this.loading) { LoadingProgress().width(32).height(32) }
      if (this.error) { Text(this.error).fontSize(14).fontColor($r('app.color.text_secondary')); if (Runtime.store.isBound) { Text('重新加载').fontSize(14).fontColor($r('app.color.auth_link')).onClick(() => this.load()).id('leverage.retry') } }
      ForEach(this.options, (row: DataValue) => {
        Row() {
          Column({ space: 8 }) { Text('×' + row.value('leverage')).fontSize(20).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')); Text('最大可开仓金额').fontSize(12).fontColor($r('app.color.text_secondary')) }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Text(marketNumber(row.value('max_open_amount')) + ' U').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          Text(this.selected === row.get('leverage').number() ? '●' : '○').fontSize(22).fontColor(this.selected === row.get('leverage').number() ? $r('app.color.auth_link') : $r('app.color.text_secondary')).margin({ left: 12 })
        }.padding(16).borderRadius(12).border({ width: 1, color: this.selected === row.get('leverage').number() ? $r('app.color.auth_accent') : $r('app.color.border') }).width('100%').onClick(() => { this.selected = row.get('leverage').number(); }).id('leverage.option.' + row.value('leverage'))
      }, (row: DataValue) => row.value('leverage'))
      Blank()
      Button('确定', { type: ButtonType.Normal }).height(48).width('100%').borderRadius(12).backgroundColor($r('app.color.auth_accent')).fontColor('#181A20').enabled(this.options.some((row: DataValue) => row.get('leverage').number() === this.selected))
        .onClick(() => { if (this.owner === Runtime.store.session.scope) this.save(this.selected); this.close(); }).id('leverage.save')
    }.padding(16).width('100%').height('100%').backgroundColor($r('app.color.page'))
  }
}
