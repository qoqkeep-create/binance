# iOS K 线实时链路重构设计

**目标**：让 iOS 在全市场 ticker、选中交易对 1m forming、收盘 K 线、网络重连和图表绘制同时发生时保持低延迟、可恢复和正确的收盘顺序。

**范围**：`RealtimeClient`、公共行情事件存储、`MarketChartViewModel`、`ChartDataPipeline`、Metal 图表帧调度和实时诊断。页面布局、交易业务和指标参数保持同一业务含义。

## 当前确认的问题

`RealtimeClient` 使用一条 WebSocket 承载 ticker、K 线、历史通知和账户事件。`MarketChartViewModel` 通过 `AsyncStream(bufferingNewest: 64)` 读取全部事件，forming 事件和收盘事件共享缓冲策略。缓冲发生丢弃时，图表只能进入恢复路径。`ChartDataPipeline.mergeLatestPrice` 和 K 线接收都会生成新的 `ChartDataFrame`，主线程随后向 Metal 宿主提交整帧状态。ping 延迟只代表连接往返时间，不能代表 Binance eventTime 到当前帧的延迟。

现有后端已经保留全局 K 线 `sequence`，并增加 Web 专用 `closedSequence`。iOS 继续读取全局 sequence，避免收盘事件被旧 ingress 误判为迟到。

## 推荐架构

### 传输分流

将 `RealtimeClient` 拆为共享认证、共享重连状态和三条逻辑 lane。

- `market.kline` lane 只订阅当前图表交易对和 1m 流。
- `market.ticker` lane 先兼容逐条消息，随后切换到 `market.ticker.batch`。ticker 采用 latest-wins。
- `trading.*` 与账户事件 lane 保留保序和完整投递。

公共 K 线和账户事件不能共用同一个有界缓冲区。forming K 线可合并，closed K 线必须保序，账户事件必须保留。

### 公共行情存储

新增 `MarketRealtimeStore` actor，按 `symbol + interval` 保存序列水位、已确认历史、forming 尾根和最新报价。所有页面通过 store 的 AsyncSequence 读取规范化事件。store 只解析一次 WSS 消息，多个页面不再各自扫描和过滤同一事件。

store 的 K 线状态分为四部分。

- `closedHistory` 保存连续可信收盘根。
- `formingTail` 保存当前未收盘根。
- `quote` 保存最新 ticker 和 eventTime。
- `recovery` 保存 sequence 缺口、缓冲丢弃和 REST 快照请求。

forming 事件只替换同一 openTime 的尾根。closed 事件按全局 sequence 和 openTime 保序。`closedSequence` 只用于诊断和 Web 缺口判断，iOS 仍使用全局 sequence。

### 图表管线

`ChartDataPipeline` 保留 actor 隔离，将 `mergeLatestPrice` 改为尾根增量变更。forming ticker 只更新价格轴、尾根 OHLC 和需要变化的指标末值。收盘事件才推进 committed indicator engine。历史窗口、指标快照和 Metal frame 使用版本号绑定。

`MarketChartViewModel` 不再在每个事件上直接发布整帧。新增 `ChartFrameScheduler`，在一个显示刷新周期内合并多个事件，优先提交最新尾根和恢复状态。连续 forming 更新使用 30 或 60 Hz 的上限，收盘与恢复事件立即插入下一帧。

### 历史和恢复

首次进入、交易对切换和周期切换读取 1500 根完整快照。正常 forming 更新不触发 REST。检测到全局 sequence 缺口、缓冲丢弃、收盘根乱序或下游状态错误时，store 生成一个带 stream、epoch 和 boundary 的恢复请求。恢复读取当前窗口，安装后再次检查恢复请求，避免多个并发请求互相覆盖。

前台返回优先复用同周期已验证快照。连接 epoch 改变时只废弃旧网络结果和旧尾根，不清空可显示的历史帧。新快照与当前 forming 合并后再交给 Metal 首帧门闩。

## 测试与验收

先为 `MarketRealtimeStore`、`ChartFrameScheduler` 和全局 sequence 兼容写 host 测试。测试必须覆盖 ticker burst、forming coalescing、closed 保序、丢弃后恢复、交易对切换、周期切换、前台恢复和旧 epoch 迟到响应。

性能验收记录以下时间点。

```text
Binance eventTime
iOS WSS 解码时间
MarketRealtimeStore 接收时间
ChartDataPipeline 安装时间
ChartFrameScheduler 提交时间
Metal first drawable 时间
```

验收同时记录每条 lane 的消息数、丢弃数、恢复次数、store 队列深度、frame 提交频率和主线程帧耗时。连接 ping RTT 单独展示，不作为行情端到端延迟。

实施顺序为先加 store 和诊断，再拆 lane，随后接入增量管线和帧调度，最后删除 ViewModel 直接消费 WSS 的旧路径。每一步都保留旧快照恢复和交易状态隔离回归。
