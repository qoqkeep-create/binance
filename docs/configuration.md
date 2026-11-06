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
| `MARKET_WS_ATTEMPTS_PER_MINUTE` | 建连滚动 60 秒预算，默认且最多 30，可下调；已发布版本用于公共行情，2026-11-02 本地扩为公共＋私有共用；自设保守值，不是币安官方额度 |
| `MARKET_WS_CONNECT_SPACING_SECONDS` | 相邻建连间隔，默认且最少 1 秒，可增大；本地公共／私有流共用 |
| `MARKET_STREAM_ENABLED` / `ACCOUNT_STREAM_ENABLED` | 对应独立采集和账户流开关；本地原生采集开启时 scheduler 不再注册旧 Web K 线预热，关闭原生采集可保留旧预热 |
| `RUN_SCHEDULER_IN_WEB` | 设为 false，调度仅由独立 scheduler 运行 |
| `MARKET_SNAPSHOT_PREWARM_ENABLED` | 整合环境关闭旧 Web CDN 预热；本地关闭时不再注册空转调度任务 |
| `LEAD_TRADING_ENABLED` | 当前部署 false，带单新增风险保持关闭；存量保护边界见带单文档 |
| `AUTH_REFRESH_COOKIE_NAME` / `AUTH_REFRESH_COOKIE_PATH` | 整合会话 cookie 名称及 `/integrated/` 作用域 |
| `AUTH_REFRESH_COOKIE_SECURE` / `SESSION_COOKIE_SECURE` / `CSRF_COOKIE_SECURE` | 服务器 HTTPS 为 true，本地 HTTP 按开发环境配置 |
| `PUBLIC_APP_URL` / `CORS_ALLOWED_ORIGINS` | 当前公开入口及实际允许来源 |
| `INTEGRATED_BOOTSTRAP_EMAIL` / `INTEGRATED_BOOTSTRAP_PASSWORD` | 仅空用户库初始化管理员，不重置已有用户 |

Binance REST 请求预算由 `common/binance_rate_limit.py` 与 settings 管理；增加 worker 或缩短轮询不扩大交易所配额。保持保护 / 交易请求的预算优先级。

