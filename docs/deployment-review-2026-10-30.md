# 2026-10-30 未提交内容发布前审阅

状态：仅审阅，等待用户决定发布范围；本轮未提交、推送或部署，未修改应用代码。本文是有日期的审阅快照，发布操作仍以 [运维文档](operations.md) 为主。

## 结论

业务修复大部分有保留及发布价值，但当前工作区不能原样全部发布。必须先处理构建文件缺失、合并较新代码及研究样本重采集入口的兼容遗漏，再验证最终合并版本。用户提出的合约 / 现货页签与独立单笔划转尚未实现，不属于已有待发布成果。

## 基线和完整范围

- 当前分支 `codex/manual-position-protection`，HEAD 为 `ae9cbaf5efcec1269d71b27e45571d4978c8f3c7`。
- 审阅开始时共 71 个变化路径：51 个已跟踪文件变化（含 9 个删除），20 个未跟踪文件。对照 HEAD 审阅改动，并将实际文件内容与生产 `origin/main` 比较。
- 2026-10-30 经 SSH 只读核对，唯一生产目标 `47.236.86.243` 的应用 Git 为 `c299f5886425ac0af588520de5a9d496fc0fe6e3`，与 last-good 一致，不是当前工作区的旧 HEAD。六服务运行状态已检查；此次未将 HTTP 301 当作深度健康通过。
- 两个独立的后续运维分支也须保留：`codex/leverage-picker` 的 `bfb35df` 包含手动发布与端口收紧；`codex/frontend-oss-delivery` 的 `b14f21a` 包含国内 OSS / CDN 分发。两分支均基于 `c299f58`，不能认为任一分支已经包含另一分支。
- 服务器手动执行器与 `bfb35df` 的 `deploy/run-deploy.sh` SHA-256 一致；OSS publisher 与 `b14f21a` 的 `deploy/frontend_oss.py` SHA-256 一致。应用 Git HEAD 不包含全部已安装的运维文件，不能只按应用提交覆盖它们。

| 分类 | 内容与审阅判断 |
| --- | --- |
| 资金按钮与旧流水状态 | Decimal 资格判断、超额不足 0.01 U 禁用、旧笔独立核对入口、关闭清显示状态、旧笔完成后预检当前计划。保留未知结果不重复提交及账户代际隔离；可作为独立发布候选 |
| 交易成交和仓位身份 | 部分成交证据保留、零成交已终态请求解除外部发现阻塞、三个平仓入口传预期方向。需要与线上后来增加的开仓方向 / 杠杆逻辑合并；解除阻塞会让此前漏管的真实仓位重新进入既有保护 / 超额退出流程 |
| 持仓结算、历史和日志 | 区分真实零与缺字段；历史先 SQL 分页；维护队列先筛有效绑定；仅合并连续重复日志；持仓列表携带最新异常，取消逐仓全日志轮询。需保留线上后来增加的手动仓历史字段 |
| 后台与研究 | 后台任务清理 DB 连接、策略层级复用预取；研究草案条件更新和闭合 K 线校验。研究旧样本页面恢复缺口见 Spec；调度合并需保留已上线的语音和历史任务 |
| 其他前端 | 策略编辑先从服务端确认身份，防止刷新后误新建；共用小价格格式；Profile / Signals 隐藏或离线暂停轮询。交易页合并需保留已上线的杠杆选择与方向检查 |
| Pay 历史与测试 | 已经上线的改动，不能再次算作本次新功能。7 个文件与 `c299f58` 完全一致，见下表；`common/binance.py` 和 `binance_rate_limit.py` 的 Pay 部分也已上线 |
| 文档和审计材料 | 11 份主题文档修改，以及访问评估、原审计、审计复核和修复计划 4 份新增文档。保留原始材料，合并时不能覆盖后续运维及发布记录 |
| 测试与工作记录 | 新增和修改的回归测试应随对应修复入库；`.workbuddy/memory/2026-10-01.md` 是历史工作记录，不是运行功能，无需为它重建生产 |
| Docker 文件删除 | 9 个删除均未发现替代构建路径，当前不能纳入发布，见发布包装检查 |

以上路径按生产比较为：7 个相同、38 个内容不同、17 个生产中不存在、9 个本地已删除。相同文件包括生产已有而当前旧 HEAD 尚未跟踪的测试，不全是本次新增。

| 与生产完全一致的文件 |
| --- |
| `server/accounts/test_external_deposits.py` |
| `server/accounts/tests.py` |
| `server/accounts/transfer_history.py` |
| `server/accounts/test_pay_history.py` |
| `server/common/test_pay_history.py` |
| `server/integration_tests/redis_worker.py` |
| `server/integration_tests/test_pay_budget.py` |

## 发布包装检查

### P1：删除了当前构建仍依赖的 9 个文件

`docker-compose.yml:110`、`:127`、`:140`、`:166` 仍指定三个已删除 Dockerfile，`:117`、`:134` 仍指定两个已删除启动脚本。前端 Dockerfile 还需要已删除的 Nginx 配置；通知容器需要已删除的 `app.py`。因此当前目录缺少重新构建四个应用服务的输入，不是可直接部署的完整源码。已核对实际文件不存在及现行 COPY / command 引用；本机没有 Docker CLI，本轮未伪称完成镜像构建。

```text
docker/frontend/Dockerfile
docker/nginx/default.conf
docker/nginx/security-headers.conf
docker/server/Dockerfile
docker/server/scheduler.sh
docker/server/web.sh
docker/tradingview/Dockerfile
docker/tradingview/app.py
docker/tradingview/test_app.py
```

应在准备发布版本时保留有效基线的这些文件及其后续修复。此次仅记录，没有擅自恢复或删除用户改动。

