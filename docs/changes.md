# 变更与验收记录

此处保留值得长期维护的里程碑，不替代 Git 日志或全量聊天历史。每条说明来源和范围；历史通过不代表本轮重新测试。

## 2026-11-01：同步最新配置与新增持仓浮窗

- 从指定 GitHub 的 `codex/integrated-ios` 拉取至 `8afaa9b`，保留 Cloud / TestFlight 配置、工程排序和云端压力测试规则；本地 Web 复刻先提交为 `fb2e14f`，再合并为 `409e059`。合并前后 13 个业务 / 认证 / 导航源码的 SHA-256 一致；文档冲突保留双方记录，工程同时保留图标许可资源。只使用整合目录的独立 Git 元数据，来源项目与父仓库保持原状。
- “我的”新增“持仓浮窗”开关，184 × 82 pt 的 App 内原生卡片显示交易对、方向、市价与浮盈，可拖动、关闭和点击切换多笔持仓，跨底部页面及导航详情显示。只调用已有持仓查询，使用 Decimal 和同一服务端快照；前台定时与账户事件刷新，关闭 / 后台 / 换身份废弃旧响应，失败不显示旧价格。UI 偏好与持仓数据分开，详情见 [持仓浮窗](ios-floating-positions.md)。
- 本地 `TradeTool` 全量单测 172 项通过，新增 8 项覆盖精度、空仓、失败、身份与请求隔离及拖动边界，结果为 `.integration-runtime/FloatingUnit.xcresult`。首次 UI 测试暴露 DEBUG 独立 UserDefaults 的多个实例无法同步 AppStorage，改为共享实例后，两项浮窗 UI 流程全部通过（42.7 秒），结果为 `.integration-runtime/FloatingUI2.xcresult`；已实际打开浅色多仓、持仓页、拖动后详情页、深色带单、无仓和未绑定截图。
- 最终代码的 8 项浮窗单测再次通过（`.integration-runtime/FloatingFocusedUnit.xcresult`）；generic iOS 的 Release 未签名构建通过，包内存在浮窗功能、Metal 库、隐私清单和 Lucide 许可，未包含 DEBUG 视觉 fixture 入口、测试账号或独立偏好 suite。工程语法、59 个本地文档链接及差异检查通过；新增源码、测试和主题文档 3 个文件纳入 Git。源码交付分支仍为 `codex/integrated-ios`，本次推送后的 Cloud 构建 / TestFlight 分发结果待另行核对，没有把源码推送或模拟器替身数据描述成 iPhone 或真实有仓验收。

## 2026-11-01：按原 USDT Web 重做原生业务页面

