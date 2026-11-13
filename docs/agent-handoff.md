# TradeTools-Binance-iOS Agent 交接手册

> 用途：给接手本项目的 Agent、开发者和发布人员提供一份可执行的全局地图。
>
> 更新时间：2026-11-13（北京时间）
>
> 当前分支：`codex/integrated-ios`；当前 HEAD：`d241a39 docs: record trading experience deployment`
>
> 项目根目录：`/Users/apple/work/TradeTools-Binance-iOS`

这份手册描述“如何理解、修改、验证和交付整个整合项目”。它不替代主题文档，也不把历史验收结果升级成当前事实。主题文档有更具体的字段、协议和测试证据时，应以主题文档为准；本手册负责给出阅读顺序、边界和交接动作。

## 1. 接手时先建立正确的事实

当前工作区是一个独立 Git 项目，包含 Python/Django 后端、SwiftUI/Metal iOS 客户端、ArkTS/ArkUI 鸿蒙客户端、交易计划 Web 页面和整合部署配置。旧 USDT 与 USDC 项目是历史来源，只读查询，不是本项目的第二个运行时，也不是修改目标。

截至本手册更新时间，最近两个功能提交为：

| 提交 | 内容 |
| --- | --- |
| `0ab6f9f` | 新增独立 `experiences` Django 应用、交易经验页面、计划图片处理和阿里云 OSS 签名上传代码 |
| `d241a39` | 记录交易经验及 OSS 图片上传发布结果 |

线上整合环境目标是 **47.80.22.243（首尔服务器）**。最近一次交易经验版本的后端 release、静态页面和验证事实如下：

| 项目 | 当前事实 |
| --- | --- |
| 后端 release | `/opt/trade-tools-integrated/releases/integrated-20261113-full-0ab6f9f` |
| `current` | 指向上述 release |
| 交易计划 Web | `/opt/trade-tools-integrated/web/trade-plan-20261113-v7` |
| 公网页面 | `https://47.80.22.243/plan/` |
| migration | `experiences.0001_initial` 已应用 |
| 容器 | MySQL、Redis、api、market、worker、scheduler 六个容器均 healthy（以最新运维记录复核） |
| 公网健康检查 | `/integrated/v1/health` 的 database、migrations、scheduler 均为 true |
| OSS | 代码已发布，但当前服务器 `server.env` 没有 `OSS_*` 变量，真实 OSS 上传关闭 |
| 图片回退 | 交易计划页使用浏览器 Data URL 和 `localStorage` 回退 |

“页面能打开”“容器 healthy”“后端有 OSS 代码”分别只证明页面、进程和代码存在，不能互相替代。尤其不能把当前状态写成“OSS 已验收”“真实图片已上传”“交易功能已实盘通过”。

## 2. 第一次接手的阅读顺序

按下面顺序阅读，避免只看某一个页面或某一次发布记录后误改边界：

1. `AGENTS.md`：项目协作规则、来源目录只读要求、推送与部署授权规则。
2. [`docs/README.md`](README.md)：主题文档目录和每类事实的入口。
3. [`docs/INTEGRATION.md`](INTEGRATION.md)：整合后的数据链路、API、WSS、客户端映射。
4. [`docs/architecture.md`](architecture.md)：运行单元、模块责任、用户和账户身份。
5. [`docs/configuration.md`](configuration.md)：配置入口、环境变量和安全边界。
6. [`docs/development.md`](development.md)：本地安装、后端/iOS/Harmony 验证命令和已完成测试。
7. [`docs/operations.md`](operations.md)：47.80.22.243（首尔服务器）的发布、备份、回滚和最近状态。文件顶部的最新日期记录优先于较早历史段落。
8. 按任务补读：
   - 交易、订单、UNKNOWN、保护单：[`docs/trading-safety.md`](trading-safety.md)
   - 资金、归集、保证金率、结算：[`docs/capital-and-transfers.md`](capital-and-transfers.md)
   - 带单模式：[`docs/lead-trading.md`](lead-trading.md)
   - 行情、K 线、Redis 主题、补全：[`docs/market-data.md`](market-data.md)
   - APNs、Echobell、信号和投递：[`docs/signals-and-notifications.md`](signals-and-notifications.md)
   - iOS 页面、控件、截图和复刻边界：[`docs/ios-web-parity.md`](ios-web-parity.md)
   - 鸿蒙实现与分批计划：[`docs/harmony-client.md`](harmony-client.md)
   - 签名、Archive、TestFlight：[`docs/testflight.md`](testflight.md)
   - 未完成和待验收事项：[`docs/known-issues.md`](known-issues.md)
   - 具体日期的实现和上线记录：[`docs/changes.md`](changes.md)
   - 来源项目和历史 Git 基线：[`docs/sources.md`](sources.md)
   - 主题文档维护规则：[`docs/maintenance.md`](maintenance.md)

如果任务涉及最近新增的交易计划页面，再读 `docs/development.md` 开头的交易经验/OSS 段落和 `docs/operations.md` 顶部的“交易经验与 OSS 图片上传发布（2026-11-13）”。

## 3. 不可违反的协作与安全边界

### 3.1 修改位置和 Git

- 所有修改留在本项目根目录。原 USDT 项目 `/Users/apple/work/TradeTools-Binance` 和原 USDC 项目 `/Users/apple/work/tradetools-usdc` 只用于历史查询。
- 不要在来源目录复制一份“临时修复”后忘记回迁，也不要把来源项目当成部署源。
- 使用根目录 `.git` 和普通 `git status`、`git diff`、`git log`。先确认路径：

  ```bash
  cd /Users/apple/work/TradeTools-Binance-iOS
  git status --short --branch
  git rev-parse --show-toplevel
  ```

