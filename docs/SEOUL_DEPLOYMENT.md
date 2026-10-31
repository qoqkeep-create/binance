# 首尔服务器测试部署

最后验证：2026-10-31，北京时间。此环境用于从国内测试当前 Java / iOS 项目。

## 入口与发布版本

| 项目 | 当前值 |
| --- | --- |
| 服务器 | `47.80.22.243`，Ubuntu 24.04，x86_64，2 核 |
| 内存 | 云规格 4GB；系统报告 3499MiB，另有 2GiB Swap，swappiness=10 |
| HTTPS API | `https://47.80.22.243`，使用可信 IP 证书 |
| APP WebSocket | `wss://47.80.22.243/ws/v1`，鉴权 Token 通过请求头传递 |
| 后端源码 | `master` 的 `1d2d5e4`，从 Git archive 上传；服务端不保存 Git 凭证 |
| 应用镜像 | `trade-tool-app:1d2d5e4` |
| 发布目录 | `/opt/trade-tool/releases/1d2d5e4`，含源码包及构建日志 |
| 运行配置 | `/opt/trade-tool/compose.yaml`、`/opt/trade-tool/.env` |
| 数据及日志 | `/opt/trade-tool/mysql/data`、`redis/data`、`logs` |

这是新建的独立数据库。旧环境的账号、绑定、策略设置和历史信号没有迁入。
初始测试账号为 `admin`，随机密码保存在本机 Git 忽略的
`ops/.env.seoul-test`（权限 `600`）。服务器对应文件为
`/opt/trade-tool/test-account.env`；应用完整环境文件权限同为 `600`。
不要把这些文件、SSH 私钥或服务器密码加入 Git。

服务器安装了 Docker Engine、Compose 插件、Nginx、Python venv 和 Certbot。
Java 25 / Maven 位于构建镜像中，运行镜像使用 Java 25 JRE。
Docker、Nginx 已启用开机启动，三个容器使用 `unless-stopped`。

## iOS 国内测试

1. 打开 `frontend/ios-app/TradeTool.xcodeproj`。
2. 选择共享 scheme **TradeTool Seoul**，连接 iPhone 后运行。
3. 使用本机 `ops/.env.seoul-test` 中的测试账号登录。
4. 验证行情、搜索、各周期 K 线、实时更新、信号列表以及网络切换后重连。

新版客户端也可在“设置 → 切换服务器”中选择原服务器或首尔服务器，点击
“测试网络响应”查看当前设备的中位耗时，再点击“切换并重新载入”。登录页同样
提供入口；选择会保存，后续启动优先于 scheme 默认值。切换后的账号和数据保持
该服务器自己的状态。Mac 原生网络对比见 [实测报告](SERVER_NETWORK_COMPARISON_2026-10-31.md)。

`Debug-Seoul` 配置通过 [Debug-Seoul.xcconfig](../frontend/ios-app/Config/Debug-Seoul.xcconfig)
指定 API，所有该 scheme 的构建动作为此测试环境。登录态仍按 API origin 隔离。
没有保存运行时选择时，Dev A、Dev B、Release 使用各自构建配置。

首尔环境当前 `TRADING_ACCOUNT_SYNC_ENABLED=false`，没有绑定交易所账户。
APNs、外部消息和 Webhook 均未配置密钥并保持关闭。本次验收覆盖行情、登录和实时连接，
未执行绑定 API、开平仓、划转或真实通知测试。

## 资源及网络

| 服务 | 容器内存上限 | 相关配置 |
| --- | --- | --- |
| `trade_app` | 1280MiB | JVM `-Xms256m -Xmx768m` |
| `trade_mysql` | 768MiB | 仓库固定镜像摘要 |
| `trade_redis` | 768MiB | 仓库固定镜像摘要，AOF 开启 |

资源值由服务器 `.env` 覆盖。报价资产继续为 `USDC`，启动时发现 38 个交易对。
K 线采集、策略参数、各周期缓存窗口保持现有代码；初次启动会逐币补齐历史，
期间图表可通过已有 REST 兜底取数。未以减少缓存窗口的方式缩短补线范围。

