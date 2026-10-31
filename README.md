# TradeTools 原生 iOS 整合版

Python / Django 负责交易、资金、行情采集和订单维护，SwiftUI / Metal 提供原生 iPhone 客户端。导航依次为行情、持仓、开仓、信号、我的；带单模式隐藏信号。

| 路径 | 当前用途 |
| --- | --- |
| `server/` | HTTP / ASGI WSS、行情采集、账户命令和调度维护 |
| `frontend/ios-app/` | 原生客户端、图表、XCTest 与 Xcode 工程 |
| `deploy/integrated/` | 独立环境的镜像、配置模板、初始化和发布 |
| `compose.integrated.yaml` | `pro` profile 的五个运行服务 |
| `docs/` | 当前架构、业务规则、开发、运维和验收 |

打开 `frontend/ios-app/TradeTool.xcodeproj`，日常运行选择 `TradeTool`，归档选择 `TradeTool Release`。独立 Bundle ID 为 `com.waibao2025.trade.integrated`，默认 API 为 `https://47.80.22.243/integrated/`。

[文档目录](docs/README.md) · [整合说明](docs/INTEGRATION.md) · [开发验证](docs/development.md) · [运维](docs/operations.md) · [TestFlight](docs/testflight.md) · [原项目来源](docs/sources.md)。

当前目录仅保留整合实现；原 USDT / USDC 代码与历史文档在来源索引指定的本地目录查询。实际部署与测试结果见 [变更记录](docs/changes.md)。
