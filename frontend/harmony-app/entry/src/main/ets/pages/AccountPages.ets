import { Runtime } from '../platform/Runtime';
import { DataValue } from '../core/Json';
import { stopLossPreview } from '../core/MoneyRules';
import { Decimal, amount } from '../core/Decimal';
import { SectionCard, Metric, Field, ActionButton, MenuRow, confirmAction, RED, GOLD, GREEN, dateText } from '../components/Ui';

@Component
export struct ProfilePage {
  @Prop revision: number = 0;
  navigate: (route: string) => void = () => {};
  private accountValue(key: string, fallback: string = '--'): string { this.revision; return Runtime.store.account.value(key, fallback); }
  private apiLabel(): string { this.revision; return Runtime.store.isBound ? Runtime.store.binding.value('alias') : '未绑定'; }
  private total(): string {
    this.revision;
    try { return ['balance', 'spot_balance', 'funding_balance'].reduce((sum: Decimal, key: string) => sum.add(new Decimal(Runtime.store.account.value(key))), new Decimal('0')).fixed(2); } catch (_) { return '--'; }
  }
  build() {
    Scroll() {
      Column({ space: 16 }) {
        SectionCard() {
          Row() {
            Image($r('app.media.app_icon')).width(44).height(44).borderRadius(12)
            Column({ space: 4 }) {
              Text(this.accountValue('email_masked', Runtime.store.session.user.value('email'))).fontSize(16).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
              Text(Runtime.store.session.mode === 'lead' ? '带单账户' : '合约账户').fontSize(12).fontColor($r('app.color.text_secondary'))
            }.layoutWeight(1).padding({ left: 12 }).alignItems(HorizontalAlign.Start)
            Text('切换').fontSize(14).fontColor(GOLD).onClick(() => {
              const mode = Runtime.store.session.mode === 'lead' ? 'ordinary' : 'lead';
              confirmAction('切换账户模式', '切换后显示该账户的余额和订单，当前持仓及保护继续运行。', async () => { Runtime.store.switchMode(mode); });
            })
          }.width('100%')
          Text(this.total() + ' USDT').fontSize(30).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
          Metric({ label: '合约余额', value: amount(this.accountValue('balance')) + ' USDT' })
          if (Runtime.store.session.mode !== 'lead') {
            Metric({ label: '现货余额', value: amount(this.accountValue('spot_balance')) + ' USDT' })
            Metric({ label: '资金余额', value: amount(this.accountValue('funding_balance')) + ' USDT' })
          }
          Metric({ label: '止损金额', value: amount(this.accountValue('stop_loss_amount')) + ' USDT', color: GOLD })
          ActionButton({ label: '刷新账户', secondary: true, action: () => { Runtime.store.refreshAccount(); } })
        }
        Column() {
          MenuRow({ label: 'API 管理', value: this.apiLabel(), action: () => this.navigate('binding') })
          MenuRow({ label: '止损金额', value: amount(this.accountValue('stop_loss_amount')) + ' USDT', action: () => this.navigate('stop-loss') })
          MenuRow({ label: '止盈止损策略', action: () => this.navigate('strategies') })
          MenuRow({ label: '账户信息', action: () => this.navigate('account') })
          if (Runtime.store.session.mode !== 'lead') {
            MenuRow({ label: '资金整理', action: () => this.navigate('capital') })
            MenuRow({ label: '归集目标', action: () => this.navigate('collection') })
            MenuRow({ label: '资金提醒', action: () => this.navigate('reminder') })
            MenuRow({ label: '转账历史', action: () => this.navigate('transfers') })
          }
          MenuRow({ label: '操作日志', action: () => this.navigate('operations') })
          MenuRow({ label: '交易命令', action: () => this.navigate('commands') })
          MenuRow({ label: '应用内持仓浮窗', action: () => this.navigate('floating') })
          MenuRow({ label: '设置', action: () => this.navigate('settings') })
          MenuRow({ label: '用户协议', action: () => this.navigate('terms') })
          MenuRow({ label: '隐私政策', action: () => this.navigate('privacy') })
        }.borderRadius(10).clip(true)
        ActionButton({ label: '退出登录', secondary: true, action: () => { confirmAction('退出登录', '确认退出当前账户？', async () => { await Runtime.store.logout(); }); } })
        Text('Binance Tools · HarmonyOS 1.0.0').fontSize(12).fontColor($r('app.color.text_secondary')).padding(12)
      }.padding(16).width('100%').constraintSize({ maxWidth: 600 })
    }.width('100%').height('100%').backgroundColor($r('app.color.page'))
  }
}

