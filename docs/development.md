# 开发与验证

> 整合版说明（2026-10-31）：本文保留来源系统的业务或实现资料。当前运行入口、服务器、原生页面与验证边界以 [整合说明](INTEGRATION.md)、[运维](operations.md) 和 [变更](changes.md) 为准；Java 模块仅作参考。


## 本地环境

使用 Python 3.11、Node.js 20，与 `docker/server/Dockerfile`（来源路径，未随本整合交付） 和 `docker/frontend/Dockerfile`（来源路径，未随本整合交付） 对齐。前端以 `package-lock.json` 为锁文件，安装使用 `npm ci`；不要另生成 pnpm / yarn 锁文件。

后端在 `server/` 下执行：

```bash
python3.11 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
```

已有虚拟环境无需重建。本地配置参考 [配置字典](configuration.md) 和 [server/.env.example](../server/.env.example)，使用独立开发密钥，不复制生产账户凭证。SQLite 仅用于本地功能和单元测试，不证明 MySQL 并发、锁和迁移行为等价。

如果现有 `.venv/bin/python` 报 `Library not loaded`，先检查其原解释器是否已被移动或移除，不用系统中另一版本 Django 的结果代替项目验收。确认仅为可重建的开发环境后再按锁定依赖重建，保留本地 `.env` 与数据库；不要把虚拟环境目录复制到另一台机器当作安装方式。

以下命令只针对本地数据库；执行前确认当前目录和环境，不在生产服务器照抄：

```bash
DB_ENGINE=sqlite USE_REDIS_CACHE=False RUN_SCHEDULER_IN_WEB=false .venv/bin/python manage.py migrate
DB_ENGINE=sqlite USE_REDIS_CACHE=False RUN_SCHEDULER_IN_WEB=false DEBUG=True AUTH_REFRESH_COOKIE_SECURE=False .venv/bin/python manage.py runserver 127.0.0.1:8000
```

前端在 `tools/` 下执行：

```bash
npm ci
npm run dev -- --host 127.0.0.1
```

