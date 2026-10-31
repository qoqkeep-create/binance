# 配置字典

> 整合版说明（2026-10-31）：本文保留来源系统的业务或实现资料。当前运行入口、服务器、原生页面与验证边界以 [整合说明](INTEGRATION.md)、[运维](operations.md) 和 [变更](changes.md) 为准；Java 模块仅作参考。


配置值的依据是 [Django settings](../server/riskon/settings.py)、[Compose](../docker-compose.yml)、`docker/tradingview/app.py`（来源路径，未随本整合交付） 和 `docker/frontend/Dockerfile`（来源路径，未随本整合交付）。本文列出维护分组和易错点，不复制任何真实凭证。

## 生效位置

- 本地 Django 使用 `python-dotenv` 加载环境；开发样例见 [server/.env.example](../server/.env.example)。
- 生产使用仓库目录外部管理的 `.env.docker` 文件，路径见 [运维文档](operations.md)。它不纳入 Git。
- `docker compose --env-file` 只提供 Compose 变量替换；只有写进服务 `environment` 等字段的变量才进入容器。写入环境文件不等于应用一定能读到。
- `VITE_*` 是构建期公开参数，会进入浏览器代码，绝不能保存密钥。修改 API 基址后须重新构建前端。
- 修改配置要说明涉及服务、是否需要重建、验证方法和回退方式；不要只改示例文件后声称线上生效。

## 核心变量

| 变量 | 用途 / 注意 |
| --- | --- |
| `SECRET_KEY` | Django 签名密钥；不是 `DJANGO_SECRET_KEY`；生产禁止开发默认值 |
| `AES_SECRET_KEY` | API / 模型凭证的当前加密密钥；生产至少 32 字符、与 `SECRET_KEY` 不同，需稳定保管并与数据库备份配套；新值始终只用此密钥加密 |
| `AES_PREVIOUS_SECRET_KEY` | 仅供密钥轮换窗口读取上一代 AES-GCM / CBC 密文；读取后以当前密钥重写，完成全量迁移和独立解密验证后必须清空 |
| `DEBUG`、`ALLOWED_HOSTS` | 生产关闭调试、明确域名，不用 `*` |
| `CORS_ALLOW_ALL_ORIGINS`、`CORS_ALLOWED_ORIGINS` | 生产关闭任意来源，按实际部署域名配置 |
| `PUBLIC_APP_URL` | 密码重置等链接的公开根地址 |
| `AUTH_REFRESH_COOKIE_SECURE`、`PASSWORD_RESET_TIMEOUT` | 生产 HTTPS cookie；重置超时默认 1800 秒，本地 HTTP 调试另配 |
| `AUTH_LOGIN_FAILURE_WINDOW_SECONDS`、`AUTH_LOGIN_LOCK_SECONDS`、`AUTH_LOGIN_ACCOUNT_MAX_FAILURES`、`AUTH_LOGIN_IP_MAX_FAILURES` | 登录失败账户 / IP 双维度窗口和临时锁；默认 3600 / 180 秒、10 / 50 次，依赖共享缓存保证多 worker 一致 |
| `DB_ENGINE`、`DB_HOST`、`DB_PORT`、`DB_NAME`、`DB_USER`、`DB_PASSWORD` | 生产 MySQL；`DB_ENGINE` 非 mysql 时走本地 SQLite |
| `MYSQL_ROOT_PASSWORD` | MySQL 容器初始化 / 管理凭证，不是应用 DB 用户密码 |
| `USE_REDIS_CACHE`、`REDIS_URL` | 生产开启 Redis；locmem 不替代跨进程锁和心跳 |
| `GUNICORN_WORKERS`、`GUNICORN_TIMEOUT` | Compose 默认 8 / 60 秒，调大并发须评估交易所限频及 DB 连接 |
| `RUN_SCHEDULER_IN_WEB` | Compose 固定 false，调度仅运行于 scheduler 服务 |
| `LOG_LEVEL`、`APP_VERSION` | 日志级别；部署脚本生成运行版本用于定位 |
| `DATA_UPLOAD_MAX_MEMORY_SIZE` | Django 请求体内存上限，默认 262144 字节（256 KiB）；文件上传内存上限同步使用该值。用于限制本系统 JSON / 表单入口的资源消耗，调大前需逐接口评估 |
| `HTTP_PORT`、`HTTPS_PORT`、`SSL_CERT_PATH`、`SSL_KEY_PATH` | 容器网关宿主端口和证书挂载；不能与宿主机 Nginx 抢 80 / 443 |

