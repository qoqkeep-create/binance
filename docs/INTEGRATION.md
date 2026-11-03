# Python 与原生 iOS 整合

源码核对日期：2026-11-01；云端状态按下方各次验收日期区分。用户已批准在当前目录整合、在本机 Xcode 运行并部署到 47.80.22.243（首尔服务器）。原 USDT、USDC 本地源码只读。按后续授权，目标机的旧 USDC Java 环境已退役，整合数据库已逻辑迁入项目内独立 MySQL；迁移和清理范围见 [运维](operations.md)。

## 当前实现

```text
Binance /market WebSocket -> market_stream -> MySQL 收盘线 + Redis 热数据 / PubSub
                                                     -> ASGI /ws/v1 -> SwiftUI / Metal
原 USDT /v1 HTTP <------------------------------------------ 原生业务页面
原生交易命令 -> mobile 持久化命令 -> 账户 lease / fence -> 原 USDT 交易服务
Binance /private 用户流 -> Inbox -> 账户串行归并 / REST 对账 -> Outbox -> iOS 刷新
原独立 APScheduler -------------------------------------> 原订单保护和维护
```

Python 保留原交易业务、Decimal 精度、账户模式、绑定代际、原保护及结算口径。Java 的优势转为独立采集进程、账户事件流、持久化命令、账户串行执行和有界推送；运行时不再启动另一套 Java 交易引擎。