- 用户未明确说“推送”前，只保留本地改动。用户明确要求推送或部署时，按 `AGENTS.md` 交付整个整合工作区的全部改动，包括其他会话已经存在的改动；不要擅自缩小到自己的文件。
- 每次交付前执行 `git diff --check`，检查未追踪文件，并确认没有把凭证、私钥、构建产物、运行日志、数据库备份或 IDE 用户状态加入 Git。

### 3.2 部署授权不是交易授权

部署、重启、健康检查、备份和数据库迁移授权，不等于以下任何授权：

- 开仓、平仓、撤单或重发交易命令；
- 划转资金、修改 API Key、修改杠杆或账户模式；
- 撤掉已有保护单、重挂止损、改策略或人工接管未知命令；
- 打开带单新增风险或启用真实外部信号。

诊断优先使用只读查询。任何可能调用交易所写接口的测试必须明确说明对象、账户、环境和恢复方式；通常使用隔离数据库与交易所替身，不在生产实盘上“顺便验证”。

### 3.3 凭证

- AccessKey、SecretKey、JWT secret、数据库密码、MySQL root 密码、APNs `.p8`、Echobell URL、QA 密码和真实账户资料不能进入源码、文档、前端、截图、命令历史或普通日志。
- 生产环境真实配置只放 **47.80.22.243（首尔服务器）** 的受限文件 `/opt/trade-tools-integrated/server.env`（权限应为 0600）及 `/opt/trade-tools-integrated/secrets/` 下的只读密钥文件。
- 交易计划 OSS 使用受限 RAM 子账号。浏览器只能拿到短期签名 PUT URL，不能拿到 AccessKey Secret。
- 如需获得凭证或人工操作第三方控制台，应使用项目规定的受限凭证流程；不要在文档中要求下一位 Agent 把密钥贴到聊天里。

## 4. 项目目录地图

```text
/Users/apple/work/TradeTools-Binance-iOS/
├── AGENTS.md                         # 强制协作规则
├── README.md                         # 项目入口和快速导航
├── compose.integrated.yaml           # MySQL、Redis、四个 Python 运行服务
├── server/                           # Django 后端
│   ├── manage.py
│   ├── riskon/                       # settings、URL、ASGI/WSGI、统一入口
│   ├── common/                       # 认证、响应、共享锁/请求工具、通用模型
│   ├── trading/                      # 交易命令、订单、持仓、保护、结算
│   ├── market_stream/                # Binance 公共行情、K 线、历史补全、Redis 发布
│   ├── mobile/                       # iOS/Harmony 使用的移动 API、命令和账户流
│   ├── notifications/                # 事件、投递记录、APNs/Echobell/SMTP 适配
│   ├── capital/                      # 资金、归集、保证金和转账状态机
│   ├── lead_trading/                 # 带单模式和组合 Key 边界
│   ├── experiences/                  # 独立交易经验与计划图片 URL/OSS 签名
│   └── requirements.txt
├── frontend/
│   ├── ios-app/                      # SwiftUI、Metal、Widget、Xcode 工程和 XCTest
│   ├── harmony-app/                  # ArkTS/ArkUI 工程、签名和鸿蒙测试
│   └── trade-plan-web/               # 独立静态交易计划页面
├── deploy/integrated/                # Dockerfile、环境模板、发布脚本和初始化脚本
├── docs/                             # 主题主文档、API 说明、验收与本手册
└── .gitignore                        # 构建、运行、环境和 IDE 状态忽略规则
```

以下文件通常存在于本地但不应提交：`.integration-runtime/`、`.build/`、`server/.venv/`、Xcode DerivedData、IDE 用户状态、运行日志、临时截图以及完整 `.env` 文件。

## 5. 运行架构

### 5.1 总体数据链路

```text
Binance 公共 /market WSS
        ↓
market_stream
        ├─ MySQL：收盘 K 线、历史保留窗口、补全任务
        └─ Redis：ticker、热窗口、Pub/Sub、sequence、预算/锁
                         ↓
                 api 共享接收与内存分发
                         ↓ /ws/v1
                 SwiftUI / Metal、Harmony 客户端

客户端 HTTP /api/commands
        ↓
持久化交易命令 → 账户 lease / DB fence → 原交易服务 / Binance
        ↓
账户私有 WSS → Inbox → 账户串行归并 / REST 对账 → Outbox → 客户端刷新

run_scheduler → 保护单、结算、资金维护、通知调度
mobile_worker → 命令异步执行、UNKNOWN 收敛、账户维护
```

行情、交易、资金和通知是不同的责任域。修改其中一个域时，先确认是否改变了其他域的事实来源、锁、事件或 API 兼容性。

### 5.2 Compose 服务

`compose.integrated.yaml` 的 `pro` profile 一共有六个运行服务：

| 服务 | 责任 | 关键边界 |
| --- | --- | --- |
| `mysql` | 持久化业务数据、行情历史、事件和命令 | 使用持久卷；真实生产锁/唯一约束不能用 SQLite 代替 |
| `redis` | 缓存、lease、fence、行情热数据、Pub/Sub、限流和共享预算 | `noeviction`；不能把 Redis 丢失当成交易事实丢失 |
| `api` | Django HTTP、认证、业务查询、命令提交、WSS 入口 | 监听容器内 8787，由 Nginx 暴露 `/integrated/` |
| `market` | `manage.py market_stream`，公共行情订阅、收线、历史补全和发布 | 受 Binance 预算、出口和保留窗口约束 |
| `worker` | `manage.py mobile_worker`，异步交易命令和账户维护 | lease/fence 失效时不能继续写结果 |
| `scheduler` | `manage.py run_scheduler`，保护、结算、资金维护和通知 | 只读挂载 APNs 等密钥目录；与 api 分离 |