2026-11-01 新增上表两个公共连接守卫参数，缺省即启用，无新增必填凭证；后续客户端诊断另有 `market_stream.0003_chartloadreport` 迁移，见下文。`collector.py` 仍为历史任务 1 路、统计 6 路，启动和每 5 分钟按容量预热；收线缓冲上限 10,000。`service.HOT_WINDOW_SIZE` 定义窗口，本地已统一上限 1500 根，与 HTTP 单页相同；47.80.22.243（首尔服务器）已随 `7daa362` 同步为 1500，发布状态见 [构建 13／14 排查](market-data.md#构建-1314-速度回退排查2026-11-01)。`history_cache.py` 当时限 64 窗、每窗压缩后最多 256 KiB、TTL 300 秒，不改共享 Redis 的 80 MB / noeviction（两项均已于 2026-11-06 调整，见下段）。冷读增加 300 ms 锁竞争预算和 10 秒 owner lease；上游冷却、轮换及共享预算失败处理见 [行情](market-data.md#读取协调与出口保护2026-11-01本地)。同出口其他应用不共享 Redis／key prefix 时仍会消耗总额度，应核对实际出口并预留配额。`MARKET_SNAPSHOT_PREWARM_ENABLED` 仍只控制旧 Web CDN，v2 主题及 API / market 配套发布边界不变。

2026-11-06 首屏提速调整（本地实现，未部署）：`history_cache.MAX_WINDOWS` 64→192（单窗 256 KiB、TTL 300 秒不变）；`compose.integrated.yaml` Redis `maxmemory` 80mb→256mb、`mem_limit` 128m→320m，仍 `noeviction`＋AOF，部署需重建 redis 容器。`/api/market/klines` 压缩从 Django `@gzip_page` 移交宿主 nginx（`deploy/integrated/nginx-location.conf` 内 `gzip on / gzip_proxied any / gzip_comp_level 5 / gzip_types application/json / gzip_vary on`），部署时必须同步该 snippet，否则响应暂为未压缩。首屏 stale／缺口的请求内同步补齐无新增 env，约束为代码内固定常量：一页 ≤1500 根、4 秒超时、每 symbol／interval 30 秒冷却、normal 优先级预算、上游冷却期跳过。详见 [行情](market-data.md#首屏同步补齐与传输调整2026-11-06-本地)。

## 可选能力

2026-11-02 的后端主链修改复用以上开关及建连参数，没有新增必填配置；设置名称和 Redis 准入键保持兼容。共享预算限制的是建连尝试，并非同时在线连接总量；部署须配套更新 market／worker 代码，仍需盘点同出口其他进程。账户 lease 续租在等待准入期间继续；Redis 不可用时暂缓新增连接，已有健康连接按原生命周期运行，独立交易维护保持原职责。仅本地状态及验证见 [行情实施进度](market-data.md#websocket-优先与多用户容量评估2026-11-02部分已实现)。

仓位事件通知总开关为 `TRADE_NOTIFICATION_ENABLED`（源码默认 true，整合模板显式 false），同时控制内部通知及合作方的 dispatcher／直接发送；`EXTERNAL_TRADE_SIGNAL_ENABLED` 为合作方渠道的独立开关。2026-11-03 16:14 已在 47.80.22.243（首尔服务器）将两者显式设为 false 并加载到 API／scheduler。关闭保留事件及队列状态、不继续投递或重试；重新启用前须检查积压，见 [暂停规则](signals-and-notifications.md#仓位事件通知暂停2026-11-03)。普通信号 APNs 和独立浮盈通知配置不受该开关控制。内部仓位适配已改为仅移交 App outbox，旧 `TRADE_NOTIFICATION_URL/TOKEN/TIMEOUT_SECONDS` 不再用于普通通知发送；已排队的交易 App 投递也遵守总暂停开关。

SMTP 的 `EMAIL_*`、通知的 `EXTERNAL_TRADE_SIGNAL_*` / `MARKET_ANALYSIS_ALERT_*` / `OPS_ALERT_*` 按真实服务地址配置。当前仓库不再包含旧 webhook 容器；`MARKET_ANALYSIS_ALERT_*` 仅为兼容保留，2026-11-03 上线的内部信号扫描不再依赖该出口，保留业务接口不代表外部服务已接通。整合环境尚未配置的能力见 [已知事项](known-issues.md)。

交易所凭证经 AES-GCM 加密落库。轮换先发布兼容代码，再配置上一代密钥、迁移并验证当前 API 绑定密文，最后移除上一代密钥。数据库备份应配套保护解密密钥，不能仅替换当前密钥。

变更配置应同时核对代码读取位置、容器注入、重建需求和回退方法；源码配置不等同于线上状态。实际运行验收见 [变更记录](changes.md)。

注册开关使用数据库 `SystemSetting.open_registration`，不在 env 中；47.80.22.243（首尔服务器）于 2026-11-01 按用户授权开启，管理员可关闭。操作和最后验证见 [运维](operations.md#注册开关)，客户端继续读取实际状态。

信号研究退役后不再读取 `AI_PROVIDER`、`AI_BASE_URL`、`AI_API_KEY`、`AI_MODEL`、`AI_TIMEOUT_SECONDS`。凭证轮换不再处理旧研究表中的模型密钥；历史备份和回滚的密钥边界见 [研究退役](research.md)。

## 图表诊断固定边界

本轮不新增 env 或外部日志服务。`market_stream/diagnostics.py` 限制正文 24 KiB、每用户 180 次／小时、约 5000 条全局容量；`prune_reports` 由行情每小时维护调用，单轮最多 500 条、七天过期且容量达到 4500 时提前淘汰。客户端每次加载最多 64 事件／8 请求／每请求 3 个网络 metrics，40 秒超时，异步上报每次 5 秒、最多两次。详细协议、挂起／缓存及丢失边界见 [行情](market-data.md#客户端加载诊断)，发布与只读查询见 [运维](operations.md#图表加载诊断)。

## HTTPS 传输配置

2026-11-01 在 47.80.22.243（首尔服务器）按实际 iPhone 的单目的地址对照结果，已将宿主 `net.ipv4.tcp_congestion_control` 设为 `bbr`。模板为 [模块加载](../deploy/integrated/network-modules.conf)与 [sysctl](../deploy/integrated/network-sysctl.conf)，分别安装到 `/etc/modules-load.d/tradetools-integrated-network.conf` 和 `/etc/sysctl.d/99-tradetools-integrated-network.conf`。这是宿主网络命名空间的默认算法，不是 Django env 或 Binance 限频配置；既有连接不作为新算法已生效的验证依据。

当前 `fq_codel` 未改变，四个正在运行的 Python 容器默认值仍为 CUBIC；新连接已实测 BBR，持久文件哈希与本地模板相同。未重启宿主，不能声称已验证重启恢复；新主机、容器重建及后续网络配置变更应再次核对实际命名空间和连接。应用、回退与验证范围见 [运维](operations.md#https-传输拥塞控制2026-11-01)。

## MySQL 容器内存

`compose.integrated.yaml` 将 MySQL 内存上限固定为 1 GiB、内存加 swap 总上限 2 GiB，buffer pool 仍为 128 MiB、最大连接数 100。47.80.22.243（首尔服务器）已在线应用同等限额；旧 512 MiB 导致持续回收和接口超时，现场数据及恢复验证见 [运维](operations.md#mysql-内存限额与压力恢复2026-11-01)。这些是容器资源配置，不是 env 或交易所参数；后续发布／代码回滚保持足够限额，避免恢复旧值。较长时间和更高并发的容量仍待观察。

## iOS 信号和浮盈通知

本轮新增可选配置，默认全部关闭；模板为 [server.env.example](../deploy/integrated/server.env.example)，消息口径及重试见 [通知](signals-and-notifications.md)。

| 参数 | 用途 |
| --- | --- |
| `APNS_ENABLED` | 内部信号及普通仓位通知生成 App APNs 投递，默认 false；仓位另受总开关控制 |
| `LIVE_ACTIVITIES_ENABLED` | ActivityKit 持仓卡片注册与独立调度，源码及模板默认 false；另需 `APNS_ENABLED=true`，不控制普通信号或浮盈通知 |
| `EXTERNAL_SIGNAL_INGEST_ENABLED` | 旧 HTTP 信号入站总开关，默认 false；暂停所有自报来源，内部扫描直接入库不受影响 |
| `APNS_TEAM_ID` / `APNS_KEY_ID` | 原 Apple 团队及 APNs 签名 Key 标识 |
| `APNS_KEY_PATH` | scheduler 内的受限 p8 路径，模板 `/run/tradetools-secrets/AuthKey.p8` |
| `APNS_SECRET_DIRECTORY` | Compose 只读挂载来源，模板 `/opt/trade-tools-integrated/secrets` |
| `APNS_BUNDLE_ID` | 固定为整合应用 `com.waibao2025.trade.integrated`，注册及 topic 需匹配 |
| `POSITION_PROFIT_CALL_ENABLED` | 原 USDT 浮盈 Echobell 监控／投递，默认 false |
| `POSITION_PROFIT_CALL_USER_ID` | 整合数据库中的接收用户，默认 0；迁移时按身份核对，不能照搬旧库主键 |
| `POSITION_PROFIT_CALL_URL` | 既有 Echobell 通道，浮盈和保证金共享，仅存受限环境文件 |
| `POSITION_MARGIN_CALL_ENABLED` | 独立保证金 Echobell 后台检查，默认 true；复用上述指定用户／通道，用户 0 时不工作，严格 >75% 的持仓账户触发；本轮源码尚未部署 |
| `SIGNAL_ECHOBELL_ENABLED`（已退役） | 2026-11-03 起普通信号固定只走 App APNs，旧环境即使保留 true 也不入队／发送 Echo；浮盈仍由独立开关控制 |

p8 只挂载到 scheduler，不进入镜像或 Git；部署前创建来源目录，限制目录访问并确保容器 UID 10001 可读该文件，例如通过专用所有者／组和文件 0400／0440 权限。不能用向所有用户开放私钥的方式修权限。APNs 的 Key 可属于既有团队，但 topic、描述文件和客户端签名环境必须对应整合应用。

保证金监控另需新增 `positions.0030_position_margin_alerts`，不修改已有订单／资金表。它与浮盈共用通道冷却但开关独立，迁移与上线规则见 [通知](signals-and-notifications.md#保证金-echobell-与-app-币种导航2026-11-06本地)。本轮未变更任何运行环境或通道凭证。

完整 App／浮盈通知部署需先应用 `mobile.0002` 与 `positions.0029` 两个仅新增模型的 migration；仅 App 注册／派发限定包只依赖已应用的 `mobile.0002`，不加载浮盈模型和任务。回滚到旧代码可以保留新增表，代码回滚不还原数据库，也不重放已尝试通知。

2026-11-02 已按用户提供的 Echo 地址和原 iOS 项目的 APNs 签名材料，将这批配置准备到 47.80.22.243（首尔服务器）。环境文件保持 0600，p8 为 UID 10001／0400，来源目录 0700；APNs topic 使用整合应用标识，旧项目文件保持只读。开关在受限配置文件中已设为开启。2026-11-03 最初信号限定发布只包含排队和 `mobile.0002`；15:22 的 App 通知限定发布已补齐注册路由、HTTP2、每 10 秒的普通通知 dispatcher 和 scheduler 的 p8 只读挂载。浮盈扫描／Echobell 任务仍未启用；配置文件的开启不等于任务已运行。现有 APNs key 原为仅授权旧 App 的 topic-specific key；仅团队匹配不足以允许整合 topic。用户明确允许后于 15:42 在 Apple 后台保留旧 topic、新增整合 topic，三条生产测试通知苹果均接受，用户于 15:44 确认手机全部收到。设备注册和详细送达状态见 [通知实测](signals-and-notifications.md#普通通知真机测试2026-11-03)，备份与回滚见 [运维](operations.md#app-普通信号通知限定发布2026-11-03)。

## ActivityKit live 持仓卡片

2026-11-03 新增 `LIVE_ACTIVITIES_ENABLED=false`，API 注册和派发同时要求它与 `APNS_ENABLED` 开启；scheduler 仅在 live 开关开启时挂载独立的每 15 秒任务。复用现有 APNs 团队、签名 key、bundle ID 与只读 p8 挂载，不新增第三方凭证。实时活动使用每活动 token 和 `APNS_BUNDLE_ID + .push-type.liveactivity` topic，普通通知设备 token 不能替代。后台更新固定 `apns-priority=5`，无声音或横幅，不回退 Echobell；频繁更新授权时目标间隔 15 秒，否则 60 秒，均为尽力调度及投递，不保证系统按秒刷新。

发布需配套应用仅新增表的 `mobile.0003_liveactivityregistration`，该注册表记录活动、安装、用户／模式／绑定代际、token 轮换、租约与结束状态。注册最长有效期为开始时间起 8 小时，客户端不因 token 更新延长；快照 90 秒过期。退回旧代码可保留新增表，但须先停用 live 调度并评估尚在系统展示的活动，代码回滚不会撤回已送达的卡片或还原数据库。token 属敏感数据，不输出到文档或请求日志。

iOS 主应用开启 `NSSupportsLiveActivities` 与 `NSSupportsLiveActivitiesFrequentUpdates`，嵌入 `PositionLiveWidget` 扩展；频繁更新是否允许仍读取系统实时权限。ActivityKit 与普通通知路由隔离，关闭普通仓位通知不会自动停用 live。2026-11-03 22:49 在 **47.80.22.243（首尔服务器）** 核验 API／scheduler 已加载 `LIVE_ACTIVITIES_ENABLED=true`、APNs true，原三个通知／外部接收暂停开关仍为 false，注册表迁移完成；当前没有活动 token。本轮新包未上传、真实 APNs live 送达待验，版本及回退见 [运维](operations.md#live-后台持仓卡片限定发布2026-11-03)，行为见 [持仓浮窗](ios-floating-positions.md#activitykit-live-持仓卡片2026-11-03源码实现)。
