# 项目架构

> 整合版说明（2026-10-31）：本文保留来源系统的业务或实现资料。当前运行入口、服务器、原生页面与验证边界以 [整合说明](INTEGRATION.md)、[运维](operations.md) 和 [变更](changes.md) 为准；Java 模块仅作参考。


核对日期：2026-09-11。本文负责结构和模块入口，业务细则由对应主题文档维护。

## 技术栈与运行单元

| 层 | 当前实现 | 依据 |
| --- | --- | --- |
| 前端 | React 18、TypeScript、Vite 6、Vitest 4、Tailwind 4；Zustand、TanStack Query、Axios；Lightweight Charts 5 | [package.json](../tools/package.json)、[App.tsx](../tools/src/app/App.tsx) |
| API | Python 3.11 镜像；Django 5.2.17、DRF 3.17.2、SimpleJWT；Gunicorn | [依赖锁定](../server/requirements.txt)、`docker/server/Dockerfile`（来源路径，未随本整合交付） |
| 调度 | 独立 APScheduler 进程，不在每个 Web worker 中启动 | [scheduler.py](../server/trading/scheduler.py) |
| 持久化 | MySQL 8.4；Redis 7 提供共享缓存、锁、心跳 | [Compose](../docker-compose.yml) |
| 网关与通知 | 宿主机 Nginx + 容器 Nginx；独立 Python webhook 服务 | `docker/nginx/default.conf`（来源路径，未随本整合交付）、`docker/tradingview/app.py`（来源路径，未随本整合交付） |

Compose 共六个服务：`frontend`、`backend`、`scheduler`、`tradingview-webhook`、`mysql`、`redis`。`tradingview-webhook` 是兼容命名，目前承担外部信号接收、企业微信等通知转发；旧 TradingView 输入已退役。

```text
浏览器 -- HTTPS --> 主站 CDN --> 宿主机 Nginx --> frontend Nginx
                                                   |-- 静态资源 / SPA
                                                   |-- /api、/v1 --> backend --> MySQL / Redis
                                                   |-- /webhook/external --> webhook --> backend
合作方 -- HTTPS -----------------------------------|                       |--> 企业微信

浏览器 -- WSS --> stream.ba.wow211.com 宿主机隔离站点 --> Binance 公共 K 线
scheduler --> 状态对账 / 策略 / 结算 / 通知投递 / 历史同步 / 行情预热
```

WS 域名只代理公开行情，不承载账户和交易 API。公共历史快照与账户私有数据的缓存规则必须分离，详见 [行情文档](market-data.md)。

## 后端边界

| 模块 | 责任及主要入口 |
| --- | --- |
| `users` / `invites` | 注册、登录、刷新 cookie、密码重置、邀请码 |
| `api_bindings` | 每用户每模式一绑定、AES-GCM 凭证加密、Key 指纹、绑定代际、账户上下文、Binance 能力校验与确定性凭证故障熔断；[context.py](../server/api_bindings/context.py)、[services.py](../server/api_bindings/services.py) |
| `accounts` | 账户资料、止损金额设置、归集目标、转账历史及只读操作日志入口；[transfer_history.py](../server/accounts/transfer_history.py)、[operation_log_views.py](../server/accounts/operation_log_views.py) |
| `trading` | 开仓请求、限价单、行情、资金预检与规范化；[services.py](../server/trading/services.py)、[execution.py](../server/trading/execution.py)、[balance_cap.py](../server/trading/balance_cap.py) |
| `positions` | 仓位生命周期、保护单、止盈减仓、结算、事件通知；[lifecycle.py](../server/positions/lifecycle.py)、[notifications.py](../server/positions/notifications.py) |
| `market_analysis` | 内部趋势扫描和状态；[trend.py](../server/market_analysis/trend.py)，不是旧市场分析 HTTP 页面 |
| `signal_research` | 用户样本、策略定义、显式 AI 生成和回测；[services.py](../server/signal_research/services.py) |
| `watch_plans` | 用户观察计划、复盘和评分 |
| `common` | Binance 客户端、跨进程请求预算、响应、加密工具、健康和运维告警；[binance.py](../server/common/binance.py)、[binance_rate_limit.py](../server/common/binance_rate_limit.py) |

