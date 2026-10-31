# ADR-0001：K 线 Metal 渲染稳定性边界

- 状态：Accepted，稳定性策略已实现，阶段 0.5 性能/长稳持续验证
- 日期：2026-07-30
- 范围：`TradeTool/Features/ChartEngine`

## 背景

K 线图需要处理每 250ms 一次的实时更新、60/120Hz 交互、3,000 根历史、
多个指标和动态文字。渲染器必须保持纯原生性能，同时不能用无界队列、每帧分配
或强制复用繁忙 GPU 资源掩盖压力。

## 决策

1. 屏幕和离屏测试共用 `ChartRenderBatch`、Metal pipeline、shader、sRGB 像素
   格式和 encode 顺序，不维护第二套 Core Graphics renderer。
2. candle、line、bar、glyph 使用紧凑 instance record，并打包到一个有硬上限的
   frame buffer。当前单帧上限为 2MiB：
   - candle：4,096；
   - line segment：16,384；
   - bar：4,096；
   - glyph：8,192。
3. 动态 frame 使用三个预分配 buffer。租约包含单调代次，过期 completion 不能
   释放已经重新出租的槽；command error 对应槽进入 quarantine。
4. 三槽均忙时不等待 GPU、不分配第四槽；保留最新 `RenderState`，任一资源归还
   后按需重试。
5. 闭合历史使用稳定 buffer；正常实时更新只重打包 live tail。所有数量、offset、
   stride 和对齐运算先做溢出检查，NaN/Inf 或非法矩形在 scene 边界过滤。
6. Core Text atlas 使用“fallback font PostScript 名 + glyph”联合键。atlas 和
   texture 都有页数、字形数、尺寸和字节上限；未包含的字形使用明确 fallback，
   由上层异步安排下一版 atlas，热路径不扩容。
7. Core Graphics atlas 的纵坐标转换为 Metal UV 时固定使用
   `v = 1 - y / atlasHeight`。2x/3x 离屏像素 hash 与测试附件共同防止方向、
   fallback font 和坐标回归。
8. 真机通过 `drawable.addPresentedHandler` 的 `presentedTime` 记录实际呈现；
   simulator 缺少该 API，只把 command completion 用于测试，不纳入延迟结论。
9. Metal 初始化和帧编码失败返回受控状态，不使用 `fatalError`、`try!` 或强制
   解包，也不静默切换到另一套生产 renderer。
10. command buffer error 后隔离旧 resource ring，并在 completion 回到
    MainActor 的安全点创建全新 renderer。连续错误以 60 秒窗口计数；成功帧复位
    窗口，连续第 3 次错误停止新帧并显示可退出/重进的受控错误层。
11. memory warning 丢弃稳定 scene GPU buffer 与 glyph texture LRU；CPU 侧
    不可变 scene/candle 快照仍保留，下一次需要显示时按需重建资源。
12. 图表 signpost 使用 MetricKit log handle，app 启动时注册
    `MXMetricManagerSubscriber`。接收端只汇总 payload、分类和诊断数量，不保存
    stack、账户、symbol、价格或原始交易数据。
13. 长稳延迟使用固定边界直方图累计全程 presentation；最近 256 帧 ring 只用于
    revision 级诊断。RSS 每秒采样且只保留 start/end/peak，压测诊断本身不能
    引入无界数组或逐帧系统调用。
14. `KlineChartHostView` 销毁时移除 observer，并把 coordinator 的显式清理调度到
    MainActor。旧 command completion 只通过 weak host/coordinator 和 renderer
    generation 回流，不能延长宿主生命周期或触碰已销毁 UI。
15. Debug 故障注入复用正式的 quarantine/rebuild/circuit-breaker 路径，但模拟
    错误使用单独健康计数，不能增加或冒充真实 `commandBufferErrors`。
16. renderer 运行必须同时满足 host 已挂载 window 与 UIApplication active。
    `willResignActive` 先幂等 suspend、停止 display link 并 release drawable；
    inactive submit 只覆盖 latest mailbox。`didBecomeActive` 仅在仍挂载时恢复，
    SwiftUI dismantle 必须显式 dispose，不能等待 deinit 才解除系统 observer。
17. 真实 command buffer completion 若返回非 `.completed`，健康快照记录固定
    16 条最近失败摘要：status、NSError domain/code 和截断后的 message。Debug
    模拟失败不写入该 ring，避免把人为注入误当作驱动/GPU 错误证据。