## 交易所与行情

| 变量 | 用途 |
| --- | --- |
| `BINANCE_FUTURES_BASE_URL` | 默认 Binance USDT 合约 REST 源 |
| `BINANCE_TIMEOUT_SECONDS`、`BINANCE_RECV_WINDOW` | 超时默认 10 秒，签名接收窗口默认 5000ms |
| `BINANCE_DEFAULT_MAX_LEVERAGE` | 缺省上限配置，不能替代实际交易对约束校验 |
| `LEAD_TRADING_ENABLED` | 带单新绑定 / 开仓 / 追单入口开关；Python 缺省 false，Compose 在兼容基线上线后缺省 true，可用环境值 false 暂停。关闭后仍允许存量带单查询、平仓、保护及后台管理，回退边界见 [带单模式](lead-trading.md) |
| `BINANCE_FUTURES_WEIGHT_LIMIT_PER_MINUTE`、`BINANCE_SPOT_WEIGHT_LIMIT_PER_MINUTE`、`BINANCE_SAPI_WEIGHT_LIMIT_PER_MINUTE` | 三类接口的本地每分钟保守预算，默认 2400 / 6000 / 12000；用于进程间协调，不是对 Binance 官方限额的永久声明 |
| `BINANCE_BACKGROUND_WEIGHT_RATIO`、`BINANCE_NORMAL_WEIGHT_RATIO`、`BINANCE_CRITICAL_WEIGHT_RATIO` | 低优先级、普通和保护 / 交易请求可用预算比例，默认 0.65 / 0.85 / 0.96；须保持递增且不超过 1 |
| `SERVER_PUBLIC_IP` | 展示给 API 白名单设置的服务器 IP |
| `MARKET_SNAPSHOT_PREWARM_ENABLED`、`MARKET_SNAPSHOT_PREWARM_URL` | 公开 K 线快照的 CDN 预热，默认开启、目标为 `https://ba.wow211.com`；请求的是公开行情 URL，不带凭证，机制见 [行情文档](market-data.md) |
| `VITE_API_BASE_URL` | 生产 Compose 默认 `/api`；当前工作区开发配置也为 `/api`，`8de868a` 原开发代理仅支持 `/v1`，详见开发文档 |
| `DEV_API_PROXY_TARGET` | 并行任务新增的本地 Vite 代理目标，默认 `http://127.0.0.1:8000`，shell 值优先；不是浏览器密钥或生产 Nginx 配置 |

`BINANCE_SPOT_BASE_URL` 及若干行情调优变量在代码可读取，但当前 Compose 未全部透传。需新增配置时同时检查 Python / 前端读取位置、Compose environment / build args 和环境文件，不假设已生效。WS 当前入口和缓存参数见 [行情文档](market-data.md)。

## 信号与通知凭证

