# 观察计划与信号研究退役

核对日期：2026-11-01；以下为当前本地源码状态，发布和验证范围见 [变更与验收](changes.md)。

## 当前保留的能力

观察计划由独立的 [watch_plans](../server/watch_plans/models.py) 模块维护，原生入口为“我的 → 更多功能 → 看盘计划”。[API](../server/watch_plans/urls.py) 仍为 `/v1/watch-plan/list/create/update/delete`，按当前用户读写计划、复盘、结果金额、0–100 分和评分明细。金额使用 Decimal；观察记录不作为自动下单指令。

[market_analysis](../server/market_analysis/trend.py) 继续承担闭合 K 线的内部趋势扫描，输出供信号页使用。其行情扫描与交易信号链路独立于已移除的研究功能。

## 信号研究已从运行代码移除

按用户要求，iOS 已删除“信号研究”菜单、页面、Swift Charts 研究图表、DEBUG 数据及专属 UI 场景。后端已移除研究应用注册、`/v1/signal-research/` 路由、模型、管理后台、AI 请求、采集、规则、草稿、发布、回测与专属测试。旧接口不再解析，返回 404；`AI_*` 配置已停止读取。

凭证轮换命令只处理当前 API 绑定的 `api_key`、`secret_key`、`passphrase`，不再导入或查询研究模型。旧研究模型密文不在该命令的验证范围内；保留旧库备份时仍须保护对应的历史解密密钥。

## 迁移与历史资料

`server/signal_research/` 仅保留空包和历史 `migrations/`，不在 `INSTALLED_APPS` 中，也不提供运行模型或服务。本次不执行删表、删资料或删除 `django_migrations` 记录；已有数据库的研究表保留，新库不再创建研究表，因此无需新增数据库 migration。

退役前的源码与原规则可从整合版 Git 基线 `46fd475f1f143a74710b6a2191c0ccbb18478f0d` 的 `docs/research.md`、`server/signal_research/` 与 `frontend/ios-app/TradeTool/Features/USDT/USDTResearchViews.swift` 查询。本机删除前还在忽略目录 `.integration-runtime/removed-research-20261101.tar.gz` 保存了当前研究源码，包括原有未提交改动；该副本不随版本发布。

新库若回滚到退役前代码，必须使用该版本执行 migrate 补建研究表；旧库回滚仍需核对迁移记录和历史密钥。代码回滚不会恢复已主动删除的数据库资料。本次没有清理历史数据，也没有修改实盘持仓、保护或交易策略。

验证入口为 [退役回归](../server/common/test_retired_modules.py)、[凭证轮换](../server/common/test_key_rotation.py)、[观察计划](../server/watch_plans/tests.py) 与 [内部扫描](../server/market_analysis/tests.py)。
