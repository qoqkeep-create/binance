import { Runtime } from '../platform/Runtime';
import { DataValue } from '../core/Json';
import { registrationState, validateAuthForm } from '../core/AuthForm';
import { LegalPage } from './LegalPage';

@Component
export struct AuthPage {
  @Prop revision: number = 0;
  @State sheetOpen: boolean = false;
  @State sheetMode: string = 'register';
  @State sheetEmail: string = '';
  @State sheetBusy: boolean = false;
  navigate: (route: string) => void = () => {};
  private open(mode: string, email: string): void {
    this.sheetMode = mode; this.sheetEmail = email; this.sheetOpen = true;
  }
  @Builder
  private formSheet() {
    Column({ space: 0 }) {
      Row() {
        Blank()
        Text('×').fontSize(26).fontColor($r('app.color.auth_primary')).width(44).height(44).textAlign(TextAlign.Center)
          .enabled(!this.sheetBusy).onClick(() => { this.sheetOpen = false; }).accessibilityText('关闭').id('auth.sheet.close')
      }.padding({ right: 12 }).width('100%')
      AuthForm({ mode: this.sheetMode, initialEmail: this.sheetEmail, close: () => { this.sheetOpen = false; }, busyChanged: (value: boolean) => { this.sheetBusy = value; } })
    }.width('100%').height('100%').backgroundColor($r('app.color.background'))
  }
  build() {
    Column() {
      AuthForm({ mode: 'login', open: (mode: string, email: string) => this.open(mode, email), openServer: () => this.navigate('server') })
    }.width('100%').height('100%')
      .bindSheet($$this.sheetOpen, this.formSheet, {
        height: '96%', dragBar: true, showClose: false, preferType: SheetType.BOTTOM,
        backgroundColor: $r('app.color.background'), radius: { topLeft: 24, topRight: 24 },
        onWillDismiss: (action: DismissSheetAction) => { if (!this.sheetBusy) action.dismiss(); }
      })
  }
}