Compose 还包括 `mysql` 128 MiB InnoDB buffer pool、1 GiB 内存限制、Redis 256 MiB maxmemory 等资源约束。行情表增长和 `prune_history()` 的查询成本是长期运维风险，处理前先读 `docs/operations.md` 中关于行情表容量的记录。

### 5.3 入口与路径

- 服务器公网 API 基址：`https://47.80.22.243/integrated/`。
- API 内部健康路径：`/v1/health`，公网完整路径为 `/integrated/v1/health`。
- HTTP 业务接口通常位于 `/api/...` 或 `/v1/...`。
- 鉴权 WSS：公网 `/integrated/ws/v1`，内部由 ASGI/API 提供。
- 计划页：`https://47.80.22.243/plan/`，由 Nginx 指向独立静态目录。
- Nginx 路由和 HTTPS 证书属于服务器配置，不要因为静态页面改动就重启交易容器。

API、market 和客户端的公共事件协议要成套发布。不能只更新 API 或只更新 market，然后让旧客户端继续发送未知频道。

## 6. Django 模块和业务边界

| 模块 | 负责 | 修改时首先检查 |
| --- | --- | --- |
| `riskon` | settings、根 URL、ASGI/WSGI、环境开关 | 生产安全配置、`/integrated/` 前缀、WSS 路由 |
| `common` | 统一响应、认证工具、共享请求、锁和基础设施 | 全局鉴权、限流、Redis/DB fallback 是否改变 |
| `trading` | 订单、命令、持仓、保护单、结算和交易日志 | `trading-safety.md`、UNKNOWN、Decimal、幂等和 fence |
| `market_stream` | ticker、K 线、历史分页、补线、Redis 主题 | `market-data.md`、Binance 预算、收线完整性 |
| `mobile` | 移动端 API、设备、账户流、命令入口 | iOS/Harmony 字段兼容、Bearer 和模式头 |
| `capital` | 余额、转账、归集、保证金和历史结算 | `capital-and-transfers.md`、资金状态机 |
| `lead_trading` | 普通/带单模式身份和能力 | `LEAD_TRADING_ENABLED`、组合 Key、存量保护 |
| `notifications` | 事件入库、独立投递记录和渠道适配 | 交易成功路径不能依赖外部发送成功 |
| `experiences` | 交易经验内容和图片 URL/OSS 上传签名 | 不得导入订单、持仓、命令或资金服务 |

新增功能应尽量落在正确的域中。交易经验是复盘内容，不能用 `trading` 的订单模型承载；计划图片是页面资产，不能进入交易命令 payload；通知失败不能回滚已确认交易。

## 7. 认证、用户和账户身份

### 7.1 HTTP 和 Cookie

- 登录、注册、当前用户、refresh、logout 沿用整合 API 的 JWT/refresh 机制。
- API 请求使用 Bearer access token；refresh 使用安全、Secure、限定路径的 cookie。
- 生产必须使用 HTTPS；`PUBLIC_APP_URL`、CORS、CSRF、Session 和 refresh cookie 的安全开关不能为开发值。
- REST 遇到 401 时，客户端按现有规则最多 refresh 并重试一次；身份已切换后旧请求不能覆盖新会话。

### 7.2 交易模式和绑定代际

每个交易请求都与用户、交易模式、绑定 ID/指纹和创建时快照关联。普通 Key 与带单组合 Key 不能互借；账户重新绑定后产生新的 binding generation，旧 worker 不能给新绑定写执行结果。

WSS 连接通过 Bearer JWT 和 `X-Trading-Mode` 建立。事件按用户和模式过滤。客户端收到 `trading.*` 事件后，应重新读取权威业务状态；事件是“有变化提示”，不是订单成功回执。

### 7.3 交易经验的用户隔离

`server/experiences` 的所有查询都按 `request.user` 过滤。即使知道另一个用户的整数 ID，也不能读取、修改或删除其经验。新接口必须保持这一点，并为未认证请求返回 401，而不是返回空列表或生成匿名数据。

## 8. 交易安全规则（修改交易代码前必读）

### 8.1 幂等、lease 和 fence

- 客户端提交命令必须带幂等键；后端保存用户、模式、请求哈希、绑定 ID/指纹和创建时间快照。
- 每账户 Redis lease 默认 30 秒、10 秒续期；DB fence 防止旧 worker 在新 worker 接管后继续写入。
- 网络调用可能已经到达交易所，但本地进程在返回前崩溃，因此不能宣称交易所写入 exactly-once。
- SQLite/LocMem 只适合逻辑检查，不能证明 MySQL 锁、唯一约束、跨进程 lease 或 Redis 预算正确。

### 8.2 UNKNOWN

进程中断后的 RUNNING 命令可能进入 UNKNOWN。处理顺序必须是：

1. 读取本地持久化订单和命令事实；
2. 使用同一绑定代际保存的原交易所订单号做精确只读核对；
3. 只在待成交、成交/部分成交、明确零成交等事实完整的终态下收敛；
4. 缺少订单号、查询失败、字段不完整或账户代际不匹配时保持 UNKNOWN；
5. 未收敛的 UNKNOWN 阻止本绑定新增风险，但不凭猜测重发、撤单或改写订单。

