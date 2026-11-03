# 信号与通知

> 本文维护整合版沿用的业务规则；当前运行与验证边界见 [整合说明](INTEGRATION.md)。来源项目历史资料从 [来源索引](sources.md) 查询。

本主题维护数据流、模块隔离和消息口径；请求字段和响应协议以两份独立 [接入](api/external-signals.md) / [推送](api/trade-notifications.md) 文档为准。

投递语义核对日期：2026-11-02。以下 APNs／Echobell 为本地源码实现，实际配置及手机投递尚未验收。

## 内部信号恢复状态（2026-11-03）

2026-11-03 12:23（北京时间），**47.80.22.243（首尔服务器）** 已限定部署直接入库链路。旧扫描先检查通知入口 token，缺失时返回 `evaluated=0`，因此前端有读取接口也没有数据；现在计算／持久化不依赖旧通知入口。自然调度已完成 14 个币种 × 4 个周期共 56 项，`failed=0`，当轮真实触发数为 0；鉴权 `source=internal` GET 200、数据仍为空，没有插入样例消息或重放历史。真实触发后的生产保存及手机可见性仍待自然验收，不能把本次空结果写成已有信号到达。

原生信号页进入立即读取，前台停留每 30 秒刷新已入库信号，可下拉手动刷新；离页／后台停止任务，带单模式不启动此读取。该客户端改动尚未发布到 TestFlight。限定包已应用 `mobile.0002` 并包含通知排队所需模型，但没有设备注册路由、通知 dispatcher 或浮盈外发任务，真实发送尝试为 0。下文完整 APNs／Echobell 能力仍是源码实现及待完整发布的边界。版本、备份与回滚见 [运维](operations.md#信号入库与杠杆金额限定发布2026-11-03)，隔离入库／读取用例见 [开发](development.md#图表账户反馈回归2026-11-03)。

## 三条链路不要混淆

| 链路 | 数据源与去向 | 是否交易 |
| --- | --- | --- |
| 外部指标信号 | 合作方 JSON -> webhook 翻译 -> 数据库；新增消息尽力转发企业微信，当前 iOS 不展示该来源 | 否，不读取交易账户、不自动开平仓 |
| 内部指标信号 | 自有趋势扫描 -> 数据库 -> iOS 信号页及现有通知通道 | 扫描 / 通知本身不自动下单 |
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

## iOS 信号与 Echobell 独立投递（2026-11-02，本地）

已复现无旧 `MARKET_ANALYSIS_ALERT_URL/TOKEN` 时扫描整轮退出的问题。现在内部扫描直接在同一事务中保存 `source=internal` 消息及 `mobile.NotificationEvent`／`NotificationDelivery`，不再经过旧 webhook。稳定事件键为 `trend:{symbol}:{interval}:{closeMs}`；入库或排队失败不推进扫描标记，下轮可重试。规则本身不变，只记录最后一根已收盘 K 线的真实触发，不补造历史信号。关闭外发仍可保存并读取信号。

登录后的根界面激活原生通知管理器；设备通过 JWT 鉴权的 `POST /api/push/devices/register`／`unregister` 注册或注销，字段为 `installationId`（UUID）、`deviceToken`（十六进制）、`environment`（development／production）、`bundleIdentifier`。退出使用 `X-Push-Installation-ID` 仅停用本用户当前安装。绑定 token 的用户发生变化后，旧用户的待发消息取消。`strategy.signal` 载荷可由原生解析，点击打开同币种、同周期的标准 K 线。

调度器每 10 秒独立派发通知；APNs 与 Echobell 各自领取投递记录，不在扫描或交易成功路径同步发送。APNs 使用 HTTP/2、ES256 provider token、当前应用 topic 和 production／sandbox，60 秒租约、最多 8 次退避尝试；失效 token 停用，超过一小时的事件取消。中断的最后一次尝试收敛为 exhausted；稳定 `apns-id` 不等同于苹果端严格只投一次。Echobell 每事件一次尝试，中断／不确定结果记 unknown，不盲目重拨。异常只记录类型，不保存 token、完整 URL 或原始响应。

APNs 开关只对开启时新入队事件生成设备投递；Echobell 同理，不承诺开启后自动补发全部历史。设备注册成功、代码编译或前台 WSS 成功均不能代替后台系统通知验收。

## 浮盈 Webhook（沿用原 USDT）

已按用户要求从原 USDT Git 基线 `c299f58` 移植 `positions/profit_alerts.py` 及回归。阈值为 **1R、1.5R、2R、3R、4R、5R、6R、7R、8R**，R 固定为首次观察时的止损额；浮盈取当前交易所仓位，不从客户端显示值推算。仅监控配置用户、当前绑定代际的普通／带单有效仓位，同币种同向本地重复订单不猜测归属；读取失败不关闭现有仓位或取消已有保护。

每仓位每阈值持久化去重，配置用户跨仓位与模式共用至少 60 秒间隔；真正发送前再读实时浮盈，因此已排队的阈值可能用回落后的当前浮盈播报，此行为保持原版。Echobell 返回拒绝为 failed，超时／中断为 unknown，均不自动重拨。发送使用严格限定的 Echobell HTTPS 地址，并禁止重定向；仓位扫描、通知投递均不执行开平仓、资金或保护单写操作。

配置入口和受限 p8 挂载见 [配置](configuration.md#ios-信号和浮盈通知)。2026-11-02 用户随后提供旧 Echobell 地址，已写入 47.80.22.243（首尔服务器）的 0600 环境文件，浮盈接收范围按整合库当前唯一有效绑定用户配置，不直接照搬旧库主键。APNs 复用原 iOS 项目的签名材料，已核对 P-256 密钥及与当前工程相同的团队；只读挂载源已准备为 UID 10001、目录 0700／文件 0400。仅保存配置，没有重启容器、部署通知源码、应用新迁移或真实外发，当前运行进程尚未加载这批参数；上线与手机验收仍待进行，操作备份见 [运维](operations.md#通知配置准备2026-11-02)。

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

外发开关 `EXTERNAL_TRADE_SIGNAL_ENABLED` 同时控制入队和派发。关闭不删除历史记录，重新开启可能发送已有待投递事件，不承诺自动补发所有历史交易。暂停 / 移除前应核对 pending / sending / exhausted 状态和接收方期望。

未来移除外部服务器渠道时优先关闭独立开关，再删除渠道适配、调度调用及相应配置；保留核心交易与企微事件，投递审计数据按单独保留策略处理。不要为移除渠道改动开平仓、止损或结算算法。

## 模板测试

命令 [send_trade_notification_templates](../server/positions/management/commands/send_trade_notification_templates.py) 与 [send_external_trade_notification_templates](../server/positions/management/commands/send_external_trade_notification_templates.py) 分别面向内部通知通道和对方服务器；通过各自 `--help` 确认参数，显式 `--confirm` 才发送。

模板覆盖五种类型，标题有测试标记，内容不对应真实交易。它们仍会发送真实外部消息，仅在任务明确要求时执行；默认验证应使用 [单测](../server/positions/test_notifications.py) 和 webhook 测试，不重复通知用户。
