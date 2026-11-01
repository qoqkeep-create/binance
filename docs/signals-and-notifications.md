# 信号与通知

> 本文维护整合版沿用的业务规则；当前运行与验证边界见 [整合说明](INTEGRATION.md)。来源项目历史资料从 [来源索引](sources.md) 查询。

本主题维护数据流、模块隔离和消息口径；请求字段和响应协议以两份独立 [接入](api/external-signals.md) / [推送](api/trade-notifications.md) 文档为准。

投递语义核对日期：2026-09-10。

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
