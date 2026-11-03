# 整合环境部署与运维

唯一目标为 **47.80.22.243（首尔服务器）**。原 USDT 生产环境及本地来源目录不属于本轮操作范围。用户已授权整合版部署与旧 USDC Java 环境退役；普通验收禁止真实开平仓、划转或撤保护单。

## 信号入库与杠杆金额限定发布（2026-11-03）

2026-11-03 12:23（北京时间）核验 **47.80.22.243（首尔服务器）** 当前为 **`integrated-20261103-signal-leverage-0ead6851a38e`**。旧版扫描入口因 `MARKET_ANALYSIS_ALERT_TOKEN` 未配置而整轮跳过，信号库为空；旧杠杆路由只返回标准名义档位。本次更新独立信号入库及每次读取真实可用保证金后的前三档金额，未改变信号触发规则或交易执行。

- 以实际运行的 `integrated-20261102-leverage-api-3fb1859` 为基线，重新核对 **311** 个存档文件。限定叠加 `market_analysis/trend.py`、杠杆视图及回归、`mobile` 新模型／`push.py`／0002 迁移和通知配置读取；313 个发布文件逐文件记录 SHA-256，清单位于 `source-release.json`。未带入工作区的账户流、开仓、保护、结算或调度任务编排修改；该包不是完整 Git HEAD。
- 包 SHA-256 为 `a64875ea17edfe611317c4bee01a04ffa67e8a15eb7b9f6a9cd01dc7728de13e`，两端一致。备份目录 `/opt/trade-tools-integrated/backups/integrated-20261103-signal-leverage-0ead6851a38e/` 为 0700，数据库压缩备份为 0600、317263357 bytes，gzip 完整性通过；保存前版路径、来源、容器 ID 和发布结果。只应用 `mobile.0002_notificationevent_pushdevice_notificationdelivery_and_more`，仅新增设备、通知事件、投递三张表及约束；随后 `migrate --check` 通过，没有初始化、反迁移或交易所写操作。
- 仅重建 API 与 scheduler，六服务 healthy；market、worker、MySQL、Redis 的容器 ID 和镜像与发布前完全相同。旧 scheduler 的订单维护源码与任务编排保持原样，仅其内部信号计算模块改变。发布前后数据库活动订单、待成交限价、未决命令、待提交开仓请求计数均为 0；这只是本地库状态检查，不代替交易所全面审计。
- 实际绑定账户经 API 容器内真实 HTTP／JWT 路由读取 BTCUSDT 杠杆返回 200、**3 项**，金额是有效 Decimal 字符串且按可开金额降序；没有设置交易所杠杆。公网 HTTPS／证书验证与健康均 200。自然调度完成 **56** 条币种／周期序列，`evaluated=56, alerted=0, failed=0`，缓存也有 56 项扫描标记；内部信号 GET 200、当前 0 条。当轮没有规则触发，未插入测试消息或补造历史信号，下一次真实触发的生产入库／手机显示仍待自然验收。
- 本包仅包含信号保存及通知排队依赖，**没有启用通知 dispatcher、设备注册路由或浮盈外发任务**；投递尝试为 0，不能称为 APNs／Echobell／浮盈通知已完整上线。完整通知发布仍需配套路由、依赖、任务、密钥挂载及 `positions.0029`，见 [通知](signals-and-notifications.md)。客户端、测试与文档保留本地，未提交／推送或上传 TestFlight。

