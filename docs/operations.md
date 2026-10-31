# 整合环境部署与运维

本整合版唯一目标为用户指定的 `47.80.22.243`。旧 USDT 生产地址不属于本轮目标；来源运维资料保留于 [参考](reference/USDT_OPERATIONS.md)。用户已授权本次 SSH 部署，禁止通过验收脚本进行真实开平仓、划转或撤保护单。

## 部署结构

- `/opt/trade-tools-integrated/releases/<内容版本>`：不可变的发布源码。
- `/opt/trade-tools-integrated/current`：当前发布链接。
- `/opt/trade-tools-integrated/server.env`：600 权限的独立配置，更新时保留。
- Compose 项目 `tradetools-integrated`，必须 `--profile pro`。
- API `127.0.0.1:8787`，市场采集、账户 worker、原 scheduler 和独立 Redis。
- 复用 `trade_mysql` 数据库引擎，新 schema `tradetools_integrated` / 新用户 `tt_integrated`；不访问旧 Java schema。
- Nginx 仅添加 `/integrated/` location。旧根路径、旧容器及证书继续使用原配置。

## 初次配置与发布

上传已审阅源码后，在服务器运行 `python3 deploy/integrated/prepare_host.py`，仅首次创建新 schema、权限和随机配置；已有配置时拒绝覆盖。初始管理员仅在用户表为空时创建，不重置已存在用户密码。默认不开放注册。

在新 release 内执行：

```bash
bash deploy/integrated/release.sh
```

脚本构建镜像、启动独立 Redis、执行 Django 版本化 migration、初始化空库管理员，再启动四个 Python 进程。配置模板不含真实值。不要打印完整 env、Docker 环境或用户凭证。

Nginx location 来自 `deploy/integrated/nginx-location.conf`，放入现有 HTTPS server 的 include。修改前备份，执行 `nginx -t` 后 reload。TLS 证书使用既有 `trade-tool-seoul-ip`，不关闭证书校验。

2026-10-31 已安装 `/etc/nginx/snippets/tradetools-integrated.conf`，仅在既有 HTTPS server 加 include，`nginx -t` 与 reload 成功。站点修改前备份为 `/etc/nginx/sites-available/trade-tool-seoul.integrated-backup-20261031T085601Z`。发布版本与 HTTPS / WSS 验收见 [变更](changes.md)。

## 健康检查

```bash
curl --fail https://47.80.22.243/integrated/v1/health
cd /opt/trade-tools-integrated/current
INTEGRATED_RELEASE=$(basename "$(pwd -P)") docker compose --project-name tradetools-integrated --env-file /opt/trade-tools-integrated/server.env -f compose.integrated.yaml --profile pro ps
```

API 健康检查数据库、迁移和 scheduler heartbeat；market 健康同时检查 flush 心跳和最近收到 Socket 消息；worker 和 scheduler 单独检查心跳。健康不等于所有交易对补线完毕，验收还需读取真实 K 线 / ticker 事件及 eventTime。

日志只查看所需尾部，保护账户信息；`docker stats --no-stream` 检查资源。市场历史按 [整合说明](INTEGRATION.md) 保留规则清理。新库没有真实 API 绑定，后台维护不会对旧 Java 账户执行操作。

## 更新与回滚

更新必须创建新 release，复用受限配置，以独立 Compose 项目发布。不要推送父仓库 main 触发来源项目的自动部署。

回滚前核对 migration 与旧镜像兼容，保存数据库备份；代码回滚不会还原数据库。选用保留的旧 release，并指定对应 `INTEGRATED_RELEASE` 执行 `docker compose ... up -d --no-build`，随后更新 current 链接、复验健康和 WSS。不要把回滚实现为撤交易所订单或重发 UNKNOWN 命令。

如需关闭本整合入口，可恢复本次备份的 Nginx 站点并 `nginx -t` / reload，再停止 `tradetools-integrated` 的四个 Python 进程；不要使用会删除数据卷的 `down -v`，不要停止旧 Java、MySQL 或 Redis。

## 验收范围

部署版本、验证时间和指标记录在 [变更](changes.md)。本地 SQLite / 模拟器通过只表示本地范围；MySQL migration、HTTPS、WSS 和服务器真实行情必须独立记录。

客户端经 TestFlight 分发的独立流程见 [手机发布指南](testflight.md)。服务器 SSH 部署与 Apple 客户端上传是两个操作；截至 2026-10-31 本指南核对时，后端已部署，Apple 分发签名和 TestFlight 上传尚未执行。

## GitHub 源码交付

用户指定的整合版仓库为 `https://github.com/qoqkeep-create/binance.git`。本目录位于原 Gitee 仓库内部，因此首次交付使用独立 Git 元数据 `.integration-runtime/github-publish.git`，工作树仍为本整合目录，分支为 `codex/integrated-ios`。仅将本目录已追踪的交付文件放在新仓库根目录；父项目的提交历史、远程配置和其他改动不随之上传。

后续维护该独立记录时，在本目录使用 `git --git-dir=.integration-runtime/github-publish.git --work-tree=.`。提交前检查文件范围；忽略的环境文件、凭证、构建和运行目录不得加入。GitHub 认证使用有仓库写权限的 SSH 密钥或 HTTPS 凭证，服务器登录密钥不代表已有 GitHub 权限。推送源码与服务器部署、TestFlight 上传分别执行，实际完成状态以对应交付记录为准。

2026-10-31 仓库管理员添加专用 Deploy key 后，写入权限检查通过，首次提交 `1118eaa` 已推送到 `codex/integrated-ios`，并通过远程分支 SHA 核对。共 974 个文件放在仓库根目录，详细范围见 [变更](changes.md)。公钥位于忽略目录 `.integration-runtime/github-binance-ed25519.pub`，私钥不上传、不加入追踪。本机网络使用已有代理，独立 Git 配置使用 SSH 443；这些本机元数据不会包含在交付代码中。其他机器首次取代码时正常 clone GitHub 仓库即可，无需沿用本机独立元数据路径。
