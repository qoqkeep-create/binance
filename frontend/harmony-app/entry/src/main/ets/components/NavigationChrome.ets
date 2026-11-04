import { Runtime } from '../platform/Runtime';

@Component
export struct NavigationHeader {
  @Prop title: string = '';
  @Prop showsBack: boolean = true;
  back: () => void = () => {};
  build() {
    Stack({ alignContent: Alignment.Start }) {
      Text(this.title).fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        .textAlign(TextAlign.Center).width('100%')
      if (this.showsBack) {
        Row() { Image($r('app.media.ui_back')).width(18).height(18).fillColor($r('app.color.text_primary')) }
          .width(44).height(44).justifyContent(FlexAlign.Center).onClick(this.back).accessibilityText('返回').id('navigation.back')
      }
    }.height(52).width('100%').padding({ left: 10, right: 10 }).backgroundColor($r('app.color.background'))
  }
}

@Component
export struct BottomNavigation {
  @Link selected: string;
  @Prop revision: number = 0;
  private tabs: string[] = ['market', 'positions', 'signals', 'profile'];
  private label(tab: string): string { return tab === 'market' ? '行情' : tab === 'positions' ? '持仓' : tab === 'signals' ? '信号' : '我的'; }
  private icon(tab: string): Resource {
    return tab === 'market' ? $r('app.media.nav_market') : tab === 'positions' ? $r('app.media.nav_positions') : tab === 'signals' ? $r('app.media.nav_signals') : $r('app.media.nav_profile');
  }
  private selectedColor(): ResourceColor { this.revision; return Runtime.store.session.mode === 'lead' ? $r('app.color.navigation_lead_selected') : $r('app.color.brand'); }
  build() {
    Row() {
      ForEach(this.tabs, (tab: string) => {
        Column({ space: 2 }) {
          Image(this.icon(tab)).width(29).height(29).fillColor(this.selected === tab ? this.selectedColor() : $r('app.color.navigation_idle'))
          Text(this.label(tab)).fontSize(12).fontColor(this.selected === tab ? this.selectedColor() : $r('app.color.navigation_idle'))
        }.constraintSize({ minHeight: 49 }).justifyContent(FlexAlign.Center).layoutWeight(1)
          .onClick(() => { this.selected = tab; }).accessibilityText(this.label(tab)).id('tab.' + tab)
      }, (tab: string) => tab)
    }.width('100%').padding({ top: 2, bottom: 8 }).backgroundColor($r('app.color.background'))
      .border({ width: { top: 1 }, color: $r('app.color.border') })
  }
}
