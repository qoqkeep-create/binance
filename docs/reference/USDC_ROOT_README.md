# Trade Tool

> 来源归档（2026-10-31）：链接已按归档位置调整；当前整合实现与部署见 [整合说明](../INTEGRATION.md)。


币安 USD-M 永续合约行情与策略服务。报价资产由
`BINANCE_QUOTE_ASSET` 统一配置，默认使用 `USDC`。当前核心功能：

- 订阅当前报价资产下所有正在交易的永续合约 `1m` 连续 K 线。
- 使用 REST 快照和独立 ticker WebSocket 为 APP 提供最新价、24h 成交额与涨跌幅。
- 使用 MySQL 持久化收盘 K 线，使用 Redis 保存各周期最近 K 线。
- 基于完整 `1m` 收盘 K 线提前聚合并保存 `5m`、`15m`、`1h`、`4h`、`1d` K 线。
- 启动时补足历史 K 线，运行中每分钟检查并修复缺口。
- 使用 ta4j 计算 EMA21、EMA55、EMA144、MACD、ATR 和 SuperTrend。
- `15m` 与 `1h` 在完整收盘 K 线上识别 SuperTrend 翻转后的首次 EMA144 回踩；`4h` 必须满足严格多头 `EMA21 > EMA55 > EMA144` 或空头 `EMA21 < EMA55 < EMA144`，盘中触达 EMA144 即判断，同一交易对滚动 24 小时最多提醒一次，不受 SuperTrend 翻转窗口限制。
- EMA21、EMA55 与 MACD 继续计算和展示，但不再生成金叉/死叉提醒。
- K 线落库事务提交后异步发布事件，策略提醒异步消费，不阻塞行情写入。
- 信号成功落库后可向外部站点异步推送 UTF-8 纯文本提醒。
- 信号成功落库后可通过 APNs 向已注册 iOS 设备发送远程通知。
- 外部系统可使用独立密钥向通用 JSON 收件箱提交消息，业务解析与推送独立处理。
- 白名单币种无条件运行原策略；白名单外币种通过流动性、拥挤度和趋势质量筛选后运行策略。
- 行情采集和补线始终覆盖全部目标合约，不受策略币池限制。

详细上下文见 [项目上下文](../PROJECT_CONTEXT.md)。

项目审阅与持续跟进入口：

- [Python / Java 后端对比](../BACKEND_COMPARISON.md)：架构取舍、K 线推送和响应、下单里程碑与订单维护差异，关联同日接口实测。
- [项目审阅报告](../PROJECT_REVIEW.md)：2026-10-30 的文档盘点、代码问题、配置差异和实际验证结果。
- [项目开发与改进计划](../PROJECT_PLAN.md)：按优先级跟踪任务、依赖、状态和验收条件。
- [开发跟进与改进日志](../DEVELOPMENT_LOG.md)：记录每轮变更、验证、未完成项及下一步。

## 技术栈

- Java 25
- Spring Boot 3.5.14
- Binance Java Connector 2.0.0（显式使用 binance-common 2.2.1）
- ta4j 0.22.6
- MySQL 8
- Redis
- MyBatis-Plus
- Sa-Token 1.45.0

## 模块

当前后端服务位于：

```text
backend/app-service
```

SwiftUI iOS 前端位于：

```text
frontend/ios-app
```

iOS 登录/退出接口契约、Keychain 会话规则和币安风格视觉规范见
[`frontend/ios-app/docs/DESIGN_AND_AUTH.md`](../../frontend/ios-app/docs/DESIGN_AND_AUTH.md)。
APP 实时连接、ticker 快照、频道、鉴权、心跳和重连协议见
[`docs/REALTIME_WEBSOCKET.md`](../REALTIME_WEBSOCKET.md)。
Java 实盘账户、仓位、订单、固定/移动止盈止损、安全换单和故障恢复方案见
[`docs/TRADING_BACKEND_DESIGN.md`](../TRADING_BACKEND_DESIGN.md)。
以损定仓公式、三种建仓/止损方式、分级减仓和每分钟止损棘轮的实际执行说明见
[`docs/TRADING_R_EXECUTION.md`](../TRADING_R_EXECUTION.md)。
账户 User Data Stream、REST 对账、事件幂等归并和普通/Algo 订单状态机的专项
实施设计见
[`docs/TRADING_ACCOUNT_SYNC_DESIGN.md`](../TRADING_ACCOUNT_SYNC_DESIGN.md)。

