# 信号与通知

> 本文维护整合版沿用的业务规则；当前运行与验证边界见 [整合说明](INTEGRATION.md)。来源项目历史资料从 [来源索引](sources.md) 查询。

本主题维护数据流、模块隔离和消息口径；请求字段和响应协议以两份独立 [接入](api/external-signals.md) / [推送](api/trade-notifications.md) 文档为准。

投递语义核对日期：2026-11-03。普通自有信号只走 App APNs，只有浮盈提醒走 Echobell。App 注册和派发已限定发布，三条测试通知已获苹果接受且用户确认手机全部收到；浮盈自动任务仍未启用。

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
| 外部指标信号 | 合作方 JSON -> webhook 翻译 -> 数据库；新增消息尽力转发企业微信，当前 iOS 不展示该来源 | 否，不读取交易账户、不自动开平仓 |
| 内部指标信号 | 自有趋势扫描 -> 数据库 -> iOS 信号页与 App APNs | 扫描 / 通知本身不自动下单 |
| 五类仓位事件 | 真实交易状态 -> 通知事件 -> 企业微信等已配置通道 + 独立对方服务器投递 | 只通知既有事件，不因投递而再次交易 |

入站 `EXTERNAL_SIGNAL_API_KEY`、出站 `EXTERNAL_TRADE_SIGNAL_API_KEY`、内部服务 token 和 Binance Key 均不是同一凭证。完整入站链接属于敏感写入凭证，不能放公开日志。

## 外部信号翻译

来源解析器位于 USDT 原目录的 `docker/tradingview/app.py`（见 [来源索引](sources.md)，当前项目不包含该独立服务），持久化入口见 [trading/views.py](../server/trading/views.py)。接收非空 JSON 对象，大小最多 64KB；文本必须包装在 `message` 等字段中，不接受裸文本或顶层数组。

合作方不必改成固定内部字段。当前实现是有界的嵌套字段 / 别名识别与文本推断，不是调用 AI、也不是对任意语义保证准确。保留原始 JSON，输出统一格式和 `mapped` / `partial` / `unmapped` 状态；无法识别仍接收，拿真实脱敏样例再扩展独立映射。

消息先入库，再对新增事件转发企业微信；重复事件不重复展示，也不会重复发送企业微信。未给事件 ID 时用原始请求字节的 SHA-256 去重，因此正文空格或键顺序变化也可能变成新事件。建议合作方提供带自身系统前缀的稳定 ID。

入站企微转发是尽力一次，没有持久化失败重试队列。`wecom_forwarded=false` 不代表接收失败，重发同一 ID 也不会补发。这与五类交易通知的持久化投递不能混为一谈。

## 内部信号和保留期

[trend.py](../server/market_analysis/trend.py) 每 60 秒扫描已收盘 K 线，周期为 15m / 1h / 4h / 1d，按交易对、周期、收盘时间避免重复信号。SuperTrend 方向翻转只静默建立对应方向的等待状态，不入库、不推送；后续已收盘 K 线满足原有 EMA 过滤、K 线方向及 EMA55 / EMA144 触碰条件时才提醒。EMA55 与 EMA144 仍分别消耗等待状态；同一根 K 线同时触发时合并为一条提醒。原生 [信号页面](../frontend/ios-app/TradeTool/Features/USDT/USDTRecordsViews.swift) 在普通模式提供入口，统一标题为“信号”，仅请求 `source=internal`，不再显示来源页签；规则说明保留。此界面调整不移除外部入站接口和转发能力。

`TradingViewMessage` 为历史模型名，实际有 external / internal / tradingview 来源；旧 tradingview 数据不能自动归成 external。统一消息按 3 天保留、每 10 分钟清理，不是长期信号档案。清理后仅依赖该表的去重记录也不再永久存在，合作方应避免任意重放历史。

## iOS 信号 App 通知（2026-11-03，源码规则）

已复现无旧 `MARKET_ANALYSIS_ALERT_URL/TOKEN` 时扫描整轮退出的问题。现在内部扫描直接在同一事务中保存 `source=internal` 消息及 `mobile.NotificationEvent`／`NotificationDelivery`，不再经过旧 webhook。稳定事件键为 `trend:{symbol}:{interval}:{closeMs}`；入库或排队失败不推进扫描标记，下轮可重试。规则本身不变，只记录最后一根已收盘 K 线的真实触发，不补造历史信号。关闭外发仍可保存并读取信号。

