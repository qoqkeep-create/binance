import { AGREEMENT, PRIVACY, LegalSection } from '../core/Legal';
@Component
export struct LegalPage {
  document: string = 'terms';
  build() {
    Scroll() {
      Column({ space: 24 }) {
        ForEach(this.document === 'privacy' ? PRIVACY : AGREEMENT, (section: LegalSection) => {
          Column({ space: 10 }) {
            Text(section.title).fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
            ForEach(section.paragraphs, (text: string) => { Text(text).fontSize(14).lineHeight(24).fontColor($r('app.color.text_secondary')).width('100%') })
          }.alignItems(HorizontalAlign.Start).width('100%')
        })
        Text('最后更新日期：2024年1月').fontSize(12).fontColor($r('app.color.text_secondary'))
      }.padding(24).width('100%').constraintSize({ maxWidth: 600 })
    }.height('100%').width('100%').backgroundColor($r('app.color.surface'))
  }
}
