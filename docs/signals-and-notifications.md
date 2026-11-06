# 信号与通知

> 本文维护整合版沿用的业务规则；当前运行与验证边界见 [整合说明](INTEGRATION.md)。来源项目历史资料从 [来源索引](sources.md) 查询。

本主题维护数据流、模块隔离和消息口径；请求字段和响应协议以两份独立 [接入](api/external-signals.md) / [推送](api/trade-notifications.md) 文档为准。

投递语义核对日期：2026-11-06。普通自有信号及仓位事件的内部渠道统一走 App APNs，浮盈及保证金风险提醒走 Echobell；不再使用企微或 Echo 发送普通通知。外部 HTTP 信号接收默认暂停，旧外部 App 待发记录取消，历史记录保留。开平仓等仓位通知总开关继续关闭，未因本次路由调整恢复。App 注册和派发此前已限定发布并完成三条通知实机测试；2026-11-06 完整发布已启用原配置中的浮盈任务及独立保证金任务，部署范围见[运维](operations.md#完整同源发布2026-11-06)；自然阈值触发和手机送达仍待验。

## 保证金 Echobell 与 App 币种导航（2026-11-06，本地）

保证金风险由 [margin_alerts.py](../server/positions/margin_alerts.py) 独立只读任务每 10 秒检查；读取／发送耗时和预算等待另计，不承诺强平前一定送达。仅检查 `POSITION_PROFIT_CALL_USER_ID` 指定的有效用户，复用已有受限 Echobell 通道，不广播其他账号。`POSITION_MARGIN_CALL_ENABLED` 默认 true，独立于浮盈开关；默认接收用户 0 时不读取账户、不投递。普通／带单分别按当前有效绑定取新鲜账户快照，支持范围与风险公式沿用 [保证金接口](capital-and-transfers.md#持仓页保证金率2026-11-05本地实现)，不依赖 App 打开或 HTTP 页面轮询。

精确 Decimal 比例严格 **> 75%** 且真实有仓才创建事件，75% 本身不触发；非正权益且仍需维持保证金视为已达强平线。通知说明这是账户全仓池风险，并列出同一池的持仓币种，不将多币种账户比例冒充单币风险。`PositionMarginWatch` 按用户／模式／绑定 ID、指纹和创建代际的摘要持久化超限状态；`PositionMarginAlert` 保存事件载荷及独立发送状态。同一持续超限只尝试一次，确认回落到 ≤75% 或空仓后重新武装；读取失败、不支持模式、旧快照不重置状态。发送前复核有效绑定、快照最多 20 秒，用户行锁串行领取，网络在事务锁外。与浮盈共用 60 秒通道冷却；拒绝记 failed、超时或中断记 unknown，同一事件不自动重拨。新绑定独立状态，旧绑定待发事件不能用于新账户。

App `trade.notification` 优先用结构化 `symbol` 打开该 USDT 合约 K 线，保留普通／带单模式，未给周期默认 1h；缺少合法币种的旧通知回退持仓页。`strategy.signal` 沿用信号币种／周期直达。新仓位载荷包含 `recipientUserId`，当前登录用户不匹配则忽略；冷启动暂存点击直至会话恢复，退出登录或关闭通知清空。旧外部信号路由仍被拒绝；不恢复仓位通知总开关、不将 Echobell 通知转为 App APNs。

源码已推送 GitHub，并于 2026-11-06 随[完整同源发布](operations.md#完整同源发布2026-11-06)部署至 **47.80.22.243（首尔服务器）**。已应用 `positions.0029`／`0030` 的四张独立表，新 scheduler 已加载且保证金／浮盈开关为 true，受限接收人及通道已配置；没有发送测试通知。回滚代码保留新增表及已尝试事件。界面与导航需安装新客户端，自然超限、实际送达和冷启动点击待真机验收。验证范围见 [开发](development.md#账户入口与保证金通知2026-11-06本地)。

## 本地未读红点与外部接收暂停（2026-11-03）

iOS 信号底栏以红点提示未读。`USDTStore` 将最新消息 ID 与已读至 ID 按服务器地址／用户保存在本机 UserDefaults；重启可恢复，不新增服务端已读接口。进入信号页清除红点，页内新记录记已读，离开后出现新 ID 才重新提示。普通模式前台每 30 秒读取最新一条 `source=internal` 消息，信号页可见时复用原有列表读取；后台、带单停止探测。前台信号 APNs 到达触发校对，网络失败保留游标，取消或旧账户响应不得写回。

`EXTERNAL_SIGNAL_INGEST_ENABLED=false` 时，鉴权后的整个旧 HTTP ingest 入口返回 503，不保存消息、不转发、不生成 App 投递；请求自报 `source=internal` 也不能绕过。内部扫描直接事务入库，不使用此 HTTP 入口，继续正常保存和生成 App 信号通知。重新接入需显式开启配置，不删除外部历史或更换凭据。`enqueue_signal` 也拒绝非 internal 来源；旧 `reference.trade.notification` 或明确 external／tradingview 来源的 App 队列在领取前取消，不消耗发送尝试、不回退 Echobell。iOS 对旧外部路由以及 external／tradingview／tv 来源载荷不展示前台通知、不处理点击导航。

## 普通通知真机测试（2026-11-03）

用户要求发送三条普通信号测试通知。15:22（北京时间）已在 **47.80.22.243（首尔服务器）** 补齐鉴权设备注册／注销、登出停用、HTTP/2 依赖、p8 只读挂载及每 10 秒的 App 通知派发；旧的两条 Echo 信号待发记录已取消、尝试次数为 0。版本、备份和回滚见 [运维](operations.md#app-普通信号通知限定发布2026-11-03)。浮盈扫描和 Echobell 派发未随本包启用。

15:26 用户重新打开 App 并允许通知后，已注册一台 production 设备；15:27 仅给该用户设备创建三条独立测试通知事件／投递，标题为“普通信号通知测试 1/3～3/3”，间隔约 20 秒，使用 `strategy.signal` 路由。不伪造 `TradingViewMessage`、不写真实信号列表、不广播其他账号、不发送 Echobell。首轮三条均未获苹果接受，失败尝试分别为 4／3／2 次；针对一条投递采集的安全响应为 **HTTP 400 / `TopicDisallowed`**，先暂停测试重试。

Apple 开发者后台只读核对确认：首轮使用的生产 APNs 密钥为 Topic Specific，当时仅授权旧 App `com.oovso.trade`，没有整合版 `com.waibao2025.trade.integrated`。按电脑操作工具的权限确认要求，用户随后明确允许保留旧 topic 并新增整合 topic；15:42 已在 Apple 后台完成保存，页面确认密钥已更新、允许 **2 Topics / Production**，没有撤销旧 App 权限或更换 p8。Apple 对 [TopicDisallowed](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns) 的定义与首轮拒绝一致。

授权保存后使用原三条测试事件继续投递，均为 **HTTP 200／sent**，累计尝试为 5／4／3（包含此前苹果拒绝），最后错误清空、无待重试项；没有重复生成新测试事件。15:44（北京时间）用户明确确认 **“3 条都收到了”**，因此本次普通信号 App APNs 测试的服务端与手机送达均通过；不能据此推断自然信号触发、锁屏／声音全部场景、长稳或浮盈 Echo 已验收。

实测同时发现 httpx 默认 INFO 日志包含 APNs 请求路径。已在 `riskon.settings.LOGGING` 将 httpx／httpcore 传输日志改为 NullHandler、禁止传播，保留适配器的安全错误类型；17 项隔离回归及 47.80.22.243（首尔服务器）的运行配置核对通过。没有将设备 token、JWT、p8 或原始凭证写入文档。

## 回声铃单次通知测试（2026-11-03）

用户明确要求发送一次回声铃测试。15:48:26（北京时间）在 **47.80.22.243（首尔服务器）** 使用已配置的受限 Echobell 通道发送 **1 条**“回声铃通知测试”，接口返回 **HTTP 200／success=true**，现有适配器的 `notificationTriggered` 检查通过。用户随后明确确认 **“收到了”**，本次回声铃单次测试的接口与手机送达均通过；该结果不代替浮盈阈值监控／调度的验收。

本次仅单次调用现有 `profit_alerts.py` 的通道校验和发送函数，不加载仓位扫描模型、不启用定时浮盈任务、不部署或迁移、不创建虚假浮盈记录、不执行交易或资金动作。复用严格 HTTPS host／path 校验、禁止重定向及五秒超时；一次尝试后不自动重拨。发送前以排他创建方式写入尝试标记，脱敏结果保存在 `/opt/trade-tools-integrated/backups/echobell-test-20261103-074744/attempt.json`，本机证据在忽略目录 `.integration-runtime/EchobellTest/`，没有保存通道凭证或原始响应。普通自有信号仍固定走 App APNs，浮盈自动任务仍未上线。

## 内部信号恢复状态（2026-11-03）

2026-11-03 12:23（北京时间），**47.80.22.243（首尔服务器）** 已限定部署直接入库链路。旧扫描先检查通知入口 token，缺失时返回 `evaluated=0`，因此前端有读取接口也没有数据；现在计算／持久化不依赖旧通知入口。自然调度已完成 14 个币种 × 4 个周期共 56 项，`failed=0`，当轮真实触发数为 0；鉴权 `source=internal` GET 200、数据仍为空，没有插入样例消息或重放历史。真实触发后的生产保存及手机可见性仍待自然验收，不能把本次空结果写成已有信号到达。

用户于本日后续反馈信号页已出现一条真实信号；这是用户可见性反馈，未另行核对生产事件或后台通知送达。自有信号卡不展示评分。原生信号页首次进入立即读取，前台停留每 30 秒刷新已入库信号，可下拉手动刷新；切页／后台保留列表和滚动位置并暂停读取，返回时先呈现保留内容，再按上次读取的剩余间隔或立即核对，带单模式不启动此读取。账户 scope 变化清空旧列表，稳定信号 ID 避免整列表重新创建。该客户端改动尚未发布到 TestFlight。最初信号限定包仅应用 `mobile.0002` 和排队依赖；后续 App 注册／派发上线及手机待验状态以上方真机测试记录为准，浮盈外发仍未上线。原信号恢复版本、备份与回滚见 [运维](operations.md#信号入库与杠杆金额限定发布2026-11-03)，隔离入库／读取用例见 [开发](development.md#图表账户反馈回归2026-11-03)。

## 三条链路不要混淆

| 链路 | 数据源与去向 | 是否交易 |
| --- | --- | --- |
| 外部指标信号 | HTTP 接收默认暂停；已有历史保留，iOS 不展示该来源，旧外部 App 待发投递取消 | 否，不读取交易账户、不自动开平仓 |
| 内部指标信号 | 自有趋势扫描 -> 数据库 -> iOS 信号页与 App APNs | 扫描 / 通知本身不自动下单 |
| 五类仓位事件 | 真实交易状态 -> 通知事件 -> 所属用户 App 队列；当前总开关与合作方渠道均关闭 | 只通知既有事件，不因投递而再次交易 |

入站 `EXTERNAL_SIGNAL_API_KEY`、出站 `EXTERNAL_TRADE_SIGNAL_API_KEY`、内部服务 token 和 Binance Key 均不是同一凭证。完整入站链接属于敏感写入凭证，不能放公开日志。

## 外部信号翻译

来源解析器位于 USDT 原目录的 `docker/tradingview/app.py`（见 [来源索引](sources.md)，当前项目不包含该独立服务），持久化入口见 [trading/views.py](../server/trading/views.py)。接收非空 JSON 对象，大小最多 64KB；文本必须包装在 `message` 等字段中，不接受裸文本或顶层数组。

合作方不必改成固定内部字段。当前实现是有界的嵌套字段 / 别名识别与文本推断，不是调用 AI、也不是对任意语义保证准确。保留原始 JSON，输出统一格式和 `mapped` / `partial` / `unmapped` 状态；无法识别仍接收，拿真实脱敏样例再扩展独立映射。

上述翻译器仅为来源协议说明，整合版当前没有运行该独立服务，HTTP 接收也已默认暂停。历史设计为先入库再尽力转发；重启接入前应按当前 App 通知规则重新核对，不能恢复普通通知到企微／Echobell。未给事件 ID 时用原始请求字节的 SHA-256 去重，因此正文空格或键顺序变化也可能变成新事件。建议合作方提供带自身系统前缀的稳定 ID。

历史入站企微转发是尽力一次，没有持久化失败重试队列；当前接收已暂停。`wecom_forwarded=false` 不代表接收失败，重发同一 ID 也不会补发。这与五类交易通知的持久化投递不能混为一谈。

## 内部信号和保留期

[trend.py](../server/market_analysis/trend.py) 每 60 秒扫描已收盘 K 线，周期为 15m / 1h / 4h / 1d，按交易对、周期、收盘时间避免重复信号。SuperTrend 方向翻转只静默建立对应方向的等待状态，不入库、不推送；后续已收盘 K 线满足原有 EMA 过滤、K 线方向及 EMA55 / EMA144 触碰条件时才提醒。EMA55 与 EMA144 仍分别消耗等待状态；同一根 K 线同时触发时合并为一条提醒。原生 [信号页面](../frontend/ios-app/TradeTool/Features/USDT/USDTRecordsViews.swift) 在普通模式提供入口，统一标题为“信号”，仅请求 `source=internal`，不再显示来源页签；规则说明保留。外部入站接口代码保留，但按本轮独立开关暂停接收。

`TradingViewMessage` 为历史模型名，实际有 external / internal / tradingview 来源；旧 tradingview 数据不能自动归成 external。统一消息按 3 天保留、每 10 分钟清理，不是长期信号档案。清理后仅依赖该表的去重记录也不再永久存在，合作方应避免任意重放历史。

## iOS 信号 App 通知（2026-11-03，源码规则）

已复现无旧 `MARKET_ANALYSIS_ALERT_URL/TOKEN` 时扫描整轮退出的问题。现在内部扫描直接在同一事务中保存 `source=internal` 消息及 `mobile.NotificationEvent`／`NotificationDelivery`，不再经过旧 webhook。稳定事件键为 `trend:{symbol}:{interval}:{closeMs}`；入库或排队失败不推进扫描标记，下轮可重试。规则本身不变，只记录最后一根已收盘 K 线的真实触发，不补造历史信号。关闭外发仍可保存并读取信号。

登录后的根界面激活原生通知管理器；设备通过 JWT 鉴权的 `POST /api/push/devices/register`／`unregister` 注册或注销，字段为 `installationId`（UUID）、`deviceToken`（十六进制）、`environment`（development／production）、`bundleIdentifier`。退出使用 `X-Push-Installation-ID` 仅停用本用户当前安装。绑定 token 的用户发生变化后，旧用户的待发消息取消。`strategy.signal` 载荷可由原生解析，点击打开同币种、同周期的标准 K 线。

调度器每 10 秒独立派发 App 信号通知，不在扫描或交易成功路径同步发送。内部信号仅生成 APNs 投递，不再根据旧 `SIGNAL_ECHOBELL_ENABLED` 生成 Echo 记录；该旧配置已退役。旧版队列中 pending／failed／租约过期的 Echo 信号记录在领取时取消，不外发、不改写历史成功记录。浮盈 Echo 使用下方独立链路，不受该取消规则影响。APNs 使用 HTTP/2、ES256 provider token、当前应用 topic 和 production／sandbox，60 秒租约、最多 8 次退避尝试；失效 token 停用，超过一小时的事件取消。中断的最后一次尝试收敛为 exhausted；稳定 `apns-id` 不等同于苹果端严格只投一次。浮盈 Echobell 的一次尝试及 unknown 规则见下节。异常只记录类型，不保存 token、完整 URL 或原始响应。

APNs 开关只对开启时新入队事件生成设备投递，关闭时仍保存信号及事件，不回退到 Echobell；不承诺开启后自动补发全部历史。设备注册成功、代码编译或前台 WSS 成功均不能代替后台系统通知验收。

## 设置中的通知开关（2026-11-04，本地）

iOS 设置新增“开启通知”，直接读写现有 `notificationsEnabled` 本机偏好（缺失时沿用默认开启），不新增一套通知开关。开启沿原通知管理器检查／申请系统权限和设备注册；关闭取消在途授权及重试，调用原设备注销并清理已送达通知，前台展示回调也检查开关。权限请求返回或重试等待结束后再次核对取消、会话与偏好，避免关闭后又注册。系统权限与本机偏好分开：用户拒绝时显示“系统通知权限未开启”及前往系统设置入口，回前台重新检查，不能把切换成功显示成权限已获准。

此开关只管理 App 普通通知的注册和展示，不改变信号列表、本机未读游标、独立 live 或浮盈 Echobell 配置。注销是网络操作，在完成前系统后台通知仍可能有在途投递，关闭不等于撤回已送往 APNs 的请求。信号红点直径由 8 增至 16 pt，已读规则不变。本轮仅本地替身与编译，系统权限、注销实际送达边界及新包待真机验收；没有发送测试通知。

## ActivityKit live 持仓卡片（2026-11-03，源码实现）

live 是用户主动开启的锁屏／灵动岛持仓展示，与普通信号 APNs、仓位事件和浮盈 Echobell 各自独立。客户端在前台创建活动后，用 JWT 鉴权的 `POST /api/push/live-activities/register` 注册每活动 token；注销使用同前缀的 `/unregister`。注册按安装 ID 保留当前活动，校验所属用户、普通／带单模式、有效 API 绑定代际和开始时间；token 轮换有独立时间序，旧活动、旧 token 或旧账户请求不能覆盖新注册。设备普通通知 token 不用于 live，普通通知权限或 APNs 测试成功不等于实时活动已可更新。

`mobile.LiveActivityRegistration` 与 `mobile/live_activities.py` 独立维护注册、45 秒租约、投递结果及结束状态，通过 `mobile.0003_liveactivityregistration` 新增表。scheduler 每 15 秒检查到期注册，频繁更新权限开启时成功投递后的目标间隔为 15 秒，关闭时为 60 秒；APNs 使用 `liveactivity` push type、`bundle ID + .push-type.liveactivity` topic 及静默优先级 5，不附声音或 alert，不生成普通通知或 Echobell。发送在数据库锁外执行，token／账户变更以 fence 阻止旧投递结果写回；失败退避，连续八次失败或活动 token 永久失效后停用。苹果的预算、合并和网络状况仍可能延迟或丢失更新，这些间隔不代表锁屏实时刷新保证。

后台只读当前身份的交易所持仓缓存或 GET 仓位接口，以 Decimal 格式化浮盈，最多四行并保留总持仓数；不调用仓位对账、交易执行、保护单维护或绑定健康写入。普通／带单按各自用户、绑定 ID、API 指纹与绑定创建时间隔离；同一轮相同账户复用读取。读取后再次核对绑定，失效／解绑／用户停用或注册到期时发送结束状态；注销和登出仅标记结束投递，不与交易成功路径同步发送。

每份载荷含 Unix `updatedAt` 和 90 秒 `stale-date`；读取失败立即使用“更新延迟”和无效时间戳，Widget 同时检查系统过期标记和快照时间，以 `--` 隐藏旧盈亏。活动最长 8 小时，开始时间不被注册重试或 token 轮换延长，过期需用户重新开启。客户端退出、切模式或账户／绑定范围变化会结束旧活动；系统生命周期与 Widget 外观见 [持仓浮窗](ios-floating-positions.md#activitykit-live-持仓卡片2026-11-03源码实现)。

新开关 `LIVE_ACTIVITIES_ENABLED` 在源码和模板均默认 false，注册与派发另需 `APNS_ENABLED=true`；不受仓位事件总开关控制，也不启用外部信号或浮盈呼叫。2026-11-03 22:49 已在 **47.80.22.243（首尔服务器）** 核验独立注册表、API／scheduler 及 live 开关 true，普通 APNs 保持 true、原三个暂停设置仍为 false；当前注册为 0，没有发送真实 live 通知。版本和验收见 [运维](operations.md#live-后台持仓卡片限定发布2026-11-03)，参数见 [配置](configuration.md#activitykit-live-持仓卡片)。本轮新包未上传，正式签名包的锁屏／灵动岛、Home 后投递、权限、token 轮换、90 秒过期与 8 小时生命周期仍待真机验收；此前三条普通通知和一次 Echo 测试不覆盖 live。

## 浮盈 Webhook（沿用原 USDT）

已按用户要求从原 USDT Git 基线 `c299f58` 移植 `positions/profit_alerts.py` 及回归。阈值为 **1R、1.5R、2R、3R、4R、5R、6R、7R、8R**，R 固定为首次观察时的止损额；浮盈取当前交易所仓位，不从客户端显示值推算。仅监控配置用户、当前绑定代际的普通／带单有效仓位，同币种同向本地重复订单不猜测归属；读取失败不关闭现有仓位或取消已有保护。

每仓位每阈值持久化去重，配置用户跨仓位与模式共用至少 60 秒间隔；真正发送前再读实时浮盈，因此已排队的阈值可能用回落后的当前浮盈播报，此行为保持原版。Echobell 返回拒绝为 failed，超时／中断为 unknown，均不自动重拨。发送使用严格限定的 Echobell HTTPS 地址，并禁止重定向；仓位扫描、通知投递均不执行开平仓、资金或保护单写操作。

配置入口和受限 p8 挂载见 [配置](configuration.md#ios-信号和浮盈通知)。2026-11-02 用户随后提供旧 Echobell 地址，已写入 47.80.22.243（首尔服务器）的 0600 环境文件，浮盈接收范围按整合库当前唯一有效绑定用户配置，不直接照搬旧库主键。APNs 复用原 iOS 项目的签名材料，已核对 P-256 密钥及与当前工程相同的团队；只读挂载源已准备为 UID 10001、目录 0700／文件 0400。仅保存配置，没有重启容器、部署通知源码、应用新迁移或真实外发，当前运行进程尚未加载这批参数；上线与手机验收仍待进行，操作备份见 [运维](operations.md#通知配置准备2026-11-02)。

## 仓位事件通知暂停（2026-11-03）

用户要求后台先关闭开仓、平仓等一系列通知。16:14（北京时间）已在 **47.80.22.243（首尔服务器）** 将 `TRADE_NOTIFICATION_ENABLED=false`、`EXTERNAL_TRADE_SIGNAL_ENABLED=false` 应用到 API／scheduler，覆盖普通／带单的开仓、止损、策略止盈、手动平仓／止盈和减仓，以及内部通道和合作方转发。总开关源码默认 true 以兼容旧部署，整合环境模板显式 false。暂停期间仍保存仓位通知事件；两个 dispatcher 在读队列／领取前直接返回 0，直接发送入口也拒绝，不消耗尝试、不修改租约或重试时间。恢复前需评估积累的待发记录，不承诺只发送开启后的新事件。

本次线上以网络替身核对两个 dispatcher 及直接 sender 均无 HTTP 请求，队列前后相同：内部 4 条 exhausted、外部 0 条，未重置或删除。普通自有信号的 App APNs 保持开启；浮盈 Echo 配置不变，自动任务仍未上线。交易执行、保护及结算逻辑无变化，没有执行真实交易或资金动作。限定发布、配置备份和回滚边界见 [运维](operations.md#仓位事件通知关闭2026-11-03)，39 项隔离回归见 [开发](development.md#仓位通知暂停回归2026-11-03)。

## 五类通知口径

带单订单仍走同一事件和渠道投递逻辑；标题增加 `【带单】`，正文首行增加 `交易账户：带单组合`，平仓归因升级和最终渲染保留标识。普通订单格式不变，JSON 顶层协议不变，不能通过消息发送驱动另一模式交易。

所有消息标题为“类型图标 + 货币对 + 多单 / 空单 + 动作”。标题和正文共享 [notifications.py](../server/positions/notifications.py) 的格式化逻辑，不分别维护 App 版和合作方版交易计算。

| 事件 | 标题动作 | 正文必备业务项，所有类型均含币种和订单方向 |
| --- | --- | --- |
| `OPEN` | 开仓 | 止损价、真实成交价、成交时间；有本地订单编号时显示编号 |
| `STOP_LOSS` | 止损 | 开仓价、止损价、止损时间、止损盈亏比 |
| `STRATEGY_TAKE_PROFIT` | 止盈 | 止盈价、止盈盈亏比、止盈时间 |
| `MANUAL_TAKE_PROFIT` | 手动止盈 | 止盈价、止盈盈亏比、止盈时间 |
| `REDUCTION` | 减仓 | 减仓百分比、减仓价格、减仓时间、浮盈减仓 / 浮亏减仓 |

盈亏比按净盈亏 / 止损金额，不是行情涨跌百分比。关闭事件等待结算达到终态，估算终态会附加明确的结算说明；不要为了极简模板删掉估算提示。方向采用实际订单方向，不从盈亏正负推断。正式字段样例及各类型图标见 [合作方协议](api/trade-notifications.md)。

## 低耦合投递与移除

`TradeNotificationEvent` 保存通用事件及向 App 队列移交的状态；[external_trade_signals.py](../server/positions/external_trade_signals.py) 使用 `ExternalTradeSignalDelivery` 独立投递给另一台服务器。两个适配器消费同一份 `eventId / type / title / content / occurredAt` 载荷，调度任务派发，网络请求在短事务领取之后、数据库锁之外执行。

两类投递均有租约恢复、尝试次数和下次重试时间；租约 60 秒，最多尝试 8 次，耗尽后停止自动尝试并触发带冷却的运维告警。内部适配器按稳定 `eventId` 幂等创建 `mobile.NotificationEvent`，只给订单所属用户当前有效 App 设备生成投递；源事件 `sent` 表示已移交 App 队列，不等于苹果或手机已收到。实际状态以 `NotificationDelivery` 为准；没有有效设备不会广播给其他用户，也不自动补历史。外部服务器协议保留且独立开关关闭，恢复前仍需评估幂等与积压。

仓位事件总开关 `TRADE_NOTIFICATION_ENABLED` 同时拦截源事件、已移交的 `trade.notification` App 投递及合作方发送，关闭后不领取或消耗尝试，保留状态、重试时间与租约；事件与外部投递意图仍可保存。外部独立开关 `EXTERNAL_TRADE_SIGNAL_ENABLED` 同时控制该渠道入队和派发。关闭不删除历史记录，重新开启可能发送已有待投递事件，不承诺自动补发所有历史交易。暂停 / 移除前应核对 pending / sending / exhausted 状态和接收方期望。

当前外部服务器渠道保持关闭；未来移除时再删除渠道适配、调度调用及相应配置，保留核心交易与 App 事件，投递审计数据按单独保留策略处理。不要为移除渠道改动开平仓、止损或结算算法。

## 模板测试

命令 [send_trade_notification_templates](../server/positions/management/commands/send_trade_notification_templates.py) 面向 App 队列，要求显式 `--user-id`，避免广播；[send_external_trade_notification_templates](../server/positions/management/commands/send_external_trade_notification_templates.py) 仍为已暂停的合作方渠道工具；通过各自 `--help` 确认参数，显式 `--confirm` 才发送。

模板覆盖五种类型，标题有测试标记，内容不对应真实交易。它们仍会发送真实外部消息，仅在任务明确要求时执行；默认验证应使用 [单测](../server/positions/test_notifications.py) 和 webhook 测试，不重复通知用户。
