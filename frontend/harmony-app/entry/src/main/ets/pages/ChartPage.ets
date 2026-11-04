import { Runtime } from '../platform/Runtime';
import { INTERVALS, INTERVAL_LABELS } from '../core/Market';
import { marketNumber } from '../core/MarketList';
import { Decimal } from '../core/Decimal';
import { OVERLAYS, PANELS, visibleIntervals, DEFAULT_FAVORITES } from '../core/ChartSettings';
import { KlineCanvas } from '../components/KlineCanvas';
import { ChartTicket } from '../components/ChartTicket';
import { IntervalSheet, LeverageSheet } from '../components/ChartSheets';
import { MarketPairPicker } from '../components/MarketPairPicker';
import { IndicatorSettingsPage } from './IndicatorSettingsPage';
import { NavigationHeader } from '../components/NavigationChrome';

@Component
export struct ChartPage {
  @Prop @Watch('syncPrice') revision: number = 0;
  @Prop @Watch('handleBack') backRequest: number = 0;
  @Prop active: boolean = true;
  @State stop: string = '';
  @State entry: string = '';
  @State limitStop: string = '';
  @State type: string = 'market';
  @State sheetOpen: boolean = false;
  @State editor: string = '';
  @State settingsRevision: number = 0;
  @State held: string = '[]';
  @State locked: boolean = false;
  private sheetKind: string = '';
  private pendingSymbol: string = '';
  private leverageOwner: string = '';
  navigate: (route: string) => void = () => {};
  back: () => void = () => {};
  showPositions: () => void = () => {};
  aboutToAppear(): void { Runtime.store.loadDefaultLeverage(Runtime.store.selectedSymbol); }
  private symbol(): string { this.revision; return Runtime.store.selectedSymbol; }
  private interval(): string { this.revision; return Runtime.store.interval; }
  private favorite(): boolean { this.revision; return Runtime.store.watchlist.includes(this.symbol()); }
  private selectedLeverage(): number { this.revision; return Runtime.store.selectedLeverage(this.symbol()); }
  private leverageLabel(): string { this.revision; const value = Runtime.store.displayedLeverage(this.symbol()); return value ? '杠杆 × ' + value : '杠杆 · 读取中'; }
  private chartPending(): boolean { this.revision; return Runtime.store.chartPending; }
  private selection(key: string, fallback: string): string { this.settingsRevision; this.revision; return Runtime.store.preferences.read(key, fallback); }
  private price(): string {
    this.revision; const candles = Runtime.store.chart.candles; return candles.length ? candles[candles.length - 1].close.toFixed(12) : Runtime.store.tickers.find((t) => t.symbol === Runtime.store.selectedSymbol)?.price || '';
  }
  private change(): string { this.revision; const ticker = Runtime.store.tickers.find((t) => t.symbol === Runtime.store.selectedSymbol); return ticker ? (ticker.change >= 0 ? '+' : '') + ticker.change.toFixed(2) + '%' : '--'; }
  private toggle(name: string, overlay: boolean): void {
    const key = overlay ? 'chart-main' : 'chart-panels'; const values = this.selection(key, overlay ? 'EMA,SUPER' : 'MACD,VOL').split(',').filter((v: string) => !!v);
    Runtime.store.preferences.write(key, (values.includes(name) ? values.filter((v: string) => v !== name) : values.concat([name])).join(',')); this.settingsRevision++;
  }
  private selectInterval(value: string): void { if (Runtime.store.interval === value) return; if (this.type === 'market') this.stop = ''; Runtime.store.selectChart(Runtime.store.selectedSymbol, value); }
  private changeType(value: string): void {
    if (value === 'market') { if (this.type === 'limit') this.limitStop = this.stop; this.type = value; this.stop = ''; return; }
    const selected = this.type === 'market' ? this.stop : ''; this.type = value;
    if (this.entry && this.limitStop) { this.stop = this.limitStop; return; }
    if (Number(this.price()) > 0) {
      const price = new Decimal(this.price()); const useSelected = Number(selected) > 0 && new Decimal(selected).compare(price) !== 0;
      this.entry = useSelected ? price.toString() : price.multiply(new Decimal('0.996')).toString();
      this.stop = useSelected ? selected : price.multiply(new Decimal('0.986')).toString(); this.limitStop = this.stop;
    }
  }
  private handleBack(): void { if (this.sheetOpen) this.sheetOpen = false; else if (this.editor) this.editor = ''; else this.back(); }
  private syncPrice(): void {
    if (this.type === 'limit' && !this.entry && Number(this.price()) > 0) this.changeType('limit');
    const owner = Runtime.store.session.scope + ':' + Runtime.store.selectedSymbol;
    if (owner !== this.leverageOwner) { this.leverageOwner = owner; Runtime.store.loadDefaultLeverage(Runtime.store.selectedSymbol); }
  }
  private showSheet(kind: string): void { this.sheetKind = kind; this.sheetOpen = true; }
  private afterSheet(): void {
    if (!this.pendingSymbol) return; const symbol = this.pendingSymbol; this.pendingSymbol = '';
    if (symbol === Runtime.store.selectedSymbol) return; this.stop = ''; this.entry = ''; this.limitStop = ''; this.type = 'market'; this.held = '[]';
    Runtime.store.selectChart(symbol, Runtime.store.interval); Runtime.store.loadDefaultLeverage(symbol);
  }
  @Builder
  private sheet() {
    if (this.sheetKind === 'pairs') {
      MarketPairPicker({ revision: this.revision, selectedSymbol: this.symbol(), select: (symbol: string) => { this.pendingSymbol = symbol; this.sheetOpen = false; }, close: () => { this.sheetOpen = false; } })
    } else if (this.sheetKind === 'interval') {
      IntervalSheet({ selected: this.interval(), select: (value: string) => this.selectInterval(value), close: () => { this.sheetOpen = false; }, changed: () => { this.settingsRevision++; } })
    } else if (this.sheetKind === 'leverage') {
      LeverageSheet({ symbol: this.symbol(), current: Runtime.store.displayedLeverage(this.symbol()), close: () => { this.sheetOpen = false; }, save: (value: number) => { if (!this.locked) Runtime.store.selectLeverage(Runtime.store.selectedSymbol, value); } })
    }
  }
  @Builder
  private tool(icon: Resource, label: string, id: string, action: () => void, width: number = 44) {
    Column({ space: 2 }) { Image(icon).width(18).height(20).fillColor($r('app.color.text_primary')).draggable(false); Text(id === 'chart.leverage' ? this.leverageLabel() : label).fontSize(9).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).maxLines(1) }.width(width).height(44).justifyContent(FlexAlign.Center).onClick(action).id(id)
  }
  @Builder
  private header() {
    Row({ space: 6 }) {
      Column() { Image($r('app.media.ui_back')).width(20).height(20).fillColor($r('app.color.text_primary')) }.width(40).height(44).justifyContent(FlexAlign.Center).onClick(this.back).id('chart.back')
      Column({ space: 1 }) {
        Text(this.symbol() + ' ⌄').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).maxLines(1).minFontSize(10)
        Row({ space: 4 }) { Text(marketNumber(this.price())).fontSize(10).fontWeight(FontWeight.Medium).fontColor(this.change().startsWith('-') ? $r('app.color.negative') : $r('app.color.positive')); Text(this.change()).fontSize(10).fontWeight(FontWeight.Medium).fontColor(this.change().startsWith('-') ? $r('app.color.negative') : $r('app.color.positive')) }
      }.height(44).layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Start).onClick(() => this.showSheet('pairs')).id('chart.symbol')
      Row({ space: 0 }) {
        this.tool($r('app.media.chart_indicators'), '指标', 'chart.indicators', () => { this.editor = 'indicators'; })
        this.tool($r('app.media.chart_leverage'), '', 'chart.leverage', () => this.showSheet('leverage'), 62)
        this.tool($r('app.media.chart_settings'), '设置', 'chart.settings', () => { this.editor = 'settings'; })
      }
      Column() { Image(this.favorite() ? $r('app.media.ui_star_filled') : $r('app.media.ui_star')).width(18).height(18).fillColor(this.favorite() ? $r('app.color.auth_accent') : $r('app.color.text_secondary')) }.width(44).height(44).justifyContent(FlexAlign.Center).onClick(() => Runtime.store.toggleWatch(Runtime.store.selectedSymbol)).id('chart.favorite')
    }.width('100%').height(53).padding({ left: 4, right: 11 }).border({ width: { bottom: 0.5 }, color: $r('app.color.border') })
  }
  @Builder
  private indicatorGroup(title: string, names: string[], overlay: boolean) {
    Row({ space: 2 }) {
      Text(title).fontSize(10).fontColor($r('app.color.text_secondary')).margin({ right: 2 })
      ForEach(names, (name: string) => {
        Text(name).fontSize(13).fontWeight(this.selection(overlay ? 'chart-main' : 'chart-panels', overlay ? 'EMA,SUPER' : 'MACD,VOL').split(',').includes(name) ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.selection(overlay ? 'chart-main' : 'chart-panels', overlay ? 'EMA,SUPER' : 'MACD,VOL').split(',').includes(name) ? $r('app.color.text_primary') : $r('app.color.text_secondary')).height(40).padding({ left: 6, right: 6 }).onClick(() => this.toggle(name, overlay)).id('chart.indicator.' + name)
      }, (name: string) => name)
    }
  }
  build() {
    Stack() {
      Column({ space: 0 }) {
        this.header()
        Scroll() { Row({ space: 8 }) { this.indicatorGroup('指标', OVERLAYS, true); Divider().vertical(true).height(22).color($r('app.color.border')); this.indicatorGroup('副图', PANELS, false) }.padding({ left: 2, right: 2 }) }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).height(42).width('100%')
        Row({ space: 0 }) {
          Scroll() {
            Row({ space: 2 }) {
              ForEach(visibleIntervals(this.selection('chart-favorites-v1', DEFAULT_FAVORITES), this.interval()), (value: string) => {
                Text(INTERVAL_LABELS[INTERVALS.indexOf(value)]).fontSize(12).fontWeight(this.interval() === value ? FontWeight.Medium : FontWeight.Normal).fontColor(this.interval() === value ? $r('app.color.auth_link') : $r('app.color.text_secondary')).height(38).padding({ left: 6, right: 6 }).border({ width: { bottom: this.interval() === value ? 2 : 0 }, color: $r('app.color.auth_accent') }).onClick(() => this.selectInterval(value)).id('chart.interval.' + value)
              }, (value: string) => value)
              Column() { Image($r('app.media.chart_intervals')).width(14).height(14).fillColor($r('app.color.text_primary')) }.width(30).height(38).justifyContent(FlexAlign.Center).onClick(() => this.showSheet('interval')).id('chart.interval.edit')
            }
          }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).layoutWeight(1)
          Row({ space: 4 }) { Text('auto').fontSize(11).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary')); Toggle({ type: ToggleType.Switch, isOn: this.selection('chart-auto-fit', 'true') === 'true' }).width(28).height(17).selectedColor($r('app.color.chart_positive')).onChange((v: boolean) => { Runtime.store.preferences.write('chart-auto-fit', String(v)); this.settingsRevision++; }).id('chart.auto') }.padding({ left: 4, right: 8 })
        }.width('100%').height(38).padding({ left: 4 })
        Scroll() {
          Column({ space: 0 }) {
            KlineCanvas({ identity: this.symbol() + ':' + this.interval(), revision: this.revision + this.settingsRevision,
              main: this.selection('chart-main', 'EMA,SUPER'), panels: this.selection('chart-panels', 'MACD,VOL'), parameters: this.selection('chart-parameters-v1', '{}'), autoFit: this.selection('chart-auto-fit', 'true') === 'true',
              orderType: this.type, stopPrice: this.stop, entryPrice: this.entry, positions: this.held, interactive: !this.locked,
              selectedPrice: (value: string) => { if (!this.locked && this.type === 'market') this.stop = value; }, moveLine: (kind: string, value: string) => { if (!this.locked) { if (kind === 'stop') { this.stop = value; this.limitStop = value; } else this.entry = value; } } })
            if (this.chartPending()) { Text('历史数据补全中，已有行情持续更新').fontSize(11).fontColor($r('app.color.text_secondary')).padding(8) }
          }.width('100%')
        }.align(Alignment.Top).layoutWeight(1).width('100%').scrollBar(BarState.Off)
        ChartTicket({ revision: this.revision, symbol: this.symbol(), visible: this.active && this.editor === '', stop: this.stop, entry: this.entry, orderType: this.type, leverage: this.selectedLeverage(),
          changeType: (value: string) => this.changeType(value), navigate: this.navigate, showPositions: this.showPositions, holdingsChanged: (value: string) => { this.held = value; }, lockChanged: (value: boolean) => { this.locked = value; } })
      }.width('100%').height('100%').visibility(this.editor ? Visibility.Hidden : Visibility.Visible)
      if (this.editor === 'indicators') { IndicatorSettingsPage({ back: () => { this.editor = ''; }, applied: () => { this.settingsRevision++; } }) }
      else if (this.editor === 'settings') { Column() { NavigationHeader({ title: '设置', showsBack: true, back: () => { this.editor = ''; } }); Blank() }.width('100%').height('100%').backgroundColor($r('app.color.page')) }
    }.width('100%').height('100%').backgroundColor($r('app.color.background'))
      .bindSheet($$this.sheetOpen, this.sheet, { height: '80%', dragBar: true, showClose: false, preferType: SheetType.BOTTOM, backgroundColor: $r('app.color.background'), radius: { topLeft: 24, topRight: 24 }, onDisappear: () => this.afterSheet() })
  }
}