18. ready-to-present 的性能目标仍为 `50ms`。真机 60Hz 连续交互的精细桶显示
    p95 位于 `(50.000ms, 50.250ms]`；固定直方图验收允许 `0.250ms` 上界容差，
    代码常量和单元测试共同锁定。该容差只解决 60Hz 三刷新周期边界和桶上界
    量化，不得扩成一帧容差，也不得用于放宽 frame time、GPU error、dropped、
    FPS 或内存门槛。
19. `interaction` 与 `soak` 的 long-run 结果必须满足本轮
    `droppedPresentations == 0`，不能只依赖不含 dropped 的通用健康快照。
    `lifecycle` 刻意在 in-flight 时销毁宿主，允许并记录对应 dropped，使用独立
    门禁，不能把该例外扩散到性能长跑。
20. 最近 dropped 诊断使用固定 16 槽 ring。每条只保存 revision、时间、提交时
    与回调时的 App/host/window/renderer/interaction 上下文及有界计数，不保存
    drawable 或业务数据。该 ring 只提高可定位性，不能改变 dropped 的定义或
    long-run 零容忍门槛。
21. interaction 的“调用方仍请求连续帧”与“display link 当前活跃”是两个独立
    状态。UIApplication 短暂 inactive 时只停止实际 display link 并保留请求；
    active 恢复后重建单一 display link。显式交互结束、dispose 与熔断必须清除
    请求，防止后台运行或重复帧泵。
22. 阶段 0.5 性能验证必须同时保留两级入口：直接构造 `RenderState` 的场景用于
    隔离 renderer、交互和生命周期；端到端 `pipeline` 场景必须实际经过
    `KlineIngressState -> CandleStore -> provisional indicator -> RenderState`
    后再进入 Metal。后者的入站 live/barrier/recovery 必须有硬上限，并把
    coalescing、异常分类、恢复完成、历史复制和指标有限值纳入门禁。
23. 生产详情页的 WebSocket observer 必须使用有界 `.bufferingNewest(64)`；
    任意 buffer drop 都不能静默跳过，而要把当前 stream 标记为需要 REST 快照。
    actor 内 live pending 固定为 1、close barrier 固定为 8，主线程最多每
    250ms drain 一次，不能让 WebSocket 到达频率直接决定 SwiftUI/Metal 发布
    频率。drain 和 recovery 任务退出边界必须保留 pending latch，不能因任务
    尚未清空引用而吞掉恰好同时到达的新调度请求。
24. REST 快照与实时增量以 stream epoch 为一致性边界。`ready` 必须生成新
    epoch 并重新取快照；快照必须验证 symbol/interval、拒绝空结果和旧 epoch，
    安装后再应用请求期间保留的最新 live tail。恢复失败采用单一任务和有界退避，
    当前可见 frame 不清空。
25. 生产 `SceneBuilder` 必须按稳定层/动态层拆分。稳定层 cache key 至少包含
    stream/epoch、candle/indicator 历史对象身份、viewport 和 live-slot 形态；
    同根更新在既有价格域内只替换 live-tail batch。收线、尺寸/epoch 变化或实时
    数据越出既有价格域时才重建稳定场景，不能每 250ms 重新编译或复制全历史。
26. 页面只有在合法 `ChartDataFrame -> RenderState` 完成后才覆盖静态回退。
    场景坐标必须使用 view point × display scale 的 drawable 像素契约；价格轴、
    时间轴和最新价文字共用缓存的 Core Text atlas。无数据、非法尺寸或构建失败
    保留静态图，不能用空白 Metal view 取代 last-good UI。
27. 指标计算和场景输入必须通过 descriptor、instance configuration、registry、
    calculator 与通用 series snapshot。生产数据帧和 SceneBuilder 不允许再增加
    `ema21/ema55/superTrend` 等专用字段；插件输出只能声明 placement、axis、
    autoscale 和通用 figure 样式，不能直接调用 Metal。
28. EMA、SuperTrend 等递归插件必须保持 committed/provisional 分支。方向分段使用
    两条 series 与显式 hidden validity 表达，不能把非当前方向伪装为数值 0、NaN
    或 data gap；真实时间断档仍要重置递归状态并请求快照恢复。
29. 主图和副图必须由通用 `ChartPanelLayout` 描述，共享时间轴但使用独立 Y 域。
    指标输出通过 line/histogram figure style 和颜色策略进入通用 scene compiler；
    VOL/MACD 插件不能增加专用 Metal pipeline 或绕过单帧资源上限。
30. MACD 与 VOL 的同根 250ms 更新必须从 committed 状态生成 provisional 尾点，
    不能重复 append。MACD 的 signal EMA 求和、计数和输出都要做有限值/溢出检查；
    异常点不提交候选状态，避免一次极端值永久污染递归链。
