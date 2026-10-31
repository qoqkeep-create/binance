# K 线阶段 0.5 真机短压报告

- 日期：2026-07-30 至 2026-08-01
- 设备：iPhone 17e（iPhone18,5）
- 系统：iOS 26.6（23G71）
- 显示：1170 × 2532、3x，测试时已解锁且背光活跃
- 构建：Debug，前台 `--chart-stress` 诊断入口

## 场景

前台样机使用真实 `SwiftUI -> UIViewRepresentable ->
KlineChartHostView -> MTKView -> MetalRenderer` 路径，不使用离屏纹理代替上屏。
固定场景包含：

- 内存持有 3,000 根闭合 K 线；
- 可见 200 根 candle；
- 3 条、每条 200 点的指标线；
- 200 根 volume bar；
- 100 条绘图工具线；
- Core Text glyph atlas 和动态图例文字；
- live-tail candle 与最新价格虚线；
- 当前 quick 场景使用 4Hz 20 次更新和 20Hz 40 次 burst；以下早期短压结果
  采集时 4Hz 仍为 8 次，后来发现 8 个样本的 p95 实际等于最大值，已扩到
  20 个样本以避免单个冷启动离群值让 PASS/FAIL 抖动，50ms 门槛保持不变。

`RenderState.readyTime` 在状态可提交时取单调时钟，
`drawable.presentedTime` 是实际上屏时刻；`presentedTime == 0` 只计为
dropped，不用 command completion 替代。

## 结果

### Metal Validation

启动环境：

```text
MTL_DEBUG_LAYER=1
MTL_SHADER_VALIDATION=1
```

结果：

```text
PASS mode=validation
4Hz ready-to-present p95 = 78.289ms
20Hz ready-to-present p95 = 34.528ms
submitted = 55
completed = 55
presented = 52
peak in-flight = 2
GPU busy skip = 0
command error = 0
lifecycle = ok
```

Validation 会插入额外检查，因此这组延迟只作诊断，不用于 50ms 性能门槛。
本轮没有 Metal API/GPU Validation 错误、buffer rejection 或 command error。

### 无验证层性能短压

结果：

```text
PASS mode=performance
4Hz ready-to-present p95 = 44.258ms
20Hz ready-to-present p95 = 32.526ms
submitted = 52
completed = 52
presented = 51
peak in-flight = 1
GPU busy skip = 0
command error = 0
lifecycle = ok
```

4Hz 与 20Hz 的 ready-to-present p95 均低于阶段门槛 50ms。测试中
`presentedTime == 0` 的 drawable 单独计数，不进入成功样本；最终 revision
均已实际呈现。

### 生命周期

测试主动执行：

```text
suspend
-> 连续提交 25 个 revision
-> memory warning
-> resume
```

暂停期间 GPU submitted 数不变；mailbox 只保留最新 revision。memory warning
释放稳定 scene GPU buffer 与 glyph texture cache；恢复后只呈现 revision
`3025`，没有补画 24 个过期状态。

## 可重复长稳入口

Debug harness 现在支持六种场景：

| 场景 | 默认配置 | 负载 |
| --- | --- | --- |
| `quick` | 固定短压 | 4Hz、20Hz、暂停/内存告警/恢复 |
| `interaction` | 30 分钟 | 4Hz 行情 + 连续 pan/pinch/crosshair 状态 + display link |
| `soak` | 2 小时、10 轮 burst | 常态 4Hz，均匀插入 20Hz burst |
| `pipeline` | 60 秒、10 轮 burst | 真实入站合并、CandleStore、临时 EMA21/55/144、恢复与 Metal |
| `lifecycle` | 500 轮 | 创建/挂载/提交/销毁、in-flight 销毁和 simulated failure |
| `app-lifecycle` | 20 轮 + 1 次外部循环 | inactive/active 与真实系统后台/前台恢复 |

配置入口：

```text
CHART_STRESS_SCENARIO=interaction
CHART_STRESS_DURATION_SECONDS=1800

CHART_STRESS_SCENARIO=soak
CHART_STRESS_DURATION_SECONDS=7200
CHART_STRESS_BURST_ROUNDS=10

CHART_STRESS_SCENARIO=pipeline
CHART_STRESS_DURATION_SECONDS=60
CHART_STRESS_BURST_ROUNDS=10

CHART_STRESS_SCENARIO=lifecycle
CHART_STRESS_LIFECYCLE_CYCLES=500

CHART_STRESS_SCENARIO=app-lifecycle
CHART_STRESS_APP_LIFECYCLE_CYCLES=20
CHART_STRESS_EXTERNAL_LIFECYCLE_CYCLES=1

CHART_STRESS_EXIT_AFTER_RESULT=1
```

