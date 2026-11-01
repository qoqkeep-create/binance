# 原 Web 页面与原生 iOS 对照

本主题维护原 USDT Web 的原生业务页面复刻方式。SwiftUI 实现位于 `frontend/ios-app/TradeTool/Features/USDT/`；2026-11-01 按用户新要求，认证入口 `Features/Auth/LoginView.swift` 改为 USDC 原生布局和底部 sheet，名称与图标见 [品牌与认证](ios-authentication.md)。原项目来源及只读路径见 [来源索引](sources.md)，本地参考副本和截图不属于发布资源。

## 当前实现

业务页面以原 Web 的移动端 DOM、Tailwind 样式及实际截图为依据，使用原生组件实现。共享外观在 `USDTComponents.swift`；Lucide 图标复制原 Web 图标的 SVG 路径，由原生 Path 绘制，许可见 [Lucide ISC](licenses/Lucide-ISC.txt)，同一许可文件随 App 资源打包。原生系统 Form 和默认大标题已替换为对应的页面、字段、卡片、标签页与弹窗。

首个“行情”入口、行情列表及其 SwiftUI + Metal K 线继续使用 USDC 来源的原生实现。信号研究已按 2026-11-01 新要求移除，包含其独立的 Swift Charts 历史图表；退役与旧库兼容见 [研究退役](research.md)。

持仓、限价委托和历史仓位未绑定 API 时，统一显示“请先绑定 Binance API”的下划线链接及右向开口箭头，在页签下方可用内容区水平、垂直居中，最小点击高度 44 pt；点击以原位渐变打开已有 API 绑定界面。三个页签均停止列表请求，清空旧数据、分页、错误与加载状态，并拒绝旧请求晚到回写；历史页同时隐藏日期筛选。不展示后端长错误或“重新加载”按钮。三个页签的刷新直接挂在 ScrollView 上，空列表仍可下拉；刷新先读取绑定与账户，再从第一页更新当前列表。

