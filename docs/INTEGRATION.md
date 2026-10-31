# Python 与原生 iOS 整合

核对日期：2026-10-31。用户已批准在当前目录整合、在本机 Xcode 运行并部署到 47.80.22.243（首尔服务器）。原 USDT、USDC 本地源码只读。按后续授权，目标机的旧 USDC Java 环境已退役，整合数据库已逻辑迁入项目内独立 MySQL；迁移和清理范围见 [运维](operations.md)。

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

行情覆盖当前报价资产的全部正在交易永续合约，默认 USDT。`1m` 连续 K 线每组最多 80 个订阅；独立 ticker 流；200ms 合并；收线 upsert；完整分钟聚合 `5m/15m/1h/4h/1d`，缺分钟不会伪造完整桶。iOS 同时订阅 1m 与目标周期，沿用原 Metal 图表的分钟合成及历史分页逻辑。

每轮逐合约预热最近 500 根分钟线，并修复保留范围内的首个缺口，单次最多 1000 根，后续轮次继续。历史查询独立调用 Binance 原生周期 REST；满页但尾部陈旧或存在间隔缺口也会修复。请求使用原共享 REST 预算。冷数据和断线补齐受交易所限速影响，不保证所有合约瞬间补完。

数据库保留周期：1m 7 天、5m 14 天、15m 30 天、1h 90 天、4h 180 天、1d 365 天；每小时分批清理。分页可以按需向交易所读取更早记录，旧数据将在后续清理中删除。

## 协议

所有下列路径都相对于当前 API 基址；首尔包含 `/integrated/` 前缀。

| 路径 | 用途 |
| --- | --- |
| `/api/auth/login/register/me/refresh/logout` | 原认证适配；JWT、协议同意、原限频和 refresh cookie |
| `/api/market/tickers`、`/popular`、`/search` | 列表、热门和搜索 |
| `/api/market/klines` | `symbol/interval/limit/beforeOpenTime/tradingData`；与原 Swift 模型兼容 |
| `/api/market/watchlist/defaults` | 默认自选；用户编辑由原客户端保存 |
| `/api/commands`、`/api/commands/<UUID>` | 带幂等键提交、当前用户/模式查询 |
| `/v1/*` | 原 USDT 业务接口；原生页面使用既有字段与规则 |
| `/ws/v1` | Bearer JWT 与 `X-Trading-Mode`；ready / ack / ping / pong / event |

WSS 分发行情及 `trading.account/position/order/fill`，按用户和交易模式过滤。每连接 128 条有界队列，慢客户端超时断开重连；access token 到期关闭 4401，客户端合并 refresh 后重连。REST 遇 401 最多 refresh 并重试一次；身份已经切换时旧请求不能覆盖新会话。

`trading.*` 事件在客户端合并 350ms 后读取原业务状态，持仓、委托、详情、命令记录随之刷新。账户 REST 对账完成后再次投递提示，避免首次读到尚未收敛状态。行情与账户推送不直接当作交易成功回执。

## 命令与订单维护

命令保存用户、模式、幂等键、请求哈希及绑定 ID / 指纹 / 创建时间快照。每账户 Redis lease 30 秒、10 秒续期，DB fence 阻止旧 worker 写入新执行结果；原交易生命周期锁内再次核对绑定代际。原调度器继续维护已有保护单，账户事件促使同一套服务尽快对账。

进程中断后的 RUNNING 变为 UNKNOWN，不盲目重发。UNKNOWN 暂停本绑定新增风险，包括已经排队的开仓；原保护及管理类操作继续。建仓、限价及追单可通过已持久化订单事实收敛成功；其他 UNKNOWN 仍需核对，没有实现全动作自动消歧。网络调用在 lease 丢失前可能已经到达交易所，不能宣称交易所写入 exactly-once。

## 原生页面映射

| 原 USDT Web | 原生入口 / 实现 |
| --- | --- |
| 原 USDC 行情列表与 K 线 | 首个行情 Tab；原 Dashboard / 搜索 / 自选 / Metal 图表和指标布局 |
| 持仓、限价、历史 | 持仓 Tab；按原 snake_case 数据显示数量、盈亏、价格、保护、结算状态和日志 |
| 市价 / 限价建仓 | 开仓 Tab；资金预检、EMA 初筛、止损金额、策略和提交确认 |
| 图表划线下单 | 进入原生 USDT 表单，再执行原预检 / EMA / 确认 |
| 外部、自有、TV 信号 | 信号 Tab；普通模式展示，可进入同一 K 线 |
| 账户、API、止损、策略 | 我的；独立模式、API 验证、1–5 层策略编辑 |
| 观察计划与复盘 | 我的 / 信号；计划、结果、全部评分细项及否决项 |
| 信号研究 | 我的；样本、行情分析、可信标签、规则、AI 模型、草案参数、发布与回测 |
| 资金、历史、日志 | 我的；金额 / 路径 / 地址确认、固定归集流水跟进、分页与筛选 |
| 协议、注册、密码重置 | 原生认证及协议页面；沿用邮件服务配置 |

Bundle ID 使用 `com.waibao2025.trade.integrated`，与旧客户端隔离。iOS / Release 会话使用 Keychain。仅 Debug Mac Catalyst 且显式传入 `--integration-ephemeral-session` 时允许内存会话，用于本地无 Apple 签名身份的临时 UI 验证。

