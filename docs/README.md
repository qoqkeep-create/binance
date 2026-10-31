# 文档目录

本目录当前服务于 Python + 原生 iOS 整合项目。原 USDT、USDC 文档作为来源资料保留；旧环境地址、发布状态和 Java 功能不能作为本整合环境的运行结论。

| 文档 | 内容 |
| --- | --- |
| [整合说明](INTEGRATION.md) | 当前架构、协议、原生页面映射、实现边界与验证 |
| [部署运维](operations.md) | 首尔独立发布、进程、健康检查、凭证与回滚 |
| [变更及验收](changes.md) | 有日期的发布结果与验证范围 |
| [TestFlight 手机测试](testflight.md) | 独立 App、签名、隐私清单待办、上传及手机安装步骤 |
| [交易安全](trading-safety.md) | 原 USDT 幂等、保护、结算及禁止测试操作 |
| [资金](capital-and-transfers.md) | 原 USDT 资金状态机与历史归属 |
| [带单模式](lead-trading.md) | 原 USDT 模式、身份和首期限制 |
| [配置](configuration.md) | 原业务环境变量；新增整合变量见整合说明和部署模板 |
| [原业务架构](architecture.md) | Python 模块入口；当前运行层补充见整合说明 |
| [已知事项](known-issues.md) | 来源系统遗留问题与整合验收边界 |
| [信号研究](research.md) | 样本、模型、草案发布和回测规则 |
| [通知](signals-and-notifications.md) | 原业务通知与投递隔离 |
| [操作日志](operation-logs.md) | 原业务日志规则 |
| [后端对比](BACKEND_COMPARISON.md) | 整合前的 Python / Java 对比，属于来源时点 |
| [执行计划](plans/2026-10-31-python-ios-integration.md) | 本次任务范围与完成记录 |
| [文档维护](maintenance.md) | 主题维护、迁移索引与记录规则 |

来源根文档保留于 [USDT README](reference/USDT_ROOT_README.md)、[USDC README](reference/USDC_ROOT_README.md)、[旧 USDT 运维](reference/USDT_OPERATIONS.md)、[旧文档目录](reference/USDT_DOCS_INDEX.md)。Java 专项文档继续保留，用于参考 Java 实现；本整合版是否实现以 [整合说明](INTEGRATION.md) 为准。