31. 指标选择必须使用强类型、版本化状态。主图 overlay 可独立组合，副图槽当前最多
    一个；持久化内容必须使用确定顺序并严格校验，未知、重复或非法组合回退默认值。
    未接入插件的 UI 项不能维护与真实 pipeline 脱节的伪选中状态。
32. 运行时切换指标必须在 `ChartDataPipeline` actor 内从同一 CandleStore 快照构建
    候选引擎，再原子替换；不得清空 last-good frame、重新创建 ingress 或丢弃排队中
    的 live/close barrier。选择 revision 必须单调，并在 actor 可重入点后重新检查；
    提交前还必须确认 CandleStore revision 未改变，否则从新快照重建。ViewModel 发布
    还要同时匹配当前 session、epoch 与 revision，防止旧选择或旧历史回写。
33. 内置指标参数必须先进入不可变强类型值，再进入插件配置。范围、整数/步长以及
    EMA 顺序、VOL 快慢线和 MACD 快慢线等关系约束必须集中校验；编辑 UI 只维护文本
    草稿，不能在每次键入时重建历史。持久化 payload 必须包含 schema version，未知
    版本、损坏数据或非法组合统一回退默认值。
34. 指标选择与参数属于同一个运行时 configuration revision。应用参数时必须复用
    决策 32 的稳定 CandleStore snapshot 与原子替换路径，并让参数进入 calculator、
    instanceID 和图例；不得让 SceneBuilder 或 Metal renderer 按具体参数增加分支。
35. 时间轴视口必须用连续可见槽位数和 fractional trailing offset 表达。pan 不得按
    整根量化；pinch 必须以触点对应的数据槽位为不动点。返回最新只重置尾部偏移，
    不擅自恢复默认缩放。历史状态追加新 slot 时增加相同尾部偏移，自动跟随状态保持
    offset 为 0；symbol/interval/epoch 改变则重置为最新端。
36. 图表位于纵向详情 ScrollView 内时，父 pan 必须显式等待图表方向识别失败。横向
    由图表持有，纵向交还父级，系统左边缘导航优先；不得依靠 SwiftUI 视图层级或
    recognizer 的偶然竞争结果。cancel、inactive、background 和 dispose 都必须结束
    interaction display link 并恢复 idle。
37. 历史视窗不得继续 autoscale 或绘制不可见的 live candle、live indicator 和最新价
    marker，也不得把它们 clamp 到绘图区右边缘。Scene cache identity 必须包含时间轴
    视口；行情与手势异步构建都只允许最新 request key 覆盖可见 RenderState。
38. 当前 `24...120` 可见槽、`1.15` 方向锁和 `20pt` 左边缘保护是集中管理的初始
    token，不是币安一致性结论。惯性和回弹可以先按可替换 token 建立完整状态与性能
    路径，但完成真机 gesture trace 前不得宣称速度曲线已与币安一致；长按、双击或
    价格轴拖动也不能凭经验宣称完成。持续手势的最终热路径必须使用 guard-band 几何
    加 uniform 更新，不能把每次稳定 buffer 重建当成最终性能方案。
39. 稳定 scene 必须在真实可见窗口两侧持有有界 guard-band，当前每侧 48 个 slot；
    guard 数据只用于交互连续性，不能加入主图或副图 autoscale。达到边界时提交一次
    viewport rebase，不能无限扩大缓存，也不能让单次场景扫描完整 1,500 根历史。
40. pan/pinch 高频采样只更新 `InteractionSnapshot` 的 affine X 轴变换，不得逐采样
    发布 SwiftUI viewport 或创建新的 `StaticSceneSnapshot`。手势结束、guard-band
    越界、symbol/interval/epoch 或布局改变才允许重建稳定几何；250ms live-tail 更新
    到达时必须继续应用当前交互变换。
41. render batch 必须声明 `.timeline` 或 `.fixed` 坐标空间。只有 timeline candle、
    indicator line/histogram 应用 X 轴变换并裁剪到 plot；网格、Y 轴、时间轴文字、图例
    和最新价 marker 保持固定。不得用全场景统一 scale 造成价格轴、网格或标签漂移。
42. rebase 是异步边界：旧变换必须保持到新 static revision 可提交，期间拒绝第二个
    手势；不得先把 interaction 清零再等待 builder。临近窗口的 live tail 可以进入
    guard-band，但不可见时不得参与 domain，也不得绘制固定最新价提示。
43. 惯性必须复用 renderer 已有的 interaction `CADisplayLink`，不能另建永久 timer 或
    第二条逐帧渲染循环。每帧只推进纯值动力学并提交 interaction uniform；行情的
    250ms live-tail 更新继续继承当前位移。
