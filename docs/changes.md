# 变更与验收记录

此处保留值得长期维护的里程碑，不替代 Git 日志或全量聊天历史。每条说明来源和范围；历史通过不代表本轮重新测试。

## 2026-10-31：退役首尔旧 Java 环境，独立数据库与远程模拟器验收

- 用户确认唯一目标为 **47.80.22.243（首尔服务器）**，并授权删除旧 USDC Java 系统及其专属支撑环境。协作规则已记录：向用户提及目标机操作或状态时写 IP＋备注。本地 USDT 456 个、USDC 476 个来源文件哈希再次核对一致。
- 先完成远程无绑定 QA 账号的模拟器页面验证，再备份两套数据库与配置至本机受限忽略目录。退役前复查旧交易账户 / 持仓 / 订单及整合绑定 / 订单 / 限价单六项计数均为 0，全程未调用交易所开平仓、划转或撤单接口。
- 在 47.80.22.243（首尔服务器）发布 `integrated-20261031-d2498172efa6`：六个服务使用独立默认网络，新增固定 digest 的 MySQL 8.4 和命名卷，移除外部 `trade_network` 依赖；初始化与发布脚本同步更新。停止四个 Python 写入进程后，从旧引擎 MySQL 26.7.0 逻辑导出整合 schema，恢复到 MySQL 8.4.13。43 张表、458,367 行的行数与按主键排序的完整行输出 SHA-256 全部一致；应用密钥、账号数据及应用数据库密码保持原值。最终 dump 与本机副本哈希一致，当前配置也已保存到本机受限备份。
- 切换并验证后，47.80.22.243（首尔服务器）已删除旧 `trade_app` / `trade_redis` / `trade_mysql` 容器及对应镜像、整个 `/opt/trade-tool`（含旧数据库、Redis 数据和日志）、`trade_network`、旧 Nginx 路由 / 配置 / 日志、旧证书续期 units / webroot、过期整合发布及未使用构建缓存。宿主原本没有 Java / JDK / JRE / Maven / Jenkins / MySQL / Redis 安装包，Java 运行时随旧镜像删除。保留整合版需要的 Docker / containerd、Nginx、Certbot 与有效证书，保留云厂商基础 agent。
- 47.80.22.243（首尔服务器）最后资源检查为六个容器全部 healthy、三份使用中镜像、两个使用中数据卷、构建缓存 0。根盘占用从盘点约 12GB 降为 6.9GB，可用约 31GB；内存可用约 2.2GB。旧 8686 / 3306 / 6379 监听已消失，API 8787 仅本机监听；整合健康入口 200，旧根路径和 `/ws/v1` 404。
- 新增整合 Nginx 站点、证书续期 service / timer 与 reload hook 四份模板。47.80.22.243（首尔服务器）继续复用有效 IP 证书的历史 lineage 名称 `trade-tool-seoul-ip`，ACME webroot 已迁入整合版路径，新的每六小时 timer active。`nginx -t`、普通 renew、ACME staging `renew --dry-run --run-deploy-hooks` 与 Nginx 自动 reload 均通过。
- 47.80.22.243（首尔服务器）的 HTTPS 登录 / Secure refresh、只读业务接口、401 / 404 隔离、300 根 1m / 1h K 线及历史分页、真实 WSS K 线 / ticker 和 ping / pong 通过。清理后容器经公网 HTTPS / Nginx 的 522 合约列表五次读取中位数 13.7ms，300 根 1m / 1h 为 17.5 / 17.6ms；15 秒 49 条事件的 eventTime 延迟中位数 / P95 / 最大值为 172 / 384 / 922ms。仅为短样本行情链路，不能推论实盘成交速度或固定性能倍数。本机脚本使用自动代理时出现 TLS / WSS 握手偶发超时；显式直连后完整流程通过（27 条行情事件，中位数 / P95 / 最大值 267 / 723 / 838ms），代理路径波动待定位，见 [已知事项](known-issues.md)。
- 本地 Xcode / iOS 27.2 的专用 iPhone 18 Pro 模拟器连接 47.80.22.243（首尔服务器），22:05 及 22:07 两次完整 UI 流程通过（45.4 / 43.1 秒）：退出后重新登录、真实行情、Metal 图表、持仓、无绑定开仓禁用、信号、我的与 API 表单。失败截图发现测试在系统保存密码弹窗退场时点击行情；测试增加弹窗消失及可点击状态等待，临时导航探针已删除，产品页面代码无持久改动。实际查看截图，报告位于忽略目录 `.integration-runtime/RemoteUIFinal.xcresult` 与 `RemoteUIFinalRepeat.xcresult`；结束后在 Xcode Device Hub 显示专用 `TradeTools Integrated` 模拟器的已登录真实行情页面并保持运行。本轮验证范围为部署、数据迁移、脚本语法与定向 UI，没有扩大为 iPhone 实机、TestFlight 上传或真实交易通过。
- 同步维护运维、架构、配置、整合、开发、TestFlight 与已知事项主文档；临时退役计划已合入主文档并移除。源码交付仍使用独立 GitHub 分支，父仓库与原项目文件保持原状。

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