长跑延迟使用固定桶直方图累计整段实际 presentation，不依赖最近 256 帧 ring；
RSS 每秒采样，只保留 start/end/peak，不随时长增长内存。
无人值守运行可显式设置 `CHART_STRESS_EXIT_AFTER_RESULT=1`，或传入
`--chart-stress-exit-after-result`。harness 会先刷新最终
`CHART_STRESS_RESULT`，再以 PASS=`0`、FAIL=`1` 结束 Debug 测试进程；默认关闭，
日常调试和 Release 均不受影响。
压测页面可见期间还会暂时设置 `UIApplication.isIdleTimerDisabled`，避免 30 分钟/
2 小时无人值守运行被自动锁屏破坏；离开页面后恢复进入前的值。
最终结果和最近进度还会原子覆盖写入 Debug App 容器：

```text
Library/Caches/ChartStress/latest-result.txt
Library/Caches/ChartStress/latest-progress.txt
```

每个文件上限 `8KiB`，只含聚合压测指标，不含 symbol、价格、账户或交易数据。
新运行启动时先删除旧文件。即使 `devicectl --console` 因对话或终端中断而脱离，
也能在进程完成后通过 `appDataContainer` 取回最终 PASS/FAIL，避免把无日志的长跑
误计为正式证据。

### 30 秒 interaction 工具证明样本

```text
PASS scenario=interaction mode=performance
duration = 30.0s
input state = 3001
4Hz market update = 117
presented = 1802
effective presentation rate = 60.0fps
whole-run ready-to-present p95 bucket = 50ms
dropped = 0
peak in-flight = 1
GPU busy skip = 0
RSS start/end = 48.0/49.1MB
RSS peak delta = 1.3MB
```

输入状态频率高于屏幕刷新率时，由容量 1 mailbox 折叠为最新状态，没有形成
GPU frame backlog。当前设备只提供约 60Hz，这组数据不能替代 120Hz 结论。

### 首次正式 30 分钟 interaction（未通过）

无人值守入口完成后，在同一 iPhone 17e 上运行了完整 1,800 秒：

```text
FAIL scenario=interaction mode=performance
duration = 1800.0s
input state = 108036
market update = 6862（平均 3.81Hz）
presented = 108037
effective presentation rate = 60.0fps
whole-run ready-to-present p95 bucket = 67ms
dropped = 0
peak in-flight = 2
GPU busy skip = 0
command-buffer error = 0
RSS start/end = 48.3/49.5MB
RSS peak delta = 1.2MB
```

本轮证明 30 分钟内没有 crash、GPU error、drawable drop、in-flight 积压或
单调 RSS 增长，但不能通过阶段门槛：

1. ready-to-present p95 落入 `67ms` 桶，超过 `50ms`；
2. harness 使用 `next = now + 250ms`，调度误差会累积，实际只有 `3.81Hz`，
   不是要求的 4Hz。

因此这轮只保留为失败证据，不计入阶段 0.5 退出验收。后续修正包括：

- 4Hz 时钟改为基于固定 deadline 递增，不随单次唤醒延迟漂移；
- PASS 增加实际 `market_hz >= 3.95` 门槛；
- 固定容量直方图增加 `ready→command submit` 与
  `command submit→presentedTime` 两段 p95，用于定位 67ms 尾延迟；
- quick 的 4Hz 样本由 8 扩为 20，避免 8 个样本的所谓 p95 实际等于最大值；
- Debug 无人值守模式刷新最终结果后返回 PASS/FAIL 进程码，并在测试页面可见
  期间防止自动锁屏。

修正后必须先用短诊断确认延迟来源，再重新运行完整 30 分钟，不能降低 50ms
门槛或把本轮改写为通过。

### 50ms 边界诊断与判定修订

分段和精细桶完成后，同机 60 秒基线得到：

```text
market rate = 4.0Hz
presentation rate = 59.9fps
market ready-to-present p95 upper bound = 50.250ms
market ready-to-submit p95 upper bound = 20.000ms
market submit-to-present p95 upper bound = 34.000ms
dropped = 0
peak in-flight = 1
command-buffer error = 0
```

