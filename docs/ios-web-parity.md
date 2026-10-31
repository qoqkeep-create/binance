# 原 Web 页面与原生 iOS 对照

本主题维护原 USDT Web 的原生复刻方式。SwiftUI 实现位于 `frontend/ios-app/TradeTool/Features/USDT/`，认证入口在 `Features/Auth/LoginView.swift`。原项目来源及只读路径见 [来源索引](sources.md)，本地参考副本和截图不属于发布资源。

## 当前实现

业务页面以原 Web 的移动端 DOM、Tailwind 样式及实际截图为依据，使用原生组件实现。共享外观在 `USDTComponents.swift`；Lucide 图标复制原 Web 图标的 SVG 路径，由原生 Path 绘制，许可见 [Lucide ISC](licenses/Lucide-ISC.txt)，同一许可文件随 App 资源打包。原生系统 Form 和默认大标题已替换为对应的页面、字段、卡片、标签页与弹窗。

首个“行情”入口、行情列表及其 SwiftUI + Metal K 线继续使用 USDC 来源的原生实现。信号研究页的历史蜡烛图则使用 Swift Charts 绘制，包含 EMA21/55/144、SuperTrend 和信号位置，独立请求研究图表接口。两种图表用途不同。

| 原 Web 页面 / 组件 | 原生实现 | 对照范围 |
| --- | --- | --- |
| login、注册、找回密码 | `LoginView` | RISKON 标志、标题、字段、复选框、登录卡、注册关闭状态、重置密码参数 |
| trading | `USDTTradeView` | 双卡片、报价、订单类型、止损、估算、手续费、策略入口、方向初筛、开仓确认 |
| holdings | `USDTPositionsView` / `USDTPositionControls` | 持仓、限价、历史、策略日志、保本损、手动止盈、追单及平仓确认 |
| profile | `USDTProfileView` | 资产、API、模式、归集及补资入口、菜单 |
| StopLossSettingsModal | `USDTStopLossView` | 底部浮层、比例、公式、金额分档取整、当前值、待生效和确认状态 |
| 资金预检 / 归集 / 提醒 | `USDTCapitalView` 等 | 源固定深色弹窗、资金分项、只补资金、阻断状态及确认 |
| strategy | `USDTStrategiesView` / `USDTStrategyEditor` | 默认选择、层级、减仓、移动止损、R 说明及固定底部保存 |
| signals / SignalRulesModal | `USDTSignalsView` | 内外部标签、信号卡和完整规则说明 |
| transfer-history / operation-logs | `USDTRecordsView` | 统计、筛选、日期、状态及列表 |
| indicator | `USDTIndicatorsView` | 本地指标列表、名称、条件、编辑及固定底部操作；数据按账户隔离 |
| watch-plan | `USDTWatchPlansView` / `USDTWatchEditor` | 横向表格、筛选、写计划、复盘、结果金额、评分与固定评分区 |
| preflight | `USDTPreflightView` | 题库、随机题、倒计时、通过及过期流程 |
| signal-research | `USDTResearchView` | 样本录入、分析特征、模型选择、AI 请求预览、策略与回测、研究蜡烛图 |
| settings / legal | `USDTSettingsView` / `USDTLegalView` | 主题、权限区域、退出、协议及隐私文本 |
| BottomNav | `BottomNavigationBar` | 保留首个行情项，其余业务入口采用原 Web 图标与尺寸 |

## 尺寸与外观口径

在相同逻辑宽度下，CSS px 对应 iOS pt；截图中的物理像素随设备倍率变化。iOS 使用自己的安全区，不重复加入 Web 的状态栏占位。普通业务容器最大宽度 448、左右间距 16；常用字段高 48、标签页高 44。尺寸允许具体页面按源覆盖，不能用一个通用卡片替代全部布局。

