import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { Runtime } from '../platform/Runtime';
import { DataValue } from '../core/Json';
import { normalizeOrigin, DEFAULT_API } from '../core/Session';
import { SectionCard, Metric, Field, ActionButton, MenuRow, confirmAction, GOLD } from '../components/Ui';

@Component
export struct SettingsPage {
  @State appearance: string = 'system';
  @State openRegistration: boolean = false;
  @State admin: boolean = false;
  @State busy: boolean = false;
  navigate: (route: string) => void = () => {};
  aboutToAppear(): void {
    this.appearance = Runtime.store.preferences.read('appearance', 'system');
    this.loadAdmin();
  }
  private async loadAdmin(): Promise<void> {
    if (!Runtime.store.session.user.get('isAdmin').flag() && !Runtime.store.session.user.get('is_staff').flag()) return;
    try { const value = await Runtime.store.session.request('/v1/auth/admin-settings'); this.admin = value.get('is_admin').flag(); this.openRegistration = value.get('open_registration').flag(); } catch (_) { this.admin = false; }
  }
  private setAppearance(value: string): void {
    this.appearance = value; Runtime.store.preferences.write('appearance', value);
    const context = getContext(this) as common.UIAbilityContext;
    context.getApplicationContext().setColorMode(value === 'dark' ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK : value === 'light' ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    Runtime.store.chartRevision++; Runtime.store.changed();
  }
  build() {
    Scroll() {
      Column({ space: 16 }) {
        SectionCard() {
          Text('外观').fontSize(18).fontColor($r('app.color.text_primary'))
          ForEach(['system', 'light', 'dark'], (value: string, index: number) => { MenuRow({ label: ['跟随系统', '浅色', '深色'][index], symbol: this.appearance === value ? '✓' : '○', action: () => this.setAppearance(value) }) })
        }
        SectionCard() {
          MenuRow({ label: '服务器设置', action: () => this.navigate('server') })
          MenuRow({ label: '持仓浮窗', action: () => this.navigate('floating') })
          MenuRow({ label: '通过邮件令牌重置密码', action: () => this.navigate('reset-confirm') })
          Metric({ label: '当前版本', value: '1.0.0 · HarmonyOS' })
        }
        if (this.admin) {
          SectionCard() {
            Metric({ label: '开放注册', value: this.openRegistration ? '已开放' : '已关闭' })
            ActionButton({ label: this.openRegistration ? '关闭注册' : '开放注册', interactive: !this.busy, action: () => {
              const target = !this.openRegistration;
              confirmAction('修改注册设置', target ? '确认开放新用户注册？' : '确认关闭新用户注册？', async () => { this.busy = true; try { const value = await Runtime.store.session.request('/v1/auth/admin-settings', 'POST', DataValue.object({ open_registration: target })); this.openRegistration = value.get('open_registration').flag(); } finally { this.busy = false; } });
            } })
          }
        }
      }.padding(16).width('100%').constraintSize({ maxWidth: 600 })
    }.width('100%').height('100%').backgroundColor($r('app.color.page'))
  }
}
@Component
export struct ServerPage {
  @State origin: string = '';
  @State busy: boolean = false;
  aboutToAppear(): void { this.origin = Runtime.store.session.baseUrl; }
  private save(): void {
    try {
      const origin = normalizeOrigin(this.origin);
      confirmAction('切换服务器', origin + '\n切换后需要重新登录。', async () => { this.busy = true; try { await Runtime.store.changeServer(origin); } finally { this.busy = false; } });
    } catch (e) { Runtime.store.report(e as Error); }
  }
  build() {
    Column({ space: 16 }) {
      SectionCard() {
        Field({ label: 'HTTPS 服务地址', value: $origin })
        ActionButton({ label: '保存并重新登录', interactive: !this.busy, action: () => this.save() })
        ActionButton({ label: '填入整合环境地址', secondary: true, action: () => { this.origin = DEFAULT_API; } })
      }
    }.padding(16).height('100%').width('100%').backgroundColor($r('app.color.page'))
  }
}
@Component
export struct ResetConfirmPage {
  @State uid: string = '';
  @State token: string = '';
  @State password: string = '';
  @State confirmation: string = '';
  @State busy: boolean = false;
  @State message: string = '';
  private submit(): void {
    if (this.password.length < 8 || this.password !== this.confirmation) { this.message = '密码至少8位，两次输入需要一致'; return; }
    const payload = DataValue.object({ uid: this.uid.trim(), token: this.token.trim(), new_password: this.password, confirm_password: this.confirmation });
    confirmAction('重置密码', '使用重置邮件中的 UID 与令牌更改密码。', async () => { this.busy = true; try { await Runtime.store.session.request('/v1/auth/password-reset/confirm', 'POST', payload, {}, false); this.message = '密码已重置，请重新登录'; this.token = ''; } finally { this.busy = false; this.password = ''; this.confirmation = ''; } });
  }
  build() {
    Scroll() {
      Column({ space: 16 }) {
        SectionCard() {
          Text('填写重置邮件链接中的 uid 和 token。').fontSize(13).fontColor($r('app.color.text_secondary'))
          Field({ label: 'UID', value: $uid })
          Field({ label: '重置令牌', value: $token, secret: true })
          Field({ label: '新密码（至少8位）', value: $password, secret: true })
          Field({ label: '确认新密码', value: $confirmation, secret: true })
          ActionButton({ label: '确认重置', interactive: !this.busy && !!this.uid && !!this.token, action: () => this.submit() })
          if (this.message) { Text(this.message).fontSize(13).fontColor(GOLD) }
        }
      }.padding(16).width('100%')
    }.width('100%').height('100%').backgroundColor($r('app.color.page'))
  }
}