“成交”是交易事实，不等于某个本地 UI 卡片有订单号；“订单不存在”也必须结合条件单终态和本地历史判断，不能直接当作失败。

### 8.3 保护单和资金

- 保护单必须先挂新保护，再确认新保护存在，最后处理旧保护，不能制造无保护窗口。
- 使用 `Decimal` 处理金额、数量、价格、费率和保证金率；不能使用 float 作为持久化或最终判断依据。
- 资金查询不会自动触发交易动作。可用余额、保证金率、估算结算和强平结算是不同事实，不能互相冒充。
- `LEAD_TRADING_ENABLED=false` 时禁止新增带单风险，但要保留存量持仓的保护和平仓边界。

## 9. 行情与实时推送

公共行情由 Binance `/market` WSS 进入 `market_stream`，写入 MySQL 收盘线并发布 Redis 热数据。客户端同时使用 HTTP 历史分页、Redis/WSS 实时事件和 Metal 图表管线。

- `1m` 是原生基础周期，高周期必须由完整源桶聚合。
- 缺少源线时不能伪造完整高周期蜡烛。
- 历史补全、尾部恢复和内部缺口修复是后台任务，受 Binance 限速和保留窗口约束。
- 客户端先展示已有快照，再等待后台就绪/订阅确认，不能把首屏空白误判成交易所无数据。
- Redis v2 主题包含频道、币种、周期、sequence；API 与 market 必须匹配版本。
- WSS 每连接有界队列，慢客户端应断开重连；access token 过期时使用 4401 等既定路径恢复。

修改行情代码后，应读 [`docs/market-data.md`](market-data.md) 的具体主题、分页边界、周期和验证记录，不要只凭 API 返回一根 K 线就判断冷补已完成。

## 10. 交易计划 Web 与交易经验

### 10.1 页面边界

目录：`frontend/trade-plan-web/`

- `index.html`：计划记录、新建计划、交易经验栏目、经验弹窗、计划图片输入。
- `app.js`：视图切换、筛选、localStorage、经验卡片、弹窗、图片选择/粘贴/拖放和 OSS 适配。
- `styles.css`：白底黑色装饰、横向经验卡片和响应式布局。

交易经验是独立栏目，主页横向滚动显示卡片，每张卡片有标题、正文摘要、时间和“查看全文”；新增/编辑采用弹出框。它不读取订单、持仓、命令或账户余额，也不触发交易 API。

### 10.2 经验后端模型

文件：`server/experiences/models.py`、`serializers.py`、`views.py`、`urls.py`。

模型 `TradingExperience` 的字段：

| 字段 | 说明 |
| --- | --- |
| `user` | Django 用户外键，级联删除，所有接口按用户隔离 |
| `title` | 服务端最大 120 字，不能为空，保存前 trim |
| `body` | 服务端最大 20,000 字，不能为空，保存前 trim |
| `images` | JSON 数组，最多 5 个 URL；允许 HTTP(S) 或 `data:image/...` |
| `created_at` / `updated_at` | 服务端时间戳 |

数据库表名为 `trading_experience`，索引为用户和创建时间组合索引，migration 为 `experiences.0001_initial`。

### 10.3 经验 API

以下路径相对于 API 根；线上完整前缀为 `/integrated/v1/experience/`，全部需要登录：

| 方法 | 路径 | 作用 |
| --- | --- | --- |
| `GET` | `/v1/experience/list` | 返回当前用户经验，按最新创建时间排序 |
| `POST` | `/v1/experience/create` | 创建标题、正文和图片 URL 列表 |
| `GET` | `/v1/experience/<id>` | 读取当前用户的一条经验 |
| `PATCH` / `PUT` | `/v1/experience/<id>` | 局部或完整更新 |
| `DELETE` | `/v1/experience/<id>` | 删除当前用户经验 |
| `POST` | `/v1/experience/upload-url` | 申请一张图片的短期 OSS PUT URL |

`upload-url` 只返回签名上传信息，不接收图片字节。未配置 OSS 时返回 503；未认证时返回 401。经验保存接口只保存 URL，不验证对象是否已经成功上传，因此启用 OSS 后仍应在前端处理 PUT 失败和孤儿对象清理策略。

### 10.4 计划图片输入

新建计划界面支持：

- 文件选择；
- 拖放图片；
- 从剪贴板直接粘贴图片；
- 每条计划最多 5 张；
- 单张前端大小限制为 4 MB；
- 没有 OSS 配置或没有可用 token 时回退到 Data URL 和浏览器本地存储。

计划图片 URL 只属于计划页面数据，不进入交易命令或订单 API。UI 的标题/正文提示长度（当前页面显示的 80/2400 字）比后端最大长度更严格；如果调整页面限制，应同步检查序列化器、存储大小、XSS 展示和移动端布局。

### 10.5 当前持久化现状

当前交易计划页默认使用 `localStorage`。后端接口已经具备，但页面只有在部署时注入 `window.TRADE_PLAN_CONFIG` 并提供 token 适配后，才会调用带鉴权的经验/OSS API。不要把“后端接口已经存在”写成“网页已经完成云端同步”。

## 11. 阿里云 OSS 配置和启用方式

### 11.1 代码链路

`server/experiences/oss.py` 使用无第三方 SDK 的 Aliyun OSS V1 签名算法生成短期 PUT URL：

