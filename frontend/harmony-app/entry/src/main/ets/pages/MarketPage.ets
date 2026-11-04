import { Runtime } from '../platform/Runtime';
import { Ticker } from '../core/Market';
import { MarketSort, sortedMarketSymbols, marketNumber, marketTurnover } from '../core/MarketList';
import { MarketPairPicker, WatchlistAction } from '../components/MarketPairPicker';

@Component
struct SortHeader {
  @Prop label: string = '';
  @Prop sortDirection: string = '';
  action: () => void = () => {};
  build() {
    Row({ space: 3 }) {
      Text(this.label).fontSize(11).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
      Column({ space: 1 }) {
        Text('▲').fontSize(4).fontColor(this.sortDirection === 'ascending' ? $r('app.color.text_primary') : $r('app.color.text_secondary')).opacity(this.sortDirection === 'descending' ? 0.35 : 0.7)
        Text('▼').fontSize(4).fontColor(this.sortDirection === 'descending' ? $r('app.color.text_primary') : $r('app.color.text_secondary')).opacity(this.sortDirection === 'ascending' ? 0.35 : 0.7)
      }.width(7).height(11).justifyContent(FlexAlign.Center)
    }.onClick(this.action).accessibilityText(this.label + (this.sortDirection === 'ascending' ? '，升序' : this.sortDirection === 'descending' ? '，降序' : '，默认顺序'))
  }
}

@Component
struct TickerRow {
  @Prop symbol: string = '';
  @Prop revision: number = 0;
  open: (symbol: string) => void = () => {};
  private ticker(): Ticker | undefined { this.revision; return Runtime.store.tickers.find((v: Ticker) => v.symbol === this.symbol); }
  private price(): string { const ticker = this.ticker(); return ticker ? marketNumber(ticker.price) : '--'; }
  private change(): string { const ticker = this.ticker(); return ticker ? marketNumber(String(ticker.change), true) + '%' : '--'; }
  private detail(): string { const ticker = this.ticker(); return ticker ? 'USD-M | ' + marketTurnover(ticker.volume) : 'USD-M'; }
  private positive(): boolean { const ticker = this.ticker(); return !ticker || ticker.change >= 0; }
  build() {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Row({ space: 6 }) {
          Text(this.symbol).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).maxLines(1).minFontSize(11)
          Text('永续').fontSize(11).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary')).padding({ left: 4, right: 4, top: 2, bottom: 2 }).borderRadius(4).backgroundColor($r('app.color.input'))
        }.width('100%')
        Text(this.detail()).fontSize(11).fontColor($r('app.color.text_secondary')).maxLines(1)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Column({ space: 3 }) {
        Text(this.price()).fontFeature('tnum').fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).maxLines(1).minFontSize(10)
        Text('$' + this.price()).fontFeature('tnum').fontSize(11).fontColor($r('app.color.text_secondary')).maxLines(1).minFontSize(9)
      }.alignItems(HorizontalAlign.End).width(78)
      Text(this.change()).fontFeature('tnum').fontSize(12).fontWeight(FontWeight.Medium).fontColor(Color.White).width(76).height(30).textAlign(TextAlign.Center)
        .borderRadius(4).backgroundColor(this.positive() ? '#32BD82' : '#F6485E')
    }.constraintSize({ minHeight: 60 }).width('100%').onClick(() => this.open(this.symbol)).id('market.row.' + this.symbol)
  }
}