当前设置页的交易配置统一经过 Java 服务：分级止盈止损策略支持 1–5 级，每级可
独立选择减仓、一次移动到固定 R、或持续保持“当前浮盈减 R”；止损额按账户余额
的 1%–25% 计算并冻结，调低立即生效，调高在 2 小时后生效。下单设置
额外保存默认止盈止损策略、建仓/止盈/止损委托方式，及限价止损的
保底市价止损 R 位置。K线划线下单由 Java 使用冻结的 R 计算数量，并在成交后按设置
同时安装保护单和全部分级止盈单，达到各级 R 后再激活只收紧不放宽的止损棘轮。每笔建仓还冻结完整执行设置、交易
规则和级别快照；后续修改默认设置不会影响旧仓位。活动计划会定期通过 REST 核对
主止损、保底止损与全部已配置止盈，按持久化 revision 和退避游标只补异常单；止盈部分
成交后仅补该级剩余计划量，建仓继续成交会安全换单补足止盈，多级止盈和人工减仓
统一受剩余仓位容量约束；仓位结束前还会收敛未成交建仓余量与全部退出单。交易命令
只在账户处于 `ACTIVE + SYNCED` 且当前 worker 持有有效 lease/fencing token 时执行；
系统不再提供全局或账户级下单开关。并发建仓会在事务内锁定账户行并二次检查活动
计划，避免不同幂等键绕过单仓位约束；人工平仓会先暂停计划、确认撤销剩余建仓与
全部止盈，保留止损直到仓位结束，并清理归零或换代后的残留 Maker 平仓单。

主要包：

```text
com.oovso.binance   币安 REST/WebSocket 接入
com.oovso.auth      Sa-Token 登录、退出、会话和用户认证
com.oovso.market    K线存储、Redis缓存、连续性守护与补线
com.oovso.indicator ta4j BarSeries 和指标持久化
com.oovso.strategy  策略、K线形态、信号持久化
com.oovso.notification 纯文本 Webhook、APNs 提醒与内容格式化
com.oovso.realtime APP WebSocket 鉴权、订阅、心跳和实时事件分发
com.oovso.trading  账户凭证、User Data Stream、REST 对账与交易事实镜像
```

## API 登录鉴权

后端使用 Sa-Token `1.45.0`，会话写入现有 Redis。iOS 使用：

```text
POST /api/auth/login
POST /api/auth/register
GET  /api/auth/me
POST /api/auth/logout
Authorization: Bearer <accessToken>
```

首次部署在 `.env` 中配置初始管理员：

```bash
APP_ADMIN_ACCOUNT=admin
APP_ADMIN_PASSWORD=至少12位强密码
APP_ADMIN_EMAIL=admin@example.com
APP_ADMIN_DISPLAY_NAME=Administrator
APP_REGISTRATION_ENABLED=true
```

只有数据库中不存在该账号时才会创建，不会在每次启动时覆盖密码。生产环境应
通过 HTTPS 反向代理暴露 API，不能在明文 HTTP 上传输账号、密码或 Token。
如果不希望开放自助注册，可将 `APP_REGISTRATION_ENABLED=false`。

## APP 行情查询

登录后的 APP 使用以下行情接口：

```text
GET /api/market/tickers
GET /api/market/tickers/popular?page=0&size=10
GET /api/market/tickers/search?query=BTC&page=0&size=20
GET /api/market/klines?symbol=BTCUSDC&interval=1h&limit=500
GET /api/market/klines?symbol=BTCUSDC&interval=1h&beforeOpenTime=...&limit=1500
GET /api/market/klines?symbol=BTCUSDC&interval=1h&limit=500&tradingData=openInterest,topPositionRatio
```

`/api/market/klines` 最新页只在 `tradingData` 参数显式请求时，才调用对应的币安统计
接口并在 K 线的可选 `tradingData` 字段中返回数据。支持
`openInterest`、`topAccountRatio`、`topPositionRatio`、`globalAccountRatio`、
`buySellVolume` 和 `basis`；未启用这些面板的默认图表不会请求或返回统计数据。
这些数据来自币安 USD-M 的近 30 天统计接口，支持 `5m`、`15m`、`1h`、
`4h`、`1d`；`1m` 以及使用 `beforeOpenTime` 的历史分页不附加该字段。
各统计源独立降级，单个币安统计接口失败不会影响 K 线响应。

策略信号历史、用户删除与反转二次提醒接口：

```text
GET /api/strategy/signals
GET /api/strategy/signals?cursor={nextCursor}
PUT /api/strategy/signals/{signalId}/read
PUT /api/strategy/signals/{signalId}/reversal-alert
DELETE /api/strategy/signals/{signalId}
GET /api/strategy/notification-preferences
PUT /api/strategy/notification-preferences
```

