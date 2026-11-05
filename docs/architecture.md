# 整合版架构

当前数据流程与接口见 [整合说明](INTEGRATION.md)。本文维护模块边界；运行单元与分发边界于 2026-11-06 复核，其余按各节日期区分。

## 运行单元

| 单元 | 入口与责任 |
| --- | --- |
| API | `riskon.asgi` / Uvicorn：认证、业务 HTTP、鉴权 WSS；每事件循环共享 Redis 接收／解码，向独立连接队列分发（2026-11-06 本地） |
| market | `manage.py market_stream`：独立 live 分发、ticker、收线存储／聚合、历史补全、6 个统计 worker、热窗口预热与心跳 |
| worker | `manage.py mobile_worker`：账户用户流、持久化命令、Inbox / Outbox 与对账 |
| scheduler | `manage.py run_scheduler`：已有订单保护、结算、资金及业务维护 |
| Redis | 热数据、PubSub、账户 lease、请求预算和心跳 |
| MySQL | 项目内独立 MySQL 8.4 服务、命名卷、`tradetools_integrated` schema 和受限用户 |
| iOS | SwiftUI 页面、Metal 图表、Keychain 会话、HTTP 与 WSS |
| HarmonyOS | 独立 ArkTS／ArkUI 工程、Canvas、Asset Store、同一 HTTP／WSS；已编译未签名 HAP，签名／真机待验 |

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
| `market_analysis` | 既有内部趋势扫描 |
| `common` | Binance REST、共享预算、加密、健康及告警 |

看盘计划、专用校准问答、手动开仓理由／指标校验和信号研究已从运行代码移除，数据库历史资料和 migrations 保留，兼容边界见 [功能退役](research.md)。

## 身份与事务

用户不等于交易所账户。账户模式、Key 指纹和绑定代际必须进入锁、幂等、缓存与订单归属。交易所订单按账户身份、symbol、订单 ID 识别；金额使用 Decimal。

命令按账户 lease / fence 串行执行，网络未知结果保留 UNKNOWN。状态落库与第三方交易所写入不能组成一个事务，恢复必须复用稳定身份和已确认事实。通知事件与独立投递状态保持分离。详细约束见 [交易安全](trading-safety.md)、[资金](capital-and-transfers.md) 和 [通知](signals-and-notifications.md)。

## 客户端边界

`Features/USDT/` 是整合后原生业务页面，`Features/Dashboard/`、`Chart/`、`ChartEngine/` 负责行情和图表。共享网络、认证、图表模型保留在 `Core/`。客户端提交原业务请求，持仓与命令状态以服务端对账为准。