1. 浏览器向 `/v1/experience/upload-url` 提交 `content_type` 和 `size`；
2. 后端读取服务器环境中的 Endpoint、Bucket、RAM AccessKey；
3. 后端生成随机对象 key：`<OSS_KEY_PREFIX>/<user_id>/<uuid>.<ext>`；
4. 浏览器携带返回的 `Content-Type` 向 OSS 直接 PUT；
5. 前端把返回的 `public_url` 写入经验或计划图片字段；
6. API 从不接收图片字节，也不向浏览器暴露 Secret。

### 11.2 环境变量

模板在 `deploy/integrated/server.env.example`，实际值只放 **47.80.22.243（首尔服务器）** 的受限 `server.env`：

```dotenv
OSS_ENDPOINT=https://oss-cn-<region>.aliyuncs.com
OSS_BUCKET=<bucket-name>
OSS_REGION=<region>
OSS_ACCESS_KEY_ID=<ram-access-key-id>
OSS_ACCESS_KEY_SECRET=<ram-access-key-secret>
OSS_PUBLIC_BASE_URL=<optional-public-or-cdn-base-url>
OSS_KEY_PREFIX=trade-plan
OSS_SIGNED_URL_TTL=600
OSS_MAX_IMAGE_BYTES=4194304
```

当前生产文件没有这些 `OSS_*` 变量，所以 `oss-configured=False`，真实上传关闭。`OSS_REGION` 当前由配置保留供部署和审计使用；签名实现使用 Endpoint 的 host 生成 URL。

### 11.3 启用前必须完成的云端配置

启用真实 OSS 前，逐项完成并留下非敏感验证证据：

1. 创建专用 Bucket，确认地域和 Endpoint；
2. 创建受限 RAM 子账号，只授予目标 Bucket 的对象写入/读取权限，禁止无关 Bucket 和账号管理权限；
3. 确认对象读取策略。若 Bucket 私有，不能直接把普通 `public_url` 当作长期可读地址，应改用带鉴权 CDN 或应用侧签名 GET；
4. 配置 Bucket CORS，允许计划页实际来源，至少覆盖 `PUT`、`GET`、`HEAD` 和 `Content-Type` 请求头；
5. 在服务器写入 `server.env`，设置 0600，不能写入 Git 或前端；
6. 重启/重建 api、worker、scheduler，使环境变量生效；
7. 用已登录的非生产测试账号上传一张小图片，验证签名 URL、浏览器 PUT、读取 URL、经验保存和跨刷新加载；
8. 验证错误路径：未认证 401、OSS 未配置 503、非图片、超 4 MB、超过 5 张和过期 URL；
9. 检查日志中没有 Secret、完整签名 query 或用户图片内容；
10. 记录 Bucket、权限、CORS、域名/CDN 和验收时间，但不记录密钥值。

若没有真实 Bucket、Region、RAM 凭证或无法完成 CORS/读取策略验证，应保持关闭并继续使用本地回退。不能为了让按钮“看起来能上传”而把 Secret 放到 `window.TRADE_PLAN_CONFIG`。

### 11.4 前端注入契约

部署页面可注入类似配置：

```js
window.TRADE_PLAN_CONFIG = {
  enableOssUploads: true,
  apiBase: '/integrated',
  getAccessToken: () => token,
};
```

也可提供自定义 `uploadImage(file)` 适配器。`getAccessToken` 不应把长期密钥写死在静态文件中；token 失效时应走既有登录/refresh 逻辑。关闭 OSS 时不要调用 `/upload-url`，直接使用已实现的 Data URL 回退。

## 12. iOS 客户端

工程：`frontend/ios-app/TradeTool.xcodeproj`。

- SwiftUI 负责页面、导航、表单和系统 sheet；Metal 负责行情图表绘制。
- Widget/Live Activity 是独立扩展，签名和 Bundle ID 规则见 `docs/testflight.md`。
- 日常运行 scheme：`TradeTool`；常用连接整合环境：`Debug-Seoul`；归档：`TradeTool Release`；图表校准/真实 QA smoke 使用 `TradeTool Chart Calibration` 和 `IntegratedNativeUITests`。
- Bundle ID：`com.waibao2025.trade.integrated`，与旧客户端隔离。
- 新客户端连接 `https://47.80.22.243/integrated/`（47.80.22.243 为首尔服务器）。
- Release/真实会话使用 Keychain；仅显式的 Debug Mac Catalyst 临时 UI 验证可使用内存会话。

不要用 iOS 编译成功证明 HTTP/WSS、真机、通知、交易或 TestFlight 已通过。模拟器登录测试需保留 `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`，否则 Keychain 相关验证可能失真。

## 13. 鸿蒙客户端

工程：`frontend/harmony-app/`。

ArkTS/ArkUI 客户端复用整合后端认证、行情、业务 HTTP、命令和鉴权 WSS，不复制交易引擎。当前已完成窗口/认证、导航/自选行情、13 周期图表/指标参数和嵌入式开仓票据等前三批工作，并在 Mate 80 上做过签名安装和离线替身检查。

后续持仓、账户、真实 HTTP/WSS、双指缩放、性能长稳、系统浮窗和通知仍需按 `docs/harmony-client.md` 与复刻计划逐项验收。签名安装通过不等于真实账户或实盘通过。

## 14. 通知和外部集成

通知使用“事件入库 + 独立投递记录 + 渠道投递”模型。交易成功路径不能等待 APNs、Echobell、SMTP 或第三方接口返回成功。