端口核验：公网由 Nginx 提供 `80/443`，SSH 使用 `22`；
应用 `8686`、MySQL `3306` 和 Redis `6379` 仅绑定 `127.0.0.1`。
首次补线期间抽样：应用约 423MiB、MySQL 542MiB、Redis 50MiB；
该快照不代表全部历史补齐后或并发负载下的占用。三容器重启次数为 0，未发生 OOM。

## HTTPS 与自动续期

公网入口使用 Let's Encrypt 的 IP 证书，Certbot 5.9.0 安装于 `/opt/certbot`。
该证书采用约六天有效期，必须保留续期任务。机制参见
[Let's Encrypt 官方说明](https://letsencrypt.org/2026/03/11/shorter-certs-certbot)。
本次证书有效至北京时间 **2026-11-07 04:32:02**，已通过客户端 TLS 和 IP SAN 验证。

| 文件 | 服务器安装位置 |
| --- | --- |
| [Nginx 配置](../deploy/nginx/seoul-ip.conf) | `/etc/nginx/sites-available/trade-tool-seoul` |
| [续期服务](../deploy/certbot/trade-tool-cert-renew.service) | `/etc/systemd/system/trade-tool-cert-renew.service` |
| [续期 timer](../deploy/certbot/trade-tool-cert-renew.timer) | `/etc/systemd/system/trade-tool-cert-renew.timer` |
| [续期后重载脚本](../deploy/certbot/reload-nginx.sh) | `/usr/local/sbin/trade-tool-cert-reload`，权限 `750` |

Nginx 的启用链接为 `/etc/nginx/sites-enabled/trade-tool-acme`。
证书路径为 `/etc/letsencrypt/live/trade-tool-seoul-ip/`；
HTTP-01 webroot 为 `/var/www/trade-tool-acme`，80 端口须持续可达。
timer 每六小时检查一次，带最多 20 分钟随机延迟并补跑错过的任务。
签发时配置的 deploy hook 先执行 `nginx -t`，成功后平滑重载。
`certbot renew --dry-run --cert-name trade-tool-seoul-ip` 已通过。

## 本次验证

- Docker 构建内实际运行 Java 25 / Maven 全量测试：331 项，0 失败、0 错误、0 跳过。
- Flyway 成功执行 15 项版本化迁移，数据库版本 v15；MySQL、Redis 健康检查通过。
- 公网 HTTPS：匿名 `/api/auth/me` 返回 401；测试账号登录及鉴权查询返回 200。
- 行情：38 个 USDC ticker、热门分页、BTC 搜索均正常；BTCUSDC 的
  `1m/5m/15m/1h/4h/1d` 各返回 500 根按时间升序排列的 K 线。
- WSS：收到 `ready`、订阅 `ack`、心跳 `pong`，以及真实 ticker / K 线事件。
- 测试会话完成后已退出；账户列表为空，没有接入实际资金。
- iOS `TradeTool Seoul` 在 Xcode 27.2 下 `build-for-testing` 成功，
  构建产物 Info.plist 中的 `API_BASE_URL` 为 `https://47.80.22.243`。
  此项是编译检查；国内 iPhone 实际使用体验由后续真机测试确认。

验收日志：服务器发布目录内 `build.log`，本机
`/tmp/trade-tool-seoul-smoke.log`、`/tmp/trade-tool-seoul-ios-build.log`。
初次全市场历史补线仍在后台进行，不把首批数据视为全部历史已经补齐。

## 后续检查与更新

通过本机 `ops/server-access.env` 中的专用私钥连接服务器，在
`/opt/trade-tool` 执行：

```bash
docker compose --env-file .env -f compose.yaml ps
docker stats --no-stream
docker logs --tail 50 trade_app
systemctl list-timers trade-tool-cert-renew.timer
```

发布后续后端版本时，先上传对应 Git archive 到独立 release 目录并构建，
保持 Dockerfile 内测试门禁；通过后才修改 `.env` 的 `APP_TAG` 并切换应用。
保留上一版本镜像及源码，失败时仅在迁移兼容的前提下回退代码；不删除数据目录。
配置文件、凭证主密钥和数据库不能用示例环境覆盖。
