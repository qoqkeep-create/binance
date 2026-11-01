import { Runtime } from '../platform/Runtime';
import { DataValue } from '../core/Json';
import { AuthPage } from './AuthPage';
import { MarketPage } from './MarketPage';
import { PositionsPage } from './PositionsPage';
import { TradePage } from './TradePage';
import { ChartPage } from './ChartPage';
import { ProfilePage, AccountFormPage } from './AccountPages';
import { RecordsPage } from './RecordsPage';
import { PositionDetailPage } from './PositionDetailPage';
import { StrategyPage } from './StrategyPage';
import { IndicatorsPage, SettingsPage, ServerPage, ResetConfirmPage } from './SettingsPages';
import { LegalPage } from './LegalPage';
import { FloatingPositions } from '../components/FloatingPositions';
import { SectionCard, ActionButton, GOLD } from '../components/Ui';

class Destination {
  route: string;
  item: DataValue = new DataValue();
  historical: boolean = false;
  stop: string = '';
  entry: string = '';
  constructor(route: string) { this.route = route; }
}
@Entry
@Component
struct Index {
  @State revision: number = 0;
  @State initialized: boolean = false;
  @State loggedIn: boolean = false;
  @State tab: string = 'market';
  @State destinations: Destination[] = [];
  @State notice: string = '';
  @State floating: boolean = false;
  private identity: string = '';
  aboutToAppear(): void {
    Runtime.store.onChange = () => this.refreshState();
    this.floating = Runtime.store.preferences.read('floating-enabled', 'false') === 'true';
    if (!Runtime.store.initialized) Runtime.store.initialize(); else this.refreshState();
  }
  aboutToDisappear(): void { Runtime.store.onChange = () => {}; }
  onBackPress(): boolean { if (this.destinations.length) { this.back(); return true; } return false; }
  private refreshState(): void {
    const store = Runtime.store; const identity = store.session.baseUrl + ':' + store.session.user.value('id', '') + ':' + store.session.mode;
    if (identity !== this.identity) { this.destinations = []; this.tab = 'market'; this.identity = identity; }
    this.initialized = store.initialized; this.loggedIn = store.session.authenticated; this.notice = store.notice; this.revision++;
  }
  private current(): Destination { return this.destinations.length ? this.destinations[this.destinations.length - 1] : new Destination(''); }
  private navigate(route: string): void { this.destinations = this.destinations.concat([new Destination(route)]); }
  private back(): void {
    if (this.current().route === 'chart') Runtime.store.closeChart();
    this.destinations = this.destinations.slice(0, -1);
    if (this.current().route === 'chart') Runtime.store.realtime.setChart(Runtime.store.selectedSymbol, Runtime.store.interval);
  }
  private chart(symbol: string, interval: string = '1h'): void { Runtime.store.selectChart(symbol, interval); this.navigate('chart'); }
  private trade(stop: string, entry: string): void {
    const destination = new Destination('trade'); destination.stop = stop; destination.entry = entry;
    this.destinations = this.destinations.filter((v: Destination) => v.route !== 'trade').concat([destination]);
  }
  private detail(row: DataValue, historical: boolean): void {
    const destination = new Destination('position'); destination.item = DataValue.parse(row.json()); destination.historical = historical;
    this.destinations = this.destinations.concat([destination]);
  }
  private logs(id: string): void { const destination = new Destination('strategy-log'); destination.item = DataValue.object({ id: id }); this.destinations = this.destinations.concat([destination]); }
  private title(): string {
    const titles = new Map<string, string>([
      ['chart', Runtime.store.selectedSymbol], ['trade', '开仓'], ['position', '仓位详情'], ['binding', 'API 管理'],
      ['stop-loss', '止损金额'], ['strategies', '止盈止损策略'], ['account', '账户信息'], ['capital', '资金整理'],
      ['collection', '归集目标'], ['reminder', '资金提醒'], ['transfers', '转账历史'], ['operations', '操作日志'],
      ['commands', '交易命令'], ['strategy-log', '策略执行记录'], ['settings', '设置'], ['server', '服务器设置'],
      ['floating', '持仓浮窗'], ['terms', '用户协议'], ['privacy', '隐私政策'], ['indicators', '图表指标'], ['reset-confirm', '重置密码']
    ]);
    return titles.get(this.current().route) || this.tabLabel(this.tab);
  }
  private chartRevision(): number { this.revision; return Runtime.store.chartRevision; }
  private tabs(): string[] { this.revision; return Runtime.store.session.mode === 'lead' ? ['market', 'positions', 'trade', 'profile'] : ['market', 'positions', 'trade', 'signals', 'profile']; }
  private tabLabel(value: string): string {
    const labels = new Map<string, string>([['market', '行情'], ['positions', '持仓'], ['trade', '开仓'], ['signals', '信号'], ['profile', '我的']]);
    return labels.get(value) || 'Binance Tools';
  }
  private icon(value: string, selected: boolean): Resource {
    if (value === 'market') return selected ? $r('app.media.tab_market_on') : $r('app.media.tab_market_off');
    if (value === 'positions') return selected ? $r('app.media.tab_positions_on') : $r('app.media.tab_positions_off');
    if (value === 'trade') return selected ? $r('app.media.tab_trade_on') : $r('app.media.tab_trade_off');
    if (value === 'signals') return selected ? $r('app.media.tab_signals_on') : $r('app.media.tab_signals_off');
    return selected ? $r('app.media.tab_profile_on') : $r('app.media.tab_profile_off');
  }
  @Builder
  private bodyContent() {
    if (this.current().route === 'terms' || this.current().route === 'privacy') { LegalPage({ document: this.current().route }) }
    else if (this.current().route === 'server') { ServerPage() }
    else if (this.current().route === 'reset-confirm') { ResetConfirmPage() }
    else if (!this.loggedIn) { AuthPage({ revision: this.revision, navigate: (route: string) => this.navigate(route) }) }
    else if (this.current().route === 'chart') { ChartPage({ revision: this.chartRevision(), navigate: (route: string) => this.navigate(route), openTrade: (stop: string, entry: string) => this.trade(stop, entry) }) }
    else if (this.current().route === 'trade') { TradePage({ revision: this.revision, initialStop: this.current().stop, initialEntry: this.current().entry, navigate: (route: string) => this.navigate(route), openChart: (symbol: string) => this.chart(symbol) }) }
    else if (this.current().route === 'position') { PositionDetailPage({ initial: this.current().item, historical: this.current().historical, openChart: (symbol: string) => this.chart(symbol), openLogs: (id: string) => this.logs(id) }) }
    else if (this.current().route === 'binding') { AccountFormPage({ kind: 'binding', revision: this.revision }) }
    else if (this.current().route === 'stop-loss') { AccountFormPage({ kind: 'stop-loss', revision: this.revision }) }
    else if (this.current().route === 'account') { AccountFormPage({ kind: 'account', revision: this.revision }) }
    else if (this.current().route === 'capital') { AccountFormPage({ kind: 'capital', revision: this.revision }) }
    else if (this.current().route === 'collection') { AccountFormPage({ kind: 'collection', revision: this.revision }) }
    else if (this.current().route === 'reminder') { AccountFormPage({ kind: 'reminder', revision: this.revision }) }
    else if (this.current().route === 'strategies') { StrategyPage({ revision: this.revision }) }
    else if (this.current().route === 'transfers') { RecordsPage({ kind: 'transfers', revision: this.revision }) }
    else if (this.current().route === 'operations') { RecordsPage({ kind: 'operations', revision: this.revision }) }
    else if (this.current().route === 'commands') { RecordsPage({ kind: 'commands', revision: this.revision }) }
    else if (this.current().route === 'strategy-log') { RecordsPage({ kind: 'strategy-log', positionId: this.current().item.value('id'), revision: this.revision }) }
    else if (this.current().route === 'settings') { SettingsPage({ navigate: (route: string) => this.navigate(route) }) }
    else if (this.current().route === 'indicators') { IndicatorsPage() }
    else if (this.current().route === 'floating') {
      Column({ space: 16 }) {
        SectionCard() {
          Text('在应用内查看持仓，拖动卡片调整位置。显示当前账户模式，切换账户后重新读取。').fontSize(14).fontColor($r('app.color.text_secondary'))
          ActionButton({ label: this.floating ? '关闭持仓浮窗' : '开启持仓浮窗', action: () => { this.floating = !this.floating; Runtime.store.preferences.write('floating-enabled', String(this.floating)); } })
        }
      }.padding(16).width('100%').height('100%').backgroundColor($r('app.color.page'))
    }
    else if (this.tab === 'market') { MarketPage({ revision: this.revision, openChart: (symbol: string) => this.chart(symbol) }) }
    else if (this.tab === 'positions') { PositionsPage({ revision: this.revision, openDetail: (row: DataValue, historical: boolean) => this.detail(row, historical), navigate: (route: string) => this.navigate(route) }) }
    else if (this.tab === 'trade') { TradePage({ revision: this.revision, navigate: (route: string) => this.navigate(route), openChart: (symbol: string) => this.chart(symbol) }) }
    else if (this.tab === 'signals') { RecordsPage({ kind: 'signals', revision: this.revision, openChart: (symbol: string, interval: string) => this.chart(symbol, interval) }) }
    else { ProfilePage({ revision: this.revision, navigate: (route: string) => this.navigate(route) }) }
  }
  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column({ space: 0 }) {
        if (!this.initialized) { Blank(); LoadingProgress().width(40).height(40); Blank() }
        else {
          if (this.current().route || (this.loggedIn && this.tab !== 'market')) {
            Row() {
              if (this.current().route) { Text('‹').width(48).height(48).fontSize(32).fontColor($r('app.color.text_primary')).textAlign(TextAlign.Center).onClick(() => this.back()) } else { Blank().width(48) }
              Text(this.title()).fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).textAlign(TextAlign.Center).layoutWeight(1)
              Blank().width(48)
            }.width('100%').height(56).backgroundColor($r('app.color.surface'))
          }
          if (this.notice) { Text(this.notice + '   ×').fontSize(13).fontColor(GOLD).padding(12).width('100%').backgroundColor($r('app.color.surface')).onClick(() => { Runtime.store.notice = ''; Runtime.store.changed(); }) }
          Column() { this.bodyContent() }.layoutWeight(1).width('100%')
          if (this.loggedIn && !this.destinations.length) {
            Row() {
              ForEach(this.tabs(), (value: string) => {
                Column({ space: 3 }) {
                  Image(this.icon(value, this.tab === value)).width(24).height(24)
                  Text(this.tabLabel(value)).fontSize(10).fontColor(this.tab === value ? GOLD : $r('app.color.text_secondary'))
                }.height(56).justifyContent(FlexAlign.Center).layoutWeight(1).onClick(() => { this.tab = value; })
              })
            }.width('100%').backgroundColor($r('app.color.surface')).border({ width: { top: 0.5 }, color: $r('app.color.border') })
          }
        }
      }.width('100%').height('100%').backgroundColor($r('app.color.background'))
      if (this.loggedIn && this.floating && Runtime.store.isBound) { FloatingPositions({ revision: this.revision, close: () => { this.floating = false; Runtime.store.preferences.write('floating-enabled', 'false'); }, open: () => { this.destinations = []; this.tab = 'positions'; } }) }
    }.width('100%').height('100%')
  }
}
