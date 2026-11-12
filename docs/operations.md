# 整合环境部署与运维

<a id="完整同源发布20261112-条件单终态查询"></a>

## 完整同源发布（2026-11-12，手动仓条件单终态查询修复）

提交 **`7ed091ff61dabf54fb0653d01c9af336913aadc3`** 已推送至 GitHub `codex/integrated-ios`，并按用户授权将完整同源后端发布到 **47.80.22.243（首尔服务器）**。当前发布目录为 `/opt/trade-tools-integrated/releases/integrated-20261112-full-7ed091f`，API／market／worker／scheduler 统一使用镜像 `tradetools-integrated:integrated-20261112-full-7ed091f`。

本次修复 Binance 条件单已经触发、取消或过期后精确查询返回 `order does not exist` 的正常终态：适配层按空结果处理，已结束的旧止损进入恢复补挂；提交结果仍未知的请求继续等待幂等核对，不重复提交，也不再把原始错误展示在持仓卡片。数据库 gzip 备份 **401138839 bytes**，无待应用 migration；MySQL／Redis、数据卷、环境文件和 Nginx 配置保持不变。六个容器均 healthy，公网健康检查返回 `{"status":"ok","checks":{"database":true,"migrations":true,"scheduler":true}}`；活动仓位、待成交委托及 PENDING／RUNNING 命令均为 0，原有 **UNKNOWN 1** 保持原样。

本地相关后端回归 **341 项／0 失败**，线上只做健康、数据库、迁移、scheduler 和状态只读核验，没有执行真实开仓、撤单、止损、平仓、划转或保护单操作。按用户授权清理了两份旧数据库备份，并清理可重建的 Docker 构建缓存以完成发布空间回收；当前发布备份仍保留，可按其回滚脚本恢复旧应用镜像和 `current`，不恢复数据库、不反迁移、不重放交易命令。这里的切换仍是同一台 **47.80.22.243（首尔服务器）** 内的 release／镜像切换，不是从 USDT 项目服务器迁移。

<a id="完整同源发布20261112b85356f"></a>

## 完整同源发布（2026-11-12，手动仓位与 Maker 投影修复）

按用户“提交所有更改并部署”授权，将提交 **`b85356f5b387e4a7ea412163ec1b7262b4dadbbd`** 推送至 GitHub `codex/integrated-ios`，并把完整同源后端发布到 **47.80.22.243（首尔服务器）**。发布目录为 `/opt/trade-tools-integrated/releases/integrated-20261112-full-b85356f`，API／market／worker／scheduler 统一使用镜像 `tradetools-integrated:integrated-20261112-full-b85356f`；319 个运行 Python／requirements 文件与提交清单完全匹配。

北京时间 **2026-11-12 06:15:40** 切换完成。数据库 gzip 备份 **400880380 bytes**，无待应用 migration；MySQL／Redis 容器、卷、环境文件和 Nginx 配置保持不变。切换前后活动持仓、待成交限价、PENDING／RUNNING 命令均为 0，原有 **UNKNOWN 1** 保持原样，没有重放或强改未知命令。六个容器均 healthy，公网健康、数据库／migration／scheduler 验收及 13 个行情周期／192 个历史窗口核对通过；隔离 MySQL／Redis 回归 **53 项通过**，没有真实开仓、撤单、止损、平仓、划转或保护单操作。

这里的“切换”是同一台 **47.80.22.243（首尔服务器）** 内由旧 release／镜像切到新 release／镜像，不是从 USDT 项目的服务器迁移。iOS 整合项目此前一直使用这台首尔服务器；原 USDT／USDC 来源目录和旧生产栈不属于本次运行目标。后续回滚使用该备份中的脚本恢复旧四个应用镜像和 `current`，保留数据库、基础设施及交易事实，不恢复数据库、不反迁移、不重放 UNKNOWN 命令。

<a id="完整同源发布20261112"></a>

## 完整同源发布（2026-11-12）

按用户“提交部署”授权，将完整整合工作区提交 **`06619e7d402ce184a042a112f719d4bb7dd3783c`** 推送至 GitHub `codex/integrated-ios`，并将同源后端发布到 **47.80.22.243（首尔服务器）**。发布目录为 `/opt/trade-tools-integrated/releases/integrated-20261112-full-06619e7`，API／market／worker／scheduler 统一使用镜像 `tradetools-integrated:integrated-20261112-full-06619e7`；运行源码清单 **319 个 Python／requirements 文件**逐项匹配，归档包含 **333 个**后端／部署文件。

北京时间 **2026-11-12 05:35:07** 切换完成。数据库 gzip 备份 **401400449 bytes**，没有待应用 migration；MySQL／Redis 容器、卷、环境文件和 Nginx 配置保持不变。切换前后活动持仓、待成交限价、PENDING／RUNNING 命令均为 0，原有 **UNKNOWN 1** 保持原样，没有重放或强改未知命令。六个容器均 healthy，公网 `/integrated/v1/health` 返回 200，数据库／migration／scheduler 检查通过；13 个行情周期、192 历史窗口和保证金／浮盈监控只读核验通过。

部署前可用磁盘约 **1.61 GiB**，低于历史发布脚本的 3 GiB 预警值；本次确认构建镜像约 319 MB、备份完成后切换成功，未删除历史备份或 Docker 数据。后续发布前仍需优先补充磁盘或制定受控的历史归档清理方案。隔离 MySQL／Redis 回归 **53 项通过**，没有真实开仓、撤单、止损、平仓、划转或保护单操作。证据保存在本机忽略目录 `.integration-runtime/FullDeliveryNov12/` 与服务器备份 `/opt/trade-tools-integrated/backups/integrated-20261112-full-06619e7/`。

<a id="完整同源发布20261111"></a>

## 完整同源发布（2026-11-11）

按用户“把未提交的全部提交部署”授权，整合工作区全部 25 个待交付文件以 `4fc9e9b` 提交推送，包含独立目录整理、统一委托 API／iOS 卡片、限价图表冻结与挂单导航，以及发布核验定位的市价提交回调修复。隔离 MySQL 验证发现两处测试可移植性假设后，以 `14e1182` 补齐测试和验证文档；没有略过失败，也没有实现此前仅讨论的逐仓保证金规划。

北京时间 **01:54:57**，将完整同源后端 `14e1182dc45960cc19c0ff60621a4bc0f4cec439` 部署至 **47.80.22.243（首尔服务器）**。`current` 为 `/opt/trade-tools-integrated/releases/integrated-20261111-full-14e1182`，API／market／worker／scheduler 统一使用 `tradetools-integrated:integrated-20261111-full-14e1182`。归档 **333 个文件**逐项匹配 Git；四个应用容器各 **319 个 Python／requirements 文件**全部匹配 manifest，不采用选择性覆盖。归档 SHA-256 为 `242fd91379b9ad976a4748084b986a3f518e486003326110fdfc349eb81c60a5`。

