# 整合版架构

当前数据流程与接口见 [整合说明](INTEGRATION.md)。本文维护模块边界；核对日期为 2026-11-01。

## 运行单元

| 单元 | 入口与责任 |
| --- | --- |
| API | `riskon.asgi` / Uvicorn：认证、业务 HTTP、鉴权 WSS |
| market | `manage.py market_stream`：独立 live 分发、ticker、收线存储／聚合、历史补全、6 个统计 worker、热窗口预热与心跳 |
| worker | `manage.py mobile_worker`：账户用户流、持久化命令、Inbox / Outbox 与对账 |
| scheduler | `manage.py run_scheduler`：已有订单保护、结算、资金及业务维护 |
| Redis | 热数据、PubSub、账户 lease、请求预算和心跳 |
| MySQL | 项目内独立 MySQL 8.4 服务、命名卷、`tradetools_integrated` schema 和受限用户 |
| iOS | SwiftUI 页面、Metal 图表、Keychain 会话、HTTP 与 WSS |

六个 Compose 服务及资源约束见 [整合 Compose](../compose.integrated.yaml)，均使用项目默认网络；MySQL / Redis 不发布宿主端口。47.80.22.243（首尔服务器）的宿主 Nginx 仅代理整合前缀，旧 Java 环境已退役，运行结构与迁移验证见 [运维](operations.md)。

## 后端模块

| 模块 | 责任 |
| --- | --- |
| `users` / `invites` | 登录、刷新、注册策略、密码与邀请码 |
| `api_bindings` | 账户模式、凭证加密、Key 指纹、绑定代际及能力校验 |
| `accounts` | 账户设置、资金归集、转账历史和操作日志入口 |
| `trading` / `positions` | 开仓请求、保护、策略、成交、对账和结算 |
| `market_stream` | 整合行情存储、聚合、采集、持久化后台补全任务与 WSS；历史 HTTP 只读本地快照，见 [行情](market-data.md) |
| `mobile` | 原生协议适配、命令、账户事件和用户隔离 |
| `watch_plans` | 观察计划、复盘、结果金额与评分 |
| `market_analysis` | 既有内部趋势扫描 |
| `common` | Binance REST、共享预算、加密、健康及告警 |

信号研究已从前后端运行代码移除，仅留历史 migration 与旧库资料，兼容边界见 [观察计划与研究退役](research.md)。

## 身份与事务

用户不等于交易所账户。账户模式、Key 指纹和绑定代际必须进入锁、幂等、缓存与订单归属。交易所订单按账户身份、symbol、订单 ID 识别；金额使用 Decimal。

命令按账户 lease / fence 串行执行，网络未知结果保留 UNKNOWN。状态落库与第三方交易所写入不能组成一个事务，恢复必须复用稳定身份和已确认事实。通知事件与独立投递状态保持分离。详细约束见 [交易安全](trading-safety.md)、[资金](capital-and-transfers.md) 和 [通知](signals-and-notifications.md)。

## 客户端边界

`Features/USDT/` 是整合后原生业务页面，`Features/Dashboard/`、`Chart/`、`ChartEngine/` 负责行情和图表。共享网络、认证、图表模型保留在 `Core/`。客户端提交原业务请求，持仓与命令状态以服务端对账为准。

行情连接先于账户资料刷新，图表只读取行情，点击下单入口后再刷新业务资料并进入原 USDT 表单。公共 K 线／ticker／补全就绪通过 Redis 主题筛选，账户事件保留原身份总线；live 缓存锁不覆盖数据库操作，补全通知仅在成功提交后发布。当前 Python 与 Redis 的进程边界继续保留；与原 USDC 的对照及发布兼容见 [行情](market-data.md)。
