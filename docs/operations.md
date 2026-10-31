# 整合环境部署与运维

唯一目标为 **47.80.22.243（首尔服务器）**。原 USDT 生产环境及本地来源目录不属于本轮操作范围。用户已授权整合版部署与旧 USDC Java 环境退役；普通验收禁止真实开平仓、划转或撤保护单。

## 当前部署结构

- `/opt/trade-tools-integrated/releases/<内容版本>`：发布源码；`current` 指向当前版本。
- `/opt/trade-tools-integrated/server.env`：600 权限的独立配置，各 release 通过链接读取。
- Compose 项目 `tradetools-integrated`，使用 `--profile pro`；API、market、worker、scheduler、MySQL、Redis 共六个服务，仅使用项目默认网络。
- API 仅发布 `127.0.0.1:8787`。MySQL、Redis 不发布宿主端口，使用各自命名卷 `integrated-mysql`、`integrated-redis`。
- MySQL 8.4 镜像在 Compose 中固定 digest，独立 `tradetools_integrated` schema / `tt_integrated` 用户。应用不再依赖 `trade_mysql` 或 `trade_network`。
- 宿主 Nginx 为 HTTPS / WSS 代理，仅 `/integrated/` 指向 API；旧根路径和 `/ws/` 返回 404。
- 保留 Docker / containerd、Nginx、`/opt/certbot` 和有效 TLS 证书，它们现在支撑整合版。

部署与行情完整验收基线为 2026-10-31；2026-11-01 额外核对了当前版本、容器健康与注册开关，范围见下节及 [变更](changes.md)。

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

整合版仓库为 `https://github.com/qoqkeep-create/binance.git`，分支 `codex/integrated-ios`。有两种本地工作副本，操作前先核对 Git 元数据和 origin，不能仅凭相同目录名判断：

- 正常独立 clone：根目录有 `.git`，使用普通 `git` 命令，以 `git rev-parse --show-toplevel` / `git remote -v` 核对范围与仓库。Apple / Cloud 准备任务使用过这种副本。
- 原始嵌套交付目录：本目录位于父 Gitee 仓库内，没有本目录 `.git`，但已有 `.integration-runtime/github-publish.git`。本轮退役任务使用这种副本，显式指定独立 Git 元数据；不要对父仓库直接提交或重建不存在的元数据。

```bash
git --git-dir=.integration-runtime/github-publish.git --work-tree=. status
git --git-dir=.integration-runtime/github-publish.git --work-tree=. diff --check
```

Xcode Cloud 必须单独获得指定 GitHub 仓库的访问授权；本机 Deploy key 可推送不代表 Cloud 已获授权。

只提交本任务交付文件；来源目录、父仓库改动与历史不混入。环境文件、私钥、备份、日志、构建和 IDE 用户状态保持忽略。GitHub Deploy key 与目标机 SSH 密钥是不同认证，均不随代码交付。本机 SSH 443 / 代理设置只存于忽略的独立 Git 配置，其他机器正常 clone 即可。

推送授权以 [项目协作规则](../AGENTS.md#发布与验证) 为准。2026-11-01 的名称 / 图标 / 认证 / 白底启动页及开启注册整批获单次推送授权；验收见 [变更记录](changes.md)。推送可能触发 Xcode Cloud，源码推送与开启注册的授权范围不包含真实交易。

源码推送、47.80.22.243（首尔服务器）的部署和 TestFlight 上传分别记录，不能互相替代。手机签名 / 上传见 [TestFlight](testflight.md)，当前待验收项见 [已知事项](known-issues.md)。