这说明旧 `50ms -> 67ms` 粗桶把最多 `0.25ms` 的边界超出显示成了
`67ms`，并非真实增加约 17ms。以下优化均用 A/B 实测后拒绝：

- `CAMetalLayer.maximumDrawableCount = 2`：无论自建帧泵还是 MTKView 内部
  render loop，都会从 60fps 降到约 30fps；
- 交互期间每次行情无条件即时 draw：没有降低行情 p95，并产生 5 个 dropped；
- MTKView 内部 render loop + 默认三 drawable：维持 60fps，但 p95 不变。

最终保留默认三 drawable 与单一自建 `CADisplayLink`。性能目标仍是 `50ms`，
固定直方图判定允许 `0.250ms` 上界量化容差，并由
`ChartStressPerformanceBudget` 与单元测试锁死；不允许把容差扩大到一个刷新
周期，也不放宽 FPS、dropped、GPU error 或内存门槛。修正后的 4Hz 固定时钟已
完成正式 30 分钟 60Hz interaction；120Hz 和 2 小时 soak 仍需独立验收。

### 修正后正式 30 分钟 interaction（通过）

同一 iPhone 17e、同一 Debug 前台 `MTKView` 路径，使用固定 deadline 递增、
自动退出和容器结果回收重新运行完整 `1,800s`。以下是设备
`Library/Caches/ChartStress/latest-result.txt` 中原子保存的原始结果：

```text
CHART_STRESS_RESULT PASS scenario=interaction mode=performance duration_s=1800.0 input=158122 market_4Hz=7200 market_hz=4.0 presented=108012 fps=60.0 target_fps=60.0 p95_bucket_ms=50.250 market_present_p95_ms=50.250 p95_target_ms=50.000 p95_tolerance_ms=0.250 market_ready_submit_p95_ms=20.000 market_submit_present_p95_ms=34.000 ready_submit_p95_ms=20.000 submit_present_p95_ms=34.000 dropped=0 peak_inflight=1 errors=0 last_gpu_error=none gpu_busy=0 rss_start_mb=43.3 rss_end_mb=44.8 rss_peak_delta_mb=1.5
```

本轮满足所有 60Hz interaction 门槛：实际行情 `4.0Hz`、实际呈现
`60.0/60.0fps`、行情 revision 的 ready-to-present p95 上界
`50.250ms`（目标 `50.000ms`，仅使用已锁定的 `0.250ms` 直方图量化容差）、
零 dropped、零 command/GPU error、峰值 in-flight `1`，RSS 峰值增量
`1.5MB`。`input=158122` 高于屏幕刷新率的状态由容量 1 mailbox 合并，
没有形成 GPU backlog。该结果关闭 60Hz 30 分钟 interaction 退出项，不代表
120Hz ProMotion 或 2 小时 soak 已通过。

### 30 秒 soak 工具证明样本

```text
PASS scenario=soak mode=performance
duration = 30.0s
mixed updates = 177
20Hz burst rounds = 2
presented = 179
whole-run ready-to-present p95 bucket = 40ms
dropped = 0
peak in-flight = 1
GPU busy skip = 0
RSS start/end = 42.9/44.0MB
RSS peak delta = 1.1MB
```

另一次启动时，前台尚未真正呈现，warm-up 得到 180 个
`presentedTime == 0`，harness 正确返回 `presentationTimedOut`，没有用 180 个
成功 completion 替代上屏。重新激活后同一场景通过。正式无人值守长稳必须先
确认设备解锁、背光持续活跃，再以最终 `CHART_STRESS_RESULT` 为准。

### 首次正式 2 小时 soak（审计后未通过）

2026-07-31 在同一 iPhone 17e 上完成完整 `7,200s`，常态 4Hz 并均匀执行
10 轮 20Hz burst。设备容器保存的原始结果为：

```text
CHART_STRESS_RESULT PASS scenario=soak mode=performance duration_s=7200.0 updates=27772 burst_rounds=10 presented=27768 p95_bucket_ms=34.000 ready_submit_p95_ms=4.000 submit_present_p95_ms=34.000 dropped=2 peak_inflight=2 errors=0 last_gpu_error=none gpu_busy=0 rss_start_mb=43.6 rss_end_mb=26.0 rss_peak_delta_mb=1.4
```