2026-11-01 历史加载修复已配套部署到 47.80.22.243（首尔服务器），客户端待新包安装：绑定后的首次进入、筛选与第一页刷新先读取 `/v1/position/history?snapshot=local`，展示已有记录并结束首屏加载；按 `exchange_refresh_required` 决定是否继续普通查询，更新期间保留记录并显示轻量提示。没有普通活动仓位且无需修复结算时不额外补查，部分平仓记录和最终分页总数以补查响应为准；“加载更多”继续使用普通查询，补查期间暂不可点。更新失败保留本地记录并显示错误，可下拉重试；切页、筛选、解绑、取消和账户范围变化后，旧响应不能覆盖新页面。待结算、结算待重试和估算各自标记。接口的读取及结算边界见 [仓位历史读取](trading-safety.md#仓位历史读取)。

手动下拉先刷新账户再加载列表，使用独立读取任务，避免账户状态发布引起外层刷新任务取消后丢弃结果；在读取列表前再次核对账户范围、所选页签与筛选，列表请求仍遵守取消和代际校验。

“我的”顶部始终显示 48 × 48 pt 头像；未绑定时使用现有默认头像，右侧居右放浅红色“请先绑定 API”按钮（12 pt 字、高 34 pt、左右内边距 12 pt、圆角 8 pt），点击打开已有绑定界面。模式切换保留独立入口。

顶部资产卡按原 USDT `tools/src/pages/profile/index.tsx` 的配色：普通模式为左上至右下 `yellow-50`（`#FEFCE8`）→ `amber-50`（`#FFFBEB`）渐变，边框为 Tailwind 4 `yellow-200`（`#FFF085`），分隔线使用边框色的 50% 透明度。深色在当前页面底色上叠加品牌黄 `#F0B90B` 的 5%→10% 渐变，边框 20%、分隔线 10%，替代原先的灰色 surface / elevated 渐变。带单模式沿用原版对应蓝色：浅色 `#F0F9FF`→`#EFF6FF`、边框 `#B8E6FE`，深色使用品牌蓝 `#58B9EF` 的相同透明度。

“我的”页的退出登录为与内容区同宽的浅红底、红字按钮，最小高度 48 pt、圆角 10 pt，保留二次确认。

信号页只读取内部信号，页头统一为 18 pt 粗体“信号”，移除来源切换标签和黄色选中横线，保留规则说明按钮。账户资产卡移除“补资提醒”按钮，将“归集余额”移至原提醒按钮所在的下方位置；后端提醒能力及通知链路未改动。

后续新增的“我的 → 持仓浮窗”沿用这套菜单与主题，具体交互、刷新和生命周期见 [持仓浮窗](ios-floating-positions.md)。

| 原 Web 页面 / 组件 | 原生实现 | 对照范围 |
| --- | --- | --- |
| login、注册、找回密码 | `LoginView` | 已按新要求改为 USDC 原生布局与底部 sheet；保留整合后端协议、注册开关和重置参数，见 [品牌与认证](ios-authentication.md) |
| trading | `USDTTradeView` | 双卡片、报价、订单类型、止损、估算、手续费、策略入口、方向初筛、开仓确认 |
| holdings | `USDTPositionsView` / `USDTPositionControls` | 持仓、限价、历史、策略日志、保本损、手动止盈、追单及平仓确认 |
| profile | `USDTProfileView` | 资产、API、模式、归集入口、菜单 |
| StopLossSettingsModal | `USDTStopLossView` | 底部浮层、比例、公式、金额分档取整、当前值、待生效和确认状态 |
| 资金预检 / 归集 / 提醒 | `USDTCapitalView` 等 | 源固定深色弹窗、资金分项、只补资金、阻断状态及确认 |
| strategy | `USDTStrategiesView` / `USDTStrategyEditor` | 默认选择、层级、减仓、移动止损、R 说明及固定底部保存 |
| signals / SignalRulesModal | `USDTSignalsView` | 统一页头、仅内部信号卡和完整规则说明 |
| transfer-history / operation-logs | `USDTRecordsView` | 统计、筛选、日期、状态及列表 |
| settings / legal | `USDTSettingsView` / `USDTLegalView` | 主题、权限区域、退出、协议及隐私文本 |
| BottomNav | `BottomNavigationBar` | 保留首个行情项，其余业务入口采用原 Web 图标与尺寸 |

## 自选与交易对底部列表（2026-11-01）

行情搜索、编辑自选底部“添加自选”、开仓交易对下拉共用 `MarketSearchView`，使用 Apple 原生 `sheet` 与单一 `.fraction(0.85)` detent，和用户协议／隐私政策共用高度修饰器。标题“交易对”、搜索及 X 关闭位于同一面板，输入在本地过滤服务器目录；目录五分钟内复用，失败保留上次内容，首次失败可重试。范围为当前平台支持的 USDT 永续合约，目录存储与接口见 [行情](market-data.md#交易对目录与开仓报价2026-11-01)。

列表以同一个 `DashboardViewModel` 的 `isVisible` 判断自选：已自选名称加粗、右侧删除；未自选普通字重、右侧＋。行情和编辑入口点击名称或右侧按钮管理自选；删除使用系统二次确认。开仓入口点击名称选择交易对并关闭，右侧按钮仍管理自选。三个入口不创建各自的选择状态。

编辑页只列自选项，移除选择框、全选、群组、批量移除和固顶；列名改为“交易对／删除／移到顶部／拖动”，底部为全宽“添加自选”。排序使用系统 `List`、`ForEach.onMove` 和激活的 `EditMode`，由原生手柄完成拖动。顺序和自选按用户持久化；兼容读取旧偏好，但忽略并清空旧固顶集合。

开仓顶部显示“开仓”，交易对以 17 pt 字体放在市价／限价同一行。止损额直接读取常驻 `USDTStore.account`，进入页面可后台核对；相同账户数据不重复发布、不清空旧值。调整止损与“我的”均原生呈现同一个 `USDTStopLossView`。选中交易对加入常驻 WSS ticker 订阅，切换标签不重建报价状态，移除原先每三秒 `/v1/trade/symbol/info` 轮询；重连／行情刷新仍使用既有服务器 ticker 快照。

用户协议和隐私政策移除独立标题条与“完成”，标题和 X 位于正文同一表面，原生面板关闭后回到原注册表单。模拟器验证和手机待验范围见 [开发](development.md#自选与共用交易对回归2026-11-01)。

## 尺寸与外观口径

在相同逻辑宽度下，CSS px 对应 iOS pt；截图中的物理像素随设备倍率变化。iOS 使用自己的安全区，不重复加入 Web 的状态栏占位。普通业务容器最大宽度 448、左右间距 16；常用字段高 48、标签页高 44。尺寸允许具体页面按源覆盖，不能用一个通用卡片替代全部布局。

| Token | 浅色 | 深色 |
| --- | --- | --- |
| 页面 | `#F5F5F5` | `#212731` |
| 卡片 | `#FFFFFF` | `#272F3A` |
| 输入 | `#F3F4F6` | `#212731` |
| 边线 | `#E5E7EB` | `#333B47` |
| 正文 | `#111827` | `#EAECEF` |
| 次级文字 | `#4B5563` | `#848E9C` |
| 品牌 / 盈利 / 亏损 | `#F0B90B` / `#0ECB81` / `#F6465D` | 同左 |

沿用来源实际圆角：4、8、10、14、16、24；常见弹窗最大宽 384、内边距 24、遮罩 60%。止损设置使用下文说明的原生底部面板；资金弹窗按各自来源布局实现。带单模式保留来源蓝色品牌；暗色页面与卡片按本轮用户要求统一 USDC 色板。

看盘计划、专用校准问答及手动开仓理由／指标校验已按新要求删除，移除范围与历史代码索引见 [功能退役](research.md)。SwiftUI 与浏览器的字体光栅化、系统日期控件、键盘及菜单呈现存在平台差别，截图回归不能等同于所有设备和所有动态状态的逐像素一致认证。

## 返回手势与弹窗（本地改动）

2026-11-01 按用户确认统一层级返回：每个 UINavigationController 共用一个公开 UIKit 交互转场与 Pan recognizer，左侧 50 pt 范围起手，按水平方向、距离和速度判断完成或取消。SwiftUI 原导航代理继续接收回调；根页面不触发返回。K 线图同步预留左侧 50 pt，时间轴横拖从该范围外起手，避免与返回争夺。横向表格在最左边界让出返回手势，已横向滚动时先恢复表格位置；输入框和滑杆避让。

覆盖列表设置、K 线、图表指标与下单设置，以及转账历史、设置、日志、策略列表与编辑、交易命令。二级页面通用标题栏的返回图标统一使用左向开口箭头（Lucide `chevron-left`），点击区 44 × 44 pt；行情的原生返回按钮同样使用 `chevron.left`。实际模拟器覆盖范围写入变更记录，不能以公共修饰器存在替代逐页真机验收。

公共 `webModal` 使用透明且禁用系统整体转场的容器。首次布局时按实际卡片高度选择动画：达到可用容器一半的大弹窗以 0.18 秒从下方滑入，较小弹窗以 0.16 秒原位淡入，关闭均为 0.14 秒；系统“减弱动态效果”开启时统一淡入淡出。绑定 API／API 管理窗口明确指定淡入淡出，无论表单高度、账户模式或键盘状态都不改为上滑。动画选择在本次展示内固定，键盘或内容变化不会切换动画类型。遮罩原位渐变，嵌套弹窗按底层已有遮罩补足透明度，避免重复叠黑。

大面板头部下拉时卡片位移和遮罩透明度同步，小弹窗下拉时原位淡出；未达到关闭条件则恢复。适用于资金、账户、交易确认、持仓操作和策略选择。注册／密码表单、图表、图表下单及策略管理大面板使用 `WebSheet`，保留拖动条与顶部圆角。导航子页右滑返回。

止损设置单独使用 Apple 原生 [`sheet`](https://developer.apple.com/documentation/swiftui/view/sheet(ispresented:ondismiss:content:))，由系统处理上滑转场、遮罩、下拉关闭和安全区；24 pt 顶角，单一 detent 最高 650 pt 并受当前窗口可用高度限制，辅助功能字号时使用完整可用高度。标题固定、表单滚动，底部“确定”放在 `safeAreaInset` 内保持位置稳定。比例滑杆改用原生 `Slider`，数据返回一次性无动画更新；倒计时只在存在待生效提示时用局部 `TimelineView` 更新。提交中禁止重复操作与关闭，二次确认仍使用原位淡入淡出。止损金额的 Decimal 算法与提交接口沿用既有实现。

大面板根页的返回按钮通过展示绑定执行关闭动画；嵌套导航子页继续使用导航返回，避免退出整个面板。认证下拉测试从实际面板头部起手，不依赖系统 sheet 的固定屏幕坐标。

暗色 Tab Bar 背景为 `#212731`，顶部资产卡使用上述 USDT 品牌色渐变，其余卡片与边线见上表。业务尺寸沿用既有复刻实现。

## 业务与测试边界

页面继续通过 `USDTStore` 使用既有 Python API、账户模式和持久化命令。方向初筛通过后的主按钮按源切换为市价/限价开多或开空，选择策略进入“我的策略”。资金整理预检判断 `normalization_required` 和有效计划，不能因归集金额为零而禁用仅补入资金的计划。止损预览使用 Decimal，原值小于 20 按 1、小于 100 按 5、其余按 10 向上取整，服务端仍为最终依据。

持仓弹窗携带所选持仓和动作，避免首次呈现旧数据。批量平仓逐笔复用已有 `position-close` 命令，在发送前保存当前账户范围的目标与幂等键；未知或非终态停止后续处理，并沿用原键核对。切换账户范围后停止该批处理。普通测试只检查入口和确认界面，不执行真实平仓；会话、绑定代际与服务端未知结果恢复仍遵守 [交易安全](trading-safety.md)。本轮没有修改 Python 交易规则。

重置密码支持解析已有 `reset_uid` / `reset_token` 参数；邮件 HTTPS 链接自动唤起 App 的 Universal Links 关联尚未专门配置和验收。SMTP 和通知真实发送仍遵守 [已知事项](known-issues.md)。

## 本地校对

`WebParityUITests` 位于 `TradeToolChartCalibrationUITests/ChartCalibrationUITests.swift`，使用 DEBUG 专属启动参数 `--web-parity-fixture <page>`。该 API 无网络 transport；只有资金预检与 EMA 初筛允许返回本地静态 POST 预览，其他写操作全部拒绝。采用独立 fixture 用户和会话空间，不读取生产账号或交易凭证，Release 不包含该入口。

提示条回归参数 `--fixture-toast` 在本地替身展示一条持续 30 秒的两行提示；正常运行继续使用原有 1.5 秒自动消失。刷新回归专用参数 `--fixture-refresh-lists` 使持仓、限价和历史各自首次读取为空、下拉后返回静态记录，用于验证三个空列表实际触发重新请求；不连接网络。

`--fixture-history-supplement-slow` 为已绑定历史页返回本地待结算记录，并将后续核对延迟 6 秒；`testBoundHistoryShowsRecordsWhileExchangeSupplementIsSlow` 检查核对期间能看到记录和状态，最终进度消失。`testAllUnboundPositionTabsOnlyShowBindingPrompt` 覆盖三个页签的居中绑定入口及表单打开。

附加状态参数为 `--fixture-dark`、`--fixture-lead`、`--fixture-empty`、`--fixture-unbound`、`--fixture-multiple`、`--fixture-capital-refill`。页面包括 `market`、`launch`、`trade`、`positions`、`signals`、`profile`、`strategies`、`strategy-editor`、`operations`、`transfers`、`settings`、`legal`、`privacy`、`binding`、`stop-loss`、`collect`、`capital`、`reminder`、`login`。行情延迟替身默认 86 ms（绿），`--fixture-latency-fair` 为 280 ms（黄），`--fixture-latency-slow` 为 780 ms（红）；`--fixture-latency-overflow` 模拟 1520 ms 并显示 999，`--fixture-latency-unavailable` / `--fixture-latency-measuring` 分别模拟不可用（红色 `-- ms`）与首次测量（`-- ms` 加小型圆形进度）。点击或下拉重测保留读数并显示进度，800 ms 后恢复固定 86 ms，`--fixture-latency-refresh-slow` 将此过程延长至 6 秒，覆盖 UI 自动化等待下拉回弹的时间，只用于校对中间状态。这些 UI 替身不建立网络连接；实际探测口径见 [行情](market-data.md)。

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