登录后的根界面激活原生通知管理器；设备通过 JWT 鉴权的 `POST /api/push/devices/register`／`unregister` 注册或注销，字段为 `installationId`（UUID）、`deviceToken`（十六进制）、`environment`（development／production）、`bundleIdentifier`。退出使用 `X-Push-Installation-ID` 仅停用本用户当前安装。绑定 token 的用户发生变化后，旧用户的待发消息取消。`strategy.signal` 载荷可由原生解析，点击打开同币种、同周期的标准 K 线。

调度器每 10 秒独立派发 App 信号通知，不在扫描或交易成功路径同步发送。内部信号仅生成 APNs 投递，不再根据旧 `SIGNAL_ECHOBELL_ENABLED` 生成 Echo 记录；该旧配置已退役。旧版队列中 pending／failed／租约过期的 Echo 信号记录在领取时取消，不外发、不改写历史成功记录。浮盈 Echo 使用下方独立链路，不受该取消规则影响。APNs 使用 HTTP/2、ES256 provider token、当前应用 topic 和 production／sandbox，60 秒租约、最多 8 次退避尝试；失效 token 停用，超过一小时的事件取消。中断的最后一次尝试收敛为 exhausted；稳定 `apns-id` 不等同于苹果端严格只投一次。浮盈 Echobell 的一次尝试及 unknown 规则见下节。异常只记录类型，不保存 token、完整 URL 或原始响应。

APNs 开关只对开启时新入队事件生成设备投递，关闭时仍保存信号及事件，不回退到 Echobell；不承诺开启后自动补发全部历史。设备注册成功、代码编译或前台 WSS 成功均不能代替后台系统通知验收。

## 浮盈 Webhook（沿用原 USDT）

已按用户要求从原 USDT Git 基线 `c299f58` 移植 `positions/profit_alerts.py` 及回归。阈值为 **1R、1.5R、2R、3R、4R、5R、6R、7R、8R**，R 固定为首次观察时的止损额；浮盈取当前交易所仓位，不从客户端显示值推算。仅监控配置用户、当前绑定代际的普通／带单有效仓位，同币种同向本地重复订单不猜测归属；读取失败不关闭现有仓位或取消已有保护。

每仓位每阈值持久化去重，配置用户跨仓位与模式共用至少 60 秒间隔；真正发送前再读实时浮盈，因此已排队的阈值可能用回落后的当前浮盈播报，此行为保持原版。Echobell 返回拒绝为 failed，超时／中断为 unknown，均不自动重拨。发送使用严格限定的 Echobell HTTPS 地址，并禁止重定向；仓位扫描、通知投递均不执行开平仓、资金或保护单写操作。