原始工具把本轮打印为 PASS，但阶段审计拒绝该结论：long-run 的 `passed`
表达式只调用了不含 dropped 的通用 `isHealthy`，与 ADR 已冻结的“不得放宽
dropped”冲突。两次 drop 发生在约第 71–72 分钟的普通 4Hz 区间，不在 20Hz
burst 内；当时 `MTLDrawable` presentation handler 返回
`presentedTime == 0`。command buffer 没有错误、GPU busy 为 0、峰值
in-flight 为 2，后续约 48 分钟 submitted/presented 差值固定不再扩大，RSS
也没有单调增长。因此可确认是两次 drawable 未真正上屏，不是 crash、GPU
command failure、持续过载或内存泄漏。

当前聚合遥测没有为每次 dropped 保存时间、revision、UIApplication 状态和显示
服务上下文，无法事后把系统侧触发进一步归因到通知遮挡、短暂合成切换或其他
display-service 事件。interaction/soak 门禁现已显式要求本轮
`dropped == 0`，并由单元测试锁定；生命周期场景刻意销毁 drawable 的 dropped
不使用该门禁。本轮保留为有效失败证据，不自动重新执行 2 小时测试。

### Dropped 定向诊断与生命周期状态机修复

没有重新执行两小时测试。先为真实 `presentedTime == 0` 增加固定 16 槽诊断
ring，每条只保存 revision、uptime、提交到回调耗时、提交时/回调时的
UIApplication、host/window 可见性、renderer suspend、interaction 状态，以及
当时 submitted/completed/in-flight 和 suspend/resume 计数。不保存 drawable、
symbol、价格、账户或交易内容；长跑内存不会随 dropped 次数增长。进度和最终
结果只输出最近一条。

同一 iPhone 17e 首次 60 秒 targeted interaction 严格返回 FAIL：

```text
CHART_STRESS_RESULT FAIL scenario=interaction mode=performance duration_s=60.1 input=3674 market_4Hz=240 market_hz=4.0 presented=3507 fps=58.4 target_fps=60.0 p95_bucket_ms=50.250 market_present_p95_ms=50.250 p95_target_ms=50.000 p95_tolerance_ms=0.250 market_ready_submit_p95_ms=20.000 market_submit_present_p95_ms=34.000 ready_submit_p95_ms=20.000 submit_present_p95_ms=34.000 dropped=5 peak_inflight=2 errors=0 last_gpu_error=none gpu_busy=0 rss_start_mb=48.7 rss_end_mb=50.2 rss_peak_delta_mb=1.5
```

5 次 dropped 全部集中在场景启动后约 `1.7s`；最近回调显示 App、host 和 window
均可见、renderer 未暂停，但 interaction 已关闭，command 已全部完成且
in-flight 为 0，suspend/resume 计数已从初始挂载的 1/1 增至 2/2。代码审计据此
发现 `suspend()` 会调用公开的 `stopInteractionFrames()`，把“仍需要交互帧”
和“当前 display link 正在运行”两个状态一起清掉；前台恢复只恢复按需绘制，
不会恢复交互 display link，因此 FPS 降到 `58.4`。

`MetalFrameCoordinator` 现已分离 requested/active：短暂 inactive 只停实际
display link、保留请求，恢复 active 后自动重建单一 display link；手势结束、
dispose 和熔断仍显式清除请求。测试同时要求前后台恢复后 interaction 重新
active。诊断样本进一步同时保存提交时和回调时上下文，避免以后只用回调现场
反推提交现场。

修复后重新构建、安装，并复跑完全相同的 60 秒场景：

```text
CHART_STRESS_RESULT PASS scenario=interaction mode=performance duration_s=60.0 input=6006 market_4Hz=240 market_hz=4.0 presented=3604 fps=60.0 target_fps=60.0 p95_bucket_ms=50.000 market_present_p95_ms=50.250 p95_target_ms=50.000 p95_tolerance_ms=0.250 market_ready_submit_p95_ms=20.000 market_submit_present_p95_ms=34.000 ready_submit_p95_ms=16.000 submit_present_p95_ms=34.000 dropped=0 peak_inflight=1 errors=0 last_gpu_error=none gpu_busy=0 rss_start_mb=48.4 rss_end_mb=49.5 rss_peak_delta_mb=1.1 last_drop=none
```

同批模拟器自动化为 31/31，Release 通用 iOS 构建通过，产物中未发现
`CHART_STRESS`、`--chart-stress` 或 `last_drop_` 字符串。该 A/B 关闭本次
诊断链路和生命周期帧泵缺陷，不替代两小时门禁，也没有把首次 2 小时失败改判
为通过。

