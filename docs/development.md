# 开发与验证

当前工程入口见 [README](../README.md)，配置见 [配置字典](configuration.md)。以下命令在本整合目录执行。

## Python

使用 Python 3.11，按锁定依赖创建本地环境：

```bash
python3.11 -m venv server/.venv
server/.venv/bin/python -m pip install -r server/requirements.txt
cp server/.env.example server/.env
```

开发配置使用 SQLite、独立 Redis 和无交易绑定账号。HTTP / WSS 由 ASGI 运行：

```bash
cd server
.venv/bin/python manage.py migrate
.venv/bin/python -m uvicorn riskon.asgi:application --host 127.0.0.1 --port 8787
```

行情、命令和调度分别运行 `manage.py market_stream`、`mobile_worker`、`run_scheduler`；测试期间不启动实际账户维护进程。只有需要完整本地链路时，才配置独立 Redis 并分别启动。

不读取本地真实 `.env` 的基础验证：

```bash
cd server
export PYTHON_DOTENV_DISABLED=1 DB_ENGINE=sqlite USE_REDIS_CACHE=False RUN_SCHEDULER_IN_WEB=false
.venv/bin/python manage.py check
.venv/bin/python manage.py makemigrations --check --dry-run
.venv/bin/python manage.py test
```

SQLite / LocMem 不能替代 MySQL 事务、唯一约束及 Redis 跨进程验收。相关测试位于 `server/integration_tests/`，使用测试专用数据库和 Redis；不得指向生产环境。普通回归使用交易所替身，不实际开平仓、划转或撤保护单。

## iOS

打开 `frontend/ios-app/TradeTool.xcodeproj`。保留的 Scheme 为 `TradeTool`、`TradeTool Seoul`、`TradeTool Release`、`TradeTool Chart Calibration`；Debug / Debug-Seoul / Release 默认均指向整合服务器。本地开发入口可在 App 服务器设置中选择，手机的 `127.0.0.1` 指手机自身。