@Component
export struct MarketPage {
  @Prop revision: number = 0;
  @State sort: MarketSort = new MarketSort();
  @State showingPairs: boolean = false;
  @State refreshing: boolean = false;
  @State pendingSymbol: string = '';
  openChart: (symbol: string) => void = () => {};
  edit: () => void = () => {};
  private rows(): string[] { this.revision; return sortedMarketSymbols(Runtime.store.watchlist, Runtime.store.tickers, this.sort); }
  private sortDirection(field: string): string { return this.sort.field === field ? this.sort.direction : ''; }
  private latency(): string { this.revision; const live = Runtime.store.realtime; return live.status === '已连接' && live.latency >= 0 ? Math.round(Math.min(999, live.latency)) + ' ms' : '-- ms'; }
  private latencyColor(): ResourceColor { this.revision; const n = Runtime.store.realtime.latency; return n < 0 || n >= 500 ? $r('app.color.negative') : n >= 200 ? $r('app.color.auth_link') : $r('app.color.positive'); }
  private bars(): number { this.revision; const n = Runtime.store.realtime.latency; return n < 0 || n >= 500 ? 1 : n >= 200 ? 3 : 4; }
  private async refresh(): Promise<void> {
    this.refreshing = true; Runtime.store.realtime.testLatency();
    try { await Runtime.store.loadTickers(); } finally { this.refreshing = false; }
  }
  @Builder
  private pairs() {
    MarketPairPicker({ revision: this.revision, close: () => { this.showingPairs = false; }, select: (symbol: string) => { this.pendingSymbol = symbol; this.showingPairs = false; } })
  }
  build() {
    Column({ space: 0 }) {
      Column() {
      Row({ space: 8 }) {
        Image($r('app.media.ui_search')).width(13).height(13).fillColor($r('app.color.text_secondary'))
        Text('搜索币种/币对/合约').fontSize(13).fontColor($r('app.color.text_secondary'))
        Blank()
      }.width('100%').height(46).padding({ left: 10, right: 10 }).backgroundColor($r('app.color.input')).borderRadius(8)
        .onClick(() => { this.showingPairs = true; }).id('market.search')
      }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 14 })
      Row() {
        Text('合约').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).layoutWeight(1)
        Row({ space: 5 }) {
          if (Runtime.store.realtime.status === '已连接' && Runtime.store.realtime.latency < 0) { LoadingProgress().width(10).height(10).color($r('app.color.auth_link')) }
          else { Blank().width(10).height(10) }
          Text(this.latency()).fontSize(11).fontWeight(FontWeight.Medium).fontColor(this.latencyColor())
          Row({ space: 2 }) {
            ForEach([0, 1, 2, 3], (index: number) => { Rect().width(3).height(4 + index * 3).radius(1).fill(index < this.bars() ? this.latencyColor() : $r('app.color.text_secondary')).opacity(index < this.bars() ? 1 : 0.2) })
          }.alignItems(VerticalAlign.Bottom).height(13)
        }.constraintSize({ minWidth: 66 }).height(44).margin({ right: 6 }).onClick(() => Runtime.store.realtime.testLatency()).accessibilityText('网络延迟 ' + this.latency()).id('market.latency')
        Row() { Image($r('app.media.market_edit')).width(24).height(24).fillColor($r('app.color.text_primary')) }
          .width(44).height(44).justifyContent(FlexAlign.Center).onClick(this.edit).accessibilityText('编辑行情列表').id('market.edit')
      }.width('100%').padding({ left: 16, right: 16 }).margin({ bottom: 8 })
      Row({ space: 10 }) {
        Row({ space: 3 }) {
          SortHeader({ label: '名称', sortDirection: this.sortDirection('symbol'), action: () => { this.sort = this.sort.next('symbol'); } })
          Text('/').fontSize(11).fontColor($r('app.color.text_secondary'))
          SortHeader({ label: '成交额', sortDirection: this.sortDirection('volume'), action: () => { this.sort = this.sort.next('volume'); } })
        }.layoutWeight(1)
        Row() { SortHeader({ label: '最新价', sortDirection: this.sortDirection('price'), action: () => { this.sort = this.sort.next('price'); } }) }.width(78).justifyContent(FlexAlign.End)
        Row() { SortHeader({ label: '24h\n涨跌幅', sortDirection: this.sortDirection('change'), action: () => { this.sort = this.sort.next('change'); } }) }.width(76).justifyContent(FlexAlign.End)
      }.width('100%').padding({ left: 16, right: 16 }).margin({ bottom: 2 })
      Refresh({ refreshing: $$this.refreshing }) {
        List() {
          ForEach(this.rows(), (symbol: string) => { ListItem() { TickerRow({ symbol: symbol, revision: this.revision, open: this.openChart }) } }, (symbol: string) => symbol)
          if (this.rows().length === 0) {
            ListItem() {
              Column({ space: 12 }) {
                Text('⌁').fontSize(30).fontColor($r('app.color.text_secondary'))
                Text('暂无行情').fontSize(17).fontColor($r('app.color.text_primary'))
                Text('可在编辑列表中打开显示').fontSize(15).fontColor($r('app.color.text_secondary'))
              }.width('100%').padding({ top: 56 })
            }
          }
        }.height('100%').width('100%').padding({ left: 16, right: 16, bottom: 18 }).scrollBar(BarState.Off)
      }.layoutWeight(1).width('100%').onRefreshing(() => this.refresh())
    }.width('100%').height('100%').backgroundColor($r('app.color.background'))
      .bindSheet($$this.showingPairs, this.pairs, { height: '80%', dragBar: true, showClose: false, preferType: SheetType.BOTTOM, backgroundColor: $r('app.color.background'), radius: { topLeft: 24, topRight: 24 }, onDisappear: () => { if (this.pendingSymbol) { const symbol = this.pendingSymbol; this.pendingSymbol = ''; this.openChart(symbol); } } })
  }
}

