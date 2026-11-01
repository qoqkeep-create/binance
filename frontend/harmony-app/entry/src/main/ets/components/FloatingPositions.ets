import { Runtime } from '../platform/Runtime';
import { DataValue } from '../core/Json';
import { amount } from '../core/Decimal';
import { GREEN, RED } from './Ui';
@Component
export struct FloatingPositions {
  @Prop revision: number = 0;
  @State rows: DataValue[] = [];
  @State updated: number = 0;
  @State error: string = '';
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  private panX: number = 0;
  private panY: number = 0;
  private generation: number = 0;
  close: () => void = () => {};
  open: () => void = () => {};
  aboutToAppear(): void { this.poll(++this.generation); }
  aboutToDisappear(): void { this.generation++; this.rows = []; }
  private async poll(generation: number): Promise<void> {
    const scope = Runtime.store.session.scope;
    while (generation === this.generation && scope === Runtime.store.session.scope) {
      if (Runtime.store.foreground && Runtime.store.isBound) {
        try {
          const value = await Runtime.store.session.request('/v1/position/list');
          if (generation !== this.generation || scope !== Runtime.store.session.scope) return;
          this.rows = value.items(); this.updated = Date.now(); this.error = '';
        } catch (_) { if (generation === this.generation) this.error = '更新失败'; }
      }
      await Runtime.store.clock.delay(3000);
    }
  }
  build() {
    Column({ space: 8 }) {
      Row() {
        Text('持仓 · ' + (Runtime.store.session.mode === 'lead' ? '带单' : '合约')).fontSize(12).fontWeight(FontWeight.Bold).fontColor('#EAECEF').layoutWeight(1).onClick(this.open)
        Text('×').fontSize(20).width(32).height(32).textAlign(TextAlign.Center).fontColor('#848E9C').onClick(this.close)
      }.width('100%')
      ForEach(this.rows.slice(0, 4), (row: DataValue) => {
        Row() {
          Text(row.value('symbol').replace('USDT', '')).fontSize(12).fontColor('#EAECEF').layoutWeight(1)
          Text(amount(row.value('pnl'))).fontSize(13).fontColor(row.get('pnl').number() >= 0 ? GREEN : RED)
        }.width('100%').onClick(this.open)
      }, (row: DataValue) => row.value('id') + ':' + row.json())
      if (!this.rows.length) { Text('暂无持仓').fontSize(12).fontColor('#848E9C') }
      Text(this.error || (!Runtime.store.foreground || Date.now() - this.updated > 10000 ? '等待更新' : '更新于 ' + new Date(this.updated).toLocaleTimeString('zh-CN', { hour12: false }))).fontSize(10).fontColor('#848E9C')
    }.width(200).padding(12).backgroundColor('#F2272F3A').borderRadius(12).border({ width: 1, color: '#333B47' })
      .translate({ x: this.offsetX, y: this.offsetY }).margin({ right: 16, bottom: 76 })
      .gesture(PanGesture().onActionStart(() => { this.panX = this.offsetX; this.panY = this.offsetY; }).onActionUpdate((event: GestureEvent) => { this.offsetX = Math.max(-140, Math.min(0, this.panX + event.offsetX)); this.offsetY = Math.max(-400, Math.min(0, this.panY + event.offsetY)); }))
  }
}
