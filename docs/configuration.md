# 整合版配置

核对依据为 [Django settings](../server/riskon/settings.py)、[整合 Compose](../compose.integrated.yaml)、[部署模板](../deploy/integrated/server.env.example) 和 iOS `Config/`。

## 配置入口

- 本地 Python 使用 [server/.env.example](../server/.env.example) 创建忽略的 `server/.env`。
- 47.80.22.243（首尔服务器）的配置保存在 `/opt/trade-tools-integrated/server.env`，发布目录通过链接读取；文件权限 600，保留现有值。
- Compose 的 `--env-file` 用于变量替换，`env_file: ./server.env` 将配置注入 Python 容器。
- iOS 使用 xcconfig 展开 `Info.plist` 的 `API_BASE_URL`；Debug、Debug-Seoul 与 Release 默认是 `https://47.80.22.243/integrated/`。运行时服务器选择可以覆盖默认值。

## 关键参数

| 参数 | 当前用途 |
| --- | --- |
| `SECRET_KEY` / `AES_SECRET_KEY` | 独立随机密钥，生产至少 32 字符且彼此不同；密码哈希与交易所凭证加密是两种机制 |
| `AES_PREVIOUS_SECRET_KEY` | 轮换窗口读取上一代密文，迁移和独立解密验证后清空 |
| `DEBUG` / `ALLOWED_HOSTS` | 生产关闭调试并明确主机，不能用通配符 |
| `DB_ENGINE` / `DB_*` | 47.80.22.243（首尔服务器）使用项目内独立 MySQL，`DB_HOST=mysql`；本地可用 SQLite |
| `MYSQL_ROOT_PASSWORD` | 仅用于独立 MySQL 的初始化和健康检查；与应用 `DB_PASSWORD` 分开生成并保留，变更 env 不会自动修改已有卷内密码 |
| `USE_REDIS_CACHE` / `REDIS_URL` | 共享缓存、账户锁、预算及心跳 |
| `MARKET_REDIS_URL` / `CACHE_KEY_PREFIX` | 整合行情分发与缓存命名空间 |
| `BINANCE_QUOTE_ASSET` | 整合环境默认 USDT，影响行情发现和订阅 |
| `MARKET_WS_URL` / `ACCOUNT_WS_URL` | `/market` 公共流和 `/private` 用户流，省略前缀可能握手后无数据 |
| `MARKET_WS_PROXY` | 本机开发显式代理；服务器直接连接 |
| `MARKET_WS_ATTEMPTS_PER_MINUTE` | 公共行情建连滚动 60 秒预算，默认且最多 30，可下调；自设保守值，不是币安官方额度 |
| `MARKET_WS_CONNECT_SPACING_SECONDS` | 公共行情相邻建连间隔，默认且最少 1 秒，可增大 |
| `MARKET_STREAM_ENABLED` / `ACCOUNT_STREAM_ENABLED` | 对应独立采集和账户流开关 |
| `RUN_SCHEDULER_IN_WEB` | 设为 false，调度仅由独立 scheduler 运行 |
| `MARKET_SNAPSHOT_PREWARM_ENABLED` | 整合环境关闭旧 Web CDN 预热 |
| `LEAD_TRADING_ENABLED` | 当前部署 false，带单新增风险保持关闭；存量保护边界见带单文档 |
| `AUTH_REFRESH_COOKIE_NAME` / `AUTH_REFRESH_COOKIE_PATH` | 整合会话 cookie 名称及 `/integrated/` 作用域 |
| `AUTH_REFRESH_COOKIE_SECURE` / `SESSION_COOKIE_SECURE` / `CSRF_COOKIE_SECURE` | 服务器 HTTPS 为 true，本地 HTTP 按开发环境配置 |
| `PUBLIC_APP_URL` / `CORS_ALLOWED_ORIGINS` | 当前公开入口及实际允许来源 |
| `INTEGRATED_BOOTSTRAP_EMAIL` / `INTEGRATED_BOOTSTRAP_PASSWORD` | 仅空用户库初始化管理员，不重置已有用户 |

Binance REST 请求预算由 `common/binance_rate_limit.py` 与 settings 管理；增加 worker 或缩短轮询不扩大交易所配额。保持保护 / 交易请求的预算优先级。

本轮新增上表两个公共连接守卫参数，缺省即启用，无新增必填凭证；后续客户端诊断另有 `market_stream.0003_chartloadreport` 迁移，见下文。`collector.py` 仍为历史任务 1 路、统计 6 路，启动和每 5 分钟按容量预热；收线缓冲上限 10,000。`service.HOT_WINDOW_SIZE` 定义窗口，本地已统一上限 1500 根，与 HTTP 单页相同；47.80.22.243（首尔服务器）已随 `7daa362` 同步为 1500，发布状态见 [构建 13／14 排查](market-data.md#构建-1314-速度回退排查2026-11-01)。`history_cache.py` 仍限 64 窗、每窗压缩后最多 256 KiB、TTL 300 秒，不改共享 Redis 的 80 MB / noeviction。冷读增加 300 ms 锁竞争预算和 10 秒 owner lease；上游冷却、轮换及共享预算失败处理见 [行情](market-data.md#读取协调与出口保护2026-11-01本地)。同出口其他应用不共享 Redis／key prefix 时仍会消耗总额度，应核对实际出口并预留配额。`MARKET_SNAPSHOT_PREWARM_ENABLED` 仍只控制旧 Web CDN，v2 主题及 API / market 配套发布边界不变。

## 可选能力

SMTP 的 `EMAIL_*`、通知的 `TRADE_NOTIFICATION_*` / `EXTERNAL_TRADE_SIGNAL_*` / `MARKET_ANALYSIS_ALERT_*` / `OPS_ALERT_*` 按真实服务地址配置。当前仓库不再包含旧 webhook 容器；保留业务接口不代表外部服务已接通。整合环境尚未配置的能力见 [已知事项](known-issues.md)。

交易所凭证经 AES-GCM 加密落库。轮换先发布兼容代码，再配置上一代密钥、迁移并验证当前 API 绑定密文，最后移除上一代密钥。数据库备份应配套保护解密密钥，不能仅替换当前密钥。

变更配置应同时核对代码读取位置、容器注入、重建需求和回退方法；源码配置不等同于线上状态。实际运行验收见 [变更记录](changes.md)。

注册开关使用数据库 `SystemSetting.open_registration`，不在 env 中；47.80.22.243（首尔服务器）于 2026-11-01 按用户授权开启，管理员可关闭。操作和最后验证见 [运维](operations.md#注册开关)，客户端继续读取实际状态。

信号研究退役后不再读取 `AI_PROVIDER`、`AI_BASE_URL`、`AI_API_KEY`、`AI_MODEL`、`AI_TIMEOUT_SECONDS`。凭证轮换不再处理旧研究表中的模型密钥；历史备份和回滚的密钥边界见 [研究退役](research.md)。

## 图表诊断固定边界

本轮不新增 env 或外部日志服务。`market_stream/diagnostics.py` 限制正文 24 KiB、每用户 180 次／小时、约 5000 条全局容量；`prune_reports` 由行情每小时维护调用，单轮最多 500 条、七天过期且容量达到 4500 时提前淘汰。客户端每次加载最多 64 事件／8 请求／每请求 3 个网络 metrics，40 秒超时，异步上报每次 5 秒、最多两次。详细协议、挂起／缓存及丢失边界见 [行情](market-data.md#客户端加载诊断本地实现尚未分发)，发布与只读查询见 [运维](operations.md#图表加载诊断)。
