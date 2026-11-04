import { Runtime } from '../platform/Runtime';
import { pairPickerSymbols } from '../core/MarketList';

@Component
export struct WatchlistAction {
  @Prop symbol: string = '';
  @Prop revision: number = 0;
  @Prop removeOnly: boolean = false;
  private favorite(): boolean { this.revision; return Runtime.store.watchlist.includes(this.symbol); }
  private async toggle(): Promise<void> {
    const store = Runtime.store; const scope = store.session.scope; const symbol = this.symbol;
    if (!store.watchlist.includes(symbol)) { store.addWatch(symbol); return; }
    try {
    const result = await this.getUIContext().getPromptAction().showDialog({
      title: '删除自选', message: '确定从自选中删除 ' + symbol + '？',
      buttons: [{ text: '取消', color: $r('app.color.text_secondary') }, { text: '删除自选', color: $r('app.color.negative') }]
    });
    if (result.index === 1 && scope === store.session.scope) store.removeWatch(symbol);
    } catch (_) { /* Dismissing the native confirmation leaves the watchlist unchanged. */ }
  }
  build() {
    Column({ space: 3 }) {
      Image(this.removeOnly ? $r('app.media.ui_trash') : this.favorite() ? $r('app.media.ui_star_filled') : $r('app.media.ui_star'))
        .width(18).height(18).draggable(false).fillColor(this.removeOnly ? $r('app.color.text_primary') : this.favorite() ? $r('app.color.auth_accent') : $r('app.color.text_secondary'))
      if (!this.removeOnly) { Text('自选').fontSize(9).fontColor($r('app.color.text_secondary')) }
    }.width(44).height(this.removeOnly ? 56 : 48).justifyContent(FlexAlign.Center)
      .onClick(() => this.toggle()).accessibilityText((this.favorite() ? '删除自选 ' : '添加自选 ') + this.symbol).id('pairs.favorite.' + this.symbol)
  }
}

@Component
struct PairRow {
  @Prop symbol: string = '';
  @Prop selectedSymbol: string = '';
  @Prop revision: number = 0;
  select: (symbol: string) => void = () => {};
  private favorite(): boolean { this.revision; return Runtime.store.watchlist.includes(this.symbol); }
  build() {
    Row({ space: 12 }) {
      Row({ space: 8 }) {
        Text(this.symbol).fontSize(16).fontWeight(this.favorite() ? FontWeight.Bold : FontWeight.Normal).maxLines(1).minFontSize(12).fontColor($r('app.color.text_primary'))
        Text('永续').fontSize(11).fontColor($r('app.color.text_secondary'))
        if (this.symbol === this.selectedSymbol) { Text('✓').fontSize(15).fontColor($r('app.color.auth_link')) }
        Blank()
      }.layoutWeight(1).height(56).onClick(() => this.select(this.symbol)).id('pairs.select.' + this.symbol)
      WatchlistAction({ symbol: this.symbol, revision: this.revision })
    }.width('100%').padding({ left: 20, right: 16 })
  }
}

@Component
export struct MarketPairPicker {
  @Prop revision: number = 0;
  @Prop selectedSymbol: string = '';
  @Prop autofocus: boolean = true;
  @State query: string = '';
  close: () => void = () => {};
  select: (symbol: string) => void = () => {};
  aboutToAppear(): void { this.query = ''; Runtime.store.loadCatalog(); }
  private symbols(): string[] { this.revision; return pairPickerSymbols(Runtime.store.catalogSymbols, Runtime.store.watchlist, this.query); }
  private loading(): boolean { this.revision; return Runtime.store.catalogLoading; }
  private emptyCatalog(): boolean { this.revision; return Runtime.store.catalogSymbols.length === 0; }
  build() {
    Column({ space: 0 }) {
      Row() {
        Text('交易对').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).layoutWeight(1)
        Text('×').fontSize(26).fontColor($r('app.color.text_primary')).width(44).height(44).textAlign(TextAlign.Center).onClick(this.close).accessibilityText('关闭').id('pairs.close')
      }.padding({ left: 20, right: 20, top: 12 }).width('100%')
      Row({ space: 8 }) {
        Image($r('app.media.ui_search')).width(16).height(16).fillColor($r('app.color.text_secondary'))
        TextInput({ text: this.query, placeholder: '搜索交易对' }).onChange((value: string) => { this.query = value; })
          .layoutWeight(1).height(24).padding(0).borderRadius(0).backgroundColor(Color.Transparent)
          .fontSize(16).fontColor($r('app.color.text_primary')).placeholderColor($r('app.color.text_secondary'))
          .enablePreviewText(false).enableAutoFill(false).enterKeyType(EnterKeyType.Search)
          .onSubmit(() => this.getUIContext().getFocusController().clearFocus()).defaultFocus(this.autofocus).id('pairs.search')
      }.padding(12).borderRadius(10).backgroundColor($r('app.color.input')).margin({ left: 20, right: 20, bottom: 12 })
      if (this.emptyCatalog()) {
        Column({ space: 12 }) {
          if (this.loading()) { LoadingProgress().width(30).height(30).color($r('app.color.auth_accent')) }
          else {
            Text('交易对加载失败').fontSize(15).fontColor($r('app.color.text_secondary'))
            Text('重新加载').fontSize(15).fontColor($r('app.color.auth_link')).onClick(() => Runtime.store.loadCatalog(true))
          }
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.symbols().length === 0) {
        Text('未找到相关交易对').fontSize(15).fontColor($r('app.color.text_secondary')).width('100%').layoutWeight(1).textAlign(TextAlign.Center)
      } else {
        List() {
          ForEach(this.symbols(), (symbol: string) => {
            ListItem() { PairRow({ symbol: symbol, selectedSymbol: this.selectedSymbol, revision: this.revision, select: this.select }) }
          }, (symbol: string) => symbol)
        }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.background'))
  }
}