信号历史固定每次返回 `10` 条，使用服务端游标向后分页；已读状态按登录用户持久化。
打开通知只进入信号页，不会自动已读，只有从信号页点击进入对应 K 线详情后才调用
已读接口。删除只隐藏当前用户的记录，不会删除其他用户的数据；二次提醒每次设置只触发一次，
用户设置后只检查来源周期对应的后续完整收盘 K 线，首次命中严格反转形态，或最新 MACD(12,26,9) 柱绝对值小于上一根、表现为能量向零轴衰减时，定向推送该用户；`15m` 来源信号检查 `15m`，`1h` 与 `4h` 来源信号检查 `1h`，MACD 衰减不区分原信号多空。已设置的信号在列表中显示状态标识；提醒触发后用户可再次设置，重新等待下一次有效二次提醒。
历史金叉/死叉信号不再展示，也不会继续生成。
信号页右上角的提醒设置按登录用户保存 `15m`、`1h`、`4h` 三个 APNs 开关；没有
配置记录的用户默认全部开启。关闭某周期会停止该周期主信号和二次提醒的系统推送，
并从当前用户的信号历史查询与实时列表中隐藏该周期；重新开启后可再次查询历史记录。
策略分析、全局信号落库与 Webhook 继续运行。

交易账户设置接口：

```text
GET/POST/PUT/DELETE /api/trading/accounts/{accountId}/exit-strategies
GET/PUT             /api/trading/accounts/{accountId}/loss-limit
GET/PUT             /api/trading/accounts/{accountId}/order-settings
GET/PUT             /api/trading/accounts/{accountId}/leverage?symbol=BTCUSDC
POST                /api/trading/accounts/{accountId}/orders
DELETE              /api/trading/accounts/{accountId}/entry-orders/{orderId}
GET                 /api/trading/accounts/{accountId}/commands/{commandId}
```

账户监听与交易事实只读接口：

```text
GET  /api/trading/accounts/{accountId}/snapshot
GET  /api/trading/accounts/{accountId}/position-center?historyLimit=100
GET  /api/trading/accounts/{accountId}/orders?limit=100
GET  /api/trading/accounts/{accountId}/fills?limit=100
POST /api/trading/accounts/{accountId}/reconcile
```

`position-center` 为 iOS 主菜单“持仓”页一次返回当前持仓、活动限价委托和历史
持仓。历史持仓由服务端按成交顺序划分完整开平仓周期，汇总开仓/减仓/平仓均价、
已实现盈亏以及该周期所有成交手续费；多手续费资产分别返回，客户端不自行估算。
本系统创建且仍活动的建仓限价单会返回 `entryCancelable=true`，iOS 点击“撤单”后直接
通过幂等撤单命令取消剩余未成交数量；止盈、止损和外部订单不提供该入口。若建仓单已经
部分成交，撤单不影响已成交仓位，原计划继续按下单快照管理该部分仓位与保护单。

设置 `TRADING_ACCOUNT_SYNC_ENABLED=true` 后，Java 会在账户绑定事务提交后启动
Binance User Data Stream，并以 REST 快照进行启动、断线和周期对账。账户达到
`ACTIVE + SYNCED` 且当前 worker 持有有效 lease/fencing token 后即可提交交易命令；
不存在额外的环境变量或账户级下单开关。主网上线前必须先完成 Futures Testnet 验收。

绑定 API 密钥时，Java 会先验证读取权限，再把 Binance USD-M 账户切换为双向持仓，
读取账户专属 `leverageBracket`，并把当前报价资产下全部 `TRADING + PERPETUAL`
交易对设置为各自允许的最大初始杠杆；完成后二次验证为 `HEDGE` 才加密保存。该批量
杠杆初始化只在绑定 API 时执行。服务启动仍会校准账户为双向持仓，但不会读取杠杆
档位或批量修改任何交易对杠杆。新建仓时不再读取、校验或修改持仓模式，每个建仓
命令只向 Binance 提交一次。交易所明确拒绝时直接结束命令并返回中文原因；例如
`-4061` 会提示用户自行在 Binance 将账户切换为双向持仓模式后重新下单。网络超时等
结果未知场景只按原客户端订单号查询实际结果，不会再次提交订单。
已知 Binance 错误码由 Java 统一翻译，iOS 不直接展示 `BINANCE_-xxxx`。