| Token | 浅色 | 深色 |
| --- | --- | --- |
| 页面 | `#F5F5F5` | `#0B0E11` |
| 卡片 | `#FFFFFF` | `#1A1D23` |
| 输入 | `#F3F4F6` | `#0B0E11` |
| 边线 | `#E5E7EB` | `#2B2F36` |
| 正文 | `#111827` | `#FFFFFF` |
| 次级文字 | `#4B5563` | `#9CA3AF` |
| 品牌 / 盈利 / 亏损 | `#F0B90B` / `#0ECB81` / `#F6465D` | 同左 |

沿用来源实际圆角：4、8、10、14、16、24；常见弹窗最大宽 384、内边距 24、遮罩 60%。止损浮层使用 45% 遮罩和底部 8 加安全区；研究弹窗、评分及资金弹窗按各自来源布局实现。带单模式保留来源蓝色品牌和独立背景。

原 Web 看盘计划的写计划弹窗在 402 宽度仍采用十二列头部，控件会拥挤或重叠；本轮按来源保留这一布局，没有擅自改为另一套纵向表单。SwiftUI 与浏览器的字体光栅化、系统日期控件、键盘及菜单呈现存在平台差别，截图回归不能等同于所有设备和所有动态状态的逐像素一致认证。

## 业务与测试边界

页面继续通过 `USDTStore` 使用既有 Python API、账户模式和持久化命令。方向初筛通过后的主按钮按源切换为市价/限价开多或开空，选择策略进入“我的策略”。资金整理预检判断 `normalization_required` 和有效计划，不能因归集金额为零而禁用仅补入资金的计划。止损预览使用 Decimal，原值小于 20 按 1、小于 100 按 5、其余按 10 向上取整，服务端仍为最终依据。

持仓弹窗携带所选持仓和动作，避免首次呈现旧数据。批量平仓逐笔复用已有 `position-close` 命令，在发送前保存当前账户范围的目标与幂等键；未知或非终态停止后续处理，并沿用原键核对。切换账户范围后停止该批处理。普通测试只检查入口和确认界面，不执行真实平仓；会话、绑定代际与服务端未知结果恢复仍遵守 [交易安全](trading-safety.md)。本轮没有修改 Python 交易规则。

重置密码支持解析已有 `reset_uid` / `reset_token` 参数；邮件 HTTPS 链接自动唤起 App 的 Universal Links 关联尚未专门配置和验收。SMTP、AI 和通知真实发送仍遵守 [已知事项](known-issues.md)。

## 本地校对

`WebParityUITests` 位于 `TradeToolChartCalibrationUITests/ChartCalibrationUITests.swift`，使用 DEBUG 专属启动参数 `--web-parity-fixture <page>`。该 API 无网络 transport；只有资金预检与 EMA 初筛允许返回本地静态 POST 预览，其他写操作全部拒绝。采用独立 fixture 用户和会话空间，不读取生产账号或交易凭证，Release 不包含该入口。

附加状态参数为 `--fixture-dark`、`--fixture-lead`、`--fixture-empty`、`--fixture-unbound`、`--fixture-multiple`、`--fixture-capital-refill`。页面包括 `trade`、`positions`、`signals`、`profile`、`strategies`、`strategy-editor`、`operations`、`transfers`、`watch`、`watch-editor`、`watch-score`、`watch-review`、`watch-result`、`research`、`research-analysis`、`research-rules`、`research-backtest`、`settings`、`legal`、`privacy`、`binding`、`stop-loss`、`collect`、`capital`、`reminder`、`indicators`、`preflight`、`login`。

```bash
xcodebuild -project frontend/ios-app/TradeTool.xcodeproj \
  -scheme 'TradeTool Chart Calibration' -configuration Debug-Seoul \
  -destination 'platform=iOS Simulator,name=TradeTools Web Review' \
  -derivedDataPath .integration-runtime/WebParityBuild \
  -parallel-testing-enabled NO \
  -only-testing:TradeToolChartCalibrationUITests/WebParityUITests \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

XCTest 附件保留页面截图，必须实际打开检查。页面存在或按钮可点的断言不证明布局一致；同时对照同宽 Web、浅深色、空态、键盘及弹窗。实际构建、测试数量和验证日期见 [变更记录](changes.md)；真机、TestFlight、真实交易与所有像素精度仍应分别验收。