44. 边界只能改变瞬时屏幕位移，逻辑 viewport 始终夹在 latest 与 oldest 之间。橡皮筋
    位移有明确上限，回弹使用有界临界阻尼并设置最大 2 秒生命周期；时间步必须截断，
    防止主线程停顿恢复后一次跨越大量 slot 或形成永不停止的 display link。
45. 惯性跨出 48-slot guard-band 时暂停逐帧驱动，保留速度和已用时，等待新 static
    revision 后从同一逻辑 viewport 恢复；不能把长 fling 在第一个 rebase 处直接截断。
46. 新手势可中断惯性；如果方向仲裁把触摸交给父滚动或系统导航，则先归零瞬时回弹并
    提交当前逻辑 viewport。inactive、background、dispose 和 renderer stop 都必须
    取消动力学，不得遗留 display link 或延迟回调。
47. 十字光标选择必须以 `openTime` 而不是数组下标为身份，并通过当前 timeline
    interaction transform 的逆映射 O(1) 吸附真实 slot。覆盖层只能发布有界的
    fixed-coordinate dynamic batch，复用既有 atlas、mailbox 和 display link；长按移动
    不得重建 static scene 或稳定 GPU buffer。历史选择不可被 live tick 改写，当前
    provisional candle 则允许更新同一时间身份下的数值。

## 结果

- 4Hz 行情不会驱动 60/120Hz 的无意义连续渲染；交互期间只有一个
  `CADisplayLink`。
- 新指标和工具通过 line/bar/glyph 等通用批次进入 renderer，不能直接绕过资源
  上限发 draw call。
- 离屏 golden 能在不修改 on-screen drawable 可读性的前提下复用真实 shader。
- 资源上限命中时保留 last-good frame，并通过健康计数暴露问题。
- renderer 重建次数、熔断停止和 memory warning 都进入线程安全健康快照。
- 生产同根 4Hz 更新复用 `StaticSceneSnapshot`，只上传最后一根、指标尾段、
  图例、最新价格线和价格标签；2x/3x 离屏生产场景保持确定性。
- EMA 三实例和 SuperTrend 共用通用插件快照；测试用新插件无需改数据管线、
  SceneBuilder 或 renderer 即可进入引擎。
- MACD 和 VOL 共用通用 panel、折线与 histogram 编译；主图/MACD 共享 X 轴但各自
  autoscale，VOL 可按配置替换副图而不改变 Metal renderer。
- 详情页指标按钮已经驱动真实插件实例；EMA/SuperTrend 独立开关、MACD/VOL 互斥，
  状态安全持久化，切换过程中不丢 CandleStore 历史或有界 realtime ingress。
- 指标设置页通过强类型、版本化参数快照驱动同一插件链路；自定义 EMA、SuperTrend、
  VOL 和 MACD 参数无需修改 SceneBuilder 或 renderer，并与选择状态一起原子切换。
- 生产图表已经具备 fractional pan、触点锚定 pinch、父级纵向滚动仲裁和保留缩放的
  返回最新控制；历史视窗不再错误绘制 live tail。每侧 48 slot guard-band、
  fixed/timeline 分层、绘图区裁剪与 interaction-uniform 热路径已经接通；惯性减速、
  latest/oldest 橡皮筋和临界阻尼回弹复用同一 display link，并可跨 rebase 续跑。
  长按十字光标也已通过同一交互通道接通 O(1) 吸附、有界 fixed overlay 和选中值联动。
  这些速度、手势与视觉 token 尚未经过币安真机 trace 定标。

代价是需要显式管理 buffer layout、atlas 生命周期、错误隔离和真机 GPU 诊断。
这是实现稳定高刷新率和可扩展 figure 系统所接受的复杂度。

## 2026-07-30 至 2026-07-31 已验证

- 模拟器与 iPhone 17e 均通过 20/20 `TradeToolTests`；
- 真机任务明确启用 Metal API Validation 与 Metal GPU/Shader Validation，
  真实离屏 candle/line/bar/glyph golden 无验证错误；
- 10,000 次 provisional EMA 更新不改变 committed 状态；
- 连续错误的两次重建、第三次停止、成功复位和 60 秒窗口裁剪有确定性测试；
- MetricKit subscriber 已接入，signpost 使用可聚合 log handle。
- iPhone 17e 前台真实 `MTKView` 短压通过：无验证层 4Hz/20Hz
  ready-to-present p95 分别为 `44.258ms`/`32.526ms`，峰值 in-flight 为 1；
