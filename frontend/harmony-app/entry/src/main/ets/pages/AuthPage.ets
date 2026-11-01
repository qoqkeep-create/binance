import { Runtime } from '../platform/Runtime';
import { DataValue } from '../core/Json';
import { ActionButton, Field, runJob } from '../components/Ui';

@Component
export struct AuthPage {
  @Prop revision: number = 0;
  @State account: string = '';
  @State password: string = '';
  @State confirmation: string = '';
  @State agreed: boolean = false;
  @State mode: string = 'login';
  @State sending: boolean = false;
  @State sent: boolean = false;
  navigate: (route: string) => void = () => {};
  private busy(): boolean { this.revision; return Runtime.store.busy || this.sending; }
  private async submit(): Promise<void> {
    if (this.busy()) return;
    if (!this.agreed) { Runtime.store.report(new Error('请先阅读并同意用户协议和隐私政策')); return; }
    if (this.mode === 'register' && this.password !== this.confirmation) { Runtime.store.report(new Error('两次密码不一致')); return; }
    if (this.mode === 'reset') {
      this.sending = true;
      await runJob(async () => {
        await Runtime.store.session.request('/v1/auth/password-reset/request', 'POST', DataValue.object({ email: this.account.trim() }), {}, false);
        this.sent = true;
      });
      this.sending = false;
    } else await Runtime.store.login(this.account, this.password, this.mode === 'register');
    this.password = ''; this.confirmation = '';
  }
  build() {
    Scroll() {
      Column({ space: 24 }) {
        Row() { Blank(); Text('服务器设置').fontSize(13).fontColor($r('app.color.text_secondary')).onClick(() => this.navigate('server')) }.width('100%')
        Image($r('app.media.app_icon')).width(80).height(80).borderRadius(20).margin({ top: 42 })
        Text('Binance Tools').fontSize(28).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        Text(this.mode === 'login' ? '登录您的账户' : this.mode === 'register' ? '创建您的账户' : '找回密码').fontSize(18).fontColor($r('app.color.text_secondary'))
        Column({ space: 16 }) {
          Field({ label: '邮箱', placeholder: '请输入邮箱地址', value: $account })
          if (this.mode !== 'reset') { Field({ label: '密码', placeholder: '请输入密码', value: $password, secret: true }) }
          if (this.mode === 'register') { Field({ label: '确认密码', value: $confirmation, secret: true }) }
          Row({ space: 4 }) {
            Checkbox({ name: 'agreement' }).select(this.agreed).selectedColor('#F0B90B').onChange((value: boolean) => { this.agreed = value; })
            Text('我已阅读并同意').fontSize(12).fontColor($r('app.color.text_secondary'))
            Text('用户协议').fontSize(12).fontColor('#D9A70A').onClick(() => this.navigate('terms'))
            Text('及').fontSize(12).fontColor($r('app.color.text_secondary'))
            Text('隐私政策').fontSize(12).fontColor('#D9A70A').onClick(() => this.navigate('privacy'))
          }.width('100%')
          ActionButton({ label: this.busy() ? '请稍候…' : this.mode === 'login' ? '登录' : this.mode === 'register' ? '注册' : '发送重置邮件', interactive: !this.busy() && this.agreed && this.account.trim() !== '', action: () => { this.submit(); } })
          if (this.sent) { Text('如该邮箱已注册，我们将发送重置说明。请检查邮箱。').fontSize(13).fontColor($r('app.color.text_secondary')) }
          Row() {
            Text(this.mode === 'login' ? '注册账户' : '返回登录').fontSize(14).fontColor('#D9A70A').onClick(() => { this.mode = this.mode === 'login' ? 'register' : 'login'; this.password = ''; this.confirmation = ''; })
            Blank()
            if (this.mode === 'login') { Text('忘记密码？').fontSize(14).fontColor($r('app.color.text_secondary')).onClick(() => { this.mode = 'reset'; this.password = ''; }) }
          }.width('100%')
        }.width('100%').margin({ top: 12 })
        if (this.mode === 'reset') { Text('使用邮件中的令牌重置密码').fontSize(13).fontColor('#D9A70A').onClick(() => this.navigate('reset-confirm')) }
        Text('行情 · 风险管理 · 交易记录').fontSize(12).fontColor($r('app.color.text_secondary')).margin({ top: 24, bottom: 24 })
      }.width('100%').constraintSize({ maxWidth: 448 }).padding(24)
    }.width('100%').height('100%').backgroundColor($r('app.color.background'))
  }
}
