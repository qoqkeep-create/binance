# 文档维护规范与迁移索引

## 持续维护要求

用户已明确要求：每次任务结束，由执行者主动评估是否有值得长期保留的信息，并写入文档。项目级执行约束见根 [AGENTS.md](../AGENTS.md)。不要等待用户再次提出“记到文档里”。

| 本轮改变了什么 | 更新位置 |
| --- | --- |
| 模块、数据所有权、调用关系 | 当前 [整合架构](INTEGRATION.md)；原业务模块参考 [来源架构](architecture.md)，重大取舍另记 [决策](decisions.md) |
| 本地环境、代码约定、测试方式 | [开发](development.md) |
| 环境变量、凭证作用和生效方式 | [配置](configuration.md)，有样例时一并核对 |
| 云配置、证书、部署授权、发布 / 回滚 | [运维](operations.md)，实际验收另记 [变更](changes.md) |
| 交易、资金、通知、行情或研究行为 | 各自主题主文档，不新建另一份同主题交接手册 |
| 对接字段、鉴权、幂等、成功响应 | 对应 [入站接口](api/external-signals.md) / [出站接口](api/trade-notifications.md) |
| 新缺陷、限制或未验证项 | [已知事项](known-issues.md)，修复后写结果与验证范围 |
| 无持久性变化的问答、临时诊断 | 可以不改文档；交付说明已评估，不为每次问答造文件 |

## 写作和归档标准

- 一个主题只有一个主要维护位置，其他页面链接引用。首页是导航，不堆叠全部细节。
- 标明当前实现、未来目标、待验证和历史事实；以源码和测试核对实现，云端数据写实际验证日期，不将旧记录当实时状态。
- 参数、路由和文件入口要能定位代码；没有全面契约校验时不声称存在完整 OpenAPI。
- 不保存生产 token、完整 webhook 密钥链接、机器人凭证、密码、私钥或带真实账户数据的调试输出。示例数据应可独立分享。
- 运维命令写明执行目录、目标、前置条件及副作用。禁止提供直接照抄的交易绕过和毁坏数据操作作为排障捷径。
- 计划记录实施意图和验收状态，不是现行规范。跨会话复杂工作可以保留活动计划，完成后将维护价值合入主题，删除已合并计划并保留索引 / Git 路径。
- 用户原始附件与忽略文件不是自动清理对象；文档删除需确认内容已合并或已明确过期，并说明可恢复性。

## 每次交付检查

1. 对照本轮 diff，判断接口、配置、权限、业务和运维规则是否改变，并更新对应主文档。
2. 验证相对链接、源码路径和命令实际存在；检查旧路径是否还有活跃引用。
3. 运行 `git diff --check`，确认没有误带凭证、生成物、无关代码或用户资料。
4. 记录真正跑过的测试和线上检查；未部署、未验证的内容直说，不写成“全部完成”。
5. 最终交付给出主要入口、重要变化和验证范围；删除了文档时说明 Git 恢复路径。

## 本次迁移说明

整理日期：2026-09-06。旧文档最后完整基线为 `8de868a`。表内旧路径是历史检索标识，不是有效现行链接；新位置才是后续维护入口。两份合作方协议迁移并修正，其余 37 份过期 / 重复文件合并后删除。

### 旧 doc 目录

| 原路径 | 处理 / 新位置 |
| --- | --- |
| `doc/agent-handbook.md` | 拆分到架构、开发、配置、运维和业务文档；未完成项独立；根 README 导航替代巨型手册 |
| `doc/production-server.md` | 合入 [运维](operations.md)，删除过期 TradingView / 纯容器入口说明 |
| `doc/docker-deploy.md` | 合入 [运维](operations.md) 和 [配置](configuration.md)，不沿用移除宿主 Nginx 的旧方案 |
| `doc/server-access-control.md` | 现行授权和交易禁区合入 [运维](operations.md) / [交易安全](trading-safety.md)，未落地加固转 [已知事项](known-issues.md) |
| `doc/binance-prod-launch-checklist.md` | 合入 [运维上线清单](operations.md) / [开发验证](development.md) |
| `doc/external-signal-api.md` | 迁移为 [入站协议](api/external-signals.md)，修正无 ID 去重与企微转发边界 |
| `doc/outbound-trade-notification-api.md` | 迁移为 [出站协议](api/trade-notifications.md)，补重试上限与独立渠道边界 |
| `doc/PRD.MD`、`doc/PRD1.MD` | 旧 OKX 产品设计退出维护；有效规则按当前实现归入各业务主题；背景见 [历史说明](archive/legacy-design.md) |
| `doc/spec.md`、`doc/spec1.md` | 旧技术设计及镜像合并，架构与开发规范取代 |
| `doc/tasks.md`、`doc/tasks1.md` | 一次性旧任务清单删除；未实现且仍有意义的内容转已知事项 |
| `doc/openapi.yaml`、`doc/openapi1.yaml` | 旧契约与空镜像删除，不匹配当前认证 / Binance 字段；当前路由地图和独立对接协议替代，完整 schema 列为待完善 |
| `tools/README.md` | 保留并缩短为前端快速入口，纠正 pnpm、过期版本及目录结构，链接统一开发规范 |