- 普通信号走 App APNs；浮盈/保证金提醒可走 Echobell 独立通道。
- APNs `.p8` 只读挂载到 scheduler；设备 token 按用户注册/注销。
- 外部交易信号接收、普通外部通知、SMTP、Live Activity 和真实自然触发各有独立开关。
- 测试通知必须使用测试账号/测试 token，并区分苹果接受、设备收到、前台导航和冷启动点击。
- 配置一个通道时不要顺手打开另一个通道；按 `docs/signals-and-notifications.md` 的开关和验收边界执行。

## 15. 配置清单

配置模板：`deploy/integrated/server.env.example`。

### 15.1 基础生产配置

- `INTEGRATED_RELEASE`：当前 release 内容修订。
- `SECRET_KEY`、`AES_SECRET_KEY`：独立随机值。
- `DEBUG=False`、`ALLOWED_HOSTS`、`PUBLIC_APP_URL`。
- `DB_ENGINE=mysql`、数据库主机/用户/密码及 MySQL root 密码。
- `USE_REDIS_CACHE=True`、`REDIS_URL`、`MARKET_REDIS_URL`。
- `MARKET_WS_URL`、`ACCOUNT_WS_URL`、WSS 预算和连接间隔。
- `RUN_SCHEDULER_IN_WEB=False`、`LEAD_TRADING_ENABLED=false`。

### 15.2 认证和通知配置

- refresh cookie 名称、路径、Secure/CSRF/Session 安全开关。
- APNs team/key/bundle ID 和受限密钥目录。
- `TRADE_NOTIFICATION_ENABLED`、`APNS_ENABLED`、`LIVE_ACTIVITIES_ENABLED`。
- `POSITION_PROFIT_CALL_ENABLED`、`POSITION_MARGIN_CALL_ENABLED` 和 Echo URL。
- 外部信号/交易开关必须按当前运维授权保持关闭或单独验收。

### 15.3 计划页和 OSS 配置

见本手册第 11 节。模板为空时保持关闭；不要把生产 `server.env` 复制到仓库或交接消息。

## 16. 本地开发准备

后端推荐 Python 3.11，使用隔离虚拟环境：

```bash
cd /Users/apple/work/TradeTools-Binance-iOS
python3.11 -m venv server/.venv
server/.venv/bin/pip install -r server/requirements.txt
cp deploy/integrated/server.env.example server/.env  # 仅本地忽略文件，按需填写替身值
```

本地只做 Django/SQLite 逻辑检查时，使用明确的隔离开关，不连接生产：

```bash
DEBUG=true \
DB_ENGINE=sqlite3 \
USE_REDIS_CACHE=False \
RUN_SCHEDULER_IN_WEB=false \
server/.venv/bin/python server/manage.py check

DEBUG=true \
DB_ENGINE=sqlite3 \
server/.venv/bin/python server/manage.py makemigrations --check --dry-run

DEBUG=true \
DB_ENGINE=sqlite3 \
server/.venv/bin/python server/manage.py test experiences common --verbosity 1
```

如果测试涉及跨进程 Redis、唯一约束、锁或行情预算，必须使用隔离 MySQL/Redis。`MARKET_TEST_REDIS_BINARY=/abs/path/redis-server` 缺失时条件跳过只能说明测试环境不具备，不应写成“Redis 回归通过”。

前端静态语法检查：

```bash
node --check frontend/trade-plan-web/app.js
```

## 17. 验证矩阵

每次修改先选择与风险匹配的验证范围，并在主题文档中写清“通过/跳过/未验”：

| 改动 | 最低验证 | 不能由此推出 |
| --- | --- | --- |
| 经验模型/接口 | `check`、migration drift、`experiences common` 测试、用户隔离和 401/404 | OSS 实际上传、生产容量 |
| 计划页 UI | `node --check`、页签/弹窗/粘贴/拖放/5 张上限/刷新回退、控制台错误 | 云端同步、实机交易 |
| OSS 配置 | 未配置 503、签名字段、CORS、测试 Bucket PUT/GET、过期和超限 | 真实用户长期可用性、CDN 缓存正确性 |
| 交易/命令 | 隔离 MySQL+Redis、幂等、lease/fence、UNKNOWN 和保护回归 | 真实开平仓安全 |
| 行情 | Redis 条件测试、API/WSS 主题、分页/补线/收线完整性 | 所有网络的延迟和长稳 |
| iOS | scheme 编译、XCTest、模拟器 UI、必要时真机 | TestFlight 分发、所有设备、实盘 |
| Harmony | HAP 构建/签名、HTTP/WSS、真机帧耗时/长稳 | iOS 功能全部等价 |
| 发布 | migration、health、容器、HTTPS、auth、WSS、页面标记 | 历史数据完整、交易所写操作安全 |

已有测试数量和日期见 `docs/development.md`、`docs/changes.md`。不要为了让报告好看而把“条件跳过”改写成通过。

## 18. 发布流程

### 18.1 发布前

1. 确认工作区和分支，阅读本次改动对应主题文档。
2. 检查 `git status`，识别其他会话改动；用户要求全量交付时必须保留并纳入。
3. 运行适用的后端、前端和客户端测试。
4. 检查 migration 是否已生成且可逆性/兼容性清楚。
5. `git diff --check`，确认新增文档/脚本安全，确认无凭证和构建产物。
6. 用户明确要求推送/部署后，提交全量整合工作区，记录 commit。

### 18.2 服务器发布

服务器：**47.80.22.243（首尔服务器）**。关键路径：

