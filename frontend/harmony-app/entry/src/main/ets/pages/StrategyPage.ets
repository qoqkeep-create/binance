import { Runtime } from '../platform/Runtime';
import { DataValue } from '../core/Json';
import { StrategyLevel, strategyPayload } from '../core/Strategy';
import { SectionCard, Metric, Field, ActionButton, EmptyState, confirmAction, GOLD, RED } from '../components/Ui';

@Component
export struct StrategyPage {
  @Prop revision: number = 0;
  @State editing: boolean = false;
  @State name: string = '';
  @State levels: StrategyLevel[] = [];
  @State busy: boolean = false;
  @State message: string = '';
  private strategyId: DataValue = new DataValue();
  private strategies(): DataValue[] { this.revision; return Runtime.store.strategies; }
  private edit(row: DataValue): void {
    this.strategyId = row.get('id'); this.name = row.value('name', '');
    this.levels = row.get('levels').rows().map((v: DataValue) => StrategyLevel.from(v));
    if (!this.levels.length) this.levels = [new StrategyLevel()]; this.editing = true;
  }
  private update(index: number, key: string, value: string): void {
    const level = StrategyLevel.from(this.levels[index].value());
    if (key === 'profit') level.profit = value;
    if (key === 'reduce') level.reduce = value;
    if (key === 'stopType') level.stopType = value;
    if (key === 'stopValue') level.stopValue = value;
    this.levels = this.levels.map((v: StrategyLevel, i: number) => i === index ? level : v);
  }
  private async mutate(path: string, payload: DataValue): Promise<void> {
    if (this.busy) return; this.busy = true;
    try { await Runtime.store.session.request('/v1/strategy/' + path, 'POST', payload); this.editing = false; this.message = '已保存'; await Runtime.store.refreshAccount(); }
    finally { this.busy = false; }
  }
  private save(): void {
    try {
      const payload = strategyPayload(this.name, this.levels, this.strategyId);
      confirmAction('保存策略', payload.value('name') + '\n' + payload.get('levels').rows().map((v: DataValue, i: number) => 'L' + (i + 1) + '：' + v.value('profitRR') + 'R，减仓 ' + v.value('reducePosition') + '%').join('\n'), async () => { await this.mutate('save', payload); });
    } catch (e) { this.message = (e as Error).message; }
  }
  build() {
    Scroll() {
      Column({ space: 16 }) {
        if (this.editing) {
          SectionCard() {
            Field({ label: '策略名称', value: $name })
            ForEach(this.levels, (level: StrategyLevel, index: number) => {
              Column({ space: 10 }) {
                Row() { Text('L' + (index + 1)).fontWeight(FontWeight.Bold).fontColor(GOLD).layoutWeight(1); if (this.levels.length > 1) { Text('删除层级').fontSize(13).fontColor(RED).onClick(() => { this.levels = this.levels.filter((v: StrategyLevel, i: number) => i !== index); }) } }.width('100%')
                TextInput({ text: level.profit, placeholder: '盈利 R' }).type(InputType.NUMBER_DECIMAL).onChange((v: string) => this.update(index, 'profit', v)).height(48).backgroundColor($r('app.color.input')).fontColor($r('app.color.text_primary'))
                TextInput({ text: level.reduce, placeholder: '减仓比例 %' }).type(InputType.NUMBER_DECIMAL).onChange((v: string) => this.update(index, 'reduce', v)).height(48).backgroundColor($r('app.color.input')).fontColor($r('app.color.text_primary'))
                Select([{ value: '不移动止损' }, { value: '移动到当前浮盈 - xR' }, { value: '移动到 xR 位置' }])
                  .selected(['none', 'fixedRR', 'absoluteRR'].indexOf(level.stopType)).value(level.stopType === 'none' ? '不移动止损' : level.stopType === 'fixedRR' ? '当前浮盈 - xR' : '移动到 xR 位置')
                  .onSelect((i: number) => this.update(index, 'stopType', ['none', 'fixedRR', 'absoluteRR'][i])).width('100%')
                if (level.stopType !== 'none') { TextInput({ text: level.stopValue, placeholder: level.stopType === 'absoluteRR' ? '目标 R，必须大于 -1' : '回撤 R，必须大于0' }).onChange((v: string) => this.update(index, 'stopValue', v)).height(48).backgroundColor($r('app.color.input')).fontColor($r('app.color.text_primary')) }
              }.width('100%').padding(12).border({ width: 1, color: $r('app.color.border') }).borderRadius(8)
            })
            if (this.levels.length < 5) { ActionButton({ label: '添加层级', secondary: true, action: () => { const next = new StrategyLevel(); next.profit = String(this.levels.length + 1); this.levels = this.levels.concat([next]); } }) }
            ActionButton({ label: this.busy ? '保存中…' : '保存策略', interactive: !this.busy, action: () => this.save() })
            ActionButton({ label: '取消编辑', secondary: true, interactive: !this.busy, action: () => { this.editing = false; } })
          }
        } else {
          ActionButton({ label: '新建策略', action: () => this.edit(new DataValue()) })
          ForEach(this.strategies(), (row: DataValue) => {
            SectionCard() {
              Text(row.value('name') + (row.get('is_active').flag() ? ' · 当前使用' : '')).fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
              ForEach(row.get('levels').rows(), (level: DataValue, i: number) => { Metric({ label: 'L' + (i + 1) + ' · ' + level.value('profitRR') + 'R', value: '减仓 ' + level.value('reducePosition') + '%' }) })
              Row({ space: 10 }) {
                ActionButton({ label: '编辑', secondary: true, action: () => this.edit(row) }).layoutWeight(1)
                ActionButton({ label: '设为当前', interactive: !this.busy && !row.get('is_active').flag(), action: () => { const payload = DataValue.object({ strategy_id: row.get('id').raw }); confirmAction('设为当前策略', row.value('name'), async () => { await this.mutate('set-active', payload); }); } }).layoutWeight(1)
              }.width('100%')
              ActionButton({ label: '删除策略', secondary: true, interactive: !this.busy, action: () => { const payload = DataValue.object({ strategy_id: row.get('id').raw }); confirmAction('删除策略', '确认删除 ' + row.value('name') + '？已有仓位使用的策略快照以服务器为准。', async () => { await this.mutate('delete', payload); }); } })
            }
          }, (row: DataValue) => row.value('id') + ':' + row.json())
          if (!this.strategies().length) { EmptyState({ title: '暂无策略' }) }
        }
        if (this.message) { Text(this.message).fontSize(13).fontColor(GOLD) }
      }.padding(16).width('100%').constraintSize({ maxWidth: 600 })
    }.height('100%').width('100%').backgroundColor($r('app.color.page'))
  }
}