该 release 的 Compose 操作使用 `-f compose.integrated.yaml -f compose.signal-leverage.yaml`，指定本版 `INTEGRATED_RELEASE`；override 固定 market／worker 的原镜像，不沿用前版将 scheduler 固定旧镜像的 override。回滚时读备份的 `previous-release`，在前版使用其 `compose.api-leverage.yaml` 和对应 release 值，仅恢复 API／scheduler，然后恢复 `current` 并验证健康。新增三表可保留，不能以反迁移或恢复数据库撤销代码发布；代码回滚后信号扫描恢复旧限制。客户端本地验证见 [开发](development.md#图表账户反馈回归2026-11-03)。

## 通知配置准备（2026-11-02）

2026-11-02 23:15（北京时间）已在 **47.80.22.243（首尔服务器）** 保存本轮通知所需配置，没有部署源码、应用迁移或重启容器。`current` 仍为 `integrated-20261102-leverage-api-3fb1859`，六服务只读核对均 healthy；当前进程未加载新增参数，不能将此记录写成 APNs／Echo 已上线或手机通知通过。

- Echo 地址来自用户本轮提供，浮盈接收范围使用整合库当前唯一有效绑定用户。环境文件 `/opt/trade-tools-integrated/server.env` 保持 0600，只增加／更新通知配置项，不公开地址或密钥。
- APNs 材料从原 iOS 项目只读取得，核对现有 P-256 私钥、Key 标识及团队与整合 Xcode 工程一致；topic 指向整合应用。p8 保存在 `/opt/trade-tools-integrated/secrets/AuthKey.p8`，目录 0700、文件 0400、UID 10001，配套 Compose 仅给 scheduler 只读挂载；未改变原项目文件。
- 首次 Echo 配置前环境备份为 `/opt/trade-tools-integrated/backups/notification-config-20261102-231232/server.env`；加入 APNs 前再次备份到 `notification-config-apns-20261102-231520/server.env`。备份目录 0700／文件 0600。回退配置须按上述阶段选取备份，保留其他后续配置；恢复文件不改变正在运行进程的环境。
- 后续完整通知发布须包含新依赖、`positions.0029` 的仅新增模型迁移及 API／scheduler 配套路由、任务与挂载；`mobile.0002` 已在 2026-11-03 信号限定发布应用，不能再把其完成当作整套通知已上线。代码回滚保留新增表，不重放已尝试通知。真实后台送达另作验收，本轮没有发送测试通知或执行交易／资金／保护单操作。配置及本地验证见 [配置](configuration.md#ios-信号和浮盈通知)、[通知](signals-and-notifications.md) 与 [开发](development.md#图表持仓杠杆与通知回归2026-11-02)。

## 自动杠杆只读接口补发（2026-11-02）

2026-11-02 20:18（北京时间）核验 **47.80.22.243（首尔服务器）** 当前为 **`integrated-20261102-leverage-api-3fb1859`**。此次修复客户端已有杠杆面板请求 404：旧运行版本未包含 `GET /v1/trade/leverage-brackets`，不是档位计算失败。以下账户、市值及其他发布记录为历史基线。

本次是限定范围的 API 发布，不代表整个 GitHub HEAD 已部署。以旧线上 **`171be8d74c506dc950be2395bf6e55ee57a7acc2`** 为后端基线，逐文件核对 306 个后端／部署文件与运行存档一致；仅叠加 `3fb1859` 的杠杆视图、路由、兼容测试和 `get_leverage_bracket` 中的完整档位字段，再加入本轮 URL 鉴权／拒绝 POST 回归。适配器只增加 `brackets`，保留基线其余方法；没有带入共享工作区的账户流、scheduler 等其他修改。`source-release.json` 记录来源、基线、限定路径、方法范围及每文件 SHA-256，不把混合来源归档标成完整源码提交。

- 归档 SHA-256 为 `301ad15038a23cfc662446e0e2fd25116ace95305e41a44775db869330c7a6dd`，远端核验通过。备份位于 `/opt/trade-tools-integrated/backups/integrated-20261102-leverage-api-3fb1859/`，目录 700、数据库压缩备份 600、291471834 bytes，gzip 完整性通过；前版 release／镜像保留。
- 无 migration 变化，仅执行 `migrate --check`；没有初始化、反迁移或生产交易写入。发布前后各有 1 个活动仓位，待成交限价、未决命令和待提交开仓请求均为 0；检查仅为数据库计数，不等于交易所持仓全面审计。
- 仅重建 API 容器。release 中 `compose.api-leverage.yaml` 将 market／worker／scheduler 固定为前版镜像；其余五个服务的容器 ID、镜像和 healthy 状态前后完全一致。六个服务均 healthy，公网健康接口 200，匿名杠杆请求由 404 变为预期 401；在 API 容器内通过实际 HTTP 路由和当前绑定账户完成 BTCUSDT 签名只读查询，200 返回 12 档、最高 150 倍，金额仍为 Decimal 字符串。

该限定 release 的 Compose 操作须同时使用 `-f compose.integrated.yaml -f compose.api-leverage.yaml` 并指定对应 `INTEGRATED_RELEASE`，以保留后三个服务的镜像。若需回退本次接口，先读取备份的 `previous-release`，在前版 release 中以其版本值执行 `docker compose ... up -d --no-deps --no-build --wait api`，再恢复 `current` 并检查健康、认证与 WSS；无需还原数据库或改变现有订单。后续正常完整发布重新从确定源码生成存档，不把该限定包视为完整 `3fb1859`。

客户端的时间／价格标签与纵排杠杆卡片仍为本地修改，未提交、推送或上传 TestFlight；验证及手机待验范围见 [开发](development.md#十字光标标签与杠杆面板回归2026-11-02)。

## 账户归集与服务器自选配套发布（2026-11-02）

2026-11-02 16:47（北京时间）最后核验 **47.80.22.243（首尔服务器）** 当前为 **`integrated-20261102-git-171be8d74c50`**，来源提交 **`171be8d74c506dc950be2395bf6e55ee57a7acc2`**。界面与初版后端提交为 `8a5c6ea`，后续 `171be8d` 修正公共市值接口限流；两者均已推送 `codex/integrated-ios`。下方三分钟及资金发布保留为历史基线。

- 初版发布前逐个核对 305 个已追踪后端／部署文件，除旧归档缺少 `.dockerignore` 外，均与原线上基线一致；随后只从确定提交导出发布。最终归档 SHA-256 为 `b03c6564563957b454610882f14a13fbf610562de102b7d1f1b5fe60a4a6bf98`，远端校验通过；`current`、`source-release.json` 和四个 Python 镜像对应最终提交，六个容器均 healthy。
- 初版应用 `market_stream.0005_watchlist_and_market_cap`，只新增用户自选与公共市值两张表；最终修正版无待应用迁移。最终数据库备份为 `/opt/trade-tools-integrated/backups/integrated-20261102-git-171be8d74c50/database.sql.gz`，目录 700、文件 600、300459099 bytes，发布前 gzip 完整性通过；同目录保留来源及前版路径 `integrated-20261102-git-8a5c6eabd91a`，原三分钟版本也保留。
- 初次公共采集遇到 429，实测响应要求等待 60 秒；改为批间 13 秒及有上限的重试。修正后仅清除已诊断、无成功快照的首次失败时间，再调用正式采集函数初始化，没有改写交易数据。16:44:52 开始的完整快照成功覆盖 522 个合约中的 505 个，其余 17 个无有效市值排在末尾；后续每七天更新，失败保留快照并退避，规则见 [行情](market-data.md#自选持久化与市值排序2026-11-02)。
- 无绑定 QA 公网核验：HTTPS 健康 200、自选写入／读取顺序一致并恢复原可见列表、522 项目录市值降序、BTC 3m 历史 200；鉴权 WSS ready、ETH ticker、订阅 ack 与应用心跳通过。QA 原用默认列表时，恢复结果会显式保存该列表；不涉及真实绑定账号资金。证据位于忽略目录 `.integration-runtime/InterfaceRefinement/`。
- 手动止盈只改变当前用户以后开仓使用的默认策略，不修改已有订单策略快照、保护单或持仓；本次没有真实开平仓、划转或撤单。新增表与旧代码兼容，代码回滚保留自选／市值数据，不反迁移；回到三分钟旧版后，新自选写入与手动默认项接口不可用，需同步考虑客户端功能。iOS 本地构建与手机待验范围见 [开发](development.md#账户归集服务器自选与图表修正2026-11-02)，没有以服务器通过代替 TestFlight 或 iPhone 16 Pro Max 验收。

## K 线三分钟配套发布（2026-11-02）

2026-11-02 14:22（北京时间）最后核验 **47.80.22.243（首尔服务器）** 当前为 **`integrated-20261102-git-e57289609d41`**，来源提交 **`e57289609d414b3a84509cfaf33f11309c1a8c13`**。以下先前账户资金发布及 2026-11-01 记录保留为历史基线。

- 发布前发现线上已从 `b849f17` 更新为 `ac93920`，旧基线校验在任何变更前中止。重新以当前线上 `ac939205db9df4e27cfe2877d61a22b8883cd24d` 为基线，仅叠加本任务四个 `market_stream` 文件；发布包全部后端／部署文件逐个与本次完整提交核对一致，归档 SHA-256 为 `7092ad98847214cd24833a9979cbd28b9ae1e6601de67487a5517a9c20f2ccaa`，远端校验通过，来源写入 `source-release.json`。
- 发布前／后只读核对各有 1 个绑定，活动仓位、待成交限价、未决命令和开仓请求均为 0。数据库备份位于 `/opt/trade-tools-integrated/backups/integrated-20261102-git-e57289609d41/database.sql.gz`，600 权限、260820019 bytes，gzip 完整性通过；前版 `integrated-20261102-git-ac939205db9d` 及镜像保留。本次无待应用 migration，保留既有账户、资金接口、配置、订单及保护规则。
- `current` 与四个 Python 镜像对应本版，六服务 healthy、HTTPS 健康 200。无绑定 QA 通过既有 HTTPS CONNECT 代理读取 BTC3m／300 根，开盘时间升序、无重复且对齐 180000 ms，最终单次完整响应 499.99 ms；`historyPending=false`，统计无待补。单次冒烟不代表手机首帧或延迟分位数。
- 鉴权 WSS 直连的 ready、3m／1m 订阅 ack、应用 ping／pong、1m 实时 K 线与一次 3m 对齐收盘事件通过。首轮 30 秒未跨收盘边界；第二轮脚本长等待漏续应用心跳被 1013 关闭，修正脚本后跨桶验证通过。没有修改产品心跳或用合成事件代替生产公共行情。
- 客户端／后端源码已推送 `codex/integrated-ios`，本轮本地构建与替身 UI 见 [开发](development.md#图表下单与周期回归2026-11-02)。未执行真实开平仓、划转或撤保护单；Apple 构建／TestFlight 分发与手机安装待另验。回滚代码不会还原数据库；回到前版后 3m 不受支持，客户端需选择旧有周期。

## 最新发布与核验（2026-11-02，资金界面配套）

2026-11-02 14:03～14:07（北京时间）发布并核对 **`integrated-20261102-git-ac939205db9d`**，位于 **47.80.22.243（首尔服务器）**，后端源码提交 **`ac939205db9df4e27cfe2877d61a22b8883cd24d`**。本次发布只包含该提交的后端与部署文件，不包含同工作区另一图表任务的未提交改动；后续共享 Git 分支的客户端 / 文档提交不自动改变此运行版本。

- 发布归档 SHA-256 两端一致；`current`、四个 Python 镜像与 `source-release.json` 均对应该版本。数据库压缩备份位于 `/opt/trade-tools-integrated/backups/integrated-20261102-git-ac939205db9d/`，权限 600，同目录保存前版路径、来源与变更哈希；前版 `integrated-20261101-git-b849f175f4a1` 保留。
- 发布前两次只读核对交易所真实持仓、普通挂单和条件单均无；本地活动订单 / 委托及 PENDING / RUNNING / UNKNOWN 命令为 0。有 1 个普通活动绑定、1 笔旧归集待确认，不读取或执行该流水的后续资金动作。
- 仅应用 `trading.0016_capital_wallet_operation`，新增动作与请求 UUID；旧动作为数据库空字符串默认值，UUID 可空，旧代码写入兼容。发布后旧活动归集仍为 1、新动作活动流水为 0；迁移不访问交易所或划转资金。回滚保留新增列 / 索引，不能反迁移或删流水；有新待确认动作时先核对，旧版没有新动作的恢复入口。金额及旧链边界见 [资金](capital-and-transfers.md#原生划转与转账2026-11-02)。
- 六容器 healthy，HTTPS 健康 200；无绑定 QA 验证两个新端点均返回“请先绑定 Binance API”，带单路径拒绝；鉴权 WSS ready / ping-pong 通过。历史端点对无绑定 QA 按既有规则拒绝，首次冒烟脚本误期望 200，改为核对绑定拒绝后完成；不把这次检查写成绑定账号历史或真实划转验收。
- 本次没有真实开平仓、划转、撤保护单、人工接管或策略修改。iOS 交付及 Release / 模拟器范围见 [变更记录](changes.md#2026-11-02账户与资金归集重设计)，Apple 打包、TestFlight 上传 / 安装和实机资金动作待验。

## 最新发布与核验（2026-11-01）

2026-11-01 22:16～22:22（北京时间）更新为 **`integrated-20261101-git-b849f175f4a1`**，位于 **47.80.22.243（首尔服务器）**，后端源码提交 **`b849f175f4a142a1de65f8cb9769f31cd29d957c`**。配套客户端共用交易对列表、自选与开仓状态修复；同批交付历史仓位快照。下方 16:42 发布改为历史基线。

- 从确定 commit 导出后端／部署文件，上传归档 SHA-256 核对通过；`current`、四个 Python 镜像与 `source-release.json` 对应该版。发布前只读核对绑定、活动仓位、待成交委托及未决命令均为 0。
- 受限备份位于 `/opt/trade-tools-integrated/backups/integrated-20261101-git-b849f175f4a1/`，包含 600 权限数据库压缩备份（238445308 bytes）、前版路径和来源／变更哈希；前版 `integrated-20261101-git-7daa36228c9f` 及镜像保留。新增 `market_stream.0004_marketsymbol` 只建公共目录表，代码回滚可保留该表，不能用代码回滚还原交易数据库。
- 新目录已保存 **522** 个活动 USDT 永续合约。六服务 healthy；本次 Compose 应用此前已在线调整的 MySQL 1 GiB／含 swap 2 GiB 配置并重建 MySQL，数值复核为 1073741824／2147483648；Redis 保留。没有真实开平仓、划转、撤保护单、订单策略或账号密码变更。
- HTTPS 深度健康 200，服务器回环 HTTPS 约 52～55 ms。无绑定 QA 公网验证目录、默认自选同目录、旧搜索分页字段和历史本地快照；目录单次 186.72 ms、空历史 325.05 ms，均为本机经现有 HTTPS CONNECT 代理的冒烟样本，不是手机／实际绑定账号分位数。鉴权 WSS 直连的 ready、订阅 ack、ETH ticker 和 ping-pong 通过。
- 本机直连 HTTPS 两次超时、WSS 经代理首次握手超时后，分别改用上述链路完成验证；SSH 传输重试后归档和来源均核对。未因本机链路抖动改生产网络配置或清空行情缓存。客户端与交付文档按本次用户授权推送，Apple 打包／TestFlight 分发和手机安装另验。


2026-11-01 16:42～16:44（北京时间）当前更新为 **`integrated-20261101-git-7daa36228c9f`**，位于 **47.80.22.243（首尔服务器）**，后端源码提交 **`7daa36228c9ff48637439da9d8e3cb5d229fdc4d`**。本次用户授权为手机测试直接推送客户端；配套部署诊断接收、冷读减量及此前已交付的行情读取协调／公共出口保护，按现有部署授权执行。下方 14:20 发布为历史基线。

- 发布包从确定 Git commit 导出，SHA-256 两端一致；`current`、四个 Python 镜像、release／备份中的 `source-release.json` 均对应本版。后续部署验收文档提交不改变该后端源码。
- 发布前只读核对 API 绑定、活动仓位、待成交委托和 PENDING／RUNNING／UNKNOWN 命令均为 0。备份位于 `/opt/trade-tools-integrated/backups/integrated-20261101-git-7daa36228c9f/`，含数据库逻辑压缩备份、`previous-release`、来源和变更哈希，权限受限。兼容回滚目标 `integrated-20261101-git-90911798159b` 及镜像保留；回滚代码不恢复数据库。
- 唯一待应用 migration `market_stream.0003_chartloadreport` 已完成，仅新增诊断表；初始化检测已有用户，不改账号密码，注册仍开启。六容器 healthy、HTTPS 深度健康 200。
- 无绑定 QA 公网读取 BTC1h／1500 根，gzip 完整接收 709.45 ms，history 277.84 ms，无 stale／pending；合法 trace／request 和服务端时间头正确。该单次冒烟不等于手机首帧或稳定分位数。鉴权 WSS ready／订阅 ack／BTC ticker 与 1m K 线事件／ping-pong 均通过。
- 诊断固定样本使用 build `0`／cancelled，鉴权 POST 两次均 200、数据库同 trace 只存一条，匿名 POST 401；这是接口与落库验收，不是手机呈现样本。未执行真实交易。
- 源码交付分支为 `codex/integrated-ios`，按本次授权推送以交给用户既有 Jenkins／Apple 打包流程；本轮不修改其配置，不把 GitHub 推送当作云端完成、TestFlight 可安装或手机测试通过。


2026-11-01 14:20～14:22（北京时间），按用户本次“全部推送并部署”授权，将整合 GitHub 分支 `codex/integrated-ios` 的源码提交 **`90911798159bd08d17fd369193bb83c7c0e7711b`** 发布到 **47.80.22.243（首尔服务器）**。当前版本为 **`integrated-20261101-git-90911798159b`**，`current`、四个 Python 容器镜像及 release 内 `source-release.json` 均对应这一版本。下方先前发布记录保留为历史，不表示仍运行旧版。

- 从确定 Git commit 导出已追踪的后端、Compose 和部署文件；上传包 SHA-256 已与本地核对。后端源码与此前 range 版内容清单相同，本次为建立 Git／运行版本对应而发布，没有追加交易逻辑改动。
- 发布前逻辑备份及 `previous-release` 保存在 `/opt/trade-tools-integrated/backups/integrated-20261101-git-90911798159b/`，目录 700、备份 600。兼容前版为 `integrated-20261101-kline-range-6413a8768d2b`，保留其源码和镜像；代码回滚不会恢复数据库。
- migration 输出为无待应用项；空库初始化确认已有用户，不修改账号密码。六容器均 healthy，HTTPS 深度健康 200；无绑定 QA 的鉴权 WSS ready、订阅 ack、应用 ping／pong、BTC ticker 与 1m K 线事件通过。注册开关仍为 true。
- 公网 gzip 单次读取：BTC1h 1500 根约 66.45 KB／853.58 ms，BTC1m 1500 根约 53.02 KB／1369.92 ms；时间是完整网络响应，均非 stale／pending，时间升序且无重复。这是发布冒烟样本，不是首帧或稳定性分位数。
- 全部 iOS、鸿蒙及文档源码已推送。iOS 使用此前同内容的 145 项图表／快速路径回归与 Release 无签名构建证据，本次新增后端 69 项、鸿蒙 40 项及工程检查通过。没有重新上传 TestFlight、签名鸿蒙 HAP 或安装手机；GitHub 推送可能触发既有 Xcode Cloud，Cloud 处理与手机版本未核实。

## 当前部署结构

- `/opt/trade-tools-integrated/releases/<内容版本>`：发布源码；`current` 指向当前版本。
- `/opt/trade-tools-integrated/server.env`：600 权限的独立配置，各 release 通过链接读取。
- Compose 项目 `tradetools-integrated`，使用 `--profile pro`；API、market、worker、scheduler、MySQL、Redis 共六个服务，仅使用项目默认网络。
- API 仅发布 `127.0.0.1:8787`。MySQL、Redis 不发布宿主端口，使用各自命名卷 `integrated-mysql`、`integrated-redis`。
- MySQL 8.4 镜像在 Compose 中固定 digest，独立 `tradetools_integrated` schema / `tt_integrated` 用户，当前内存 1 GiB、内存加 swap 总限额 2 GiB；本次在线调整和后续发布配置见 [压力恢复](#mysql-内存限额与压力恢复2026-11-01)。应用不再依赖 `trade_mysql` 或 `trade_network`。
- 宿主 Nginx 为 HTTPS / WSS 代理，仅 `/integrated/` 指向 API；旧根路径和 `/ws/` 返回 404。
- 保留 Docker / containerd、Nginx、`/opt/certbot` 和有效 TLS 证书，它们现在支撑整合版。

前版为 `integrated-20261101-pruned-8ff1d7379c22`，2026-11-01 12:31（北京时间）在 47.80.22.243（首尔服务器）确认六个容器 healthy、HTTPS 健康 200、鉴权 WSS 声明 `market.history` 与一次应用层 ping / pong。它包含此前 `74b8e5d` 的行情优化、WSS 鉴权连接清理，以及本地看盘计划／校准问答的运行逻辑退役；发布名末尾为后端与部署文件内容清单的 SHA-256 前缀，不代表 Git 提交。源码未提交或推送。用户安排先不测试，手机速度和完整功能待其验收；客户端本轮修改仅保留本地，不能把本次部署当作手机升级。

12:17 行情发布前核对 API 绑定、活动仓位、待成交限价及 PENDING / RUNNING / UNKNOWN 命令均为 0；当时迁移只新增 `market_stream.0002_markethistorytask`，不修改交易表或已有账户密码。数据库逻辑备份、原 release 路径与 WSS 修正文件 SHA-256 位于目标机受限目录 `/opt/trade-tools-integrated/backups/integrated-20261101-74b8e5d-wss/`；不得上传其中数据库内容。保留原 `integrated-20261031-d2498172efa6` release / 镜像用于兼容回滚；API / market 必须成对切换，代码回滚不还原数据库。

随后退役功能发布前再次核对绑定、活动仓位、待成交限价及未决命令均为 0；执行 `users.0009_retire_watch_calibration`，其数据库操作为空，仅删除 ORM 状态，历史 nullable 列和计划表继续保留。新备份及前版路径存放于 `/opt/trade-tools-integrated/backups/integrated-20261101-pruned-8ff1d7379c22/`，可回滚前版为 `integrated-20261101-74b8e5d-wss`。代码回滚不自动反迁移；新库回到包含计划模块的旧代码时，需要使用旧版迁移补建计划表，见 [功能退役](research.md)。

此前完整部署与行情验收基线为 2026-10-31，范围见 [变更](changes.md)。

2026-11-01 13:26（北京时间）当前版本更新为 **`integrated-20261101-kline-range-6413a8768d2b`**，位于 47.80.22.243（首尔服务器）。本轮先发布 gzip 版 `integrated-20261101-kline-gzip-0afeeba67c44`，再经分段测量修复当前部分桶多读 3000 根分钟线；相对前版只改变公共行情响应压缩、当前桶读取范围及对应测试，没有新增 migration 或修改交易规则。两次发布均显示无待应用迁移，保留账号与配置。

最终版六容器 healthy、HTTPS 深度健康 200、无绑定 QA 鉴权 WSS ready／六次 ping-pong 通过；1500 根 BTC／ETH／SOL 及统计读取有响应，实测范围和抖动见 [行情](market-data.md#测量与结论边界)。这不等于物理手机或 TestFlight 通过。源码、客户端均未提交／推送／分发。

最终发布备份位于 `/opt/trade-tools-integrated/backups/integrated-20261101-kline-range-6413a8768d2b/`，包含受限数据库逻辑压缩备份、`previous-release` 和变更文件哈希；前置 gzip 版备份位于同级同名目录。当前兼容回滚候选为 gzip 版及 pruned 版，均保留原 release／镜像；代码回滚不会恢复数据库。本轮未修改 Nginx 全局配置、凭证、保护单或既有交易策略。

随后执行首屏交接计划，2026-11-01 13:43～14:04（北京时间）仅只读核对 47.80.22.243（首尔服务器）：`current` 与运行 API 仍为 range 版，六容器 healthy，内部健康 200／约 13 ms；真实 gzip、不同币种／周期和 ZEC／SOL 按需补线完成状态已复核，范围见 [首屏补验](market-data.md#按首屏交接计划补验2026-11-01)。本轮没有修改服务器配置、清空 Redis、迁移或重新发布。新增客户端分页恢复修复仍在本地，手机 TestFlight 12 未升级；不能将此轮验收当作新的后端或客户端部署。

## MySQL 内存限额与压力恢复（2026-11-01）

本次 16:42～16:44 发布初期六容器及接口通过；后续检查发现 47.80.22.243（首尔服务器）的 MySQL 接近旧 512 MiB cgroup 上限并持续回收，数据库和应用健康检查随后超时。现场 `memory.current=536489984`／`memory.max=536870912`，`memory.events.max=355300`，PSI full avg10 为 89.79%，MySQL CPU 约 194.55%；没有 OOM kill 或数据库重启。宿主仍有约 1.9 GiB 可用内存，不能把它误判成主机内存已耗尽。

先暂停公共 market 减少请求，再用 `docker update --memory 1g --memory-swap 2g tradetools-integrated-mysql-1` 在线增加限额；没有重启 MySQL、修改数据库卷／账号／订单或调整交易规则。阻塞的诊断查询立即完成，确认同 trace 只有一条 build 0 样本、注册仍开启；随后恢复 market。

恢复采集后的 30 秒观察：cgroup 约 609～612 MB，已超过旧限额；`memory.events.max` 保持 384713、没有新增限额命中，PSI some／full avg10 均为 0。随后再次验证 HTTPS 健康、BTC1h 1500 根 gzip（单次 633.84 ms，history 171.37 ms，无 stale／pending）、诊断提交／重复上报及 WSS ready／ack／ticker／1m K 线／ping-pong。该短观察不能代替长期容量验收，也不能据此宣称最初 TestFlight 13／14 的慢加载只有这一个原因。

当前部署源码仍为 `7daa362`；此次数据库内存采用在线更新，release 存档中的原 Compose 作为来源证据保留。本轮源码 `compose.integrated.yaml` 已将 MySQL `mem_limit: 1g`、`memswap_limit: 2g` 固化，并在 47.80.22.243（首尔服务器）通过实际 Compose `config --quiet` 校验。后续发布使用更新后的 Compose；回滚 Python 代码也必须保留至少该内存限额，不能把旧 512 MiB 设置重新应用到运行容器。备份中的 `compose-memory-1g.yaml` 仅作本次校验证据，不另立部署手册。

## 注册开关

注册状态存于 `users.SystemSetting` 的 `open_registration` 数据库项，`1` 为开启，默认关闭；不属于 `server.env` 配置。匿名 `GET /v1/auth/admin-settings` 可读取当前状态，管理员可在 App 设置或通过同路径的鉴权 `POST` 提交 `{"open_registration": true}` / `false` 修改，重启和代码发布不重置已有设置。

2026-11-01 03:04（北京时间）在 47.80.22.243（首尔服务器）核对六个整合容器均 healthy、当前发布仍为 `integrated-20261031-d2498172efa6`，再经 SSH 在现有 API 容器调用 `SystemSetting.set_open_registration(True)`，只改变这一设置。匿名公网状态返回 true、HTTPS 健康检查为 200；未重建容器或执行真实注册、邮件发送及交易操作。管理员需要关闭时修改同一设置即可。

## 初次配置与发布

源码必须先审阅并放入独立 release。首次运行 `python3 deploy/integrated/prepare_host.py`，生成随机应用密钥、数据库密码与初始管理员资料，并启动独立 MySQL，由官方镜像初始化 schema / 用户。已有 `server.env` 时拒绝覆盖。管理员仅在用户表为空时创建，不重置已有密码；默认不开放注册。

在 release 中运行：

```bash
bash deploy/integrated/release.sh
```

脚本构建应用镜像，等待独立 MySQL / Redis 健康，执行 Django 版本化 migration、空库管理员初始化，再启动四个 Python 进程并更新 `current`。发布前评估迁移与旧代码兼容性；不要打印完整 env、容器环境或凭证。

## HTTPS 与证书续期

47.80.22.243（首尔服务器）的当前文件对应关系：

| 源文件 | 安装位置 |
| --- | --- |
| `deploy/integrated/nginx-site.conf` | `/etc/nginx/sites-available/tradetools-integrated`，由同名 sites-enabled 链接启用 |
| `deploy/integrated/nginx-location.conf` | `/etc/nginx/snippets/tradetools-integrated.conf` |
| `deploy/integrated/cert-renew.service` / `.timer` | `/etc/systemd/system/tradetools-integrated-cert-renew.service` / `.timer` |
| `deploy/integrated/reload-nginx.sh` | `/etc/letsencrypt/renewal-hooks/deploy/tradetools-integrated-reload.sh`，权限 755 |

站点模板定义 WSS Upgrade 的 map，与 location 配套更新；配置修改后先 `nginx -t`，通过才 reload。80 端口保留 ACME challenge，其他路径转 HTTPS。ACME webroot 为 `/var/www/tradetools-integrated-acme`，续期配置中的 webroot 必须一致。

有效 IP 证书沿用 Certbot lineage `trade-tool-seoul-ip`，证书 / 私钥仍位于 `/etc/letsencrypt/live/trade-tool-seoul-ip/`。这个历史名称仅标识证书，不代表 Java 系统仍存在。不要手工改名证书目录或关闭 TLS 校验。新的 `tradetools-integrated-cert-renew.timer` 每六小时检查，成功续期后 deploy hook 检查并 reload Nginx。

```bash
nginx -t
systemctl status tradetools-integrated-cert-renew.timer
systemctl start tradetools-integrated-cert-renew.service
```

普通 renew 成功只表示本轮命令完成；未到续期时间可能跳过签发。2026-10-31 已在 47.80.22.243（首尔服务器）执行 `certbot renew --dry-run --run-deploy-hooks --cert-name trade-tool-seoul-ip`：ACME staging 模拟续期及 deploy hook 检查 / reload 均成功；没有将 staging 证书替换为线上证书。以后改动 webroot 或站点时需复验该流程。

## HTTPS 传输拥塞控制（2026-11-01）

47.80.22.243（首尔服务器）原宿主默认 CUBIC，在实际手机链路出现重传、缩窗和发送排队。先用一个带 10 分钟自动撤销的目的地址路由指标做 BBR 对照，保持网关与全局默认不变；内核确认手机新连接为 BBR，构建 15 三次 BTC1h 首帧为 503.60／433.48／453.03 ms，用户反馈零点几秒。详情及未覆盖范围见 [行情排查](market-data.md#构建-15-真机传输排查2026-11-01)。

随后固化宿主默认 BBR，不改变既有 `fq_codel`。持久配置与当前交付模板对应：

| 源文件 | 安装位置 |
| --- | --- |
| [network-modules.conf](../deploy/integrated/network-modules.conf) | `/etc/modules-load.d/tradetools-integrated-network.conf` |
| [network-sysctl.conf](../deploy/integrated/network-sysctl.conf) | `/etc/sysctl.d/99-tradetools-integrated-network.conf` |

取得包含这两个模板的源码后，以 root 从源码根目录执行；先确认目标文件是否存在并备份，保留其他网络设置。宿主配置独立于容器 release，不由当前 `release.sh` 自动安装。

```bash
modprobe tcp_bbr
install -m 644 deploy/integrated/network-modules.conf /etc/modules-load.d/tradetools-integrated-network.conf
install -m 644 deploy/integrated/network-sysctl.conf /etc/sysctl.d/99-tradetools-integrated-network.conf
sysctl -p /etc/sysctl.d/99-tradetools-integrated-network.conf
sysctl -n net.ipv4.tcp_congestion_control
```

本次安装前两个目标文件均不存在，宿主值为 CUBIC；备份清单和应用结果保存在 `/opt/trade-tools-integrated/backups/chart-transport-probe-20261101/host-network/`。本次仅加载指定 sysctl 文件，没有运行 `sysctl --system`、切换 qdisc、升级内核或重建容器。四个正在运行的 Python 容器网络命名空间默认值复核仍为 CUBIC；宿主默认不是所有既有 socket 的算法，也不能替代容器重建后的核对。

临时目的路由、其回滚状态文件、定时器和 TCP 采样已撤销；Nginx 恢复前原文与 SHA-256 `2752682e40e3ce8d9a599321820ea48e9ad01dbe5b31418fb2589f91045b6e53` 一致，检查及平滑 reload 通过。撤销后独立新建 HTTPS keep-alive 连接，内核明确为 BBR、健康接口 200；六个整合容器 healthy。无绑定 QA 的鉴权 WSS ready、订阅 ack、BTC ticker／1m K 线及应用 ping-pong 也通过。`current` 和镜像仍为 `integrated-20261101-git-7daa36228c9f`，这次是宿主传输配置应用，不能写成新应用版本部署或新客户端分发。文件已配置开机加载，但没有为测试重启宿主，重启恢复与其他网络长稳仍待验收。

取舍与影响范围：宿主默认算法作用于该网络命名空间的新 TCP 连接，范围不限于 K 线或 443 端口；容器和既有连接要分别核对。BBR 不直接改变开平仓、订单维护或资金计算规则，但传输延迟与吞吐仍可能随链路改变，不能承诺所有网络都更快；共享瓶颈下各连接的带宽分配也可能变化。本次三次手机对照支持保留配置，不代表多用户并发或长期稳定性已验收。

当前使用内核自带实现，没有更换自定义内核。保留 `fq_codel` 时，Linux 6.8 BBR 可依赖每 TCP socket 的内部 pacing 定时器，可能增加资源消耗，具体 CPU 增量本次未测量；依据见 [Linux 6.8 实现说明](https://github.com/torvalds/linux/blob/v6.8/net/ipv4/tcp_bbr.c)。后续性能异常需要结合首帧阶段耗时、重传、连接数及 CPU 判断，不能仅凭启用 BBR 推断故障原因。

本次状态的回退方式：先核对上述清单和文件哈希；将运行默认恢复为 `sysctl -w net.ipv4.tcp_congestion_control=cubic`，再删除本次新增的这两个指定文件。若未来已有其他原配置，应恢复其备份。无需反向迁移数据库或重启交易容器；已存在的 BBR socket 不会据此全部切换，回退验证应重新建立连接。不要为了卸载模块强制中断现有业务连接。

## 健康与资源检查

```bash
curl --fail https://47.80.22.243/integrated/v1/health
cd /opt/trade-tools-integrated/current
INTEGRATED_RELEASE=$(basename "$(pwd -P)") docker compose --project-name tradetools-integrated --env-file /opt/trade-tools-integrated/server.env -f compose.integrated.yaml --profile pro ps
```

API 检查数据库、迁移和 scheduler heartbeat；market 检查 flush 心跳与最近 Socket 消息；worker / scheduler 单独检查心跳。六个容器 healthy 不等于所有交易对历史已补完，还需读取真实 K 线 / ticker 事件、eventTime 与历史分页。

只查看必要日志尾部，保护账户信息。`docker stats --no-stream`、`docker system df` 和磁盘检查用于资源排障。禁止盲目执行包含 volumes 的全局 prune；数据库卷和 Redis 卷保存持久数据。

## 更新与回滚

更新使用新 release、受限配置和同一个 Compose 项目。不要推送父 Gitee 仓库 main 触发来源系统自动部署。

回滚先核对 migration 与目标镜像兼容，保存数据库备份；代码回滚不会还原数据库。兼容时选择保留的 release / 镜像，指定对应 `INTEGRATED_RELEASE` 执行 `docker compose ... up -d --no-build`，更新 `current` 后复验健康、认证和 WSS。不得通过撤单或重发 UNKNOWN 命令实现回滚。

2026-10-31 迁移前的 release 依赖已删除的外部 MySQL / 网络，不能直接作为当前部署的回滚目标。本轮清理后仅保留当前 release 和使用中的镜像；后续发布需要保留兼容的整合版本。数据库灾难恢复必须使用受限备份并评估数据时间点，不能恢复旧 Java 栈来代替整合版恢复。

## 旧 USDC Java 环境退役记录

2026-10-31 在 47.80.22.243（首尔服务器）执行：

1. 核对旧交易账户 / 持仓 / 订单和整合版绑定 / 订单 / 限价单均为 0。
2. 将旧 schema、整合 schema 和配置备份到本机忽略且受限目录 `.integration-runtime/retirement-backup-20261031/`，权限分别为目录 700 / 文件 600；不加入 Git。旧数据不在目标机保留副本。
3. 停止旧 Java / Redis，冻结四个整合 Python 进程写入，最终逻辑导出整合数据库。从源 MySQL 26.7.0 恢复到独立 MySQL 8.4.13；没有搬用物理 data 目录。43 张表共 458,367 行的行数及按主键排序的完整行输出 SHA-256 全部一致，应用密钥、数据库应用密码和账号数据保留。
4. 切换到独立数据库与网络，复验六个服务健康、HTTPS / WSS 后，删除 `trade_app` / `trade_redis` / `trade_mysql`、其镜像、`trade_network`、整个 `/opt/trade-tool`、旧 Nginx 配置 / 日志 / 路由、旧续期 units / webroot、过期整合 release / 镜像和未使用构建缓存。
5. 宿主未安装 Java / JDK / JRE / Maven / Jenkins / MySQL / Redis 软件包；Java 运行时随旧镜像一起删除。Docker / Nginx / Certbot 仍被整合版使用，云厂商 agent 属于主机基础设施，予以保留。

本机最终 dump 的 SHA-256 与远端迁移报告一致；迁移报告 `/opt/trade-tools-integrated/migration-20261031.json` 只含表计数 / 哈希与版本，不含行内容或密码。远端临时 dump 和上传包已删除。数据库备份与应用解密配置必须一起保管，备份中可能含敏感数据，不能上传源码仓库。

## GitHub 源码交付

2026-11-03 后续用户明确要求本轮完成后直接提交推送，以 `dd4f048` 为基线交付策略编辑、指标卡片及透明度、连续 Super 填充、同触点十字线、默认杠杆、账户／持仓界面及普通信号 APNs／浮盈 Echo 分流源码。全部本地验证与范围见 [本批记录](changes.md#2026-11-03策略指标交互与通知分流源码交付)。沿用独立 Git 元数据推送 `codex/integrated-ios`；本次不追加部署、迁移或手动 TestFlight 上传，**47.80.22.243（首尔服务器）** 的运行范围继续以本页实际发布记录为准，完整通知及手机新包待配套验收。

2026-11-03 用户明确授权提交推送当前整合工作区全部未提交内容，本批以 `df1e032` 为基线，将 31 个客户端、测试及文档文件交付 `codex/integrated-ios`，包括其他会话留存的顶部控件、浮窗入口和周期／日期选项。范围与验证边界见 [本批交付记录](changes.md#2026-11-03图表账户反馈与顶部控件整批源码交付)。沿用既有独立 Git 元数据，父 Gitee 仓库及忽略的凭证、备份、构建不参与；本次不追加部署或手动上传 TestFlight。**47.80.22.243（首尔服务器）** 的实际运行代码继续以上方信号／杠杆限定发布为准。

2026-11-02 用户后续明确要求直接提交并推送全部改动，本批以 `d533b19` 为基线交付工作区 21 个文件到 `codex/integrated-ios`，包含此前开仓／持仓切页优化与十字光标／杠杆界面及配套测试、文档。验证证据及未验范围见 [整批交付记录](changes.md#2026-11-02开仓面板持仓缓存与十字光标整批源码交付)。本次不重新部署或手动上传 TestFlight；**47.80.22.243（首尔服务器）** 的运行状态继续以上方 API 限定发布为准，GitHub 全部源码交付不等于所有后端改动已上线。

2026-11-02 用户明确授权提交并推送当前整合工作区全部改动，包含其他会话内容；本批以 `f155c95` 为基线，通过既有独立 Git 元数据交付 `codex/integrated-ios`。范围和各任务已有验证见 [跨会话源码交付](changes.md#2026-11-02跨会话全部改动源码交付)。本次不执行新部署或手动 TestFlight 上传；源码交付不能替代 **47.80.22.243（首尔服务器）** 的运行版本核验，上方最后实际发布记录继续作为部署依据。

2026-11-01 本次用户授权整批提交并推送，收录工作区的界面／延迟、连续纵轴和行情协调／出口保护等全部安全改动，基线为 `fab71ee`；范围与既有验证见 [本次交付记录](changes.md#2026-11-01整批源码提交与-github-交付)。本次不执行服务器部署或手动 TestFlight 上传，源码交付与运行版本分别记录；上方 47.80.22.243（首尔服务器）的最后发布记录继续有效。

整合版仓库为 `https://github.com/qoqkeep-create/binance.git`，分支 `codex/integrated-ios`。有两种本地工作副本，操作前先核对 Git 元数据和 origin，不能仅凭相同目录名判断：

- 正常独立 clone：根目录有 `.git`，使用普通 `git` 命令，以 `git rev-parse --show-toplevel` / `git remote -v` 核对范围与仓库。Apple / Cloud 准备任务使用过这种副本。
- 原始嵌套交付目录：本目录位于父 Gitee 仓库内，没有本目录 `.git`，但已有 `.integration-runtime/github-publish.git`。本轮退役任务使用这种副本，显式指定独立 Git 元数据；不要对父仓库直接提交或重建不存在的元数据。

```bash
git --git-dir=.integration-runtime/github-publish.git --work-tree=. status
git --git-dir=.integration-runtime/github-publish.git --work-tree=. diff --check
```

Xcode Cloud 必须单独获得指定 GitHub 仓库的访问授权；本机 Deploy key 可推送不代表 Cloud 已获授权。

只提交本任务交付文件；来源目录、父仓库改动与历史不混入。环境文件、私钥、备份、日志、构建和 IDE 用户状态保持忽略。GitHub Deploy key 与目标机 SSH 密钥是不同认证，均不随代码交付。本机 SSH 443 / 代理设置只存于忽略的独立 Git 配置，其他机器正常 clone 即可。

推送授权以 [项目协作规则](../AGENTS.md#发布与验证) 为准。2026-11-01 用户明确授权本次 K 线诊断在需要发布客户端时完成后直接推送，并说明由其既有 Jenkins 调用 Apple 打包服务；这是本次任务授权，后续任务仍默认经用户批准再推送。本轮不修改 Jenkins 或 Apple 工作流；推送成功不代表打包、分发或手机安装成功。2026-11-01 的名称 / 图标 / 认证 / 白底启动页及开启注册整批获单次推送授权；验收见 [变更记录](changes.md)。推送可能触发 Xcode Cloud，源码推送与开启注册的授权范围不包含真实交易。

源码推送、47.80.22.243（首尔服务器）的部署和 TestFlight 上传分别记录，不能互相替代。手机签名 / 上传见 [TestFlight](testflight.md)，当前待验收项见 [已知事项](known-issues.md)。

2026-11-02 用户在本地图表／持仓／通知验收完成后授权“提交推送”，本批以 `17a3eda` 为基线交付 51 个文件到 `codex/integrated-ios`，范围与既有验证见 [变更记录](changes.md#2026-11-02图表持仓杠杆选择与通知源码交付)。生产 Echo／APNs 配置和密钥不随源码上传；本次不部署后端、重启服务或手动上传 TestFlight，47.80.22.243（首尔服务器）仍以上方通知配置准备及杠杆限定发布记录为准。

## 图表加载诊断

2026-11-01 按用户实际点击，47.80.22.243（首尔服务器）临时启用仅针对 K 线的 Nginx 阶段日志，采到 build 14 响应头约 72 ms、完整传送 4.62 秒。临时配置已撤销，站点文件与原备份 SHA-256 相同，`nginx -t`／reload 通过。配置备份和脱敏计时位于 `/opt/trade-tools-integrated/backups/kline-diagnostic-20261101/`，目录／日志保持受限；没有清空缓存、修改交易或发布新应用。结论和 upstream 背压解释见 [行情](market-data.md#手机实际请求与响应体传送)。

客户端新诊断已按本次授权提交交付，新增表 migration `market_stream.0003_chartloadreport` 已在 47.80.22.243（首尔服务器）完成，发布与验收见本页顶部。后续发布继续按既有 release／数据库备份流程迁移，再启新 API／market 镜像；API 与 market 配套，行情维护负责有界清理。该迁移只新增表，与旧版回滚兼容；代码回滚可保留表和既有数据，不需要反迁移，更不能通过回滚还原交易数据库。没有新凭证、端口或外部服务。

迁移部署后在所选 release 的 API 容器执行只读查询（用既有 Compose 参数，不打印 env）：

```bash
python manage.py chart_load_reports --build <构建号> --limit 10
python manage.py chart_load_reports --trace-id <追踪UUID> --limit 1
```

命令限最多 50 条，输出服务端接收时间及固定公共诊断 payload，不输出账户标识。诊断表仍按登录用户关联，不能将其当匿名数据公开；访问仅限既有受控运维。保存边界和保留策略见 [行情协议](market-data.md#客户端加载诊断)。旧 TestFlight 14 不会上报；2026-11-01 已在 47.80.22.243（首尔服务器）收到实际 iPhone 构建 15 的三轮九次 BTC1h 报告，确认手机上报／落库贯通。前六次首帧 2.00～6.94 秒、主要耗时在传输；BBR 对照后三次为 0.504／0.433／0.453 秒，阶段表与证据限制见 [真机排查](market-data.md#构建-15-真机传输排查2026-11-01)。

同日真机排查临时配置仅记录 BTC1h 的合法 trace、端口、连接数字 ID、代理计时和 TCP 数字指标，不记录认证、手机号／IP、完整 URL 或完整 UA。配置在安装前保存站点原文与 SHA-256，`nginx -t` 后平滑 reload，并设置 30 分钟自动恢复；TCP 采样也有时间和条数上限。受限证据位于 `/opt/trade-tools-integrated/backups/chart-transport-probe-20261101/`，本机副本位于忽略目录 `.integration-runtime/KlineDiagnostics/Phone15/`。这些临时操作不改变应用 release／镜像或迁移版本。

采样及自动回退定时器已停止，Nginx 原文哈希已恢复；后续单目的地址 BBR 对照和持久配置的结果统一见 [HTTPS 传输拥塞控制](#https-传输拥塞控制2026-11-01)。回滚所需的手机网络地址只短暂存在于受限操作状态文件，该文件在删除临时路由后已删除，不进入诊断日志或源码。