```text
/opt/trade-tools-integrated/server.env       # 受限生产环境
/opt/trade-tools-integrated/releases/<name>  # 版本目录
/opt/trade-tools-integrated/current           # 当前版本软链接
/opt/trade-tools-integrated/backups/<name>    # 数据库/回滚资料
/opt/trade-tools-integrated/web/<name>        # 交易计划静态页
```

典型发布脚本是 release 目录内的 `deploy/integrated/release.sh`，核心动作包括：

```bash
docker compose --project-name tradetools-integrated \
  --env-file /opt/trade-tools-integrated/server.env \
  -f <release>/compose.integrated.yaml --profile pro build api

docker compose ... up -d --wait mysql redis
docker compose ... run --rm --no-deps api python manage.py migrate --noinput
docker compose ... run --rm --no-deps api python manage.py bootstrap_mobile
docker compose ... up -d --no-build api market worker scheduler
```

正式执行前：

- 先备份数据库并记录备份大小、哈希和位置；
- 核对 migration 与旧版本兼容，必要时先扩展字段再切换代码；
- 不使用 `docker volume prune`；
- 不在生产命令中运行会调用交易所写接口的测试；
- Nginx 改动先 `nginx -t`，通过后再 reload；
- 静态页面采用新目录上传后原子切换，保留上一版目录以便回退；
- 不因静态页面更新而重启 MySQL/Redis/交易服务。

### 18.3 发布后

至少验证：

```bash
curl --fail https://47.80.22.243/integrated/v1/health
docker compose ... --profile pro ps
curl --fail https://47.80.22.243/plan/
```

再按改动范围检查登录/refresh、认证失败、经验 API 401/CRUD、页面关键标记、WSS ready/ack/ping/pong、market ticker/历史、scheduler/worker 状态。健康检查为 true 只能证明数据库、migration 和 scheduler 基本可用，不证明历史补全、通知自然触发、OSS 实际 PUT 或真实交易。

### 18.4 回滚

- 回滚优先切回兼容的应用 release/镜像和 `current` 软链接。
- 代码回滚通常不反迁移数据库，不恢复数据库，不重放交易命令。
- 只有在明确的灾难恢复方案、备份完整性和数据丢失边界都确认后，才讨论数据库恢复。
- API、market 和客户端协议必须成对回滚，不能只回滚某一层。
- 回滚后再次验证 health、auth、WSS、行情和 worker/scheduler；保留证据。
- 不因页面样式问题回滚交易后端，不因交易异常直接删除数据库表。

## 19. 常见故障排查

### 页面打开但经验为空

1. 看浏览器 console 是否有 JS 错误。
2. 看 `localStorage` 是否被清理、页面是否换了 origin。
3. 如果页面配置了 API，检查 access token、`/integrated/v1/experience/list` 的 HTTP 状态和响应结构。
4. 确认当前用户是否与创建经验的用户相同。
5. 不要先改数据库；先区分 localStorage 模式和后端同步模式。

### 上传按钮失败

- 503：服务器没有完整 `OSS_ENDPOINT`、`OSS_BUCKET`、`OSS_ACCESS_KEY_ID`、`OSS_ACCESS_KEY_SECRET`，这是当前线上预期状态。
- 401：页面没有有效 Bearer token。
- 400：文件类型、大小或请求字段不符合接口约束。
- 浏览器 CORS 错误：检查 Bucket CORS 的来源、方法、请求头和 HTTPS。
- PUT 成功但图片打不开：检查 Bucket 读策略、`OSS_PUBLIC_BASE_URL`、CDN 域名和对象 key。
- 不要把完整签名 URL 或 Secret 贴到日志/聊天；URL 过期后重新申请即可。

### 容器 healthy 但行情不动

检查顺序：

1. market 日志是否有 Binance 连接/预算错误；
2. Redis ping、主题 sequence 和 Pub/Sub 是否更新；
3. MySQL 收盘线和补全任务是否有新增；
4. API 是否共享接收并向 WSS 投递；
5. 客户端 token、模式头和主题协商是否正确。

不要只看 api health。`market_stream` 的冷补、出口限速、Binance 保留窗和数据库 I/O 可能独立异常。

### 命令卡住或 UNKNOWN

不要点击“重试”或手动补发。按第 8 节流程使用原订单号和同绑定代际只读核对；查询失败继续 UNKNOWN，并阻止新增风险。先确认 lease/fence、worker 是否运行、Binance 查询是否限频，再决定是否需要代码修复。

### 发布后迁移失败

- 先停止进一步切换，不删除数据卷。
- 读取 Django migration 具体错误和数据库备份状态。
- 判断是代码/依赖/环境错误还是 schema 不兼容。
- 如果旧 release 仍兼容，切回旧应用版本；不要未经评估反迁移。
- 将错误、已执行 SQL/迁移、回滚动作和剩余风险写入 `docs/operations.md`。

## 20. 当前已知限制和待验收项

以下内容不能在交接时写成“已完成”：