`dev` profile 会以 `BINANCE_PRIVATE_REST` 打印脱敏后的 Binance 私有 REST 方法、路径、
请求业务参数、HTTP 状态和响应，便于核对真实下单链路；API Key、Secret、签名和
listenKey 不写入日志。非 dev 环境默认关闭，可通过
`BINANCE_PRIVATE_REST_DIAGNOSTIC_LOGGING=true` 临时开启。

K 线详情页可读取和修改当前交易对杠杆。调整请求只由 Java 使用服务器端凭证访问
Binance，iOS 不接触 Secret；弹窗同时展示账户杠杆档位对应的最大持仓名义价值。
划线准备下单时，页面按冻结的当前 R 和止损距离实时预览仓位 U 与止损回撤百分比。

热门交易只包含当前 `BINANCE_QUOTE_ASSET` 下正在交易的 USD-M 永续合约，并按
Binance 24h 成交额从高到低排序。热门和搜索接口都返回页码、总数量、总页数与
`hasNext`；行情快照在后端短时复用，避免客户端输入过程中高频重复请求 Binance。
K 线详情查询支持 `1m`、`5m`、`15m`、`1h`、`4h` 和 `1d`，只用于前端展示，
`beforeOpenTime` 为严格排他的向前分页边界。查询优先读取 MySQL；本地数量不足时才
使用相同边界向 Binance 兜底，并把兜底得到的本地缺失且已收盘 K 线写回 MySQL 和
Redis，避免后续重复请求。该回写不触发策略提醒。可由 `1m` 聚合的高周期最新页还会
使用服务器已有的连续已收盘 `1m` 数据聚合当前未收盘柱并随响应返回；该临时柱不写库、
不触发策略事件，历史分页也不包含它。K 线详情页只保留图表和底部菜单，不再提供盘口
深度接口。

## 本地运行

数据库和 Redis 连接位于：

```text
backend/app-service/src/main/resources/application-dev.yml
```

`dev` 中的 MySQL 密码、Redis 密码和交易凭证主密钥分别通过
`MYSQL_PASSWORD`、`REDIS_PASSWORD`、`TRADING_CREDENTIAL_MASTER_KEY` 注入。
启动前在当前终端或 IDE 的运行配置中设置；Maven 不会自动加载根目录的 `.env`。
当前代码副本不包含生产环境文件和 APNs 私钥，配置模板见 `.env.example`。

`dev` profile 已固定使用 Binance USD-M Futures Testnet：公共/私有 REST 为
`https://testnet.binancefuture.com`，行情流为
`wss://fstream.binancefuture.com/market/stream`，账户流为
`wss://fstream.binancefuture.com/private`。行情、账户对账、普通下单和 Algo 条件单
使用同一套真实交易代码，只由 profile 切换币安端点。Testnet API Key 必须在 Futures
Testnet 单独创建，与主网 Key 不通用；`pro`/默认 profile 继续使用 USD-M 主网。

数据库结构由 Flyway 在应用启动时先于业务组件迁移。MySQL 版本化脚本位于
`backend/app-service/src/main/resources/db/migration/mysql`，跨数据库兼容迁移位于
`backend/app-service/src/main/java/db/migration/common`。已发布的迁移不得修改；以后所有
建表、补列、索引或数据修正都必须新增下一个 Flyway 版本，不得在 Java 启动
组件中直接执行 DDL。

