# TradeTools Binance

> 来源归档（2026-10-31）：链接已按归档位置调整；当前整合实现与部署见 [整合说明](../INTEGRATION.md)。


面向 Binance USDT 合约的交易辅助系统，包含开仓与持仓保护、资金规范化、转账历史、内外部信号、交易通知和信号研究。仓库及数据库中保留部分 `riskon`、`TradingView`、`OKX` 历史命名，不代表仍使用旧业务路径。

## 文档入口

从 [维护文档目录](../README.md) 开始。新接手项目建议依次阅读：

1. [项目架构](../architecture.md)：模块、数据归属、请求和后台任务。
2. [开发与验证](../development.md)：本地环境、代码规范、测试要求。
3. [交易安全边界](../trading-safety.md)：不可破坏的业务约束。
4. [部署与运维](../operations.md)：生产结构、发布、排障和证书。

对接方单独使用 [外部信号接入](../api/external-signals.md) 或 [交易通知推送](../api/trade-notifications.md)，凭证通过私密渠道另行提供。

## 仓库入口

| 目录 | 职责 |
| --- | --- |
| `tools/` | React / TypeScript 前端，名称不是脚本工具目录 |
| `server/` | Django API、交易状态、后台任务和数据库迁移 |
| `docker/` | 应用镜像、容器 Nginx、通知接收与转发服务 |
| `deploy/` | 版本化部署脚本、宿主机 WS Nginx 和证书钩子 |
| `docs/` | 现行说明、接口协议、决策、待办与历史索引 |

执行任务前遵守 [AGENTS.md](USDT_ROOT_AGENTS.md)。任务完成时评估并更新受影响的文档，不把未验证的方案写成已完成功能。本文档整理基线为 `8de868a`，线上历史验收见 [变更记录](../changes.md)，未完成项见 [已知事项](../known-issues.md)。
