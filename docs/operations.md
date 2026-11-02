# 整合环境部署与运维

唯一目标为 **47.80.22.243（首尔服务器）**。原 USDT 生产环境及本地来源目录不属于本轮操作范围。用户已授权整合版部署与旧 USDC Java 环境退役；普通验收禁止真实开平仓、划转或撤保护单。

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

## 图表加载诊断

2026-11-01 按用户实际点击，47.80.22.243（首尔服务器）临时启用仅针对 K 线的 Nginx 阶段日志，采到 build 14 响应头约 72 ms、完整传送 4.62 秒。临时配置已撤销，站点文件与原备份 SHA-256 相同，`nginx -t`／reload 通过。配置备份和脱敏计时位于 `/opt/trade-tools-integrated/backups/kline-diagnostic-20261101/`，目录／日志保持受限；没有清空缓存、修改交易或发布新应用。结论和 upstream 背压解释见 [行情](market-data.md#手机实际请求与响应体传送)。

客户端新诊断已按本次授权提交交付，新增表 migration `market_stream.0003_chartloadreport` 已在 47.80.22.243（首尔服务器）完成，发布与验收见本页顶部。后续发布继续按既有 release／数据库备份流程迁移，再启新 API／market 镜像；API 与 market 配套，行情维护负责有界清理。该迁移只新增表，与旧版回滚兼容；代码回滚可保留表和既有数据，不需要反迁移，更不能通过回滚还原交易数据库。没有新凭证、端口或外部服务。

迁移部署后在所选 release 的 API 容器执行只读查询（用既有 Compose 参数，不打印 env）：

```bash
python manage.py chart_load_reports --build <构建号> --limit 10
python manage.py chart_load_reports --trace-id <追踪UUID> --limit 1
```

命令限最多 50 条，输出服务端接收时间及固定公共诊断 payload，不输出账户标识。诊断表仍按登录用户关联，不能将其当匿名数据公开；访问仅限既有受控运维。保存边界和保留策略见 [行情协议](market-data.md#客户端加载诊断本地实现尚未分发)。旧 TestFlight 14 不会上报；47.80.22.243（首尔服务器）已验证接收与落库，手机端仍须等待 Jenkins／Apple 新包分发和安装，尚无本轮手机端贯通结果。