@Component
struct AuthField {
  @Prop label: string = '';
  @Prop placeholder: string = '';
  @Prop secret: boolean = false;
  @Prop fieldId: string = '';
  @Link value: string;
  @State focused: boolean = false;
  submit: () => void = () => {};
  build() {
    Column({ space: 9 }) {
      Text(this.label).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.auth_primary'))
      TextInput({ text: this.value, placeholder: this.placeholder })
        .id(this.fieldId).type(this.secret ? InputType.Password : InputType.Email).showPasswordIcon(this.secret)
        .onChange((value: string) => { this.value = value; }).onFocus(() => { this.focused = true; }).onBlur(() => { this.focused = false; })
        .enterKeyType(this.secret ? EnterKeyType.Go : EnterKeyType.Next).onSubmit(this.submit)
        .height(this.secret ? 52 : 48).borderRadius(10).padding({ left: 14, right: 14 })
        .backgroundColor($r('app.color.auth_input')).fontColor($r('app.color.auth_primary'))
        .placeholderColor($r('app.color.auth_secondary')).fontSize(17)
        .border({ width: this.focused ? 1.5 : 1, color: this.focused ? $r('app.color.auth_accent') : $r('app.color.auth_border') })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}

@Component
struct AuthForm {
  @Prop mode: string = 'login';
  @Prop initialEmail: string = '';
  @State email: string = '';
  @State password: string = '';
  @State confirmation: string = '';
  @State agreed: boolean = false;
  @State submitting: boolean = false;
  @State completed: boolean = false;
  @State notice: string = '';
  @State registration: string = 'loading';
  @State legalOpen: boolean = false;
  @State legal: string = 'terms';
  open: (mode: string, email: string) => void = () => {};
  openServer: () => void = () => {};
  close: () => void = () => {};
  busyChanged: (value: boolean) => void = () => {};
  private requestGeneration: number = 0;
  aboutToAppear(): void { this.email = this.initialEmail; if (this.mode === 'register') this.loadRegistration(); }
  aboutToDisappear(): void { this.requestGeneration++; this.password = ''; this.confirmation = ''; }
  private title(): string { return this.mode === 'login' ? '登录' : this.mode === 'register' ? '注册' : '找回密码'; }
  private subtitle(): string { return this.mode === 'login' ? '登录后查看行情与管理交易' : this.mode === 'register' ? '创建账号，开启你的交易工具箱' : '输入注册邮箱，接收密码重置邮件'; }
  private async loadRegistration(): Promise<void> {
    const generation = ++this.requestGeneration; this.registration = 'loading';
    try {
      const value = await Runtime.store.session.request('/v1/auth/admin-settings', 'GET', DataValue.object(), {}, false);
      if (generation === this.requestGeneration) this.registration = registrationState(value);
    } catch (_) { if (generation === this.requestGeneration) this.registration = 'unavailable'; }
  }
  private openForm(mode: string): void {
    if (this.submitting) return;
    this.getUIContext().getFocusController().clearFocus(); this.password = ''; this.confirmation = '';
    this.open(mode, this.email);
  }
  private async submit(): Promise<void> {
    if (this.submitting) return;
    this.notice = validateAuthForm({ mode: this.mode, email: this.email, password: this.password, confirmation: this.confirmation, agreed: this.agreed, registration: this.registration });
    if (this.notice) return;
    this.getUIContext().getFocusController().clearFocus();
    this.submitting = true; this.busyChanged(true);
    const generation = ++this.requestGeneration;
    try {
      if (this.mode === 'reset') {
        await Runtime.store.session.request('/v1/auth/password-reset/request', 'POST', DataValue.object({ email: this.email.trim() }), {}, false);
        if (generation === this.requestGeneration) this.completed = true;
      } else {
        await Runtime.store.session.authenticate(this.email.trim(), this.password, this.mode === 'register');
        Runtime.store.start(); Runtime.store.changed();
      }
    } catch (e) { if (generation === this.requestGeneration) this.notice = (e as Error).message; }
    finally { if (generation === this.requestGeneration) { this.submitting = false; this.busyChanged(false); } }
  }
  @Builder
  private legalSheet() {
    Column({ space: 0 }) {
      Row() {
        Text(this.legal === 'privacy' ? '隐私政策' : '用户协议').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.auth_primary')).layoutWeight(1)
        Text('×').fontSize(26).width(44).height(44).textAlign(TextAlign.Center).fontColor($r('app.color.auth_primary'))
          .onClick(() => { this.legalOpen = false; }).accessibilityText('关闭')
      }.width('100%').padding({ left: 24, right: 12 })
      Column() { LegalPage({ document: this.legal }) }.layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor($r('app.color.surface'))
  }
  private showLegal(document: string): void {
    this.getUIContext().getFocusController().clearFocus(); this.legal = document; this.legalOpen = true;
  }
  build() {
    Scroll() {
      Column({ space: 0 }) {
        Row({ space: 12 }) {
          Image($r('app.media.app_icon')).width(42).height(42).borderRadius(9.24)
          Column({ space: 2 }) {
            Text('Binance Tools').fontSize(17).fontWeight(FontWeight.Bold).letterSpacing(0.3).fontColor($r('app.color.auth_primary'))
            Text('MARKET & TRADING').fontSize(11).fontWeight(FontWeight.Medium).letterSpacing(0.8).fontColor($r('app.color.auth_secondary'))
          }.alignItems(HorizontalAlign.Start)
        }.width('100%').margin({ bottom: 48 })
          .gesture(LongPressGesture().onAction(() => { if (this.mode === 'login' && !this.submitting) this.openServer(); }))
        Text(this.title()).fontSize(32).fontWeight(FontWeight.Bold).fontColor($r('app.color.auth_primary'))
        Text(this.subtitle()).fontSize(15).fontColor($r('app.color.auth_secondary')).margin({ top: 9, bottom: 32 })
        if (this.completed) {
          Text('✓').fontSize(36).fontColor($r('app.color.positive')).margin({ bottom: 24 })
          Text('如果该邮箱已注册，重置邮件会在几分钟内发送。请在 30 分钟内打开邮件中的链接。')
            .fontSize(15).fontColor($r('app.color.auth_primary')).margin({ bottom: 24 })
          AuthPrimaryButton({ label: '返回登录', action: this.close })
        } else {
          if (this.mode === 'register' && this.registration !== 'open') {
            Text(this.registration === 'loading' ? '正在确认注册状态…' : this.registration === 'closed' ? '暂未开放注册，请联系管理员' : '暂时无法获取注册状态，请重试')
              .fontSize(13).fontColor(this.registration === 'loading' ? $r('app.color.auth_secondary') : $r('app.color.negative')).margin({ bottom: 20 })
            if (this.registration === 'unavailable') { Text('重试').fontSize(13).fontColor($r('app.color.auth_link')).margin({ bottom: 20 }).onClick(() => this.loadRegistration()) }
          }
          AuthField({ label: '邮箱', placeholder: '请输入邮箱', value: $email, fieldId: this.mode + '.account', submit: () => { if (this.mode === 'reset') this.submit(); else this.getUIContext().getFocusController().requestFocus(this.mode + '.password'); } })
          if (this.mode !== 'reset') {
            AuthField({ label: '密码', placeholder: this.mode === 'login' ? '请输入密码' : '至少 8 位密码', value: $password, secret: true, fieldId: this.mode + '.password', submit: () => this.submit() }).margin({ top: 18 })
          }
          if (this.mode === 'register') {
            AuthField({ label: '确认密码', placeholder: '请再次输入密码', value: $confirmation, secret: true, fieldId: 'register.confirmPassword', submit: () => this.submit() }).margin({ top: 18 })
          }
          if (this.mode === 'login') {
            Row() { Blank(); Text('忘记密码？').fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.auth_link')).onClick(() => this.openForm('reset')) }
              .width('100%').margin({ top: 14 })
          }
          if (this.mode !== 'reset') {
            Row({ space: 8 }) {
              Checkbox({ name: 'agreement' }).select(this.agreed).shape(CheckBoxShape.ROUNDED_SQUARE)
                .width(18).height(18).margin({ left: 3, right: 3, top: 3, bottom: 3 }).selectedColor($r('app.color.auth_accent'))
                .unselectedColor($r('app.color.auth_secondary')).mark({ strokeColor: '#181A20' }).onChange((value: boolean) => { this.agreed = value; })
                .accessibilityText('同意用户协议和隐私政策').id(this.mode + '.agreement')
              Text() {
                Span('我已阅读并同意 ').fontColor($r('app.color.auth_secondary'))
                Span('用户协议').fontColor($r('app.color.auth_link')).onClick(() => this.showLegal('terms'))
                Span(' 和 ').fontColor($r('app.color.auth_secondary'))
                Span('隐私政策').fontColor($r('app.color.auth_link')).onClick(() => this.showLegal('privacy'))
              }.fontSize(13).lineHeight(20).layoutWeight(1)
            }.width('100%').alignItems(VerticalAlign.Top).margin({ top: 20 })
          }
          if (this.notice) { Text(this.notice).fontSize(13).fontColor($r('app.color.negative')).margin({ top: 16 }).id('auth.notice') }
          Column() { AuthPrimaryButton({ label: this.mode === 'reset' ? '发送重置邮件' : this.title(), busy: this.submitting, available: !this.submitting && (this.mode !== 'register' || this.registration === 'open'), action: () => this.submit() }) }
            .width('100%').margin({ top: 28 }).id(this.mode === 'login' ? 'auth.submit' : this.mode + '.submit')
          Text(this.mode === 'login' ? '注册账号' : '返回登录').fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.auth_link'))
            .textAlign(TextAlign.Center).width('100%').margin({ top: 18 }).enabled(!this.submitting)
            .onClick(() => { if (this.mode === 'login') this.openForm('register'); else this.close(); })
          Row({ space: 10 }) {
            Image($r('app.media.auth_security')).width(16).height(16).fillColor($r('app.color.auth_link'))
            Text('妥善保管账号信息，保护你的交易安全').fontSize(12).fontColor($r('app.color.auth_secondary'))
          }.width('100%').margin({ top: 28 })
        }
      }.alignItems(HorizontalAlign.Start).width('100%').constraintSize({ maxWidth: 520 })
        .padding({ left: 24, right: 24, top: this.mode === 'login' ? 36 : 16, bottom: 40 })
    }.width('100%').height('100%').align(Alignment.Top).scrollBar(BarState.Off).backgroundColor($r('app.color.background'))
      .bindSheet($$this.legalOpen, this.legalSheet, { height: '80%', dragBar: true, showClose: false, preferType: SheetType.BOTTOM, backgroundColor: $r('app.color.surface'), radius: { topLeft: 24, topRight: 24 } })
  }
}

@Component
struct AuthPrimaryButton {
  @Prop label: string = '';
  @Prop busy: boolean = false;
  @Prop available: boolean = true;
  action: () => void = () => {};
  build() {
    Button({ type: ButtonType.Normal }) {
      if (this.busy) { LoadingProgress().width(24).height(24).color('#181A20') }
      else { Text(this.label).fontSize(17).fontWeight(FontWeight.Bold).fontColor('#181A20') }
    }.width('100%').height(48).borderRadius(10).backgroundColor($r('app.color.auth_accent'))
      .enabled(this.available).opacity(this.available ? 1 : 0.45).onClick(this.action)
  }
}