使用 Homebrew JDK 25：

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@25/libexec/openjdk.jdk/Contents/Home
cd backend/app-service
mvn spring-boot:run
```

IntelliJ 内置 Maven 的测试命令：

```bash
JAVA_HOME=/opt/homebrew/opt/openjdk@25/libexec/openjdk.jdk/Contents/Home \
'/Applications/IntelliJ IDEA.app/Contents/plugins/maven/lib/maven3/bin/mvn' test
```

## 当前策略摘要

基础行情周期为 `1m`；`15m` 与 `1h` 策略消费本地聚合后的完整收盘 K 线并使用相同规则，`4h` 主提醒把实时 `1m` 更新合成为当前未收线 `4h` K 线并盘中判断：

1. SuperTrend 使用 ATR `10`、multiplier `6`。
2. `15m` 与 `1h` 在 SuperTrend 翻转后最多等待当前周期的 `30` 根 K 线。
3. EMA144 是唯一回踩目标；EMA55 和 SuperTrend 继续计算并展示，但不触发独立回踩提醒。
4. 接近容差取 `min(ATR10 × 0.1, 目标价 × 0.2%)`；`15m` 与 `1h` 影线进入容差区后还需通过宽松的方向性局部极值过滤。
5. `15m` 与 `1h` 的 SuperTrend 多头要求候选低点接近最近低位，空头要求候选高点接近最近高位；比较采用比例排名和 ATR/价格容差，不强制创新低或创新高。
6. `15m` 与 `1h` 过滤离开回踩极值过远或已经滞后的信号。
7. `15m` 与 `1h` 同一次 SuperTrend 翻转、同方向最多提醒一次。`4h` 必须严格满足 `EMA21 > EMA55 > EMA144`（多头）或 `EMA21 < EMA55 < EMA144`（空头），相等或交错排列不提醒；不等待翻转，也不受 30 根限制。每个交易对的 4h 主提醒滚动 24 小时最多一次，多空方向共用冷却；冷却满后仍须有新的有效触达，不补发冷却期间的旧触达。实时价格需先回到趋势一侧并离开容差区，再次触达才构成新回踩。触达状态、最后提醒时间与信号在同一事务持久化，重启继续冷却。
8. 不再生成 EMA21/EMA55 金叉或死叉提醒；EMA21、EMA55 与 MACD 仅保留为指标数据。
9. 用户可对已有 EMA144 回踩信号设置二次提醒；严格反转 K 线或 MACD(12,26,9) 能量衰减任一成立即可触发。MACD 条件只比较最新两根完整柱，只要最新柱绝对值小于上一柱、即距离零轴更近便成立，不区分原信号多空，也不要求零轴方向、连续扩张或前置反向 K 线。`15m` 来源信号检查后续完整 `15m` 柱，`1h` 与 `4h` 来源信号检查后续完整 `1h` 柱；每次设置只触发一次，触发后可再次设置，K线形态仍排除延续/突破形态、普通十字星和未确认倒锤。
10. 白名单外币种还需通过动态市场筛选、30天 K 线质量、EMA144 斜率和 ADX14 过滤。

当前 `reversal-pattern-required: false`，反转形态过滤已关闭。

### 动态币池

`symbol-whitelist` 中的币种保持原有策略行为，不经过新增筛选。白名单外币种默认每小时刷新一次准入快照，主要条件：

```text
上市至少 90 天
24h 成交额和最近 30 天每日成交额中位数均不低于 3000 万当前报价资产
持仓价值不低于 1000 万当前报价资产
盘口价差不超过 0.05%
资金费率绝对值不超过 0.05%
24h 涨跌幅绝对值不超过 20%
24h 持仓价值变化率绝对值不超过 40%
最近 30 天对应策略周期的异常 K 线不超过 3 根
EMA144 斜率顺势且 ADX14 不低于 20
```

空白名单表示没有币种绕过筛选，所有币种都按动态规则准入。动态筛选失败或 Binance 数据暂时不可用时，只跳过白名单外币种，不影响行情保存、补线及白名单策略。

### 报价资产切换

`binance.usdm.continuous-kline.quote-asset` 是全系统唯一报价资产开关，
生产环境通过 `.env` 设置：

```dotenv
BINANCE_QUOTE_ASSET=USDC
```

改为 `USDT` 并重启后，行情发现、WebSocket 订阅、REST 补线、策略白名单和
iOS 行情列表会一起切换。`symbol-whitelist` 只配置 `BTC`、`ETH` 这类基础币种；
系统会拼接当前报价资产，并自动排除 Binance 当前不存在或未交易的合约。

## iOS 策略通知

系统通知使用 Apple Push Notification service（APNs），不依赖 App 进程或行情
WebSocket 在线。iOS 登录后向 Apple 注册设备令牌，再通过鉴权接口保存到 Java；信号
事务提交成功后，Java 使用 APNs Token Key 直连 Apple HTTP/2 接口发送远程通知。
前台同样显示横幅和声音。点击通知会恢复其中携带的信号并打开“信号”页，点击信号
卡片会进入对应交易对的来源周期 K 线详情页。`strategy.signal` WebSocket 只负责 App
在线时刷新页面数据，不再用于生成系统通知。
信号页可分别关闭 `15m`、`1h`、`4h` 的 APNs 提醒，设置由后端按用户持久化；
信号历史和在线列表按相同周期开关过滤，关闭后立即刷新列表；全局 Webhook 继续运行。

服务端默认关闭 APNs。先在 Apple Developer 中为 `com.oovso.trade` 开启 Push
Notifications、创建 APNs Auth Key，并把 `.p8` 文件整体做 Base64 后通过环境变量注入：

```bash
export APNS_NOTIFICATION_ENABLED=true
export APNS_TEAM_ID=你的TeamID
export APNS_KEY_ID=你的KeyID
export APNS_PRIVATE_KEY_BASE64=完整p8文件的Base64单行内容
export APNS_TOPIC=com.oovso.trade
```

禁止把 `.p8`、Base64 私钥或其他 Apple 凭证提交到仓库。Debug 构建注册 sandbox
令牌，Release/TestFlight 构建注册 production 令牌，Java 会自动选择对应 APNs 主机。
未立即送达的信号默认最多由 APNs 保留 `6h`，避免行情信号过期后才提醒。

## 通用外部 JSON 消息接收

其他系统通过 `POST /api/external/messages` 提交 JSON，并在
`X-External-Message-Key` 请求头中携带独立密钥。接口不使用 App 登录 Token，默认关闭：

```bash
export EXTERNAL_MESSAGE_ENABLED=true
export EXTERNAL_MESSAGE_API_KEY="$(openssl rand -hex 32)"
export REFERENCE_TRADE_NOTIFICATION_TARGET_EMAIL="475842526@qq.com"
```

Key 校验成功后，服务先将原始 JSON 与接收时间写入 `external_message`，再通过独立
处理器识别参考通知。`OPEN`、`STOP_LOSS`、`STRATEGY_TAKE_PROFIT`、
`MANUAL_TAKE_PROFIT`、`REDUCTION` 会按 `eventId` 幂等投影到
`reference_trade_notification`，事务提交后异步触发目标账号 APNs；通知失败不影响
收件和投影落库。未知类型仍保留在通用收件箱，不与接收入口耦合。具体协议见
[`deploy/EXTERNAL_MESSAGE_API.md`](../../deploy/EXTERNAL_MESSAGE_API.md)。

## 纯文本 Webhook

外部 Webhook 默认关闭。启用后，策略信号在数据库事务提交成功后通过 HTTP `POST`
发送。请求遵循目标站点协议，顶层发送 `eventId`、`sourceName`、`symbol`、`signal`、
`strategy`、`interval`、`price`、`timestamp`、`comment` 和 `indicators`；完整 UTF-8 纯文本位于
`comment` 字段。内部 `USDC` 交易对仅在 Webhook 出站时改为 `USDT`，结构化
`signal` 字段中的 `LONG/SHORT` 分别改为 `BUY/SELL`；请求类型为
`application/json; charset=UTF-8`。HTTP `429`、`5xx`
和网络异常默认最多尝试 `3` 次；推送失败不影响行情、指标或信号落库。

```bash
export WEBHOOK_NOTIFICATION_ENABLED=true
export STRATEGY_SIGNAL_WEBHOOK_URL='https://example.com/webhook/external'
export STRATEGY_SIGNAL_WEBHOOK_KEY='replace_me'
```

Webhook 地址不能包含查询参数；访问 key 通过独立变量注入，只能写入实际 `.env` 或
Jenkins Secret file，不能提交到仓库。Docker Compose 会把这三个配置传入 Java 服务。

## Docker Compose 部署

首尔服务器的独立测试入口为 `https://47.80.22.243`，iOS 使用共享 scheme
`TradeTool Seoul`。安装、资源分配、证书自动续期和验收记录见
[首尔测试部署](../SEOUL_DEPLOYMENT.md)。