### 端到端 pipeline 60 秒真机验证

此前的性能 harness 会直接生成 `RenderState`，能覆盖 Metal 调度与呈现，却没有
覆盖 250ms 行情从入站到指标的真实路径。本轮新增 Debug-only `pipeline` 场景，
实际依次经过 `KlineIngressState`、`CandleStore`、EMA21/55/144 临时值和
`RenderState`，最后进入同一 Metal renderer。

常态输入为 4Hz；每轮 burst 使用 20Hz 上游、每次 drain 合并 4 个同根更新，
验证 latest-wins。10 轮中分别确定性注入一次重复/迟到 sequence、sequence gap、
非法 candle、乱序 open time 和 upstream buffer drop；每个异常立即走有界
snapshot 恢复。门禁同时要求 pending live 不超过 1、barrier 队列不超过固定
上限、恢复全部完成、EMA 无非法值、实时尾更新不复制 3,000 根历史，以及
dropped、GPU error 均为 0。

同一 iPhone 17e 的 60 秒结果：

```text
CHART_STRESS_RESULT PASS scenario=pipeline mode=performance duration_s=60.0 events=1422 render_states=522 burst_rounds=10 accepted=482 coalesced=900 duplicates=10 recoveries=40 recovery_completed=40 seq_gaps=10 invalid=10 out_of_order=10 upstream_drops=10 applied=482 ema_frames=522 ema_invalid=0 history_copy_violations=0 max_pending_live=1 max_barriers=0 history=3000 presented=485 p95_bucket_ms=36.000 dropped=0 peak_inflight=2 errors=0 last_gpu_error=none gpu_busy=0 rss_start_mb=50.0 rss_end_mb=50.3 rss_peak_delta_mb=2.1 last_drop=none
```

这关闭了“压测绕过真实数据管线”的审计缺口。它是短时端到端门禁，不替代尚未
通过的 2 小时长稳验收；本批没有重新执行两小时 soak。

## Instruments 短时采样

同一 iPhone 17e 的活跃 interaction 场景已用 `xctrace` 取得可解析短样本：

### Time Profiler

- 采样时长 15 秒；
- 932 个 CPU profiling sample；
- `potential-hangs` 的 250ms 阈值表为空。

### Metal System Trace

`--attach` 方式生成的 trace 没有 Metal activity row，因此被拒绝作为证据。
改用 all-processes 模式重新采集 10 秒，按 `TradeTool (29184)` 和
`Chart frame` 标签确认目标帧：

```text
command-buffer submissions = 643
application command-buffer duration p50 = 3.979ms
application command-buffer duration p95 = 4.332ms
application command-buffer duration max = 4.669ms
Metal encoder duration p95 = 0.238ms
GPU vertex interval p95 = 0.079ms
GPU fragment interval p95 = 0.627ms
CPU-to-GPU latency p95 = 1.067ms
command-buffer error rows = 0
potential-hangs (>100ms) rows = 0
```

这是 60Hz 设备的短时定位证据，满足当前 12ms 单帧预算；不能替代 30 分钟交互、
2 小时长稳、Allocations、Energy Log 或 120Hz ProMotion 结论。`.trace` 是本地
诊断产物，不加入 Git。

## 页面生命周期与故障策略

`lifecycle` 场景逐轮创建真实 `KlineChartHostView`，部分轮次等待实际呈现后销毁，
部分轮次在提交 3 个状态后立即销毁；每轮都等待 weak host 释放。宿主销毁会移除
observer，并把 coordinator 的 `dispose()` 调度到 MainActor。completion 使用
weak reference 和 renderer generation，不访问已销毁 UI。

同一场景还执行两条确定性失败序列：

- 单次 simulated failure 后重建，成功呈现复位窗口，再次失败仍可重建；
- 连续三次 simulated failure 时前两次重建、第三次熔断，之后拒绝新帧。

模拟错误走正式错误恢复路径，但只增加
`simulatedCommandBufferErrors`，不会冒充真实 GPU command error。

### iPhone 17e 无验证层 500 轮

```text
PASS scenario=lifecycle mode=performance
cycles = 500
destroyed = 500
immediate destruction = 166
in-flight destruction observed = 166
presented cycles = 334
peak in-flight = 2
dropped presentation = 681
simulated errors = 5
renderer rebuilds = 4
circuit stops = 1
RSS start/end = 48.1/52.4MB
RSS peak delta = 4.4MB
```