行情覆盖当前报价资产的全部正在交易永续合约，默认 USDT。`1m` 连续 K 线每组最多 80 个订阅；live 事件唤醒即时发布、ticker 与收线存储独立；收线 upsert，完整源桶聚合高周期，缺源线不会伪造完整桶。iOS 同时订阅 1m 与目标周期，沿用原 Metal 图表的分钟合成及历史分页逻辑。本地已扩展至 13 种周期，含自定义 16h 与周一对齐的 1w，新增六种按需补全、未扩大启动预热范围；本批尚未部署，边界及具体周期见 [行情](market-data.md#快捷周期与自动价格视窗2026-11-03)。

2026-11-01 改动将历史 HTTP 与外部补线解耦：先返回数据库／共享热窗口快照，由持久化任务在后台补齐全部周期的尾部、内部缺口和保留窗口。启动／定时预热，使用上市边界和本地分钟部分桶；统计由独立的 6 个 worker 并发缓存。客户端行情先连接，账户资料后刷新；已有数据即展示，补全以就绪通知／订阅确认触发重读，保留 15 秒校对。迁移、兼容和验证边界见 [行情与图表](market-data.md#后台自动补全与首屏读取)。相关改动已纳入 GitHub 源码交付；后端于本日部署至 47.80.22.243（首尔服务器）的 `integrated-20261101-74b8e5d-wss`，手机首屏速度待用户验收，见 [运维](operations.md)。

后台按币种、周期和分页边界领取持久化任务，单次最多补入 1500 根原生周期线；先恢复最新尾部，再补内部缺口和更早的保留窗口。补线和统计独立领取任务，共用低优先级 REST 预算；冷数据和断线补齐受交易所限速影响，不保证所有合约瞬间补完。

数据库按周期保留并每小时分批清理，原周期及新增周期的天数以 `market_stream.service.RETENTION_DAYS` 和 [行情](market-data.md#快捷周期与自动价格视窗2026-11-03) 为准。历史分页可以触发后台补全，到保留窗口或上市边界停止向前扩展。

## 协议

所有下列路径都相对于当前 API 基址；首尔包含 `/integrated/` 前缀。

| 路径 | 用途 |
| --- | --- |
| `/api/auth/login/register/me/refresh/logout` | 原认证适配；JWT、协议同意、原限频和 refresh cookie |
| `/api/market/tickers`、`/popular`、`/search` | 列表、热门和搜索 |
| `/api/market/klines` | `symbol/interval/limit/beforeOpenTime/tradingData`；与原 Swift 模型兼容 |
| `/api/market/watchlist/defaults` | 默认自选；用户编辑由原客户端保存 |
| `/api/push/devices/register`、`/unregister` | 当前登录用户安装的 APNs token 注册／停用 |
| `/api/commands`、`/api/commands/<UUID>` | 带幂等键提交、当前用户/模式查询 |
| `/v1/*` | 原 USDT 业务接口；原生页面使用既有字段与规则 |
| `/ws/v1` | Bearer JWT 与 `X-Trading-Mode`；ready / ack / ping / pong / event |

WSS 分发行情及 `trading.account/position/order/fill`，按用户和交易模式过滤。每连接 128 条有界队列，慢客户端超时断开重连；access token 到期关闭 4401，客户端合并 refresh 后重连。REST 遇 401 最多 refresh 并重试一次；身份已经切换时旧请求不能覆盖新会话。

公共行情改用按频道／币种／周期的 Redis v2 主题，sequence 与发布原子执行。新增 `market.history` 能力协商和后台就绪通知；新客户端不会向旧后端发送未支持的频道。API 与 market 必须配套升级／回滚，不能混用公共事件路由版本，详细字段见 [就绪协议](market-data.md#补全就绪协议)。

`trading.*` 事件在客户端合并 350ms 后读取原业务状态，持仓、委托、详情、命令记录随之刷新。账户 REST 对账完成后再次投递提示，避免首次读到尚未收敛状态。行情与账户推送不直接当作交易成功回执。

## 命令与订单维护

命令保存用户、模式、幂等键、请求哈希及绑定 ID / 指纹 / 创建时间快照。每账户 Redis lease 30 秒、10 秒续期，DB fence 阻止旧 worker 写入新执行结果；原交易生命周期锁内再次核对绑定代际。原调度器继续维护已有保护单，账户事件促使同一套服务尽快对账。

进程中断后的 RUNNING 变为 UNKNOWN，不盲目重发。UNKNOWN 暂停本绑定新增风险，包括已经排队的开仓；原保护及管理类操作继续。建仓、限价及追单可通过已持久化订单事实收敛成功；其他 UNKNOWN 仍需核对，没有实现全动作自动消歧。网络调用在 lease 丢失前可能已经到达交易所，不能宣称交易所写入 exactly-once。

## 原生页面映射

| 原 USDT Web | 原生入口 / 实现 |
| --- | --- |
| 原 USDC 行情列表与 K 线 | 首个行情 Tab；原 Dashboard / 搜索 / 自选 / Metal 图表和指标布局 |
| 持仓、限价、历史 | 持仓 Tab；按原 snake_case 数据显示数量、盈亏、价格、保护、结算状态和日志 |
| 市价 / 限价建仓 | K 线下单区复用 `USDTTradeView`；资金预检、EMA 初筛、止损金额、策略和提交确认；独立开仓 Tab 已于 2026-11-02 移除 |
| 图表划线下单 | 进入原生 USDT 表单，再执行原预检 / EMA / 确认 |
| 外部、自有、TV 信号 | 信号 Tab；普通模式展示，可进入同一 K 线 |
| 账户、API、止损、策略 | 我的；独立模式、API 验证、1–5 层策略编辑 |
| 资金、历史、日志 | 我的；金额 / 路径 / 地址确认、固定归集流水跟进、分页与筛选 |
| 协议、注册、密码重置 | 原生认证及协议页面；沿用邮件服务配置 |

2026-11-02 客户端底栏调整为行情、持仓、信号、我的四项。活动持仓卡片新增基于同周期 EMA 与 Supertrend 的逆势建议，只读取公共行情并展示文本；条件、参数、刷新及带单信号限制见 [页面说明](ios-web-parity.md#持仓逆势建议与四项底栏2026-11-02)。本项无需后端升级，客户端交付状态以本轮验证记录为准。

同日持仓页的市价和浮盈改为逐条消费共享 ticker：以已同步的开仓均价、剩余数量和持仓方向本地估值，卡片及总浮盈不再使用接口 `pnl`，行情 tick 不触发仓位 REST 读取。公共推送与数量／订单对账分工、价格口径及上游限流依据见 [行情说明](market-data.md#持仓市价与浮盈推送限流边界2026-11-02)。

Bundle ID 使用 `com.waibao2025.trade.integrated`，与旧客户端隔离。iOS / Release 会话使用 Keychain。仅 Debug Mac Catalyst 且显式传入 `--integration-ephemeral-session` 时允许内存会话，用于本地无 Apple 签名身份的临时 UI 验证。

## 配置与边界

部署配置模板是 [`deploy/integrated/server.env.example`](../deploy/integrated/server.env.example)，实际凭证位于服务器受限文件。`MARKET_WS_URL` 默认 `wss://fstream.binance.com/market`，`ACCOUNT_WS_URL` 默认 `wss://fstream.binance.com/private`；旧无路由前缀入口会出现握手后无数据。`MARKET_WS_PROXY` 仅供本机开发显式配置代理，生产直接连接。HTTPS 证书校验始终开启。

整合环境 SMTP 及未列明的外部通知通道尚未配置；Echo／APNs 已准备受限配置，实际发送能力仍取决于配套发布与验收。看盘计划、校准问答、手动开仓理由／指标校验及信号研究已按 2026-11-01 新要求移除，旧数据及迁移记录的处理见 [功能退役](research.md)。内部信号已在源码接入 Python App APNs 投递与原生注册、点击导航；2026-11-03 起普通信号不走 Echobell，浮盈 Echobell 沿原 USDT 阈值独立投递。2026-11-03 先限定发布内部信号保存／排队及真实余额杠杆 GET，15:22 再补齐 App 注册／派发、HTTP2 和私钥挂载至 47.80.22.243（首尔服务器）；浮盈任务仍未上线。15:44 普通通知三条测试均获苹果接受且用户确认全部收到；首轮密钥 topic 授权缺失、修复及范围见 [通知实测](signals-and-notifications.md#普通通知真机测试2026-11-03)，前台 WSS 与系统通知仍分别验收。链路、去重与待配置边界见 [通知](signals-and-notifications.md)。带单新增风险由 `LEAD_TRADING_ENABLED=false` 保持关闭，已有模式边界照旧。

已完成代码映射不代表每个资金 / 交易分支均实盘验收。没有绑定真实账户，也没有进行真实开平仓、划转、撤保护单或更改旧订单策略。验证记录见 [变更](changes.md)，运维见 [部署](operations.md)。

## 本地 iOS 验证

使用 Xcode 27.2 / iOS 27.2 的 iPhone 18 Pro 模拟器。单元和 Metal 测试通过 `TradeTool` scheme 执行；真实登录及页面 smoke 使用 `TradeTool Chart Calibration` scheme 下的 `IntegratedNativeUITests`，必须显式提供配置化的无绑定 QA 账号、密码和 API 地址，参数见 [开发验证](development.md)。缺少密码时跳过此 opt-in 测试，不在源码保存密码。

模拟器登录验证必须保留 Xcode 的临时签名和 simulated entitlements：`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`。使用 `CODE_SIGNING_ALLOWED=NO` 虽可执行纯测试，但会令登录后 Keychain 保存不可用。原生 iOS 会话不使用内存回退。离屏测试的背景色已按当前 `#212731` 暗色画布校准，像素命中判断比较未绘制角落背景，避免将整块画布当成最新价线。

2026-10-31 17:08（北京时间），`IntegratedNativeUITests` 完整流程通过：本地无绑定 QA 会话、真实 BTC 行情及 Metal 图表、持仓、禁用开仓、信号、我的和 API 绑定表单。已实际查看行情、图表、开仓及账户截图。系统“保存密码”提示由测试处理；我的菜单行使用完整矩形点击区域和 44pt 最小高度，修复点击行中间空白不能导航的问题。完整 XCTest 166 项及随后独立 Keychain 读写测试通过；没有 iPhone 实机或实盘验证。

`Debug-Seoul` 与 `Release` 均默认连接 47.80.22.243（首尔服务器）的整合入口。上述 17:08 UI 结果使用本地 API；本轮远程 UI 验收另见 [变更](changes.md)，不将模拟器结果扩大为所有线上业务、实机或实盘通过。历史运行报告保留在忽略目录 `.integration-runtime/`。

TestFlight 内部分发已完成：`TradeTools USDT` 的 `1.0.1 (7)` 已自动加入“内部测试”组，后台状态为“正在测试”，测试员已邀请；尚未验收 iPhone 接受邀请、安装和运行。已添加 `PrivacyInfo.xcprivacy` 并加入主 App 资源，声明现有 UserDefaults 与图表 `systemUptime` 的访问理由。新 Bundle ID 已注册且启用 Push Notifications，团队、App Store Connect App 记录和内部测试组已建立；本地开发签名 Release Archive 及 162 项单测通过。已重新生成新应用 Cloud manifest，仓库所有者授权与 `iOS TestFlight` 工作流均已保存，包含必过单测、Release 归档及内部测试自动分发。云端 Build 起始号为 4，之后原生递增；修正 Cloud 模拟器耗时测试条件后，提交 `509f2da` 的构建 7 已通过云端测试、分发签名归档、上传和组内自动分发，见 [手机发布指南](testflight.md)。

## 本次服务器验收与性能范围

2026-10-31 首次部署 `integrated-20261031-ddec4af96a86`，随后在 47.80.22.243（首尔服务器）切换为独立数据库版本 `integrated-20261031-d2498172efa6`。HTTPS 登录、Secure refresh cookie、历史分页、认证拒绝及真实 K 线 / ticker WSS 通过。首次部署的私有推送用临时无交易事件验证用户、普通 / 带单模式隔离，未创建交易命令或交易所订单；本轮结果见 [变更](changes.md)。

| 短时采样路径 | 列表读取中位数（5 次） | 300 根 1m / 1h 读取 | 事件延迟中位数 / P95 / 最大值 |
| --- | --- | --- | --- |
| 首尔容器经公网 HTTPS / Nginx 回环 | 12.9ms | 23.5ms / 20.0ms | 239ms / 670ms / 857ms（15 秒、45 条） |
| 本机到首尔 HTTPS / WSS | 280.9ms | 169.2ms / 225.3ms | 302ms / 1179ms / 18265ms（15 秒、33 条） |

事件延迟按接收时钟减 Binance `eventTime` 计算，合并 BTC 1m K 线与 ticker；不是订单执行延迟。服务器当前发现 522 个 USDT 永续合约，历史分页按 `beforeOpenTime` 排除边界。样本较短，本机链路出现 18.265 秒离群点，原因待定位；不能据此承诺稳定性或宣称相对旧 Java 的固定加速倍数。

## 鸿蒙客户端扩展

2026-11-01 新增 `frontend/harmony-app/` 独立 ArkTS／ArkUI 工程，使用现有认证、行情、命令、业务 HTTP 与鉴权 WSS。首轮源码覆盖主要页面与请求恢复；未修改交易引擎或部署服务。已安装本机独立工具链，真实 ArkTS 编译和未签名 HAP 打包通过；调试签名、Mate 80 真机安装、界面全量对照、系统浮窗与通知仍待完成。功能与验证范围见 [鸿蒙客户端](harmony-client.md)。