首次部署先准备环境变量：

```bash
cp .env.example .env
```

修改 `.env` 中的 MySQL、Redis、APNs 和 Webhook 配置后启动：

```bash
mkdir -p logs
chmod 777 logs
docker compose up -d --build
docker compose logs -f trade_app
```

应用日志同时写入宿主机目录：

```text
./logs/trade-tool.log
```

策略信号出现时会记录包含 `STRATEGY_SIGNAL_CREATED` 的日志，可直接检索：

```bash
grep STRATEGY_SIGNAL_CREATED logs/trade-tool.log
```

更新部署：

```bash
git pull
docker compose up -d --build --remove-orphans
docker image prune -f
```

上面这组命令适合本机或单机直接构建部署。生产环境也可以使用下一节的 Jenkins SSH 流程，部署服务器不需要保存 Git 仓库。

## Jenkins SSH 部署

仓库根目录的 `Jenkinsfile` 使用生产 SSH 发布流程，部署服务器不保存 Git 仓库：

```text
Checkout
-> 判断当前提交相对上次成功构建的文件变更范围
-> 校验部署参数
-> 打包后端源码
-> 检查生产服务器
-> 上传源码和 Jenkins Secret file
-> 校验生产变量并构建镜像（执行全部 Java 测试）
-> Docker Compose 切换生产容器
-> API 冒烟检查
-> 失败自动恢复上一版本
```