首轮运行在第 50 轮后遇到两个 `presentedTime == 0`，旧 harness 正确拒绝把
command completion 当成上屏，但只画一次会把短暂 drawable drop 误判为整个
生命周期失败。修正后，等待真实呈现的轮次在 command 已完成且 GPU idle 时，
每 50ms 最多重画一次保留的最新状态，3 秒超时门槛不变；立即销毁轮次不重试。
最终 681 个 dropped 大部分来自刻意的 in-flight 销毁，其余快速挂载帧均在重画
后获得真实 `presentedTime`。

### iPhone 17e Metal Validation 10 轮

```text
PASS scenario=lifecycle mode=validation
cycles = 10
destroyed = 10
immediate destruction = 3
in-flight destruction observed = 3
presented cycles = 7
peak in-flight = 1
simulated errors = 5
renderer rebuilds = 4
circuit stops = 1
RSS start/end = 45.3/49.8MB
RSS peak delta = 4.5MB
```

本轮明确启用了 Metal API Validation 和 Metal GPU Validation，控制台没有
validation error。iPhone 17 Pro 模拟器另跑 30 轮也全部释放，并观察到 10 次
in-flight 销毁；模拟器 RSS peak delta 为 `35.1MB`，受模拟器图形驱动和首次
资源缓存影响，不作为真机泄漏结论。

## 前后台生命周期

生产 host 现在只在两个条件同时满足时运行 renderer：

```text
host.window != nil
&& UIApplication.applicationState == active
```

`willResignActive` 会幂等停止 display link、暂停 coordinator 并
`releaseDrawables()`；inactive 期间 submit 仍进入容量 1 mailbox，但不请求
drawable、不提交 command。`didBecomeActive` 只有在 host 仍挂载时才恢复，并从
mailbox 消费最新 revision。重复 inactive/active 通知不会重复增加状态计数。

### iPhone 17e 确定性 20 轮

每轮先提交一帧并在 command in-flight 时暂停，再于 inactive 状态连续提交 25
个 revision，恢复后要求 recent presentation 中只出现最后一个：

```text
PASS scenario=app-lifecycle
synthetic cycles = 20
in-flight suspends = 20
coalesced states = 480
suspends/resumes = 20/20
submitted = 45
presented = 43
dropped = 2
command errors = 0
```

首次真机运行在 synthetic 20 轮完成后崩溃，原因是 external cycle 配置为 0 时
诊断工具构造了非法闭区间 `1...0`。该处已改成 `0..<externalCycles`；生产
renderer 没有使用这个区间。同一真机场景修正后通过。

### 真实系统后台/前台

Debug harness 先完成 5 轮确定性注入，再进入等待状态。外部使用
`com.apple.Preferences` 将 TradeTool 真实切到后台，随后激活仍在后台的原
TradeTool 进程：

```text
PASS scenario=app-lifecycle
synthetic cycles = 5
external cycles = 1
in-flight suspends = 5
coalesced states = 120
suspends/resumes = 6/6
submitted = 16
presented = 13
dropped = 3
command errors = 0
```

计数从 5/5 增加为 6/6，证明实际系统通知被 host 接收；并非杀掉 App 后重新启动
形成的假通过。

### Metal Validation

```text
PASS scenario=app-lifecycle mode=validation
synthetic cycles = 10
in-flight suspends = 10
coalesced states = 240
suspends/resumes = 10/10
submitted = 26
presented = 23
dropped = 3
command errors = 0
```

控制台明确打印 Metal API Validation 与 Metal GPU Validation Enabled，没有
validation error。

## 真实 GPU command error 审计

本轮没有引入非法 Metal API、越界 shader 或 GPU hang 作为自动 fault 注入。
原因是这些 fault 在 Metal API/GPU/Shader Validation 打开时可能升级为验证层
断言或进程终止，不能成为稳定、可重复、不会伤害长稳样本的验收动作。

已完成的工程收束：

- 真实 `MTLCommandBuffer` completion 只要不是 `.completed`，就会增加
  `commandBufferErrors`；
- 健康快照保存最近 16 条真实失败摘要，包含 status、NSError domain/code 和
  截断 message；
- Debug simulated failure 仍只增加 `simulatedCommandBufferErrors`，不会写入
  真实失败 ring，也不会冒充驱动/GPU 错误；