配置入口和受限 p8 挂载见 [配置](configuration.md#ios-信号和浮盈通知)。2026-11-02 用户随后提供旧 Echobell 地址，已写入 47.80.22.243（首尔服务器）的 0600 环境文件，浮盈接收范围按整合库当前唯一有效绑定用户配置，不直接照搬旧库主键。APNs 复用原 iOS 项目的签名材料，已核对 P-256 密钥及与当前工程相同的团队；只读挂载源已准备为 UID 10001、目录 0700／文件 0400。仅保存配置，没有重启容器、部署通知源码、应用新迁移或真实外发，当前运行进程尚未加载这批参数；上线与手机验收仍待进行，操作备份见 [运维](operations.md#通知配置准备2026-11-02)。

## 仓位事件通知暂停（2026-11-03）

用户要求后台先关闭开仓、平仓等一系列通知。16:14（北京时间）已在 **47.80.22.243（首尔服务器）** 将 `TRADE_NOTIFICATION_ENABLED=false`、`EXTERNAL_TRADE_SIGNAL_ENABLED=false` 应用到 API／scheduler，覆盖普通／带单的开仓、止损、策略止盈、手动平仓／止盈和减仓，以及内部通道和合作方转发。总开关源码默认 true 以兼容旧部署，整合环境模板显式 false。暂停期间仍保存仓位通知事件；两个 dispatcher 在读队列／领取前直接返回 0，直接发送入口也拒绝，不消耗尝试、不修改租约或重试时间。恢复前需评估积累的待发记录，不承诺只发送开启后的新事件。

本次线上以网络替身核对两个 dispatcher 及直接 sender 均无 HTTP 请求，队列前后相同：内部 4 条 exhausted、外部 0 条，未重置或删除。普通自有信号的 App APNs 保持开启；浮盈 Echo 配置不变，自动任务仍未上线。交易执行、保护及结算逻辑无变化，没有执行真实交易或资金动作。限定发布、配置备份和回滚边界见 [运维](operations.md#仓位事件通知关闭2026-11-03)，39 项隔离回归见 [开发](development.md#仓位通知暂停回归2026-11-03)。

## 五类通知口径

带单订单仍走同一事件和渠道投递逻辑；标题增加 `【带单】`，正文首行增加 `交易账户：带单组合`，平仓归因升级和最终渲染保留标识。普通订单格式不变，JSON 顶层协议不变，不能通过消息发送驱动另一模式交易。

所有消息标题为“类型图标 + 货币对 + 多单 / 空单 + 动作”。标题和正文共享 [notifications.py](../server/positions/notifications.py) 的格式化逻辑，不分别维护企微版和合作方版交易计算。

| 事件 | 标题动作 | 正文必备业务项，所有类型均含币种和订单方向 |
| --- | --- | --- |
| `OPEN` | 开仓 | 止损价、真实成交价、成交时间；有本地订单编号时显示编号 |
| `STOP_LOSS` | 止损 | 开仓价、止损价、止损时间、止损盈亏比 |
| `STRATEGY_TAKE_PROFIT` | 止盈 | 止盈价、止盈盈亏比、止盈时间 |
| `MANUAL_TAKE_PROFIT` | 手动止盈 | 止盈价、止盈盈亏比、止盈时间 |
| `REDUCTION` | 减仓 | 减仓百分比、减仓价格、减仓时间、浮盈减仓 / 浮亏减仓 |

盈亏比按净盈亏 / 止损金额，不是行情涨跌百分比。关闭事件等待结算达到终态，估算终态会附加明确的结算说明；不要为了极简模板删掉估算提示。方向采用实际订单方向，不从盈亏正负推断。正式字段样例及各类型图标见 [合作方协议](api/trade-notifications.md)。

## 低耦合投递与移除

`TradeNotificationEvent` 保存通用事件与企业微信链路投递状态；[external_trade_signals.py](../server/positions/external_trade_signals.py) 使用 `ExternalTradeSignalDelivery` 独立投递给另一台服务器。两个适配器消费同一份 `eventId / type / title / content / occurredAt` 载荷，调度任务派发，网络请求在短事务领取之后、数据库锁之外执行。

两类投递均有租约恢复、尝试次数和下次重试时间；租约 60 秒，最多尝试 8 次，耗尽后停止自动尝试并触发带冷却的运维告警。内部企微中转将已成功的 `eventId` 保存在独立持久卷并对重复请求直接确认；外部服务器仍必须按同一稳定 `eventId` 幂等。中转进程若恰好在企微成功后、幂等账本落盘前崩溃，仍存在极小重复窗口，这是非事务型第三方 webhook 无法完全消除的边界。

仓位事件总开关 `TRADE_NOTIFICATION_ENABLED` 同时拦截两类网络投递及直接发送，关闭后不领取或消耗队列尝试；事件与外部投递意图仍可保存。外部独立开关 `EXTERNAL_TRADE_SIGNAL_ENABLED` 同时控制该渠道入队和派发。关闭不删除历史记录，重新开启可能发送已有待投递事件，不承诺自动补发所有历史交易。暂停 / 移除前应核对 pending / sending / exhausted 状态和接收方期望。

未来移除外部服务器渠道时优先关闭独立开关，再删除渠道适配、调度调用及相应配置；保留核心交易与企微事件，投递审计数据按单独保留策略处理。不要为移除渠道改动开平仓、止损或结算算法。

## 模板测试

命令 [send_trade_notification_templates](../server/positions/management/commands/send_trade_notification_templates.py) 与 [send_external_trade_notification_templates](../server/positions/management/commands/send_external_trade_notification_templates.py) 分别面向内部通知通道和对方服务器；通过各自 `--help` 确认参数，显式 `--confirm` 才发送。

模板覆盖五种类型，标题有测试标记，内容不对应真实交易。它们仍会发送真实外部消息，仅在任务明确要求时执行；默认验证应使用 [单测](../server/positions/test_notifications.py) 和 webhook 测试，不重复通知用户。