流水线按变更范围选择发布动作：`Jenkinsfile`、Compose、`deploy/**`、生产
Dockerfile 等部署文件发生变化时执行完整 Compose 发布；仅
`backend/app-service/**` 业务文件变化时只重建并切换 `trade_app`，不会启动或重建
MySQL、Redis，也不会覆盖现有 Compose、Nginx 或整份生产环境文件；仅
`frontend/ios-app/**` 或文档变化时在 checkout 后成功结束，不读取
生产凭据，也不连接生产服务器。无法可靠确定上次提交、重复构建同一提交，或勾选
`FORCE_FULL_DEPLOY` 时保守执行完整发布。

Jenkins 节点不需要 Docker、Maven 或 Java 25；远程连接和文件上传由
`SSH Pipeline Steps` 插件执行。部署服务器需要 Docker、Docker Compose v2、
Nginx、`tar`、`curl`、SSH，以及可访问 Maven/Docker 镜像源的网络。Jenkins 使用的
SSH 账号需要能执行 `docker`，并且对 `APP_DEPLOY_DIR` 和 `REMOTE_WORK_DIR`
有写入权限。

仓库提供了不挂载 `docker.sock` 的 Jenkins 容器：

```bash
sudo install -d -o 1000 -g 1000 /opt/jenkins/data
docker compose -f deploy/jenkins/compose.yaml up -d --build
```

镜像会自动安装 Pipeline、Git、Credentials Binding、SSH Credentials 和 SSH
Pipeline Steps 插件。Jenkins 任务选择 `Pipeline script from SCM`，填写 Gitee 仓库、
拉取凭据和脚本路径 `Jenkinsfile`。

Jenkins 需要以下凭据：

| 默认凭据 ID | Jenkins 类型 | 内容 |
| --- | --- | --- |
| 任务 SCM 中配置 | Username/Password 或 SSH Key | Gitee 拉取凭据 |
| `ssh-home` | Username with password | 生产服务器 SSH 账号 |
| `trade-tool-production-env` | Secret file | 完整生产 `.env` 文件 |

生产 SSH 连接不再绑定 `known_hosts` Secret file，修改 `DEPLOY_SERVER_HOST` 后可直接
切换服务器。流水线会接受目标主机返回的任意 SSH host key，因此不会检测服务器身份
变化或中间人攻击；生产服务器地址和网络链路必须由可信运维渠道确认。

生产环境 Secret file 可以复制 `.env.example` 后填写真实值，但不能提交到 Git。
至少必须替换 MySQL、Redis 和 `TRADING_CREDENTIAL_MASTER_KEY`；主密钥使用
`openssl rand -base64 32` 生成，部署后不得遗失或随意更换。正式启用 APNs 时还要设置：

```dotenv
APP_REGISTRATION_ENABLED=false
APNS_NOTIFICATION_ENABLED=true
APNS_TEAM_ID=你的TeamID
APNS_KEY_ID=你的KeyID
APNS_PRIVATE_KEY_BASE64=AuthKey_p8文件整体的Base64单行内容
APNS_TOPIC=com.oovso.trade
WEBHOOK_NOTIFICATION_ENABLED=true
STRATEGY_SIGNAL_WEBHOOK_URL=https://example.com/webhook/external
STRATEGY_SIGNAL_WEBHOOK_KEY=replace_me
```

流水线会拒绝 `change_me` 占位密码、非 32 字节的交易凭证主密钥、Testnet 地址和
不完整的 APNs/Webhook 配置。它只在服务器上保存权限为 `600` 的
`/opt/trade-tool/.env.production`，不会把密钥写入工作区或构建日志。

Jenkins 会把日志目录映射到：

```text
/opt/trade-tool/logs/trade-tool.log
```

生产环境只使用仓库根目录的 `compose.remote.yaml`；Jenkins 会将其安装为
`/opt/trade-tool/compose.yaml`。同一个文件既可启动全部服务，也可只指定
`trade_mysql trade_redis` 初始化基础服务。容器名固定为 `trade_mysql`、
`trade_redis`，Docker 网络固定为 `trade_network`，持久化内容都位于部署目录：

```text
/opt/trade-tool/mysql/data
/opt/trade-tool/redis/data
```

只初始化基础服务时使用：

```bash
install -d -m 750 /opt/trade-tool/mysql/data /opt/trade-tool/redis/data
docker compose \
  --env-file /opt/trade-tool/.env.production \
  -f /opt/trade-tool/compose.yaml \
  up -d --wait trade_mysql trade_redis
```

