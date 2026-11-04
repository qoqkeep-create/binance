import { Runtime } from '../platform/Runtime';
import { IndicatorParameters, parameterFields, ParameterField } from '../core/ChartSettings';

const TABS: string[] = ['MA', 'EMA', 'BOLL', 'SAR', 'AVL', 'SUPER', 'VOL', 'MACD', 'RSI', 'KDJ', 'OBV', 'WR', 'StochRSI', 'ATR', '合约数据'];
@Component
export struct IndicatorSettingsPage {
  @State selected: string = 'EMA';
  @State values: Record<string, string> = {};
  @State transparency: number = 20;
  back: () => void = () => {};
  applied: () => void = () => {};
  aboutToAppear(): void { this.load(IndicatorParameters.load(Runtime.store.preferences.read('chart-parameters-v1', '{}'))); }
  private load(p: IndicatorParameters): void {
    const fields: Record<string, string> = {}; for (const key of Object.keys(p.values)) fields[key] = String(p.values[key]); this.values = fields;
    this.transparency = Math.round((1 - Math.min(1, p.values['superAlpha'] / 0.2)) * 100);
  }
  private update(key: string, text: string): void { const next: Record<string, string> = {}; for (const k of Object.keys(this.values)) next[k] = this.values[k]; next[key] = text; this.values = next; }
  private resolved(): IndicatorParameters {
    const p = new IndicatorParameters();
    for (const kind of TABS) for (const field of parameterFields(kind)) {
      const text = this.values[field.key]?.trim() || ''; const valid = field.integer ? /^\d+$/.test(text) : /^\d+(\.\d+)?$/.test(text);
      p.values[field.key] = valid ? Number(text) : NaN;
    }
    p.values['superAlpha'] = 0.2 * (1 - this.transparency / 100); return p;
  }
  private title(): string { return this.selected === 'SUPER' ? 'SuperTrend' : this.selected; }
  private subtitle(): string {
    const labels: Record<string, string> = { 'MA': '简单移动平均线，三个周期必须从小到大排列。', 'EMA': '指数移动平均线，三个周期必须从小到大排列。', 'BOLL': '布林带周期与标准差倍数。', 'SAR': '抛物线转向指标，起始步长不能大于最大步长。', 'SUPER': '调整趋势周期、倍数与填充透明度。', 'VOL': '成交量与短、长周期均量线。', 'MACD': '快线周期必须小于慢线周期。', 'AVL': '每根 K 线的成交额 / 成交量，无可调参数。', 'OBV': '根据收盘涨跌累计成交量，无可调参数。', '合约数据': '合约数据由服务端提供；可在图表快捷栏选择副图。' };
    return labels[this.selected] || '调整指标计算周期与平滑参数。';
  }
  build() {
    Column({ space: 0 }) {
      Row() {
        Image($r('app.media.ui_back')).width(20).height(20).fillColor($r('app.color.text_primary')).margin({ right: 24 }).onClick(this.back).id('indicator.back')
        Blank(); Text('指标设置').fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')); Blank()
        Text('重置').fontSize(15).fontColor($r('app.color.auth_link')).height(44).onClick(() => this.load(new IndicatorParameters())).id('indicator.reset')
      }.width('100%').height(52).padding({ left: 16, right: 16 }).border({ width: { bottom: 0.5 }, color: $r('app.color.border') })
      Grid() {
        ForEach(TABS, (name: string) => {
          GridItem() {
            Text(name === 'SUPER' ? 'Super' : name).fontSize(14).fontWeight(FontWeight.Medium).maxLines(1).minFontSize(10).textAlign(TextAlign.Center)
              .fontColor(this.selected === name ? '#181A20' : $r('app.color.text_primary')).backgroundColor(this.selected === name ? $r('app.color.auth_accent') : $r('app.color.surface'))
              .width('100%').height(36).borderRadius(8).onClick(() => { this.selected = name; }).id('indicator.tab.' + name)
          }
        })
      }.columnsTemplate('1fr 1fr 1fr 1fr').columnsGap(8).rowsGap(8).height(184).padding({ left: 16, right: 16, top: 12, bottom: 4 })
      Scroll() {
        Column({ space: 0 }) {
          Text(this.title()).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).width('100%')
          Text(this.subtitle()).fontSize(12).fontColor($r('app.color.text_secondary')).margin({ top: 6, bottom: 16 }).width('100%')
          ForEach(parameterFields(this.selected), (field: ParameterField) => {
            Row({ space: 12 }) {
              Text(field.title).fontSize(14).fontColor($r('app.color.text_primary')).layoutWeight(1)
              TextInput({ text: this.values[field.key], placeholder: String(field.value) }).type(InputType.NUMBER_DECIMAL)
                .onChange((v: string) => this.update(field.key, v)).width(116).height(40).fontSize(14).fontColor($r('app.color.text_primary')).textAlign(TextAlign.End)
                .backgroundColor($r('app.color.input')).borderRadius(5).padding({ left: 10, right: 10 }).enablePreviewText(false).id('indicator.field.' + field.key)
            }.height(56).width('100%').border({ width: { bottom: 0.5 }, color: $r('app.color.border') })
          }, (field: ParameterField) => field.key)
          if (this.selected === 'SUPER') {
            Row() { Text('填充透明度').fontSize(14).fontColor($r('app.color.text_primary')).layoutWeight(1); Text(String(Math.round(this.transparency)) + '%').fontSize(14).fontColor($r('app.color.text_primary')) }.margin({ top: 16 }).width('100%')
            Slider({ value: this.transparency, min: 0, max: 100, step: 1 }).selectedColor($r('app.color.auth_accent')).onChange((v: number) => { this.transparency = v; }).id('indicator.transparency')
          }
          if (!this.resolved().valid()) { Text('请输入范围内的有效参数，并检查周期顺序。').fontSize(12).fontColor($r('app.color.negative')).margin({ top: 12 }).width('100%') }
        }.alignItems(HorizontalAlign.Start).width('100%').padding(16).backgroundColor($r('app.color.surface')).borderRadius(10)
      }.align(Alignment.Top).layoutWeight(1).width('100%').padding(16)
      Row() {
      Button('应用', { type: ButtonType.Normal }).height(48).width('100%').fontSize(16).fontWeight(FontWeight.Medium).fontColor('#181A20').borderRadius(6)
        .backgroundColor($r('app.color.auth_accent')).enabled(this.resolved().valid()).opacity(this.resolved().valid() ? 1 : 0.45)
        .onClick(() => { const p = this.resolved(); if (!p.valid()) return; Runtime.store.preferences.write('chart-parameters-v1', p.json()); Runtime.store.chartRevision++; Runtime.store.changed(); this.applied(); this.back(); }).id('indicator.apply')
      }.padding({ left: 16, right: 16, top: 10, bottom: 12 }).width('100%')
    }.width('100%').height('100%').backgroundColor($r('app.color.background'))
  }
}