- 同一前台场景启用 Metal API/GPU Validation 后 55/55 command 完成，
  command error、GPU busy skip 和 validation error 均为 0；
- suspend 期间 25 个 revision 只保留最新值，memory warning 后恢复只呈现
  revision 3025。详细证据见
  [阶段 0.5 真机短压报告](./KLINE_CHART_STAGE_0_5_TEST_REPORT.md)。
- Debug 长稳入口已支持 30 分钟 interaction 和 2 小时 soak 配置。iPhone 17e
  的 30 秒工具证明样本分别得到 interaction p95 `50ms` 桶、soak p95 `40ms`
  桶，peak in-flight 均为 1，dropped 均为 0；这不替代正式长时验收。
- 活跃 interaction 的短时 Instruments 样本已可重复采集：Time Profiler
  未发现 250ms hang；Metal System Trace 中 application command-buffer p95
  `4.332ms`，GPU vertex/fragment interval p95 为 `0.079ms`/`0.627ms`，
  CPU-to-GPU latency p95 `1.067ms`，零 command-buffer error。
- Debug lifecycle 入口支持默认 500 轮页面创建/销毁和确定性 simulated failure。
  iPhone 17e 无验证层 500 轮与 Metal Validation 10 轮均全部释放；分别覆盖
  166/3 次 in-flight 销毁，失败策略均为 5 次模拟失败、4 次成功重建、1 次熔断，
  RSS peak delta 分别为 `4.4MB`/`4.5MB`，没有 validation error。500 轮中
  681 个零 `presentedTime` 均按 dropped 记录并重画，未使用 completion 代替。
- 自动化基线为模拟器 30/30；iPhone 17e 在 Metal Validation 下 24 项 core
  unit tests 通过。
- iPhone 17e 的 app-lifecycle 无验证层 20 轮全部在 in-flight 时暂停，480 个
  inactive 状态被合并，suspend/resume 各 20 次、零 command error；由 Settings
  触发的 1 次真实系统后台/前台往返恢复的是原进程，计数从 5/5 对称增加为
  6/6。Metal API/GPU Validation 10 轮也通过，零 validation error。
- 真实 GPU command error 审计完成：当前不加入非法 Metal API 或越界 shader
  的自动注入，因为这类 fault 在验证层下可能直接终止进程，不能作为稳定验收
  手段。运行时已经记录真实 completion failure 摘要；阶段 0.5 剩余的是外部
  真实 fault 条件或硬件/系统异常下的观察验证，而不是模拟注入。
- 首次 2 小时 soak 在第 71–72 分钟出现 2 个 dropped，审计为失败。随后增加
  固定容量 dropped 上下文诊断；60 秒 targeted interaction 据此定位并修复
  UIApplication 短暂失活后 interaction display link 不恢复的问题。同配置
  A/B 从 `58.4fps/dropped 5` 恢复到 `60.0fps/dropped 0`，自动化为 31/31。
  Release 构建和 Debug-only 字符串审计通过；该短测不替代两小时重新验收。
- Debug `pipeline` 端到端场景在 iPhone 17e 运行 60 秒：1,422 个上游事件形成
  522 个 render state，900 个 burst 更新被 latest-wins 合并；10 轮异常得到
  40/40 次恢复，pending live 峰值为 1，EMA 非法值和历史复制违规均为 0，
  presentation dropped 与 GPU error 均为 0，p95 为 `36ms`。模拟器自动化升为
  32/32，Release 构建及 Debug-only 字符串审计再次通过；该短测不替代两小时
  长稳。
- 生产 `ChartDataPipeline` 已并行接入详情页 REST/WebSocket，但仍不替换可见
  静态图。1,500 根快照、250ms drain、有界 buffer drop 恢复、请求窗口增量
  重放、EMA 历史共享、sequence gap、空快照、旧 epoch 和闭合修正均有确定性
  测试；模拟器全套基线为 37/37。
- guard-band、interaction uniform、惯性减速和 latest/oldest 边界回弹接入后，
  iPhone 17 Pro 模拟器完整自动化为 64/64；其中 3 项新增动力学测试同时用独立纯
  Swift smoke 复核。Release 通用 iOS 无签名构建通过；未以此替代真机速度 trace、
  120Hz 或两小时长稳。

## 尚未关闭的验证

- 长时 Metal System Trace/Time Profiler、Allocations 和 Energy Log；
- 60Hz/120Hz 的长时间 pan/pinch/crosshair；120Hz 4Hz/20Hz 尚未覆盖；
- 外部真实 GPU command error/硬件故障条件下的观察验证；
- 2 小时长稳、MetricKit 实际日 payload 和 TestFlight 小范围发布门槛。