@Component
export struct AccountFormPage {
  @Prop revision: number = 0;
  kind: string = 'binding';
  @State data: DataValue = new DataValue();
  @State apiKey: string = '';
  @State secret: string = '';
  @State alias: string = '';
  @State percentage: string = '2';
  @State address: string = '';
  @State network: string = '';
  @State loading: boolean = false;
  @State busy: boolean = false;
  @State message: string = '';
  private active: boolean = true;
  aboutToAppear(): void { this.active = true; this.load(); }
  aboutToDisappear(): void { this.active = false; this.apiKey = ''; this.secret = ''; }
  private async load(): Promise<void> {
    this.loading = true;
    try {
      const path = this.kind === 'stop-loss' ? '/v1/account/stop-loss' : this.kind === 'collection' ? '/v1/account/capital-collect-account' : this.kind === 'reminder' ? '/v1/trade/capital/remind' : this.kind === 'account' ? '/v1/account/profile' : '/v1/api/info';
      const value = this.kind === 'capital' ? await Runtime.store.capital.preview() : await Runtime.store.session.request(path);
      if (!this.active) return;
      this.data = value; this.percentage = value.value('current_percentage', '2');
      this.address = value.value('capital_collect_address', ''); this.network = value.value('capital_collect_network', '');
    } catch (e) { if (this.active) this.message = (e as Error).message; }
    finally { if (this.active) this.loading = false; }
  }
  private async write(path: string, payload: DataValue): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    try {
      const value = await Runtime.store.session.request(path, 'POST', payload);
      if (this.active) { this.data = value; this.message = '操作已完成'; }
      if (this.kind === 'binding') await Runtime.store.bindingChanged(); else await Runtime.store.refreshAccount();
    } finally { this.busy = false; this.apiKey = ''; this.secret = ''; }
  }
  private bind(): void {
    const payload = DataValue.object({ api_key: this.apiKey, secret_key: this.secret, passphrase: '', alias: this.alias.trim() });
    confirmAction('确认绑定 API', '绑定到当前' + (Runtime.store.session.mode === 'lead' ? '带单账户' : '合约账户') + '：' + this.alias, async () => { await this.write('/v1/api/bind', payload); });
  }
  private stopTarget(): string { try { return stopLossPreview(this.data.value('total_balance', this.data.value('balance')), this.percentage); } catch (_) { return '--'; } }
  private updateStop(): void {
    if (!/^\d+$/.test(this.percentage) || Number(this.percentage) < 1 || Number(this.percentage) > 25) { this.message = '请输入1至25之间的整数百分比'; return; }
    const payload = DataValue.object({ percentage: this.percentage });
    confirmAction('调整止损金额', '比例：' + this.percentage + '%，预计止损金额：' + this.stopTarget() + ' USDT。调整只作用于后续开仓；降低金额的生效时间以服务器结果为准。', async () => { await this.write('/v1/account/stop-loss', payload); });
  }
  private collectValue(): DataValue { return this.data.get('pending_collection').empty() ? this.data : this.data.get('pending_collection'); }
  private normalize(): void {
    const original = DataValue.parse(this.data.json()); const collection = this.collectValue();
    confirmAction('确认资金整理', '金额：' + collection.value('transfer_amount', collection.value('collection_total')) + ' USDT\n网络：' + collection.value('destination_network') + '\n地址：' + collection.value('destination_address') + '\n请核对上方完整资金计划。', async () => {
      if (this.busy) return; this.busy = true;
      try { const result = await Runtime.store.capital.confirm(original); if (this.active) { this.data = result; this.message = result.value('message', '请预览并核对处理结果'); } await Runtime.store.refreshAccount(); }
      finally { this.busy = false; }
    });
  }
  build() {
    Scroll() {
      Column({ space: 16 }) {
        if (this.loading) { LoadingProgress().width(30).height(30) }
        if (this.kind === 'binding') {
          SectionCard() {
            if (Runtime.store.isBound) {
              Metric({ label: 'API 别名', value: Runtime.store.binding.value('alias') })
              Metric({ label: '连接状态', value: Runtime.store.binding.value('status') === '1' ? '已连接' : '连接异常' })
              ActionButton({ label: '验证连接', secondary: true, interactive: !this.busy, action: () => { confirmAction('验证 API', '重新读取当前 API 的连接状态。', async () => { this.data = await Runtime.store.session.request('/v1/api/info?validate=1'); Runtime.store.binding = this.data; Runtime.store.changed(); }); } })
              ActionButton({ label: '解除 API 绑定', color: RED, interactive: !this.busy, action: () => { confirmAction('解除绑定', '确认解绑当前模式的 API？', async () => { await this.write('/v1/api/unbind', DataValue.object()); }); } })
            } else {
              if (Runtime.store.session.mode === 'lead') { Text('请使用币安对应带单组合的专用 API Key。').fontSize(13).fontColor($r('app.color.text_secondary')) }
              Field({ label: 'API Key', value: $apiKey, secret: true })
              Field({ label: 'Secret Key', value: $secret, secret: true })
              Field({ label: 'API 别名', value: $alias })
              ActionButton({ label: this.busy ? '绑定中…' : '确认绑定', interactive: !this.busy && !!this.apiKey && !!this.secret && !!this.alias.trim(), action: () => this.bind() })
            }
          }
        } else if (this.kind === 'stop-loss') {
          SectionCard() {
            Metric({ label: '当前止损金额', value: amount(this.data.value('current_amount')) + ' USDT' })
            Metric({ label: '账户总资产', value: amount(this.data.value('total_balance', this.data.value('balance'))) + ' USDT' })
            if (!this.data.get('pending_amount').empty()) {
              Metric({ label: '待生效金额', value: amount(this.data.value('pending_amount')) + ' USDT', color: GOLD })
              Metric({ label: '生效时间', value: dateText(this.data.value('pending_effective_at')) })
              ActionButton({ label: '取消待生效调整', secondary: true, interactive: !this.busy, action: () => { confirmAction('取消调整', '确认取消尚未生效的止损金额调整？', async () => { await this.write('/v1/account/stop-loss/cancel', DataValue.object()); }); } })
            }
            Field({ label: '账户余额百分比（%）', value: $percentage, numeric: true })
            Metric({ label: '预计止损金额', value: this.stopTarget() + ' USDT', color: GOLD })
            ActionButton({ label: '确认调整', interactive: !this.busy && this.stopTarget() !== '--', action: () => this.updateStop() })
          }
        } else if (this.kind === 'collection') {
          SectionCard() {
            Metric({ label: '账户类型', value: this.data.value('account_type') === 'sub' ? '子账户' : this.data.value('account_type') === 'master' ? '主账户' : '待同步' })
            Field({ label: '目标主账户 Spot 充值地址', value: $address })
            Select([{ value: 'BSC（BEP20）' }, { value: 'TRX（TRC20）' }, { value: 'ETH（ERC20）' }]).value(this.network || '选择网络').onSelect((index: number) => { this.network = ['BSC', 'TRX', 'ETH'][index]; }).width('100%')
            Text('地址与网络必须匹配，不支持邮箱或 UID。子账户归集按服务器识别的账户关系执行。').fontSize(13).fontColor($r('app.color.text_secondary'))
            ActionButton({ label: '保存目标', interactive: !this.busy, action: () => {
              const payload = DataValue.object({ capital_collect_address: this.address.trim(), capital_collect_network: this.network });
              confirmAction('保存归集目标', this.address + '\n' + this.network, async () => { await this.write('/v1/account/capital-collect-account', payload); });
            } })
            ActionButton({ label: '清除目标', secondary: true, interactive: !this.busy, action: () => { confirmAction('清除目标', '确认清除当前资金归集地址和网络？', async () => { await this.write('/v1/account/capital-collect-account', DataValue.object({ capital_collect_address: '', capital_collect_network: '' })); this.address = ''; this.network = ''; }); } })
          }
        } else if (this.kind === 'capital') {
          SectionCard() {
            Text(this.data.value('message', '预览当前账户的资金整理计划')).fontSize(15).fontColor($r('app.color.text_primary'))
            Metric({ label: '状态', value: this.data.value('status') })
            Metric({ label: '开仓最低线', value: amount(this.data.value('minimum_open_balance', this.data.value('refill_trigger'))) })
            Metric({ label: '合约最高保留', value: amount(this.data.value('maximum_futures_balance', this.data.value('target'))) })
            Metric({ label: '合约余额', value: amount(this.data.value('futures_balance')) })
            ForEach(['funding_to_futures', 'spot_to_futures', 'futures_collect', 'funding_collect', 'transfer_amount'], (key: string, index: number) => {
              if (!this.collectValue().get(key).empty()) { Metric({ label: ['资金 → 合约', '现货 → 合约', '合约 → 现货', '资金 → 现货', '现货 → 主账户'][index], value: amount(this.collectValue().value(key)) + ' USDT' }) }
            })
            if (this.data.value('status') === 'shortfall') { Metric({ label: '至少补充', value: amount(this.data.value('minimum_topup')) }); Metric({ label: '最多补充', value: amount(this.data.value('maximum_topup')) }) }
            if (this.collectValue().value('destination_address', '')) {
              Metric({ label: '目标地址', value: this.collectValue().value('destination_address') })
              Metric({ label: '网络', value: this.collectValue().value('destination_network') })
            }
            if (!this.collectValue().get('collection_id').empty()) { Metric({ label: '归集流水', value: this.collectValue().value('collection_id') }); Text(this.collectValue().value('collection_error', '结果核对期间将继续使用同一流水。')).fontSize(12).fontColor(GOLD) }
            ActionButton({ label: '重新预览 / 核对结果', secondary: true, interactive: !this.busy && !this.loading, action: () => { this.load(); } })
            if (this.data.value('status') === 'normalization_required' || !this.collectValue().get('collection_id').empty()) { ActionButton({ label: this.busy ? '处理中…' : this.collectValue().get('collection_id').empty() ? '确认资金整理' : '继续核对同一流水', interactive: !this.busy && !this.loading, action: () => this.normalize() }) }
          }
        } else if (this.kind === 'reminder') {
          SectionCard() {
            Metric({ label: '账户余额', value: amount(this.data.value('account_total')) })
            Metric({ label: '开仓最低线', value: amount(this.data.value('minimum_open_balance')) })
            Text(this.data.value('email_subject', this.data.value('message'))).fontSize(16).fontColor($r('app.color.text_primary'))
            Text(this.data.value('body', this.data.value('email_body', ''))).fontSize(14).fontColor($r('app.color.text_secondary'))
            ActionButton({ label: '发送资金提醒邮件', interactive: !this.busy && !this.loading, action: () => { confirmAction('发送资金提醒', '确认向当前账户邮箱发送上方资金提醒？', async () => { await this.write('/v1/trade/capital/remind', DataValue.object()); }); } })
          }
        } else {
          SectionCard() {
            ForEach(['email_masked', 'display_name', 'account_label', 'bound', 'position_mode', 'permission', 'sync_error'], (key: string, index: number) => {
              if (!this.data.get(key).empty()) { Metric({ label: ['邮箱', '显示名称', '账户名称', '已绑定', '持仓模式', 'API 权限', '同步状态'][index], value: this.data.value(key) }) }
            })
          }
        }
        if (this.message) { Text(this.message).fontSize(13).fontColor(GOLD).width('100%') }
        if (this.kind !== 'capital') { ActionButton({ label: '刷新', secondary: true, interactive: !this.loading && !this.busy, action: () => { this.load(); } }) }
      }.padding(16).width('100%').constraintSize({ maxWidth: 600 })
    }.width('100%').height('100%').backgroundColor($r('app.color.page'))
  }
}