```bash
xcodebuild -project frontend/ios-app/TradeTool.xcodeproj -scheme TradeTool   -configuration Debug-Seoul -destination 'platform=iOS Simulator,name=iPhone 18 Pro'   -derivedDataPath .integration-runtime/DerivedData   CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

本机 Xcode 27.2 的模拟器窗口从 `Xcode → Open Developer Tool → Device Hub` 打开；本轮专用设备名为 `TradeTools Integrated`（iPhone 18 Pro / iOS 27.2）。完成验证后保留该设备的已登录行情页面，方便继续查看。

模拟器 Keychain 测试保留临时签名与 simulated entitlements。发布构建及 TestFlight 使用有效 Apple 团队签名，见 [手机发布指南](testflight.md)。

Xcode Cloud 的 Test action 选 `TradeTool`（包含单测），Archive action 选 `TradeTool Release`（Release）；后者的 TestAction 无测试列表。工程旁的 `ci_scripts/ci_pre_xcodebuild.sh` 自动检查 Metal Toolchain 并按需下载，可用以下替身测试检查安装、已安装、并发导入及持续失败分支，不访问 Apple 或交易所：

```bash
sh frontend/ios-app/ci_scripts/tests/ci_pre_xcodebuild_test.sh "$PWD/frontend/ios-app/ci_scripts/ci_pre_xcodebuild.sh"
```

Cloud 分发使用平台自动递增的构建号，首次在后台核对 Next Build Number；不在脚本里修改版本或提交回 Git。隐私清单已加入主 App 资源。云端签名、上传、Apple 处理和手机安装仍要分别验收，具体工作流设置见 [TestFlight 指南](testflight.md#xcode-cloud自动构建与-testflight-分发)。

图表压力测试在 Cloud 继续检查呈现覆盖、帧并发、缓冲区拒绝与命令错误，并保留 4Hz / 20Hz 的 P95 报告；共享云端模拟器不使用本地 150ms 呈现耗时阈值作为分发条件。仅在 Apple 提供的 `CI_XCODE_CLOUD=TRUE` 测试环境记录该耗时，本地模拟器仍执行原阈值；实机性能仍由前台 Debug harness 单独验证。Apple 会把 Cloud 环境变量传入测试进程，见[环境变量文档](https://developer.apple.com/documentation/xcode/environment-variable-reference)。

`IntegratedNativeUITests.testConfiguredLoginMarketAndBusinessPages` 为 opt-in 的登录 / 页面检查。测试进程读取 `INTEGRATION_QA_ACCOUNT`、`INTEGRATION_QA_PASSWORD`、`INTEGRATION_QA_API_BASE`，默认账号 / API 为本地隔离环境；兼容旧 `INTEGRATION_LOCAL_QA_PASSWORD`，缺少密码时跳过。通过 xcodebuild 传入时使用 `TEST_RUNNER_` 前缀，凭证从受限文件读取并避免日志泄露。远程验证使用专用无绑定 QA 账号，目标明确为 47.80.22.243（首尔服务器）；不能误用有资金权限的账号。

测试覆盖真实 BTC 列表、图表加载、持仓、无绑定开仓禁用、信号、我的和 API 表单；若启动时已有会话，先通过页面退出，再执行新登录，避免只测到会话恢复。进入图表前等待系统保存密码按钮消失及行情行可点击，避免在系统弹窗退场时误点。其他 UI 校准脚本和 Debug harness 用于行情 / Metal，不把离屏测试当作真机帧率或长稳结果。实际结果见 [变更](changes.md)。

业务页面的原 Web 对照、DEBUG 隔离数据和 `WebParityUITests` 命令见 [Web 原生复刻](ios-web-parity.md)。该模式无需账号，不连接真实交易；只有本地资金预检和 EMA 预览返回静态响应。Release 不包含该入口。

认证页现采用 USDC 原生布局和底部 sheet；显示名、图标、已有接口及注册开关替身见 [品牌与认证](ios-authentication.md)。认证 UI 测试只提交本地验证失败的表单，后端协议用 SQLite / LocMem 的 `users.tests.AuthApiTests` 和 `mobile.tests.MobileAuthTests` 验证，重置邮件使用 locmem。

`TradeToolTests/NetworkLatencyAndModalTests` 覆盖 WSS RTT 匹配、中位数、超时重置、颜色阈值、大小弹窗动画及编译后启动 storyboard 的 96 pt 尺寸和资源透明圆角。相关 UI 回归入口为 `WebParityUITests.testMarketLatencySignalAndInternalOnlyHeader`、`testCollectionButtonAndSmallConfirmationCanReopen` 及认证面板流程。

修改发布图标后，在 macOS 重新生成启动专用连续圆角资源，再构建并检查冷启动（保留工程发布版本号，缓存排查见品牌文档）：

```bash
swift frontend/ios-app/scripts/render_launch_mark.swift \
  frontend/ios-app/TradeTool/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png \
  frontend/ios-app/TradeTool/Resources/Assets.xcassets/LaunchBrandMark.imageset
```

持仓浮窗的数据生命周期、单测、两项 App 内与一项跨 App UI 测试见 [持仓浮窗](ios-floating-positions.md)。视觉模式使用独立 UserDefaults suite，每次启动重置开关和位置；普通运行的浮窗偏好保持不变。App 内测试显式传 `--fixture-inline-floating`；跨 App 测试使用系统 AVKit，仅在明确不支持时跳过，不能把跳过当作画中画通过。

## 行情补全与交互回归

2026-11-01 本地补全任务测试位于 `market_stream.tests`，使用隔离 SQLite / LocMem 与公共交易所替身。覆盖快照读取不调用交易所、任务合并、过期租约恢复、失败退避、轮询不重置退避、各周期缺口、上市／保留边界、历史分页及提交后缓存版本更新。`common.tests` 补充 continuousKlines 的请求权重回归。

```bash
PYTHON_DOTENV_DISABLED=1 DB_ENGINE=sqlite USE_REDIS_CACHE=False RUN_SCHEDULER_IN_WEB=false \
  server/.venv/bin/python server/manage.py test market_stream.tests mobile.tests common.tests