默认 [本地前端](http://127.0.0.1:5173)；端口被占用时另选端口并报告实际地址，不终止其他任务的服务。

当前开发配置使用 `VITE_API_BASE_URL=/api`；Vite 将 `/api` 改写为 `/v1`，同时保留 `/v1` 代理。`DEV_API_PROXY_TARGET` 默认指向 `http://127.0.0.1:8000`，可由 shell 环境覆盖。

代理目标通常保持本地，不为解决开发跨域自动改连生产；真实账户和写接口边界仍适用。后续代理任务完成后更新此段状态。

本地深度健康在未启动 Redis / scheduler 时可能为 503，这是心跳检查的预期结果。不要为了让它变绿而接入真实账户启动交易后台。

## 编码约定

- 前端沿用 `src/pages` 页面、`shared/lib` 服务与纯逻辑、`shared/store` 状态、`components` 公共控件；`@/` 指向 `src`。网络访问统一经现有 API client，避免自行复制鉴权刷新。
- 页面采用现有按需加载边界。K 线生命周期、请求取消、缓存和更新节流集中在既有行情模块；不要在账户页面再造行情客户端。
- 后端沿用 DRF 视图和现有响应封装，权限和用户归属校验不能靠前端；已存在服务负责状态转换，模型迁移负责结构变更。
- 金额、数量、费用用 Decimal 和交易所步长规则；区分委托价、真实成交价、标记价与估算价格。时间保存与运算使用带时区值，展示默认北京时间。
- 所有交易所请求有超时、错误分类和可追踪标识。写请求超时意味着结果未知，不等于失败，必须按身份对账后决定后续动作。
- 通知采用独立事件与投递模块，发送异常不能改变主交易结果；添加渠道要有开关、幂等、重试边界和移除说明。
- 数据缓存明确身份、键、TTL、失效时机；账户数据不进入 CDN、公用本地存储或跨用户缓存。内存快照也要隔离用户和异步代际。
- 不进行无关重构。修复后的旧分支、废弃格式化函数和多余参数应在确认无调用后清理，避免保留两套规则。

## 认证与凭证边界

Access token 默认 15 分钟，仅驻留浏览器内存；refresh 默认 14 天，使用 HttpOnly、SameSite=Lax cookie，生产 Secure，并轮换 / 黑名单处理。并发 401 统一复用刷新请求，不能各接口独立刷新制造竞态。不要恢复旧 localStorage token 持久化流程。

密码哈希与 API 凭证加密分开，主密钥管理见 [配置字典](configuration.md)。公开行情 localStorage 缓存不包含账户资料，不能由此推导财务数据也可以持久化在浏览器。

## 验证命令

前端命令在 `tools/` 中执行：

```bash
npm test
npm run build
npm run lint
npm run typecheck
npm audit --audit-level=moderate
```

`build` 包含 TypeScript 构建检查。已有 lint / 测试失败应区分既有问题与本次引入，不宣称未运行的检查通过。

后端命令在 `server/` 中执行，确保外部服务均被测试替身隔离：

```bash
DB_ENGINE=sqlite USE_REDIS_CACHE=False RUN_SCHEDULER_IN_WEB=false .venv/bin/python manage.py check
DB_ENGINE=sqlite USE_REDIS_CACHE=False RUN_SCHEDULER_IN_WEB=false .venv/bin/python manage.py makemigrations --check --dry-run
DB_ENGINE=sqlite USE_REDIS_CACHE=False RUN_SCHEDULER_IN_WEB=false .venv/bin/python manage.py test
```

仓库根目录的独立检查：

```bash
python3 -m unittest discover -s docker/tradingview -p 'test_*.py'
bash deploy/test-deploy-state.sh
git diff --check
```

需要验证生产数据库 / 缓存并发契约时，只使用仓库提供的隔离 Compose；它使用临时 MySQL / Redis 和测试专用占位密钥，不读取 `.env.docker`，也不启动 scheduler：

```bash
docker compose -f docker-compose.integration.yml up --build --abort-on-container-exit --exit-code-from test-runner
docker compose -f docker-compose.integration.yml down --volumes
```

执行前仍需检查 Compose 渲染结果没有意外引用生产环境文件。开发机没有 Docker；2026-09-11 已在授权服务器使用独立 internal 网络和有资源上限的临时容器实际通过 9 项隔离 MySQL / Redis 测试。只挂载不含环境文件的测试源码、使用占位密钥，没有连接生产 DB / Redis 或启动 scheduler，测试资源随后已移除。覆盖活动资金槽位、幂等、通知置信度并发、双模式绑定、旧 ORM 写入新结构、线程 / 跨进程锁与跨进程带单预算；SQLite 回归仍不能替代此项。

2026-09-11 底座收敛的本地验证使用从 `server/requirements.txt` 严格安装的临时环境 `/tmp/tradetools-codex-venv`，因为仓库 `.venv` 仍引用已缺失的 Python 3.9 动态库。最终 Django 全量发现 597 项、执行 592 项并通过，1 项按隔离环境要求跳过；前端全量 68 项、webhook 28 项通过，lint、TypeScript、生产构建、Django check、迁移漂移、Python 编译、Ruff 基础静态检查、Bandit High、部署状态脚本、npm audit、pip-audit 及差异检查通过。临时环境仅是本次验证记录，不应写入脚本或视为仓库 `.venv` 已修复。

## 风险与测试矩阵

2026-09-30 手动仓保护新增验证：本机继续使用按 `server/requirements.txt` 安装的临时 Python 3.11 环境，未修改失效的仓库 `.venv`、环境文件或开发数据库。`trading.test_external_positions` / `trading.test_external_discovery` / `trading.test_external_scheduler` / `positions.test_external_api` / `common.test_external_protection` 覆盖金额精度、来源发现、模式隔离、撤单恢复、MARK_PRICE、未知提交、部分平仓、重开及真实适配器契约；仅模拟交易写操作。0027 与活动槽位在隔离 MySQL / Redis 下验证；最终实际数量和线上状态见 [变更记录](changes.md)。

| 改动范围 | 最少应覆盖 |
| --- | --- |
| K 线 | `KlineChartCard.test.tsx`、`binanceKlineStream.test.ts`、`klineSnapshotCache.test.ts`；`trading.test_public_market_klines`；桌面和手机切换周期、非空图像、失联兜底 |
| 转账历史 | `accounts.tests`、`accounts.test_transfer_history_cache`、`accounts.test_external_deposits`、`accounts.test_pay_history`、`common.test_deposit_history`、`common.test_pay_history`；充值与 Pay 收支、真实适配器到刷新 API、满页完整性、来源升级补查、首屏只读库、刷新失败保留旧数据、Key 变更隔离；同步版本迁移兼容见 `integration_tests.test_transfer_history_migration`，UID 预算真实 Redis 跨进程隔离见 `integration_tests.test_pay_budget` |
| 交易操作日志 | `accounts.test_operation_logs`、`trading.test_web_operation_logs`、`trading.test_external_operation_logs`、前端 operation-logs / profile 入口；身份隔离、确认语义、分页、失败不阻断交易、脱敏和定时刷新停止；MySQL 契约见 `integration_tests.test_operation_logs` |
| 信号 / 通知 | `trading.test_signals`、`positions.test_notifications`、webhook 单测；去重、五类字段、发送失败和开关 |
| 开仓 / 保护 / 资金 | `trading.tests`、`trading.test_balance_cap`、`positions.tests`；重复请求、部分成交、未知结果、保护恢复、精度、两笔风险敞口边界 |
| 认证 / 公共缓存 | `users.tests`、`api_bindings.tests`、前端 `client.test.ts`；401 并发刷新、cookie、用户隔离、私有响应不缓存 |
| 前端版本 / PWA | `serviceWorker.test.ts`、下述浏览器跨版本升级回归；保留旧缓存、普通导航获取新 HTML、后台更新不强刷操作页面 |
| 研究 | `signal_research.tests`、`market_analysis.tests`；权限、闭合 K 线、不可变发布和未来数据隔离 |
| 数据库 / 调度 | SQLite 单测之外，在隔离 MySQL / Redis 环境验证迁移、唯一约束和多进程锁；不能用线上资金验收 |
| 部署 / Nginx | 部署状态脚本测试、对应环境的配置语法和健康、真实路径 / TLS / WS 消息验证 |
| 纯文档 | 链接与源码路径、过期引用、密钥扫描、历史迁移映射、差异检查；无须触发生产重建 |

2026-09-30 全仓审阅修复新增入口：`positions.test_review_fixes`（金额完整性、历史窗口、摘要和维护资格），`trading.test_incomplete_fills` / `trading.test_close_direction`（成交证据和方向），`trading.test_scheduler_connections` / `trading.test_strategy_loading`（后台边界和查询次数），`signal_research.test_safety` 及隔离 `integration_tests.test_research_publication`。均使用交易所替身；MySQL 并发测试只在测试专用容器运行。最终数量及未发布状态见 [修复验证](known-issues.md#修复验证与剩余范围)。

线上模板发送、手动历史同步都不是纯只读操作，分别会向外发消息、或请求交易所并写数据库。需要符合当前任务授权；模板不会真实交易，但不能未经要求刷屏。

## 交易页手续费开关布局回归

修改「止损含手续费」开关布局时，在 `tools/` 使用 [浏览器布局回归脚本](../tools/scripts/test-stop-loss-fee-switch.cjs)：

```bash
NODE_PATH=/path/to/runtime/node_modules node scripts/test-stop-loss-fee-switch.cjs
```

脚本自行启动并关闭独立 localhost Vite 服务，全部 API 使用占位数据并阻断外部请求，无需登录真实账户。需要外部运行时提供 Playwright，默认使用 macOS Google Chrome，可通过 `CHROME_EXECUTABLE` 指定路径；已安装 Playwright WebKit 时可设 `SWITCH_BROWSER=webkit`。覆盖 320 / 390 / 1280px、深浅主题及关闭 → 开启 → 关闭，等待实际动画结束后测量圆点和轨道，检查两端 2px 边距、垂直居中、轨道不被压缩及圆点不越界。jsdom 不执行真实布局，不能用 CSS 类名断言替代此项。

## 浏览器跨版本升级回归

修改 worker 或注册方式前，保留旧版生产构建 `dist` 到独立临时目录；不能只在无缓存的新浏览器中验收。构建新版本后，在 `tools/` 使用 [升级脚本](../tools/scripts/test-service-worker-upgrade.cjs)：

```bash
NODE_PATH=/path/to/runtime/node_modules node scripts/test-service-worker-upgrade.cjs /path/to/previous-dist
SW_BROWSER=webkit NODE_PATH=/path/to/runtime/node_modules node scripts/test-service-worker-upgrade.cjs /path/to/previous-dist
```

外部测试运行时须有 Playwright 及对应 WebKit 浏览器；Chromium 默认使用 macOS Google Chrome，可通过 `CHROME_EXECUTABLE` 指定路径。不为运行此脚本改项目依赖或锁文件。旧构建须含完整 worker / precache 资源，第二个位置参数可指定新构建目录，默认 `dist`。

脚本使用 localhost 服务、模拟账户接口、占位登录信息和限制同源的 CSP；使用独立普通浏览器配置目录，退出后删除该测试目录。保留缓存经历真实旧版 -> 新版升级，阻断非首屏策略页资源，并验证普通打开、后续 HTML 单独发布、旧 chunk 兼容、Cookie / localStorage / sessionStorage 保留和当前文档不被新客户端的 worker 更新强刷。不可调用恢复入口或清缓存来让升级测试通过。WebKit 自动化采用普通持久存储环境，不把隐私会话缓存行为当作普通 Safari 的证据，也不等同于用户 iPhone 实机验收。

## 完成标准

说明修改内容、实际验证结果、未验证范围、已知风险和提交 / 部署状态。按 [文档维护规范](maintenance.md) 主动更新需要长期保留的结论。不要将 HTTP 200、编译通过或单次截图等同于整个交易系统已全面验收。
