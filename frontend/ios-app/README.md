# TradeTools 原生 iOS

当前整合客户端使用 SwiftUI / Metal，最低 iOS 17.0，独立 Bundle ID `com.waibao2025.trade.integrated`。导航为行情、持仓、信号、我的；开仓入口在 K 线页面。

打开 `TradeTool.xcodeproj`。可用 Scheme：

| Scheme | 用途 |
| --- | --- |
| `TradeTool` | 日常运行与单元测试，Archive 使用 Release |
| `TradeTool Seoul` | 整合服务器调试 |
| `TradeTool Release` | Release 运行与归档 |
| `TradeTool Chart Calibration` | 图表和原生流程 UI 检查 |

工程位于独立项目的 `frontend/ios-app/`，相对项目根目录的构建及许可证路径随根目录整体搬迁仍有效。

Debug、Debug-Seoul、Release 默认连接 47.80.22.243（首尔服务器），API 均为 `https://47.80.22.243/integrated/`。登录页及我的页面提供服务器设置；本地开发使用独立 ASGI 服务。手机的回环地址不能访问 Mac。

`Features/USDT/` 是整合后的业务页面，`Dashboard/`、`Chart/`、`ChartEngine/` 为行情与图表；`Core/` 包含共享模型、网络、Keychain 与样式。旧 Java 专属页面和 LAN Scheme 已删除。

- [开发与 XCTest](../../docs/development.md)
- [签名与 TestFlight](../../docs/testflight.md)
- [行情架构](../../docs/market-data.md)
- [图表内核](docs/KLINE_CHART_ARCHITECTURE.md)
- [图表校准](docs/KLINE_CHART_CALIBRATION.md)
- [原项目历史查询](../../docs/sources.md)

真实交易、转账和保护单操作不作为普通安装或 UI 测试。实际验证范围见 [变更](../../docs/changes.md)。