```

`ChartEngineCoreTests` 增加兼容旧响应、晚到快照不回退 Socket 数据、K 线横拖让出 50 pt 返回范围及业务／行情暗色色板一致性测试。两项 `WebParityUITests` 为 `testWideSwipeReturnsFromBusinessPagesAndNestedStrategy`、`testSwipeCanCancelAndStopLossModalClosesWithoutMovingPage`，使用无网络 fixture，覆盖业务多层导航、40 pt 起手、取消手势、表格边界、指标编辑内部返回、暗色止损和按钮／拖动关闭。本轮使用独立 `Binance Navigation Review` 模拟器，避免其他本地 UI 校验干扰。

### USDC 行情关键路径回归

`market_stream.test_fast_path` 覆盖 live 无数据库依赖、慢收线不阻塞 live、并发更新保持收盘状态、缓冲上限、主题路由、历史／统计任务隔离、共享窗口、上市边界与分钟部分桶。协议测试可指定本机 Redis 可执行文件；测试自行选择临时回环端口并启动无持久化实例，结束后关闭，不连接已有或远程 Redis：

```bash
PYTHON_DOTENV_DISABLED=1 DB_ENGINE=sqlite USE_REDIS_CACHE=False RUN_SCHEDULER_IN_WEB=false \
  MARKET_TEST_REDIS_BINARY=/absolute/path/to/redis-server \
  server/.venv/bin/python server/manage.py test \
  market_stream.tests market_stream.test_fast_path mobile.tests common.tests --keepdb --noinput
```

真实 Redis ASGI 测试覆盖 ready 能力、订阅确认、币种／周期主题、序号、就绪事件、账户模式隔离与退订；另一项并发生产者暂停回归确保分配 sequence 与发布保持原子性，容量测试检查历史缓存只淘汰自身旧窗口、限制单窗大小、预热不挤占空间并保留模拟账户锁。未传入可执行文件时这三项跳过，不能把跳过写为协议验证通过。

iOS `MarketFastPathTests` 覆盖账户范围准备不请求业务接口、pending 分页立即合并、统计不短轮询、匹配的就绪通知、订阅确认恢复漏通知与旧后端兼容。图表无网络 UI 入口为 `TradeTool Chart Calibration` 的 `testCaptureTradeToolChartOnlyDetail`、`testCaptureTradeToolQuickSwitcherFlow` 和 `testCaptureTradeToolIndicatorSettingsShortcut`；固定 OHLC 替身用于交互与布局，不代表不同币种真实价格或链路耗时。

2026-11-01 本地 177 项后端回归（含三项独立真实 Redis）、190 项 iOS 单测通过；图表／切币切周期／指标返回三项 UI 流程分轮通过，已查看截图；generic iOS Release 未签名构建通过，具体报告见 [变更](changes.md)。MySQL 跨进程锁、生产 Redis 缓存配置、线上首屏延迟与物理手机仍待验收。新任务表及 API / market 配套升级与回滚见 [行情](market-data.md#后台自动补全与首屏读取)。

## 回归范围

- 行情延迟：`NetworkLatencyAndModalTests` 用临时回环端口的真实 WebSocket 服务与 `URLSessionWebSocketTask` 收发应用层 ping / pong，服务延迟 120 ms 后回复，验证实际 RTT、重复连接后继续采样；另覆盖匹配、超时、数值上限和弹窗动画策略。该服务不使用生产账号，UI 的固定延迟替身只检查呈现，不能替代收发链路测试。
- 行情与命令：`market_stream.tests`、`mobile.tests`，覆盖聚合、缺口、分页、鉴权、模式及绑定代际、幂等与恢复。
- 交易与资金：既有 `trading`、`positions`、`accounts`、`api_bindings` 测试覆盖精度、保护、未知结果及账户隔离。
- iOS：图表、Keychain、服务器切换和业务会话测试；设备运行单独记录。
- 提交前检查文档链接、敏感信息、`git diff --check` 和未追踪文件。实际结果写入 [变更记录](changes.md)。