@Component
struct WatchlistRow {
  @Prop symbol: string = '';
  @Prop revision: number = 0;
  build() {
    Row({ space: 0 }) {
      Row({ space: 5 }) {
        Text(this.symbol).fontSize(15).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).maxLines(1).minFontSize(10)
        Text('永续').fontSize(11).fontColor($r('app.color.text_secondary'))
      }.layoutWeight(1)
      WatchlistAction({ symbol: this.symbol, revision: this.revision, removeOnly: true })
      Row() { Image($r('app.media.ui_top')).draggable(false).width(18).height(18).fillColor($r('app.color.text_primary')) }
        .width(68).height(56).justifyContent(FlexAlign.Center).onClick(() => Runtime.store.moveWatch(Runtime.store.watchlist.indexOf(this.symbol), 0)).accessibilityText('移到顶部 ' + this.symbol).id('watchlist.top.' + this.symbol)
      Image($r('app.media.ui_drag')).draggable(false).width(20).height(20).fillColor($r('app.color.text_secondary')).margin({ left: 2, right: 2 }).accessibilityText('拖动 ' + this.symbol)
    }.height(56).width('100%')
  }
}

@Component
export struct MarketListSettingsPage {
  @Prop @Watch('refreshSymbols') revision: number = 0;
  @State orderedSymbols: string[] = [];
  @State showingPairs: boolean = false;
  @State pendingSymbol: string = '';
  openChart: (symbol: string) => void = () => {};
  aboutToAppear(): void { this.refreshSymbols(); }
  private refreshSymbols(): void { if (JSON.stringify(this.orderedSymbols) !== JSON.stringify(Runtime.store.watchlist)) this.orderedSymbols = Runtime.store.watchlist.slice(); }
  @Builder
  private pairs() {
    MarketPairPicker({ revision: this.revision, autofocus: false, close: () => { this.showingPairs = false; }, select: (symbol: string) => { this.pendingSymbol = symbol; this.showingPairs = false; } })
  }
  build() {
    Column({ space: 0 }) {
      Row({ space: 0 }) {
        Text('交易对').layoutWeight(1).fontSize(12).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary'))
        Text('删除').fontSize(12).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary')).width(44).textAlign(TextAlign.Center)
        Text('移到顶部').fontSize(12).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary')).width(68).textAlign(TextAlign.Center)
        Text('拖动').fontSize(12).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary')).width(24).textAlign(TextAlign.Center)
      }.width('100%')
        .padding({ left: 16, right: 16, top: 24, bottom: 10 }).border({ width: { top: 1 }, color: $r('app.color.border') })
      List() {
        ForEach(this.orderedSymbols, (symbol: string) => { ListItem() { WatchlistRow({ symbol: symbol, revision: this.revision }) } }, (symbol: string) => symbol)
          .onMove((from: number, to: number) => Runtime.store.moveWatch(from, to))
        if (this.orderedSymbols.length === 0) { ListItem() { Text('暂无自选交易对').fontSize(15).fontColor($r('app.color.text_secondary')).padding(32).width('100%').textAlign(TextAlign.Center) } }
      }.width('100%').layoutWeight(1).padding({ left: 16, right: 16 }).scrollBar(BarState.Off).id('watchlist.list')
      Row() {
        Button('添加自选', { type: ButtonType.Normal }).fontSize(16).fontWeight(FontWeight.Medium).fontColor('#181A20').height(48).width('100%')
          .borderRadius(8).backgroundColor($r('app.color.auth_accent')).onClick(() => { this.showingPairs = true; }).id('watchlist.add')
      }.width('100%').padding(16)
    }.width('100%').height('100%').padding({ left: 0, right: 0 }).backgroundColor($r('app.color.background'))
      .bindSheet($$this.showingPairs, this.pairs, { height: '80%', dragBar: true, showClose: false, preferType: SheetType.BOTTOM, backgroundColor: $r('app.color.background'), radius: { topLeft: 24, topRight: 24 }, onDisappear: () => { if (this.pendingSymbol) { const symbol = this.pendingSymbol; this.pendingSymbol = ''; this.openChart(symbol); } } })
  }
}
