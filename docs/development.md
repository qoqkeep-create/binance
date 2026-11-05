# 开发与验证

当前工程入口见 [README](../README.md)，配置见 [配置字典](configuration.md)。以下命令在本整合目录执行。

## API 共享行情分发器（2026-11-06，本地）

基线为已推送的 `c96fcbc`。先扩展实际三连接／三事件回归，旧实现明确失败 `AssertionError: 9 != 3`，日志 `.integration-runtime/shared-fanout-baseline.log`；此前已验证的公共重复编码仍应为 0。新 `fanout.py` 接管 Redis 接收、主题合并与重叠 pattern 去重，原 ASGI `matches` 逐连接过滤、发送队列和客户端恢复协议保留；方案及 USDC 比较见 [行情](market-data.md#api-共享行情分发器2026-11-06本地)。

新增 11 项边界回归：真实临时回环 Redis 检查精确／通配重叠订阅只解码／投递一次、订阅引用及替换／退订／最后关闭、慢连接隔离与顺序、无效主题隔离、实际 Redis `CLIENT KILL TYPE pubsub` 后重建，以及 ASGI shutdown。可控 ACK 替身覆盖命令发送期间阻塞的超时边界、实际确认前不就绪、更新途中取消、首次 attach 取消和 Redis 故障唤醒全部等待者；替身不执行交易所／资金调用。

补充突发回归曾复现：两个正常 ASGI send 回调、8 条发送队列连续接收 64 条 Redis 事件时，被误判 `slow_consumer`，测试收到 `websocket.close` 而非完整事件。共享 reader 在缓冲数据就绪时可能连续执行而不悬停；现每次分发后以 `asyncio.sleep(0)` 交还执行机会，无固定等待时间，让正常 sender 排空。修复后该用例及完整套件通过，失败证据 `shared-fanout-burst-baseline.log`。

最终完整 `market_stream` **105 项通过（5.581 秒，0 跳过）**，包括新增 11 项和已有鉴权、私有事件范围、发送超时、token 到期及序列回归。既有三连接 ASGI 测试现确认三公共事件的服务端解码 **9→3** 次，重复编码维持 **0** 次，原身份 BUS 的订阅客户端 **3→1**；内部元数据仍不外发，用户及普通／带单模式不串流。复现命令：

```bash
server/.venv/bin/python .integration-runtime/ChartIntervalLatencyNov5/run_isolated_backend.py market_stream
server/.venv/bin/python .integration-runtime/bench_shared_fanout.py
```

隔离运行器禁外网、dotenv、账户流和 scheduler，使用临时 SQLite／Redis；完整日志为 `.integration-runtime/shared-fanout-full-final.log`，定向日志为 `shared-fanout-boundaries.log`／`shared-fanout-protocol.log`。实现及测试输入 SHA-256 位于 `shared-fanout-source-manifest.json`。本轮没有 iOS 代码变更，不重复启动模拟器或 Xcode 构建。

### 本机分发对照

使用同一临时回环 Redis，在同一 Python 进程中分别载入 Git `c96fcbc` 的旧 ASGI 与本地新 ASGI，每连接数各发布 100 条行情，等待全部 send 回调返回；先完成鉴权替身和订阅 ack，再进行采样。表为最终源码在完整回归结束后的独立单轮结果，不作为容量／生产 P95 承诺。表中 CPU 为整个 100 事件循环的进程 CPU 时间，包含发布调用和接收回调；P50／P95 为单事件发布开始至全部 ASGI send 回调的墙钟时间，不含 TLS、公网、手机和绘制。

| 连接数 | Redis 订阅客户端 旧→新 | 解码次数 旧→新 | CPU ms 旧→新 | P50 ms 旧→新 | P95 ms 旧→新 |
| --- | --- | --- | --- | --- | --- |
| 1 | 1→1 | 100→100 | 13.379→13.441 | 0.235→0.228 | 0.267→0.262 |
| 3 | 3→1 | 300→100 | 19.811→16.051 | 0.288→0.243 | 0.339→0.278 |
| 30 | 30→1 | 3000→100 | 89.815→37.142 | 0.996→0.463 | 1.057→0.487 |

证据为 `.integration-runtime/shared-fanout-benchmark.json` 和 `shared-fanout-benchmark.log`。这证明连接增加时重复接收／解码和 CPU 成本减少；单连接结果接近，不能由此推断手机切周期少等多少毫秒。该对照是当前 Python 旧版与新版，不是重新运行 USDC Java 的 A/B。

本轮本地实现无新依赖、协议／配置、数据库迁移或交易策略变更。未提交／推送、部署到 47.80.22.243（首尔服务器）或上传 TestFlight；新后端的真实端到端延迟和在线负载仍待发布后验证。

## 刷新图标稳定与保证金紧凑展示（2026-11-06，本地）

旧实现松手后将 28 pt 指示器行插入 ScrollView 内容，实际 UI 回归 `testRefreshReleaseKeepsContentAtRestPosition` 记录同一文字锚点从 y=190.333 移到 218.333（+28 pt，断言失败）。改为拖动与刷新共用同一覆盖层，20×20 pt 图标位于 36 pt 高区域，不再改动内容布局；仍观察原 pan／offset、70 pt 释放触发。旧版证据 `.integration-runtime/refresh-release-baseline.log`、`.integration-runtime/RefreshBadgeNov6/Baseline.xcresult`。

保证金徽标改为系统压缩宽度的 heavy 数字，普通 20 pt／52×28 pt，三位整数 16 pt／60×28 pt，触摸高度保留 44 pt。顶部整数／个位补零，不显示比较符号，100 以上保留实际整数；明细保留精确值。host 模型／分页／格式 **11 项通过**，实际生产 Header 320／393／440 pt × 浅深主题 × 4 种比例（3.45／55／85／121.25）× 3 个选中页共 **72 个布局**，已查看 `03%` 和 `121%` 的字形及风险颜色；无效／过期仍灰色。复现命令：

```bash
python3 frontend/ios-app/scripts/test_position_margin.py .integration-runtime/RefreshBadgeNov6/Header
```

最终在 iPhone 18 Pro／iOS 27.2 专用模拟器（`6D67613C-F801-48BA-A3FF-0726A254389A`）**3 项 UI 用例通过（171.343 秒，0 失败）**：

- `testRefreshReleaseKeepsContentAtRestPosition`：实际图标 20×20 pt，松手后同一内容锚点相对静止位置差不超过 1 pt，刷新后出现第 2 次读取结果、指示器收起。
- `testSignalsPullRefreshShowsIndicatorAndLoadsNewSnapshot`：30 pt 短拖不刷新，完整下拉显示指示器、更新内容并收起。
- `testSharedRefreshIndicatorOnMarketProfileCommandsAndRecords`：行情、账户、命令、操作日志、归集、策略日志和内嵌记录七类页面均检查图标尺寸／屏幕内位置及刷新后消失。

无交互覆盖层以 ActivityIndicator 类型及“正在刷新”标签定位，并检查实际尺寸和截图；不以可点击性判断可见。SwiftUI 外层列表的 identifier 会覆盖部分子元素，旧 `refresh.indicator` 定位不适用于这些覆盖层。本轮较早的 `Final.xcresult` 中，`testAllPositionTabsRefreshFromEmptyLists`（29.612 秒）和 `testPositionPagesSwipeAndMarginDetailsStayReadOnly`（19.184 秒）已通过，覆盖持仓三页从空列表刷新、页签横滑、徽标点击／明细及弹窗隔离；该混合结果包内另外三项旧定位／点击断言失败已修正，以最终 `Verified.xcresult` 为准，不将整个旧包记为通过。

最终结果 `.integration-runtime/RefreshBadgeNov6/Verified.xcresult`，日志 `.integration-runtime/refresh-badge-verified-ui.log`；旧位移与修复后截图已对照。主 App／Widget 的 generic iOS 无签名 Release 构建通过（`.integration-runtime/refresh-badge-passive-release.log`），测试目标编译通过（`refresh-badge-verified-build.log`）。最终 host 11 项通过（2.820 秒），日志 `refresh-badge-header-final.log`，输入哈希保存在 Header 目录。复现 UI 命令：

```bash
xcodebuild test-without-building -project frontend/ios-app/TradeTool.xcodeproj -scheme 'TradeTool Chart Calibration' -destination 'platform=iOS Simulator,id=6D67613C-F801-48BA-A3FF-0726A254389A' -derivedDataPath .integration-runtime/PositionSwipeNov6/Tests -only-testing:TradeToolChartCalibrationUITests/WebParityUITests/testRefreshReleaseKeepsContentAtRestPosition -only-testing:TradeToolChartCalibrationUITests/WebParityUITests/testSignalsPullRefreshShowsIndicatorAndLoadsNewSnapshot -only-testing:TradeToolChartCalibrationUITests/WebParityUITests/testSharedRefreshIndicatorOnMarketProfileCommandsAndRecords CODE_SIGNING_ALLOWED=NO
```

本轮只改本地客户端显示和共用刷新布局，没有新增接口／配置或数据库迁移；既有后端待提交改动保留。未提交／推送、部署到 47.80.22.243（首尔服务器）或上传 TestFlight，没有真实交易／资金／保护单操作；iOS 17 和新包 iPhone 动态手感待验。展示口径见 [资金](capital-and-transfers.md#持仓页保证金率2026-11-05本地实现)，共用容器见 [页面规范](ios-web-parity.md#账户设置与紧凑刷新2026-11-05本地)。

## 公共行情编码复用与持仓整页手势（2026-11-06，本地）

公共行情原字符串复用的新增回归运行三个实际 ASGI 连接及临时回环 Redis：旧实现三种事件重复编码 9 次，修改后 0 次；含内部字段的公共事件仍清理，私有事件按用户／模式过滤，ping 作为队列屏障检查没有额外私有事件。全量 `market_stream` **94 项通过（14.433 秒，0 跳过）**。运行器禁外网／dotenv、关闭账户流和 scheduler，使用隔离 SQLite 及交易所替身：

```bash
server/.venv/bin/python .integration-runtime/ChartIntervalLatencyNov5/run_isolated_backend.py market_stream
python3 frontend/ios-app/scripts/test_position_margin.py .integration-runtime/PositionSwipeNov6/HeaderFinal
```

后端旧版失败日志为 `.integration-runtime/market-wire-baseline.log`，最终为 `market-wire-final.log`。客户端 host **10 项通过（2.020 秒）**，包含 9 项模型／分页／阈值回归及 1 项实际 Header 渲染：320／393／440 pt × 浅深主题 × 三种风险比例 × 三个选中页，共 54 个布局，检查外溢及页签文字确实渲染；已查看恢复后的生产字形。host 不执行 UIKit 手势。

旧版 `fcffac9` 的只读归档配合同一修正坐标 UI 用例，在页头按钮行横滑处失败（15.793 秒，`LegacyActual.xcresult`）；修复版已经单独通过页头、卡片、空白、空列表及未绑定状态往返（56.631 秒，`Coordinates.xcresult`）。最初测试用页头无障碍分组的中点，实际分组 frame 为 y=0…106，按钮行在 y=62…106，中点位于状态栏安全区；该无应用触摸回调的失败不作为产品复现。最终用可见页签按钮的真实中线起手，并在旧归档重新确认失败。归档与模拟器证据均位于忽略目录 `.integration-runtime/PositionSwipeNov6/`；临时触摸探针已移除。

去掉探针后，iPhone 18 Pro／iOS 27.2 专用模拟器（`6D67613C-F801-48BA-A3FF-0726A254389A`）最终 **3 项 UI 用例通过（85.956 秒，0 失败）**：`testPositionPageSwipesCoverHeaderCardsAndEmptySpace`、`testPositionPagesSwipeAndMarginDetailsStayReadOnly`、`testAllPositionTabsRefreshFromEmptyLists`。覆盖页头按钮起手／卡片／空白／空和未绑定列表往返、短竖拖不切页、三页真实下拉刷新后出现数据、徽标点击及明细、弹窗横拖不切底层页。结果为 `Final.xcresult`，日志 `.integration-runtime/position-swipe-ui-final.log`。完整复现命令：

```bash
xcodebuild test-without-building -project frontend/ios-app/TradeTool.xcodeproj -scheme 'TradeTool Chart Calibration' -destination 'platform=iOS Simulator,id=6D67613C-F801-48BA-A3FF-0726A254389A' -derivedDataPath .integration-runtime/PositionSwipeNov6/Tests -only-testing:TradeToolChartCalibrationUITests/WebParityUITests/testPositionPageSwipesCoverHeaderCardsAndEmptySpace -only-testing:TradeToolChartCalibrationUITests/WebParityUITests/testPositionPagesSwipeAndMarginDetailsStayReadOnly -only-testing:TradeToolChartCalibrationUITests/WebParityUITests/testAllPositionTabsRefreshFromEmptyLists CODE_SIGNING_ALLOWED=NO
```

最终主 App／Widget 的 generic iOS 无签名 Release 构建通过，日志 `.integration-runtime/position-swipe-release-final.log`，测试目标也已实际编译运行。只有本地假数据和系统手势，不做真实交易／划转／撤保护单。实际截图已核对恢复后的页签和保证金率排布；iOS 17 与手机动态手感仍需新包验收。

本轮不含提交／推送、47.80.22.243（首尔服务器）部署、TestFlight 或新包实机验收。当前编码复用范围与后续共享分发器边界见 [行情](market-data.md#公共行情编码复用与-usdc-思路2026-11-06本地)，页面手势及字号见 [页面规范](ios-web-parity.md#保证金徽标与手势切页2026-11-05本地)。

## USDC 前端与推送源码对照（2026-11-05）

按用户要求先将当前全部安全改动以 `dd4e5db` 推送 GitHub `codex/integrated-ios`，再只读比较 USDC `104d7d7`。本轮不改业务代码、不新增测试；沿既有验证记录核对交付内容，执行 Git 差异／敏感模式／未追踪文件检查，并验证远端分支包含提交。`.build/` 加入忽略，未收录原始诊断、凭证或来源目录。

对比覆盖真实 iOS 模型、网络、数据／指标、场景、宿主、Metal，以及 Java／Python 的采集、分发、收盘、HTTP 和统计链路。USDC 选定路径 `git diff HEAD --name-only` 为空，未把来源目录其他 Scheme 与网络研究改动混入结论。当前／来源 engine 为 42／44 文件，共同文件 18 个字节相同、24 个不同；双方 SHA、路径清单及基线写入忽略目录 `.integration-runtime/USDCComparisonNov5/source-comparison.json`。这是可核对的源码差异，未运行两套后端 A/B、旧 Java 或新一轮真机测试；性能推断与待测项见 [行情主文档](market-data.md#与-usdc-的前端和数据推送对照2026-11-05)。

## 保证金率与手势切页（2026-11-05，本地）

后端 `positions.test_margin` 15 项及 `common.tests.BinanceRequestBudgetTests` 17 项共 32 项通过。覆盖交易所权益分母与独立委托占用、真实维持保证金不由杠杆反推、空账户／零及负权益、无效／非有限／不一致字段、逐仓与多资产拒算、未成交委托、认证、绑定变更、跨用户／模式／Key／创建代际缓存、过慢快照和失败不缓存，以及两项新增账户 GET 的低优先级完整权重。测试用 SQLite 临时库、内存缓存和交易所替身，通过既有禁外网运行器执行，无生产账户或交易动作。

```bash
server/.venv/bin/python .integration-runtime/ChartIntervalLatencyNov5/run_isolated_backend.py positions.test_margin common.tests.BinanceRequestBudgetTests
python3 frontend/ios-app/scripts/test_position_margin.py .integration-runtime/MarginAndSwipeNov5/Host
```

后端也可按项目现有 SQLite 测试配置直接运行上述两个版本化测试模块；忽略目录运行器仅提供禁外网、禁 dotenv 和本地配置。后端日志为 `.integration-runtime/position-margin-backend.log`。

Swift host 直接编译真实 Store、分页模型、保证金状态、百分比与手势规则，9 项模型测试通过；包含延迟旧账户回包、前后台 monitor 交接、失败保留明细但取消风险颜色、有效期、重复请求、颜色边界／强平后不截断、水平阈值及边缘、两套分页模型和返回不增请求。另 1 项真实生产 Header／WebTabs／Badge 的离屏渲染测试通过：320／393／440 pt × 深浅主题 × 绿黄红共 18 组，2x 输出，检查尺寸和边缘溢出；只将 UIKit 主题颜色选择与字体适配为 AppKit。已人工查看 320 pt 浅色红色和 393 pt 深色绿色。日志 `.integration-runtime/position-margin-host.log`，图片在 Host 的 `rendered/`，生产源码 SHA 清单为 `production-inputs.json`。

generic iOS 主 App／Widget Release 无签名构建和 arm64 Simulator `build-for-testing` 通过，日志分别为 `.integration-runtime/position-margin-release.log`、`.integration-runtime/position-margin-build-tests.log`。新增离线 UI 场景为 `testPositionPagesSwipeAndMarginDetailsStayReadOnly`，只完成编译，**未运行模拟器、系统手势或真机验收**。真实滚动／刷新手感、弹窗动态效果、当前绑定和带单绑定结果仍待新包验证。

本次未提交／推送、部署到 47.80.22.243（首尔服务器）或上传 TestFlight；新客户端与新增接口需配套发布。业务口径见 [资金](capital-and-transfers.md#持仓页保证金率2026-11-05本地实现)，轻量切页的实现与取舍见 [原生页面](ios-web-parity.md#保证金徽标与手势切页2026-11-05本地)。

## 周期缓存、宿主复用与首帧优先（2026-11-05，本地）

在下节排查基线之后实现会话内周期缓存、两根尾部核验、Metal 宿主复用及通知覆盖／首帧门控。现行有效期、失效条件与数据边界统一见 [行情](market-data.md#会话内周期缓存与宿主复用本地实现)，本节只记录验证。

`python3 frontend/ios-app/scripts/test_chart_recovery.py .integration-runtime/ChartIntervalNov5/CacheChecks` 的最终模型 44 项及真实数据／指标管线 14 项共 **58 项通过（25.019 秒，0 失败）**，日志 `.integration-runtime/ChartIntervalNov5/host-checks.log`。API／WSS 为内存替身，不启动 transport；覆盖缓存上限、TTL 不续期、跨收线边界、后台／重连／指标／序列缺口失效、订阅确认与真实通知、严格水位去重、无呈现回调的 500ms 兜底、旧请求／分页隔离。尾部新增阻塞测试覆盖真实 OHLC／成交量纠正、下载期间较新报价、已有统计与指标历史对象复用、分页不收缩、连切只增加两根请求、迟到响应拒绝，以及真实通知／缺口／跨桶升级完整读取。

同样使用 500ms 固定 HTTP、真实 1500 根指标管线，只替换优化前后模型的单次受控对照如下。冷周期仍受 HTTP 约束，热返回同步发布完整 frame；两根核验完成后仍复用同一指标历史对象。

| 模型 | 首次 1h ms | 切 5m ms | 返回 1h ms | 三次请求 limit | 返回时指标历史复用 |
| --- | ---: | ---: | ---: | --- | --- |
| 修改前 | 560.11 | 540.88 | 566.26 | 1500／1500／1500 | 否 |
| 修改后 | 568.52 | 562.52 | 0.0716 | 1500／1500／2 | 是 |

这是模型 frame 就绪耗时，不含 UIKit／Metal、真实网络或物理屏幕。可复现命令为 `python3 .integration-runtime/ChartIntervalNov5/CacheBenchmark/run_benchmark.py`，原始 `before.log`／`after.log`、`results.json`、源码哈希与模型快照保留在该目录；没有覆盖下节旧三模型基线。

真实 SwiftUI `UIHostingController` 用例先在旧实现复现 frame 变 nil 后宿主移除并重建，4 处断言失败；修复后验证 nil／新周期／同周期更新全程宿主构造计数为 1、renderer 身份相同，以及切换清理交互、旧 epoch 回调隔离和加载遮挡不盖住渲染错误。专用模拟器为 `TradeTools Chart Host Reuse`（`6D67613C-F801-48BA-A3FF-0726A254389A`）。`ChartEngineCoreTests` 170 项加 `ChartLoadDiagnosticsTests` 4 项共 **174 项通过（23.104 秒，0 失败／0 跳过）**，结果为 `.integration-runtime/ChartHostReuseNov6/FinalCover.xcresult`，日志 `.integration-runtime/chart-host-reuse-final-cover.log`。

追加下述 live 水位修复后 clean 重编译，最终定向 **10 项通过（0.592 秒，0 失败／0 跳过）**，为 6 项宿主／呈现回归和 4 项诊断，结果 `.integration-runtime/ChartHostReuseNov6/FinalTen.xcresult`，日志 `.integration-runtime/chart-host-reuse-final-ten.log`。该轮离线 SwiftUI／Metal 用例实测视图创建到首个 GPU completion 代理 61.2ms，三次新状态到 GPU completion 代理分别为 18.1／13.0／8.5ms，宿主仍只创建一次且 renderer 身份不变。它不含 HTTP 和模型取数，也不等于手机真实 presentedTime。早期旧专用模拟器磁盘目录缺失导致启动失败，另一次增量链接使用到签名变化前的模块；均未计为产品验证，最终 clean 定向通过。另修正一个已有右侧未来空白测试的坐标样本，未修改几何／命中生产代码。

宿主复用后另补 live revision 水位回归：旧 stream `100` → 新 stream `1` → 迟到旧 stream `101` → 新 stream `2`。修改前新增回归有 6 处断言失败；按 presentationID 重置水位并拒绝旧 ID 更新当前 live 统计后，独立健康检查 **6 项通过（0.003 秒）**，保留原 nil-ID 行为。命令为 `python3 frontend/ios-app/scripts/test_renderer_presentation.py .integration-runtime/ChartHostReuseNov6/Health`；输入哈希和提取测试保留在该目录，日志为 `.integration-runtime/chart-host-reuse-health-baseline.log` 与 `chart-host-reuse-health-fixed.log`。

最终主 App／Widget generic iOS 无签名 Release 构建通过，命令为 `xcodebuild -project frontend/ios-app/TradeTool.xcodeproj -scheme 'TradeTool Release' -configuration Release -destination 'generic/platform=iOS' -derivedDataPath .integration-runtime/ChartIntervalOptimizedNov5/DerivedData CODE_SIGNING_ALLOWED=NO build`，日志 `.integration-runtime/chart-interval-optimized-release.log`。文档链接、`git diff --check` 和未追踪文件检查完成，新增安全测试脚本加入独立 Git 追踪。没有提交／推送、部署或上传 TestFlight；新包真机连续切换、长后台及相同网络下与币安的对照仍待验。

## 周期切换排查与百分比回归（2026-11-05，本地）

十字线右轴百分比的真实 glyph 回归先在旧格式复现失败，固定两位后 `test_chart_order_axis_labels.py` 的 6 项全部通过，覆盖正负／整数／小百分比／归零、2x／3x、320／390／440 pt，以及原订单价格轴和 Metal 像素规则。命令为 `python3 frontend/ios-app/scripts/test_chart_order_axis_labels.py .integration-runtime/CrosshairPercentNov5/Host`；失败与最终日志为 `.integration-runtime/crosshair-percent-baseline.log`、`crosshair-percent-final.log`，生产输入哈希保留于 host 目录。

后端新回归执行真实 `repair.run_next → service.warm_history → history_cache`，使用专用临时回环 Redis、隔离 SQLite 和两格测试容量：旧实现确认 maintenance 驱逐 BTC 前台窗口，按需 history 对照通过；修复后两项通过（0.115 秒）。完整 `market_stream` **93 项通过（5.369 秒，0 跳过）**，包含真实 Redis 协议测试。运行器禁用环境文件、调度器／账户流及非回环 socket／DNS，交易所为替身：

```bash
server/.venv/bin/python .integration-runtime/ChartIntervalLatencyNov5/run_isolated_backend.py market_stream
```

命令依赖本机已有测试 Redis 二进制；可维护测试位于 `server/market_stream/test_fast_path.py`，运行器及 `cache-priority-before.log`／`cache-priority-after.log`／`market-stream-tests.log` 位于忽略的 `.integration-runtime/ChartIntervalLatencyNov5/`。production 修改仅让 maintenance 使用原有 `prewarm=True`，没有修改账户／交易路径、数据库结构或按需通知职责。

三模型受控对照把每次 HTTP 固定为 500ms／1500 根，只替换模型，首次 1h → 5m → 返回 1h 都产生三次完整读取，约 550–570ms；当前、`7daa362`、USDC 各 1 项对照通过，归档后再运行 `all` 验证三个入口可复现。归档 `.integration-runtime/ChartIntervalNov5/Comparison/` 含三份模型、相同管线快照、原始／复测数据、来源 Git 与输入哈希，不含 `.build/`：

```bash
python3 .integration-runtime/ChartIntervalNov5/Comparison/run_model.py all
```

该对照断言的是优化前每次等待 HTTP 的基线行为；它隔离模型差异，不是各历史版本完整管线／Metal、线上旧后端或手机 A/B。完整结论及后续周期缓存／宿主复用见 [行情](market-data.md#周期切换耗时与十字线百分比2026-11-05)。

主 App／Widget 的 generic iOS 无签名 Release 构建成功，命令为 `xcodebuild -project frontend/ios-app/TradeTool.xcodeproj -scheme 'TradeTool Release' -configuration Release -destination 'generic/platform=iOS' -derivedDataPath .integration-runtime/ChartIntervalNov5/DerivedData CODE_SIGNING_ALLOWED=NO build`，日志 `.integration-runtime/chart-interval-release.log`。本轮未启动模拟器或进行新包实机验收，未提交／推送、部署或上传 TestFlight；**47.80.22.243（首尔服务器）** 只读结果与本地修复分开记录，见 [运维](operations.md#周期切换只读测量2026-11-05)。

## 图表恢复、弹窗与边缘填充（2026-11-05，本地）

`test_chart_recovery.py` 提取真实 `MarketChartViewModel`、`RealtimeClient`、HTTP 类型、指标和数据管线，使用受控历史接口阻塞／释放快照，不启动网络 transport。旧实现先复现首次 socket ready 取消 HTTP、历史尚未返回时 ticker／K 线提前发布新 epoch；修复后 23 项模型用例和 14 项原管线用例通过。范围包含首次握手、真实重连旧请求取消、旧分页晚到、通知合并、15 秒核验、空快照、修正 OHLC、每条实时 K 线、指标一致性；新增前后台生命周期检查覆盖 1m／1h、没有 socket 重连、后台消息、补线时改指标及重复前台通知。

实际 SwiftUI 草稿叠层先复现右轴无填充，修复后 1 项像素用例覆盖 2／3 倍屏及多空两向，确认右边缘与图内同色且主图上下无越界。实际场景／Metal 4 项通过，先复现左边界为 8／12 物理像素，修复后为 0，并保持主图正方形及右轴价格层级。真实卡片表达式及费用 14 项通过，旧版对三种成功绑定提示的断言失败；真实错误仍显示。弹窗实际 `WebModalBackdrop`／`webModalCard`／合成层 2 项通过，检查 0／25／50／75／100% 的卡片与蒙层像素透明度、固定位置和持仓操作转场选择。

可复现命令（从仓库根目录执行；输出均在忽略目录）：

```bash
python3 frontend/ios-app/scripts/test_chart_recovery.py .integration-runtime/ChartResumeNov5/Host
python3 frontend/ios-app/scripts/test_chart_order_axis_labels.py .integration-runtime/ChartResumeNov5/Axis
python3 frontend/ios-app/scripts/test_chart_order_overlay.py .integration-runtime/ChartResumeNov5/Overlay
python3 frontend/ios-app/scripts/test_position_fee_presentation.py .integration-runtime/ChartResumeNov5/Card
python3 frontend/ios-app/scripts/test_modal_fade.py .integration-runtime/ChartResumeNov5/Modal
```

合计 58 项 host 定向回归通过，生产输入哈希保存在各目录 `production-inputs.json`。旧版失败与修复日志为 `recovery-baseline.log`／`recovery-final.log`／`pipeline-final.log`、`axis-baseline.log`／`axis-fixed.log`、`overlay-baseline.log`／`overlay-fixed.log`、`card-baseline.log`／`card-fixed.log` 和 `modal-fixed.log`。最终主 App／Widget 的 generic iOS 无签名 Release 构建及 arm64 Simulator `build-for-testing` 成功（`release-final.log`／`test-build.log`）；没有启动模拟器、执行 iOS UI 测试或手机动态验收。主模型 host 需要显式导入 Combine，字体接口从 UIKit 适配到 AppKit，草稿像素检查仅使用主题替身，生产几何、裁剪、标签与手势未替换。弹窗像素检查不代替系统 fullScreenCover／真实点击与时间动画验收。

只读查看 **47.80.22.243（首尔服务器）** 的既有 Build 44 诊断，未变更服务器、数据库或部署；具体样本及未定位的线上耗时见 [行情](market-data.md#首次握手与后台恢复2026-11-05本地)。本轮未提交／推送或上传 TestFlight，不涉及真实交易、资金或保护单操作。

2026-11-05 同日后续按用户明确要求，将“策略和执行日志”的 `strategyLog` 动作显式固定为 fade，覆盖当前持仓与历史仓位入口，复用同一合成层蒙层。定向 `test_modal_fade.py .integration-runtime/StrategyLogFadeNov5/Host` 的 3 项 host 用例通过：包含运行中／历史策略、加载前短内容／加载后高内容，以及卡片和蒙层各阶段同步像素。日志位于 `.integration-runtime/strategy-log-fade-test.log`。本次主 App／Widget 的 generic iOS 无签名 Release 构建及 arm64 Simulator `build-for-testing` 均成功，日志为 `.integration-runtime/strategy-log-fade-release.log` 与 `.integration-runtime/strategy-log-fade-build-tests.log`。未启动模拟器，系统展示和真机观感仍待新包验收。

## 下拉刷新触发与动画恢复（2026-11-05，本地）

2026-11-04 的公共刷新容器替换了系统 `.refreshable`，原页面回调仍在，但真实拖动未进入有效距离状态。离线 UI 用例 `WebParityUITests.testAllPositionTabsRefreshFromEmptyLists` 在旧代码失败；定向探针记录 53 次手势更新、最大测距 0、松手距离 0，将测量器移入内容背景仍失败。原有三个 `WebRefreshInteractionTests` 只验证纯状态，无法发现滚动视图接线失效，不能作为动画和真实触发通过的证据。

共用组件现读取实际 `UIScrollView` 顶部越界距离，并观察其已有 pan 的释放／取消；不占用原 delegate，不再添加 SwiftUI 拖动手势。保留 70 pt 阈值、0.5 指示器、短／空列表回弹、单个刷新任务、无障碍动作，以及各页面原账户范围和隐藏取消规则。完整行为与覆盖入口见 [页面规范](ios-web-parity.md#账户设置与紧凑刷新2026-11-05本地)。临时测距探针已移除。

在专用 iPhone 18 Pro／iOS 27.2 离线模拟器上，四个不同 UI 用例通过：三个空持仓页签下拉后从空变为有数据；信号 30 pt 短拖不刷新、充分下拉出现小动画并从“读取 1”变为“读取 2”；行情、我的、交易命令、操作日志、资金归集、策略日志和内嵌记录逐一验证动画可见且完成收起；信号原有跨标签／前后台滚动位置保留用例通过。已查看行情、信号、账户及记录截图，指示器约 10×10 pt。慢响应只由 DEBUG 的 `--fixture-refresh-delay` 内存 API 提供，没有网络传输，写操作仍按原 fixture 拒绝；命令就绪标记用于等待首次加载结束，避免把已有在途读取的防重保护误判为下拉失败。

复现命令为 `xcodebuild test-without-building -project frontend/ios-app/TradeTool.xcodeproj -scheme 'TradeTool Chart Calibration' -destination 'platform=iOS Simulator,id=18FBF3F9-632C-4B00-BADE-F1CA7FFF483E' -derivedDataPath .integration-runtime/PullRefresh/DerivedData -only-testing:TradeToolChartCalibrationUITests/WebParityUITests/testAllPositionTabsRefreshFromEmptyLists CODE_SIGNING_ALLOWED=NO`；其他三个用例为 `testSignalsPullRefreshShowsIndicatorAndLoadsNewSnapshot`、`testSharedRefreshIndicatorOnMarketProfileCommandsAndRecords`、`testSignalListKeepsSnapshotAndScrollPositionAcrossTabsAndBackground`。证据位于 `.integration-runtime/PullRefresh/`：旧版 `baseline-retry.log`／`Probe.xcresult`，通过结果分别在 `Fixed.xcresult`（空列表、保留滚动）、`Indicator.xcresult`（信号）和 `AllPages.xcresult`（其余入口）。初始化期间另有一次模拟器 runner 崩溃，恢复专用设备后已重跑；不计为产品用例通过。

最终 `TradeTool Release` 的 generic iOS 无签名主 App／Widget 构建成功，日志为 `.integration-runtime/PullRefresh/release.log`；UI 测试目标也已实际编译并运行。最低部署版本仍为 iOS 17，本轮运行验证仅覆盖上述模拟器版本。没有真机、新签名包、TestFlight 上传或生产部署；改动保留本地、未提交推送。真实 iPhone 的连续下拉手感仍需新包验收。

## 启动图标交接（2026-11-05，本地）

系统启动 storyboard 将图标约束到整屏中心，旧 `AppLaunchView` 只有背景忽略安全区，图标仍按安全区居中。实际 SwiftUI `ImageRenderer` 注入上下 59／34 pt 安全区后，393×852 pt 画面的图标从 y=378…473 移至 y=391…486，稳定复现约 13 pt 的下移；整容器填满窗口并忽略安全区后恢复到原坐标。两阶段统一使用 96 pt 的 `LaunchBrandMark`，避免从较小图集放大并再次裁切；登录页品牌组件不变。现行资源和布局规范见 [品牌与认证](ios-authentication.md)。

`python3 frontend/ios-app/scripts/test_launch_layout.py .integration-runtime/LaunchLayout/RepositoryFixed` 提取真实生产视图，只有图片加载从 iOS bundle 适配为源 PNG；使用真实 SwiftUI 离屏渲染，对照 storyboard 的全窗口中心与预渲染资源。四组布局（无安全区、两种竖屏及非对称横屏）乘浅深主题，8／8 逐像素一致；`--source .integration-runtime/LaunchLayout/RootBefore.swift` 重放旧版为 0／8，复现竖屏下移及横屏偏移。两个 Host 目录的 `production-inputs.json` 保存源码和资源哈希。

最终主 App／Widget generic iOS Release 无签名构建通过，generic iOS Simulator arm64 的 `build-for-testing` 通过，日志为 `.integration-runtime/LaunchLayout/{release-final,test-compile}.log`。新增 iOS XCTest 对照三组非对称安全区与浅深主题，仅编译，未启动模拟器或执行 iOS XCTest／UI。手机冷启动仍需安装新签名包后验收，旧启动资源缓存注意事项见 [认证文档](ios-authentication.md)。本轮未提交推送、上传 TestFlight 或发布后端；此前运维记录保留。

## 订单价格框接线与持仓费用展示（2026-11-04，本地）

订单右轴价格框改用图表主题背景：浅色白底、深色灰黑底。持仓止盈也进入右轴框投影，持仓及草稿的 SwiftUI 横线统一止于绘图区右边；Metal 仅绘制到框左边的短连接线，边缘夹紧时避开圆角空隙。修复原纯白硬编码及虚线贯穿框体，保留固定坐标、完整价格和最新价／十字线的覆盖层级。现行规则见 [行情](market-data.md#价格轴与图内订单标签2026-11-02)。

手续费主项未确认时用单边估算并标“估”，确认后使用真实入场费，包括实际零值；保留原实际符号，USDT 简写 U。持仓卡片恢复“（估总 … U）”，确认入场费替换原入场估算，未确认时使用原往返估计的一半；缺原估计时按原数量、开仓价和单边费率 0.0005 估入场费。已减仓部分按开仓价估费，未来剩余部分按最新价格估费，均使用 Decimal，避免把整笔往返估算再加一次。现行 API 不提供已减仓部分的真实费用，该部分仍明确估算；未知数量／价格、手动增仓、非 U 费用不能直接相加时，估总显示待核对。持仓盈亏最多两位并带 U，缺行情保留 `--`。费用显示局部增加严格数字解析，避免 `null`、`--` 被 Foundation 误当零，不修改全局 JSON 工具或交易计算。显示规范见 [原生界面](ios-web-parity.md)。

本地验证：

- `python3 frontend/ios-app/scripts/test_position_fee_presentation.py .integration-runtime/PositionFeeCard/FixedHost`：13 项通过，提取真实展示方法及实际卡片调用点；同一测试重放旧代码有 31 处行为断言失败，覆盖确认转换、实际零、部分减仓、最新报价、非法／缺失值、费用资产和盈亏单位。
- `python3 frontend/ios-app/scripts/test_chart_order_axis_labels.py .integration-runtime/AxisThemeConnection/Host`：3 项真实 Metal Host 通过；旧代码有 36 处断言失败。覆盖浅深主题、2×／3×、边缘连接、平移缩放及最新价／十字线像素层级。
- 实际 SwiftUI 标签 Host 9 项通过，旧止盈线重放有 4 处失败；`python3 frontend/ios-app/scripts/check_chart_lines.py` 5 项通过。以上合计 30 项不同回归检查。

费用证据为 `.integration-runtime/PositionFeeCard/{baseline,fixed}.log`；图表证据为 `.integration-runtime/AxisPriceLabels/{theme-connection-baseline,theme-connection-fixed,repository-runner-fixed,line-check}.log` 与 `.integration-runtime/ChartPositionLabels/axis-connection-{baseline,fixed}.log`。最终主 App＋Widget Release 构建与 arm64 测试目标编译成功，日志为 `.integration-runtime/PositionFeeAxis-{release,test-compile}-final.log`。同步 UI 用例的 U 单位断言，仅编译而未运行模拟器／UI 或真机。本轮没有后端改动、迁移、真实交易、资金、通知或部署操作；完成时保留本地，后续用户明确授权提交推送，范围见 [源码交付记录](changes.md#2026-11-04订单价格框与持仓费用源码交付)。实际触摸与手机外观待新签名包验收。

## 周期收藏与手续费简写（2026-11-04，本地）

周期设置改为只编辑快捷收藏，最多 7 项，上方与外层快捷栏精确对应，下方为支持周期补集。收藏项统一选中底色／边框和实心星，备选项统一未选中和空心星；卡片和星标都只增减收藏，不切图、不关闭面板。允许全部取消，外层始终保留设置按钮；原存储键及首次六项默认保留，空串明确表示零项，旧超限值按时间顺序截为七项。超限点击不禁用按钮，而是沿公共浮字提示“最多可选 7 个周期”。提示层挂在周期面板自身，避免被 `fullScreenCover` 遮住。规则见 [行情](market-data.md#快捷周期与自动价格视窗2026-11-03)。

开仓模块已持仓手续费将 USDT 简写为 U，沿用最多两位和去尾零；未确认状态、其他资产单位、费用计算及交易载荷不变。预估手续费原已使用 U。既有显示回归覆盖 1.255→1.26 U 和 0 U，同时保留默认调用的完整资产单位。

`python3 frontend/ios-app/scripts/test_chart_interval_preferences.py .integration-runtime/IntervalFavorites/Host` 直接编译实际偏好模型与仓库测试，5 项通过；旧模型重放出现 7 处断言失败，覆盖增减分区、空值、上限第七／第八项、当前周期不隐式回填和旧偏好规范化。费用实际生产方法的独立 Host 2 项通过。UI 用例同步为先收藏、关闭面板后点击外层切图，并新增超限提示及面板保持打开断言；本轮只编译，未运行 UI／模拟器或真机。证据位于 `.integration-runtime/IntervalFavorites-{baseline,fixed}.log` 和 `.integration-runtime/IntervalFee/fee-tests.log`；最终编译日志为 `.integration-runtime/IntervalFee-{release,test-compile}.log`。

最终主 App＋Widget Release 构建和 arm64 测试目标编译均成功，未启动模拟器。文档链接及 `git diff --check` 通过。本轮完成时保留本地；后续用户明确授权提交推送，源码交付范围见 [变更记录](changes.md#2026-11-04周期收藏与手续费简写源码交付)。未手动上传平台，没有真实交易、资金或通知操作。周期移动、星标外观和浮字提示的实际触摸体感待新签名包验收。

## 浮窗自适应高度与源码交付（2026-11-04）

画中画每页最多 3 笔，保留 5 秒整组轮播；视频高度及被遮挡源视图比例按当前页实际行数共同更新，尾页不足 3 笔也缩高。共享 `FloatingPiPFrameLayout` 统一分页上限、视频宽高、源视图和页脚位置；源尺寸只随实际成功入队的画面更新，背压等待时不提前变成另一页比例。没有为尺寸变化重建控制器、强制 flush 或把播放状态失效接口当作尺寸 API。尺寸及系统边界见 [浮窗](ios-floating-positions.md#使用与范围)。

`python3 frontend/ios-app/scripts/test_floating_positions.py .integration-runtime/AdaptivePiP/Host` 共 41 项通过。脚本现在以 AppKit 字体／绘图上下文适配，编译实际视频渲染器，真实生成 CVPixelBuffer、CMVideoFormatDescription 和 IOSurface；新增尺寸回归覆盖 0／1／2／3 行、640×240／322／404、同比源尺寸，并验证分页 3／3／1、尾页缩高及持仓减少。旧实现重放出现 10 处断言失败，证明回归可复现。日志为 `.integration-runtime/AdaptivePiP-{baseline,tests}.log`，输入 SHA 清单位于 Host 下。

最终主 App＋Widget Release `build`、arm64 `build-for-testing` 均成功，日志为 `.integration-runtime/AdaptivePiP-{release,test-compile}.log`；后者仅编译测试目标，未启动模拟器。下节图表／金额／费用验证结果继续适用于未再修改的上轮代码。文档链接、敏感字面量及 `git diff --check` 检查通过。系统外窗真实收缩动画、用户缩放与长期后台行为仍待签名包 iPhone 验收；本轮没有真实交易、资金操作或通知发送。

按用户本轮授权，与下节尚未提交的图表／持仓细调一起提交推送；基线、范围和发布边界见 [变更记录](changes.md#2026-11-04浮窗自适应高度与图表细调源码交付)。不含原 `.build/` 产物、凭证、签名、日志或 IDE 状态。

## 图表价格标签与持仓细调（2026-11-04，本地）

图内持仓开仓／止损标签改为 80×20 pt、待开仓为 72×20 pt，9 pt 固定字号，开仓盈亏最多一位小数。新增右轴订单价格框，使用独立显示数据与原价格域、字形图集；右轴虚线和框均在 Metal 内绘制，避免 SwiftUI 叠盖最新价。动态批次在最新价和十字线之前分别完成各类图元，交互帧与主题切换保留订单标签。布局与金额口径见 [行情](market-data.md#价格轴与图内订单标签2026-11-02)。

实际及预估手续费最多两位小数并去尾零，已持仓止盈改为正文色只读标签；当前代码已无“开仓绑定策略”提示行。持仓 K 线入口改为红绿实心蜡烛，黄条上移 3 pt；指标详情项本机持久化，非法旧值回退 MA。只调整展示，不改金额计算、订单载荷、策略选择或保护单。

本地验证：

- 真实 SwiftUI 持仓标签／投影／金额 Host 8 项通过，覆盖 80×20 pt 固定宽高、浅深主题、2×／3×、正负及极小负值、图内线不覆盖右轴。
- 费用等显示 Host 15 项通过，含实际 `USDTEntryDraft` 4 项、金额格式 6 项、费用 2 项及既有刷新 3 项；覆盖 1.254→1.25、1.255→1.26、零及原价格精度。
- 真实 Metal Host 3 项通过，包含新增右轴 2 项与原十字线覆盖 1 项，验证完整长价格、非法／离屏过滤、轴内延伸、浅深主题和 2×／3× 遮挡；恢复旧图元分组会出现 56 处像素失败，确认层级回归可复现。
- `scripts/check_chart_lines.py` 5 项通过；Release 主 App＋Widget 无签名构建和 arm64 `build-for-testing` 成功。后者仅编译测试目标，未启动模拟器。

证据位于忽略目录 `.integration-runtime/ChartLabelPolish/HostTests/`、`.integration-runtime/TicketPolish/Host/`、`.integration-runtime/AxisPriceLabels/`，最终构建日志为 `.integration-runtime/ChartLabelPolish-{release,test-compile}.log`。未进行实机、真实交易、资金操作或通知测试。本批验证结束时保留本地；后续随上方自适应浮窗整批交付，见 [本批记录](changes.md#2026-11-04浮窗自适应高度与图表细调源码交付)。手机上的字号与拖动体感待签名包验收。

## 图表顶部、归集页签与整批源码交付（2026-11-04）

K 线顶部移除独立设置按钮，指标／杠杆靠右，自选星标增加 9 pt 标题和统一 44 pt 点击区；行情标题改为“合约自选”。原设置视图代码保留，收藏与杠杆逻辑不变。资金页签即时选中、只让背景平移，预检读取与提交状态分离；旧动作在进入记录后仍相同，之前迟到的 pending 响应可能切回划转，现按请求 UUID／页签／动作／scope 及取消状态保护成功、错误和清理。

新增 `python3 frontend/ios-app/scripts/test_capital_tab_loading.py .integration-runtime/CapitalTabs/Host`，直接提取生产视图的状态、选择、load／execute 方法，HTTP 为内存替身。修改前 8 项中 6 项失败，修改后 8／8 通过；覆盖读取期间立即切换、旧请求不能拉回记录页或覆写新状态、取消与跨账户错误丢弃、真实执行入口／pending 仍锁定原 request_id 与 plan_token，不调用真实钱包接口。UI 的旧设置入口和持仓止损格式断言同步当前实现。

为整批交付核对既有鸿蒙改动，`npm test` 122 项及 `npm run check`（14 配置、148 导入、55 资源）通过，核心 TypeScript strict 检查通过；从当前公开源码同步本地工程并执行正常 `assembleHap` 成功（4.960 秒），未安装或启动手机。首轮测试仅因 Swift `DisplayNumber` 新增金额展示方法导致参考源码 SHA 不匹配；通过原 Swift 生成器重算，连续／缺口各 180 根合成 K 线及全部指标数值与重算前完全一致，仅该来源校验值变化，没有使用鸿蒙输出替换期望值。

最终 iOS Release 及测试目标编译结果和本批提交推送见 [变更记录](changes.md#2026-11-04图表顶部归集筛选与全部待提交源码交付)。既有 84 项 iOS host 验证仍按下节范围记录，本次新增为 8 项资金页签。未启动模拟器、执行真实交易／资金／通知或手机验收；未追加部署或手动上传 TestFlight。

## 账户、图表与外部浮窗调整（2026-11-04，本地）

本轮实现颜色切换外置、通知偏好开关、普通黄／带单蓝资产卡、16 pt 未读红点、固定黄色页签短线、96 pt 实心持仓标签和贯通价格边栏的水平线。浮盈最多 2 位、止损金额最多 1 位去尾零，保留原始 Decimal 判断颜色和交易精度；实际开仓费不再附估算，未确认显示“待核对”。移除逆势建议的运行入口和附加 K 线读取；止盈选项已选为正文色、未有效选择为红色，委托选择器共用圆角矩形。设置止盈与蒙层继续明确 fade。

下拉刷新改为公共可配置容器，指示器 scale 0.5、释放阈值 70 pt（100 pt 设计基准的 70%，不冒称系统原生固定阈值）。状态回归覆盖低于阈值、程序滚动、回拉撤销、刷新中不重复；只读复核补齐保留信号页隐藏／场景非活跃时取消及任务执行前取消检查，避免隐藏后的旧刷新把新信号标已读。页面原 scope、独立读取、幂等与交易命令条件保留。

外部 PiP 取代 App 内卡片，每页最多 4 行、每 5 秒组轮播。先在旧实现复现前台仍请求 inline／仅单行标题，再验证新多行和生命周期；图表先复现标签空底、宽度、金额位数及价格栏截线，再用实际 SwiftUI ImageRenderer 像素回归验证。通知先复现权限返回／重试取消后仍注册，再用实际管理器和内存系统边界验证。所有数据替身不发网络交易或真实通知。

本地不同 host 用例合计 **84 项通过**：

- `python3 frontend/ios-app/scripts/test_floating_positions.py .integration-runtime/ClientPolishNov4/FloatingHost`：40 项，包括真实 Store、估值、PiP 分页／过期／启动状态及 live 身份。
- `python3 frontend/ios-app/scripts/test_position_strategy_picker.py .integration-runtime/ClientPolishNov4/StrategyHost`：17 项，保留策略二次确认、账户隔离及未知结果原键查询。
- `test_notification_preferences.py`：8 项，完整生产通知管理器、实际请求类型及 UN／UIKit 内存边界替身，不触发系统权限或 APNs。
- `.integration-runtime/ChartPositionLabels/HostTests`：8 项，真实持仓 overlay／投影／估值／格式器，macOS 仅适配 UIKit 字体／主题边界，浅深主题、2x／3x、正负／极小负／长金额像素通过。
- `.integration-runtime/ClientPolishNov4/AmountRefreshHost`：11 项，直接抽取生产金额／费用／刷新状态类型，使用仓库 `DisplayNumberTests.swift`，包含原有价格精度回归。

最终 `generic/platform=iOS` 的 Release 无签名构建通过（主 App 与 Widget）；`generic/platform=iOS Simulator` arm64 的 Debug `build-for-testing` 通过，仅编译测试和 UI 目标。首次构建发现浮窗引用不存在的主题成员，改用真实根背景后最终构建成功。日志在 `.integration-runtime/ClientPolishNov4/{release-final.log,unit-compile.log,amount-refresh.log,strategy.log,floating.log}`，通知与图表红绿证据分别留 `.integration-runtime/ProfileSettings/`、`.integration-runtime/ChartPositionLabels/`。

没有启动模拟器、执行 UI／真机测试、开平仓／划转／撤保护单或发送通知。新 UI 用例已将旧内部浮窗和设置主题入口改为当前规范并编译。PiP 遮挡源可用性、直接外部启动、多行字号、系统权限和推送实际停止边界、刷新体感及淡出动态仍待正式签名包 iPhone 验收。本批验证结束时保留本地；后续整批提交推送见 [交付记录](changes.md#2026-11-04图表顶部归集筛选与全部待提交源码交付)，未追加部署或手动上传 TestFlight。

## 持仓交互、弹窗与浮窗同步回归（2026-11-03）

本轮将持仓“添加自动止盈”改为共用 60% 高度的 WebSheet，仅列自动策略；选择后二次确认，成功关闭，失败保留，未知结果锁定原策略／幂等键并查询。开仓及设置入口原有策略选择行为保留。交易对名称复用 K 线导航，市价止盈设置紧随文字；顶部三页签仅保留单层文字缩放和一条黄色短线移动。普通 Bool／item 弹窗默认原位淡入淡出，蒙层共用动画进度；大面板显式上滑，首次有效布局前隐藏，避免零高度误判与系统 fullScreenCover 上滑。页面规则见 [界面](ios-web-parity.md#持仓卡片操作区2026-11-03)。

浮窗问题先用实际类型复现：均价 100、剩余 2、ticker 110、REST pnl 19.5 时，持仓卡片为 20，而旧浮窗为 19.5。现在 Store 共用只读仓位事实和 ticker 估值，报价订阅按 owner 合并；共享读取由独立 Task 持有，消费者等待不会因另一页面退出被取消。回归还先复现消费者取消丢弃首次响应，再验证修复。PiP 即时报送并在背压时只保留最新帧，公共运行循环计时器负责轮播／过期；当前币种的报价与成功仓位事实均须有效，其他币种或新 REST 不续期旧报价。live 首帧显式保留服务端 upl 投影，与后台口径一致；详见 [浮窗](ios-floating-positions.md#数据和生命周期) 和 [行情](market-data.md#持仓市价与浮盈推送限流边界2026-11-02)。

本地隔离结果：

- `python3 frontend/ios-app/scripts/test_position_strategy_picker.py .integration-runtime/PositionStrategyPicker/HostTests`：实际 picker／控制器和既有策略确认逻辑共 17 项（新增 10＋既有 7）通过，测试 0.048 秒。覆盖过滤手动、确认取消／失败／成功、scope 变化、重复点击及未知结果只重查原命令；网络为内存替身。
- `python3 frontend/ios-app/scripts/test_floating_positions.py .integration-runtime/FloatingValuation/SharedHost`：浮窗 21、ticker 估值 12、live 4，合计 37 项通过，测试 0.055 秒；包含共享读取显式 join 门闩、取消归属、多 owner／session、跨账户／乱序、REST 失败不续期、多币种过期及帧背压。直接编译实际生产类型和仓库测试，不启动 AVKit／ActivityKit 或真实网络。
- `NetworkLatencyAndModalTests` 的三项动画状态测试，使用实际 `WebModalMotion`／`WebModalTransitionState` 的 host 包通过；旧实现先复现两个断言失败，再验证淡出与蒙层同进度、未知布局隐藏及大面板位移。
- 最终 `TradeTool Release` generic iOS 无签名 `build` 和 `TradeTool` generic iOS Simulator `build-for-testing` 均通过，包含主 App／Widget 与测试目标。首轮编译发现新增报价参数后旧 `FloatingPosition.init` 引用失配，修正 live 首帧独立投影后重建通过；最终构建所用 Swift 文件 SHA 与交付源码一致。

证据分别在忽略目录 `.integration-runtime/PositionStrategyPicker.log`、`.integration-runtime/FloatingValuation/`、`.integration-runtime/ModalFade/` 和 `.integration-runtime/PositionPolish/{release.log,unit-compile.log}`。57 项为本轮不同 host 用例合计；没有启动模拟器、执行 iOS UI／实机测试、真实交易／资金操作或通知发送。系统弹窗和页签动态观感、PiP 跨 App 长时间刷新需新签名包验收。本轮只交付 iOS 与对应文档，不追加服务端部署或手动 TestFlight 上传；源码提交／推送见 [变更记录](changes.md)。

2026-11-01 用户后续授权整批提交和推送，源码交付范围见 [最新变更记录](changes.md#2026-11-01整批源码提交与-github-交付)。下文“本地／未提交”描述各批验证结束当时的状态；本次交付没有重复测试、部署或手动上传 TestFlight，真实 iPhone 性能和云端分发仍按各主题待验项处理。

2026-11-01 的绑定与延迟界面任务中，用户当时要求停止进一步测试、先部署后自行验收。“我的”绑定长按钮、点击测延迟、三点等待动画和 2 秒单在途采样已完成，`Debug-Seoul` 模拟器目标仅执行 `build`，编译通过（`.integration-runtime/profile-latency-build.log`）；未运行修改后的单测、UI 或速度回归。既有断言已同步新状态并补充慢在途样本及点击重测场景，不能据此称为本轮测试通过。服务端仅执行发布必要的迁移、容器健康、HTTPS 与一次鉴权 WSS 心跳检查，未作交易操作和完整性能验收。新客户端与 WSS 数据库连接清理改动留在本地未提交、未推送；后者已包含在本次 SSH 部署中，版本及备份见 [运维](operations.md)。

本轮按用户后续的 BTC 加载排障要求恢复定向验证：行情后端 `manage.py test market_stream` 共 41 项，38 项通过、3 项专用 Redis 验证未启用；iOS `MarketFastPathTests` 10 项加 5 项快照／epoch／翻页回归全部通过（`.integration-runtime/ChartHistoryRefreshFinal.xcresult`）。新增慢响应门闩测试先复现取消下载，再验证首个响应优先展示、通知合并、切周期和 stop 的取消边界、pending 分页；这些结果不代替全部业务 UI、Release 或手机测试。后端和公网／GPU 分段样本、旧 USDC 的逐段对照见 [行情](market-data.md#与原-usdc-实现的核对2026-11-01)，本轮客户端仍未提交／推送。

随后按首屏交接计划补验：`market_stream.tests market_stream.test_fast_path` 41 项全部通过（2.469 秒），本轮显式提供专用 Redis 二进制，三项真实回环 Redis 测试没有跳过；`MarketFastPathTests` 18 项加 `ChartEngineCoreTests` 127 项全部通过（52.965 秒，`.integration-runtime/KlineFirstFrame/CorrectnessFinal.xcresult`）。新增分页重连／恢复顺序测试均先失败后修复，包含真实 15 秒校对、真实结构 ack、下载失败及不响应取消的旧请求。上述为本地隔离测试，未执行交易操作。

2026-11-01 本轮全部源码发布前，针对当前改动补跑 `market_stream.tests market_stream.test_fast_path common.test_retired_modules users.tests` 共 69 项，8.748 秒通过，显式使用专用临时 Redis；鸿蒙核心 40 项及工程检查通过。iOS 复用上方同内容 145 项与移除探针后的 Release 构建证据，本轮没有重跑手机性能或上传 TestFlight。发布后公网冒烟与源码版本关联见 [运维](operations.md#最新发布与核验2026-11-01)，代码评估与未实施项见 [行情](market-data.md#性能与可替换性评估2026-11-01)。

2026-11-01 随后的延迟刷新与止损入场优化另作本地验证：`NetworkLatencyAndModalTests` 9 项通过（2.273 秒），包含真实回环 WebSocket 上的手动重测保留读数、匹配 pong 结束进度，以及下拉刷新保留健康连接。专用 `TradeTools Web Review` 模拟器上的两项定向 UI 最终通过，覆盖点击／下拉刷新中间状态、浅深色绑定按钮、原生止损滑杆／底部按钮位置、确认取消、关闭与系统把手下拉；测试仅使用 DEBUG 替身。generic iOS Release 未签名编译通过，入场录屏未见明显闪烁，但没有真机帧耗时或 TestFlight 结果。初次 UI 失败及最终证据见 [变更记录](changes.md#2026-11-01延迟保留读数绑定按钮配色与原生止损面板仅本地)。本轮没有提交、推送、部署或平台上传。

策略选择／绿色统一与持仓页签／方向标记两批已按用户后续授权统一提交推送 iOS 源码；下方“未提交”保留各任务验证结束时的记录，本批交付不重复测试或平台上传，范围见 [源码交付](changes.md#2026-11-03策略选择持仓标记与配色-ios-源码交付)。

## 开仓初筛退役、止盈选择与策略确认（2026-11-03）

本轮隐藏十字线 OHLC 详情卡，保留原绘制及格式化代码和显式启用参数，时间／价格轴标签不变。开仓页无自动策略时使用手动止盈；止盈选择改为下划线及箭头，手动绿字、自动策略黄字并截断长名称。失效策略显示“请选择止盈方式”，按钮保持原全色。开仓模块不再放行内小字结果，复用公共 toast；正常取消不报错。手动／自动策略整卡选择均先二次确认，K 线入口成功返回、设置入口留列表，取消或失败均保留当前页。

客户端删除 EMA 初筛状态、卡片、计时、请求与 DEBUG 替身；后端删除专属路由、缓存与新单门控。直接进入原资金预检、冻结确认与持久命令，预检和发送前仍检查 scope、草稿和持仓就绪。旧 `ema_check_id` 仅保留指纹兼容：历史字符串与数值继续按旧字符串规则 trim，不读取初筛缓存或行情。并非移除图表 EMA／内部信号或资金风控。当前规范见 [界面](ios-web-parity.md)、[行情](market-data.md#十字线详情卡隐藏2026-11-03)与[交易安全](trading-safety.md#图表与标准开仓共用流程2026-11-02)。

- 实际策略页面方法及 Store 的 host 回归 **7 项通过（0.026 秒）**，覆盖确认／取消、手动重选、成功与失败、两种入口、切账户和迟到响应；可复现命令为 `python3 frontend/ios-app/scripts/test_strategy_selection_confirmation.py`。只替换网络及导航记录，fixture 与提取脚本纳入追踪，产物置于忽略目录。
- 实际 `advanceEntry`、`currentDraft`、校验方法、页面初始化任务及 Store 的方法级 host 回归 **6 项通过（0.021 秒）**，一次点击只发资金预检再确认；空 active 恢复手动、有策略恢复自动，阻断／超时／参数或 scope 变化不进入确认。实际 Draft／Decimal 载荷回归另有 **4 项通过（0.004 秒）**，覆盖手动不携策略字段、自动快照和无 EMA 字段。
- 十字线真实场景构建器及原 XCTest 方法 host 回归 **2 项通过（7.582 秒）**，对比默认隐藏／显式显示，覆盖 320／390／440 pt、2／3 倍屏、10k 蜡烛及轴标签。各组为分开范围，不作为整套 iOS 测试通过。

最终 generic iOS Release 无签名 `build` 及 generic iOS Simulator arm64 `build-for-testing` 均通过，后者只编译单测／UI 目标，没有启动模拟器或运行 iOS UI。UI 断言同步为单次点击直接确认和策略二次确认取消。证据位于忽略目录 `.integration-runtime/{EntryTakeProfit,DirectEntryMethod,CrosshairCard}/` 和 `strategy-selection-confirmation.log`。后端 API 快照以 LivePositions 实际运行版为基线，**264 项通过（116.000 秒）**；worker 以自身 `171be8` 实际运行版为基线，**264 项通过（116.140 秒）**，两组重叠、不相加。均为 SQLite／LocMem、外部 socket 禁用；覆盖无字段／过期／任意／空白／null 旧编号不门控，历史 scalar trim 及请求指纹、持久命令、资金、账户／带单隔离。两个归档分别核对 317／307 个源文件，只有相同 5 条允许路径变化（运行 3、测试 2），72 个非目标 views 声明逐字节保持原样；worker 的原运行源码另有 295 个镜像文件只读哈希匹配。证据位于 `.integration-runtime/RemoveEntryEMA/` 的包清单、归档审计和两份 snapshot 测试日志。生产检查与本地回归分开记录，不执行真实开平仓、划转、撤保护或测试通知。新客户端触摸／弹窗与 live 系统行为仍待签名包 iPhone 验收。

## MACD 操作色、十字线缩放与 live 持仓卡片（2026-11-03）

开多、选择止损价提示及 auto 直接使用图表当前主题的 MACD 绿色，开空使用同一 MACD 红色；移除交易按钮禁用态的整体半透明，保留原禁用条件。账户刷新此前仅识别原生 `CancellationError`，网络层转换后的 `APIError.cancelled` 被写成“请求已取消”；现在按任务、账户 scope 与 `shouldPresent` 过滤正常取消，真实错误仍展示。行情编辑图标改为 20 pt、保留 44 pt 点击区，延迟与编辑之间去掉多余间距。

实际生产逻辑提取到 macOS host 包的回归共 **12 项通过**：取消提示 3 项（0.003 秒，旧版 4 个断言失败）、十字线／pinch 状态 3 项（0.001 秒，旧版 2 个断言失败）、inline／Home PiP 激活策略 3 项（0.002 秒）、Live 跨端载荷／Decimal／身份隔离 3 项（0.001 秒）。同次长按仍可单指移动十字线，双指缩放接管后清除十字线，后到的长按结束回调不能中断缩放。UIKit 手势与跨 App UI 断言已编译，未在 iPhone 或模拟器执行。证据分别在忽略目录 `.integration-runtime/ChartActionCancel/`、`CrosshairPinch/`、`FloatingAutoPiP/`、`LivePositions/`。

live 使用主 App ActivityKit 与独立 Widget 扩展，共享秒级 Unix 时间和 Decimal 格式化的内容结构；后台为独立 APNs 推送，不依赖手机进程持续运行。当前后端 `mobile.test_live_activities` **54 项通过（0.251 秒）**；实际线上基线只叠加 9 条允许路径的 317 文件快照 **108 项通过（6.946 秒，0 跳过）**，涵盖 mobile 通知、信号隔离及 scheduler。这两组有重叠，不相加。均使用 SQLite／LocMem、外部 socket 禁用及投递替身，没有真实通知、开平仓、划转或保护单操作。新增迁移仅建独立注册表；隔离库执行 `mobile.0002 → 0003 → 0002 → 0003`，保留原普通通知数据，`makemigrations --check --dry-run` 通过。发布快照、哈希审查与测试见 `.integration-runtime/LivePositions/{package.json,snapshot-verification.json,snapshot-tests.log}`，迁移证据在 `.integration-runtime/activitykit-migration-check.log`。

最终 generic iOS Release 无签名编译通过，主 App 与 `PositionLiveWidget` 同时构建；generic iOS Simulator arm64 的单测／UI 目标 `build-for-testing` 通过，仅编译。最后静态检查发现两套 DEBUG fixture 缺少新增 live 控制器注入，已补齐后重新编译通过，未运行 UI。最终日志为 `.integration-runtime/LivePositions/{release-final.log,unit-compile-final.log}`。macOS 离屏渲染实际共享 SwiftUI 卡片辅助视图，375 × 157 pt 的当前／过期两种布局已查看，过期隐藏金额；这不是 iOS 截图或真机 UI 验收。本轮未启动模拟器、未上传 TestFlight。新签名包的 PiP 自动切出／placeholder、锁屏与灵动岛、APNs 后台实际送达、系统刷新预算及手势体感仍需 iPhone 验收。线上发布事实另见 [运维](operations.md#live-后台持仓卡片限定发布2026-11-03)，使用与生命周期见 [持仓浮窗](ios-floating-positions.md)。

## 信号红点与通知分流回归（2026-11-03）

信号红点只保存本机服务器／用户的最新与已读 ID；普通模式前台最新一条探测与可见列表复用，后台／带单停止。账户卡统一黄色、余额标题和数字间距 4 pt，下方钱包间距 18 pt；持仓三项页签宽度收至 248 pt。模式入口使用当前模式品牌色。接口暂停外部 HTTP 接收，普通消息仅 App，已排队外部／Echo 普通信号取消，开平仓暂停也覆盖已移交的 App 记录。

直接编译实际 `USDTStore` 的 macOS host 包 **5 项通过（0.017 秒）**，覆盖重启恢复、打开清除／新 ID、服务器／用户／模式隔离、旧响应／取消和非法 ID。当前后端 SQLite／LocMem、外部 socket 禁用的定向回归 **87 项通过（14.967 秒，0 跳过）**；针对真实线上基线构建的 314 文件限定快照另有 **70 项通过（6.802 秒）**，两组部分重叠，不相加。旧外部 APNs 接受及入站／分流先以失败断言复现。证据在忽略目录 `.integration-runtime/SignalUnreadBadge/`、`SignalNotificationPolicy/`、`SignalBadgePolish/`。

最终 generic iOS Release 无签名编译和 generic iOS Simulator arm64 单测／UI 目标 `build-for-testing` 通过；后者只编译，未启动模拟器或执行 XCTest／UI。另从当前生产解析器与原 XCTest 方法提取的 macOS host 路由测试 **3 项通过（0.003 秒）**，覆盖普通／带单、缺失／非法模式及旧外部 route／source 载荷拒绝；不代替系统通知委托实测。浅深黄色、点击范围、红点实机及新通知点击仍待新包验收；本轮没有发送测试通知或执行真实交易／资金操作。服务端版本和实际验收见 [运维](operations.md#外部接收暂停与-app-通知分流2026-11-03)，当前交互见 [页面对照](ios-web-parity.md)。

## 持仓文字页签、方向标记与行情编辑图标（2026-11-03）

持仓页签改为选中 20 pt 粗体、未选中 15 pt 灰字及 4 pt 高圆角黄短线，保留等宽 44 pt 点击区。行情编辑图标按用户 SVG 原路径绘制，适配浅深正文色和 44 pt 点击区。当前持仓 K 线添加固定 10 pt 红 S／绿 B，复用当前持仓读取及原生交互变换，清仓后移除；价格标签重叠时沿原方向避让。时间锚点现用接口的本地订单创建时间，精确成交时间限制见 [行情](market-data.md#当前持仓方向标记2026-11-03本地)，样式见 [页面对照](ios-web-parity.md#顶部选择器与时间筛选2026-11-03本地)。

从当前文件提取实际标记筛选、日期解析、二分定位及坐标投影，在 macOS host 包运行 **6 项测试通过（0.009 秒）**，包括非零活动仓／方向／清空、ISO 与秒毫秒时间、真实桶边界和缺口、2／3 倍屏及平移缩放下固定尺寸、价格标签避让、离屏不吸附。初次 host 编译暴露 Foundation 的 CGRect 重载解析失败，显式导入 CoreGraphics 后通过；没有替换被测算法。最终 generic iOS Release 无签名编译，以及 `TradeTool` 单测／`TradeTool Chart Calibration` UI 目标的 generic iOS Simulator arm64 `build-for-testing` 均通过，未执行 iOS 测试；编译日志与 host 包在忽略目录 `.integration-runtime/PositionMarkers/`。

按用户偏好未启动模拟器，浅深页签／SVG、B／S 字号和持续拖动的视觉效果待新包实机验收；本次没有真实交易、资金操作或后端变更。沿用用户“先不提交”要求保留当前及此前工作区改动，未提交、推送、部署或上传 TestFlight。

## 策略卡片选择与绿色统一（2026-11-03）

策略卡片改为直接保存选择，移除独立“使用”按钮及选择确认弹窗，右下角“编辑 ›”为独立按钮；已选策略保留黄框和标题行对勾。选择后只重读策略列表，读取序号避免首屏旧响应覆盖新选择，scope 校验阻止跨账户回写；手动止盈不把未加载的空列表误判为已保存。浅色头像／余额卡统一绿渐变，深色分支保持原样；开多、选止损提示与 auto 共享 `BinanceTheme.positive`，不改变交易计算及开空色。当前界面规则见 [页面对照](ios-web-parity.md#策略编辑与指标设置2026-11-03)。

从当前生产文件提取 `USDTStore`／`JSONValue`，仅替换传输层的 macOS host 包运行 **2 项回归通过（0.015 秒）**，覆盖先前页面响应晚到及账户切换隔离。generic iOS `Release` 无签名编译通过，`TradeTool` 单测目标及 `TradeTool Chart Calibration` UI 目标的 generic iOS Simulator `build-for-testing` 均通过；UI 用例已同步整卡不进编辑、独立编辑及删除断言。初次测试目标编译因磁盘空间不足失败，清理可重建的缓存后重试通过，未删除源码或验收记录。证据位于忽略目录 `.integration-runtime/StrategyCardSelection/`，host 包不会加入交付源码。

按用户偏好未启动模拟器、未执行 iOS XCTest／UI 或真机验收，卡片点击区域和浅深视觉效果仍待新包确认。本轮按用户要求只保留本地，不提交、推送、部署或上传 TestFlight，无真实交易／资金操作。

## 仓位通知暂停回归（2026-11-03）

新增三个回归先复现旧版在总开关关闭时仍领取投递／调用 sender：覆盖无数据库访问的 dispatcher 拦截、有效凭据下直接 sender 拦截，以及真实事件／外部投递在暂停期间保留 status、attempt_count、next_retry_at 并在恢复后各发送一次。实现为 `TRADE_NOTIFICATION_ENABLED` 对两个 dispatcher／直接 sender 的前置保护，原事件保存和订单逻辑保持原样。

以 47.80.22.243（首尔服务器）实际 `app-push-privacy` 为基线，仅叠加三个通知／配置文件、回归和环境模板，`positions.test_notifications` 在 SQLite／LocMem、禁止外部 socket、网络替身下 **39 项通过（5.408 秒）**。313 个发布文件逐项核对，允许差异仅五个路径；证据在忽略目录 `.integration-runtime/TradeNotificationsOff/`。发布后 API 和 scheduler 分别用 HTTP 替身调用实际入口确认返回／拦截、零 HTTP 请求、队列状态不变；没有发送测试通知或执行交易。线上配置及版本见 [运维](operations.md#仓位事件通知关闭2026-11-03)。

## App 通知限定包验证（2026-11-03）

为用户要求的普通通知实测，以实际运行的信号／杠杆限定包为基线，只增加 App 注册／注销、登出停用、HTTP/2 依赖、普通信号派发任务和私钥挂载。新增任务移除后，scheduler AST 与原版完全一致；本机另验证任务间隔为 10 秒且只调用 `dispatch_notifications`，不启动浮盈任务。

在限定源码快照上复用当前 `mobile.test_push` 及基线的连接／信号独立性测试，SQLite／LocMem、禁止外部 socket，Echo 作为独立外发边界替身：**16 项通过（0.063 秒）**。覆盖鉴权注册、账号隔离注销、登出停用、topic／环境／HTTP2、失效 token、重试和租约上限、普通信号仅 App、旧 Echo 队列取消及信号保存独立性。来源 313 个文件哈希逐项核对，仅六个允许路径变化；证据在忽略目录 `.integration-runtime/SignalPushTest/`。实测又复现 HTTPX 默认日志向 root 输出 APNs 请求路径；新增真实 logging 调用回归，httpx／httpcore 改为 NullHandler 且不传播后，限定包最终 **17 项通过（0.063 秒）**，证据为 `tests-final.log`。这些是隔离回归，真实发布与发送结果分别见 [运维](operations.md#app-普通信号通知限定发布2026-11-03) 和 [通知](signals-and-notifications.md#普通通知真机测试2026-11-03)，不等同于手机已收到。

## 策略编辑、指标设置与触摸归属（2026-11-03）

本轮将默认杠杆接到既有只读最大倍数接口；Super 默认填充调为 16%，用连续四边形贴合趋势线，增加持久化透明度；同次长按始终移动十字线，抬手后的新拖动才平移。策略草稿、名称焦点、紧凑数字、列表整行编辑／左滑删除和独立使用按钮已调整，账户按钮与归集按钮同尺寸并对齐，持仓筛选等宽。普通信号只生成 App APNs 投递，浮盈继续独立走 Echobell。实现口径见 [行情](market-data.md#拖动一致性当前价与尾线修复2026-11-03)、[策略与指标界面](ios-web-parity.md#策略编辑与指标设置2026-11-03) 和 [通知](signals-and-notifications.md#ios-信号-app-通知2026-11-03源码规则)。

新增故障回归先复现同触点长按被 pan 接管和信号误入 Echo。自查又以价格轴 2／4 倍放大复现填充越界的四个断言失败，修复为按主图边界交点切分再裁剪。最终 `TradeTool`／`Debug-Seoul` 在 `3E685E56-9767-43E7-81DD-35972DE7FAD7` 实际运行 **158 项通过（24.662 秒，0 失败、0 跳过）**：ChartEngineCore 149、ChartOrderTicket 6、StrategyDraftEditing 3；覆盖历史／实时填充精确端点、两主题真实 Metal 斜边像素和平移、纵向裁剪、透明度旧偏好兼容、独立策略值及默认杠杆的账户隔离。

实际模拟器 UI 四项分轮通过：持仓进入图表及默认／手选杠杆保存；浅深色四列指标卡、Super 滑杆应用后保留、模式／归集按钮宽高和左边缘一致、持仓三项等宽及自有信号不评分；名称直接聚焦、清空减仓仍选中、两个止损值分别输入和添加层级；列表整行编辑、左滑删除及二次确认。初轮发现容器覆盖内部控件标识，已改为独立字段及包含式分组；左滑按钮显式恢复 `.automatic`，避免继承全页 `.plain` 导致不显示。输入测试在字段末端删除并断言实际清空，滚动到固定保存栏上方再切换焦点；滑杆测试核对实际落点的持久化，不假定系统拖动必然精确落在 65%。已实际打开最终浅深图表、指标设置、模式按钮、持仓筛选、策略编辑和左滑截图检查。

后端使用隔离 SQLite／LocMem 和通知替身，`mobile.test_push positions.test_profit_alerts market_analysis.test_notification_independence` **30 项通过（5.740 秒）**，包括旧 Echo 信号记录取消、APNs 关闭仍保存且不回退 Echo，未真实发送通知。最终 generic iOS `Release` 无签名构建通过；未执行真实开平仓、资金划转或保护单操作。

证据在忽略目录 `.integration-runtime/InteractionStrategyReview/`：`before-backend.log`、`before-crosshair.log`、`before-clip.log`、`final-verified-core.log`、`backend-verified.log`、`ui.log`、`ui-verified.log`、`strategy-ui-final.log`、`release-verified.log` 及各 attachments 目录。XCTest 结果在 `.integration-runtime/ChartBusinessBuild/Logs/Test/`。本轮按用户明确授权提交推送全部安全源码，见 [交付记录](changes.md#2026-11-03策略指标交互与通知分流源码交付)；没有追加后端部署或手动 TestFlight 上传，手机触摸／键盘及真实后台通知仍待配套发布验收。

## 图表账户反馈回归（2026-11-03）

用户后续已授权整批提交推送，包含本节及下方顶部控件任务；交付范围见 [变更记录](changes.md#2026-11-03图表账户反馈与顶部控件整批源码交付)。下文未提交状态是本地验证结束时的记录，本次交付沿用既有证据。

本轮修复图表交互矩形、固定右轴当前价、长按转平移、切周期临时尾线与权威快照合并，并调整主题、文案、杠杆前三档、余额手动刷新及资金卡片。实现见 [行情](market-data.md#拖动一致性当前价与尾线修复2026-11-03)、[界面](ios-web-parity.md#图表与账户反馈2026-11-03) 与 [资金](capital-and-transfers.md#原生划转与转账2026-11-02)。

新增三项真实故障回归在修改前均失败：Metal 平移后的空心柱／连续填充像素差异、临时新桶开盘衔接、离屏价格轴位置。修复后 `TradeTool`／`Debug-Seoul` 在 `3E685E56-9767-43E7-81DD-35972DE7FAD7` 实际运行 **181 项通过（38.638 秒，0 跳过）**，覆盖 ChartEngineCore、MarketFastPath、ServerSwitching、RetainedTradeRisk、ChartOrderTicket。包含两主题 GPU 像素平移、历史与未来视口右轴、同触点长按转 pan、快照修正真实 open／报价极值、私有事件不重读余额且显式刷新带 `fresh=1`。旧场景断言同步为新的轴内价格标记和完整绘图区虚线，未删除或跳过必过回归。

`TradeTool Chart Calibration` 的实际持仓／杠杆保存流程通过（27.702 秒）；最终图表账户两主题与资金三页签／方向流程 **2 项通过（102.402 秒）**，验证多余档位被裁到前三、确认后外部倍数、余额刷新可点、合约余额与保留额分别展示、转账仅一处金额、浅黄／浅蓝模式按钮。初轮资金断言误期望整数 `100`，按统一格式器修正为 `100.00` 后通过。已打开最终浅深截图核对提示绿色、Super 填充、MACD、星标、止盈浅绿框、弹窗同底色和两行资金卡；没有以存在控件代替视觉检查。generic iOS Release 无签名构建通过。

后端本地隔离 SQLite／LocMem 和交易所替身 **36 项通过（0.830 秒）**；实际线上基线组合出的限定包再次运行信号、通知独立入库、杠杆与鉴权相关 **26 项通过（0.752 秒）**，迁移一致性检查无遗漏。两组用例重叠，不能相加为独立测试数。后端限定发布与生产只读验收见 [运维](operations.md#信号入库与杠杆金额限定发布2026-11-03)；未执行真实开平仓、划转、撤保护或外发通知。

证据统一在忽略目录 `.integration-runtime/ChartAccountFeedback/`：`before.log`、`final-core.log`、`final-ui.log`、`release-build.log`、`backend.log`、`limited-backend.log`、`limited-schema.log`、`FinalScreenshots/` 与发布／只读验收记录。XCTest 结果保留在 `.integration-runtime/ChartBusinessBuild/Logs/Test/`。本轮未提交、推送或上传 TestFlight，真机拖动流畅度、显示及下一次自然信号仍待新包验收。

## 持仓顶部控件与周期选择（2026-11-03）

本地新增持仓页左侧原生分段选择器、选中项 16 pt 粗体与右侧浮窗图标；信号与持仓顶栏统一 44 pt，历史日期筛选及图表周期面板使用紧凑圆角选项。浮窗沿用已有共享偏好与 overlay，不新增请求任务。实现口径见 [页面对照](ios-web-parity.md#顶部选择器与时间筛选2026-11-03本地) 和 [浮窗](ios-floating-positions.md)。

当前共享工作区执行 `TradeTool`／`Debug-Seoul` 的 generic iOS Simulator arm64 `clean build-for-testing` 通过，客户端与单元测试目标均成功编译；同步删除图表回归 fixture 中 `MarketCandle` 不支持的 `closed` 参数。证据在忽略目录 `.integration-runtime/PositionHeaderReview/build-clean-verified.log`。本轮没有启动模拟器或执行 XCTest／UI，不把编译当成交互或截图验收；浅深色、窄屏原生分段控件及图标与菜单同步仍待新包实机确认。本次追加界面改动未提交、未推送，没有后端发布或真实交易操作。

## 持仓线颜色、固定宽度与模式按钮（2026-11-03）

持仓开仓标签按未格式化 Decimal 浮盈的正负同步切换文字、边框与虚线颜色；持仓标签固定 120 pt，不再以每次实时金额重新测量。账户模式按钮改为双向切换图标和“带单／合约”短文案。现行样式见 [行情](market-data.md#价格轴与图内订单标签2026-11-02)、[原生界面](ios-web-parity.md#账户与资金面板2026-11-02) 与 [带单模式](lead-trading.md#使用范围)。

先新增真实 SwiftUI `ImageRenderer` 像素回归，在原实现复现 **4 个失败断言**：正负盈亏框仍为品牌色，三种金额导致三种宽度。修改后完整 `ChartPositionContextTests` **9 项通过（0.054 秒）**；新用例直接渲染生产覆盖层，检查正负及大数位下开仓／止损框等宽不跳动，分别检查文字与边框绿／红像素，保留原持仓身份、价格择源及旧响应隔离回归。像素缓冲区通过受限指针生命周期读取。

真实模拟器 UI **2 项通过（75.577 秒）**，覆盖模式确认及双向切换、实际持仓 K 线、只读止损和浅深色展示；已打开普通／带单按钮和浅深色图表截图核对。generic iOS Release 未签名编译通过；证据为忽略目录 `.integration-runtime/PositionLabelReview/{Before,Final,UI}.xcresult`、`release.log` 与 `Attachments/`。本轮没有真实交易、资金或后端发布操作；源码按前文授权提交推送，TestFlight 与手机新包待验。

## 持仓卡片与 K 线持仓显示（2026-11-03）

右上角双蜡烛图标替代卡片左下角 K 线入口，普通持仓三项操作等宽；持仓操作统一显式淡入淡出。K 线页持仓按钮使用既有币安黄底／深色字，止损金额改为正常文字颜色的只读数值。卡片正文核对无独立绑定策略名称；完整样式见 [原生界面](ios-web-parity.md#持仓卡片操作区2026-11-03)。`webModal(item:motion:)` 增加可选动画参数，默认仍由共用容器按高度选择，本次持仓操作明确传入 `.fade`。

真实模拟器定向 UI **3 项通过（93.764 秒）**，覆盖图标位置、三按钮宽高、卡片不显示绑定策略名称、持仓／K 线往返、实际持仓字段与只读止损金额、浅深色截图、策略／保本损／止盈弹窗，以及未持仓的止损设置、市价初筛和限价确认。初次验证的新金额断言未按已有显示精度书写，另有旧测试的上方点击点仍低于替身当前价；修正断言为 `10.000 U`，将点击移至替身价格范围顶部后，保留原多空／确认断言并通过。只调整测试坐标，没有修改选价或交易计算。

`AppearanceTests` **7 项通过（0.627 秒）**，包含显式淡入淡出优先级与共享外观检查；generic iOS Release 未签名编译通过。证据位于忽略目录 `.integration-runtime/PositionCardReview/`：`UIFinal.xcresult`、`Appearance.xcresult`、`release.log`；已实际打开最终浅深色持仓卡片、日志弹窗及 K 线持仓截图核对。本轮为本地替身验证，不执行真实交易或资金操作，不代表 TestFlight 或 iPhone 实机通过；源码按本次授权提交推送，手机新包待验。

## 图表持仓杠杆与通知回归（2026-11-02）

用户随后明确授权提交并推送，本节记录本地验收当时的结果；51 个文件已纳入本批源码交付，范围见 [变更记录](changes.md#2026-11-02图表持仓杠杆选择与通知源码交付)。此次交付沿用既有验证，不重复运行测试或部署后端。

本轮按用户确认停止旧构建排障，调整图内短标签、实际持仓下单栏、蓝灰模式按钮、透明右轴及纵向适配、MACD 增强实心／衰减空心、前三档杠杆选择。杠杆选择进入市价／限价的冻结草稿和服务端持久化请求，提交前验证档位与可开上限，已有持仓不因面板选择而改变。界面及接口见 [原生页面](ios-web-parity.md)、[行情](market-data.md) 与 [交易安全](trading-safety.md)。

完整 `TradeToolTests` 在独立 `EC99818A-F4D6-43BF-A460-3918A9385BBC` 模拟器实际运行 **267 项通过（49.115 秒，0 跳过）**，证据为 `.integration-runtime/ChartBusiness/TestsFinal.xcresult`；包含新增正负 MACD 历史／实时柱、图内标签／浮盈、纵轴随高度适配和冻结杠杆意图回归。不是只编译测试目标。

后端隔离 SQLite／LocMem 与交易所替身的广泛回归 **331 项通过（154.014 秒）**；随后通知、信号及交易选档相关补验 **46 项通过（7.376 秒）**，内部信号读取／既有路由补验 **11 项通过（0.753 秒）**。最终新加旧杠杆缓存升级回归，原代码复现 `TypeError: str object is not a mapping`；缓存键升级后完整杠杆文件 **11 项通过（0.012 秒）**。证据依次为 `chart-business-backend-final.log`、`chart-business-backend-followup.log`、`chart-business-signals-read-final.log` 和 `chart-business-leverage-cache-{before,after}.log`，均在忽略目录 `.integration-runtime/`。部分用例重叠，不能相加为独立测试数；SQLite 结果不代表 MySQL 并发已验收。

共用大面板沿用项目贴底 `WebSheet`，高度统一为可用容器 80%。验证中修复键盘高度重复计入底部留白、归集页签父容器覆盖子按钮标识及短动画期间读取 footer 的竞态。最终 `TradeTool Chart Calibration` 的四项真实模拟器 UI 流程 **全部通过（125.650 秒）**，覆盖行情搜索自动键盘／自选和开仓入口不聚焦、选币回调、实际持仓字段、杠杆点选保存、归集三页签／方向切换、浅深色与止损关闭。已打开最终截图核对键盘下列表、纵排卡片、归集固定底栏及持仓数据。结果为 `ChartBusiness/UIFinal.xcresult`，截图位于同目录 `UIFinalAttachments/`；前期失败包保留用于排障。最终 generic iOS Release 未签名构建通过，日志为 `chart-business-release-verified.log`。

信号未入库已复现为缺旧通知出口时扫描整轮退出，修复后入库及独立通知事件不再依赖旧出口；APNs、Echobell 和原 USDT 浮盈阈值移植使用替身验证，详见 [通知](signals-and-notifications.md)。用户随后提供 Echo 地址，且找到与当前工程团队匹配的原 iOS APNs 密钥，已完成本地和 47.80.22.243（首尔服务器）的受限配置准备；没有重启服务或部署通知源码，当前进程尚未加载。迁移一致性检查无缺项。本轮未执行真实交易、资金操作或外发通知，未提交、推送或上传 TestFlight；iPhone 16 Pro Max 的键盘、弹窗与后台通知仍待新包及配套后端上线验收。

## 构建 25 反馈后的测试越界修复（2026-11-02）

用户报告刚推送的客户端版本再次失败，并提供构建号 25。以 `cafc053` 为源码基线，使用 Cloud 的 `TradeTool`／Debug 测试方案在独立 `TradeTool Cloud Test Repair`（iPhone 18 Pro／本机 iOS 27.2）实际运行完整单测；**263 项中 261 项通过、2 项因测试进程数组越界崩溃失败**。不是再次把 `build-for-testing` 当成测试通过。

失败为 `testChartSceneBuilderBuffersNearLiveTailWithOffscreenMarker` 与 `testChartSceneBuilderShowsFullPriceReferenceInHistoricalViewport`。价格参考线限制到绘图区后，返回最新标记贴右边界时只有一条可见虚线；旧测试仍假定两段线、无条件读取 `priceLines[1]`，并把线端点断言为整张画布边界，导致 `Index out of range`。本次仅修改测试：改为检查虚线与标记在同一水平线上、全部位于绘图区、合起来无缺口无重叠地覆盖整个绘图区，并保留最多两段虚线约束；不恢复覆盖价格轴的旧画法，也不跳过测试或降低 Cloud 必过门槛。

同一方案、设备与配置重新实际运行完整 `TradeToolTests`，**263 项全部通过（49.171 秒，0 跳过）**，包含 Metal 离屏、十字光标、指标、持仓缓存、账户隔离及回环网络测试。初次失败证据为 `.integration-runtime/CloudBuild25/Before.xcresult`，修复后为 `After.xcresult` 及对应日志／JSON 摘要。仅测试文件改变，本轮未重复 Release 归档、UI 流程、实机或交易测试，也未部署后端。

GitHub 对 `cafc053` 的公开 Xcode Cloud check 已显示 Archive 成功、0 errors；本次读取时 Test 仍为 in progress，尚无失败 annotations。前一提交 `d533b19` 的 Test 与 Archive 均显示成功。公开 check 没有可确认的构建号字段，因此不能把本地两项崩溃直接写成已取得构建 25 的云端日志；本轮已修复同一源码测试链中的确定失败点，Cloud 编号映射、修复后的云端运行与 TestFlight 分发仍需核验。用户随后授权提交并推送本轮测试修复和文档至 `codex/integrated-ios`；本次源码交付沿用上述 263 项实际运行证据，不另行部署或手动上传 TestFlight。

## 十字光标标签与杠杆面板回归（2026-11-02）

时间标签缩高并按字形居中，右轴标签移除加号／分隔线、统一圆角和文字右对齐位置；自动杠杆改为满宽卡片纵向排列及固定“确定”按钮。两个真实场景回归在原源码下先复现 91 个失败断言，修改后在 host Swift Package **2 项通过（0.084 秒）**，覆盖 320／390／440 pt、2 倍／3 倍屏、主图及副图的标签高度、居中、圆角、无加号控件、完整数字和轴内边界。验证器直接编译生产图表数据／场景／CoreText 字形代码，不是 GPU 像素或手机验收。

杠杆接口新增实际 URL 鉴权／拒绝 POST 回归；当前工作区与限定发布包分别用 SQLite／LocMem 和交易所替身运行档位、适配器首档兼容、带单测试，均 **31 项通过**（6.798 秒／6.739 秒）。generic iOS Release 未签名构建通过；单测／UI 目标 `build-for-testing` 通过，仅编译，不启动模拟器。既有 UI 用例已增加卡片满宽／纵排及底部确定按钮的断言，尚未实际运行；iPhone 标签观感与弹窗布局仍待新包验收。证据在忽略目录 `.integration-runtime/CrosshairLeverage/`，服务端发布与实读结果见 [运维](operations.md)。客户端本轮未提交、推送或上传 TestFlight。

## 开仓面板与持仓切页回归（2026-11-02）

本轮调整开仓信息区底色／高度／分隔线、订单线与合并价格标签、模式切换配色、行情搜索焦点和划转方向菜单；页面规范见 [原生界面](ios-web-parity.md#k-线下单区域2026-11-02)，图表边界见 [行情](market-data.md#价格轴与图内订单标签2026-11-02)。持仓页首次访问后常驻根页面，列表按页签／筛选保留内存快照和分页，事件、主动刷新、前台恢复及账户隔离见 [持仓切页](ios-web-parity.md#持仓切页与内存快照2026-11-02)。

新增 `PositionPageReuseTests` 六项，覆盖反复进入的请求次数、跨页签恢复和分页、交易事件与强制刷新、失败保留／重试、重置／账户代际及恢复快照后拒绝其他页签晚到结果；旧模型实际复现五个用例、九个断言失败。图表新增绘图区裁剪回归（320／390／440 pt、2 倍／3 倍屏），补充离屏当前价线条边界并同步原生产场景断言；把旧场景源码放入同一隔离检查器，可复现三项用例共 23 个断言失败。

host Swift Package 直接编译生产 `USDTPageModel`／`USDTStore`、JSONValue、完整图表数据／指标／场景／CoreText 字形代码，复用上述六项与三项图表测试方法，最终 **9 项全部通过（0.125 秒）**。网络请求外壳使用替身，不涉及真实账户。证据在忽略目录 `.integration-runtime/TradingPanel/`。该结果验证模型和场景数据，不是 GPU 像素、iOS 交互或手机截图验收；本轮按用户偏好不启动模拟器、不执行 iOS XCTest／UI。

generic iOS Release 未签名构建及 `TradeTool Chart Calibration` 的 generic iOS Simulator `build-for-testing` 均通过；后者仅编译单测和 UI 目标，不运行模拟器。共享选币 UI 用例增加行情入口自动键盘、自选／开仓入口不聚焦的断言。浅深色观感、小屏布局、iPhone 触摸与焦点行为仍待新包实机验收。本轮保留本地修改，未提交、推送、后端部署或上传 TestFlight，未执行真实交易。

## 云端构建图表断言修复（2026-11-02）

用户反馈连续三次构建失败，提供的 Cloud 截图可见构建 22：Archive 成功、Test 失败。原始三项定向测试在当前 `3fb1859` 基线实际运行：图例完整性、离屏价格标记边界两项失败，底栏四项顺序已通过；截图中的五项底栏对应旧实现，云端具体构建与提交映射尚未从后台核实。首次结果保存在 `.integration-runtime/CloudBuild22/Before.xcresult`，不能以此前 `build-for-testing` 成功替代实际测试结果。

先增加两项真实场景回归，修复前共复现 34 个断言失败：`testIndicatorLegendsPreserveEveryValueAcrossWidthsAndDisplayScales` 覆盖 320／390／600 pt、2 倍／3 倍屏、实时和十字线图例的全部指标、字形数量与边界；`testOffscreenPriceMarkerStaysInsidePlotAcrossDisplayScales` 覆盖两种倍率和两个历史视口。修复内容见 [行情与图表](market-data.md#图例完整性与离屏价格边界2026-11-02)，保留原失败断言，没有跳过用例或关闭 Cloud 必过测试。

独立 `TradeTool Cloud Test Repair`（iPhone 18 Pro／iOS 27.2）使用 `TradeTool`、Debug-Seoul、关闭并行和覆盖率实际运行完整 `TradeToolTests`：**255 项全部通过（43.307 秒）**，含核心图表 138 项、Metal 离屏／十字线遮盖／一万次移动、行情快速路径、真实回环 WSS、持仓与账户隔离测试。证据为 `.integration-runtime/CloudBuild22/AllUnitTests.xcresult` 及对应日志；测试使用替身／回环，不执行真实交易。该结果是本地模拟器 XCTest，不代表新 Cloud 构建、TestFlight 分发或实机通过；Release 编译与源码交付状态见 [变更记录](changes.md#2026-11-02云端测试失败修复)。

## 图表下单与周期回归（2026-11-02）

图表复用标准 USDT 开仓流程，行为见 [页面](ios-web-parity.md#k-线下单区域2026-11-02)，确认与估算边界见 [交易安全](trading-safety.md#图表与标准开仓共用流程2026-11-02)。新增 `ChartOrderTicketTests` 五项覆盖 Decimal 金额／费用、无效和相等止损、方向变化、确认快照／原命令字段、限价线交叉、不同屏宽／比例下的正方形价格绘图区及快捷周期偏好。

`ChartOrderTicketTests`、`ChartEngineCoreTests`、`MarketFastPathTests` 共 **162 项通过（41.147 秒）**。后端 `manage.py test market_stream --noinput` 共 **73 项通过（最终隔离源码 8.681 秒，5 项独立 Redis 条件跳过）**；新增 3m 聚合和不调度不受支持统计的回归先失败再修复。首轮全量暴露旧任务数断言仍为六个，更新为七个后通过。隔离 SQLite／LocMem 与交易所替身不能代表 MySQL 并发或出口长稳。

专用 `Chart Order Review` 模拟器验证布局、周期编辑、主图十字线、限价线拖动与共用止损／开仓确认，测试只取消确认。首轮发现校准 fixture 缺少 AppContainer 环境导致崩溃，以及父容器无障碍标识覆盖子按钮；已补齐 fixture 并将容器设为独立分组。第二轮修正布局断言的浮点误差，并为确认流程单独指定资金已就绪 fixture；一轮补测在启动前因专用模拟器关闭导致 runner 超时，保留失败证据。最终从仅含本任务的源码快照验证：三项 UI 全部通过（121.981 秒），generic iOS Release 未签名构建通过；截图复核后将确认框的费用合计按已有 Decimal 金额工具保留两位，随后仅补构建。Release 及最终 UI 证据保存在忽略目录 `.integration-runtime/ChartTicket/`；不作为 TestFlight 或手机验收。

2026-11-02 后续底栏样式调整仅作编译验证：两行信息、含手续费开关、方向按钮同 K 线色、铺满底部安全区、选币系统档位及周期短下划线已接入。原 USDT 计算和提交函数未修改；从当前 Git 基线提取本任务三份源文件的隔离快照，generic iOS Release 未签名构建通过，证据位于 `.integration-runtime/ChartTicketPolish/release-build.log`。按用户“简单调整不启动模拟器测试”的偏好，本轮未启动模拟器或重跑单测／UI；iOS 26 大尺寸交易对面板、不同屏宽排布及实机手势仍需新包验收。

## 图表持仓上下文与杠杆回归（2026-11-02）

行为与接口见 [页面](ios-web-parity.md#k-线下单区域2026-11-02)、[行情](market-data.md#图表持仓线与杠杆档位2026-11-02本地) 及 [交易安全](trading-safety.md#图表与标准开仓共用流程2026-11-02)。新增 `ChartPositionContextTests` 六项，覆盖币种／零数量／关闭过滤、市价止损择源、已挂市价与限价止盈、非法价格、多空标识、页面重置及账户切换拒绝晚到响应。使用 host Swift Package 编译实际 JSONValue、USDTStore、持仓模型和价格线数据模型，只有网络／事件依赖使用替身；复用六个测试方法全部通过（0.012 秒）。

`trading.test_leverage_brackets`、原适配器首档兼容测试与 `trading.test_lead_mode` 共 **30 项通过（6.976 秒）**。SQLite／LocMem 与交易所替身覆盖全部档位精度、只读调用、缓存命中、用户／模式／绑定隔离、读取中重新绑定、无绑定、失败／空数据、非法参数和 POST 拒绝，不执行真实交易所写入。

generic iOS Release 未签名构建、`TradeTool` 单测目标及 `TradeTool Chart Calibration` UI 目标的 generic iOS Simulator `build-for-testing` 均通过。新增 UI 用例覆盖持仓按钮／三条价格线、标准图表导航、杠杆卡片和空设置页；本轮仅编译，没有启动模拟器或执行 iOS XCTest／UI，也没有截图、实机或 TestFlight 验收。证据在忽略目录 `.integration-runtime/ChartPositions/`。本轮未提交、推送或部署；新杠杆接口需配套发布后才可在线使用。

## 持仓逆势建议与底栏回归（2026-11-02）

活动持仓建议与四项底栏规则见 [页面说明](ios-web-parity.md#持仓估值与四项底栏2026-11-0211-04-更新)。新增 `PositionTrendAdviceTests` 八项，覆盖多空方向的双条件、均线相等／交错、三个高周期真实指标计算、数据不足／过期／近期缺口、未收盘线反转、账户切换后旧响应拒绝、取消清理及失败后移除旧建议。既有底栏断言同步四项；登录 UI 检查的未绑定下单禁用断言改至 K 线下单区，独立开仓表单 fixture 继续用于共用组件检查。

本轮通过 host Swift 检查器执行上述八项逻辑：复用测试方法、生产 EMA／Supertrend 计算器及完整建议模型；仅 API 协议／请求外壳为本地替身，Supertrend 绘图插件未纳入 host 编译。八项全部通过。最终 generic iOS Release 未签名构建，以及 `TradeTool Chart Calibration` 的 generic iOS Simulator `build-for-testing` 均通过，后者只编译单测与 UI 工程，没有启动模拟器或执行 XCTest／UI 用例。证据位于忽略目录 `.integration-runtime/PositionAdvice/`。未执行真实交易、后端部署、TestFlight 上传或实机验收；本轮未执行提交与推送。

## 持仓市价与浮盈实时回归（2026-11-02）

`PositionLiveValuationTests` 新增十项：逐条 ticker 同步市价／盈亏且忽略接口旧 `pnl`、减仓剩余量和加仓后均价、空仓方向、杠杆不重复相乘、小币价 Decimal 精度、零／未知数量、旧协议数量回退、乱序／非法／非持仓币种过滤、账户代际／旧任务清理、断线／重连清理及延迟／未来包过滤。`AppearanceTests` 原真实回环 WebSocket 订阅用例同步加入持仓币种优先级，覆盖自选／搜索／恢复订阅后保留持仓与所选开仓币种；本轮只编译该用例，没有执行。

本轮使用 host Swift 检查器复用上述十项测试方法，编译真实 `PositionLiveValuation`／`PositionLiveQuotes`、从生产文件提取的 JSONValue／事件模型及 JSON 扩展，十项全部通过。generic iOS Release 未签名构建、generic iOS Simulator `build-for-testing` 均通过；没有启动模拟器或执行 iOS XCTest／UI。证据保存在忽略目录 `.integration-runtime/PositionRealtime/`。官方限流与展示范围核对结果归并至 [行情说明](market-data.md#持仓市价与浮盈推送限流边界2026-11-02)；手机网络下的刷新、断线恢复及新包实机仍待验收。本轮未执行提交、推送、后端部署或 TestFlight 上传，也未发起真实交易。

## K 线协调与出口保护回归

构建 13／14 速度排查新增 `HistoryFastPathTests.test_cold_first_page_does_not_materialize_unused_history`，在实际 `load_history` 冷读路径填入 3001 根并检查只物化所需 1500 根，同时核对返回窗口和非 stale 状态；修复前断言为 `3000 != 1500`。2026-11-01 使用下文临时 Redis 配置执行 `manage.py test market_stream --noinput`，58 项全部通过。这一步仅本地后端窗口减量，未部署；随后新增持久诊断，见下节。隔离源码副本上的 4 轮首帧 UI 对照和 36 个进入样本见 [行情排查](market-data.md#构建-1314-速度回退排查2026-11-01)，不能用它替代手机 TestFlight 13／14 的验收。

2026-11-01 本地实现及待发布范围见 [行情](market-data.md#读取协调与出口保护2026-11-01本地)。回归先复现同历史重建、刷新丢旧分页和首屏／恢复重复读取，再验证对象与指标复用、旧页及修订保留、取消／旧 epoch、并发快照／分页／配置一致性，以及 historyPending 等待通知。

专用模拟器 `A9B09AF9-195A-4F50-B706-7F07A0EB4CD4`、Debug-Seoul、关闭覆盖率及并行测试：`ChartEngineCoreTests` 131 项加 `MarketFastPathTests` 20 项全部通过（30.903 秒，`.integration-runtime/KlineCoordination/IOSVerified.xcresult`）。本轮未重新采样首帧、执行业务 UI 或安装手机。

后端 `market_stream.tests market_stream.test_fast_path market_stream.test_coordination common.tests mobile.tests` 共 196 项通过（8.807 秒，`KlineCoordination/backend-verified.log`），显式指定独立临时 Redis，无相关跳过。覆盖窗口合并与等待到期、缓存失联、公共 REST 共享预算失败时不出站、已知冷却任务不领取、独立 Redis 客户端共享滚动建连预算／封禁、无共享进程锁时的 owner lease、短连接退避、主动轮换与取消，以及慢发送／队列满／订阅超时／Redis／无效事件／过期／正常断开的诊断与资源清理。首轮故障测试暴露超时取消竞态，真实 Redis 测试暴露冷却 Lua 语法问题，修复后重跑通过。

调用命令与下方既有行情回归相同，只需加入 `market_stream.test_coordination`；所有交易所访问使用替身，无真实交易或生产限频试验。generic iOS Release 构建结果与最终静态检查见 [变更](changes.md)。Redis 共享接口测试不代替 MySQL 事务、真实 NAT 全流量及长稳验收。

连续纵轴适配已在本地接入：横拖／捏合／惯性按显示帧合并，单个交互场景在途，新场景保持手指基准和惯性时钟；主图／MACD 复用同一场景映射。`ChartEngineCoreTests` 新增 5 项真实 UIKit 宿主回归，包含回到起始比例时覆盖中间请求；模拟器使用 `ChartCalibrationUITests.testContinuousScalePinchPanAndCrosshairFixture` 和 `--chart-calibration-fixture`，无需账号或真实交易。离线优化基准保留 20 次预热、500 次采样及源码哈希，范围和结果见 [行情主文档](market-data.md#连续纵轴适配2026-11-01本地实现)。完整核心、UI 与 Release 的实际结果见 [变更](changes.md)；Mac／模拟器不能代替 iPhone 60／120 Hz、功耗及实时行情并发 A/B。

## 历史仓位加载回归（2026-11-01，隔离验证）

`positions.test_review_fixes` 的快照回归覆盖不访问交易所、不写结算、无需补查的已结算页、重试退避、外部手动仓估算，以及日期／分页／用户／模式／Key 隔离。先运行新增两项检查复现失败，再修复；原 `positions.tests` 保留部分平仓、真实零费用、结算修复和每次最多两笔的回归。

```bash
PYTHON_DOTENV_DISABLED=1 DB_ENGINE=sqlite USE_REDIS_CACHE=False RUN_SCHEDULER_IN_WEB=false \
  server/.venv/bin/python server/manage.py test positions.test_review_fixes positions.tests --noinput
```

最终组合 **106 项通过（45.430 秒）**，包含五项新增快照边界检查。SQLite／LocMem 和全部交易所替身仅用于隔离验证。

客户端定向入口为 `TradeToolTests/PositionHistoryLoadingTests` 和 `NativeIntegrationTests`：10 项通过（1.832 秒），覆盖本地先显示、旧服务端兼容、解绑清空、切页、取消和补查失败保留记录。UI 使用 `WebParityUITests/testAllUnboundPositionTabsOnlyShowBindingPrompt`、`testBoundHistoryShowsRecordsWhileExchangeSupplementIsSlow`、`testAllPositionTabsRefreshFromEmptyLists`，最终三项通过（62.433 秒），已检查截图；generic iOS Release 未签名编译通过。证据保存在忽略目录 `.integration-runtime/PositionHistory/`；后端已配套部署，手机新版安装、实际绑定账户与真实网络耗时仍待验，初轮失败及修复见 [变更记录](changes.md)。

## 自选与共用交易对回归（2026-11-01）

`market_stream.test_symbol_catalog` 先复现旧搜索响应缺少五个客户端必填分页字段，再验证修复；覆盖采集器筛选／持久化／下架、空快照保留及缓存丢失后读数据库，列表请求不访问 Binance。与 `market_stream`、`positions.test_review_fixes`、`positions.tests` 组合 **177 项／57.324 秒通过，5 项独立 Redis 条件跳过**；SQLite／LocMem／交易所替身不等于生产 MySQL 验收。

`WatchlistInteractionTests` 覆盖自选增删、隐藏项不参与排序、旧固顶偏好兼容、用户持久化、共享目录缓存和刷新失败保留；与历史／原生接口检查 12 项通过（1.893 秒）。追加 `RetainedTradeRiskTests` 与真实 loopback WSS 检查两项通过（0.528 秒），验证账户核对不清空旧值、相同风险额不发布，选中币种在超过 200 个候选、自选删除／搜索退订及切币种时持续收到所需报价。

UI 用 DEBUG 无网络业务替身：原生排序手柄实际长按拖动并核对顺序、移到顶部；三个交易对入口、自选添加／取消删除／确认删除、过滤和开仓选币；开仓／我的共用止损滑杆与固定按钮、默认头像和紧凑绑定按钮；协议／隐私 X 关闭返回注册表单。首轮纠正搜索可访问名称与父容器覆盖关闭标识，系统删除确认改为显式“取消／删除”警告框。图表退订／恢复的补查复现了并发发送订阅乱序，已按连接串行发送；扩展 `AppearanceTests`／`MarketFastPathTests`／自选与风险回归共 31 项通过（19.332 秒），覆盖旧连接失效及真实 loopback 的最终订阅。最终四个 UI 流程分别通过；共享流程 30.172 秒，原生拖动最终 12.013 秒，其余见 `.integration-runtime/PairPicker/` 的结果包。已查看截图。generic iOS Release 未签名构建最终通过，迁移漂移检查通过；生产目录及只读 HTTP／WSS 验收见 [变更](changes.md)；本地结果不表示 TestFlight／手机完成。

### 交易对名称与自选操作分离（2026-11-02）

追加 `WebParityUITests.testPairNamesOpenChartsWithoutChangingWatchlist`，覆盖行情搜索／编辑添加入口点名称打开图表、图表顶部下拉复用完整列表、未自选币种查看后仍未自选、按钮添加／取消删除／确认删除及切币后状态保留。DEBUG 行情替身补齐实际图表导航和本地合成 K 线；图表校准替身提供共用目录及环境对象。本轮属于简单交互调整，遵守用户偏好只编译，不启动模拟器运行回归；实际编译和交付范围见 [变更记录](changes.md)。

## 后端主链瘦身回归（2026-11-02）

实现、扫描范围和未实施项见 [架构](architecture.md#后端扫描与主链瘦身2026-11-02本地) 与 [行情实施进度](market-data.md#websocket-优先与多用户容量评估2026-11-02部分已实现)。新增 `mobile.test_stream_lifecycle`／`mobile.test_event_delivery` 共 13 项，覆盖建连准入等待、短断退避、握手冷却与日志脱敏、轮换、保活、租约丢失取消、纯余额通知、风险事件继续对账、陈旧事实、批量投递、失败待重试及每轮 100 条上限。先复现失败后，连同原生命令与共享守卫的 45 项定向回归通过。

`mobile market_stream trading.test_scheduler_connections` 的独立 Redis 组合最终 **119 项通过（9.921 秒）**，包括新增私有批次只用一次 pipeline、序号顺序、账户／模式筛选与真实 ASGI 投递；初轮发现协议 fixture 仍调用已合并的旧发布入口及新 fixture 缺筛选字段，修正后通过。随后新增 scheduler 注册回归先复现重复任务，`trading.test_scheduler_connections trading.test_public_market_klines trading.test_snapshot_prewarm` **25 项通过（0.041 秒）**，覆盖原生／旧预热切换、CDN 显式开关和普通／带单保护任务保留。

最终固定源码快照的全量回归 **Ran 1005 tests／310.659 秒，OK，6 项专用集成条件跳过**；发现计数为 1022，部分专用集成类在 setUpClass 时整体跳过，执行数按 runner 的 Ran 口径记录。证据与冻结源码清单位于忽略目录 `.integration-runtime/BackendSlim/`。`server/.env` 未复制，测试使用 SQLite／LocMem、临时独立 Redis 和交易所替身，额外阻止外部 DNS／socket，仅允许回环连接。初次全量为 1004 项、6 项条件跳过；增加预热调度修改后以上述最终结果为准。快照保留当时工作区已有的其他任务改动，不能把全部差异归为本次瘦身。

复现主要回归的命令：

```bash
PYTHON_DOTENV_DISABLED=1 DB_ENGINE=sqlite USE_REDIS_CACHE=False RUN_SCHEDULER_IN_WEB=false \
  MARKET_TEST_REDIS_BINARY=/absolute/path/to/isolated/redis-server \
  server/.venv/bin/python server/manage.py test mobile market_stream trading.test_scheduler_connections --noinput
```

系统检查和 `makemigrations --check --dry-run` 通过，无 migration 漂移。以上不替代 MySQL 行锁、跨进程账户 lease、网络故障长稳或用户容量压测；本轮没有实盘操作、提交、推送、部署及客户端构建。

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

独立工程为 `frontend/harmony-app/`，不接应用市场。2026-11-03 首两批复刻完成54项无网络替身测试、核心 strict 与工程检查，正常源码真实 ArkTS／签名 HAP 构建及 Mate 80 更新安装通过。黑边先用旧真机截图复现，再检查深浅主题；认证表单、协议和自选行情在 `.local-build/preview-project/` 的内存替身中作真机交互检查，未进行真实账户或交易联调。两项新增自选同步／旧账户错误竞争在旧实现失败、修复后通过。

2026-11-03第三批另完成122项无网络测试、TypeScript 5.9.3 strict、14份配置／148个导入／55项资源检查及真实ArkTS签名构建（7.740秒）。新增 `generate-ios-chart-reference.py` 从当前Swift源码生成连续／缺口两组180根数据，来源SHA-256随基准保存；默认20类指标逐值验证，包含预热、统计缺值及末根替换。图表票据覆盖Decimal含费估算、参数／策略快照改变、EMA过期、确认取消、页面／账户变化、持仓读取失败与未决命令阻断。

Mate 80离线真机验证了深浅图表、13周期及收藏／重置、指标无效输入／重置／应用、Super透明度、同次触摸跟随及松手保留／后续平移清除、auto与手动价格域、限价线及多空联动、杠杆／手动策略、确认取消与持仓只读；换币种清空旧意图；持仓读取失败只重试、不进入开仓确认。测试后恢复正常签名包并核对登录首屏与深色系统栏。初次真机截图暴露的Canvas物理字号、提示按钮变暗、周期旧高亮和票据第一行旧值已复现并修复后复测。收尾同步图表配色及双指接管十字线状态，新增接管／迟到回调回归先失败后通过。未测真实订单、HTTP／WSS、双指缩放、帧耗时或长稳；不能将替身、单指手势或数值测试写成这些范围已通过。

正常工程 `.local-build/project/` 与离线预览工程隔离，签名仅存在忽略目录。每次编译前先同步公开源码；预览结束重新安装正常包。完整工具链、验收范围及后续批次见 [鸿蒙主文档](harmony-client.md) 与 [复刻计划](plans/2026-11-03-harmony-ios-parity.md)，具体命令见 [工程 README](../frontend/harmony-app/README.md)。

## 图表加载诊断回归

2026-11-01 后续取得实际 iPhone `1.0.1 (15)` 的三轮九次 BTC1h 报告，确认 URLSession／图表／Metal 呈现／鉴权上报／生产落库链路实际贯通。前六次首帧 2.00～6.94 秒，蜂窝、无 VPN 的连接实测 TCP 重传及缩窗；单目的地址 BBR 对照后，三次为 503.60／433.48／453.03 ms，内核确认连接为 BBR，用户体感一致。随后固化宿主配置，撤销临时路由／采样，新建 HTTPS 连接确认 BBR 且健康 200。当前三次达到约 1 秒目标，不作为其他网络长期保证；这轮没有改动产品代码或为配置／文档重复运行既有单测，配置应用检查及真实链路证据与以下本地替身测试分开，见 [真机排查](market-data.md#构建-15-真机传输排查2026-11-01)。

2026-11-01 本地 `market_stream` 67 项通过，包含五项独立临时 Redis 回归及九项诊断入口测试：鉴权、合法网络字段、未知字段拒绝、实际 24 KiB 正文限制、非有限数值、用户节流、容量／重复报告幂等、用户隔离、retention 和 K 线关联响应头。migration 漂移检查通过，仅新增诊断表。

专用模拟器 `A9B09AF9-195A-4F50-B706-7F07A0EB4CD4` 上 `ChartEngineCoreTests` 136、`MarketFastPathTests` 21、`ChartLoadDiagnosticsTests` 4，共 161 项通过（33.188 秒）。覆盖旧 epoch 首帧拒绝、周期替换和结束一次、取消、固定诊断字段／事件上限、HTTP 追踪头及解码边界、诊断 401 不全局登出、Metal 有效首帧 observer 可重入且只触发一次。日志保存在忽略目录 `.integration-runtime/KlineDiagnostics/`。

在独立 SQLite 数据库与回环 HTTP API 中迁移新表，种入 1500 根合成 BTC1h，禁止外部交易所请求，以真实 URLSession、图表 pipeline、Metal 模拟器完成回调、异步 POST 和 Django 入库串通验证。三次进入均保存 displayed、首尾时间、网络 metrics 和完整图表阶段；模拟器完成属于 GPU 代理，不是物理手机呈现或公网性能。初次配置用不在已知列表的回环端口，App 回落到了既有远端选择，因此那一轮 UI 虽通过但没有本地记录，不计入隔离贯通；随后通过构建设置显式指定回环 API，并核对实际数据库三条记录。

最后补充网络／本地缓存来源字段及隐私清单后，九项后端诊断与五项 iOS 定向回归再次通过，隔离 UI 再次完成三次加载并入库；数据库确认缓存来源标记存在，原始网络读取在前一轮已验证。只读 trace 查询通过，最终 generic iOS Release 无签名编译通过并确认成品清单包含新增声明。两轮隔离验证均不作为手机／公网性能数据；没有上传 TestFlight 或执行真实交易。


## 账户与资金双页签回归（2026-11-02）

`trading.test_capital_wallet`、`trading.test_balance_cap`、`trading.test_lead_mode` 组合 128 项通过（33.806 秒），使用 SQLite / LocMem 和交易所替身。覆盖合约超额加资金钱包只转现货、两个独立补入方向、独立现货转出、原 UUID 终态重试、余额变化重新核对、超时只查回执、逐步骤持仓检查、旧链隔离、Key 隔离及带单路径拒绝。执行命令与前文的隔离环境变量相同；migration 漂移和 `git diff --check` 通过。

DEBUG 无网络 `WebParityUITests` 新增 `testCapitalWalletSheetTabsAndDirections`、`testCapitalCollectionAccountAndModeEntry`、`testCapitalWalletBlockedAndEmptyStates`：三项通过（合计 179.423 秒），已打开浅深色、转账和账号历史截图检查。资金提交接口在视觉替身中始终拒绝，未确认真实划转；原生大面板的方向菜单、模式确认、脱敏地址和原账号编辑窗口已覆盖。首屏合计改为固定底栏后，该页签 / 方向流程再次通过（126.091 秒），确认金额始终在按钮上方可见并重新检查截图。旧归集核对入口移至主按钮后，空态 / 阻断 / 旧链恢复组合再次通过（28.488 秒）。证据位于忽略目录 `.integration-runtime/CapitalUI/`；generic iOS Release 未签名构建通过，手机 / TestFlight 和真实资金动作未验收。

## 归集资金三页签与账号空态（2026-11-02）

将资金面板改为圆角矩形“划转 / 转账 / 记录”三页签，复用现有历史组件并提供嵌入模式；记录页移除账号接口、卡片与编辑入口。转账页补齐未配置账号的 ＋ 卡片，沿用原编辑弹窗；已配置账号保留脱敏卡片与管理入口。现有 UI 流程同步调整为三个页签、无账号历史页、两种账号卡片和菜单直达记录；DEBUG 未配置替身保持资金写请求拒绝。

generic iOS Release 未签名构建及 generic iOS Simulator 的 `build-for-testing` 均通过，证据位于忽略目录 `.integration-runtime/CapitalTabs/`。按用户“简单调整不启动模拟器测试”的偏好，本轮未启动模拟器、未执行 XCTest / UI 测试；编译不等于交互、截图或实机验收。未执行真实资金动作，未上传 TestFlight；本轮只改客户端，不发布后端。

## 账户顶栏与统一数字精度（2026-11-02）

账户顶栏的绑定 API 紧跟头像，模式切换位于同一行最右侧；绑定与切换按钮均为 36 pt 高、12 pt 中等字重。新增 Foundation 层 `DisplayNumber`，行情、开仓 / 确认、持仓 / 历史、资金、策略摘要、浮窗 / 画中画及图表共用按绝对值分档的显示规则，详见 [统一数字显示](ios-web-parity.md#统一数字显示2026-11-02)。原输入与交易请求保持完整精度。

在本机临时 Swift Package 中直接编译实际 `DisplayNumber.swift`、`MarketSnapshot.swift` 与 `DisplayNumberTests.swift`，5 项测试通过，覆盖分档、四位有效数字 / 尾零、跨档进位、负值 / 零、大额 Decimal、无效值、行情和缩放单位。既有浮窗 / 图表参数 / 开仓估算断言按新格式更新，UI 顶栏流程增加头像间距、同行和按钮高度断言。

本任务源码快照的 generic iOS Release 未签名构建、单测工程和 UI 工程 `build-for-testing` 通过；工作区并行交付的已提交图表布局纳入最终编译。证据保存在忽略目录 `.integration-runtime/ProfileNumbers/`。按用户偏好未启动模拟器、未执行 iOS 单测 / UI 测试，页面截图、TestFlight 与实机验收待核；本轮没有后端发布或真实资金操作。

## 账户归集、服务器自选与图表修正（2026-11-02）

`market_stream mobile.tests trading.test_strategy_loading` 共 100 项（95 通过、5 项独立 Redis 条件跳过，9.290 秒），使用隔离 SQLite／LocMem、公共数据替身和无绑定账号。新增自选顺序／空列表／用户隔离／缓存丢失、无效目录拒绝、市值排序／倍数币种、七天刷新／失败退避／分页失败保留旧快照、手动止盈默认项隔离测试。migration 漂移检查通过。

市值接口限流补充回归先在旧实现复现一项失败、一项错误，加入 429 `Retry-After`、永久错误不重试和重试上限覆盖后，目录／移动端／策略定向 34 项通过（6.973 秒）。全部网络均为替身，等待被替换，不用真实资金操作测试重试。

实际 `DisplayNumber.swift` 与 `MarketSnapshot.swift` 在本机临时 Swift Package 运行 5 项测试通过；将同样断言放回前版格式器可复现 8 个失败，修复后通过，涵盖用户给出的两个小数示例与尾零、零值、进位。iOS 增加服务器自选恢复与离线重试测试，更新当前价全宽线／轴内标记及 UI 入口断言。

本轮 generic iOS Release 未签名构建、单测工程与 UI 工程 `build-for-testing` 通过，证据在忽略目录 `.integration-runtime/InterfaceRefinement/`。按既有用户偏好未启动模拟器、未执行 iOS XCTest／UI 测试，iPhone 16 Pro Max 底部贴边及真机触摸仍待手机新版确认；没有上传 TestFlight。线上后端与公共数据结果见 [变更](changes.md)，不能用本地测试代替生产验证。

## 页面保留、模式菜单与 Super 范围（2026-11-03）

本轮将 Super 滑杆显示值 0–100% 映射为实际 80–100% 透明度，保留 alpha 存储格式；“我的”移除顶部模式按钮及重复浮窗入口，切换模式改为下方菜单和目标模式蓝／黄图标。持仓三项选择器居中，共用交易对列表改用与 K 线一致的星标。持仓报价跨切页／重连保留，信号列表及滚动状态由生产根容器保留；账户 scope 变化、解绑和旧响应仍隔离。当前实现见 [界面](ios-web-parity.md#信号列表保留2026-11-03本地)、[行情](market-data.md#持仓市价与浮盈推送限流边界2026-11-02) 与 [浮窗入口](ios-floating-positions.md)。

先在旧实现运行新增报价保留回归，10 项中出现 3 个预期失败断言（重订阅／结束订阅清空报价、暂停和 ready 后盈亏为空）。修复后 `TradeTool`／`Debug-Seoul` 的 `PositionLiveValuationTests` 11 项、`PositionPageReuseTests` 6 项及 Super 映射／持久化 2 项，共 **19 项通过**，0 失败／跳过。验证包含默认滑杆 20%、完整滑程 alpha 0.20→0、旧 alpha 边界、历史／实时样式、过期包拒绝、旧会话清理不能影响新会话及账户变化清空。

模拟器 UI 使用 `RetainedTradingPages` 生产容器和无网络替身，`--fixture-page-state` 提供带读取次数的 20 条信号；已确认切页／退后台后继续显示同一列表及滚动位置，30 秒内没有重复读取。交易对新增／删除二次确认及开仓选币流程通过。首轮发现旧模拟器偏好使默认滑杆断言不成立，改为验证端点与保存后重开；同时为持仓顶栏增加独立辅助功能容器，避免父标识覆盖浮窗按钮标识。

同一 iPhone 模拟器（`3E685E56-9767-43E7-81DD-35972DE7FAD7`）下，4 项不同 UI 流程最终分别通过：交易对自选／选币（27.709 秒）、信号保留与退后台（15.269 秒）、浮窗空仓／未绑定／带单深色（42.658 秒）、指标保存／模式双向切换／居中页签的浅深色（72.126 秒）。原生 XCTest 滑杆拖到最右端可能落在 99%，UI 断言容许一个原生步长，精确 100% 到 alpha 0 由单测覆盖。已打开最终浅深色截图核对模式图标、星标、透明度滑杆、页签及浮窗入口。generic iOS Release 无签名编译通过。

证据在忽略目录 `.integration-runtime/PageStateReview/`：旧实现 `Before.xcresult`、`CoreFinal.xcresult`、`UI.xcresult` 中的两个通过流程、`UIFinal.xcresult` 中的浮窗通过流程、`MenuUI.xcresult`、`release-final.log` 及截图目录。失败的早期整组结果保留，不能称为整组通过；上述为修正后的独立流程结果。本轮没有服务端发布、真实交易／资金动作，源码和文档留本地，未提交、推送或上传 TestFlight，手机显示仍待新包验收。

## 快捷周期与 auto 回归（2026-11-03）

先按用户要求将本轮开始时全部安全改动提交为 `df77ba2` 并成功推送 GitHub `codex/integrated-ios`；此后新增的周期、auto、限价线和间距调整仍为本地未提交内容。实现规则见 [行情](market-data.md#快捷周期与自动价格视窗2026-11-03)，页面尺寸见 [原生界面](ios-web-parity.md#当前实现)。

- 六周期上限回归先在旧代码产生 3 个失败断言（`ChartAutoRed.xcresult`）；新增后端周期目录回归先产生 6 个缺失周期失败（`ChartIntervalsBackendRed.log`）。随后实现快捷栏分区和最多六项、固定手动价格域、主图上下平移／手指锚点缩放、auto 恢复、跨 stream 重建价格域、限价止损正价格越界和右侧画布贯通。扩展六种周期，16h 由 8h 连续聚合，周线在后端和客户端按 UTC 周一对齐。
- `ChartEngineCoreTests`／`ChartOrderTicketTests` 首批 161 项通过（`ChartAutoCoreFixed.xcresult`）。加入周线与完整行情校对后，183 项运行中 182 项通过，一项快捷切换顺序断言仍按旧七周期编写（3 个失败断言，`ChartAutoFinalCore.xcresult`）；同步 30m／2h 邻接及新回绕位置后，与手动 pan＋pinch 和新增跨 stream 回归一同 3 项通过（`ChartAutoSupplement.xcresult`）。最终源码的 156 项核心、7 项开仓、21 项行情用例共 184 项已有分批通过记录，未把重复运行累计为新增用例。
- 后端完整 `market_stream` 共 91 项，84 项通过、7 项需独立 Redis 的用例未启用（5.852 秒，`ChartIntervalsBackendFinal.log`）。覆盖新 HTTP／WSS 目录、全部周期内部缺口补全、16h 两页有界 8h 聚合及缺首桶拒绝、形成中尾线、周线小时＋当前分钟合并、无效统计请求不排队；种子仍为原七周期。首轮形成中尾线测试在退出模拟时钟后读取已过期缓存，已将断言移入同一时钟范围再通过。
- 模拟器 `3E685E56-9767-43E7-81DD-35972DE7FAD7`、Debug-Seoul：`ChartCalibrationUITests.testChartIntervalShortcutsAndSettings` 和 `WebParityUITests.testChartAutoIntervalPanelAndLimitLinesInBothAppearances` 两项通过（59.457 秒，`ChartAutoUIExpanded.xcresult`）。覆盖分区、六项增减、设置按钮紧随尾项、auto 开关、上下拖动、六种新增入口、浅深色绿底白字、限价线到画布右端及视窗外止损草稿。首轮两处 UI 断言分别受文字可访问区域的外侧留白及偏好更新时序影响，已按实际点击区域／异步偏好更新修正；最终截图已导出并检查。
- generic iOS、无签名 Release 构建通过（`ChartAutoRelease.log`）。全部日志、xcresult 和截图位于忽略目录 `.integration-runtime/`。本轮未执行真实交易、划转、撤保护单，未部署后端或上传 TestFlight；实机手感、新周期线上补全和长稳仍待新版配套验收。


## 主题填充与账户策略界面回归（2026-11-03）

Super 滑杆保留同一偏好值，深色映射实际 80–100%、浅色 40–60% 透明度，历史和实时填充在 Metal 配色编码层按主题解析。MACD 空心柱从约 0.5 pt 加粗到 1 pt，受窄柱尺寸限制时保留空心区域，边框取整为物理像素。“我的”账户卡间距收紧，模式入口移至设置下方最后一项；持仓页签改左对齐。止损面板隐藏灰色控制柄并统一表面色，金额最多 3 位小数／去尾零、百分比整数。策略列表恢复 52 pt 满宽黄色新建按钮，选中项黄框与标题行黄勾，独立“编辑 ›”位于摘要下方右下角。当前规则见 [界面](ios-web-parity.md#策略编辑与指标设置2026-11-03) 和 [行情](market-data.md#拖动一致性当前价与尾线修复2026-11-03)。

先将真实生产场景的 Super 历史／实时主题断言和 MACD 边框覆盖断言放入 host Swift Package，在旧代码下两项均失败：浅色仍为 alpha 0.16；3 倍屏边框为 1.5 像素，分数像素平移时左右分别覆盖 1／2 个像素。修正后复用生产测试方法、实际图表数据／指标／场景／配色和 Decimal 格式代码，最终 **8 项通过，0 失败／跳过（0.063 秒）**。范围包括红绿双主题滑杆全程、历史及实时默认值、偏好兼容／持久化、MACD 强弱及正负柱／实时边框、分数像素平移覆盖、止损 3 位四舍五入／进位／去尾零、大额 Decimal 和原向上取整步长，以及既有其他图表颜色／坐标标签对比。网络依赖使用替身，没有调用真实交易。

`TradeTool Release` 的 generic iOS 无签名构建、`TradeTool Chart Calibration` 和 `TradeTool` 的 generic iOS Simulator `build-for-testing` 均通过。更新 UI 断言覆盖右下角编辑入口、标题行选择标识、满宽新建按钮、模式菜单顺序、左对齐页签、止损无灰柄／整数百分比和去尾零金额；本轮按用户偏好没有启动模拟器或执行 iOS XCTest／UI，也没有新增截图或实机验收。host 结果验证生产场景和物理像素覆盖计算，不代表 GPU 像素截图验证。证据在忽略目录 `.integration-runtime/ThemePolish/` 的 `before.log`、`final.log`、`release.log`、`test-build.log` 和 `unit-build.log`。本轮保留本地，未提交／推送、部署或上传 TestFlight，实机布局、点击及观感待新包确认。
