# iOS 持仓浮窗与 live 卡片

## 使用与范围

在持仓页右上角点击“持仓浮窗”图标开启：前台先显示 App 内小卡片，并为系统画中画准备播放状态；点击 Home 或切至后台时自动请求外部画中画，前台开启时不立即弹出第二个窗口。也可点击卡片上的画中画图标手动开启。系统负责外部窗口的拖动、缩放、播放 / 暂停、关闭和返回 App；返回 App 后恢复内部卡片，下一次退后台仍可自动请求。保存的开关在下次启动时恢复内部显示与自动切换准备。再次点击入口、关闭内部浮窗或在系统窗口点击关闭即可停用。

2026-11-03 本地将入口统一到持仓页右上角的纯图标开关，移除“我的”中的重复菜单，点击区域 44 × 44 pt，无可见文字，辅助功能标注“持仓浮窗”和当前开关状态；与浮窗关闭按钮共用同一个偏好，不另建数据读取或画中画实例。顶部布局见 [页面对照](ios-web-parity.md#顶部选择器与时间筛选2026-11-03本地)。此入口尚待新包实机外观验收。

App 内卡片为 184 × 82 pt，显示交易对、方向、市价和浮盈；多笔持仓点击顶部切换，右侧显示序号。拖动边界保留 12 pt、底部预留 76 pt，避免覆盖导航，沿用浅色 / 深色主题。系统画中画使用 640 × 320 视频帧，采用固定深色以提高可读性，额外显示更新时间；多仓每 5 秒自动轮播。画中画的实际最小尺寸、位置与控制按钮由 iOS 决定，不能按 App 内尺寸强制设置，也不能在视频卡片内放置普通交互按钮。两种浮窗均不提供交易操作。

2026-11-03 本地将画中画源视图与内部卡片一起在外部窗口有效播放时隐藏，避免 App 中残留“此视频正在以画中画播放”字样；源图层保持挂载，供 AVKit 继续播放。自动启动使用 `canStartPictureInPictureAutomaticallyFromInline` 并在后台阶段请求启动，仍由设备支持和系统设置决定是否允许。这次自动切换及 placeholder 隐藏均仅为源码实现，真机待验。

设备明确不支持、音频会话不可用或启动超时会提示原因，并保留 App 内浮窗；不会把 App 内显示冒充跨 App 成功。App 内系统弹窗、sheet 和全屏呈现在普通浮窗上方。

入口与 App 内卡片位于 `FloatingPositionsView.swift`，由 `MainAppView` 的 NavigationStack 外层挂载；`FloatingPositionsPiP.swift` 独立负责 AVKit 控制器、线程安全的播放状态、像素缓冲渲染和系统回调。使用公开的 [sample-buffer PiP 接口](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/contentsource-swift.class/init%28samplebufferdisplaylayer%3Aplaybackdelegate%3A%29)及 [PiP 所需背景配置](https://developer.apple.com/documentation/avfoundation/configuring-your-app-for-media-playback)，`Info.plist` 配置 `UIBackgroundModes = [audio]`；用户开启内部浮窗后，为自动画中画激活音频会话，与其他音频混音，停用时释放，不播放静音音轨，不申请麦克风、摄像头或通话权限。

## 数据和生命周期

- `USDTStore` 持有共用的只读 `FloatingPositionsModel` 仓位快照与 `PositionLiveQuotes`，持仓卡片、App 内浮窗及画中画读取同一批数量／均价与同一份 ticker。App 内前台开启浮窗，或画中画正在启动／有效播放时，每次 `GET /v1/position/list` 完成后等待 3 秒校对仓位事实；账户事件可提前刷新。持仓页也复用该快照，所有消费者 join 模型持有的独立读取 Task，同账户最多一个请求在途；关闭浮窗或离开某页面不会取消其他消费者仍需要的读取。
- App 内与画中画的市价／浮盈通过实际 `PositionLiveValuation` 统一：多仓 `(ticker 最新成交价 − 开仓均价) × 剩余数量`，空仓反向；优先 `exchange_size`，只有旧接口缺字段才回退 `size`，不乘杠杆、不含手续费／资金费／已实现收益。服务端 `pnl` 优先是交易所 upl，旧浮窗直接显示它而持仓卡片按 ticker 计算，导致同一行可显示 19.5 与 20；本轮已在真实模型对照中复现并统一。浮窗不再读取 REST 的 `pnl/current_price` 作为报价估值兜底，缺 ticker／有效数量时显示 `--`。
- ticker 逐事件刷新估值并立即通知 PiP，不再等待下一轮 3 秒仓位读取。持仓页与浮窗拥有独立的报价消费 session 和订阅 owner，Dashboard 对币种取并集；退出持仓页不撤掉画中画所需订阅。相同事件去重，旧 session、乱序、跨 scope 及过期事件拒绝；Store 转发子模型发布，嵌套共享状态能实际驱动 SwiftUI 更新。
- 金额继续使用 Decimal 和 [统一数字显示](ios-web-parity.md#统一数字显示2026-11-02)，App 内／画中画复用相同格式。读取失败保留同账户最后仓位事实，显示失败状态，不把失败当成平仓或刷新成功；成功空列表才清空持仓。切换账户／模式／绑定代际、解绑或离开登录态会 reset、取消共享 Task 并清空报价，旧响应不能回写。UserDefaults 只存开关与拖动位置，不存仓位、报价、盈亏或凭证。
- PiP 每个 ticker 变化立即提交当前画面，另用 common run-loop mode 的 1 Hz timer 处理轮播、过期和自动启动，App 内拖动不会暂停该 timer。显示图层暂不可接收时只保留最新待发送画面，由 `requestMediaDataWhenReady` 就绪后立即送出，避免直接丢帧或排队播放旧盈亏。此逻辑不增加视频帧率承诺；系统仍可挂起进程。
- 画中画按**当前展示币种**的 `quoteTime` 与仓位读取成功时间中较早者判断 12 秒过期；其他币种的新 tick 或新 REST 响应不能给旧行情续期。过期／暂停显示 `--` 和“更新延迟／已暂停”，更新时间来自真实估值时间。画中画关闭／暂停后停止后台轮询，返回 App 后恢复前台刷新；系统挂起期间网络和渲染均可能暂停，持续后台效果需 iPhone 验收。

## ActivityKit live 持仓卡片（2026-11-03，源码实现）

持仓页右上角在浮窗按钮左侧新增独立的 `live` 入口，使用心电波形图标与 9 pt 文字，点击区为 44 × 44 pt；开启或注册中显示进度，开启后使用模式品牌色，再次点击立即结束。它与 App 内／画中画的开关独立，不提供交易操作。首次开启读取当前模式的 `/v1/position/list` 快照，初始内容和服务端后续更新均使用 REST `pnl`（交易所 upl）投影，独立于 App／PiP 的 ticker 估值模型；缺少有效绑定、系统实时活动权限或签名推送环境时提示原因。

`PositionLiveActivity.swift` 管理活动和 token；共享数据结构位于 `frontend/ios-app/Shared/PositionLiveActivityAttributes.swift`；独立 `PositionLiveWidget` 扩展绘制锁屏卡片和灵动岛。锁屏最多显示四笔的币种、方向、浮盈浮亏及更新时间；灵动岛展开显示三笔，紧凑态显示首笔币种与盈亏，额外持仓用数量提示。采用固定深色背景、黄色品牌标识及红绿盈亏，金额继续用 Decimal 精度规则，财务内容标记 `privacySensitive`，实际隐藏由系统隐私设置决定。

活动从前台发起，使用每个活动独有的 `pushToken`，与普通通知设备 token 分开。App 向鉴权 `/api/push/live-activities/register` 注册安装 ID、活动 ID、token、签名环境、模式及开始／token 更新时间；token 轮换、系统频繁更新权限变化和回到前台会重新注册。后台由独立服务器 dispatcher 读取只读持仓快照并经 APNs 更新，客户端不依赖常驻前台轮询维持 live。投递优先级、调度、迁移与开关见 [通知](signals-and-notifications.md#activitykit-live-持仓卡片2026-11-03源码实现)及 [配置](configuration.md#activitykit-live-持仓卡片)。

每份快照设置 90 秒过期时间；Widget 同时检查系统 `isStale` 与 Unix 更新时间，过期、缺值或更新失败时以 `--` 和“更新延迟”代替旧盈亏。活动最长 8 小时，之后需重新开启。恢复仅选择同服务器／用户／模式且仍有效的活动；切换账户、模式、绑定代际或退出主界面时结束旧活动，服务器另核对绑定 ID、指纹和创建时间，不能把旧身份数据更新到新活动。停止时本机立即结束并调用注销接口；服务器注销及登出通过独立结束投递收敛，不与交易写入绑定。

当前已接入客户端、Widget 与后台源码；`LIVE_ACTIVITIES_ENABLED` 默认 false。2026-11-03 22:49 已在 **47.80.22.243（首尔服务器）** 核验限定发布、独立注册表和开关 true，当前无活动注册，未发送真实 live 通知；版本与回退见 [运维](operations.md#live-后台持仓卡片限定发布2026-11-03)。源码已于前批 `8593267` 提交推送，本轮继续调整客户端；未手动上传 TestFlight。锁屏、灵动岛、Home 后系统更新、token 注册与轮换、权限关闭、过期、8 小时生命周期及切换账户仍需正式签名包真机验收；编译和隔离测试不能替代这些结果。

## 验证方式

`FloatingPositionsTests` 使用无网络 API 替身，覆盖 Decimal / 小币价、缺失值与负零、平仓后空列表、失败保留最后仓位事实／不续期、共享读取取消归属、旧账户响应、关闭后在途响应、并发请求去重和拖动边界；新增多仓轮播、暂停 / 过期不显示旧金额及真实 IOSurface 视频帧生成测试。

`PositionLiveActivityTests` 覆盖服务器 Unix 时间解码、90 秒过期边界、缺失盈亏、Decimal 精度、四行上限与总数保留、服务器／用户／模式身份隔离，以及首帧继续使用服务端盈亏投影。2026-11-03 最终 macOS host 包直接编译实际生产类型及测试，浮窗 21 项、ticker 估值 12 项、live 4 项合计 37 项全部通过；另覆盖独立 owner／session、共享读取等待和取消、多币种过期、PiP 帧背压只保留最新值。Release 与测试目标编译通过，没有启动模拟器、ActivityKit 或真实 APNs。复现、命令和边界见 [本轮验证](development.md#持仓交互弹窗与浮窗同步回归2026-11-03)，后端既有测试范围见 [通知](signals-and-notifications.md#activitykit-live-持仓卡片2026-11-03源码实现)。

`WebParityUITests` 的两项 App 内浮窗流程使用 [Web 原生复刻](ios-web-parity.md#本地校对) 的 DEBUG 隔离数据和 `--fixture-inline-floating`，验证多仓、跨页、拖动、关闭、空仓、未绑定和深色。`testFloatingPositionsPictureInPictureAcrossApps` 不加此参数，会实际请求 PiP，切到主屏和系统设置，等待后台刷新并返回关闭 / 重新开启。仅在设备明确报告不支持时跳过；一般启动失败仍是失败。`--fixture-live-floating` 让隔离快照中的测试价格随请求变化，用于判断是否在刷新，Release 不包含这些入口。

2026-11-01，本机 iPhone 18 Pro / iOS 27.2 模拟器返回画中画不受支持，不能在该环境证明跨 App 运行；本机没有可用于此验收的物理 iPhone。当前实现已经接入，真机跨 App、暂停 / 系统关闭 / 返回、重开、切换账户、长时间后台刷新与本次 TestFlight 构建仍待验收。手机安装新构建后，从持仓页右上角开启，切到其他 App 检查币种、盈亏和更新时间至少持续 1–5 分钟，再关闭并返回确认开关；不要通过真实开平仓来测试。实际构建与测试结果见 [变更记录](changes.md)。