| 变量 | 服务 / 作用 |
| --- | --- |
| `EXTERNAL_SIGNAL_API_KEY` | webhook 入站信号专用 token；合作方 URL `key` 或 `X-API-Key` 的值，不是 Binance Key |
| `TV_MESSAGE_API_TOKEN`、`TV_MESSAGE_INGEST_URL` | webhook 向后端入库的内部认证和地址 |
| `TV_WEBHOOK_WECOM_URL`、`TV_WEBHOOK_WECOM_SECRET` | 企业微信机器人地址及签名配置，机器人 URL 本身也是敏感信息 |
| `TV_WEBHOOK_TIMEOUT_SECONDS`、`TV_WEBHOOK_LOG_LEVEL` | webhook 外发请求超时、日志 |
| `TRADE_NOTIFICATION_URL`、`TRADE_NOTIFICATION_TOKEN`、`TRADE_NOTIFICATION_TIMEOUT_SECONDS` | 后端向内部交易通知转发服务发送的配置 |
| `TRADE_NOTIFICATION_STATE_PATH` | webhook 内部交易通知的 `eventId` 幂等账本；Compose 默认落在独立持久卷 `/data` |
| `EXTERNAL_TRADE_SIGNAL_ENABLED` | 独立对外交易通知开关，默认 false；开启前核对目标和双方协议 |
| `EXTERNAL_TRADE_SIGNAL_URL`、`EXTERNAL_TRADE_SIGNAL_API_KEY`、`EXTERNAL_TRADE_SIGNAL_TIMEOUT_SECONDS` | 对方接收地址、请求头密钥和超时，API Key 只放 `X-External-Message-Key` |
| `MARKET_ANALYSIS_ALERT_URL`、`MARKET_ANALYSIS_ALERT_TOKEN` | 内部趋势通知配置 |
| `OPS_ALERT_URL`、`OPS_ALERT_TOKEN`、`OPS_ALERT_TIMEOUT_SECONDS` | 运维告警；部分 token 有兼容回退，改动时要逐端验证 |
| `TG_BOT_TOKEN`、`TG_CHAT_ID` | Telegram 通道，外部指标信号不走此通道 |
| `TV_WEBHOOK_API_KEY` | 历史 TradingView 变量，保留不表示旧入口已恢复 |

`MARKET_ANALYSIS_SIGNAL_RETENTION_DAYS` 默认 90 属于另一类扫描状态配置，不应与统一信号消息 3 天保留期混为一谈。

## AI 与邮件

`AI_PROVIDER`、`AI_BASE_URL`、`AI_API_KEY`、`AI_MODEL`、`AI_TIMEOUT_SECONDS` 为环境默认模型配置。当前还有数据库中的共享加密模型目录与用户选择，不能只按 settings 中的旧注释理解，详见 [研究文档](research.md)。

`EMAIL_HOST`、`EMAIL_PORT`、`EMAIL_HOST_USER`、`EMAIL_HOST_PASSWORD`、`EMAIL_USE_SSL`、`EMAIL_USE_TLS`、`EMAIL_FROM` 已由 Django settings 读取并由 Compose 透传。`EMAIL_HOST` 为空时使用控制台后端，仅记录邮件内容而不实际投递；生产是否可发送仍取决于受控 `.env.docker` 的实际配置、网络和 SMTP 服务，不能仅凭代码存在就声称已验收。

## 样例文件与生产差异

[.env.docker.example](../.env.docker.example) 是变量参考，不是可覆盖生产的模板：其端口为 80 / 443、`VITE_API_BASE_URL=/v1`；最近生产记录的容器端口为 8080 / 8444，Compose 构建缺省 `/api`。`/v1` 和 `/api` 在生产网关均有映射；Vite 代理按 [开发文档](development.md) 区分基线和当前未提交改动。

新环境安装必须结合 [运维拓扑](operations.md) 逐项核对。不要覆盖整份生产环境文件或把示例默认密钥用于线上。

## 密钥维护

用户密码使用 BCrypt / PBKDF2 哈希；交易所凭证是 AES-GCM 加密，兼容读取旧 CBC 数据，两者不是同一机制。解密密钥环按当前 AES、上一代 AES、历史 `SECRET_KEY` 去重尝试，后两者只为迁移兼容；轮换不能直接替换主密钥，必须先发布兼容代码，再短期配置上一代密钥、迁移全部密文、验证仅当前密钥可读，最后删除上一代密钥。备份需保护数据库与加密密钥，日志只输出数量、脱敏标识和必要状态。

生产 MySQL 模式会在 Django 启动阶段拒绝缺失、短于 32 字符或与 `SECRET_KEY` 相同的当前 AES 密钥；`AES_PREVIOUS_SECRET_KEY` 可以兼容历史短密钥，但不得与当前密钥相同，也不得作为长期配置保留。