Jenkins 首次部署到新服务器时会自动拉取本机缺失的 MySQL/Redis 镜像，无需手动勾选
`PULL_BASE_IMAGES`；该参数只用于主动重新拉取基础镜像。数据库镜像使用固定摘要，
避免迁移后因 `latest` 指向新版本而使用不兼容的引擎直接打开旧数据目录。

整目录迁移前必须在源服务器干净停止三个服务，禁止复制正在写入的 MySQL 数据目录：

```bash
docker compose \
  --env-file /opt/trade-tool/.env.production \
  -f /opt/trade-tool/compose.yaml \
  stop trade_app trade_mysql trade_redis

rsync -aHAX --numeric-ids /opt/trade-tool/ root@新服务器:/opt/trade-tool/
```

目标服务器应与源服务器使用相同 CPU 架构，并预先安装 Docker、Docker Compose v2
和正在运行的 Nginx。复制完成后只需修改 Jenkins 的部署服务器地址并执行完整部署；
Jenkins 会重新构建应用镜像，复用目录中的环境文件、数据库、Redis、日志和证书。

MySQL 与 Redis 默认只映射到服务器 `127.0.0.1`。本地排查可使用 SSH 隧道访问，
不要把 3306/6379 直接开放到公网：

```bash
ssh -L 13306:127.0.0.1:3306 -L 16379:127.0.0.1:6379 用户@服务器
```

Dockerfile 使用 BuildKit cache mount 持久化 Maven 本地仓库，缓存 ID 为
`trade-tool-maven-repository`。每次镜像构建执行全部 Java 测试；首次构建仍需下载依赖，
后续只下载新增或变化的依赖，除非服务器执行过 `docker builder prune`。

Jenkins 会先构建带 `${BUILD_NUMBER}-${GIT_COMMIT}` 标签的新镜像，再切换
`trade_app`。构建失败时旧容器继续运行；启动或冒烟检查失败会使用上一次环境文件和
镜像自动回滚。只有新容器启动并通过 `/api/auth/me` 冒烟检查后，流水线才会删除
同一 `APP_IMAGE` 下除当前标签外的旧应用镜像；MySQL、Redis、基础镜像、BuildKit/Maven
缓存及 `/opt/trade-tool` 下的数据目录不会被删除。

源码包来自 Jenkins checkout 的当前提交。新增 Java、迁移或部署脚本必须加入 Git
并提交，否则 Jenkins 不会收到这些文件。

生产 API 固定映射为 `127.0.0.1:8686:8686`，Jenkins 会拒绝公网监听地址。宿主机
Nginx 是 80/443 的唯一入口，`binance.oovso.com` 在标准 HTTPS 端口 443 转发到
`127.0.0.1:8686`；`/ws/v1` 保留 WebSocket Upgrade 头。证书、配置安装和续期说明见
[`deploy/nginx/README.md`](../../deploy/nginx/README.md)。确认上述配置后，在 Jenkins 任务中
执行 `Build with Parameters`，填写服务器地址；其余参数通常保持默认即可。

当前服务器还运行另一组 Compose 服务且没有 Swap。生产 Compose 因此默认限制
`trade_app=1g`、`trade_mysql=768m`、`trade_redis=256m`，Java 堆限制为 `640m`；
Jenkins 远程构建的 Maven 堆限制为 `768m`。这些限制用于保护现有服务，正式长期运行
仍建议把服务器升级到至少 8GB 内存。

## 重要提醒

- 当前 WebSocket 基础订阅为币安原生 `1m` 连续 K 线；`15m` 与 `1h` 策略由完整 `1m` 本地聚合后触发，`4h` 主提醒额外用未收线 `1m` 更新合成当前 `4h` K 线并按约 250ms 行情节奏合并分析，不等待 4h 收线。
- 补线缺哪个周期就直接从 Binance REST 拉哪个周期，不再为了补高周期强制补 `1m` 再聚合。
- 启动长跨度历史补线默认关闭；需要时可按 `10` 天窗口从近到远补到 `2018-01-01`。
- 每分钟常规巡检只修最近窗口，默认巡检 `1m`、`5m`、`15m`、`1h`、`4h`、`1d`。
- Redis 使用 ZSET，score 为 `openTimeMs`，新 K 线进入后自动移除最旧数据。
- 不要为了处理 TLS 报错而关闭证书校验。
- 不要把应用管理员密码写入 YAML 或提交到 Git，只能通过环境变量注入。
- 修改配置后必须重新编译并重启应用；旧进程可能继续使用旧白名单或旧策略参数。
- 仓库可能存在尚未提交的用户改动，不要随意回滚。