行情连接先于账户资料刷新，图表只读取行情，点击下单入口后再刷新业务资料并进入原 USDT 表单。公共 K 线／ticker／补全就绪通过 Redis 主题筛选，账户事件保留原身份总线；live 缓存锁不覆盖数据库操作，补全通知仅在成功提交后发布。当前 Python 与 Redis 的进程边界继续保留。2026-11-06 本地新增 API 共享接收器，主题按连接引用合并，逐连接鉴权及有界发送保留；Redis 故障仍关闭连接并由客户端重连恢复，最后连接退出／ASGI shutdown 释放资源。采集与 API 完整同进程尚未实现，决策与 USDC 取舍见 [行情](market-data.md#api-共享行情分发器2026-11-06本地)。

2026-11-01 本地进一步统一 iOS 最新快照任务，分页单独按边界读取；`ChartDataPipeline` actor 独占同步 `CandleStorage`，避免状态修改跨 actor 悬停，相同历史复用不可变对象与指标。后端冷读使用有界窗口锁／Redis owner lease；公共上游建连由 Redis 共享准入，行情 REST 显式要求共享预算，交易调用保留原降级规则。该轮尚未发布，阈值、共享出口边界及验收见 [行情](market-data.md#读取协调与出口保护2026-11-01本地)。

鸿蒙工程位于 `frontend/harmony-app/`，业务核心与鸿蒙平台适配分离，共用后端的认证、持久化交易命令和资金状态机。首次真实编译与未签名 HAP 打包已通过，调试签名、Mate 80 安装与全量页面对照尚未完成；当前覆盖及身份协议限制见 [鸿蒙客户端](harmony-client.md)。

## 后端扫描与主链瘦身（2026-11-02，本地）

本轮以当时工作区扫描 294 个 Python 文件，其中运行代码 148 个文件、约 28,672 行；覆盖应用注册、URL、调度任务、交易所请求入口、测试与辅助函数引用。账户事件、连接恢复、投递及行情预热做调用链审阅；其余模块做结构和引用扫描。已退役的研究／计划空包与历史 migrations 仍承担兼容职责，保留规则见 [功能退役](research.md)。

按“主链收益大、范围小”落实四项：私有流复用共享建连守卫并增加退避／错峰；纯余额事件仅更新事实和通知；公私事件共用 Lua 有序发布、Outbox 投递状态批量更新；原生采集开启时不注册旧 Web K 线预热，未启用的 CDN 预热也不注册。无需新依赖、表结构或 HTTP 协议；关键保护、策略、结算及资金路径继续原职责。连接实现和剩余容量边界统一见 [行情实施进度](market-data.md#websocket-优先与多用户容量评估2026-11-02部分已实现)。

清理只删除经源码／测试／路由引用检查确认无调用的 `_step_digits`、`_ts_to_iso`、`_place_stop_loss_verified`、`_strategy_level_reached`，以及已由批量发布完整替代的 `bus.event`／`bus.publish` 两步入口；已有实际止损与止盈实现保留。

后续最有价值的方向是账户读取快照及统一补差、事件与 scheduler 的重复读取协调、客户端浮窗和资料的局部刷新。`trading/views.py`、`positions/views.py`、`common/binance.py` 仍偏大，后续可按纯序列化／查询／适配边界逐段提取，需以各段调用者和回归为依据。本轮没有拆交易状态机、删除兼容接口或历史数据，也未给出支持人数；仅本地验证，范围见 [开发](development.md#后端主链瘦身回归2026-11-02)。

## Python 与 Java 的性能判断（2026-11-01）

公共行情已经由后端共享，私有账户流按有效绑定维持连接。2026-11-02 的评估及部分主链修改统一维护在 [WebSocket 优先与多用户容量评估](market-data.md#websocket-优先与多用户容量评估2026-11-02部分已实现)。账户读取快照及统一容量验证仍待实施，尚未给出压测人数。

当前运行的是 CPython 3.11，API 为单 Uvicorn worker，market／worker／scheduler 独立进程。CPU 密集的纯 Python 聚合、JSON 构建与压缩受 GIL 和解释执行成本影响；同进程增加线程不等于多核执行 Python 计算，但线程／async 适合并发等待网络和数据库，见 [Python 3.11 threading](https://docs.python.org/3.11/library/threading.html)。Java 通常更适合持续 CPU 计算及多核并行；原 USDC 已使用按 pair 的虚拟线程消费。虚拟线程本身主要改善等待型并发的吞吐，不会使一次计算自动更快，见 [Oracle 虚拟线程](https://docs.oracle.com/en/java/javase/21/core/virtual-threads.html)。这些是运行机制判断，不是本项目同条件基准。

本项目此前秒级首屏的已确认根因是多读 3000 根分钟线、未压缩响应及通知取消下载。范围修复后的后端处理样本为 42.69 ms；1500 根压缩后约 66 KB。不能从 Java 原版更流畅直接推导“换语言即可恢复半秒”，也不能承诺 Python／Java 的固定倍数。原版 Java 缺历史时还会在 HTTP 内同步补 Binance 数据，当前 Python 将补线与统计放到后台，在上游变慢时具有不同的取舍。

当前建议保留 Python 交易主体与独立行情边界，先依据端到端 P95、缓存命中率、事件积压及 CPU 数据优化。若目标并发下证实 market／API 的 CPU 饱和，再评估 API 多进程或独立行情服务；复制 collector 前必须设计唯一写入者／租约、聚合顺序与预算，不能直接启动多个采集实例。当前单机、单 MySQL／Redis 和单 collector 没有提供高可用保证。详细代码评估与待办见 [行情评估](market-data.md#性能与可替换性评估2026-11-01)。本次只记录判断，没有改进程数量或交易规则。