### 已合并的 24 份计划

| 原路径 | 新维护位置 |
| --- | --- |
| `docs/plans/2026-06-21-ai-strategy-workflow.md` | [研究](research.md) |
| `docs/plans/2026-06-21-research-packet.md` | [研究](research.md) |
| `docs/plans/2026-06-21-signal-research.md` | [研究](research.md) |
| `docs/plans/2026-06-21-user-ai-models.md` | [研究](research.md)，以现有共享目录 + 个人选择修正旧设计 |
| `docs/plans/2026-06-24-market-analysis.md` | [研究](research.md) / [信号](signals-and-notifications.md)，标明旧 HTTP 页面非现行 |
| `docs/plans/2026-08-25-semi-automatic-capital-normalization.md` | [资金](capital-and-transfers.md) |
| `docs/plans/2026-08-25-trading-safety-remediation.md` | [交易安全](trading-safety.md) / [已知事项](known-issues.md) |
| `docs/plans/2026-08-30-capital-system-intent-review.md` | [资金](capital-and-transfers.md) |
| `docs/plans/2026-09-03-external-signal-ingestion.md` | [信号](signals-and-notifications.md) / [入站协议](api/external-signals.md) |
| `docs/plans/2026-09-03-transfer-history.md` | [转账历史](capital-and-transfers.md) |
| `docs/plans/2026-09-04-external-trade-notification-forwarding.md` | [通知](signals-and-notifications.md) / [出站协议](api/trade-notifications.md) |
| `docs/plans/2026-09-04-flexible-external-signal-ingestion.md` | [入站协议](api/external-signals.md) |
| `docs/plans/2026-09-04-signal-source-classification-design.md` | [信号](signals-and-notifications.md) |
| `docs/plans/2026-09-04-trade-notification-simplification-design.md` | [通知](signals-and-notifications.md) / [出站协议](api/trade-notifications.md) |
| `docs/plans/2026-09-04-transfer-history-cache-design.md` | [转账历史](capital-and-transfers.md) |
| `docs/plans/2026-09-04-transfer-history-incremental-sync.md` | [转账历史](capital-and-transfers.md) |
| `docs/plans/2026-09-05-frontend-security-deployment-governance.md` | [开发](development.md)、[配置](configuration.md)、[运维](operations.md) |
| `docs/plans/2026-09-05-kline-edge-cache.md` | [K 线](market-data.md) |
| `docs/plans/2026-09-05-kline-hybrid-market-data-design.md` | [K 线](market-data.md) |
| `docs/plans/2026-09-05-kline-hybrid-market-data-implementation.md` | [K 线](market-data.md) |
| `docs/plans/2026-09-05-kline-review-fixes.md` | [K 线](market-data.md) |
| `docs/plans/2026-09-05-notification-settlement-ledger.md` | [交易安全](trading-safety.md) / [通知](signals-and-notifications.md) |
| `docs/plans/2026-09-05-same-origin-kline-stream-and-origin-compression.md` | [K 线](market-data.md) / [运维](operations.md)，以独立 WS 域名的最终实现为准 |
| `docs/plans/2026-09-05-transfer-history-manual-refresh-design.md` | [转账历史](capital-and-transfers.md) |

### 查看和恢复原文

在仓库根目录运行以下只读命令，替换为表内对应旧路径：

```bash
git show 8de868a:doc/agent-handbook.md
git log --all -- doc/agent-handbook.md
git show 8de868a:docs/plans/2026-09-05-kline-review-fixes.md
```

若确需恢复某段原文，先用 `git show` 检索，再将所需内容放到明确标注历史的文件或现行主题；不要整批恢复过期运维指令覆盖本次整理。提交本轮后，还可按 Git 路径历史查看删除和迁移差异。
