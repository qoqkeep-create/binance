# 行情与原生图表

整合环境使用 Python 采集和推送，SwiftUI / Metal 显示。接口和当前性能样本见 [整合说明](INTEGRATION.md)。

## 服务端数据

`market_stream` 发现当前报价资产全部正在交易的永续合约，默认 USDT。连续 1m K 线按组直接订阅 Binance 公共 WebSocket，ticker 独立订阅。收盘线持久化到 MySQL，热数据和事件进入 Redis；完整分钟桶聚合为 5m / 15m / 1h / 4h / 1d，缺分钟时不伪造完整桶。

补线、预热、周期保留和历史 REST 请求受共享预算约束。原生 `/api/market/klines` 使用 `beforeOpenTime` 做排除边界分页，WSS `/ws/v1` 按订阅推送。慢客户端队列有界，认证过期后刷新会话并重新连接。

## 客户端

- `Features/Dashboard/`：列表、搜索、自选和可见行情订阅。
- `Features/Chart/`：周期切换、历史请求、实时价格、指标设置与交互。
- `Features/ChartEngine/`：闭合历史 / live tail、增量指标、场景、Metal、字形图集和手势。
- REST 快照与 Socket 事件经入口状态合并；epoch / sequence / 收线屏障避免旧连接、乱序和恢复过程污染当前图表。
- 历史与 live tail 分离，实时变化不重建整段历史。渲染 mailbox 容量为 1，GPU 资源使用有代次的槽位；暂停和恢复只呈现最新快照。

图表当前维护入口见 [图表架构](../frontend/ios-app/docs/KLINE_CHART_ARCHITECTURE.md) 与 [校准方法](../frontend/ios-app/docs/KLINE_CHART_CALIBRATION.md)。来源项目的设计和历史报告从 [来源索引](sources.md) 查询。

## 排障与验收

分别记录历史接口耗时、首条有效 Socket 数据、渲染耗时、连接恢复及分页一致性。HTTP101 只证明握手，不证明有行情；K 线事件延迟不等于订单执行延迟。

网络切换、后台恢复、token 刷新、切币种 / 周期及历史分页均需覆盖。当前短样本存在本机链路延迟离群点，尚未完成真机长期稳定性验收；实际结果与边界见 [变更](changes.md) 和 [已知事项](known-issues.md)。
