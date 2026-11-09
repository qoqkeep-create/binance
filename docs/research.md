# 看盘计划、手动校验与信号研究退役

核对日期：2026-11-03；以下为当前源码状态，发布和验证范围见 [变更与验收](changes.md)。

## 看盘计划与手动校验已移除

2026-11-01 按用户新要求删除“我的 → 更多功能”中的“看盘计划”和“开仓理由/指标校验”。计划列表、编辑、复盘、评分、结果、交易前校准问答及手动指标清单的页面、状态、持久化读写和 DEBUG 替身均已删除。手动清单原先只使用本机 `integrated.indicators.<userID>`，没有独立服务端接口；退休不批量擦除用户旧偏好。

后端移除 `watch_plans` 应用注册、模型、服务、路由和专属 CRUD 测试，`/v1/watch-plan/list/create/update/delete` 不再解析；移除 `/v1/auth/preflight-status`、`preflight-complete` 及登录响应的校准时间。`users.0009_retire_watch_calibration` 通过 `SeparateDatabaseAndState` 删除 ORM 字段，数据库操作为空：历史 nullable 列、计划表、数据和已应用的 migration 记录保留，便于回滚。`server/watch_plans/` 仅保留空包及历史 migrations，新库不再创建计划表。

移除范围是手动清单和计划功能。资金预检、图表技术指标及内部信号扫描继续保留。2026-11-03 又按用户要求移除开仓 EMA 方向初筛专属模块与接口，当前市价／限价直接进入资金预检和订单确认；详见 [交易安全](trading-safety.md#图表与标准开仓共用流程2026-11-02)。后端发布状态见 [运维](operations.md)，客户端源码交付状态见 [本轮记录](changes.md#2026-11-03开仓初筛退役止盈显示与策略二次确认)，签名新包仍待分发／手机验收。

## 当前保留的能力

[market_analysis](../server/market_analysis/trend.py) 继续承担闭合 K 线的内部趋势扫描，输出供信号页使用。其行情扫描与交易信号链路独立于已移除的研究功能。

## Binance Maker / Post Only 能力核对（2026-11-09）

本轮只读核对 Binance 官方接口和当前整合版下单路径，未改交易逻辑。项目当前使用 USDⓈ-M Futures：`BinanceFuturesClient.place_limit_order` 发送 `LIMIT` + `timeInForce=GTC`，市价开仓和立即平仓发送 `MARKET`，手动／策略止盈通过条件单 `TAKE_PROFIT` 或 `TAKE_PROFIT_MARKET`；对应代码见 [币安客户端](../server/common/binance.py) 与 [持仓接口](../server/positions/views.py)。

USDⓈ-M 的普通限价单支持 `timeInForce=GTX`（Good Till Crossing / Post Only）：只有能作为 Maker 留在订单簿时才接受；若会立即吃单，接口拒绝并返回 `-5022 GTX_ORDER_REJECT`，不会自动改价重挂。开仓限价和需要触发后挂限价的 `TAKE_PROFIT` 理论上可采用 GTX；`MARKET`、`STOP_MARKET`、`TAKE_PROFIT_MARKET`、强平和 ADL 没有 Maker 保证。GTX 可能长时间不成交，且盘口变化会导致拒单，因此业务必须单独定义拒单提示、是否重试和价格重算，不能把 GTX 当成“尽量 Maker”。官方枚举与语义见 [USDⓈ-M 公开 API 参数](https://developers.binance.com/zh-CN/docs/products/derivatives-trading-usds-futures/common-definition)，拒单码见 [Binance 错误代码](https://developers.binance.com/en/docs/products/derivatives-trading-portfolio-margin/error-code)。

现货产品使用不同的专用类型 `LIMIT_MAKER`，含义同样是只能作为 Maker、不能立即撮合；本项目当前交易适配器不是 Spot 路径。官方定义见 [Spot API Glossary](https://developers.binance.com/en/docs/products/spot/faqs/spot_glossary)。Maker 功能暂列为待决策项，不在本轮实现或部署。

## 信号研究已从运行代码移除

按用户要求，iOS 已删除“信号研究”菜单、页面、Swift Charts 研究图表、DEBUG 数据及专属 UI 场景。后端已移除研究应用注册、`/v1/signal-research/` 路由、模型、管理后台、AI 请求、采集、规则、草稿、发布、回测与专属测试。旧接口不再解析，返回 404；`AI_*` 配置已停止读取。

凭证轮换命令只处理当前 API 绑定的 `api_key`、`secret_key`、`passphrase`，不再导入或查询研究模型。旧研究模型密文不在该命令的验证范围内；保留旧库备份时仍须保护对应的历史解密密钥。

## 迁移与历史资料

`server/signal_research/` 仅保留空包和历史 `migrations/`，不在 `INSTALLED_APPS` 中，也不提供运行模型或服务。本次不执行删表、删资料或删除 `django_migrations` 记录；已有数据库的研究表保留，新库不再创建研究表，因此无需新增数据库 migration。

退役前的源码与原规则可从整合版 Git 基线 `46fd475f1f143a74710b6a2191c0ccbb18478f0d` 的 `docs/research.md`、`server/signal_research/` 与 `frontend/ios-app/TradeTool/Features/USDT/USDTResearchViews.swift` 查询。本机删除前还在忽略目录 `.integration-runtime/removed-research-20261101.tar.gz` 保存了当前研究源码，包括原有未提交改动；该副本不随版本发布。

新库若回滚到退役前代码，必须使用该版本执行 migrate 补建研究表；旧库回滚仍需核对迁移记录和历史密钥。代码回滚不会恢复已主动删除的数据库资料。本次没有清理历史数据，也没有修改实盘持仓、保护或交易策略。

计划、问答及手动清单的删除前基线为整合版 Git `74b8e5da76544321e6d4960c0c7e646201a79828`；查询该版本的 `server/watch_plans/`、`USDTWatchViews.swift` 与 `USDTStrategyViews.swift`。普通发布不执行历史数据删除，代码回滚不代表数据库回滚。

验证入口为 [退役回归](../server/common/test_retired_modules.py)、[凭证轮换](../server/common/test_key_rotation.py) 与 [内部扫描](../server/market_analysis/tests.py)。本轮仅做编译、系统及迁移漂移检查，按用户安排未运行测试；旧通过记录不能当作本轮功能验收。
