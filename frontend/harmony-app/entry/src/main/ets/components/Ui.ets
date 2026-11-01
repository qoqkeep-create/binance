import { promptAction } from '@kit.ArkUI';
import { Runtime } from '../platform/Runtime';
import { DataValue } from '../core/Json';
import { amount } from '../core/Decimal';

export const GREEN: string = '#0ECB81';
export const RED: string = '#F6465D';
export const GOLD: string = '#F0B90B';

export async function runJob(job: () => Promise<void>): Promise<void> {
  try { await job(); } catch (e) { Runtime.store.report(e as Error); }
}
export async function confirmAction(title: string, message: string, job: () => Promise<void>): Promise<void> {
  const scope = Runtime.store.session.scope;
  const choice = await promptAction.showDialog({ title: title, message: message, buttons: [{ text: '取消', color: '#848E9C' }, { text: '确认', color: GOLD }] });
  if (choice.index !== 1 || scope !== Runtime.store.session.scope) return;
  await runJob(job);
}
export function dateText(text: string): string {
  const date = new Date(text); if (!Number.isFinite(date.getTime())) return '--';
  return date.toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai', hour12: false });
}
export function money(row: DataValue, key: string, places: number = 2): string { return amount(row.value(key, ''), places); }

@Component
export struct SectionCard {
  @BuilderParam content: () => void;
  build() {
    Column({ space: 14 }) { this.content() }
      .alignItems(HorizontalAlign.Start).width('100%').padding(16)
      .backgroundColor($r('app.color.surface')).borderRadius(10)
  }
}
@Component
export struct Metric {
  @Prop label: string = '';
  @Prop value: string = '--';
  @Prop color: ResourceColor = $r('app.color.text_primary');
  build() {
    Row({ space: 12 }) {
      Text(this.label).fontSize(14).fontColor($r('app.color.text_secondary')).layoutWeight(1)
      Text(this.value).fontSize(14).fontColor(this.color).textAlign(TextAlign.End).maxLines(3)
    }.width('100%').constraintSize({ minHeight: 22 })
  }
}
@Component
export struct Field {
  @Prop label: string = '';
  @Prop placeholder: string = '';
  @Link value: string;
  @Prop secret: boolean = false;
  @Prop numeric: boolean = false;
  @Prop interactive: boolean = true;
  build() {
    Column({ space: 8 }) {
      if (this.label) { Text(this.label).fontSize(14).fontColor($r('app.color.text_secondary')) }
      TextInput({ text: this.value, placeholder: this.placeholder || this.label })
        .type(this.secret ? InputType.Password : this.numeric ? InputType.NUMBER_DECIMAL : InputType.Normal)
        .onChange((value: string) => { this.value = value; }).enabled(this.interactive)
        .height(48).borderRadius(10).backgroundColor($r('app.color.input'))
        .fontColor($r('app.color.text_primary')).fontSize(16).padding({ left: 16, right: 16 })
        .copyOption(this.secret ? CopyOptions.None : CopyOptions.LocalDevice)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
@Component
export struct ActionButton {
  @Prop label: string = '';
  @Prop color: ResourceColor = GOLD;
  @Prop interactive: boolean = true;
  @Prop secondary: boolean = false;
  action: () => void = () => {};
  build() {
    Button(this.label, { type: ButtonType.Normal }).width('100%').height(48).borderRadius(10)
      .backgroundColor(this.secondary ? $r('app.color.input') : this.color)
      .fontColor(this.secondary ? $r('app.color.text_primary') : '#181A20').fontSize(16).fontWeight(FontWeight.Medium)
      .enabled(this.interactive).opacity(this.interactive ? 1 : 0.45).onClick(this.action)
  }
}
@Component
export struct EmptyState {
  @Prop title: string = '暂无记录';
  @Prop detail: string = '';
  build() {
    Column({ space: 10 }) {
      Text('—').fontSize(36).fontColor($r('app.color.text_secondary'))
      Text(this.title).fontSize(16).fontColor($r('app.color.text_primary'))
      if (this.detail) { Text(this.detail).fontSize(12).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center) }
    }.padding(36).width('100%')
  }
}
@Component
export struct MenuRow {
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop symbol: string = '›';
  action: () => void = () => {};
  build() {
    Row({ space: 10 }) {
      Text(this.label).fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
      if (this.value) { Text(this.value).fontSize(13).fontColor($r('app.color.text_secondary')) }
      Text(this.symbol).fontSize(22).fontColor($r('app.color.text_secondary'))
    }.height(56).width('100%').padding({ left: 16, right: 16 }).backgroundColor($r('app.color.surface'))
      .onClick(this.action).accessibilityText(this.label)
  }
}
@Component
export struct ChoiceBar {
  @Prop labels: string[] = [];
  @Link selected: number;
  changed: (index: number) => void = () => {};
  build() {
    Row({ space: 6 }) {
      ForEach(this.labels, (label: string, index: number) => {
        Text(label).fontSize(14).fontWeight(this.selected === index ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(this.selected === index ? '#181A20' : $r('app.color.text_secondary'))
          .padding({ left: 12, right: 12, top: 10, bottom: 10 }).borderRadius(6)
          .backgroundColor(this.selected === index ? GOLD : Color.Transparent)
          .onClick(() => { this.selected = index; this.changed(index); })
      })
    }.width('100%')
  }
}
