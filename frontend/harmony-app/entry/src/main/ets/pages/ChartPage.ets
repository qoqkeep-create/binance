import { Runtime } from '../platform/Runtime';
import { INTERVALS, INTERVAL_LABELS, priceText } from '../core/Market';
import { KlineCanvas } from '../components/KlineCanvas';
import { ActionButton, Metric, GREEN, RED } from '../components/Ui';

@Component
export struct ChartPage {
  @Prop revision: number = 0;
  @State interval: number = 3;
  @State drawMode: string = '';
  @State stop: string = '';
  @State entry: string = '';
  navigate: (route: string) => void = () => {};
  openTrade: (stop: string, entry: string) => void = () => {};
  private selection(key: string, fallback: string): string { this.revision; return Runtime.store.preferences.read(key, fallback); }
  private latestPrice(): string {
    this.revision; const store = Runtime.store;
    return store.chart.candles.length ? priceText(String(store.chart.candles[store.chart.candles.length - 1].close)) : '--';
  }
  build() {
    Scroll() {
      Column({ space: 8 }) {
        Row() {
          Column({ space: 4 }) {
            Text(this.latestPrice()).fontSize(28).fontWeight(FontWeight.Bold).fontColor(GREEN)
            Text(Runtime.store.selectedSymbol + ' 永续').fontSize(12).fontColor($r('app.color.text_secondary'))
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Text(Runtime.store.watchlist.includes(Runtime.store.selectedSymbol) ? '★ 自选' : '☆ 添加自选').fontSize(14).fontColor('#F0B90B').onClick(() => Runtime.store.toggleWatch(Runtime.store.selectedSymbol))
        }.width('100%').padding(16)
        Row() {
          ForEach(INTERVAL_LABELS, (label: string, index: number) => {
            Text(label).fontSize(13).fontColor(Runtime.store.interval === INTERVALS[index] ? '#F0B90B' : $r('app.color.text_secondary'))
              .layoutWeight(1).height(36).textAlign(TextAlign.Center).onClick(() => { this.stop = ''; this.entry = ''; Runtime.store.selectChart(Runtime.store.selectedSymbol, INTERVALS[index]); })
          })
          Text('⚙').width(36).fontSize(18).onClick(() => this.navigate('indicators'))
        }.width('100%')
        KlineCanvas({ identity: Runtime.store.selectedSymbol + ':' + Runtime.store.interval, revision: this.revision, main: this.selection('chart-main', 'EMA,SUPER'), panels: this.selection('chart-panels', 'MACD,VOL'), drawMode: this.drawMode, stopPrice: this.stop, entryPrice: this.entry,
          selectedPrice: (value: string) => { if (this.drawMode === 'stop') this.stop = value; else this.entry = value; this.drawMode = ''; } })
        if (Runtime.store.chartPending) { Text('历史数据补全中，已有行情持续更新').fontSize(12).fontColor($r('app.color.text_secondary')).padding(8) }
        Row({ space: 12 }) {
          Button(this.drawMode === 'stop' ? '点击图表设置止损' : '划止损线').fontSize(13).height(40).backgroundColor(this.drawMode === 'stop' ? RED : $r('app.color.input')).fontColor($r('app.color.text_primary')).layoutWeight(1).onClick(() => { this.drawMode = this.drawMode === 'stop' ? '' : 'stop'; })
          Button(this.drawMode === 'entry' ? '点击图表设置限价' : '划限价线').fontSize(13).height(40).backgroundColor($r('app.color.input')).fontColor($r('app.color.text_primary')).layoutWeight(1).onClick(() => { this.drawMode = this.drawMode === 'entry' ? '' : 'entry'; })
        }.padding({ left: 16, right: 16 }).width('100%')
        if (this.stop) { Metric({ label: '止损价', value: this.stop }).padding({ left: 16, right: 16 }) }
        if (this.entry) { Metric({ label: '限价', value: this.entry }).padding({ left: 16, right: 16 }) }
        ActionButton({ label: this.stop ? '带入开仓表单' : '开仓', action: () => this.openTrade(this.stop, this.entry) }).padding(16)
      }.width('100%')
    }.width('100%').height('100%').backgroundColor($r('app.color.background'))
  }
}
