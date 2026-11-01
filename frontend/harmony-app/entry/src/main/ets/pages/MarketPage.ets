import { Runtime } from '../platform/Runtime';
import { Ticker, priceText } from '../core/Market';
import { ChoiceBar, EmptyState, GREEN, RED } from '../components/Ui';

@Component
export struct MarketPage {
  @Prop revision: number = 0;
  @State query: string = '';
  @State selected: number = 0;
  @State sort: number = 0;
  openChart: (symbol: string) => void = () => {};
  private rows(): Ticker[] {
    this.revision;
    const store = Runtime.store;
    const rows = store.tickers.filter((ticker: Ticker) => ticker.symbol.includes(this.query.toUpperCase()) && (this.selected !== 0 || store.watchlist.includes(ticker.symbol)));
    return rows.sort((a: Ticker, b: Ticker) => this.sort === 1 ? b.change - a.change : this.sort === 2 ? a.change - b.change : b.volume - a.volume);
  }
  private latency(): string { this.revision; const live = Runtime.store.realtime; return live.status === '已连接' ? live.latency < 0 ? '测量中' : Math.round(Math.min(999, live.latency)) + ' ms' : '-- ms'; }
  build() {
    Column({ space: 0 }) {
      Row() {
        Text('行情').fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).layoutWeight(1)
        Text('● ' + this.latency()).fontSize(12).fontColor(Runtime.store.realtime.latency > 500 ? RED : GREEN).onClick(() => Runtime.store.realtime.testLatency())
      }.width('100%').height(56).padding({ left: 16, right: 16 })
      TextInput({ text: this.query, placeholder: '搜索永续合约' }).height(46).margin({ left: 16, right: 16, bottom: 8 }).width('92%')
        .backgroundColor($r('app.color.input')).fontColor($r('app.color.text_primary')).borderRadius(8).onChange((value: string) => { this.query = value; })
      ChoiceBar({ labels: ['自选', '全部合约'], selected: $selected }).padding({ left: 16, right: 16 })
      Row() {
        Text('交易对 / 成交额').layoutWeight(1).onClick(() => { this.sort = 0; })
        Text('最新价').width('30%').textAlign(TextAlign.End)
        Text(this.sort === 1 ? '涨跌幅 ↓' : this.sort === 2 ? '涨跌幅 ↑' : '涨跌幅').width('29%').textAlign(TextAlign.End).onClick(() => { this.sort = this.sort === 1 ? 2 : 1; })
      }.width('100%').height(36).padding({ left: 16, right: 16 })
      List() {
        ForEach(this.rows(), (ticker: Ticker) => {
          ListItem() {
            Row({ space: 8 }) {
              Text(Runtime.store.watchlist.includes(ticker.symbol) ? '★' : '☆').fontSize(20).fontColor('#F0B90B').width(22)
                .onClick(() => Runtime.store.toggleWatch(ticker.symbol))
              Column({ space: 4 }) {
                Row({ space: 2 }) { Text(ticker.symbol.replace(/USDT$/, '')).fontWeight(FontWeight.Bold).fontSize(15); Text('USDT').fontSize(10).fontColor($r('app.color.text_secondary')) }
                Text((ticker.volume / 1000000).toFixed(2) + 'M').fontSize(11).fontColor($r('app.color.text_secondary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Text(priceText(ticker.price)).fontSize(14).fontWeight(FontWeight.Medium).textAlign(TextAlign.End).width('29%')
              Text((ticker.change > 0 ? '+' : '') + ticker.change.toFixed(2) + '%').fontSize(12).fontWeight(FontWeight.Medium)
                .fontColor(Color.White).width(80).height(30).textAlign(TextAlign.Center).borderRadius(4).backgroundColor(ticker.change >= 0 ? GREEN : RED)
            }.height(60).padding({ left: 16, right: 16 }).width('100%').onClick(() => this.openChart(ticker.symbol))
          }
        }, (ticker: Ticker) => ticker.symbol + ':' + ticker.eventTime + ':' + ticker.price)
        if (this.rows().length === 0) { ListItem() { EmptyState({ title: this.query ? '未找到合约' : this.selected === 0 ? '暂无自选' : '正在获取行情', detail: this.selected === 0 ? '到全部合约点击星标添加自选' : '' }) } }
      }.layoutWeight(1).width('100%').onReachEnd(() => {})
    }.width('100%').height('100%').backgroundColor($r('app.color.background'))
  }
}