视图负责权限、参数和响应；交易状态转换保持在现有业务服务中。跨模块新增功能优先复用已有入口，避免在多个页面、调度任务和通知模块各写一份交易规则。

## 数据归属与身份

- 用户是应用账户，不等于交易所账户。`ApiBinding` 按 `(user, trading_mode)` 唯一；不可变 `TradingAccountContext` 从有效绑定派生模式、Key 指纹、绑定代际和稳定命名空间，账户缓存、锁与幂等不能只用 Web 用户 ID。
- 市价开仓、限价开仓和追单一次性取得 `TradingAccountContext`，并统一通过 `entry_guard.py` 获取账户活动锁、开仓提交锁及复核绑定代际；具体订单计算和成交接管仍保持独立，不能重新在各视图拼装 Key、指纹和锁。
- 交易所订单使用 `(api_key_fingerprint, symbol, binance_order_id)` 识别；旧数据保留用户范围内兼容处理，不能仅凭订单数字跨币种查询。
- `TradeOpenRequest` 记录幂等开仓请求；`Order` / `LimitOrder` 记录订单和保护、成交、策略快照；本地数据库必须与交易所实际状态对账。
- 外部手动仓复用 `Order.position_origin=exchange_external`，活动唯一键及两个 JSON 请求记录分别保存接管身份、止损与平仓恢复信息；不伪造开仓订单号。[external_positions.py](../server/trading/external_positions.py) 负责发现、保护及关闭，旧策略、费用和结算管理排除该来源。此功能 2026-09-30 已随 `85d47b0` 发布，扫描任务已启用；细则见 [交易安全](trading-safety.md#外部手动仓位强制保护)，线上验收范围见 [变更记录](changes.md)。
- `CapitalSweep` 保存绑定 Key 指纹和分阶段归集进度；一个用户同时只允许一个活动归集槽位。相同 Key 重绑可复用同一指纹范围，不同 Key 不能接管旧 Key 留下的未知结果。
- 转账历史和同步游标按用户 + Key 指纹隔离；信号消息按 `(source, event_id)` 去重。
- `TradeNotificationEvent` 是通知事件；`ExternalTradeSignalDelivery` 是独立渠道投递状态，不能用“交易成功”代替“发送成功”。平仓归因事件先于保护清理持久化，减仓投影与事件原子提交；网络投递始终位于交易状态事务之外。
- `TradeOperationLog` 保存关键操作过程，日志失败不改变交易执行；[operation_logs.py](../server/positions/operation_logs.py) 只读汇总新日志、已有策略与成交事件。页面、身份、状态及历史覆盖边界见 [交易操作日志](operation-logs.md)；此功能 2026-09-30 已随 `85d47b0` 发布，线上验收范围见 [变更记录](changes.md)。
- 研究样本、策略和模型选择属于用户；`ResearchAiModel` 模型目录全局共享，密钥加密存储。详见 [研究文档](research.md)。

## 并发与故障边界

- API 绑定变更和通用交易所写装饰器先获取 Web 用户级生命周期锁，再获取由交易账户身份派生的活动锁。开仓、限价、追单与归集使用专用活动锁并在锁内复核绑定代际 / Key 指纹；它们不在活动锁内反向获取生命周期锁。该无反向嵌套规则是全局约束。
- 交易所写请求、数据库状态和第三方网络无法组成分布式事务。代码对交易写入使用稳定身份恢复，对资金写入保存阶段并严格查历史，对通知使用本地事件 / 投递记录；三类未知结果不得互相套用补偿规则。

## 带单模式接入门槛

带单模式不是在现有视图中增加 `if mode == ...`。满足以下条件后才能开放模式分支和前端切换：

1. 普通交易与带单交易先解析为明确的账户模式和专用交易所适配器，再进入共享的锁、幂等、成交、保护及通知服务。
2. 市价开仓、限价开仓、追单、撤单、平仓、减仓和保护单操作都有适配器契约测试；普通模式的请求路径和响应保持兼容。
3. 模式必须进入账户身份、锁键、幂等键、订单归属和缓存命名空间，两个模式不能接管彼此的订单。
4. 带单接口的部分成交、结果未知、限频、止损失败及恢复语义已用 Binance 官方接口契约核对并有故障测试。
5. MySQL 活动流水唯一约束和 Redis 跨进程账户锁 / IP 请求预算的隔离测试实际通过，不只依赖 SQLite 和单进程缓存。

2026-09-11 已实现双绑定、模式化身份、专用能力适配器和前端切换，并实际通过 MySQL / Redis 隔离并发验收。带单与普通共用交易服务，前三类关键后台任务分模式批次和线程池，其他维护仍共享资源。功能范围、真实组合 Key 的身份局限和回退约束统一维护在 [带单模式](lead-trading.md)，上线结果见 [变更记录](changes.md)。
- Redis 为跨 worker 锁、限频和心跳的生产依赖。限频观测失效时保护请求按可用性优先降级；认证登录的 IP 限频同样会降级，残余风险见 [已知事项](known-issues.md)。

## 路由地图

后端真实路由以 [riskon/urls.py](../server/riskon/urls.py) 及各模块 `urls.py` 为准。生产 `/api/*` 由 Nginx 改写到 `/v1/*`。本地 Vite 同时代理 `/api` 和 `/v1`，`/api` 会改写为 `/v1`；代理目标由 `DEV_API_PROXY_TARGET` 指定，详见 [开发环境](development.md)。

| 路径前缀 | 用途 |
| --- | --- |
| `/v1/auth/`、`/v1/api/` | 认证、API 绑定 |
| `/v1/account/` | 账户与转账历史 |
| `/v1/trade/` | 开仓、委托、资金预检、行情和信号读取 |
| `/v1/position/`、`/v1/strategy/` | 持仓、历史与订单策略 |
| `/v1/watch-plan/`、`/v1/signal-research/` | 观察计划和信号研究 |
| `/v1/health` | 数据库、迁移、scheduler 深度健康 |
| `/market-data/klines/<SYMBOL>/<interval>.json` | 匿名、有限参数的公共历史快照 |
| `/webhook/external` | 独立鉴权的外部信号接入 |

不存在当前可用的 `/v1/market-analysis` 页面 API。原 `doc/openapi.yaml` 混有 OKX 和旧认证契约，已退出当前契约；不应据此生成客户端。两份合作方协议见 [目录](README.md)。

## 后台任务

下表为代码设定周期，部分任务带错峰、抖动和内部节流，不是精确实时承诺。全部任务注册见 [scheduler.py](../server/trading/scheduler.py)。

| 周期 | 任务 |
| --- | --- |
| 2 秒 | 唤醒行情预热；按周期判断哪些组合到期，非全量每 2 秒请求 |
| 5 秒 | 限价订单同步、交易通知投递 |
| 10 秒 | 策略引擎、Web 订单保护对账、外部手动仓发现与强制保护 |
| 15 秒 | scheduler 心跳，Redis 有效期 60 秒 |
| 30 / 45 秒 | 陈旧未平仓记录修正 / 已平仓结算补偿 |
| 60 秒 | 开仓真实手续费补齐、内部趋势扫描 |
| 90 / 180 秒 | 已结束订单残留挂单补偿 / 异常平仓巡检 |
| 10 分钟 | 清理信号消息，消息仅保留最近 3 天 |
| 30 分钟 | 只读资金检查及提醒，不自动划转 |
| 每日 00:10，北京时间 | 转账历史增量入库 |

后台并非无副作用的演示进程：有些任务会管理真实保护单和仓位。开发环境不应接入生产凭证启动 scheduler。

各业务任务入口与退出 `finally` 统一调用 Django `close_old_connections()`，让复用线程丢弃过期或已失效的连接；不为每个任务另建重试框架。Redis 心跳保持轻量，只证明调度进程仍在运行，不能证明数据库业务任务成功，排障须结合任务日志。

持仓列表以一次数据库查询返回每仓当前策略快照的 `latest_strategy_error`，无异常为空字符串；恢复后的再次失败必须保留。完整策略日志由详情按需读取，持仓页不再每 15 秒逐仓拉取完整日志。策略列表复用已预取的层级默认排序，避免再次排序触发逐策略查询。

持仓历史在数据库统计和截取已关闭记录，只为最终当前页组装财务明细。活动减仓按已有数量 / 减仓事件证据发现；缺少证据的旧记录只探查交易所当前活动方向。按实际成交时间和订单 ID 与关闭记录窗口合并，保持原 `items` / `pagination` 响应，不设任意数量截断或丢失跨页记录。活动投影仍需读交易所证据，其成本不随全部已关闭历史增长。