### P1：不能把旧目录直接覆盖生产

`c299f58` 已包含当前旧 HEAD 之后的杠杆 / 容量、开仓方向、手动历史、持仓语音和 Echobell 等功能。直接以旧分支内容替换会回退这些实现，也不能保留独立安装的手动发布和 OSS 工具。

对所有已修改且仍存在的跟踪文件，以 HEAD 为共同旧文本、`b14f21a` 为较新文本进行临时三方合并检查，得到 4 个内容已相同、19 个上游未改、10 个能自动合并、9 个文本冲突。该检查只在临时目录执行，没有合并或改写仓库。9 个冲突为：

```text
docs/README.md
docs/capital-and-transfers.md
docs/changes.md
docs/known-issues.md
docs/operation-logs.md
docs/operations.md
server/common/binance_rate_limit.py
server/trading/scheduler.py
tools/src/pages/trading/index.tsx
```

其中应用代码分别涉及新 `symbolConfig` 权重、持仓语音任务与连接清理、交易页的模式守卫和共用价格格式。自动合并成功也不等于语义兼容；最终发布版本需保留较新基线功能并重新验证。上述统计尚未包含两个运维分支之间的合并，因此不能当成最终冲突总数。

## Standards

独立规范审阅未确认本批业务代码存在额外的新增规范缺陷。Decimal、用户 / 模式 / Key 身份隔离、未知写结果保留原身份核对、通知与交易路径隔离仍有必要，不建议为减少行数删除。此结论不覆盖上节构建包装问题，也不表示旧版本已知问题全部修复。

运维资料存在需要纠正的事实偏差：本地旧文档仍把 push main、webhook 和 timer 描述为现行自动发布。2026-10-30 实查 `tradetools-auto-deploy.timer` 与 `webhook.service` 均 inactive / masked，用户也已明确要求 SSH 发布；OSS publisher timer 则 active / enabled，仅同步已确认的前端构建。这两个 timer 不是同一流程。

## Spec

独立需求审阅确认 1 项不完整实现：**[P2] 旧研究样本被后端排除后，页面无法重新采集。**

需求要求“旧提前采集或缺元数据的样本重新采集后才能进入研究证据”。新增 `server/signal_research/views.py:94` 的 `_ready_samples` 要求 `fetched_at >= signal_time`；但 `tools/src/pages/signal-research/index.tsx:771` 禁用所有已经有 `fetched_at` 的单项采集按钮，`:406` 的批量入口也排除它们。样本时间到达后，用户仍无法从页面恢复样本有效性。

这是本批相对 `origin/main(c299f58)` 的兼容遗漏，已有 [REVIEW2-B6](known-issues.md#业务规格与产品行为-1) 记录，不是今天新发现的线上事故。仓库外真实组件验证中，旧提前采集样本“应允许重新采集”的反例失败，未采集可用、正常已采集禁用的两个对照通过。后端已有直接 POST 重采集的测试，未覆盖缺失的页面入口。应复用原采集 API 增加显式重采集入口，保留原样本。

其余审查范围未确认额外新增需求缺陷。资金按钮简化已实现；[主动单笔划转提案](capital-and-transfers.md#拟议按钱包主动发起单笔划转) 与固定收款目标的进一步约束未实现，不应当作本次部署成果。

## 已知问题与发布影响

- 既有 [第二轮审阅清单](known-issues.md#2026-09-30-第二轮全仓审阅尚未修复) 仍须保留，不能把本批发布说成“全部审计问题已修复”。例如未知写恢复可能重复 POST、明确无提交的拒绝路径遗留 pending、开仓费完整性和前端详情竞态，不能因本轮测试通过直接关闭。这些不是本轮新发现或全部由本批引入，不在本次审阅中顺手修复。
- 外部发现解除遗留屏蔽后，既有手动仓可能首次进入已授权的强制保护 / 超额退出规则。当前未对实际账户做完整只读影响盘点，故本次不能宣称全量发布不会影响既有持仓。准备发布时需先明确该范围。
- 本批未新增迁移、运行依赖或锁文件改动；这不允许退回缺少线上后来新增迁移 / 字段的旧代码，也不意味着代码回滚会还原数据库。
- 资金真实归集、交易所到账、旧流水实际终态，以及新页签方案均未由本轮测试验收。

## 本轮验证与边界

- 前端全量：24 个文件、162 项通过；生产构建（含 TypeScript）及全量 ESLint 通过。
- 后端：561 项通过，Django 系统检查通过。隔离 Python 3.11.16、内存 SQLite / LocMem、禁止加载 dotenv、假密钥、禁真实 HTTP、未启动 scheduler。首批 292 项涵盖 Pay、成交证据、方向、外部发现、持仓、研究和调度回归；补充 269 项涵盖适配器、账户、研究和资金既有回归。
- 研究页面独立反例：1 项按预期暴露问题、2 项对照通过；与主前端测试集全绿分开记录。
- 已核对构建路径、与生产的文件内容、两个独立运维分支和服务器脚本哈希；没有运行新合并版本的镜像构建、MySQL / Redis 并发或线上业务验收。
- 未执行真实开平仓、划转、撤保护单、改人工接管标记或外发通知。
- `git diff --check` 与本轮文档相对链接检查通过；缺失的 Docker 构建输入单列为已知发布阻断。

规范轴未确认额外新增业务规范问题；需求轴 1 项兼容遗漏（REVIEW2-B6）；发布包装另有 2 项 P1 阻断。推荐后续准备“保留现有线上功能及运维配置、补齐上述问题后，合并全部有效修复”的候选版本，由用户决定范围后再提交和 SSH 发布。
