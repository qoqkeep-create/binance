# K 线离线恢复实施计划

**目标：** 按已确认方案，不足 30 分钟的后台／断线保留旧图并提示恢复；达到 30 分钟后遮住旧图、重新读取快照，实际首帧显示后结束加载；离线、失败和超时提供重试。

**架构：** 在 `MarketChartViewModel` 记录本图表的后台／断线起点及恢复代际。复用现有完整快照、管线历史、Metal 宿主和首帧交接，不销毁渲染器、不改变交易或后端。恢复等待有独立的 20 秒上限，旧请求／超时不能结束新恢复。

**技术栈：** SwiftUI、Combine、Swift concurrency、现有 Metal 首帧呈现回调及 XCTest。

1. 在 `frontend/ios-app/TradeToolTests/ServerSwitchingTests.swift` 添加实际模型回归：1799／1800 秒边界、短时恢复提示、前台断线、旧响应／首帧、超时、失败和重试。通过 `frontend/ios-app/scripts/test_chart_recovery.py` 先验证失败。
2. 修改 `frontend/ios-app/TradeTool/Features/Chart/MarketChartViewModel.swift`：观察连接、记录持续不可用时间、恢复状态和可取消的等待上限；复用完整快照恢复并拒绝旧回调。
3. 修改 `MarketChartView.swift` 及 `Features/ChartEngine/Host/`：短时显示紧凑提示；长时复用原波形遮挡；错误在绘图区显示可点击重试，波形暂停，成功以匹配代际首帧为准。
4. 用实际模型 host 回归验证；对宿主错误显示／首帧交接补必要回归并进行定向 iOS 验证，执行 App／Widget Release 构建。
5. 更新行情主文档、开发验证和变更记录，区分本地验证与真机待验；检查链接、未追踪文件和独立 Git 的 diff；按既有授权提交推送。

实施状态与验证结果以 [行情主文档](../market-data.md)、[开发验证](../development.md) 和 [变更记录](../changes.md) 为准。

**完成情况（2026-11-07）：** 已按本计划实现；最终 74 项 host、436 项 iOS 单测及 App／Widget Release 构建通过。方案中的阈值使用虚拟时钟验证，实机持续离线与真实加载耗时仍待新包验收。
