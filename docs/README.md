# 文档目录

本文档集描述 Python + 原生 iOS 整合版，以及共用后端的独立鸿蒙客户端。源码与配置是当前实现的依据；来源项目的历史资料从 [来源索引](sources.md) 查询。

| 文档 | 内容 |
| --- | --- |
| [整合说明](INTEGRATION.md) | 数据链路、协议、页面映射与验证边界 |
| [架构](architecture.md) | 运行单元、模块责任和账户身份 |
| [Web 原生复刻](ios-web-parity.md) | 页面映射、尺寸、主题、截图回归及验证边界 |
| [品牌与认证](ios-authentication.md) | Binance Tools 名称与图标、USDC 认证布局、底部弹窗及已有接口 |
| [持仓浮窗](ios-floating-positions.md) | 外部多持仓画中画与 ActivityKit live 卡片，刷新、账户隔离及真机待验范围 |
| [鸿蒙客户端](harmony-client.md) | 原生源码、签名安装、前三批复刻与 Mate 80 验证、功能差异 |
| [鸿蒙复刻计划](plans/2026-11-03-harmony-ios-parity.md) | 当前 iOS 源码依据、七批执行顺序与剩余验收 |
| [开发验证](development.md) | 后端、Xcode、测试与回归范围 |
| [配置](configuration.md) | 整合环境的配置入口和关键参数 |
| [部署运维](operations.md) | 独立部署、回滚、GitHub 源码交付 |
| [变更与验收](changes.md) | 有日期和范围的实际结果 |
| [TestFlight](testflight.md) | 签名、隐私清单、上传和手机安装 |
| [行情与图表](market-data.md) | 采集、分页、推送、Metal、加载诊断与排障 |
| [K 线首屏交接原稿](plans/2026-11-01-ios-kline-first-frame-handoff.md) | 保留用户原始材料；执行结果已归入行情、开发、运维与变更主文档 |
| [交易安全](trading-safety.md) | 幂等、保护、结算和测试边界 |
| [资金](capital-and-transfers.md) | 归集状态机、历史归属与保证金率 |
| [带单模式](lead-trading.md) | 模式身份、能力和开放边界 |
| [信号与通知](signals-and-notifications.md) | 入库、事件和独立投递 |
| [计划、校验与研究退役](research.md) | 已移除页面与接口、内部扫描、历史资料与数据库兼容 |
| [操作日志](operation-logs.md) | 日志口径、状态与分页 |
| [入站信号接口](api/external-signals.md) | 合作方鉴权、字段和去重 |
| [出站通知接口](api/trade-notifications.md) | 事件、渠道与投递协议 |
| [已知事项](known-issues.md) | 当前待实现与待验证内容 |
| [原项目来源](sources.md) | 独立项目根目录、USDT / USDC 来源与历史 Git 基线 |
| [文档维护](maintenance.md) | 主题主文档及更新规则 |
| [Agent 交接手册](agent-handoff.md) | 面向后续 Agent 的项目全局地图、开发验证、部署回滚、OSS 和安全边界 |
