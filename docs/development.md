# 开发与验证

当前工程入口见 [README](../README.md)，配置见 [配置字典](configuration.md)。以下命令在本整合目录执行。

2026-11-01 用户后续授权整批提交和推送，源码交付范围见 [最新变更记录](changes.md#2026-11-01整批源码提交与-github-交付)。下文“本地／未提交”描述各批验证结束当时的状态；本次交付没有重复测试、部署或手动上传 TestFlight，真实 iPhone 性能和云端分发仍按各主题待验项处理。

2026-11-01 的绑定与延迟界面任务中，用户当时要求停止进一步测试、先部署后自行验收。“我的”绑定长按钮、点击测延迟、三点等待动画和 2 秒单在途采样已完成，`Debug-Seoul` 模拟器目标仅执行 `build`，编译通过（`.integration-runtime/profile-latency-build.log`）；未运行修改后的单测、UI 或速度回归。既有断言已同步新状态并补充慢在途样本及点击重测场景，不能据此称为本轮测试通过。服务端仅执行发布必要的迁移、容器健康、HTTPS 与一次鉴权 WSS 心跳检查，未作交易操作和完整性能验收。新客户端与 WSS 数据库连接清理改动留在本地未提交、未推送；后者已包含在本次 SSH 部署中，版本及备份见 [运维](operations.md)。

本轮按用户后续的 BTC 加载排障要求恢复定向验证：行情后端 `manage.py test market_stream` 共 41 项，38 项通过、3 项专用 Redis 验证未启用；iOS `MarketFastPathTests` 10 项加 5 项快照／epoch／翻页回归全部通过（`.integration-runtime/ChartHistoryRefreshFinal.xcresult`）。新增慢响应门闩测试先复现取消下载，再验证首个响应优先展示、通知合并、切周期和 stop 的取消边界、pending 分页；这些结果不代替全部业务 UI、Release 或手机测试。后端和公网／GPU 分段样本、旧 USDC 的逐段对照见 [行情](market-data.md#与原-usdc-实现的核对2026-11-01)，本轮客户端仍未提交／推送。

随后按首屏交接计划补验：`market_stream.tests market_stream.test_fast_path` 41 项全部通过（2.469 秒），本轮显式提供专用 Redis 二进制，三项真实回环 Redis 测试没有跳过；`MarketFastPathTests` 18 项加 `ChartEngineCoreTests` 127 项全部通过（52.965 秒，`.integration-runtime/KlineFirstFrame/CorrectnessFinal.xcresult`）。新增分页重连／恢复顺序测试均先失败后修复，包含真实 15 秒校对、真实结构 ack、下载失败及不响应取消的旧请求。上述为本地隔离测试，未执行交易操作。

2026-11-01 本轮全部源码发布前，针对当前改动补跑 `market_stream.tests market_stream.test_fast_path common.test_retired_modules users.tests` 共 69 项，8.748 秒通过，显式使用专用临时 Redis；鸿蒙核心 40 项及工程检查通过。iOS 复用上方同内容 145 项与移除探针后的 Release 构建证据，本轮没有重跑手机性能或上传 TestFlight。发布后公网冒烟与源码版本关联见 [运维](operations.md#最新发布与核验2026-11-01)，代码评估与未实施项见 [行情](market-data.md#性能与可替换性评估2026-11-01)。

2026-11-01 随后的延迟刷新与止损入场优化另作本地验证：`NetworkLatencyAndModalTests` 9 项通过（2.273 秒），包含真实回环 WebSocket 上的手动重测保留读数、匹配 pong 结束进度，以及下拉刷新保留健康连接。专用 `TradeTools Web Review` 模拟器上的两项定向 UI 最终通过，覆盖点击／下拉刷新中间状态、浅深色绑定按钮、原生止损滑杆／底部按钮位置、确认取消、关闭与系统把手下拉；测试仅使用 DEBUG 替身。generic iOS Release 未签名编译通过，入场录屏未见明显闪烁，但没有真机帧耗时或 TestFlight 结果。初次 UI 失败及最终证据见 [变更记录](changes.md#2026-11-01延迟保留读数绑定按钮配色与原生止损面板仅本地)。本轮没有提交、推送、部署或平台上传。

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

活动持仓建议与四项底栏规则见 [页面说明](ios-web-parity.md#持仓逆势建议与四项底栏2026-11-02)。新增 `PositionTrendAdviceTests` 八项，覆盖多空方向的双条件、均线相等／交错、三个高周期真实指标计算、数据不足／过期／近期缺口、未收盘线反转、账户切换后旧响应拒绝、取消清理及失败后移除旧建议。既有底栏断言同步四项；登录 UI 检查的未绑定下单禁用断言改至 K 线下单区，独立开仓表单 fixture 继续用于共用组件检查。

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

独立工程为 `frontend/harmony-app/`，面向 Mate 80 的原生鸿蒙测试；不接应用市场。`npm test` / `npm run check` 仅作隔离核心与配置检查。本轮40项替身测试、核心 strict 类型检查与工程静态检查通过；安装 Command Line Tools 26.0.0.865、API 26 SDK 与 JDK 21 后，真实 ArkTS 编译及未签名 HAP 打包通过，调试签名和手机运行仍待验证。工具链版本与验收边界以 [鸿蒙主文档](harmony-client.md) 为准。使用忽略的 `.local-build/project/` 配置调试签名，保护公开工程中的签名口令与证书；具体命令见 [工程 README](../frontend/harmony-app/README.md)。

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
