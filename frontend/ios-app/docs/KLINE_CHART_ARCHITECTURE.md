# 当前 Metal 图表架构

当前整合版使用 SwiftUI 容器、UIKit 手势和原生 Metal 渲染；数据链路见 [行情文档](../../../docs/market-data.md)。历史设计与旧设备报告从 [来源索引](../../../docs/sources.md) 的 USDC 原目录查询。

## 维护入口

| 目录 / 类型 | 责任 |
| --- | --- |
| `Features/Chart/MarketChartViewModel` | REST 历史、周期和实时入口 |
| `ChartEngine/Data/` | CandleStore、历史 / live tail 和 pipeline |
| `ChartEngine/Indicators/` | 增量指标、committed / provisional 状态及有效性 |
| `ChartEngine/Scene/` | 不可变场景、相对坐标、批次与失效范围 |
| `ChartEngine/Host/` | SwiftUI / UIKit 宿主、手势、viewport 和无障碍 |
| `ChartEngine/Diagnostics/` | Debug 压力、Metal 健康与 MetricKit |

Kline ingress 使用 epoch / sequence / 收线屏障，恢复请求和旧连接事件有明确边界。闭合历史与 live tail 分离，同根事件只更新动态状态；指标的临时计算不能污染已提交的收盘状态。

渲染使用容量 1 mailbox 和有租约代次的 GPU 资源槽；屏幕与离屏共用场景和 shader 路径。价格采用相对坐标，文字使用 Core Text 字形图集。暂停时保留最新状态，恢复后重画；故障按已有重建 / 熔断策略显示受控错误。

## 验证

`TradeToolTests` 包含入口、存储、增量指标、投影、Metal 离屏、命令资源和故障策略测试。`TradeTool Chart Calibration` 包含 UI 校准与 opt-in 的整合原生流程。

模拟器 completion 或离屏图像不能证明 iPhone actually-presented 延迟、120Hz 或长期稳定性。当前整合版的实际结果见 [变更记录](../../../docs/changes.md)。
