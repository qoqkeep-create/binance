# TradeTools 原生 iOS 整合版

本目录是独立整合副本：以原 USDT Python / Django 交易服务为主后端，采用 USDC 的 SwiftUI 行情界面、Metal K 线和 Socket 推送方案。原 USDT、USDC 来源目录只读。

- 后端：`server/`；HTTP、行情采集、账户命令和原调度器各自运行。
- iOS：`frontend/ios-app/TradeTool.xcodeproj`，scheme `TradeTool`，配置 `Debug-Seoul`；独立 Bundle ID `com.oovso.trade.integrated`。
- 导航：行情、持仓、开仓、信号、我的；带单模式隐藏信号。
- 部署：`compose.integrated.yaml --profile pro`，独立目录 `/opt/trade-tools-integrated`、数据库 `tradetools_integrated`，API 前缀 `https://47.80.22.243/integrated/`。
- `backend/app-service/` 为 Java 参考实现，`tools/` 保留原 Web；本次运行入口使用 Python 与原生 iOS。

[文档目录](docs/README.md) · [整合架构与页面映射](docs/INTEGRATION.md) · [部署运维](docs/operations.md) · [变更及验收](docs/changes.md)。

交易、资金、模式身份及保护规则沿用原 USDT 服务。测试不使用真实开平仓、划转或撤保护单。实际部署状态与测试范围以有日期的验收记录为准。