- 以原 Web 移动端源码、DOM、样式及 402 逻辑宽度截图为依据，重做认证、开仓、持仓 / 委托 / 历史、信号、我的、设置、策略、资金、日志、指标、看盘计划、交易前校准和信号研究页面及主要弹窗。对齐字体、间距、颜色、圆角、字段高度、固定底部操作和图标；Lucide 原路径用原生 Path 绘制，许可同时纳入源码和 App 资源。首个行情入口及 SwiftUI + Metal 图表沿用现有实现，研究历史图使用 Swift Charts。具体页面及平台差异见 [Web 原生复刻](ios-web-parity.md)。
- 复刻过程中修复首次持仓弹窗使用旧选择、资金预检仅补入资金被错误禁用、EMA 初筛后键盘遮挡主按钮、研究蜡烛实体 / 时间刻度，以及看盘评分区与底部按钮被长内容挤出的问题；复盘和结果弹窗按内容收缩，内容超高再滚动。批量平仓入口逐笔沿用既有持久化命令，按账户范围保存目标和幂等键，未知结果停止后续处理；本轮只查看预览和确认界面，没有执行真实资金操作，也没有修改 Python 后端交易规则。
- 本地 `TradeTool` XCTest 164 项通过，0 失败、0 跳过，结果为 `.integration-runtime/WebParityUnit2.xcresult`。包含止损金额 Decimal 分档与秒 / 毫秒时间解析回归；此后仅修整弹窗、图表、输入和资源打包，没有将早先全量单测描述成最后一次代码修改后的全量重跑。
- 本地 iPhone 18 Pro / iOS 27.2 的 8 个独立 `WebParityUITests` 流程分轮通过。`WebParityScreens4.xcresult` 的 7 组中 6 组通过；剩余组在启动回测页时 App 崩溃，缺少详细 crashlog，随后该模拟器也出现启动和显示超时，未据此判定根因为系统或代码。新建专用 `TradeTools Web Review` 模拟器后，`WebParityFinal6.xcresult` 的研究 / 资金 / 初筛及附属页面两组通过；新增评分组暴露真实布局问题，修复后 `WebParityWatch8.xcresult` 完整通过（34.5 秒），覆盖评分按钮可点击和滚动位置、复盘内容、结果金额及模型选择。已实际打开导出的核心页、浅深色、空态、带单和弹窗截图校对；没有把按钮存在的断言当作全部像素验收。
- DEBUG 视觉模式只使用隔离静态账号、数据与无网络 transport 的 API；允许资金预检 / EMA 的本地预览，其余写请求拒绝。最终 iOS 设备 Release 未签名构建通过，包内含隐私清单、Metal 库与图标许可，不含视觉 fixture 入口和样本标记。真机、TestFlight、邮件链接自动唤起、真实 AI / 通知发送与实盘仍需分别验收。本轮仅修改整合目录，未提交、推送、连接远程环境或上传 TestFlight。

## 2026-10-31：新应用 Cloud 自动构建与内部测试分发配置

