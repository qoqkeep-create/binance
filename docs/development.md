# 开发与验证

当前工程入口见 [README](../README.md)，配置见 [配置字典](configuration.md)。以下命令在本整合目录执行。

2026-11-01 用户后续授权整批提交和推送，源码交付范围见 [最新变更记录](changes.md#2026-11-01整批源码提交与-github-交付)。下文“本地／未提交”描述各批验证结束当时的状态；本次交付没有重复测试、部署或手动上传 TestFlight，真实 iPhone 性能和云端分发仍按各主题待验项处理。

2026-11-01 的绑定与延迟界面任务中，用户当时要求停止进一步测试、先部署后自行验收。“我的”绑定长按钮、点击测延迟、三点等待动画和 2 秒单在途采样已完成，`Debug-Seoul` 模拟器目标仅执行 `build`，编译通过（`.integration-runtime/profile-latency-build.log`）；未运行修改后的单测、UI 或速度回归。既有断言已同步新状态并补充慢在途样本及点击重测场景，不能据此称为本轮测试通过。服务端仅执行发布必要的迁移、容器健康、HTTPS 与一次鉴权 WSS 心跳检查，未作交易操作和完整性能验收。新客户端与 WSS 数据库连接清理改动留在本地未提交、未推送；后者已包含在本次 SSH 部署中，版本及备份见 [运维](operations.md)。

本轮按用户后续的 BTC 加载排障要求恢复定向验证：行情后端 `manage.py test market_stream` 共 41 项，38 项通过、3 项专用 Redis 验证未启用；iOS `MarketFastPathTests` 10 项加 5 项快照／epoch／翻页回归全部通过（`.integration-runtime/ChartHistoryRefreshFinal.xcresult`）。新增慢响应门闩测试先复现取消下载，再验证首个响应优先展示、通知合并、切周期和 stop 的取消边界、pending 分页；这些结果不代替全部业务 UI、Release 或手机测试。后端和公网／GPU 分段样本、旧 USDC 的逐段对照见 [行情](market-data.md#与原-usdc-实现的核对2026-11-01)，本轮客户端仍未提交／推送。

随后按首屏交接计划补验：`market_stream.tests market_stream.test_fast_path` 41 项全部通过（2.469 秒），本轮显式提供专用 Redis 二进制，三项真实回环 Redis 测试没有跳过；`MarketFastPathTests` 18 项加 `ChartEngineCoreTests` 127 项全部通过（52.965 秒，`.integration-runtime/KlineFirstFrame/CorrectnessFinal.xcresult`）。新增分页重连／恢复顺序测试均先失败后修复，包含真实 15 秒校对、真实结构 ack、下载失败及不响应取消的旧请求。上述为本地隔离测试，未执行交易操作。

2026-11-01 本轮全部源码发布前，针对当前改动补跑 `market_stream.tests market_stream.test_fast_path common.test_retired_modules users.tests` 共 69 项，8.748 秒通过，显式使用专用临时 Redis；鸿蒙核心 40 项及工程检查通过。iOS 复用上方同内容 145 项与移除探针后的 Release 构建证据，本轮没有重跑手机性能或上传 TestFlight。发布后公网冒烟与源码版本关联见 [运维](operations.md#最新发布与核验2026-11-01)，代码评估与未实施项见 [行情](market-data.md#性能与可替换性评估2026-11-01)。

2026-11-01 随后的延迟刷新与止损入场优化另作本地验证：`NetworkLatencyAndModalTests` 9 项通过（2.273 秒），包含真实回环 WebSocket 上的手动重测保留读数、匹配 pong 结束进度，以及下拉刷新保留健康连接。专用 `TradeTools Web Review` 模拟器上的两项定向 UI 最终通过，覆盖点击／下拉刷新中间状态、浅深色绑定按钮、原生止损滑杆／底部按钮位置、确认取消、关闭与系统把手下拉；测试仅使用 DEBUG 替身。generic iOS Release 未签名编译通过，入场录屏未见明显闪烁，但没有真机帧耗时或 TestFlight 结果。初次 UI 失败及最终证据见 [变更记录](changes.md#2026-11-01延迟保留读数绑定按钮配色与原生止损面板仅本地)。本轮没有提交、推送、部署或平台上传。

## K 线协调与出口保护回归

构建 13／14 速度排查新增 `HistoryFastPathTests.test_cold_first_page_does_not_materialize_unused_history`，在实际 `load_history` 冷读路径填入 3001 根并检查只物化所需 1500 根，同时核对返回窗口和非 stale 状态；修复前断言为 `3000 != 1500`。2026-11-01 使用下文临时 Redis 配置执行 `manage.py test market_stream --noinput`，58 项全部通过。这一步仅本地后端窗口减量，未部署；随后新增持久诊断，见下节。隔离源码副本上的 4 轮首帧 UI 对照和 36 个进入样本见 [行情排查](market-data.md#构建-1314-速度回退排查2026-11-01)，不能用它替代手机 TestFlight 13／14 的验收。

2026-11-01 本地实现及待发布范围见 [行情](market-data.md#读取协调与出口保护2026-11-01本地)。回归先复现同历史重建、刷新丢旧分页和首屏／恢复重复读取，再验证对象与指标复用、旧页及修订保留、取消／旧 epoch、并发快照／分页／配置一致性，以及 historyPending 等待通知。

专用模拟器 `A9B09AF9-195A-4F50-B706-7F07A0EB4CD4`、Debug-Seoul、关闭覆盖率及并行测试：`ChartEngineCoreTests` 131 项加 `MarketFastPathTests` 20 项全部通过（30.903 秒，`.integration-runtime/KlineCoordination/IOSVerified.xcresult`）。本轮未重新采样首帧、执行业务 UI 或安装手机。

后端 `market_stream.tests market_stream.test_fast_path market_stream.test_coordination common.tests mobile.tests` 共 196 项通过（8.807 秒，`KlineCoordination/backend-verified.log`），显式指定独立临时 Redis，无相关跳过。覆盖窗口合并与等待到期、缓存失联、公共 REST 共享预算失败时不出站、已知冷却任务不领取、独立 Redis 客户端共享滚动建连预算／封禁、无共享进程锁时的 owner lease、短连接退避、主动轮换与取消，以及慢发送／队列满／订阅超时／Redis／无效事件／过期／正常断开的诊断与资源清理。首轮故障测试暴露超时取消竞态，真实 Redis 测试暴露冷却 Lua 语法问题，修复后重跑通过。

调用命令与下方既有行情回归相同，只需加入 `market_stream.test_coordination`；所有交易所访问使用替身，无真实交易或生产限频试验。generic iOS Release 构建结果与最终静态检查见 [变更](changes.md)。Redis 共享接口测试不代替 MySQL 事务、真实 NAT 全流量及长稳验收。

连续纵轴适配已在本地接入：横拖／捏合／惯性按显示帧合并，单个交互场景在途，新场景保持手指基准和惯性时钟；主图／MACD 复用同一场景映射。`ChartEngineCoreTests` 新增 5 项真实 UIKit 宿主回归，包含回到起始比例时覆盖中间请求；模拟器使用 `ChartCalibrationUITests.testContinuousScalePinchPanAndCrosshairFixture` 和 `--chart-calibration-fixture`，无需账号或真实交易。离线优化基准保留 20 次预热、500 次采样及源码哈希，范围和结果见 [行情主文档](market-data.md#连续纵轴适配2026-11-01本地实现)。完整核心、UI 与 Release 的实际结果见 [变更](changes.md)；Mac／模拟器不能代替 iPhone 60／120 Hz、功耗及实时行情并发 A/B。

## 历史仓位加载回归（2026-11-01，仅本地）

`positions.test_review_fixes` 的快照回归覆盖不访问交易所、不写结算、无需补查的已结算页、重试退避、外部手动仓估算，以及日期／分页／用户／模式／Key 隔离。先运行新增两项检查复现失败，再修复；原 `positions.tests` 保留部分平仓、真实零费用、结算修复和每次最多两笔的回归。

```bash
PYTHON_DOTENV_DISABLED=1 DB_ENGINE=sqlite USE_REDIS_CACHE=False RUN_SCHEDULER_IN_WEB=false \
  server/.venv/bin/python server/manage.py test positions.test_review_fixes positions.tests --noinput
```

最终组合 **106 项通过（45.430 秒）**，包含五项新增快照边界检查。SQLite／LocMem 和全部交易所替身仅用于隔离验证。

客户端定向入口为 `TradeToolTests/PositionHistoryLoadingTests` 和 `NativeIntegrationTests`：10 项通过（1.832 秒），覆盖本地先显示、旧服务端兼容、解绑清空、切页、取消和补查失败保留记录。UI 使用 `WebParityUITests/testAllUnboundPositionTabsOnlyShowBindingPrompt`、`testBoundHistoryShowsRecordsWhileExchangeSupplementIsSlow`、`testAllPositionTabsRefreshFromEmptyLists`，最终三项通过（62.433 秒），已检查截图；generic iOS Release 未签名编译通过。证据保存在忽略目录 `.integration-runtime/PositionHistory/`；手机实际绑定账户、真实网络耗时与发布仍待验，初轮失败及修复见 [变更记录](changes.md)。

## 自选与共用交易对回归（2026-11-01）

`market_stream.test_symbol_catalog` 先复现旧搜索响应缺少五个客户端必填分页字段，再验证修复；覆盖采集器筛选／持久化／下架、空快照保留及缓存丢失后读数据库，列表请求不访问 Binance。与 `market_stream`、`positions.test_review_fixes`、`positions.tests` 组合 **177 项／57.324 秒通过，5 项独立 Redis 条件跳过**；SQLite／LocMem／交易所替身不等于生产 MySQL 验收。

`WatchlistInteractionTests` 覆盖自选增删、隐藏项不参与排序、旧固顶偏好兼容、用户持久化、共享目录缓存和刷新失败保留；与历史／原生接口检查 12 项通过（1.893 秒）。追加 `RetainedTradeRiskTests` 与真实 loopback WSS 检查两项通过（0.528 秒），验证账户核对不清空旧值、相同风险额不发布，选中币种在超过 200 个候选、自选删除／搜索退订及切币种时持续收到所需报价。

UI 用 DEBUG 无网络业务替身：原生排序手柄实际长按拖动并核对顺序、移到顶部；三个交易对入口、自选添加／取消删除／确认删除、过滤和开仓选币；开仓／我的共用止损滑杆与固定按钮、默认头像和紧凑绑定按钮；协议／隐私 X 关闭返回注册表单。首轮纠正搜索可访问名称与父容器覆盖关闭标识，系统删除确认改为显式“取消／删除”警告框。图表退订／恢复的补查复现了并发发送订阅乱序，已按连接串行发送；扩展 `AppearanceTests`／`MarketFastPathTests`／自选与风险回归共 31 项通过（19.332 秒），覆盖旧连接失效及真实 loopback 的最终订阅。最终四个 UI 流程分别通过；共享流程 30.172 秒，原生拖动最终 12.013 秒，其余见 `.integration-runtime/PairPicker/` 的结果包。已查看截图。generic iOS Release 构建、迁移漂移与发布检查结果在 [变更](changes.md) 更新；本地结果不表示 TestFlight／手机完成。

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

`IntegratedNativeUITests.testConfiguredKlineFirstFramePerformance` 是另一个显式 opt-in 的只读采样入口。除上述三个 QA 变量外，测试进程必须收到 `INTEGRATION_KLINE_PERFORMANCE=1`；xcodebuild 同样使用 `TEST_RUNNER_` 前缀。默认连续 20 次热进入及 5 次 App 重启后进入 BTCUSDT 1h，不通过清理服务端缓存制造冷读。可用 `INTEGRATION_KLINE_WARM_COUNT`／`INTEGRATION_KLINE_COLD_COUNT` 缩小排障批次；这些名称中的 cold 只代表 App 重启，缓存命中须另测。测试处理登录后延迟出现的保存密码弹窗，返回使用 `market-chart-back`，避免选中隐藏导航栏的同名按钮。

使用专用模拟器，关闭覆盖率以减少测量干扰，例如：

```bash
xcodebuild -project frontend/ios-app/TradeTool.xcodeproj \
  -scheme 'TradeTool Chart Calibration' -configuration Debug-Seoul \
  -destination 'platform=iOS Simulator,id=<专用模拟器 UDID>' \
  -derivedDataPath .integration-runtime/KlineFirstFrame/DerivedData \
  -parallel-testing-enabled NO -enableCodeCoverage NO \
  -only-testing:TradeToolChartCalibrationUITests/IntegratedNativeUITests/testConfiguredKlineFirstFramePerformance \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

AX 的存在／label 等待用于操作与确认，不作为点击到首帧的时间；阶段测量使用单调时钟，并区分模拟器 GPU completion 与真机 drawable presentedTime。必要临时探针测完删除，日志、凭证、xcresult 和构建目录保持忽略。当前维护结论见 [首屏补验](market-data.md#按首屏交接计划补验2026-11-01)。

业务页面的原 Web 对照、DEBUG 隔离数据和 `WebParityUITests` 命令见 [Web 原生复刻](ios-web-parity.md)。该模式无需账号，不连接真实交易；只有本地资金预检和 EMA 预览返回静态响应。Release 不包含该入口。

认证页现采用 USDC 原生布局和底部 sheet；显示名、图标、已有接口及注册开关替身见 [品牌与认证](ios-authentication.md)。认证 UI 测试只提交本地验证失败的表单，后端协议用 SQLite / LocMem 的 `users.tests.AuthApiTests` 和 `mobile.tests.MobileAuthTests` 验证，重置邮件使用 locmem。

`TradeToolTests/NetworkLatencyAndModalTests` 覆盖 WSS RTT 匹配、中位数、超时重置、颜色阈值、保留读数重测和健康连接、大小弹窗动画及编译后启动 storyboard 的 96 pt 尺寸和资源透明圆角。延迟刷新及原生止损回归入口为 `WebParityUITests.testLatencyRefreshRetainsValueAndNativeStopLossFooterStaysFixed` 与 `testSwipeCanCancelAndStopLossModalClosesWithoutMovingPage`；相关既有入口还有 `testMarketLatencySignalAndInternalOnlyHeader`、`testCollectionButtonAndSmallConfirmationCanReopen` 及认证面板流程。

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

`ChartEngineCoreTests` 增加兼容旧响应、晚到快照不回退 Socket 数据、K 线横拖让出 50 pt 返回范围及业务／行情暗色色板一致性测试。两项 `WebParityUITests` 为 `testWideSwipeReturnsFromBusinessPagesAndNestedStrategy`、`testSwipeCanCancelAndStopLossModalClosesWithoutMovingPage`，使用无网络 fixture，覆盖业务多层导航、40 pt 起手、取消手势、表格边界、暗色止损和按钮／拖动关闭。本轮使用独立 `Binance Navigation Review` 模拟器，避免其他本地 UI 校验干扰。

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

## 计划与手动校验退役的本轮范围

2026-11-01 移除看盘计划、校准问答、手动指标清单及无调用的旧 Java 账户／风控／杠杆适配、图表标注和 Signpost。同步删除仅验证已移除实现的测试；保留仍服务于当前图表的数据、指标、GPU、安全和压力测试。`common.test_retired_modules` 更新旧接口不可解析的断言；UI 用例更新未绑定链接的居中／打开绑定界面及菜单移除断言。用户安排先不测试，本轮仅执行 `TradeTool` 的 `build-for-testing` 编译（没有运行 XCTest）、Python AST／Django check／migration 漂移检查和项目文件解析；报告 `.integration-runtime/retire-watch-checklist-build.log`。UI 源码使用 Swift parser 检查，没有启动模拟器验收。实际发布与设备待验范围见 [变更](changes.md)。

## HarmonyOS

独立工程为 `frontend/harmony-app/`，面向 Mate 80 的原生鸿蒙测试；不接应用市场。`npm test` / `npm run check` 仅作隔离核心与配置检查。本轮40项替身测试、核心 strict 类型检查与工程静态检查通过；安装 Command Line Tools 26.0.0.865、API 26 SDK 与 JDK 21 后，真实 ArkTS 编译及未签名 HAP 打包通过，调试签名和手机运行仍待验证。工具链版本与验收边界以 [鸿蒙主文档](harmony-client.md) 为准。使用忽略的 `.local-build/project/` 配置调试签名，保护公开工程中的签名口令与证书；具体命令见 [工程 README](../frontend/harmony-app/README.md)。

## 图表加载诊断回归

2026-11-01 本地 `market_stream` 67 项通过，包含五项独立临时 Redis 回归及九项诊断入口测试：鉴权、合法网络字段、未知字段拒绝、实际 24 KiB 正文限制、非有限数值、用户节流、容量／重复报告幂等、用户隔离、retention 和 K 线关联响应头。migration 漂移检查通过，仅新增诊断表。

专用模拟器 `A9B09AF9-195A-4F50-B706-7F07A0EB4CD4` 上 `ChartEngineCoreTests` 136、`MarketFastPathTests` 21、`ChartLoadDiagnosticsTests` 4，共 161 项通过（33.188 秒）。覆盖旧 epoch 首帧拒绝、周期替换和结束一次、取消、固定诊断字段／事件上限、HTTP 追踪头及解码边界、诊断 401 不全局登出、Metal 有效首帧 observer 可重入且只触发一次。日志保存在忽略目录 `.integration-runtime/KlineDiagnostics/`。

在独立 SQLite 数据库与回环 HTTP API 中迁移新表，种入 1500 根合成 BTC1h，禁止外部交易所请求，以真实 URLSession、图表 pipeline、Metal 模拟器完成回调、异步 POST 和 Django 入库串通验证。三次进入均保存 displayed、首尾时间、网络 metrics 和完整图表阶段；模拟器完成属于 GPU 代理，不是物理手机呈现或公网性能。初次配置用不在已知列表的回环端口，App 回落到了既有远端选择，因此那一轮 UI 虽通过但没有本地记录，不计入隔离贯通；随后通过构建设置显式指定回环 API，并核对实际数据库三条记录。

最后补充网络／本地缓存来源字段及隐私清单后，九项后端诊断与五项 iOS 定向回归再次通过，隔离 UI 再次完成三次加载并入库；数据库确认缓存来源标记存在，原始网络读取在前一轮已验证。只读 trace 查询通过，最终 generic iOS Release 无签名编译通过并确认成品清单包含新增声明。两轮隔离验证均不作为手机／公网性能数据；没有上传 TestFlight 或执行真实交易。