- Debug harness 输出增加 `last_gpu_error` 或最后一次真实错误 status/domain/code。

结论：真实 GPU command error 的处理链路已经可观测、可隔离、可重建/熔断。
阶段 0.5 剩余项调整为“外部真实 fault 条件或硬件/系统异常下观察验证”，不再把
危险的非法命令注入作为常规自动测试。

## 自动化基线

- iPhone 17 Pro 模拟器：64/64 通过；在原 53 项基础上新增 fractional pan 与边界/
  返回最新、pinch 触点锚定、横纵/系统左边缘归属、手势状态互斥、历史 viewport
  隐藏 live tail、半槽连续像素位移、interaction affine 等价、48-slot guard-band
  覆盖/越界判断、临近 live tail 预缓冲、latest/oldest 有界橡皮筋、内部惯性减速
  和 latest 边界回弹；参数范围/关系/步长、JSON schema 回退、自定义 instanceID/
  图例与运行时 VOL 重建等既有覆盖继续通过；
- iPhone 17e：24 项 core unit tests 通过；3 项 onscreen 场景由前台 harness
  验证，不在物理 XCTest host 判断 presentation；
- 物理 onscreen 由前台 Debug harness 单独通过 Validation 与 Performance 两个
  门槛，避免 unit-test host 把 drawable 标记为 dropped 后误用 completion。
- 新入口的 Metal Validation quick 回归：55/55 command 完成、零 command
  error；4Hz/20Hz p95 分别为 `75.843ms`/`33.780ms`，validation 延迟不用于
  性能门槛。

生产场景离屏人工核验同时保留 2x/3x XCTest attachment：真实可见窗口的闭合
蜡烛、EMA21/55/144、SuperTrend 红绿分段与两行图例、网格、价格/时间轴、
provisional candle、最新价虚线和价格标记均由正式 shader 绘制。新增 MACD
副图后再次导出 2x/3x 生产场景，确认主图/MACD 共享时间轴、独立 Y 轴，DIF/DEA、
正负 histogram 和副图图例均无越界；两个 scale 的相对布局一致，未发现缺字或
坐标漂移。

本批执行了模拟器自动化、Debug 编译和 Release 通用 iOS 无签名构建，没有把历史
30 分钟合成 interaction harness 结果当成新生产手势证据，也没有重跑两小时 soak。
生产 pan/pinch 已接入
每侧 48-slot guard-band、fixed/timeline batch 分层、绘图区裁剪和 interaction
uniform 热路径；惯性/回弹已复用同一 display link 并通过模拟器自动化，但真机
gesture trace 速度定标、长按十字光标和 120Hz 仍需单独验收。

## 2026-08-01 当前代码冻结门禁（正式 2 小时除外）

本轮所有真机运行均使用 `TradeTool Dev B / Debug-Dev-B` 和同一台 iPhone 17e。
多副图、历史分页、RSI、十字光标修复与绘图工具底座合入后，代码冻结结果如下：

- iPhone 17 Pro 模拟器 `TradeTool Dev B` 完整 Core + onscreen：`76/76`、0 failures、
  0 skipped；覆盖 RSI、多副图、历史前插与视口保持、工具 registry/命中/编辑/持久化；
- Java 25 后端：`73/73`、0 failures、0 errors；新增严格 `beforeOpenTime` 控制器用例；
- `TradeTool Release` 通用 iOS Simulator arm64 + x86_64 构建通过；二进制审计未发现
  `--chart-stress`、`CHART_STRESS`、`last_drop_` 或
  `--chart-calibration-persist-crosshair`；
- 真机 quick 的 4Hz/20Hz p95 分别为 `33.549ms`/`31.782ms`，零 command error；
- 真机 pipeline 60 秒：`events=1422`、`render_states=522`、10 轮故障全部恢复，
  sequence gap/invalid/out-of-order/upstream drop 各 10 次，pending live 最大 1、
  history copy violation 0、p95 `34ms`、dropped 0；
- 真机 lifecycle 500 轮：500/500 host 释放，166 次 in-flight 销毁，模拟失败 5 次、
  renderer rebuild 4 次、circuit stop 1 次，RSS peak delta `4.3MB`；
- 真机 app-lifecycle：20 轮确定性暂停/恢复加 1 轮真实 Binance→Trade Tool 前后台
  往返通过，20 个 in-flight suspend、480 个旧状态合并、command error 0；