- 真实开仓、平仓、划转、撤保护单和策略修改未作为本次常规验收；
- 带单真实组合 Key、新增风险和实盘结果待受控验收，当前新增风险开关关闭；
- 47.80.22.243（首尔服务器）的真实 OSS Bucket、RAM 权限、CORS、PUT/GET、私有读策略和长期 CDN 行为尚未验收；
- 交易计划 Web 的后端经验 API 已实现，但页面默认 localStorage，不能自动假设云端同步已经打开；
- 完整 iPhone 实机、不同设备尺寸、TestFlight 最新构建映射和性能长稳仍需按主题文档验收；
- Harmony 真实 HTTP/WSS、长稳、后续持仓/账户页面、系统浮窗和通知仍有待验；
- APNs/Echobell 的自然触发、冷启动导航、SMTP 和 Universal Links 不能由一次手工通知推断；
- 行情历史补全受 Binance 预算、出口网络和保留窗口影响，不保证瞬间填满；
- `market_stream` 历史表的清理查询和 MySQL 长期容量需要持续观察/优化；
- Redis/MySQL 多用户压力、生产 WAF、全局限流、后台保护和补丁状态仍需独立安全审查；
- 历史强平 `INSURANCE_CLEAR` 尚未纳入完整净盈亏口径；
- 本机代理、蜂窝/公网丢包和偶发长尾延迟不能用短样本承诺稳定性。

最新具体状态仍以 `docs/known-issues.md`、`docs/changes.md` 和 `docs/operations.md` 的日期记录为准。

## 21. 新 Agent 接手 checklist

### 开始前

- [ ] 当前路径是 `/Users/apple/work/TradeTools-Binance-iOS`，不是来源项目。
- [ ] 已阅读 `AGENTS.md`、`docs/README.md`、`INTEGRATION.md`、`architecture.md`、`development.md`、`operations.md`、`configuration.md`。
- [ ] 已读取本次任务涉及的交易/资金/行情/通知/客户端主题文档。
- [ ] 已运行 `git status --short --branch` 并记录其他会话改动。
- [ ] 已区分当前实现、历史部署、待实现和待验收。
- [ ] 已确认是否拥有“推送”或“部署”授权；没有就只做本地修改和验证。

### 修改中

- [ ] 新逻辑放在正确的业务域，交易经验/计划图片不混入交易执行链路。
- [ ] 新数据变更使用 Django migration，不手改生产表。
- [ ] 金额/数量仍使用 Decimal；用户/模式/绑定代际隔离保持不变。
- [ ] 新接口有认证、用户隔离、输入长度和 URL/图片大小验证。
- [ ] 外部调用失败不会让交易成功路径回滚或重复写入。
- [ ] OSS/通知/QA 凭证只从受限环境读取。
- [ ] 相关主题主文档同步更新，而不是只写临时聊天说明。

### 修改后本地验证

- [ ] `node --check frontend/trade-plan-web/app.js`（如改 Web）。
- [ ] `manage.py check`。
- [ ] `manage.py makemigrations --check --dry-run`。
- [ ] 与改动相关的 Django tests；Redis/MySQL 相关测试使用隔离真实依赖。
- [ ] iOS/Harmony 按改动选择 scheme、签名和真机/模拟器范围。
- [ ] `git diff --check`。
- [ ] `git status --short`，确认新增文件、忽略文件和凭证状态。

### 发布后（仅用户明确授权时）

- [ ] 记录 commit、release 目录、数据库备份大小/哈希和 migration。
- [ ] 在 **47.80.22.243（首尔服务器）** 先做 health、容器和只读状态检查。
- [ ] 迁移兼容性已评估；不使用 volume prune，不执行真实交易测试。
- [ ] API/market/worker/scheduler 同源切换，Nginx 改动先 `nginx -t`。
- [ ] 验证 health、auth、WSS、行情、经验接口和 `/plan/` 页面。
- [ ] 若启用 OSS，额外验证测试账号的签名 PUT、读取、CORS、超限和日志脱敏。
- [ ] 准备并记录兼容 release 回滚方案。
- [ ] 更新 `docs/operations.md`、`docs/changes.md` 和相关主题文档。

## 22. 术语表

| 术语 | 含义 |
| --- | --- |
| binding generation | 账户绑定代际；旧绑定的 worker/结果不能写入新绑定 |
| lease | Redis 中短期账户执行租约，控制 worker 所有权 |
| DB fence | 数据库围栏，阻止失去租约的旧执行者继续写入 |
| UNKNOWN | 本地无法证明最终结果的命令状态；必须只读核对，不能盲目重发 |
| protection | 止损/保护单及其恢复状态，必须先新后旧 |
| source of truth | 某类事实的权威来源，例如数据库订单事实、交易所订单号、Redis sequence |
| OSS signed PUT | 后端签名、浏览器直传阿里云 OSS 的短期 PUT URL |
| Data URL fallback | OSS 关闭/不可用时，浏览器将图片编码为 Data URL 存在本地记录中 |
| integrated release | 整合项目同源后端/部署版本，API、market、worker、scheduler 应成套切换 |
| health | 进程/数据库/migration/scheduler 的基本存活检查，不等同业务全链路验收 |

## 23. 文档维护原则

- 架构/协议写入 `INTEGRATION.md` 和 `architecture.md`；配置写入 `configuration.md`；验证写入 `development.md`；发布事实写入 `operations.md`；日期结果写入 `changes.md`。
- 每次完成任务都评估是否需要更新本手册，尤其是入口、目录、部署路径、OSS 状态和接手 checklist。
- 明确区分“已实现”“已部署”“已验证”“待验收”。编译通过不等于实机通过，模拟器通过不等于真实交易通过，健康检查通过不等于 OSS/行情补全/通知自然触发通过。
- 文档中只放非敏感配置名、路径和操作原则；不要放密码、token、Secret、完整签名 URL 或真实用户资料。
- 删除旧路径、旧端口或旧状态前，先确认 `docs/operations.md` 是否仍需要作为历史证据保留。
- 任何新 Agent 都应能只靠本项目文件复现：从哪里开始读、改哪一层、如何测试、如何发布、如何回滚，以及哪些动作绝不能擅自执行。