## 配置与边界

部署配置模板是 [`deploy/integrated/server.env.example`](../deploy/integrated/server.env.example)，实际凭证位于服务器受限文件。`MARKET_WS_URL` 默认 `wss://fstream.binance.com/market`，`ACCOUNT_WS_URL` 默认 `wss://fstream.binance.com/private`；旧无路由前缀入口会出现握手后无数据。`MARKET_WS_PROXY` 仅供本机开发显式配置代理，生产直接连接。HTTPS 证书校验始终开启。

当前未配置整合环境 SMTP、AI 私密模型及外部通知目标；相关页面保留原业务能力，实际可用性取决于配置。APNs 尚未接入新 Python 通知链路；原 Java 实现从 [来源索引](sources.md) 指定的本地目录查询。带单新增风险由 `LEAD_TRADING_ENABLED=false` 保持关闭，已有模式边界照旧。

已完成代码映射不代表每个资金 / 交易分支均实盘验收。没有绑定真实账户，也没有进行真实开平仓、划转、撤保护单或更改旧订单策略。验证记录见 [变更](changes.md)，运维见 [部署](operations.md)。

## 本地 iOS 验证

使用 Xcode 27.2 / iOS 27.2 的 iPhone 18 Pro 模拟器。单元和 Metal 测试通过 `TradeTool` scheme 执行；真实登录及页面 smoke 使用 `TradeTool Chart Calibration` scheme 下的 `IntegratedNativeUITests`，必须显式提供配置化的无绑定 QA 账号、密码和 API 地址，参数见 [开发验证](development.md)。缺少密码时跳过此 opt-in 测试，不在源码保存密码。

模拟器登录验证必须保留 Xcode 的临时签名和 simulated entitlements：`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`。使用 `CODE_SIGNING_ALLOWED=NO` 虽可执行纯测试，但会令登录后 Keychain 保存不可用。原生 iOS 会话不使用内存回退。离屏测试的背景色已按当前 `#212731` 暗色画布校准，像素命中判断比较未绘制角落背景，避免将整块画布当成最新价线。

2026-10-31 17:08（北京时间），`IntegratedNativeUITests` 完整流程通过：本地无绑定 QA 会话、真实 BTC 行情及 Metal 图表、持仓、禁用开仓、信号、我的和 API 绑定表单。已实际查看行情、图表、开仓及账户截图。系统“保存密码”提示由测试处理；我的菜单行使用完整矩形点击区域和 44pt 最小高度，修复点击行中间空白不能导航的问题。完整 XCTest 166 项及随后独立 Keychain 读写测试通过；没有 iPhone 实机或实盘验证。

`Debug-Seoul` 与 `Release` 均默认连接 47.80.22.243（首尔服务器）的整合入口。上述 17:08 UI 结果使用本地 API；本轮远程 UI 验收另见 [变更](changes.md)，不将模拟器结果扩大为所有线上业务、实机或实盘通过。历史运行报告保留在忽略目录 `.integration-runtime/`。

TestFlight 分发尚未执行。已添加 `PrivacyInfo.xcprivacy` 并加入主 App 资源，声明现有 UserDefaults 与图表 `systemUptime` 的访问理由。新 Bundle ID 已注册且启用 Push Notifications，团队、App Store Connect App 记录和内部测试组已建立；本地开发签名 Release Archive 及 162 项单测通过。已重新生成新应用 Cloud manifest，仓库所有者授权与 `iOS TestFlight` 工作流均已保存，包含必过单测、Release 归档及内部测试自动分发。云端 Build 起始号已设为 4，之后原生递增；实际云端分发签名和上传仍需独立验收，见 [手机发布指南](testflight.md)。

## 本次服务器验收与性能范围

2026-10-31 首次部署 `integrated-20261031-ddec4af96a86`，随后在 47.80.22.243（首尔服务器）切换为独立数据库版本 `integrated-20261031-d2498172efa6`。HTTPS 登录、Secure refresh cookie、历史分页、认证拒绝及真实 K 线 / ticker WSS 通过。首次部署的私有推送用临时无交易事件验证用户、普通 / 带单模式隔离，未创建交易命令或交易所订单；本轮结果见 [变更](changes.md)。

| 短时采样路径 | 列表读取中位数（5 次） | 300 根 1m / 1h 读取 | 事件延迟中位数 / P95 / 最大值 |
| --- | --- | --- | --- |
| 首尔容器经公网 HTTPS / Nginx 回环 | 12.9ms | 23.5ms / 20.0ms | 239ms / 670ms / 857ms（15 秒、45 条） |
| 本机到首尔 HTTPS / WSS | 280.9ms | 169.2ms / 225.3ms | 302ms / 1179ms / 18265ms（15 秒、33 条） |

事件延迟按接收时钟减 Binance `eventTime` 计算，合并 BTC 1m K 线与 ticker；不是订单执行延迟。服务器当前发现 522 个 USDT 永续合约，历史分页按 `beforeOpenTime` 排除边界。样本较短，本机链路出现 18.265 秒离群点，原因待定位；不能据此承诺稳定性或宣称相对旧 Java 的固定加速倍数。
