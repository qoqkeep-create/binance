# iOS K 线首屏延迟执行报告

> **执行结果索引（2026-11-01 14:05，北京时间）**：P0 已补齐并验证；P1 实测当前成本后保留现有缓存／索引，P2 根据 20 次热进入 P95 756 ms 的模拟器首帧代理结果结束，未扩大渲染改造。新发现并修复重连旧分页取消与恢复顺序问题。145 项 iOS、41 项行情后端回归全过，清理探针后 Release 编译通过。重启共 6 次、5 次有效进入，另一次进入列表前超时保留待查；真机、确认冷缓存首帧及 TestFlight 12 对应源码仍待验。后端早已更新为 range 版，本次没有重新发布、提交或推送。现行结论和证据以 [行情主文档](../market-data.md#按首屏交接计划补验2026-11-01)、[开发](../development.md)、[运维](../operations.md) 及 [变更](../changes.md) 为准。
>
> 以下保留用户提供且尚未提交的交接原稿，属于来源材料；其编制时的线上状态和待办不代表执行后的现状，不作为第二份操作手册。按协作规则保留原始材料，后续若归档应先保留可恢复的 Git 基线。

> 给执行会话：先核对当前工作区和运行版本，再逐项验证、补齐已有修复。不要按旧排查结论重复覆盖正在进行的改动。本报告交付范围是本地修复、必要回归和性能证据；提交、推送、服务器发布及 TestFlight 分发以执行会话已有的用户授权为准。

**Goal:** 降低“点进 K 线后，空白或转圈较久”的等待，保持历史、指标、实时合并和分页正确性。

**Architecture:** 保持 REST 历史快照 → 指标计算 → SwiftUI 场景 → Metal 绘制，以及 WSS 增量更新的现有结构。优先验证请求合并和 HTTP 压缩，再依据分段计时决定是否优化冷缓存和首帧准备。

**Tech Stack:** Python 3.11、Django / DRF / ASGI、MySQL、Redis、SwiftUI、Swift Concurrency、Metal、XCTest。

**编制时间：** 2026-11-01，北京时间。最新本地源码复核约 13:16；线上状态为上一轮只读核查的快照，执行前必须重新核对。

**本报告状态：** 执行计划，不是已修复、已测试或已发布证明。编制本报告未修改程序、配置或服务器。

## 1. 项目与工作边界

| 用途 | 位置 |
| --- | --- |
| 唯一修改目标 ROOT | `/Users/apple/work/TradeTools-Binance/TradeTools-Binance-iOS` |
| 快速 USDC 参考项目，只读 | `/Users/apple/work/tradetools-usdc` |
| 整合后端 | `47.80.22.243`（首尔服务器） |
| API 基址 | `https://47.80.22.243/integrated/` |
| 独立 Git 元数据 | `/Users/apple/work/TradeTools-Binance/TradeTools-Binance-iOS/.integration-runtime/github-publish.git` |
| 本地 HEAD 参考 | `74b8e5d`，工作区存在大量未提交及已暂存改动，HEAD 不代表当前全部代码 |

先阅读 ROOT 下的 `AGENTS.md`、`docs/README.md`、`docs/INTEGRATION.md`、`docs/market-data.md`、`docs/development.md`、`docs/operations.md` 和 `frontend/ios-app/docs/KLINE_CHART_ARCHITECTURE.md`，以及父目录的 `AGENTS.md`。具体业务和配置以当前源码为准。

约束：

- 修改集中在整合项目；保留用户和其他会话已有改动。不要回滚、清理、覆盖或顺带暂存无关文件。
- 不修改交易策略、报价资产、行情覆盖范围、账户绑定、持仓、订单或资金。普通测试使用隔离数据和交易所替身。
- 保留 1500 根指标预热和当前显示窗口，不通过减少历史、关闭指标、关闭校验或伪造 K 线来取得速度数字。
- 保留 epoch / sequence、晚到快照不回退实时数据、历史排除边界、收盘状态和账户隔离。
- 保留后台补线、订阅确认补读及 15 秒兜底校对，避免优化后漏掉订阅建立前的就绪通知。
- 不关闭 TLS 校验。不把 Token、密码、环境文件、账号资料、日志和构建产物加入 Git。
- 不把此报告当作新增部署授权；有既有授权就按范围推进，无授权先交付可审阅的本地成果。

该目录嵌在父 Gitee 仓库中。使用独立元数据，避免误操作父仓库：

```bash
cd /Users/apple/work/TradeTools-Binance/TradeTools-Binance-iOS
git --git-dir=.integration-runtime/github-publish.git --work-tree=. status --short
git --git-dir=.integration-runtime/github-publish.git --work-tree=. diff --stat
```

## 2. 已有证据及其边界

### 2.1 首屏链路

两套 iOS 客户端首次都请求 1500 根历史，等待响应、排序、安装快照和指标后才产生首个 `chartDataFrame`。不能把差距解释为一套请求少、一套请求多。

USDC Java 版历史 Controller 首先查询 MySQL；不能声称它的首屏直接来自 Redis。整合版当前历史读取使用本地 MySQL / Redis 快照，缺线由后台补全，不应恢复 HTTP 内同步请求 Binance 的旧实现。

两套 Metal 核心实现基本相同。GPU 绘制不是现有样本中的主要耗时来源；渲染器初始化仍计入首屏等待，不能把二者混为一项。

### 2.2 已有模拟器分段记录

来源：ROOT 下 `.integration-runtime/chart-hang-device.log`，2026-11-01 13:07 的已有记录。本报告仅重新分解，未重新运行该场景。

| 阶段 | 约耗时 |
| --- | ---: |
| `chart_start` → 成功返回的那次历史请求开始 | 831 ms |
| 该次 API 调用，包含 HTTP 与解码 | 1159 ms |
| API 返回 → 快照 / 指标准备完成 | 223 ms |
| 后续调度、场景、宿主准备至首次 GPU 完成 | 603 ms |
| 合计 | 2816 ms |

后续阶段中，`scene_ready` 约 2.4 ms，宿主初始化约 267 ms，GPU 提交至完成约 9 ms。前面的 831 ms 尚未细分，不能全部归因为取消重发。首次 GPU 完成也不等同于精确的屏幕呈现时刻。

已有 XCTest `CHART_PROBE` 记录约 6.45～6.72 秒，包含自动化等待、点击与可访问性轮询；不能直接当作应用内部空白时长，或与上述 2.816 秒相减后归咎于渲染。

### 2.3 已有接口记录

来源均在 ROOT 下 `.integration-runtime/`，不属于本轮新增测量：

| 记录 | 结论 |
| --- | --- |
| `chart-hang-baseline.json` | BTCUSDT 1h 1500 根首次约 1036 ms，重复请求约 519 ms；服务端历史阶段分别约 206 ms / 19 ms；JSON 约 423 KB |
| `chart-hang-universe.json` | 12 个币种的 1h 响应约 607～921 ms，JSON 约 402～434 KB，采样均非 pending、非 stale |
| `chart-wire-before.json` | 即使请求声明 gzip，响应仍无 `Content-Encoding`；没有实际线缆压缩 |

`Server-Timing` 当前仅覆盖历史读取及统计缓存阶段，不包含整个鉴权、排队、JSON 渲染、压缩、传输和客户端呈现。不能把总耗时减去它的结果全部称为网络耗时。

### 2.4 源码、线上与手机必须分开

| 项目 | 编制时掌握的状态 | 下一步 |
| --- | --- | --- |
| 就绪通知打断首屏请求 | 旧源码存在；最新本地已出现 `historyRequestID`、`historyRefreshPending`、`refreshHistoryWhenIdle()` 及对应测试 | 验证完整性和回归，不重复实现 |
| HTTP gzip | 本地 `KlinesView` 已有 `@method_decorator(gzip_page)`，已有压缩回归测试 | 验证本地，再核对运行镜像与真实 HTTP |
| 线上版本 | 上一轮只读核查：47.80.22.243（首尔服务器）的 current 与运行 API 镜像为 `integrated-20261101-pruned-8ff1d7379c22`，运行源码未含 gzip | 执行前重新核查；本地 `chart-gzip-release.json` 或 tar 存在不等于已发布 |
| 冷缓存 | 最新窗口最多读 3000 根再截取；全局最多 64 个公共历史窗口；有冷热耗时差异证据 | P0 完成后根据剖析决定是否修改 |
| 手机安装包 | 未核实 | 记录版本号、构建号、来源和实际 API；服务器发布不能代替客户端升级 |

## 3. 代码入口

| 内容 | 文件 |
| --- | --- |
| 首屏、通知、任务取消与分页 | [MarketChartViewModel.swift](/Users/apple/work/TradeTools-Binance/TradeTools-Binance-iOS/frontend/ios-app/TradeTool/Features/Chart/MarketChartViewModel.swift) |
| `MarketFastPathTests`，包含在途下载、切周期、退出用例 | [ServerSwitchingTests.swift](/Users/apple/work/TradeTools-Binance/TradeTools-Binance-iOS/frontend/ios-app/TradeToolTests/ServerSwitchingTests.swift) |
| 请求、刷新 Token、完整响应解码 | [APIClient.swift](/Users/apple/work/TradeTools-Binance/TradeTools-Binance-iOS/frontend/ios-app/TradeTool/Core/Networking/APIClient.swift) |
| ready / ack 分发与能力协商 | [RealtimeClient.swift](/Users/apple/work/TradeTools-Binance/TradeTools-Binance-iOS/frontend/ios-app/TradeTool/Core/Networking/RealtimeClient.swift) |
| 快照、指标重建与实时合并 | [ChartDataPipeline.swift](/Users/apple/work/TradeTools-Binance/TradeTools-Binance-iOS/frontend/ios-app/TradeTool/Features/ChartEngine/Data/ChartDataPipeline.swift) |
| 场景与宿主初始化 | [KlineChartSceneView.swift](/Users/apple/work/TradeTools-Binance/TradeTools-Binance-iOS/frontend/ios-app/TradeTool/Features/ChartEngine/Host/KlineChartSceneView.swift)、[KlineChartHostView.swift](/Users/apple/work/TradeTools-Binance/TradeTools-Binance-iOS/frontend/ios-app/TradeTool/Features/ChartEngine/Host/KlineChartHostView.swift) |
| 历史 HTTP 与压缩 | [views.py](/Users/apple/work/TradeTools-Binance/TradeTools-Binance-iOS/server/market_stream/views.py) |
| 共享窗口、数据库读取、部分桶 | [service.py](/Users/apple/work/TradeTools-Binance/TradeTools-Binance-iOS/server/market_stream/service.py) |
| 公共历史缓存边界 | [history_cache.py](/Users/apple/work/TradeTools-Binance/TradeTools-Binance-iOS/server/market_stream/history_cache.py) |
| 字段转换；对外价格为数字 | [core.py](/Users/apple/work/TradeTools-Binance/TradeTools-Binance-iOS/server/market_stream/core.py) |
| gzip 与历史 API 测试 | [tests.py](/Users/apple/work/TradeTools-Binance/TradeTools-Binance-iOS/server/market_stream/tests.py) |
| 热路径、真实临时 Redis 与协议回归 | [test_fast_path.py](/Users/apple/work/TradeTools-Binance/TradeTools-Binance-iOS/server/market_stream/test_fast_path.py) |

函数名优先于旧行号。工作区在变化，不要依赖前一会话提供的固定行号。

## 4. 执行任务

### 任务 0：固定基线与复现口径

1. 读取规则、Git 差异、上述函数和已有测试，确认已有修复是否又发生变化。不要直接粘贴旧版本覆盖整文件。
2. 记录客户端提交及未提交范围、配置、模拟器 / 手机型号、安装构建、API、后端 release / 运行镜像和测试时间。
3. 使用专用模拟器与无绑定 QA；避免占用其他会话正在操作的模拟器。源码中已有无网络图表 fixture，只能证明功能，不能当作线上速度。
4. 复现一个最小场景：BTCUSDT、1h、1500 根、关闭交易统计面板、从列表点击进入图表。先跑单场景，再覆盖其他币种。
5. 复用既有计时；若缺少边界，只增加必要的 DEBUG 计时。以单调时钟记录点击、VM start、请求开始 / 结束 / 取消、解码、快照 / 指标、宿主初始化和首个有效画面。关联 symbol、interval、session、epoch、request ID 和触发原因，禁止记录凭证。
6. 明确约 831 ms 未归因部分在哪里；不要只盯着成功请求日志，因为取消的请求可能没有成功耗时日志。

**完成条件：** 能重复得到“点击到有效图表”的时间和请求次数，能区分一次请求慢与多次取消重发；无法完成的设备或线上测量明确标记未验证。

### 任务 1（P0）：验证并补齐在途请求合并

修改范围优先限制在 ViewModel 和现有 `MarketFastPathTests`。

预期行为：

```text
当前 symbol / interval 有历史请求在途：
  ack、匹配的 history 通知、15 秒校对 -> 只标记一次待刷新，不取消该请求
当前请求返回且仍属于当前 session / epoch：
  先安装并展示有效数据
  再消费待刷新标记，最多启动一次补读
切周期 / 切币种 / 退出：
  取消过期请求，清除其排队刷新，旧响应及旧 defer 不污染新会话
```

逐项执行：

1. 检查已有 `refreshHistoryWhenIdle()` 是否覆盖 ack、history 事件和定时校对；验证单个布尔 pending 能合并通知突发。
2. 运行已有门控下载测试：第一请求挂起时连续 6 次通知，不取消且仍只有 1 次读取；放行第一请求后必须先形成可用图表，随后最多 1 次补读，总共 2 次。
3. 如已有测试仅模拟 history event，补充真实结构的订阅 ack；同时验证其他 symbol / interval 不触发刷新。
4. 验证切周期仍取消旧请求、关闭页面仍取消下载和排队刷新、失败和取消后任务槽可释放，旧任务完成回调不清空新任务状态。
5. 验证分页同一边界的通知也合并，边界切换和取消不会串页。
6. 单独检查 `ready → beginRealtimeEpoch()`：真实重连涉及新 epoch，允许为正确性取消旧 epoch 请求；不要为了“零取消”跨 epoch 复用不安全数据。区别普通就绪通知与连接代际变更，补必要回归。
7. 保留 ack 后补读能力，验证补读可恢复订阅生效前遗漏的通知，且不会无限自触发。

**完成条件：** 普通就绪通知和定时校对不打断当前下载；第一份有效响应先展示；显式失效操作继续取消过期任务；正确性测试通过。

### 任务 2（P0）：验证已有 HTTP 压缩，核对实际生效范围

1. 检查本地 gzip 代码及 `FastHistoryApiTests.test_history_compresses_on_the_wire_without_changing_the_snapshot`，优先保留最小实现。
2. 验证 `Accept-Encoding: gzip` 返回 `Content-Encoding: gzip`、正确的 `Vary: Accept-Encoding`，解压后与 identity 响应语义相同，保留 `Server-Timing`、鉴权和错误行为。
3. 对固定的 1500 根测试数据断言压缩体小于原体一半；identity 请求保持普通 JSON。不要因每次 gzip 输出字节不同而要求压缩字节完全相等。
4. 在 HTTP 层测量真实 wire bytes。若用 requests，使用流式响应和 `response.raw.read(decode_content=False)`；`response.content` 可能已自动解压，不能拿它当压缩后流量。
5. 对线上只做少量串行行情读取。核对 current、运行镜像、容器实际源码和真实响应，不能用本地 decorator、release 清单、Nginx 的 `gzip on` 或构建成功单独证明 JSON 已压缩。
6. 如执行会话已获发布授权，验证本地实现后按现有发布流程上线并复测；否则完整交付代码、验证结果和待发布范围。客户端合并修复需要相应客户端构建，不能只部署服务器。

**完成条件：** 本地压缩协议回归通过；有权限且已发布的环境有实际压缩响应证据；未发布的环境明确说明，不能写“已生效”。

### 任务 3（P1，按测量决定）：降低冷缓存成本

仅当 P0 后 `history` 阶段仍显著影响首屏时执行，避免同时改变多处导致无法归因。

1. 分开测量缓存读取 / 解压、ORM 查询 / 对象构造、缓存写入压缩、partial bucket 和返回字段转换。不要把数据库读取和整个 `history` 阶段当成同一个值。
2. 检查最新窗口读 3000 根但请求只用 1500 根的成本；优先考虑按实际需要减少对象构造、字段读取或重复转换，同时保留共享窗口设计与分页正确性。
3. 检查缺少 live 桶时，`partial_bucket()` 读取完整分钟窗口的额外成本。任何缩小查询范围的实现必须保持分钟连续性检查及未收盘桶计算正确。
4. 数据库已有 `(symbol, interval, -open_time)` 索引；先看实际查询和执行计划，不直接重复建索引。确需结构变化时使用 Django 版本化 migration。
5. 检查 64 窗口容量与 revision 失效是否造成冷读，记录命中情况再判断。Redis 配额为 80 MB、`noeviction`，不可直接改成全市场预热、无限加缓存、全局淘汰或删除账户锁 / 预算键。
6. 保留 HTTP 不调用 Binance、统计只读缓存、任务去重和退避。若 P0 后首屏目标已达到且该阶段成本可接受，记录数据后结束该项，不扩大重构。

**完成条件：** 有该项的前后分段对比；若修改，历史内容、分页、实时合并、公共缓存边界和缺线恢复不回退。

### 任务 4（P2，按测量决定）：定位剩余客户端首帧成本

1. 将排序、安装快照、全量指标、MainActor 调度、场景构建、宿主 / Metal 初始化分开计时。
2. 对照 USDC 实现及同一运行条件，确认差异再改；原 GPU 执行约 9 ms，不能据此启动整个渲染器重写。
3. 不减少 1500 根预热，不关闭技术指标，不把后台不可见 GPU 完成冒充用户已经看到图表。
4. 仅对测得的重复初始化或阻塞做最小修改；如引入缓存，必须定义 symbol / interval / epoch / 指标参数的隔离与失效规则，并验证旧快照不覆盖新实时数据。
5. 清理临时 DEBUG 探针或纳入现有诊断入口；不要恢复已退役的无关诊断模块。

**完成条件：** 主要剩余等待均有可复核分段；若无明显瓶颈，结束该项，不做猜测性优化。

## 5. 验证命令和场景

以下命令在 ROOT 执行。只在隔离测试环境运行；不运行真实交易维护任务。若执行会话存在用户明确的“先不测试”指令，以该指令为准，记录未验项目，不把历史通过记录冒充新验证。

### 后端必要回归

```bash
PYTHONDONTWRITEBYTECODE=1 PYTHON_DOTENV_DISABLED=1 \
  DB_ENGINE=sqlite USE_REDIS_CACHE=False RUN_SCHEDULER_IN_WEB=false \
  server/.venv/bin/python server/manage.py test \
  market_stream.tests market_stream.test_fast_path --noinput
```

使用项目已有 Python 3.11 环境。真实临时 Redis 测试按 `docs/development.md` 设置 `MARKET_TEST_REDIS_BINARY`，仅由测试启动无持久化临时回环实例。未运行或被跳过必须单列，不能称为 Redis 协议已验收。若只改 gzip，先运行 `market_stream.tests.FastHistoryApiTests`，需要时再扩展。

### iOS 必要回归

先用 `xcrun simctl list devices available` 选择专用可用设备，将实际 UDID 填入变量；不要直接复用其他会话正在操作的设备。

```bash
export KLINE_SIMULATOR_ID='<专用模拟器的实际 UDID>'
xcodebuild \
  -project frontend/ios-app/TradeTool.xcodeproj \
  -scheme TradeTool -configuration Debug-Seoul \
  -destination "platform=iOS Simulator,id=${KLINE_SIMULATOR_ID}" \
  -derivedDataPath .integration-runtime/KlineFirstFrame/DerivedData \
  -parallel-testing-enabled NO \
  -only-testing:TradeToolTests/MarketFastPathTests \
  -only-testing:TradeToolTests/ChartEngineCoreTests \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

测试类 `MarketFastPathTests` 实际位于 `ServerSwitchingTests.swift`，不是独立同名文件。不需要运行 Java / Maven 测试来代替整合版验证。

### 功能与性能场景

| 场景 | 必验内容 |
| --- | --- |
| 已连接 WSS 后点击图表 | ack 不打断首屏下载，先展示第一份有效响应 |
| 下载期间通知突发 / 定时校对 | 单在途、通知合并、至多一次待处理补读 |
| 冷启动 / WSS 真重连 | 新 epoch 正确，旧响应不污染新连接 |
| 快速切币种、切周期、退出重进 | 取消过期请求，无旧图回闪、卡住或取消风暴 |
| 旧后端无 history capability | 保留 K 线 / ticker / 账户订阅及兜底恢复 |
| 缺历史 / 空 pending / 漏通知 / 请求失败 | 后台补全与有界重试继续工作，不长期无反馈 |
| 历史翻页及通知重叠 | 排除边界、去重、部分数据立即合并 |
| 开启持仓量 / 多空比等统计 | 统计缓存或待就绪状态不阻塞首屏历史 |
| BTC、ETH、ZEC、SOL、BCH、DOGE、BNB、ADA | 默认 1h 的基本进入验收；若交易对不存在，按目录实际情况记录 |
| 代表币种的 1m、1h、4h、1d | 周期切换、未收盘桶、指标与尾部一致 |

性能统计先选择 BTCUSDT 1h 做连续小样本，记录热 / 冷条件、样本数、P50 / P95 和失败数。以至少 20 次热进入、条件允许时 5 次自然冷进入作工程观察；不要为了制造冷读清空生产 Redis，也不要并发压测。冷读不能确认时标记未知。

以下为本报告提出的工程目标，不是已达结果或原用户承诺：

- 普通就绪通知导致的首屏请求取消次数为 0；一次通知突发最多产生一次补读。
- 固定 1500 根测试数据的 gzip wire bytes 小于 identity 的 50%。
- 同设备、同网络下，热进入首个有效画面的 P95 争取不超过 1.5 秒，自然冷进入争取不超过 2.5 秒。
- 线上网络波动可能使绝对值不稳定，必须同时给出各阶段与前后对照。未达目标时写清剩余瓶颈和适用范围，不隐瞒失败，也不无限扩大改动。

USDC 原 Java 服务在首尔已退役，不能把同一 IP 当前整合服务当作 Java 版进行在线 A/B。若无法在同条件运行参考版，应明确“代码对照 + 整合版前后测量”，不要承诺已证明与 USDC 体验完全一致。

## 6. 交付清单与结束条件

执行会话最终交付：

1. 实际修改的文件、修改原因，以及哪些原有修复被复用，哪些问题只是待验证假设。
2. 当前客户端构建、后端 release / 运行镜像、设备、网络、时间与统计配置。
3. 请求次数 / 取消次数、identity / gzip 真实流量、HTTP 与首帧分段、热冷样本统计、失败和跳过项。
4. 必要正确性回归结果；本地替身、模拟器、线上只读验证和真机结果分别陈述。
5. 本地、已提交、已推送、服务器已生效和手机已安装五种状态分别说明。
6. 维护结论合入 `docs/market-data.md`；命令变化写 `docs/development.md`；实际发布和验收写 `docs/operations.md` / `docs/changes.md`。任务完成后按文档维护规则合并并移除临时计划及目录入口，保留 Git 历史。

结束前执行：

```bash
git --git-dir=.integration-runtime/github-publish.git --work-tree=. diff --check
git --git-dir=.integration-runtime/github-publish.git --work-tree=. ls-files --others --exclude-standard
git --git-dir=.integration-runtime/github-publish.git --work-tree=. diff --stat
git --git-dir=.integration-runtime/github-publish.git --work-tree=. diff --cached --stat
```

新建且属于交付的安全源码、测试、文档应按具体路径加入该独立 Git 追踪；不要 `git add .`，不要顺带暂存其他会话的文件。最终说明新增追踪数量。权限与设备限制导致的未验范围清楚列出，不用编译成功或旧日志代替实际验收。

## 7. 可直接粘贴给执行会话的指令

```text
请执行 /Users/apple/work/TradeTools-Binance/TradeTools-Binance-iOS/docs/plans/2026-11-01-ios-kline-first-frame-handoff.md。

目标是改善进入 K 线页面后的空白 / 转圈等待。先读目标项目 AGENTS 和当前差异，核对最新实现与版本。报告编制时本地已存在在途请求合并及 gzip 改动，先验证和补齐，不要重复覆盖。优先完成 P0，再由分段计时决定 P1 / P2 是否需要修改；保留 1500 根指标预热、实时合并、分页及交易安全边界。

本次按报告完成本地修复、必要回归和性能证据，保留已有无关改动；提交、推送、部署和 TestFlight 以本会话已有用户授权为准。最终分别说明本地修改、后端生效和手机安装状态，以及前后性能数据和未验范围。
```
