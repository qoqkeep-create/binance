# TradeTools-Binance-iOS

独立维护的 Python / Django 后端与 SwiftUI / Metal 原生 iOS 工程，另含共用后端的鸿蒙客户端。iOS 显示名称为 **Binance Tools**，导航为行情、持仓、信号、我的；带单模式隐藏信号。品牌与认证见 [说明](docs/ios-authentication.md)。

本机项目根目录为 `/Users/apple/work/TradeTools-Binance-iOS`，与原 USDT 项目 `TradeTools-Binance`、原 USDC 项目 `tradetools-usdc` 并列。源码、构建和部署配置均在本工程内，原项目只用于历史查询。

```text
TradeTools-Binance-iOS/
├── .git/                         # 独立 Git 历史与本机配置
├── AGENTS.md                     # 项目协作规则
├── README.md                     # 项目入口
├── server/                       # Django HTTP / WSS、交易、资金、行情与调度
├── frontend/
│   ├── ios-app/                  # SwiftUI / Metal、Widget、Xcode 工程与测试
│   └── harmony-app/              # ArkTS / ArkUI 鸿蒙客户端与测试
├── deploy/integrated/            # 镜像、配置模板、初始化与发布
├── compose.integrated.yaml       # 独立 MySQL / Redis 与应用运行服务
└── docs/                         # 架构、业务规则、开发、运维与验收
```

`.integration-runtime/`、`.build/`、虚拟环境、客户端本地构建和 IDE 用户状态属于忽略的本地材料；凭证与签名不进入 Git。

打开 `frontend/ios-app/TradeTool.xcodeproj`，日常运行选择 `TradeTool`，归档选择 `TradeTool Release`。独立 Bundle ID 为 `com.waibao2025.trade.integrated`，默认连接 47.80.22.243（首尔服务器），API 为 `https://47.80.22.243/integrated/`。

在本项目根目录直接使用普通 `git status`、`git diff` 等命令；沿用现有 GitHub 仓库与 `codex/integrated-ios` 分支，交付流程见 [运维](docs/operations.md#github-源码交付)。2026-11-10 已从旧嵌套目录搬迁，历史路径及 Git 参数见 [迁移索引](docs/sources.md#本地目录独立2026-11-10)。Codex、Xcode、DevEco 应打开新根目录下的工程。

[文档目录](docs/README.md) · [Agent 交接手册](docs/agent-handoff.md) · [整合说明](docs/INTEGRATION.md) · [开发验证](docs/development.md) · [TestFlight](docs/testflight.md) · [鸿蒙客户端](docs/harmony-client.md) · [原项目来源](docs/sources.md)。实际部署与测试结果见 [变更记录](docs/changes.md)。