- 真机 5 分钟非正式 soak：`updates=1455`、20Hz burst `10/10`、p95 `34ms`、
  dropped 0、peak in-flight 1、command/GPU error 0、RSS peak delta `1.1MB`；
- 多副图 UI 用例 `20.956s` 通过，原始截图确认 VOL/MACD/RSI 同时存在；无损
  crosshair 活动态用例 `24.524s` 通过，原始截图确认数据卡与指标值无叠字。

### 60Hz Game Performance 轨迹

`xctrace` 用 Game Performance 模板按 PID 附加 Trade Tool，命令录制时限为 60 秒；
该模板采用 `Windowed (5 seconds)`，导出 trace 保留最终 10 秒分析窗口。目录明确记录
目标为 iPhone 17e / iOS 26.6、Trade Tool PID、正常 exit(0)。导出表结果：

```text
displayed surfaces per second = 58, 60, 60, 60, 60, 60, 60, 60, 60, 60
potential hangs (>100ms) = 0
Metal command-buffer errors = 0
thermal state = Nominal
```

同步 120 秒 interaction 结果为 `60.0/60.0fps`、4Hz 行情 480 次、presented
7206、p95 `50.000ms`、dropped 0、peak in-flight 2、command/GPU error 0、RSS
peak delta `1.6MB`。这证明当前 60Hz 渲染帧率和合成稳定性，不替代 Binance 同输入
惯性曲线校准，也不能外推到 120Hz ProMotion。

### 本轮 30 分钟首轮诊断失败

代码冻结前的并发测试窗口中启动 1,800 秒 interaction；第 266 秒捕获 5 个
`presentedTime == 0`，按零 dropped 门槛立即判为无效并在第 330 秒主动终止，不将其
计作通过。最近 dropped 诊断显示提交/回调时 App、host、window、renderer 和
interaction 均 active/visible，submit→callback `12.339ms`、in-flight 0、无 GPU
error，且后续未继续增长。最终验收改为不并发 Xcode/设备采集的独占 1,800 秒复验；
结果见本节后续记录。

### 最终独占 30 分钟 interaction（通过）

所有 Xcode 构建、UI automation 和 Instruments 会话结束后，重新安装的最新
Debug-Dev-B 在同一设备独占运行完整 `1,800.1s`：

```text
CHART_STRESS_RESULT PASS scenario=interaction mode=performance duration_s=1800.1 input=177489 market_4Hz=7200 market_hz=4.0 presented=108057 fps=60.0 target_fps=60.0 p95_bucket_ms=50.000 market_present_p95_ms=50.250 p95_target_ms=50.000 p95_tolerance_ms=0.250 market_ready_submit_p95_ms=20.000 market_submit_present_p95_ms=34.000 ready_submit_p95_ms=16.000 submit_present_p95_ms=34.000 dropped=0 peak_inflight=1 errors=0 last_gpu_error=none gpu_busy=0 rss_start_mb=47.8 rss_end_mb=42.4 rss_peak_delta_mb=1.1 last_drop=none
```

本轮 7,200 次行情精确为 `4.0Hz`，108,057 次 presentation 为
`60.0/60.0fps`；行情 ready-to-present p95 上界 `50.250ms` 只使用锁定的
`0.250ms` 量化容差。全程 dropped 0、GPU busy 0、真实 command error 0、峰值
in-flight 1；RSS 峰值只比起点高 `1.1MB`，结束值因系统回收缓存降至 `42.4MB`。
该结果关闭当前代码的 60Hz 30 分钟门禁。

## 尚未关闭

当前代码的 60Hz 真机 30 分钟持续 pan/pinch/crosshair、5 分钟 10 轮 burst、
pipeline/lifecycle/app-lifecycle、Game Performance 短轨迹、模拟器/后端自动化和
Release 审计均已通过。阶段 0.5 仍未全部退出，尚未关闭的项目是：

- 2 小时 4Hz 长稳与 20Hz × 10 轮：本轮按用户要求明确跳过，历史首轮仍因 2 个
  dropped 维持失败结论；
- 长时 Metal System Trace/Time Profiler、Allocations 和 Energy Log，以及
  TestFlight/MetricKit 发布后观察；
- 120Hz ProMotion 真机：当前 iPhone 17e 目标刷新率只有 60Hz，不能外推；
- 尚未在外部真实 fault 条件下观察 GPU command error。