- 已保存新 Cloud 产品 `f01be7a9-f719-4ecc-932e-17c7bac455a6` 的 `iOS TestFlight` 工作流，GitHub 授权仅选择 `qoqkeep-create/binance`，关联 App Store Connect `TradeTools USDT` / `6829222305`。发布身份、Push capability、工作流及编号细节见 [TestFlight](testflight.md)。
- 首次将 Next Build Number 保存为 4；同时发生的远端源码推送自动产生默认编译构建 4、5，均成功。保留并合并另一批服务器运维提交后，`e7734bb` 已推送，分支 SHA 与远端一致，自动触发完整流程构建 6。
- 构建 6 的 Metal 脚本、云端 Release Archive、app-store 导出与 App Store Connect 准备均成功；图表压力测试的 P95 为 426ms，超过本地模拟器 150ms 阈值。仅对 Apple 明确标识的 Cloud 环境改为记录耗时，保留覆盖率、帧并发、缓冲区和命令错误检查；本地仍执行原耗时断言。修改后本地常规模式与 `TEST_RUNNER_CI_XCODE_CLOUD=TRUE` 模式各 3 项压力测试通过，报告为 `/tmp/binance-cloud-setup/LocalStressBudget.xcresult` 与 `CloudStressMode.xcresult`。
- 修正提交 `509f2da` 已推送并自动触发构建 7：云端测试、Release Archive 和 TestFlight Internal Testing 后续操作全部成功，约 4 分钟完成。Apple 处理已结束，`1.0.1 (7)` 自动加入“内部测试”组并显示“正在测试”，1 名测试员状态“已邀请”；构建 6 被新推送自动取消，未人工将其分配到组。Cloud 构建与 TestFlight 页面链接见 [指南](testflight.md#本轮分发结果)。
- 手机接受邀请、安装和运行尚待测试者完成，不将后台“正在测试”表述为 iPhone 实机通过。工程语法、文档链接及差异检查通过，原有工程排序改动仍保持未提交；通过 OpenStep plist 转 JSON 比较确认剩余工程差异只有顺序变化。

## 2026-10-31：退役首尔旧 Java 环境，独立数据库与远程模拟器验收

- 用户确认唯一目标为 **47.80.22.243（首尔服务器）**，并授权删除旧 USDC Java 系统及其专属支撑环境。协作规则已记录：向用户提及目标机操作或状态时写 IP＋备注。本地 USDT 456 个、USDC 476 个来源文件哈希再次核对一致。
- 先完成远程无绑定 QA 账号的模拟器页面验证，再备份两套数据库与配置至本机受限忽略目录。退役前复查旧交易账户 / 持仓 / 订单及整合绑定 / 订单 / 限价单六项计数均为 0，全程未调用交易所开平仓、划转或撤单接口。
- 在 47.80.22.243（首尔服务器）发布 `integrated-20261031-d2498172efa6`：六个服务使用独立默认网络，新增固定 digest 的 MySQL 8.4 和命名卷，移除外部 `trade_network` 依赖；初始化与发布脚本同步更新。停止四个 Python 写入进程后，从旧引擎 MySQL 26.7.0 逻辑导出整合 schema，恢复到 MySQL 8.4.13。43 张表、458,367 行的行数与按主键排序的完整行输出 SHA-256 全部一致；应用密钥、账号数据及应用数据库密码保持原值。最终 dump 与本机副本哈希一致，当前配置也已保存到本机受限备份。
- 切换并验证后，47.80.22.243（首尔服务器）已删除旧 `trade_app` / `trade_redis` / `trade_mysql` 容器及对应镜像、整个 `/opt/trade-tool`（含旧数据库、Redis 数据和日志）、`trade_network`、旧 Nginx 路由 / 配置 / 日志、旧证书续期 units / webroot、过期整合发布及未使用构建缓存。宿主原本没有 Java / JDK / JRE / Maven / Jenkins / MySQL / Redis 安装包，Java 运行时随旧镜像删除。保留整合版需要的 Docker / containerd、Nginx、Certbot 与有效证书，保留云厂商基础 agent。
- 47.80.22.243（首尔服务器）最后资源检查为六个容器全部 healthy、三份使用中镜像、两个使用中数据卷、构建缓存 0。根盘占用从盘点约 12GB 降为 6.9GB，可用约 31GB；内存可用约 2.2GB。旧 8686 / 3306 / 6379 监听已消失，API 8787 仅本机监听；整合健康入口 200，旧根路径和 `/ws/v1` 404。
- 新增整合 Nginx 站点、证书续期 service / timer 与 reload hook 四份模板。47.80.22.243（首尔服务器）继续复用有效 IP 证书的历史 lineage 名称 `trade-tool-seoul-ip`，ACME webroot 已迁入整合版路径，新的每六小时 timer active。`nginx -t`、普通 renew、ACME staging `renew --dry-run --run-deploy-hooks` 与 Nginx 自动 reload 均通过。
- 47.80.22.243（首尔服务器）的 HTTPS 登录 / Secure refresh、只读业务接口、401 / 404 隔离、300 根 1m / 1h K 线及历史分页、真实 WSS K 线 / ticker 和 ping / pong 通过。清理后容器经公网 HTTPS / Nginx 的 522 合约列表五次读取中位数 13.7ms，300 根 1m / 1h 为 17.5 / 17.6ms；15 秒 49 条事件的 eventTime 延迟中位数 / P95 / 最大值为 172 / 384 / 922ms。仅为短样本行情链路，不能推论实盘成交速度或固定性能倍数。本机脚本使用自动代理时出现 TLS / WSS 握手偶发超时；显式直连后完整流程通过（27 条行情事件，中位数 / P95 / 最大值 267 / 723 / 838ms），代理路径波动待定位，见 [已知事项](known-issues.md)。
- 本地 Xcode / iOS 27.2 的专用 iPhone 18 Pro 模拟器连接 47.80.22.243（首尔服务器），22:05 及 22:07 两次完整 UI 流程通过（45.4 / 43.1 秒）：退出后重新登录、真实行情、Metal 图表、持仓、无绑定开仓禁用、信号、我的与 API 表单。失败截图发现测试在系统保存密码弹窗退场时点击行情；测试增加弹窗消失及可点击状态等待，临时导航探针已删除，产品页面代码无持久改动。实际查看截图，报告位于忽略目录 `.integration-runtime/RemoteUIFinal.xcresult` 与 `RemoteUIFinalRepeat.xcresult`；结束后在 Xcode Device Hub 显示专用 `TradeTools Integrated` 模拟器的已登录真实行情页面并保持运行。本轮验证范围为部署、数据迁移、脚本语法与定向 UI，没有扩大为 iPhone 实机、TestFlight 上传或真实交易通过。
- 推送时发现同分支已有独立 App 身份 / Cloud 准备提交，合并保留远端新 Bundle ID、隐私清单与签名记录，统一两类 Git 工作副本的操作说明。22:21 使用 `com.waibao2025.trade.integrated` 在同一专用模拟器再次完成远程登录和全部页面验收（57.0 秒），报告为 `.integration-runtime/MergedIdentityUIRecheck.xcresult`；首次网络请求在等待窗口内未到达 Nginx，复测通过，该链路波动仍按已知事项记录。合并后的工程 / plist 校验、Metal 准备脚本四项替身测试与文档链接检查通过，合并提交 `5c90f17` 已推送到 `codex/integrated-ios`。
- 同步维护运维、架构、配置、整合、开发、TestFlight 与已知事项主文档；临时退役计划已合入主文档并移除。源码交付仍使用独立 GitHub 分支，父仓库与原项目文件保持原状。

## 2026-10-31：独立 App 身份与签名接入

- 按用户指定，将主 App 的三个配置统一为 `com.waibao2025.trade.integrated`，测试目标使用同前缀的独立标识；同步当前原生 UI 启动入口和运行时 Bundle ID 回退。保留工程既有排序改动，未将其混入本次配置提交。
- 核实 Apple 团队 GUANGDONG ZHANG / `756Y5JKBUD`，新 App ID 已注册且 Push Notifications 已开启。用户明确要求本轮只预留 Push capability，暂不开发 Python APNs 投递功能。App Store Connect 已创建用户确认的 `TradeTools USDT`，App ID 为 `6829222305`，SKU 为 `waibao2025-trade-integrated-ios`；内部测试组已创建并加入当前 Apple 账号。
- 新身份的本地 Release Archive 成功，使用该 App ID 的 Xcode 自动管理开发描述文件；`codesign --verify --deep --strict` 通过，签名中的 application identifier 为 `756Y5JKBUD.com.waibao2025.trade.integrated`。这是本地开发签名归档，APNs entitlement 为 development，不代表已完成 TestFlight 分发签名或生产推送验收。
- 同身份在 Xcode 27.1 / iOS 27.0 的 iPhone 18 Pro 模拟器执行 `TradeTool` 单测，162 项全部通过，0 失败、0 跳过；结果位于本机 `/tmp/binance-cloud-setup/IdentityTests.xcresult`。本轮没有操作真实交易账户或开发 APNs 服务端投递。
- 提交 `bd2ea0d` 已推送到指定 GitHub 的 `codex/integrated-ios` 分支。本地旧 Cloud manifest 指向旧 `td0328/trade-tool` 产品，已移除本地关联以便为新应用设置工作流；旧产品、工作流和构建记录未改动。随后用户确认并完成 `qoqkeep-create/binance` 的独立 Xcode Cloud GitHub App 授权，新 Cloud manifest 已生成。保存 `iOS TestFlight` 工作流：仅交付分支的 iOS 目录变更触发，Xcode 27.1 / macOS 27.0.1 / Clean、iPhone 18 Pro 必过单测、Release 归档及内部测试组自动分发；首个 Cloud Build 已设为 4；后续完整云端与分发结果见本文上方的 Cloud 交付记录。

## 2026-10-31：Xcode Cloud / TestFlight 源码准备

- 核对已有共享 Scheme、Cloud 关联 manifest 和工程旁可执行的 Metal 准备脚本；补充主 App `PrivacyInfo.xcprivacy` 与资源引用，声明 UserDefaults `CA92.1` 和图表 systemUptime `35F9.1`，不据此宣称 App 不收集数据。保留工程文件原有改动。
- 发布指南增加 Cloud 分支触发、Test action 使用 `TradeTool`、Archive 使用 `TradeTool Release`、自动签名和 TestFlight 分发组配置。构建号采用 Cloud 原生递增，首次后台核对 Next Build Number；无需自增脚本或提交版本回 Git。同步更新开发、已知事项、整合说明及当前独立 Git clone 的维护方式。
- 本机 Xcode 27.1（27A9275）/ iOS 27.1 SDK，`TradeTool Release` 的 generic iOS 未签名 Archive 成功，核对包内隐私清单与源码一致、`default.metallib` 和可执行文件存在，Bundle ID 为 `com.oovso.trade.integrated`、Version / 本地 Build 为 `1.0.1` / `3`、API 指向首尔整合入口。首次沙箱内无法访问 Metal 组件，允许 Xcode 访问已安装组件和缓存后归档成功，未下载或替换工具链。
- Metal 准备脚本四项替身测试、plist / 工程语法、资源引用、文档链接、`git diff --check` 和未追踪文件检查通过；新增隐私清单加入追踪。本轮没有修改 Apple 后台、执行云端签名归档、推送源码、上传 TestFlight 或验收手机安装，也没有重跑 XCTest 或后端测试。

## 2026-10-31：清理旧项目副本，仅保留整合实现

- 按用户要求删除 526 个旧文件，包括 Java 后端、React Web、原部署 / Compose / Jenkins、历史文档和环境模板、网络对比材料，以及未接入导航的旧原生页面和 LAN Scheme。整合后端、原生业务 / 行情 / Metal、共享模型、迁移与测试保留；当前交付共 449 个文件。
- 原生工程移除对应源码引用和空分组，默认 Debug 使用整合入口。删除的旧持仓页面及专属模型对应 5 项测试不再适用于当前客户端；其余原有测试保留。源码查询统一见新增 [来源索引](sources.md)，清理前快照为 `7e3d166`。同步重写入口、架构、开发、配置、行情和维护文档，原项目历史发布记录从原目录查询。
- 本地 Python 3.11 系统检查、迁移漂移检查与全量回归通过：900 项，7 项跳过；测试阻断外部网络，仅使用隔离测试数据。iPhone 18 Pro / iOS 27.2 模拟器 XCTest 162 项通过，iOS 设备 Release 构建通过（未分发签名）。Metal Toolchain 构建脚本替身验证、发布脚本语法、103 个 Xcode 文件引用、文档链接和 Git 差异检查通过。
- 本地 USDT 456 个、USDC 476 个来源文件的清理前后 SHA-256 一致；本轮没有修改外部原目录或服务器运行环境，也没有上传 TestFlight、进行真实资金操作或补做实机验收。独立 GitHub 分支交付本次清理；父仓库保留原有配置及其他改动。

## 2026-10-31：整合版推送至独立 GitHub 仓库

- 用户指定 `https://github.com/qoqkeep-create/binance.git`，并为本机专用 Deploy key 开通写入权限。首次提交 `1118eaa` 已推送至 `codex/integrated-ios`，远程分支 SHA 与本地提交一致；独立 Git 记录的维护方式见 [运维](operations.md#github-源码交付)。
- 974 个文件以本整合目录为仓库根目录，包含 Python 后端、原生 iOS、保留的参考代码、测试与文档。生产环境文件、私钥和运行目录未纳入提交；原 USDT / USDC 来源文件、父 Gitee 仓库历史和其他未提交改动未混入，也未修改父仓库远程配置。
- 本轮仅交付源码和同步推送记录，执行 Git 差异、文件范围及远程 SHA 检查，没有重新部署服务器、上传 TestFlight 或重跑应用测试。既有运行验证和待办仍以对应日期的记录及 [TestFlight 指南](testflight.md) 为准。

## 2026-10-31：Python + 原生 iOS 整合版独立部署及验收

- 当前目录整合原 USDT Python / Django 交易后端与原 USDC SwiftUI / Metal 行情。新增独立行情 Socket 采集、收线 / 缺口修复、多周期与历史分页、鉴权 WSS、账户事件 Inbox / Outbox、持久化命令及账户 lease / fence。原交易精度、模式身份、绑定代际、保护与结算规则继续由 USDT 服务负责。原生导航为行情、持仓、开仓、信号、我的；其他业务页面映射见 [整合说明](INTEGRATION.md)。
- SSH 部署至用户指定 `47.80.22.243`，版本 `integrated-20261031-ddec4af96a86`，独立目录 `/opt/trade-tools-integrated`、Compose 项目、Redis、新 MySQL schema / 受限用户；执行 Django 迁移后启动 API、market、worker、scheduler。17:07（北京时间）复验五个容器均 healthy，API 深度健康的数据库、迁移、scheduler 均通过。新管理员仅初始化空库，没有真实 API 绑定。
- 新入口 `https://47.80.22.243/integrated/` 使用既有有效 TLS 证书，Nginx 仅新增前缀并通过检查 / reload；原根路径和 `/ws/` 继续指向旧 Java。HTTPS 登录、Secure cookie refresh、只读账户接口、未认证 401、未知命令 404、历史分页排除边界、真实 BTC K 线 / ticker WSS 和 ping / pong 均通过。线上临时私有事件验证不同用户及 ordinary / lead 隔离，没有写交易命令或调用交易所写接口。
- 当时行情覆盖 522 个 USDT 永续合约。首尔容器经 HTTPS / Nginx 的列表 5 次读取中位数 12.9ms，300 根 1m / 1h 分别 23.5 / 20.0ms；15 秒 45 条行情事件的 eventTime 到接收端中位数 239ms、P95 670ms、最大 857ms。本机链路短样本中位数 302ms、P95 1179ms，出现最大 18265ms 离群点，待定位；完整口径见 [性能范围](INTEGRATION.md#本次服务器验收与性能范围)。不将行情延迟当作实盘成交速度，也不宣称固定快于旧 Java 的倍数。
- Python 全量 897 项通过（7 项跳过），最后定向回归 62 项通过，迁移漂移检查通过。Xcode 27.2 / iOS 27.2 iPhone 18 Pro 模拟器 XCTest 166 项通过，随后真实 Keychain 读写回归通过；17:08 完整原生 UI 流程 1 项通过并查看实际截图，覆盖真实行情、Metal 图表、五个 Tab、禁用开仓及 API 绑定表单。修复“我的”菜单中间空白不能点击，使用整行矩形点击范围；测试处理系统保存密码提示。`Debug-Seoul` / `Release` 默认地址均为新入口。
- 原 USDT 470 个来源文件哈希均未变；原 USDC 1536 个基线中源码未变，仅另一个既有监测任务的 3 个运行产物变化，未回滚它们。首尔旧 `trade_app`、`trade_mysql`、`trade_redis` 的容器 ID、镜像和启动时间与部署前一致。配置和初始访问资料仅放受限文件，没有纳入 Git；未提交或推送父仓库，不触发原生产自动发布。
- 未进行真实开平仓、资金划转、撤保护单、修改旧订单策略或实机测试。SMTP、AI 私密模型、外部通知和 Python APNs 接入仍有配置 / 实现边界；真实绑定后的交易与订单维护需按受控业务验收。部署、回滚及限制以 [运维](operations.md) 和 [整合说明](INTEGRATION.md) 为准。