完整后端隔离回归 **1166 项、0 失败、6 项 opt-in 跳过**；最终包在没有生产配置／数据卷、没有外网的一次性 MySQL／Redis 上 **52 项／29.668 秒／0 失败／0 跳过**。首轮测试假设修正与 iOS 的 34 项 host、Release／build-for-testing 编译边界见 [开发](development.md#完整交付验证20261111)。

一致性数据库备份 **396362800 bytes**，完整 gzip 解压及 SHA-256 校验通过。受限备份目录 `/opt/trade-tools-integrated/backups/integrated-20261111-full-14e1182/` 包含旧容器与来源、环境／nginx 副本、结果及 `rollback.sh`。仅执行 `migrate --check`，没有应用 schema／数据迁移、初始化账号或重置队列。先停止旧 worker／scheduler，再以 `--no-deps --no-build --pull never --wait` 切换同源四服务；MySQL／Redis 容器 ID、镜像及卷保持原样，环境文件 inode／大小／mtime／权限和 nginx 哈希不变，`nginx -t` 通过。

切换前后数据库计数相同：活动持仓 0、待成交限价 0、PENDING／RUNNING 0、**UNKNOWN 1**。原未知命令保持待核对，没有手工重放或强改状态；没有执行真实开平仓、划转、撤保护单或发送测试通知。这些本地订单计数不代替交易所完整对账。

**01:55** 只读验收：六服务 healthy；公网 HTTPS 健康 200，统一委托匿名 401，两个现有有效绑定分别以不持久化的短期 access JWT 读取 `GET /v1/trade/order/list` 均返回 HTTP／业务 200，未解密 API Key 或请求交易所。QA 鉴权、BTC1h 1500 根与尾部 2 根、六类统计后台收敛、2h 周期、WSS ready／订阅 ACK／ping-pong／K 线／ticker 通过。三连接同时收行情，Redis 实际仅一条 Pub/Sub 连接；gzip **69918 bytes**、解压 JSON **423012 bytes**，identity 兼容。13 周期与 192 窗口保持，注册及通知开关不变。

后续 Compose 必须使用该 release 的 `compose.integrated.yaml` 加 `compose.runtime.yaml`，设置 `INTEGRATED_RELEASE=integrated-20261111-full-14e1182`；后者固定当前 MySQL／Redis 镜像。回滚执行上述备份中的 `rollback.sh`，恢复旧四应用镜像和 `current`，保留数据库、基础设施与实际订单／通知事实，不恢复数据库、不反迁移、不重放未知命令。完整证据保存在忽略目录 `.integration-runtime/FullDeliveryNov11/`。iOS 由现有 Xcode Cloud 自动构建，后端部署不代表手机更新，见 [TestFlight](testflight.md#统一委托源码自动构建20261111)。

## 确认弹窗修复发布核验（2026-11-10）

用户授权全部提交部署，客户端修复 **`bc6f49b`** 已推送 GitHub `codex/integrated-ios`。2026-11-10 **17:28～17:30（北京时间）** SSH 只读核验 **47.80.22.243（首尔服务器）**：`current` 仍为 `integrated-20261109-maker-f1f8254`；其 329 个受追踪后端／部署文件与交付源码一致，api／market／worker／scheduler 运行容器的各 317 个 Python／requirements 文件也逐项匹配，全部零差异。六容器 healthy，公网 HTTPS 健康 200，database／migrations／scheduler 检查通过。

本轮及该运行版本之后的全部提交只改客户端、测试或文档，没有尚未上线的配套后端，所以保留相同运行版本，不为相同源码重建镜像、重启容器或切换 `current`。未执行迁移、初始化、真实交易、划转、撤保护单或修改既有持仓。客户端发布需等待本次 Xcode Cloud 构建与分发，不能把后端同源核验写成手机已经生效；见 [交付记录](changes.md#2026-11-10确认弹窗修复完整源码交付与发布核验)及 [TestFlight](testflight.md#确认弹窗修复自动构建2026-11-10)。本地只读证据位于忽略目录 `.integration-runtime/ModalDeliveryNov10/`。

## Maker 开仓链路发布（2026-11-09）

2026-11-09（北京时间）按用户“推送 GitHub 并部署到云能服务器”的授权，将 GitHub `qoqkeep-create/binance` 的 `codex/integrated-ios` 提交 **`f1f8254`** 部署至 **47.80.22.243（首尔服务器）**。发布目录为 `/opt/trade-tools-integrated/releases/integrated-20261109-maker-f1f8254`，`current` 已切换到该目录；API、market、worker、scheduler 四个应用容器均使用镜像 `tradetools-integrated:integrated-20261109-maker-f1f8254`。

首次远程发布在补齐 release 的 `server.env` 符号链接前停止，未切换应用容器。重试阶段 Compose 重新核对了 MySQL 容器，但继续使用既有命名卷 `tradetools-integrated_integrated-mysql`；Redis 及其 AOF 卷未重建。最终应用切换使用 `--no-deps`，没有再次操作 MySQL／Redis。发布前备份位于 `/opt/trade-tools-integrated/backups/integrated-20261109-maker-f1f8254/`，包含数据库 gzip、受限环境副本、前版路径和发布前计数。

切换前只读计数为活动持仓 1、PENDING／RUNNING／UNKNOWN 命令 0、待成交限价 0；没有真实开仓、撤单、资金划转或撤保护单。`migrate --check` 通过，`bootstrap_mobile` 报告已有用户且未改账号或密码。切换后六个容器均 healthy，公网 `https://47.80.22.243/integrated/v1/health` 返回 **200**，数据库／迁移／scheduler 检查均通过；应用数据库复核活动持仓仍为 1、未完成交易命令为 0。日志尾部未发现应用错误。

本次线上验收只覆盖服务切换、健康检查和只读数据保护；真实 Binance Maker 成交、拒单重试、持续状态弹窗及 iOS 新包仍需在受控账户和客户端构建中分别验收。回滚应恢复备份记录的前版 `integrated-20261106-full-7e29236` 与 `current`，不恢复数据库、不反迁移、不重放交易命令。

## 完整同源发布（2026-11-06）

2026-11-06 **17:43:52（北京时间）**，按用户“全部提交推送部署，不绕过其他更改”的要求，将完整源码 `7e29236` 部署至 **47.80.22.243（首尔服务器）**。`current` 为 `integrated-20261106-full-7e29236`，API／market／worker／scheduler 均使用同一完整镜像 `tradetools-integrated:integrated-20261106-full-7e29236`，不再组合不同限定源码；331 个归档文件与 Git 存档逐项相符，四个进程各 **317 个运行 Python／requirements** 哈希完全匹配。包含此前已推送但未上线的 API 共享行情分发、私有事件批量投递／余额事实分流、账户流连接守卫、调度预热去重、全部 13 种行情周期、注册权限／短 Key、浮盈与 >75% 保证金独立 Echobell 任务，以及已有首屏同步补线／缓存／gzip 改动。

发布前只读确认本地活动仓位、待成交限价和 RUNNING 命令均为 0，未把这些计数当成交易所完整对账。完整后端 SQLite／隔离 Redis 回归最终运行器计数 **1141 项、零失败、6 项 opt-in 跳过**；另在无生产环境、无生产数据卷、无外部网络的临时 MySQL／Redis 上 **55 项通过、0 跳过**，涵盖这些并发／迁移合约及新增通知。账户事件测试因 `TestCase` 包装事务与真实连接清理不兼容而在 MySQL 首轮失败，已改为 `TransactionTestCase` 并重跑通过，未绕过测试。验证详见 [开发](development.md#完整版本发布验证2026-11-06)。

一致性数据库备份 **371387962 bytes**，完整 gzip 解压与 SHA-256 校验通过；目录 `/opt/trade-tools-integrated/backups/integrated-20261106-full-7e29236/` 为 0700，含前版容器、来源、受限配置与回退脚本。仅应用 `positions.0029_positionprofitwatch_positionprofitalert` 和 `positions.0030_position_margin_alerts`，各新增两张通知状态／投递表；没有改写既有订单、策略、账号或迁移回填。随后 `migrate --check` 通过。停止旧 worker／scheduler 后启动同源四服务，避免旧新后台混跑；没有初始化账号、重置队列、手工交易、资金划转或撤保护单。

MySQL／Redis 容器 ID、镜像及数据卷原样，Redis 保持 AOF、256 MiB maxmemory／320 MiB 容器限额，MySQL 保持 1／2 GiB 内存／swap 限额；本轮无需再次重建 Redis。环境文件 inode／大小／mtime／权限不变。宿主 nginx snippet 与完整源码模板哈希相同，`nginx -t` 通过，继续 gzip；没有为相同配置再 reload。后续 Compose 使用本 release 的 `compose.integrated.yaml` **加 `compose.runtime.yaml`**，设置 `INTEGRATED_RELEASE=integrated-20261106-full-7e29236`；后者仅固定当前 MySQL／Redis 镜像，四个 Python 服务同源，原六层限定 override 留在旧 release 作历史证据。

六服务 healthy，公网 HTTPS／QA 鉴权、BTC1h 1500 根／尾部 2 根及六类统计、鉴权 WSS ready／订阅 ACK／ping-pong 和 K 线／ticker 通过。**3 个同时连接均收到订阅行情，Redis 实际仅 1 条 Pub/Sub 连接（公共主题使用模式订阅）**，确认共享分发实际运行；不是纯进程内采集网关。新增 BTC2h 两根读取通过。公网 gzip **69850 bytes**、解压 JSON **423035 bytes**，identity 响应与 Vary 正常。注册开关仍为 true，QA 无管理权；普通／live APNs、浮盈和保证金监控开启，仓位通知、外部交易通知和外部 HTTP 接收继续关闭。自动通知自然触发、手机点击和首帧性能仍待实机验收，本轮没有发送测试通知。

回滚执行备份中的 `rollback.sh`，恢复原四个 Python 镜像和 `current`，保留 MySQL／Redis、已新增通知表及实际投递记录；**不恢复数据库、不反迁移、不重放未知通知或交易命令**。本地证据在忽略的 `.integration-runtime/FullReleaseNov6/`。客户端换根修复在 `79f812b`，完整后端在 `7e29236`；全部源码已推送 `codex/integrated-ios`，后续验收文档另提交。客户端 Cloud／TestFlight 与手机状态见 [TestFlight](testflight.md#换根修复与完整源码交付2026-11-06)，后端部署不能使旧安装包获得换根修复。

唯一目标为 **47.80.22.243（首尔服务器）**。原 USDT 生产环境及本地来源目录不属于本轮操作范围。用户已授权整合版部署与旧 USDC Java 环境退役；普通验收禁止真实开平仓、划转或撤保护单。各日期段落描述当时状态，当前运行版本以上方最新实际发布为准。

## 首屏补齐、Redis 扩容与 nginx 压缩发布（2026-11-06）

2026-11-06 16:44:27（北京时间）已将 Qoder 提交 `bb5e53b483ecc4f6367f7ce6e56ab52d1ab2c330` 的限定行情改动部署至 **47.80.22.243（首尔服务器）**。`current`／API 为 `integrated-20261106-firstscreen-api-bb5e53b`，market 为 `integrated-20261106-firstscreen-market-bb5e53b`；分别以上一版保证金 API 与历史缓存 market 的实际来源为基线，`scope=limited-first-screen-redis-gzip`。每包只变更 4 个运行 Python 文件、2 个测试文件与 Compose／nginx 共 8 条路径；API 的 307、market 的 296 个运行 Python／requirements 哈希全部匹配 manifest。没有整包覆盖 HEAD，也没有纳入共享分发、新增周期或账号／保证金通知后端。

发布前完成 299 项 HEAD 定向回归、两个实际限定包各 277 项回归。重新核对运行基线、环境文件和配置差异，构建两镜像，执行 `migrate --check` 后生成数据库一致性备份（gzip **370360137 bytes**，完整解压验证）。切换前 RUNNING 命令计数为 0。没有应用 schema／数据迁移，没有真实交易、资金划转、保护单或策略操作。

先备份并同步 `/etc/nginx/snippets/tradetools-integrated.conf`，`nginx -t` 通过后 reload，再移除旧 API 的 Django gzip，避免交接出现未压缩响应。宿主 snippet 与发布模板哈希一致，最终为 `fefffe62213ab892f9411d46ebf68a354ea9b321ff073cb6b5105c62ed0c397f`。Redis 正常停机（exit 0、非 OOM），离线备份原 `/data` 卷为 `redis-data.tar`（**25405440 bytes**，读取及 SHA-256 校验通过），随后强制重建 Redis。原 `tradetools-integrated_integrated-redis` 卷、Redis 二进制镜像哈希、AOF／everysec／noeviction 保留；新容器实际 `maxmemory=268435456`（256 MiB）、cgroup memory **335544320**（320 MiB），AOF 加载完成、写状态正常且数据库有数据。停机发起至 Compose 健康确认约 **11.14 秒**，含健康检查等待，不能等同于全部时间都不可用。未删除卷、清缓存或恢复旧键。

随后配套替换 API／market，六服务 healthy；worker、scheduler、MySQL 容器 ID 和镜像哈希原样，环境文件 inode／大小／mtime／权限原样。备份、前后容器／Redis 状态、来源 manifest、部署日志与结果保存在 `/opt/trade-tools-integrated/backups/integrated-20261106-firstscreen-api-bb5e53b/`（0700）；本机证据在忽略的 `.integration-runtime/FirstScreenDeployNov6/`。

后续 Compose 必须带齐新 API release 下的 `compose.integrated.yaml`、`compose.signal-leverage.yaml`、`compose.entry-ema.yaml`、`compose.history-cache.yaml`、`compose.margin.yaml`、`compose.firstscreen.yaml`，并设置 `INTEGRATED_RELEASE=integrated-20261106-firstscreen-api-bb5e53b`。最后一份固定两目标镜像／构建目录及其他实际镜像，Redis 固定原镜像 ID，禁止无意拉新版本。旧长运行容器的 Compose 标签可能指向已清理的十月归档；操作以这里现行完整文件链为准。

回滚执行上述备份的 `rollback.sh`：恢复原 API／market、旧 nginx snippet 和 `current`，**保留 Redis 扩容与原 AOF 卷**，不还原数据库、不反迁移、不重置队列。扩容后不自动缩回 80 MiB，以免新缓存已超过旧上限；若需独立重建 Redis，应使用备份中的 `compose.rollback.yaml` 与原完整配置链，不删除卷。

16:45:12（北京时间）公网验收通过：HTTPS 200、既有 QA 鉴权、BTCUSDT 1h 的 1500 根与尾部 2 根、六类统计、鉴权 WSS ready／订阅 ACK／ping-pong 及真实 K 线／ticker。原始 wire 检查 gzip **69910 bytes**、解压 JSON **423036 bytes**，identity 响应 **423036 bytes**，`Vary: Accept-Encoding` 正常；六服务和 192 窗上限再次核验。手机首帧收益及发布前后 `ChartLoadReport` 边界见 [行情](market-data.md#首屏同步补齐与传输调整2026-11-06)，不能由接口冒烟推导手机提速。

本轮按授权推送 GitHub `codex/integrated-ios`，包括此前仅本地提交的 `261cf59` 客户端及 Qoder 的 `bb5e53b`；交给现有前端自动构建流程。推送不代表 Cloud／TestFlight 已成功或手机已安装；没有手动上传。`261cf59` 的注册权限、短 Key 字段和保证金 Echobell 后端／迁移仍未部署，详见 [已知事项](known-issues.md)。

## 保证金只读接口限定发布（2026-11-06）

2026-11-06 15:36:55（北京时间）已将 `ba4b9e0` 中的保证金读取范围部署至 **47.80.22.243（首尔服务器）**。`current`／API 为 `integrated-20261106-margin-api-ba4b9e0`，以上一版 `integrated-20261106-history-cache-api-a91850b` 的实际归档为基线；market 继续为 `integrated-20261106-history-cache-market-a91850b`，worker／scheduler／MySQL／Redis 保留原镜像，六服务 healthy。本节保留当时状态，当前 API 以上方最新实际发布为准。

此前运行包缺少 `GET /v1/position/margin`，本次只叠加该接口、路由、只读账户适配器、带单读取允许路径及两个 GET 的权重声明，附对应测试；共 6 个允许路径，321 个来源文件中 315 个原样。适配器只 GET `accountConfig`／`fapi/v2/account`，使用 BACKGROUND 预算且各权重 5，不执行交易对账或订单／资金／保护操作。缓存 1 秒，事件／详情／手动请求 `fresh=1` 可绕缓存；无需 schema／数据迁移。限定包 63 项隔离回归通过，见 [开发](development.md#持仓紧凑切页与保证金双卡片2026-11-06)。没有整包替换为 HEAD，未带入共享行情分发或其他交易修改。

归档 SHA-256 为 `aed3f83215e391cae32fc4e8957a4c26e39cd79849d4fcf681c0a23c9cf9c959`，两端相同；307 个运行 Python／requirements 哈希与 manifest 一致。备份位于 `/opt/trade-tools-integrated/backups/integrated-20261106-margin-api-ba4b9e0/`（0700），含前版、容器、来源、配置回退命令与结果；数据库 gzip **369640322 bytes**，进程返回和完整解压校验通过。仅 `migrate --check`，没有应用迁移／恢复数据库／重放队列。切换前 RUNNING 命令计数为 0；仅替换 API，其余五服务容器 ID 与镜像哈希不变，环境文件的 inode／大小／mtime／权限未变。

沿用前三份 Compose 加 `compose.history-cache.yaml`，再叠加 `compose.margin.yaml` 固定新 API 及其他实际镜像，API 配置除镜像／构建路径外与原版一致；后续 Compose 操作不能遗漏任一 override。`INTEGRATED_RELEASE=integrated-20261106-margin-api-ba4b9e0`。回滚执行上述备份的 `rollback.sh`，只恢复原 API 镜像和 `current`，保留数据库、其他服务及环境；保证金接口会随回滚消失，需评估客户端兼容，不反迁移。

15:37:15（北京时间）复核六服务健康，公网 HTTPS 健康 200、匿名保证金读取 401；新 API 进程内以 SQL／网络均禁止的替身验证普通／带单读取、绑定变更 409、匿名拒绝、适配器只有 GET 及完整后台权重。没有真实绑定查询或交易所调用，不能把替身验收写成真实账户保证金／手机时效通过。证据在本机忽略目录 `.integration-runtime/PositionMarginTabsNov6/` 的 manifest、`deploy-remote.log`、`deployment-result.json` 与 `verify-release.log`；远端备份保留部署结果。客户端空仓／双卡片及切页改动需要新包，TestFlight 分发和 iPhone 安装仍待验。

## 历史缓存与统计限定发布（2026-11-06）

发布前 SSH 只读核验 **47.80.22.243（首尔服务器）**：`current`／API 为 `integrated-20261103-retire-entry-ema-2d2d93f13dbf`，market 为 `integrated-20261102-git-171be8d74c50`；worker 为 `integrated-20261103-worker-retire-entry-ema-f7a289ab3c7d`，scheduler 为 `integrated-20261103-position-live-activity-3a1a95e914ba`。六个服务健康，API／market 分别核对 304／295 个 Python／requirements 哈希。源码已推送的共享分发及近期周期扩展未在该运行基线生效；不能据 GitHub HEAD 推断实际发布或提速归因。

用户授权完成后推送部署。本次只叠加统计最小上下文、历史 revision 回收／回填保护及关联 maintenance 让位，按 API／market 各自实际基线构建两个独立镜像；各包 92 项隔离回归通过，详见 [开发](development.md#历史缓存生命周期与统计隔离2026-11-06)。不得整包覆盖为 HEAD，或漏带既有 Compose override 而回退其他业务。发布时已重新核对容器／源码基线并备份数据库，保留环境、迁移及原镜像，只替换 API／market；worker、scheduler、MySQL、Redis 容器不变。实际发布结果如下。

### 实际发布与验收

2026-11-06 02:14:01（北京时间）已将源码 `a91850bce48235e313478ebd5f523e2b5b2930aa` 的限定改动部署至 **47.80.22.243（首尔服务器）**：API 为 `integrated-20261106-history-cache-api-a91850b`，market 为 `integrated-20261106-history-cache-market-a91850b`，`current` 指向新 API release。两镜像各保留原有基线，manifest 的 `scope=limited-history-cache-statistics` 明确不是完整 HEAD 发布。原 Compose override 全部保留，再叠加 `compose.history-cache.yaml` 固定两目标镜像及其余服务实际镜像；切换前比较解析后的目标配置，除镜像／构建目录外一致，环境文件未变。

切换前数据库一致性备份与 gzip 校验通过；只执行 `migrate --check`，没有应用迁移、重置队列或交易／资金／保护单操作。切换后六服务健康，新 API／market 全部 Python／requirements 哈希与限定 manifest 一致；worker、scheduler、MySQL、Redis 的容器 ID 与镜像哈希保持原样。备份、前后容器、来源 manifest、部署日志及 `rollback.sh` 均在 `/opt/trade-tools-integrated/backups/integrated-20261106-history-cache-api-a91850b/`；回滚仅恢复 API／market 原镜像及 `current`，不恢复数据库、不反迁移。后续 Compose 操作须使用新 API release 的原三份配置加 `compose.history-cache.yaml`，避免误用旧镜像。

2026-11-06 02:15:17（北京时间）公网验收通过：HTTPS 健康 200、既有 QA 鉴权、BTCUSDT 1h 完整 1500 根／尾部 2 根历史、gzip、六类统计响应、WSS ready／订阅 ack／ping-pong 及 BTCUSDT 实时 K 线／ticker。统计最终 pending=false，响应中有 501 根含统计；这是接口与后台可用性验收，不能视为手机延迟 A/B。只读缓存检查记录 64 个索引窗口、0 个旧 revision 窗口；其范围为该次采样，不作长期命中率承诺。完整证据在本机忽略目录 `.integration-runtime/HistoryCacheNov6/`。本轮无需新客户端，未上传 TestFlight；共享分发／编码复用仍未纳入这两个线上镜像，真实手机收益与此前提速归因仍待测。

## 周期切换只读测量（2026-11-05）

22:03:39（北京时间）最后通过已有 SSH 认证，在 **47.80.22.243（首尔服务器）** 的 API 容器只读取得最近 50 份公共图表诊断。报告均为 Build 44，接收区间 20:00:06–22:02:03；此时 release 仍为 `integrated-20261103-retire-entry-ema-2d2d93f13dbf`，限定来源 `limited-entry-ema-retirement`／`15b4784c70433233c34cb5c6c738cb1a9b92848b`，基线为 `integrated-20261103-position-live-activity-3a1a95e914ba`。没有据 GitHub 最新源码推定线上版本。

数据库会话显式 `SET SESSION TRANSACTION READ ONLY`，除诊断外只查询四组公共历史各 1500 根并在同一会话紧接复读，测量 Python 转换与压缩；Redis 只用 GET／ZSET 查询缓存容量、窗口键和 revision。没有调用会排补线任务／写缓存的 `load_history` 或历史 HTTP 接口，没有清缓存、注入生产计时日志、修改服务／数据库／网络配置、重启或部署，也没有交易所请求、交易／资金／保护单操作。

受限原始诊断、脱敏汇总、SQL／Redis 测量与复现脚本保存在本机忽略目录 `.integration-runtime/ChartIntervalLatencyNov5/`，目录 0700、文件 0600。`reports-50.ndjson`／`reports-summary.json` 为报告证据，`history-cost-summary.json` 为已得成本样本；只读脚本为 `read_production_reports.py`／`read_production_history_cost.py`。查询仍可能占用数据库资源，未使用压力测试，也未反复清缓存制造冷启动。业务结论、缓存优先级的本地修复与待验证范围统一见 [行情](market-data.md#周期切换耗时与十字线百分比2026-11-05)，测试见 [开发](development.md#周期切换排查与百分比回归2026-11-05本地)。源码及文档保留本地，未提交／推送或上传新包；本次查询不构成修复后线上验收。

## 公网访问边界与安全核验（2026-11-05）

2026-11-05 13:54～14:00（北京时间）从本机对 **47.80.22.243（首尔服务器）** 做低频 TCP 探测、匿名 HTTP GET／一次 WSS 握手，并审阅本地部署、认证和资源使用代码。用户明确说明已在云后台关闭 22，目的为测试 Codex 是否仍可接入；22 的连接超时符合该设置，不能当作 SSH 服务故障。没有取得 SSH 会话，也没有核验宿主实时配置、线上镜像源码或全部云防火墙规则。

| 检查 | 本次实际结果 |
| --- | --- |
| 公网端口抽查 | 80／443 可连接；22、3306、33060、6379、8787、2375、2376、8443、3000、8000、9000 超时，8080 拒绝连接。仅代表本机到该 IPv4、该时点和所列端口的观测，不是全端口、IPv6 或其他来源的验证 |
| HTTPS 深度健康 | `/integrated/v1/health` 连续三次 200，约 403／430／456 ms，证书校验通过；14:00 复查仍 200，database／migrations／scheduler 全部 true。不能据此声称本轮查过六个容器或数据库内容 |
| 业务认证 | 匿名访问 `/integrated/api/auth/me`、`/integrated/api/commands`、账户 info、持仓 list、API 绑定 info、策略 list 均 401；`/integrated/ws/v1` 匿名握手 403。未携带用户会话或查询他人对象 |
| 消息与配置文件 | TradingView pending 在未配置消息凭证时返回 503，不开放读取；根路径和 `/integrated/` 下的 `.env`、`.git/HEAD` 抽查均 404 |
| 管理与注册入口 | `/integrated/admin/login/` 匿名 200，为 Django 登录页；`/integrated/v1/auth/admin-settings` 返回 `open_registration=true`、匿名 `is_admin=false`。看到登录页或注册开放不等于绕过权限 |

本轮未发现已证实的匿名任意数据库读写或远程命令执行入口；代码审阅确认以下待加固项，影响条件与线上验证必须分开：

| 优先级 | 代码与公网证据 | 风险和建议（均未实施） |
| --- | --- | --- |
| 优先 | `riskon/urls.py` 挂载标准 Django admin，公网登录页可达；`users/views.py` 的登录失败锁定只包围应用 LoginView，未包围 admin | 后台增加了独立的密码攻击面。建议不用时在入口封闭，用时限制 VPN／允许来源并配置独立登录防护；应用 `is_admin` 与 Django `is_staff` 是不同权限，不能据应用管理员身份推定可进入后台 |
| 优先 | `common/health.py` 每次匿名 GET 都执行 `SELECT 1`、实例化 `MigrationExecutor` 并查 Redis；本地 Nginx 模板未定义 `limit_req`／`limit_conn` | 请求可反复消耗 API、MySQL 与 Redis 资源，可能影响业务可用性。建议公网仅返回轻量或短时缓存状态，将完整深度检查限制在内部，并在代理层分路径限速／限并发。没有压测复现故障；线上全局 Nginx／WAF 保护尚未核实 |
| 需加固 | 注册已按既有业务要求开放；代码有每 IP 注册限制，默认 10 次／小时，创建账户前未验证邮箱。默认 REST 配置无通用请求限流；策略新增无用户总量上限、列表无分页；WSS 有消息／队列／超时边界但无每账户连接数上限 | 注册开放本身属于当前功能。新账户可使用其获授权的数据库写入和行情订阅；若被滥用，可能累积数据或占用共享资源。建议补邮箱所有权校验、每账户写入及连接配额、列表分页和入口防护；保留既有用户／模式／绑定隔离。不推定新账户能访问他人数据，也未创建测试账户或写入策略／命令 |

依据：[Django 官方安全说明](https://docs.djangoproject.com/en/5.2/topics/security/#additional-security-topics)明确标准认证不自带登录请求节流；[Nginx 请求限速模块](https://nginx.org/en/docs/http/ngx_http_limit_req_module.html)用于入口速率限制；[DRF 节流说明](https://www.django-rest-framework.org/api-guide/throttling/)指出应用节流不能单独承担暴力破解／DoS 防护。关闭 SSH 只缩小主机管理入口，正常开放的 HTTPS 仍能触发应用及其数据库访问；不能把端口关闭当作完整安全审计。

本轮没有登录尝试、注册、写入探测、压力测试、生产交易／资金／保护单动作或配置修改。本轮仅更新文档，未提交、推送或部署。依赖／宿主补丁、实际数据库权限、备份隔离及云控制台／CI 等管理入口不在本次在线验证范围；后续应通过受控云控制台或既有授权管理通道核验，无需为本次结论重新开放公网 SSH。

### 连通性复测（14:05～14:07）

2026-11-05 14:05～14:07（北京时间）按用户要求重新测试 **47.80.22.243（首尔服务器）**：22／80／443 均可建立 TCP 连接，22 建连约 135 ms。默认 SSH 身份被拒绝；随后使用本机已有项目专用密钥，在严格主机指纹校验与非交互模式下认证成功，远端只执行 `id -un`，返回 `root`、退出码 0。说明本机在此时可以通过既有授权密钥取得 root SSH 会话，不是匿名访问或认证绕过；未修改密钥、主机信任或服务器配置。

HTTPS `/integrated/v1/health` 连续三次返回 200，总耗时约 461／263／1338 ms，证书校验均通过，database／migrations／scheduler 全部 true。上方 22 阻断、未取得 SSH 的结论仅适用于 13:54～14:00；最新连通性以上述复测为准。本次未重查其他端口、全局防火墙、容器、数据库内容或安全加固状态，没有运行交易／资金／保护单动作、重启或部署；仅补记文档，未提交推送。

## 强平与费用只读对账（2026-11-05）

21:49（北京时间）最后按用户授权，在 **47.80.22.243（首尔服务器）** 现有 API 容器查询指定账户的两笔近期平仓。数据库会话显式设置 `SET SESSION TRANSACTION READ ONLY`；只读匹配订单后，核对现有绑定的 Key 指纹，凭证仅在进程内解密，不使用会迁移旧密文／写绑定健康状态的通用凭证读取器。交易所请求限制为 GET 白名单，使用现有预算机制读取 `account`、`income`、`userTrades`、`forceOrders` 和 `leverageBracket`；没有调用会补写结算的普通仓位历史接口。

订单身份、成交数量、已实现盈亏、独立清算费和当前余额核对通过，确认历史净盈亏漏计清算费；当前档位只用于近似复算维持保证金，不代替历史标记价快照。业务结论及待修复边界统一见 [资金文档](capital-and-transfers.md#强平清算费用与历史净盈亏2026-11-05线上只读核验)。受限产物位于本机忽略目录 `.integration-runtime/LiquidationReviewNov5/`（目录 0700，原始结果及对账 JSON 为 0600）；其中真实账户交易资料不进入项目文档或版本控制。未修改数据库业务数据、交易／资金／保护单状态或服务配置，没有重启、部署、迁移或测试造仓；文档保留本地，未提交推送。

22:06（北京时间）经 **47.80.22.243（首尔服务器）** 现有 API 容器补查一次未签名的公开 GET `exchangeInfo`，仅输出目标合约的公开参数。结合既有私密对账产物，复算清算费的名义价值基数、独立费率和剩余保证金上限，结果相符；未再次读取私有账单、写业务数据或执行交易。计算结果保存在同一受限目录的 `clearance-calculation.json`，查询时费率不能冒充事发时历史快照。

## 重启恢复与开机自启（2026-11-05）

2026-11-05 12:59（北京时间）最后核验 **47.80.22.243（首尔服务器）** 六个整合容器均 `running/healthy`，公网 HTTPS `/integrated/v1/health` 返回 200，数据库、迁移和 scheduler 心跳检查全部通过；Redis 持久化状态为 `loading=0`、AOF enabled、最后写入与 rewrite 状态均为 `ok`。本次恢复现有容器，没有发布新代码；`current` 仍为 `integrated-20261103-retire-entry-ema-2d2d93f13dbf`，API／worker／scheduler／market 的组合继续以下节限定发布为准。

主机于本日 12:40 启动，Docker／containerd／Nginx 和六个容器原本已经自动启动；故障并非缺少自启配置。Redis 读取 `appendonly.aof.2055.incr.aof` 时遇到格式错误并循环退出，另外四个 Python 服务随之不健康，MySQL 始终健康。只读诊断确认 BASE RDB 全部有效，INCR 的 53,309,440 字节中，前 53,307,426 字节为完整记录，剩余 2,014 字节全部为零；没有完整命令或事务需要从该尾部保留。本次可确认磁盘上可校验的完整前缀已保留；故障前尚未落盘的内存写入不在这项校验范围内。

恢复时先停止四个 Python 写入进程和故障 Redis，完整备份 Redis 卷并逐文件核对压缩归档内容哈希；备份位于 `/opt/trade-tools-integrated/backups/reboot-recovery-20261105-124725/`（目录 0700、文件受限）。归档 `redis-volume-before.tar.gz` 为 **30,081,131 bytes**，SHA-256 为 `18b079494c6ec42dd0c965638c767769494baf5894b42aa5f57388dcdbe4159c`，包含原 manifest、BASE、INCR 和 dump。备份内原容器元数据含受限配置，禁止上传仓库或输出其完整内容。

在单独副本中用原 Redis 7.4.12 镜像、以 manifest 为入口修复并复查，再以禁网络、无端口的隔离实例验证加载、PING 和持久化状态；生产卷只原子替换经确认的 INCR 完整前缀，保留原属主／权限，BASE、manifest、dump 保持原样，未对 MySQL 执行恢复或人工数据改写。修复后的原 manifest 再次检查通过，之后依次恢复 Redis、等待 MySQL／Redis 健康，再启动四个原 Python 容器。六个容器的 ID、镜像、环境和挂载与备份逐项一致，MySQL 仍为 1 GiB 内存限额；没有迁移、数据库恢复、命令／幂等状态重置、手动交易、划转、撤保护或通知测试。

已重新确认并持久化以下开机配置：

```bash
systemctl enable docker.service containerd.service nginx.service tradetools-integrated-cert-renew.timer
systemctl start docker.service nginx.service
docker update --restart unless-stopped \
  tradetools-integrated-api-1 tradetools-integrated-market-1 \
  tradetools-integrated-worker-1 tradetools-integrated-scheduler-1 \
  tradetools-integrated-mysql-1 tradetools-integrated-redis-1
```

四个宿主 units 均为 `enabled/active`，六个容器均为 `unless-stopped`，Nginx 配置检查通过。该策略会在 Docker／宿主恢复时启动未被人工停止的容器，并在进程异常退出时重启；人工 `docker stop` 的容器需要明确 `docker start` 才恢复。自启不能修复损坏的持久化文件，不设置无条件 AOF 截断脚本；本次未再次重启宿主作验证。

以后单纯重启业务应优先恢复现有容器，不运行会构建、迁移和切换 `current` 的 `release.sh`。必须使用 Compose 时仍保留现行三份配置及独立 worker／scheduler 镜像，不能用单个基础文件重新 `up`。AOF 排障遵循 [Redis 官方持久化说明](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/)：先完整备份，在副本检查损坏位置及预计损失，再决定是否修复；工具即使不带 `--fix` 也可能以 `r+` 打开文件，因此使用可写诊断副本，检查原卷时使用文件属主。容器中确认修复需转发标准输入（`docker run --interactive`），不能把没有执行修复的退出当成成功。此次应用与验证证据保存在上述备份的 `applied-recovery.json`、`isolated-validation.json`、`restoration-verification.json` 及 AOF 检查日志。

## 开仓周期初筛退役限定发布（2026-11-03）

2026-11-03 23:31（北京时间）核验 **47.80.22.243（首尔服务器）** 的 `current` 为 `integrated-20261103-retire-entry-ema-2d2d93f13dbf`（API）；worker 独立为 `integrated-20261103-worker-retire-entry-ema-f7a289ab3c7d`。本次按用户要求移除 EMA 方向／周期初筛接口及新单门控，未替换完整 Git HEAD。下方发布记录均保留各次操作时点，当前组合以本节为准。

- API 从紧接下方的 LivePositions 实际运行版叠加 5 条允许路径，317 个源文件中 312 个原样；worker 从自身 `integrated-20261102-git-171be8d74c50` 叠加同一范围，307 个文件中 302 个原样。只改 3 个运行及 2 个测试文件，72 个非目标 views 声明逐字节不变；发布前只读核对 worker 镜像 295 个源码哈希。API 归档 SHA-256 为 `8570b8ae4ce991286546570cfeec4bff72ecaf122e698e8534e381cc44668202`，worker 为 `8d028ce19df756435bd7256daf40c4fea387f58bc47d90f661cd06cd2e0456c7`，两端一致。两个独立限定包各 264 项隔离回归通过，重叠不相加，见 [开发](development.md#开仓初筛退役止盈选择与策略确认2026-11-03)。
- 备份与结果在 `/opt/trade-tools-integrated/backups/integrated-20261103-retire-entry-ema-2d2d93f13dbf/`（0700），保存前版、两个来源清单、原容器、回退命令和结果。无 schema／数据迁移，仅执行 `migrate --check`，沿用上次 LivePositions 的 **334441616-byte** 数据库 gzip 并再次完整解压核验；保存引用，不恢复数据库或重放队列。环境文件的 inode、大小、mtime 与权限未变。
- build 和切换前两次只读核对 RUNNING 命令均为 0；只重建并替换 API／worker，scheduler／market／MySQL／Redis 的 ID 与镜像均未变。六服务 healthy，公网 HTTPS 深度健康 200。API 与 scheduler 的 live／APNs 继续 true，仓位事件／合作方外发／外部入站三个暂停开关继续 false。
- 新 API 与 worker 各自运行禁用 SQL／网络的实际视图替身检查：EMA 路由 404，原开仓别名保留，9 种旧字段形态都直接到原资金／Decimal 计算边界。没有读取初筛缓存或 K 线，没有执行真实交易、划转、撤保护或测试通知；旧已持久化请求的字符串归一化和指纹恢复保留。旧客户端仍主动请求初筛时会 404，新开仓需配套更新本轮 iOS；客户端 push 不代表 TestFlight 分发完成。

当前 Compose 使用本版 `compose.integrated.yaml`＋`compose.signal-leverage.yaml`＋`compose.entry-ema.yaml`，第三份 override 将 worker 固定为独立新镜像、scheduler 固定为前版 LivePositions、其他服务固定为实际原镜像，不能漏带而将 worker 改回旧初筛。`INTEGRATED_RELEASE` 使用 API release。回滚执行本次备份中 `rollback.sh`，它只恢复 API／worker 的原镜像与 `current`，保留环境、数据库和其他容器；不执行反迁移、订单重试或数据库恢复。回退后旧初筛会恢复，需同步评估客户端版本。源码交付和手机待验范围见 [本轮记录](changes.md#2026-11-03开仓初筛退役止盈显示与策略二次确认)。

## live 后台持仓卡片限定发布（2026-11-03）

2026-11-03 22:49（北京时间）核验 **47.80.22.243（首尔服务器）** 当前为 `integrated-20261103-position-live-activity-3a1a95e914ba`。仅增加 ActivityKit 注册／注销、登出结束标记、独立注册表及只读持仓后台推送任务。`LIVE_ACTIVITIES_ENABLED=true`、APNs 保持 true；`TRADE_NOTIFICATION_ENABLED`、`EXTERNAL_TRADE_SIGNAL_ENABLED`、`EXTERNAL_SIGNAL_INGEST_ENABLED` 三项继续 false。下方旧发布段落保留各次操作时点，当前版本以本节为准。

- 以 `app-notification-routing-5f05a076af1a` 的实际存档为基线，317 个源文件逐项核对，仅 9 个允许路径变化，其余 308 个保持原样。scheduler 只叠加 settings 引入、独立 live job 和开关注册分支，原有任务编排不变；没有带入完整 Git HEAD 中尚未部署的浮盈任务或交易修改。清单在 release 的 `source-release.json`，归档 SHA-256 为 `10a54e16af1a4238906b276a13e5b42318ec7840d26e4ec8e1e3d469c892225a`，两端一致。限定包 108 项隔离回归通过，详见 [开发](development.md#macd-操作色十字线缩放与-live-持仓卡片2026-11-03)。
- 迁移前新建 `/opt/trade-tools-integrated/backups/integrated-20261103-position-live-activity-3a1a95e914ba/`（0700），保存原环境（0600）、前版路径、来源、容器记录和 **334441616 bytes** 的数据库 gzip；进程返回、完整解压 CRC 和体积校验通过。迁移计划严格只有 `mobile.0003_liveactivityregistration`，只创建独立 live 注册表，执行后 `migrate --check` 通过；不初始化、反迁移或改写既有订单。
- 仅替换 API／scheduler，六服务 healthy，market／worker／MySQL／Redis 的容器 ID 和镜像均未变化。公网 HTTPS 深度健康 200；API 与 scheduler 分别确认新开关 true、三个暂停开关 false、APNs true、新表及迁移存在。匿名新路由 401，内存鉴权替身的无效请求 400；当前注册数为 0，投递／交易所读取替身下 dispatcher 返回 0，零发送、零交易所调用。未创建假 token、发送真实通知或执行交易／资金／保护单操作。

Compose 继续使用本版 `compose.integrated.yaml`＋`compose.signal-leverage.yaml` 和对应 `INTEGRATED_RELEASE`。兼容代码回退读取备份中的 `previous-release`，只切回 API／scheduler 及 `current`；新增表保留，不能以数据库恢复或反迁移回退代码。部署脚本的启动失败回退仅恢复旧镜像，保留新增表及 live 环境开关（旧代码忽略该项），不覆盖原三个暂停设置；计划回退前应评估并结束已展示的活动、停用 live 调度。回滚不会撤回已送达的系统卡片。

此前 `15b4784` 已推送，本轮新源码保留本地，尚未提交／推送或手动上传 TestFlight。新签名包的活动 token、`liveactivity` topic 苹果接受、锁屏／灵动岛及长时间后台更新仍待 iPhone 验收；服务器健康不代表手机已收到。客户端生命周期及系统预算边界见 [持仓浮窗](ios-floating-positions.md#activitykit-live-持仓卡片2026-11-03源码实现)与[通知](signals-and-notifications.md#activitykit-live-持仓卡片2026-11-03源码实现)。

## 外部接收暂停与 App 通知分流（2026-11-03）

2026-11-03 21:57（北京时间）核验 **47.80.22.243（首尔服务器）** 当前为 `integrated-20261103-app-notification-routing-5f05a076af1a`。`EXTERNAL_SIGNAL_INGEST_ENABLED=false` 已应用到 API／scheduler；开平仓总开关与合作方发送开关继续 false，APNs 保持 true。普通内部信号走 App；旧外部／Echo 普通信号队列领取时取消，仓位通知以后只移交所属用户 App 队列，暂停期间也不领取已移交记录。浮盈配置和任务编排未变，浮盈自动任务仍未上线。

- 基于上一版 `trade-notifications-off-b14c8dea2898`，限定 314 个源码文件，只有 6 个运行／模板路径与 3 个测试路径变化；scheduler、trend、Compose、全部 migration、交易与保护逻辑逐项哈希保持基线。归档 SHA-256 `66359127ec4d1d366e040a8051adb1fd52617659a29f57bde1140a4201f935c7` 两端一致；完整来源在 release 的 `source-release.json`，不是完整 Git HEAD。限定包 70 项隔离回归通过。
- 备份目录 `/opt/trade-tools-integrated/backups/integrated-20261103-app-notification-routing-5f05a076af1a/` 为 0700，保存原环境（0600）、前版路径、清单和容器记录。无 schema／数据迁移，仅 `migrate --check`；数据库沿用已核验的 `app-push-d277ad4ed87a` 321659196-byte 备份并保存引用。
- 仅 API／scheduler 替换，六服务 healthy，其他四个容器 ID／镜像不变，公网 HTTPS 深度健康 200。两个容器分别核对三个 false 开关与 APNs true；内存鉴权替身下，external 及自报 internal 入站均为 503；数据库领取对象替身确认四类旧外部记录取消且尝试为 0、暂停 App 交易投递不改状态。两个仓位 dispatcher 不读队列，直接 sender 拒绝发送。未发送真实通知、创建信号或执行交易／资金动作。

回滚仍使用前版两个 Compose 文件及前版 `INTEGRATED_RELEASE`，仅切回 API／scheduler 和 `current`。保留三个暂停开关，不整份覆盖环境、不反迁移或重放队列；旧代码不认识新入站开关，代码回退会失去本轮接收暂停保护，需同步评估。客户端源码交付、编译与实机边界见 [开发](development.md#信号红点与通知分流回归2026-11-03)；本次不手动上传 TestFlight，iOS 红点／配色待新包验收。

## 仓位事件通知关闭（2026-11-03）

2026-11-03 16:14（北京时间）核验 **47.80.22.243（首尔服务器）** 当前为 `integrated-20261103-trade-notifications-off-b14c8dea2898`。按用户要求，持久化设置 `TRADE_NOTIFICATION_ENABLED=false`、`EXTERNAL_TRADE_SIGNAL_ENABLED=false` 并应用到 API／scheduler，关闭开仓、平仓、止盈、止损、减仓的内部及合作方通知。原版内部通道无 token、合作方开关为 false，但内部队列仍尝试至 exhausted；新增总开关使暂停期间不领取、不发送、不重试，事件保存保留。普通信号 APNs 仍为 true；浮盈配置未动、自动任务仍未上线。

- 基于紧接下方的 `app-push-privacy-2c242c254dcb`，逐项核对 313 个文件，只改变 `riskon/settings.py`、两个通知适配器、通知回归和环境模板；没有改变交易、持仓保护、结算或任务编排。归档 SHA-256 `98e50d37a29c8d216adb52d77be12070ceb45a86d4774c5af031ff4939be3bad` 两端一致，完整清单在 release 的 `source-release.json`，不是完整 Git HEAD。
- 备份 `/opt/trade-tools-integrated/backups/integrated-20261103-trade-notifications-off-b14c8dea2898/` 为 0700，保存修改前 0600 环境文件、来源和容器记录；数据库沿用已验证的 `app-push-d277ad4ed87a` 备份并保存引用。本轮无 schema／数据迁移，只执行 `migrate --check`，不恢复数据库或重放事件。
- 仅重建 API／scheduler，六服务 healthy，其余四个容器 ID／镜像不变；HTTPS 健康 200。两个实际进程的开关均为 false；使用网络替身核对两个 dispatcher 及两个直接 sender 均不访问 HTTP，队列状态前后相同（4 条 exhausted、外部 0 条）。没有真实开平仓、划转、撤保护单或测试通知发送。本地 39 项隔离回归见 [开发](development.md#仓位通知暂停回归2026-11-03)。

沿用 `compose.integrated.yaml`＋`compose.signal-leverage.yaml` 及本版 `INTEGRATED_RELEASE`。旧版代码不认识总开关，回退代码会失去本次暂停保护，必须同步评估用户的暂停要求；不得直接恢复整份旧环境覆盖后续配置。恢复通知须明确修改对应开关并重新加载 API／scheduler，先核对积压队列及历史 exhausted 记录，不自动重置尝试。源码和记录保留本地，未追加提交／推送或上传 TestFlight。

## APNs 拒绝定位与请求日志修正（2026-11-03）

**47.80.22.243（首尔服务器）** 当前已更新为 `integrated-20261103-app-push-privacy-2c242c254dcb`。相对下方 App 通知限定版，仅修改 `riskon/settings.py` 的 HTTPX／HTTPCore 传输日志配置，防止 APNs 路径中的设备标识进入应用日志；既有交易源码与任务编排未改变。归档 SHA-256 为 `bf0d084fd568b8b9000aa0a78465aa8a079fa90eaa39ff7aa695faaca918365e`，两端校验一致，来源 313 个文件逐项核对。安全回归先复现路径泄露，修正后的限定包 **17 项通过（0.063 秒）**，线上验证两个 transport logger 均为 NullHandler 且不传播。

仅重建 API／scheduler，六服务 healthy、另外四个容器 ID／镜像不变，没有 migration 或交易／资金操作；本轮日志修正复用前一限定版已经验证的数据库备份，不以代码回滚还原数据库。备份目录 `/opt/trade-tools-integrated/backups/integrated-20261103-app-push-privacy-2c242c254dcb/` 保存前版路径、来源、容器记录及备份引用；Compose 文件及仅恢复 API／scheduler 的回滚方式与下方相同。完整源码未提交／推送，未上传 TestFlight。

手机已在 15:26 注册 production 设备，三条测试通知均被苹果拒绝；安全诊断为 HTTP 400／TopicDisallowed。后台确认现有 APNs key 只允许旧 App。用户明确允许后，15:42 在 Apple 后台保留旧 topic 并新增整合 topic，页面确认 key updated、2 Topics / Production，没有更换密钥或撤销旧权限。恢复原三条测试后苹果均返回 200／sent，15:44 用户确认手机 **3 条全部收到**；本次 App 通知实测通过。浮盈任务仍未启用，自然信号触发与长稳不据此验收，详见 [通知](signals-and-notifications.md#普通通知真机测试2026-11-03)。

## App 普通信号通知限定发布（2026-11-03）

2026-11-03 15:21～15:22（北京时间），**47.80.22.243（首尔服务器）** 已更新为 `integrated-20261103-app-push-d277ad4ed87a`。用户要求发送三条普通信号测试通知；实查旧运行版本没有设备注册路由、没有 HTTP/2 依赖且设备表为空，因此先补齐 App 通知链路。

- 以紧接下方的信号／杠杆运行包为基线，逐一核对 313 个来源文件；仅叠加已有提交 `9151efa` 的 `mobile/urls.py`、`auth.py`、`push.py` 和 `requirements.txt`，以及仅含 App 派发任务的 scheduler 局部变更、scheduler 私钥只读挂载 override。既有 scheduler 的所有函数和任务编排在移除新增 App 任务后 AST 完全一致；未带入浮盈任务、交易执行或新 migration。完整清单在 release 的 `source-release.json`，此包不是完整 Git HEAD。
- 归档 SHA-256 为 `4c60ca9424e14c4c5fd74afca3b177269432731350728cce5af08e958abdc970`，两端一致。备份目录 `/opt/trade-tools-integrated/backups/integrated-20261103-app-push-d277ad4ed87a/` 保存前版路径、来源、容器记录及 321659196 bytes 的数据库 gzip，完整性通过；目录 0700、文件 0600。仅执行 `migrate --check`，没有迁移或初始化。
- 仅替换 API／scheduler，六服务 healthy，其余四个容器 ID／镜像不变；HTTPS 健康 200，匿名设备注册 POST 401（路由存在且要求鉴权），scheduler 可读受限 p8。普通 App 信号每 10 秒派发，旧队列两条 Echo 信号记录已取消，尝试次数均为 0；浮盈外发仍未启用。发布前后本地库活动仓位、待成交限价、待提交开仓请求和未决命令计数均为 0。
- 限定包在本机通过 16 项隔离回归，见 [开发](development.md#app-通知限定包验证2026-11-03)。15:22 核对仍无设备，三条测试通知尚未发送；需要手机重新打开 App 完成鉴权注册，再通过独立测试通知事件投递。苹果接受和手机收到分别记录在 [通知](signals-and-notifications.md#普通通知真机测试2026-11-03)，不能互相替代。

本版沿用 `-f compose.integrated.yaml -f compose.signal-leverage.yaml` 和对应 `INTEGRATED_RELEASE`。回滚读取本版备份的 `previous-release`，在前版使用相同两个 Compose 文件及前版版本值，仅恢复 API／scheduler、恢复 `current` 并验证健康；不反迁移、不恢复数据库、不重放已尝试通知。此次发布不上传 TestFlight、不执行交易或资金操作。

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

- `/opt/trade-tools-integrated/releases/<内容版本>`：发布源码；`current` 指向当前 API／主要 Compose 版本。各服务可以使用不同限定基线镜像，须同时核对实际容器及当次 override，不能据此推定四个 Python 进程均为同一源码版本。
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

注册状态存于 `users.SystemSetting` 的 `open_registration` 数据库项，`1` 为开启，默认关闭；不属于 `server.env` 配置。匿名 `GET /v1/auth/admin-settings` 可读取当前状态。2026-11-06 已随[完整同源发布](#完整同源发布2026-11-06)将写权限收紧为有效登录邮箱 `qqqqqq@qq.com`，不继承其他管理员标志；本轮没有改变持久化的开关值。新版本可在 App 设置或通过同路径的鉴权 `POST` 提交 `{"open_registration": true}` / `false` 修改，重启和代码发布不重置已有设置。

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

更新使用新 release、受限配置和同一个 Compose 项目，完整交付范围遵守[协作规则](../AGENTS.md#发布与验证)。从确定 Git 提交生成全部后端／部署源码存档，核对四个 Python 服务的完整来源和配套迁移后统一发布；当前配置链见[完整同源发布](#完整同源发布2026-11-06)。用户明确要求限定发布时，才保留完整 override 并固定非目标镜像。不要向来源 USDT Gitee 仓库的 main 推送整合版改动，避免触发来源系统自动部署。

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

2026-11-10 用户授权提交推送当前全部未提交改动；提交 `d34be47` 已推送至 GitHub `qoqkeep-create/binance` 的 `codex/integrated-ios`。本批仅包含 iOS 图表恢复、测试和主题文档，没有 `server/` 或 `deploy/integrated/` 文件，因此不触发 47.80.22.243（首尔服务器）部署；本地 81 项 host 回归和主 App Debug 模拟器构建已通过。

2026-11-05 用户授权先提交推送当前全部未提交改动，以 `2c491c2` 为基线沿用独立 Git 元数据交付 `codex/integrated-ios`。范围及已有验证见 [本批记录](changes.md#2026-11-05当前全部改动源码交付)；原 USDT／USDC 来源目录、父 Gitee、凭证、运行证据和 `.build/` 不参与。本次不追加 47.80.22.243（首尔服务器）部署或手动 TestFlight 上传，GitHub 源码与实际运行版本分开验收。

2026-11-03 本次用户明确授权提交推送整合工作区全部未提交内容，以 `df77ba2` 为基线交付周期／auto、六种周期后端及 Super 双主题、MACD 边框、账户与策略界面等源码到 `codex/integrated-ios`；范围和已有验证见 [整批交付记录](changes.md#2026-11-03周期主题与账户策略整批源码交付)。沿用独立 Git 元数据，父 Gitee 及忽略的凭证／构建不参与。本次不追加部署、迁移或手动 TestFlight 上传；47.80.22.243（首尔服务器）的实际版本仍以上方运行记录为准，新增周期后端和手机新包待配套交付。

2026-11-03 后续用户明确要求本轮完成后直接提交推送，以 `dd4f048` 为基线交付策略编辑、指标卡片及透明度、连续 Super 填充、同触点十字线、默认杠杆、账户／持仓界面及普通信号 APNs／浮盈 Echo 分流源码。全部本地验证与范围见 [本批记录](changes.md#2026-11-03策略指标交互与通知分流源码交付)。沿用独立 Git 元数据推送 `codex/integrated-ios`；本次不追加部署、迁移或手动 TestFlight 上传，**47.80.22.243（首尔服务器）** 的运行范围继续以本页实际发布记录为准，完整通知及手机新包待配套验收。

2026-11-03 用户明确授权提交推送当前整合工作区全部未提交内容，本批以 `df1e032` 为基线，将 31 个客户端、测试及文档文件交付 `codex/integrated-ios`，包括其他会话留存的顶部控件、浮窗入口和周期／日期选项。范围与验证边界见 [本批交付记录](changes.md#2026-11-03图表账户反馈与顶部控件整批源码交付)。沿用既有独立 Git 元数据，父 Gitee 仓库及忽略的凭证、备份、构建不参与；本次不追加部署或手动上传 TestFlight。**47.80.22.243（首尔服务器）** 的实际运行代码继续以上方信号／杠杆限定发布为准。

2026-11-02 用户后续明确要求直接提交并推送全部改动，本批以 `d533b19` 为基线交付工作区 21 个文件到 `codex/integrated-ios`，包含此前开仓／持仓切页优化与十字光标／杠杆界面及配套测试、文档。验证证据及未验范围见 [整批交付记录](changes.md#2026-11-02开仓面板持仓缓存与十字光标整批源码交付)。本次不重新部署或手动上传 TestFlight；**47.80.22.243（首尔服务器）** 的运行状态继续以上方 API 限定发布为准，GitHub 全部源码交付不等于所有后端改动已上线。

2026-11-02 用户明确授权提交并推送当前整合工作区全部改动，包含其他会话内容；本批以 `f155c95` 为基线，通过既有独立 Git 元数据交付 `codex/integrated-ios`。范围和各任务已有验证见 [跨会话源码交付](changes.md#2026-11-02跨会话全部改动源码交付)。本次不执行新部署或手动 TestFlight 上传；源码交付不能替代 **47.80.22.243（首尔服务器）** 的运行版本核验，上方最后实际发布记录继续作为部署依据。

2026-11-01 本次用户授权整批提交并推送，收录工作区的界面／延迟、连续纵轴和行情协调／出口保护等全部安全改动，基线为 `fab71ee`；范围与既有验证见 [本次交付记录](changes.md#2026-11-01整批源码提交与-github-交付)。本次不执行服务器部署或手动 TestFlight 上传，源码交付与运行版本分别记录；上方 47.80.22.243（首尔服务器）的最后发布记录继续有效。

2026-11-04 用户授权“完成后全部提交推送”，以 `194d1e7` 为基线交付当前全部安全源码和文档，包含待提交的 iOS 调整与鸿蒙前三批复刻。沿用下方独立 Git 元数据及 `codex/integrated-ios`，父 Gitee、凭证／签名和构建产物不参与。本次只做源码推送，不追加 **47.80.22.243（首尔服务器）** 部署或手动 TestFlight 上传；范围及验证见 [交付记录](changes.md#2026-11-04图表顶部归集筛选与全部待提交源码交付)。

2026-11-04 后续用户授权将自适应高度浮窗与上轮未提交的图表标签／费用／持仓细调一起提交推送；本批基线为 `9a8e545`，继续沿用同一独立 Git 元数据与 `codex/integrated-ios`。只交付 iOS 源码、回归及主题文档，原有 `.build/` 产物不纳入；不追加 47.80.22.243（首尔服务器）部署或手动 TestFlight 上传。范围与验证见 [本批记录](changes.md#2026-11-04浮窗自适应高度与图表细调源码交付)。

整合版仓库为 `https://github.com/qoqkeep-create/binance.git`，分支 `codex/integrated-ios`。自 2026-11-10 起，本机根目录为 `/Users/apple/work/TradeTools-Binance-iOS`，与原 USDT／USDC 来源项目并列，根目录 `.git` 为本项目的独立元数据。迁移沿用原有历史、分支和索引，未重新初始化或复制来源仓库历史。

```bash
cd /Users/apple/work/TradeTools-Binance-iOS
git rev-parse --show-toplevel
git remote -v
git status
git diff --check
```

2026-11-10 搬迁后只读核对：GitHub `refs/heads/codex/integrated-ios` 仍为 `268a529fc16154bd5af27b25b5484927a48a9ea1`，与本地及原跟踪引用一致。最早导入提交 `1118eaa`（2026-10-31）已经直接以 `server/`、`frontend/`、`deploy/`、`docs/` 等为仓库根内容；最早与当前的 iOS 工程路径都是 `frontend/ios-app/TradeTool.xcodeproj`，没有来源父目录或本机项目目录名前缀。首次交付范围即整合工程，Mac 本地搬迁不改变仓库内路径；本轮未推送或修改 Apple 工作流，因此无需仅因本地搬迁调整 Cloud 工程路径。当前云端运行／分发结果不属于这次核对范围。

操作前确认根目录和 origin 属于整合版。普通 clone 同样使用根目录 `.git` 与上述命令。此前嵌套工作副本使用的 `.integration-runtime/github-publish.git` 已移至 `.git`，现行命令不再带 `--git-dir` / `--work-tree`；旧交付记录中的这些参数仅代表当时状态，路径映射见 [迁移索引](sources.md#本地目录独立2026-11-10)。

迁移前的 Git 元数据和工作区差异备份位于本机 `/Users/apple/work/.repo-backups/ios-standalone-20261110-193230/`，权限受限，不纳入交付。原 USDT 仓库会显示旧嵌套路径删除；来源索引、远程和历史保持原样，删除不混入来源发布。本轮仅本地迁移，不提交、推送、部署或触发客户端分发。

Xcode Cloud 必须单独获得指定 GitHub 仓库的访问授权；本机 Deploy key 可推送不代表 Cloud 已获授权。

整合工作区的交付范围以[协作规则](../AGENTS.md#发布与验证)为准；来源目录、父仓库改动与历史不混入。环境文件、私钥、备份、日志、构建和 IDE 用户状态保持忽略。GitHub Deploy key 与目标机 SSH 密钥是不同认证，均不随代码交付。本机 SSH 443 / 代理设置只存于根目录 `.git/config`，凭证路径已随本地搬迁更新；其他机器正常 clone 即可。

推送授权以 [项目协作规则](../AGENTS.md#发布与验证) 为准。2026-11-01 用户明确授权本次 K 线诊断在需要发布客户端时完成后直接推送，并说明由其既有 Jenkins 调用 Apple 打包服务；这是本次任务授权，后续任务仍默认经用户批准再推送。本轮不修改 Jenkins 或 Apple 工作流；推送成功不代表打包、分发或手机安装成功。2026-11-01 的名称 / 图标 / 认证 / 白底启动页及开启注册整批获单次推送授权；验收见 [变更记录](changes.md)。推送可能触发 Xcode Cloud，源码推送与开启注册的授权范围不包含真实交易。

源码推送、47.80.22.243（首尔服务器）的部署和 TestFlight 上传分别记录，不能互相替代。手机签名 / 上传见 [TestFlight](testflight.md)，当前待验收项见 [已知事项](known-issues.md)。

2026-11-02 用户在本地图表／持仓／通知验收完成后授权“提交推送”，本批以 `17a3eda` 为基线交付 51 个文件到 `codex/integrated-ios`，范围与既有验证见 [变更记录](changes.md#2026-11-02图表持仓杠杆选择与通知源码交付)。生产 Echo／APNs 配置和密钥不随源码上传；本次不部署后端、重启服务或手动上传 TestFlight，47.80.22.243（首尔服务器）仍以上方通知配置准备及杠杆限定发布记录为准。

## 图表加载诊断

2026-11-07 **21:50～21:58（北京时间）**，针对用户“放后台后返回 K 线等待 5～8 秒”，只读核对 **47.80.22.243（首尔服务器）**。API 容器通过只读数据库会话查询最近 50 份报告，再用只读 ORM 汇总当日及三天内慢记录；另提取 API 24 小时日志中固定 chart timing 字段、Nginx 当日 K 线状态／字节数、即时容器资源和默认拥塞算法。运行版本仍为 `integrated-20261106-full-7e29236`，宿主默认 `bbr`；没有部署、重启、缓存变更、真实交易／资金／保护单操作。不保存完整访问日志、客户地址或鉴权内容。

本机证据为忽略且受限的 `.integration-runtime/ChartLatencyNov7/`：`reports-50.ndjson`／`reports-summary.json`、`extended.ndjson`、`runtime.json`、`access.json`；访问记录时间已归一 UTC。现有 access log 无 request／upstream duration，也无 trace，200 与发送字节数不证明手机已收到。`TraceHost` 单条回放确认“初次＋后台恢复读取两次、诊断仅一份”，为预期失败的缺口复现，不是整套回归通过；模型、管线与诊断源码已核对。带 trace 的 122 条 history 不能代表所有恢复请求。样本与限制统一见 [行情排查](market-data.md#background-chart-latency-20261107)，该只读阶段未实施建议埋点，也未重启旧 USDC 服务。

用户随后确认补齐恢复计时；本地实现通过现有 `load_started.value` 区分五种来源，继续使用同一追踪头、字段、事件和结果枚举，原严格 serializer 兼容，无需更新 **47.80.22.243（首尔服务器）**、迁移或改变限流。独立恢复、截止与旧回调隔离见 [行情](market-data.md#chart-recovery-diagnostics-20261107)，81 项 host／9 项契约／Release 的本地范围见 [开发](development.md#chart-recovery-diagnostics-20261107)。手机安装新包后应优先筛 `load_started.value=2` 的后台返回记录，并分开看 `3` 重连、`4` 手动重试；无来源值的旧记录不能冒充新恢复样本。源码交付不等于新包已上报，本次没有新生产部署。

2026-11-05 本次通过既有 SSH 认证在 **47.80.22.243（首尔服务器）** 的 API 容器只读执行 `python manage.py chart_load_reports --limit 12`。返回既有 iPhone Build 44 记录（北京时间 19:55:14–20:01:42），本机受限原始输出位于忽略目录 `.integration-runtime/ChartResumeNov5/recent-reports.ndjson`。仅汇总公共计时字段；没有修改应用／系统／网络配置、数据库、缓存或凭证，没有部署与重启。样本、已修复的本地竞态和剩余线上波动统一见 [行情](market-data.md#首次握手与后台恢复2026-11-05本地)，本次没有复查宿主 BBR 或进行新的 TCP 采样。

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
