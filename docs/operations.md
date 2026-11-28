# 整合环境部署与运维

## Web 顶部交易抽屉发布（2026-11-29，北京时间）

提交 `3d1f707` 已部署到 **47.80.22.243（首尔服务器）** 的静态 release `trade-web-20261129-trade-drawer-3d1f707`，原子切换 `/opt/trade-tools-integrated/web/integrated/market`。IP 与 `ba.wow211.com` 双入口页面和资源均返回 200，index/JS/CSS hash 分别为 `a9f3ea13…`、`e5fe82d8…`、`544303b8…`。后端未切换，上一版 `trade-web-20261128-iosrt-22065f2` 保留回滚。

提交 `8cf25d7` 已更新为 **`trade-web-20261129-trade-drawer-flow-8cf25d7`**。抽屉现在位于工具栏下方的 K 线正常布局流，展开时压缩 K 线区域，不覆盖工具栏。委托／历史改为单行信息列，操作列与持仓对齐，“交易”“自动”按钮补充图标。后端未切换，上一版 `trade-web-20261129-trade-drawer-3d1f707` 保留回滚。

提交 `26af399` 已更新为 **`trade-web-20261129-trade-drawer-rows-26af399`**。委托／历史与持仓统一字体和抽屉高度，最多显示 4 条，移除抽屉右上角收起按钮，交易箭头按展开状态切换方向。后端未切换，上一版 `trade-web-20261129-trade-drawer-flow-8cf25d7` 保留回滚。

## Web 交易抽屉历史分页发布（2026-11-29，北京时间）

提交 **`05ad966`** 已推送 `codex/integrated-ios`，静态 release **`trade-web-20261129-trade-drawer-history-05ad966`** 已原子切换到 **47.80.22.243（首尔服务器）** 的 `/opt/trade-tools-integrated/web/integrated/market`。历史抽屉首批 10 条，滚动到底部按 `pagination.has_next` 分页追加，委托继续最多 4 条。持仓、委托、历史固定相同抽屉高度，委托操作按钮与持仓保持同一行末列，交易对使用主币种＋缩小 `/USDT`。同时修正历史页对后端 `has_next` 字段的读取。后端容器和交易逻辑未切换，上一版 `trade-web-20261129-trade-drawer-rows-26af399` 保留回滚。

IP 与 `ba.wow211.com` 双入口均返回 200，index/JS/CSS SHA-256 前 16 位分别为 `c6efe8efbdb3e3e6`、`7b97002acc79aac2`、`057874dd24bcd9bb`。`/integrated/v1/health` 的 database、migrations、scheduler 均为 true，Nginx 配置检查和 reload 通过。

## Web 静态同步发布（2026-11-28，北京时间）

提交 `22065f2` 对应的静态包已部署到 **47.80.22.243（首尔服务器）** 的 `trade-web-20261128-iosrt-22065f2`，通过 `/opt/trade-tools-integrated/web/integrated/market` 原子切换。IP 与 `ba.wow211.com` 双入口 index/JS/CSS 哈希分别为 `aec9d54a…`、`7ca4ae9b…`、`e0fe3ed4…`，页面与资源均返回 200，`/integrated/v1/health` 的 database、migrations、scheduler 均为 true。上一版 `trade-web-20261128-linehit-97cda87` 保留回滚。

## iOS K 线实时链路改造发布（2026-11-28，北京时间）

完整提交 **`253f84b`** 已部署到 **47.80.22.243（首尔服务器）**，后端 release 为 **`integrated-quick-253f84b`**，api、market、worker、scheduler 四容器均 healthy，`/integrated/v1/health` 的 database、migrations、scheduler 均为 true。iOS 行情页实时消费拆为控制／K 线／ticker 三条 lane（`RealtimeClient` 按 lane 过滤），`MarketRealtimeStore` actor 做 symbol、eventTime 与重复包校验，`KlineIngressState` 兼容新 `closedSequence` 收盘水位缺口恢复，`ChartFrameScheduler` 在 16ms 窗口内合并 forming 帧、收盘与恢复帧立即发布。验证：iOS 27.2 `RefreshTest` 模拟器编译通过，`MarketRealtimeStoreTests`＋`ChartEngineCoreTests` 183 项通过、0 失败；Web `npm test`／`npm run build` 通过。Web 静态沿用 `trade-web-20261128-linehit-97cda87`（IP 与 `ba.wow211.com` 双入口 index/JS/CSS 哈希 `aec9d54a…`／`7ca4ae9b…`／`e0fe3ed4…`）。客户端本身未上传 TestFlight、未实机验收；本 release 全部提交已推送 GitHub（远程 HEAD 253f84b）。

## 划线工具命中区放大 Web 发布（2026-11-28，北京时间）

提交 **`97cda87`** 已切换到 **`trade-web-20261128-linehit-97cda87`**，目标为 **47.80.22.243（首尔服务器）**。划线的横／竖线原本是零高／零宽元素，可点击区只有 1～6px 的边框本身；新增 `::before` 隐形命中条带（横线上下各 7px、竖线左右各 7px，共 14px）后，指针落在线上或两侧约 6px 内都能选中／拖动，可见边框坐标不变。本地内置浏览器注入同结构元素验证：横／竖线在 −5～+8px 偏移均可命中（原为 2px），事件正确落到宿主元素监听器；`npm test`、`npm run build`、`git diff --check` 通过。发布：IP 与 `ba.wow211.com` 双入口 index/JS/CSS 哈希 `aec9d54a…`／`7ca4ae9b…`／`e0fe3ed4…` 与本地一致，`/integrated/v1/health` 三项 true。后端不切换，上一 release `trade-web-20261128-1hforming-6c50464` 记入 `backups/previous-web-market-20261128-linehit` 可回退。

## Web 高周期 forming 尾根修复发布（2026-11-28，北京时间）

Web 静态提交 **`6c50464`** 已切换到 **`trade-web-20261128-1hforming-6c50464`**，目标为 **47.80.22.243（首尔服务器）**。IP 和 `ba.wow211.com` 双入口均返回最新 JS `DwNFGGI6`，健康检查通过。修复规则是只有聚合周期最后一根源 1m 收盘时才关闭 1h／4h 等高周期桶，之前的早期 1m close 不再锁住当前高周期尾根。后端沿用 healthy 的 `integrated-quick-87da79d`。

## K 线 live 发布分块优化（2026-11-28，北京时间）

针对选中交易对在全市场 live 发布批次中等待过久的问题，提交 **`87da79d`** 已部署到 **47.80.22.243（首尔服务器）** 的 **`integrated-quick-87da79d`**。市场采集器现在把 live K 线 Redis 发布拆成每批 32 条，减少单次 Redis pipeline 对选中交易对的阻塞。四个应用容器 healthy，health 三项通过。Web 静态资源沿用上一版 `trade-web-20261128-realtime-cf8756b`，没有重新切换静态产物。

## iOS sequence 兼容修复发布（2026-11-28，北京时间）

针对首轮实时分流发布后发现的 iOS ingress 兼容风险，完整提交 **`cf8756b`** 已部署到 **47.80.22.243（首尔服务器）**。后端 release 为 **`integrated-quick-cf8756b`**，四个应用容器 healthy，health 三项通过。K 线保留旧的全局 `sequence`，closed 事件额外增加 `closedSequence`，旧 iOS 客户端继续按原序列处理。

Web 静态 release 已切换为 **`trade-web-20261128-realtime-cf8756b`**。IP 和 `ba.wow211.com` 双入口返回 JS 哈希 `d767f43e…`、CSS 哈希 `b27473e1…`，线上 JS 含 `closedSequence`。上一版 `trade-web-20261128-realtime-744fb64` 和后端 `integrated-quick-744fb64` 保留可回退。

## Web 实时行情分流发布（2026-11-28，北京时间）

完整工作区提交 **`744fb64`** 已部署到 **47.80.22.243（首尔服务器）**。后端 release 为 **`integrated-quick-744fb64`**，api、market、worker、scheduler 四个容器均 healthy，`/integrated/v1/health` 的 database、migrations、scheduler 均为 true。数据库、Redis 和 MySQL 未替换，没有应用 migration，也没有执行真实交易或资金操作。

Web 静态 release 为 **`trade-web-20261128-realtime-744fb64`**，已原子切换到 `/opt/trade-tools-integrated/web/integrated/market`。IP 入口和 `ba.wow211.com` 均返回 200，index 哈希 `1576fcc3…`，JS 哈希 `fbdbd930…`，CSS 哈希 `b27473e1…`，线上 JS 已包含 `market.ticker.batch`。上一 Web release `trade-web-20261128-kline3m-e6d66fc` 保留可回退。

本次发布包含 Web ticker 批量事件、ticker／K 线双 WebSocket、ASGI K 线优先队列、closed K 线 sequence 缺口恢复和前端尾部重绘合并。iOS 客户端未随本次发布，旧 `market.ticker` 协议由后端 fanout 兼容展开。后端保留原 K 线全局 sequence，并额外发送 `closedSequence`，避免影响旧 iOS ingress。

## 3 分钟 K 线桶宽修复（1m 根不再追加进 3m 图）Web 发布（2026-11-28，北京时间）

用户确认截图为 3 分钟周期，要求按分析方案直接实现并全量提交推送部署。根因：`lib/analysisIndicators.ts` 的 `intervalSeconds` 缺 `3m`，`KlineChart` 两处 `intervalSeconds[selectedInterval] ?? 60` 静默按 60 秒取桶；实时层只订阅 1m（`lib/realtime.ts` 固定 `intervals: ["1m"]`，大周期客户端聚合），于是同一 3m 桶内的 540/600 各成一根，180 秒历史间距右侧接上 60 秒间距＝右侧蜡烛挤叠。修复：新增 `knownIntervals`/`chartIntervals`/`isChartInterval`，`intervalSeconds` 改 `Record<KnownInterval, number>` 并补 `"3m": 180`；`KlineChart` 的 `INTERVALS`/`ChartPreference.interval`/`intervalRef` 收为 `ChartInterval`，两处 `?? 60` 删除；`analysisSnapshot` 的 `indicatorIntervals` 标 `SourceInterval[]` 并去掉冗余断言，`buildIndicatorRow` 参数收为 `KnownInterval`。缺周期自此是编译错误（独立样例实证 TS2741 与 TS2322＋TS7053）。测试：`candleMerge.test.ts` 首次走派生路径（9 个图表周期桶宽逐一核对、540/600 同桶只剩一根、3m/5m/15m 整桶 1m 只加一根且全部落周期边界＋时间严格递增、ticker 种子根同边界）；`klineChart.test.mjs` 契约锁定新声明并禁止 `?? 60`；把 3m 故意改成 60 秒后测试报 `3m must map to 180s, got 60` 且 exit=1（红灯确认）。提交 **`e6d66fc`**，`npm test` 全绿、`npm run build`、`tsc --noEmit`、`git diff --check` 通过。

发布：release **`trade-web-20261128-kline3m-e6d66fc`** 原子切换 47.80.22.243（首尔服务器，`ln -s`＋`mv -Tf`），tar 包 sha256 `5927d9b6…` 上传前后一致；index/JS/CSS 哈希 `58acc63e…`／`88076e4d…`／`b27473e1…` 与本地构建一致，ba.wow211.com 与 47.80.22.243（首尔服务器）HTTPS 双入口 `?cb=` 复核同哈希（CSS 未改，沿用 `b27473e1`），线上 JS 含 `"3m":180` 标记；`/integrated/v1/health` database/migrations/scheduler 均 true。构建取自提交树（`git worktree` 独立检出后打包），不掺入其他会话未提交改动。后端不切换，上一 release `trade-web-20261128-autobtn-3b968d4` 记入 `backups/previous-web-market-20261128-kline3m` 可回退。3m 尾根实时表现需线上带 WSS 目检验收。

**未随本次上线（阻塞项，待用户拍板）**：另一会话正在实时改 `server/market_stream/{bus,fanout,websocket}.py` 与 `frontend/trade-web/src/{lib/realtime.ts,lib/binance.ts}`（`docs/plans/2026-11-28-market-realtime-latency-design.md` 任务 1‑5，最后写入 06:20，任务 3‑5 前端未完成、计划要求的 `test_fast_path`/`test_fanout`/`test_coordination` 断言尚未补）。`market_stream` 112 项在隔离环境通过（唯一 error 是缺 `MARKET_TEST_REDIS_BINARY` 的既有环境限制）。风险实证：`bus.py` 把 `market.kline` 的 closed 事件改用独立序列作用域（`integrated:sequence:market.kline:{key}:closed`），而 iOS `ChartStreamKey` 仅 `(symbol, interval)`、`KlineIngressState.accept` 在分流 closure 之前先要求 `sequence == last + 1`，否则判 `.ignoredDuplicateOrLate`；两条计数器一快（forming 每分钟多次）一慢（closed 每分钟一次），上线后 iOS 会把收盘根整批当过期丢弃。该后端改动须先补 iOS 侧配套或改回单一计数器，再随后续后端 release 上线。

## 收起钮回抽屉内顶栏＋面板默认盘面（盘面｜交易带图标）＋自动/手动合并为单开关 Web 发布（2026-11-28，北京时间）

用户三点：① 展开态收起钮放回抽屉内部顶部（不再浮在抽屉外）；② 交易/盘面按钮互换，盘面在前、交易在后，默认停在盘面，两钮加图标；③ K 线右上角自动/手动合并为一个「自动」按钮，未选中＝手动、选中＝自动。实现：`.positions-dock` 去 `position: relative`、删除 `.positions-dock-open-toggle` 浮动规则，恢复 `.positions-dock-topbar`（`flex:none`＋居中＋`padding:4px 0`）作为抽屉首行，芯片仍 `min-width:108px` 居中；`pulse-mode-toggle` 两按钮改序为 盘面(`LayoutDashboard` 13px)→交易(`ArrowLeftRight` 13px)、`insightMode` 默认 `"pulse"`、按钮加 `inline-flex`＋`gap:5` 容纳图标；`KlineChart` 删除 `.view-mode` 双按钮组与 `role="group"`，改单个 `view-mode` 按钮，`aria-pressed={viewMode === "auto"}`，选中态走 `.view-mode.active`（绿描边＋12% 绿底＋600 字），未选中透明描边防漂移，点击在 auto↔manual 间切换（切回 auto 沿用 `viewModeApplyRef("auto") + resetView()`，切 manual 沿用原手动分支）。实测（本地 vite，720px 视口）：抽屉内 topbar 距抽屉顶 1px、芯片 108px 且与抽屉中线 delta 0、列头在其下方、`position: static`；面板默认 `aria-pressed` 为 盘面 true／交易 false、两钮均含 svg 图标、TradePanel 初始 hidden；工具栏右侧顺序 chart-refresh→view-mode→indicator-master→insight-toggle，单按钮 37×28，点击后 `pressed=false`＋边框转透明＋title 改「当前手动缩放，点击切为自动」，再点恢复绿芯片。契约测试同步：klineChart 锁 `.view-mode.active` 绿芯片＋禁 `>手动</button>`＋锁抽屉内 topbar，tradePanel 锁默认 pulse、盘面在交易之前、两图标存在。`npm test` 十项全绿、`npm run build` 通过、`git diff --check` 干净。本地提交 **`3b968d4`**（未推送）。Web release **`trade-web-20261128-autobtn-3b968d4`** 原子切换（目标 **47.80.22.243（首尔服务器）**，`ln -s`＋`mv -Tf`），index/JS/CSS 哈希 `d49d9a0f…`／`d74c15da…`／`b27473e1…` 与本地单链构建一致，ba.wow211.com 与 IP 双入口 `?cb=` 复核同哈希，线上 CSS 含 `.positions-dock-topbar`／`.view-mode.active`／`min-width:108px`、JS 含新 title 文案；`/integrated/v1/health` database/migrations/scheduler 均 true。后端不切换，上一 release `trade-web-20261128-uicompact-333c1fc` 保留可回退。宽屏桌面排列与手动模式拖动/自动复位归线上验收。

## 持仓钮加长一倍并移出抽屉＋右上角／开仓方式／盘面切换压缩改版 Web 发布（2026-11-28，北京时间）

用户五点：① 持仓开/关钮再加长一倍；② 抽屉打开后关闭钮移出抽屉，落在指标附图区紧贴持仓区上边缘；③ 右上角自动/手动/指标四钮缩到与右侧图标方块按钮同量级；④ 市价开仓/限价挂单缩小并改时间周期式下划线；⑤ 盘面/交易改顶部大按钮并去掉“交易”标题。实现：`.positions-dock-toggle` 加 `min-width: 108px`＋内容居中（收起态状态条与展开态同宽，实测 54→108px）；展开态改 `.positions-dock-open-toggle` 绝对定位 `bottom: 100%`＋`left: 50%`＋`z-index: 6`，删除 `.positions-dock-topbar` 独立行，实测钮下缘距抽屉上沿 1px、与抽屉同中线 463px；`.view-mode`／`.indicator-master` 统一 28px 高、11px 字、指标图标 15→13px，实测组宽 110→70px、指标钮 67→46px；`.trade-type-row` 去边框改 `button.active::after` 2px 绿下划线，实测 68×29px；`insight-panel` 顶部删除 MARKET PULSE 眉题与 h2 标题，`pulse-mode-toggle` 改整宽“交易｜盘面”二段按钮（实测 45px 高、选中沿用自动/手动同款绿芯片），`aside` 改用 `aria-label`，未使用的 `ArrowLeftRight` 导入删除。契约测试同步改锁（klineChart 的 topbar 断言换为 open-toggle 定位与 108px、字号断言换为 28px/11px；tradePanel 的绿芯片断言换为下划线与二段按钮）。`npm test` 十项全绿、`npm run build` 通过、`git diff --check` 无空白问题。本地提交 **`333c1fc`**（未推送）。Web release **`trade-web-20261128-uicompact-333c1fc`** 原子切换（目标 **47.80.22.243（首尔服务器）**，`ln -s`＋`mv -Tf` 单链切换），index/JS/CSS 哈希 `389cce6b…`／`125d0be5…`／`e8bc0e99…` 与本地单链构建一致，ba.wow211.com 与 IP 双入口 `?cb=` 复核同哈希，线上 CSS 已含 `positions-dock-open-toggle`、`min-width:108px`、`trade-type-row button.active:after`、`pulse-mode-toggle button` 四项标记；`/integrated/v1/health` database/migrations/scheduler 均 true。后端不切换，旧 release `trade-web-20261128-dockcenter3-f263e80` 保留可回退。本地浏览器视口仅 720px，宽屏桌面排列与四项最终观感归线上验收。

## 持仓钮最终归位：收起＝底部状态条内 K 线中线居中，展开＝列表上方 topbar 居中（关闭即卸载）Web 发布（2026-11-28，北京时间）

用户澄清：持仓钮初始应放在 K 线区域中线最下方的空白条（状态条）上，而不是持仓列表里；列表打开后，关闭按钮放在持仓列表以外的上方居中。实现：删除 PositionsDock 内 closed-wrap 渲染，收起态改由 App 状态条渲染 `.statusbar-dock-toggle`（absolute left=实测 chart-workspace 中心 x，ResizeObserver＋window resize 重算，随面板/助手显隐更新）；展开态保留 `.positions-dock-topbar` 居中芯片，且 `if (!open) return null` 整体卸载，消除收起时残留的 1px 边框线。实测（本地 vite＋sqlite）：收起 btnCenter==wsCenter（delta 0）且按钮矩形完全落在状态条内、无 .positions-dock 残留；点开后 topbar 芯片居中（delta 0）、位于列表体上方、状态条钮消失；再收起回归正常。截图目检通过。Web release **`trade-web-20261128-dockcenter3-f263e80`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `66d06ccb…`／`cc61823d…`／`f291175d…` 与本地单链构建一致，ba.wow211.com 复核同哈希（tt.wow211.com 当前 NXDOMAIN，以 ba 入口为准）。契约测试标记同步更新。后端不切换，旧 release 保留可回退。

## 输入框降至34px＋持仓钮改K线居中（收起贴底边、展开抽屉外顶部）Web 发布（2026-11-28，北京时间）

用户两件：① 交易模块输入框再缩窄（40→34px，限价/止损输入、止损金额盒、止盈策略盒同步）；② 持仓钮位置：收起时＝最下边条**居中（相对 K 线图中心）**；展开时＝**抽屉外**顶部居中（独立 topbar 行，不再在标题行内）。实现：.positions-dock-closed-wrap 绝对定位 workspace left:50% bottom:2px；展开渲染 .positions-dock-topbar（居中芯片行，位于 head 上方即抽屉外）；head 操作列恢复纯标题，pd-op-head 清除。实测：收起 centered=true（偏差<8px）、inputH 34px；展开 topbar 在 head 之上、居中、closed-wrap 消失；截图目检芯片悬于抽屉顶外居中。Web release **`trade-web-20261128-dockcenter-04a444b`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `cb28b48b…`／`267f9166…`／`0fd707e6…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定。后端不切换，旧 release 保留可回退。

## 工具图标选中态＝加粗变绿无背景（悬浮去背景态）Web 发布（2026-11-28，北京时间）

用户：工具栏图标点击后不要背景，改为图形加粗＋变绿；悬浮也不加背景。实现：.position-tool-trigger.{long,short,guide-line}.is-active 统一 color var(--green)＋background transparent（原绿/红/蓝 14% 底全去除）；is-active svg stroke-width 2.6 加粗；hover 仅文字色变化无背景。实测：多头/横线选中 bg=rgba(0,0,0,0)、color rgb(0,168,143)、svg 描边 2.6px；截图目检图标加粗绿色无底。Web release **`trade-web-20261128-toolactive-fd42c65`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/CSS 哈希 `e3ca5616…`／`6d931010…` 与本地单链构建一致，ba 复核同哈希。后端不切换，旧 release 保留可回退。

## 横线右轴价签对齐现价标签造型 Web 发布（2026-11-28，北京时间）

用户要求划线价签与当前价格标签造型/位置/数字位置一致。实现：.chart-line-axis-tag 字号 11→12px（同轴标）、padding 2/6→3/6px、line-height 1.2、text-align right、右缘 flush 0px＋translateY(-50%) 保持；实测价签 font 12px/高 20.4px/pad 3px 6px/右距 0，与现价芯片（红 59827.0）完全同款；价格数字沿用 priceScaleFormatter 分档与现价标签同格式。Web release **`trade-web-20261128-linetag-f88b458`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/CSS 哈希 `21c62eb1…`／`5eee3050…` 与本地单链构建一致，ba 复核同哈希。后端不切换，旧 release 保留可回退。

## 画线菜单点选即关＋纵向长图例＋选项扩充 Web 发布（2026-11-28，北京时间）

用户三件：① 菜单选项点完即收起（此前选完仍停留）；② 选项纵向排列、示意线加长（约设置条一半＝76px）、文字加大（11px），实线/虚线/颜色均同规格（颜色菜单也改图例行＋色名）；③ 选项扩充。实现：changeLineStyle 末尾 setLineMenu(null)；.chart-line-options flex-direction:column、选项按钮 flex 行＋pd-line-sample-lg 76px；粗细 1-6px（LINE_WIDTHS）、线型 实线/虚线/点线（LINE_STYLES，ChartLineStyle 增 dotted，校验/默认同步）、颜色 7 色带中文名（绿红蓝金白紫粉，LINE_COLOR_NAMES）；菜单 min-width 160。实测：粗细菜单 6 项 column/76px/11px，点 2px 即关且 line=2、defaults 同步；颜色 7 项点紫即关 color=#A78BFA；截图目检紫色 2px 线与图例条。Web release **`trade-web-20261128-linemenu-fe9b154`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `4c45df80…`／`fe454cce…`／`380e96d5…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定。后端不切换，旧 release 保留可回退。

## 十字线时间轴标签条 Web 发布（2026-11-28，北京时间）

用户要求在十字线竖线与时间轴交点处加具体时间条（参考 TradingView 样式但适配本站配色）。实现：crosshair state 增 time（吸附 bar 序号→data()[idx].time，越界按周期外推）；`.kline-crosshair-time` 芯片贴时间轴底部（bottom:2px、translateX(-50%) 居竖线、左右 clamp 78px），格式"周六 2026-11-28 00:30"（中文周几＋日期＋时分，tabular-nums）；本站样式＝bg-elevated 深底＋line-bright 描边＋4px 圆角＋白字 10px（非参考图的纯黑块）。实测：竖线处标签文本正确、居中贴轴、样式命中。Web release **`trade-web-20261128-crosstime-f5e94c8`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `0c3b4990…`／`360fd78c…`／`41b3049c…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定。后端不切换，旧 release 保留可回退。

## 画线可拖动＋指针手形/抓握＋编辑条图例化＋设置持久化 Web 发布（2026-11-28，北京时间）

用户两件：① 横线无法上下拖动；悬停要手形指针（非上下箭头），按下拖动要 grabbing 抓握形；② 粗细与颜色分开设置且直接显示（色块、线段图例＋几px、实/虚图例），并保存上次设置。实现：lineDrag 状态入 liveRef，线 onPointerDown 选中同时起拖（preventDefault 防 pan），move 按方向更新 price/time，up 清 body cursor；.chart-line-tool cursor:pointer＋:active grabbing（拖动中 body grabbing＝苹果闭手形）；编辑条三按钮＝粗细（当前色线段图例＋Npx）、线型（实/虚图例）、颜色（当前色块），菜单分别带图例；changeLineStyle 同步写 localStorage `trade-web-chart-line-defaults`，新建线继承（lineDefaultsRef 防闭包过期）。实测：拖动 price 61091.7→60375.3 下移✓、hover computed cursor=pointer、松手 body 复原；编辑条 labels 粗细/线型/颜色＋sample/swatch；改金色虚线后 stored 正确、删线重画自动继承；截图目检金色虚线与图例条在位。Web release **`trade-web-20261128-linedrag-758819b`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `889743e4…`／`7e0a1ad2…`／`f5a0e764…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定。后端不切换，旧 release 保留可回退。

## 收起态持仓钮归位 K 线区右缘（与展开态同 x）Web 发布（2026-11-28，北京时间）

用户指正：收起时按钮错放在整窗口最右（状态栏），应与展开态一样贴 **K 线区域右缘**。修正：状态栏钮删除；收起态芯片改 `.positions-dock-closed` 绝对定位于 chart-workspace 右下（right:4px/bottom:4px，workspace 补 position:relative），与展开态 head 第 9 列芯片同一 x（两态距 K 线右缘均 4px 实测）；展开时收起钮消失。Web release **`trade-web-20261128-dockalign-42322a8`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `d6d21462…`／`30177e41…`／`8e08faf9…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定。后端不切换，旧 release 保留可回退。

## 清除全部按钮改用「自动清理」SVG 图标 Web 发布（2026-11-28，北京时间）

用户提供 ~/Downloads/自动清理.svg 替换工具栏清除钮图标，颜色沿用现版钮色。实现：KlineChart 内联 svg（viewBox 0 0 1024 1024、16px、path fill=**currentColor**——原文件硬编码 #000000 已改，随 .chart-tool-clear 的 var(--muted) 与 hover var(--text)），移除 lucide Brush 导入。实测：svg 在位、fill currentColor、钮色 rgb(161,165,174) 与其他图标一致、Brush 已去除；截图目检新图标居工具组右端。Web release **`trade-web-20261128-clearicon-14edca2`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `9eb021b5…`／`db92b229…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定 viewBox。后端不切换，旧 release 保留可回退。

## 持仓钮双位置右端化（展开＝标题行右端不撑宽、收起＝状态栏右端）Web 发布（2026-11-28，北京时间）

用户按截图红框指明：展开时按钮放标题行最右端（与"操作"同格 space-between，**不得把标题行撑宽**）；收起时放最底状态栏右端（非居中）。实现：PositionsDock head 第 9 列 pd-op-head（操作＋芯片钮，150px 列内容纳不增列）；App 状态栏钮改 `{!dockOpen && ...}` 且 CSS 右对齐 right:12px；展开时状态栏钮隐藏。实测：收起 atRight=12、无 head 钮；展开 headRight=4、headW=485＝rowW（未变宽）、状态栏钮消失；截图目检芯片在"操作"列右端对齐。Web release **`trade-web-20261128-dockpos2-794e116`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `795f5cfb…`／`ae7241e7…`／`9cda992c…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定。后端不切换，旧 release 保留可回退。

## 止盈/平仓改纯加粗文字（黄/绿、无边框底色）Web 发布（2026-11-28，北京时间）

用户：两按钮改加粗文字、去边框底色、字色黄与绿。实现：.pg-tp-btn（含 is-running）＝#F5B942 金黄 700 字重、border 0、bg transparent（主题 --accent-strong 暗色为白不可用，取图表金线同色）；.pg-close-btn＝var(--green) 700、无边框底色；hover 下划线。持仓页 footer 同类同步生效。实测：tpColor rgb(245,185,66)/700/0 边框/透明底、clColor rgb(0,168,143)/700；截图「自动止盈中」金黄、「立即平仓」绿纯文字。Web release **`trade-web-20261128-textbtn-6673efd`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `7a3a4e1a…`／`bd16b6b9…`／`a8cf28e8…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定。后端不切换，旧 release 保留可回退。

## 持仓钮回最底状态栏＋运行中绿框绿字＋按钮降高＋4行预留校准 Web 发布（2026-11-28，北京时间）

用户：① 运行中按钮文案「自动止盈中」＋绿色线框绿字（去填充）；② 立即平仓保留；③ 两按钮高度统一缩窄；④ 持仓展开钮回到**最底状态栏**（K 线下方不留常驻条，收起时坞仅 1px 边框）。实现：toggle 移回 statusbar 居中（绿 14% 底无描边芯片）；PositionsDock 收起时不渲染 head/body；.pg-tp-btn.is-running 改 border green＋bg transparent；两按钮 padding 2px（高 21px 统一）；行高 34px→4 行预留 136px。实测：收起 dockH=1、钮在状态栏居中；运行中 tpText=自动止盈中/边框绿/底透明/字绿；tpH=clH=21；6 行替身 listH=136 可见 4 行。Web release **`trade-web-20261128-dockbtn-9c9c2e1`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `607e1eee…`／`bd16b6b9…`／`02307dd0…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定。后端不切换，旧 release 保留可回退。

## 持仓钮并入标题行同水平线＋标题行降高＋绿底无描边 Web 发布（2026-11-28，北京时间）

用户三件：① 展开时持仓钮要与列标题同一水平线（原独立顶栏在标题上一行）；② 标题行太高要降；③ 按钮加底色去描边、颜色自定。实现：删 `.positions-dock-bar`，toggle 移入 `.positions-dock-head` 第 9 列（pd-op-head：标题左＋按钮右 space-between），标题行常显（收起时即唯一行）；head padding 3px（行高 27px）；toggle 去 border、底 color-mix(green 14%)、字绿、hover 24%。实测：收起仅标题行（body false）、展开钮与标题中心差<8px 同线、headH 27、border 0、bg 绿 14%、listH 176 不变。Web release **`trade-web-20261128-dockhead2-ea11cf8`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `f68133b5…`／`e6349ab0…`／`119195d9…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定。后端不切换，旧 release 保留可回退。

## 持仓抽屉固定预留 4 行＋按钮/操作贴右缘（弹性列窄屏自适应）Web 发布（2026-11-28，北京时间）

用户两件：① 列表不管几笔都**预留 4 行空间**（原 max-height 随内容缩→改固定 height:176px）；② 顶栏芯片与行内「止盈/平仓」按钮**贴右边缘**。根因补充：行原 min-width:1020 固定列在窄屏横滚→按钮被推出可视右缘（实测偏差 -601px）；改弹性 fr 列（min-width:0）＋≤900px 隐藏保证金/市价止盈两列＋操作列 minmax(150px,1.7fr) 防按钮溢出压列；行/顶栏 padding-right 4px。实测（720px 窄屏）：1 笔时 listH=176（4 行预留）、无横滚、芯片与操作右缘距=4px、止损列与按钮无重叠。Web release **`trade-web-20261128-dockfit-99f6b04`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `6680d983…`／`ec6526ba…`／`a4f6674c…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定。后端不切换，旧 release 保留可回退。

## 持仓抽屉顶栏右芯片按钮＋列表限高 4 行 Web 发布（2026-11-28，北京时间）

用户终案：按钮统一放**抽屉顶栏右侧**（带描边＋底色芯片），收起时顶栏即 K 线下边条、按钮居其右缘；展开时列表在顶栏下方、**最多 4 行高**超出内滚（隐藏滚动条）；状态栏旧居中按钮移除。实现：PositionsDock 顶栏 `.positions-dock-bar`（26px、justify-end）常显，toggle 芯片 1px line-bright 描边＋panel-hover 底；body＝表头＋list（max-height:176px＝4×44px 行高）；App 删 statusbar toggle 与 wsH/ResizeObserver。实测：按钮距 workspace 右<20px、描边 1px/底 rgb(32,34,37)、状态栏无旧钮；6 行替身下 listH=176、可见 4 行、scrollable=true。Web release **`trade-web-20261128-dockhead-c0df2f9`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `dc5ad503…`／`ec6526ba…`／`373b3b93…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定。后端不切换，旧 release 保留可回退。

## 持仓坞信息改白色＋浮盈浮亏红绿 Web 发布（2026-11-28，北京时间）

用户报：坞内信息浅灰应改与币种同白；浮盈浮亏要红/绿。根因：dockbar 重写 CSS 时丢失 `.pd-up/.pd-down` 两类→盈亏随行灰；行值 color 为 muted。修：`.positions-dock-row` color 改 var(--text)（与币种按钮同白 rgb(238,240,243)）、杠杆小字同白；补回 `.pd-up{green}/.pd-down{red}`。实测：行值四列均 rgb(238,240,243)=币种色；盈利行 pd-up rgb(0,168,143)、亏损行 pd-down rgb(255,86,105)（-9.41U／-1.18%）。Web release **`trade-web-20261128-dockcolor-476d594`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `9d280b3e…`／`5ff401e0…`／`b453dc6e…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定行白与红绿类。后端不切换，旧 release 保留可回退。

## 表单顺序再调（策略→止损金额→含手续费）＋三预估改三行左右＋持仓按钮居右 Web 发布（2026-11-28，北京时间）

用户三件：① 含手续费移到止损金额下方、止盈策略移到止损价下方（市价与限价同顺序）；② 预估仓位/预估手续费/止损回撤改**三行、每行左右结构**（标签左值右，弃三列上下卡）；③ 持仓列表止盈/平仓按钮居右。实现：TradePanel 顺序＝现价→限价→止损价→止盈策略→止损金额→含手续费→trade-info→提交；.trade-info 改 column、子行 row＋space-between；.pd-actions justify-end（持仓页 footer 原已 flex-end）。实测：orderOk=true（stop<strat<risk<fee<info<submit）、三行各 17px 同线左右、坞按钮 flex-end 且距行右<20px。Web release **`trade-web-20261128-formorder-38bc936`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `ab0b6d6f…`／`5ff401e0…`／`54c875f0…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定顺序与行结构。后端不切换，旧 release 保留可回退。

## 交易面板四件：隐藏滚动条／分档价位／表单重排／设置弹窗 Web 发布（2026-11-28，北京时间）

用户四件：① 市价/限价切换时右栏出现滚动条致宽度缩窄→隐藏滚动条（保留可滚）；② 价位遵从分档小数；③ 表单重排：当前价格/止损价/止损金额/止盈策略为可操作区，「止损含手续费」勾选条移到止损价正下方，预估仓位/预估手续费/止损回撤三项移到可操作区下方、开仓按钮上方的独立信息区；④ 开仓设置改弹窗（不再内联在按钮下）。实现：insight-panel/pg-scroll `scrollbar-width:none`＋webkit 隐藏；当前价格与确认弹窗限价/止损价改 priceScaleFormatter；TradePanel 重排（trade-static 行、trade-fee-row、trade-info 三格区）；settingsOpen 渲染 pg-confirm 弹窗（3 Maker＋止损触发后市价固定行，含手续费已移主表单）。实测：切换前后右栏宽均 705px、scrollbarWidth none、feeBelowStop/infoAboveSubmit true、设置弹窗 4 行且不含手续费项。Web release **`trade-web-20261128-tradeflow-369ec3d`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `273a2d87…`／`96ae0e8a…`／`3f57b257…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定顺序与弹窗。后端不切换，旧 release 保留可回退。

## 修 wslive 引入的订阅全拒（左列表与K线停刷根因）Web 发布（2026-11-28，北京时间）

用户报：左列表与 K 线价格都不刷新/很慢，要求确认链路。根因：上一版 wslive 把 App 订阅 symbol 设为客户端通配 "*"，而 `sendSubscribe` 把全部 sub.symbol 并入 kline filters 发给后端；后端 `validate_subscription`（market_stream/websocket.py:106）按 `[A-Z0-9]{2,32}` 校验 symbols，"*" 不合法→**整条 subscribe 被拒**→ticker 与 kline 均未安装→两路全停。修：klineSymbols 过滤掉 "*"（通配仅客户端分发层使用）；ticker 仍空 symbols 通配。假 WS 实证：subscribe 帧 kline symbols=["RAYSOLUSDT"]、ticker=[]、逐符号过后台正则=true。链路确认：单共享 WS→subscribe 帧（活连接重发不重连）→后端 fanout ticker 通配/kline 按币→客户端按 sub 分发（App "*" 收全量做健康与列表、KlineChart 按币收 kline 聚合尾根）→左列表 500ms 聚合、K 线尾根 120ms 防抖、坞盈亏 WS 推算。Web release **`trade-web-20261128-wsfix-dfdd04f`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `b19600f8…`／`52a57ce5…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定过滤。后端不切换，旧 release 保留可回退。

## 持仓展开钮归位状态栏正中心（删独立条、K 线拿回 24px）Web 发布（2026-11-28，北京时间）

用户澄清：不要新开一条放按钮，放**最下面状态栏正中心**即可，给 K 线让位。实现：删除 `.positions-dock-bar`（24px 独立条）；toggle 改 `.statusbar-dock-toggle` 绝对定位 left:50% translateX(-50%) 居于状态栏中心；坞内容展开时仍贴 K 线下方 30% 高。实测：noNewBar=true、按钮中心偏差<20px 且在状态栏内、kline-stage 630→654px（拿回 24px）、展开 bodyH 211/704 不变。Web release **`trade-web-20261128-dockcenter-2411d1b`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `62590c13…`／`8c3d8391…`／`f54acb96…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定。后端不切换，旧 release 保留可回退。

## 持仓坞改居中正下方条＋标题列＋行操作＋面板同黑 Web 发布（2026-11-28，北京时间）

用户四件：① 展开按钮移到 K 线区居中正下方的条上；② 展开内容与持仓页信息同步且行尾带操作按钮；③ 顶部标题列（开仓价/仓位/浮盈浮亏等）；④ 配色与左右功能区黑一致。实现：新增 `PositionsDock.tsx`（内容＋底部 24px 居中条 `.positions-dock-bar`，toggle 居中；表头九列：币种/方向・仓位・保证金・开仓价・现价・浮盈浮亏・市价止损・市价止盈・操作；行尾「自动止盈/立即平仓」复用持仓页同款按钮与确认平仓/策略快照弹窗，TpLevels 自 Pages 导出共享；盈亏/现价 WS 实时推算）；App 以 ResizeObserver 测 workspace 高，展开 body=30%（≈两附图）；背景 var(--panel) 与左 rail 实测同色 rgb(21,22,25)；状态栏旧 toggle 移除。实测：条居中偏差<40px、位于 chart 底、bodyH 211/704、表头与行操作齐全、行盈亏 +12.31U 为 WS 推算值。Web release **`trade-web-20261128-dockbar-855b988`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `cf1de1ef…`／`e1d38cdc…`／`2e7e64d4…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定。后端不切换，旧 release 保留可回退。

## 实时层去重连断档＋展示层盈亏全 WS 化（iOS 口径）Web 发布（2026-11-28，北京时间）

用户报：K 线区当前价刷新与左列表不同频、断断续续经常断；建议展示层（K 线盈亏、持仓坞价格）全用 WS 而非 10s REST。根因：`realtime.subscribe()` 每次订阅集合变化（切币/切周期/列表刷新触发 App 重订阅）都 **teardown+整条重连**→行情断档；左列表有 500ms 聚合缓存看不出断，K 线尾根直接停跳。修：① 订阅变化改为**活连接上重发 subscribe 帧**（后端按通道替换 filters，websocket.py:202），仅无活连接时才 connect；② App 订阅只随登录建立一次（symbol:"*" 通配 kline＋tickerSymbols 走 ref 动态列表），列表/切币不再重订阅；③ 持仓坞盈亏/现价改由 **WS mark 价实时推算** `(mark−entry)/entry×名义×方向`（REST 10s 轮询仅保留持仓存在性/止损位）。假 WS 实证：两次订阅 opens 恒 1、closes 0、subscribe 帧 1→2（不重连）。K 线尾根/持仓线盈亏本就 WS 驱动，断档消除后与左列表同频。Web release **`trade-web-20261128-wslive-d58775e`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `b954964a…`／`21b5ad6f…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定。后端不切换，旧 release 保留可回退。

## web 补「止损含手续费」开关（默认不含，对齐 iOS；用户批准）Web 发布（2026-11-28，北京时间）

用户报：web 两笔订单止损金额均小于预设。定位：iOS `includeFee=false` 默认＋「止损含手续费」开关（仓位=止损额÷(距离比+含?0.001:0)）；web 硬编码 `include_fee:true` 且预览固定加 0.001→含手续费分摊使触止损**价格亏损**=预设×距离比/(距离比+0.001)<预设（例 200U/2%→190.48U）；后端 trading/views.py:2213 同公式。经 AskUserQuestion 批准「加开关默认不含」后实现：TradePanel 增 includeFee state（localStorage `integrated.chart.order-settings.include-fee` 默认 false）、开仓设置面板「止损含手续费」勾选、预览与 payload 均按开关、确认文案注明含/不含。实测：默认关 250U/2.01%→12,441.73U；开→11,851.90U；存储 true 持久化。Web release **`trade-web-20261127-inclfee-6a7d75c`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `f189d09f…`／`f7114618…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定开关默认与公式。后端不切换，旧 release 保留可回退。**注意：已开的两笔含手续费旧单不受影响，新单默认不含。**

## K 线下方持仓坞＋状态栏展开钮 Web 发布（2026-11-27，北京时间）

用户要求：开仓持仓列表加到行情 K 线图下方，最下边缘条加向上展开钮；展开高度≈两个附图高，再点收回。实现：`main.chart-workspace` 内 K 线之下新增 `.positions-dock`（收起 height:0，展开 height:30%≈MACD+StochRSI 两附图，.18s 过渡）；内含持仓行（币种/多空芯片/金额/开仓/现价/浮盈亏绿红/止损），10s 轮询复用 loadCount 同时喂 dock；点击行切到该币 K 线；状态栏右端 `.statusbar-dock-toggle`（ChevronUp/ChevronDown＋"持仓"，aria-expanded）切换。实测：展开 dockH=211px（workspace 704 的 30%，与展开前两附图合计≈197px 同量级）、2 行信息齐全（RAYSOL 多 +12.50 绿／HAEDAL 空 −3.20 红）、再点 dockH=0；截图目检坞在图下。Web release **`trade-web-20261127-posdock-eed325a`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `b98da2d0…`／`ee058efe…`／`806dd130…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定。后端不切换，旧 release 保留可回退。

## 账户止损/策略改行＋iOS 口径弹窗（交易模块复用）＋导航芯片降高 Web 发布（2026-11-27，北京时间）

用户四件：① 账户止损只显「止损金额＋金额＋右箭头」，点击弹窗做完整设定（完全参考 iOS）；② 账户止盈策略行显当前启用策略＋右箭头，弹窗看已有策略，「新建」关闭弹窗并滚动到内联创建表单；③ 交易模块止损金额/止盈策略复用同两弹窗；④ 主导航选中绿芯片高度略降。实现：新增 `AccountDialogs.tsx`（StopLossDialog：50～300 滑杆＋大字金额盒＋"当前"芯片＋三条说明＋pending 倒计时横幅可取消＋完成横幅＋确定按钮未变化禁用，GET/POST /account/stop-loss 与 /cancel；StrategyDialog：列表启用/编辑/删除＋新建策略；AccountRow 通用行）；Pages 账户两 section 改行＋弹窗，内联编辑表单保留供新建/编辑滚动（id=account-strategy-editor）；TradePanel 风险盒/策略链改开弹窗（新建→onNavigate 滚动账户）；导航 padding 4→7px（芯片 48→41px）。实测：行「止损金额200 U」「止盈策略未启用」无弹窗外滑杆；弹窗标题/金额盒/3 说明/滑杆/确定齐全；250 保存→完成横幅＋行更新；策略新建→弹窗关＋编辑器入视口；交易模块两入口同弹窗；芯片 41px/顶栏 56px。Web release **`trade-web-20261127-acctdlg-449f478`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `d9b9bb9c…`／`4b5e8db4…`／`2eec5043…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定。后端不切换，旧 release 保留可回退。

## 十字线穿透副图＋止损额保存字段修正 Web 发布（2026-11-27，北京时间）

用户两报：① 十字线不能穿透 MACD/StochRSI 副图；② 止损额调 200 保存报"必填项"。根因①：自绘十字线边界限制 y≤主图高且价格只取主图序列；改 pane 感知——竖线全容器高（CSS height:100%），横线/价签按鼠标所在 pane（getHTMLElement rect 命中）取该 pane 首序列 coordinateToPrice；价签主图＝分档价＋涨跌幅、MACD＝4 位小数、Stoch＝2 位小数。根因②：后端序列化器字段为 **amount**（必填 50–300），web 误发 `stop_loss_amount`→恒报必填；改发 `{ amount: String(amount) }`。实测：MACD pane 价签 -0.0006、竖线高 655＝容器全高；Stoch 价签 56.48；滑杆 200 保存→「止损额已保存」、行显 200 U。Web release **`trade-web-20261127-crosspane-0277255`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `995fc9ef…`／`f1861d21…`／`84a0b4f0…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定 pane 命中与 amount 字段。后端不切换，旧 release 保留可回退。

## 横线右轴价格标签＋开仓按钮直接多空红绿 Web 发布（2026-11-27，北京时间）

用户两件：① 画的横线要在右侧价格标尺上显示仿十字线价签的信息条；② 开仓模块上方"开多/开空＋止损低于现价为多"提示行删除，按钮直接按现价与止损价关系显示「市价开多/市价开空」（限价同理挂多/挂空），开多绿、开空红。实现：覆盖层为每条 horizontal 线渲染 `.chart-line-axis-tag`（right:0 贴标尺、translateY(-50%)、底色＝线色、白字/白线深字、priceScaleFormatter 分档精度、超出主图隐藏）；TradePanel 删 trade-side-row 整块与 CSS，submit 加 `is-long/is-short` 类（is-short 红底白字）。实测：价签 text=1.346、bg=线绿、rightGap=0；止损低于现价→「市价开多」rgb(0,168,143)、高于→「市价开空」rgb(255,86,105)；提示行不存在；截图右轴绿签贴线。Web release **`trade-web-20261127-axistag-170c6de`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `aa230b4c…`／`33dc8232…`／`d57a96b4…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定。后端不切换，旧 release 保留可回退。

## 信息条去叉＋工具条降高扁平＋清除改刷子带二次确认 Web 发布（2026-11-27，北京时间）

用户三件：① 测量信息条删除钮右边的 × 多余→删除（仅留删除桶）；② 顶部周期工具条字体偏大/条偏高→缩回（高 53→46px、周期 16→14px、自动手动 14→12px、指标 16→14px、图标框 35→30px），且**去掉工具组双层底**（group 边框/底色移除，图标平铺＋竖分隔保留）；③ 清除全部图标垃圾桶→**刷子**（Brush 16px）、**正常灰色**（非红）、点击**二次确认**（工具条下弹层「清除全部横线、竖线与测量工具？确认/取消」，确认才触发 clearSignal）。实测：barH 46/tf 14/vm 12/trig 30/group 透明无边框/刷子 rgb(161,165,174)；点刷子出弹层、取消关闭、确认后图面与存储全 0；信息条 buttons 仅「删除测量工具」。Web release **`trade-web-20261127-toolbar3-bbe4a2b`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `cebacb97…`／`a30b01e9…`／`423d9cec…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定。后端不切换，旧 release 保留可回退。

## 收盘水位拒绝迟到改写（倒数第三根与交易所原生不一致根因）Web 发布（2026-11-27，北京时间）

用户指认 5m 倒数第三根与 TradingView 明显不同。三路比对（我们 REST／币安原生／OKX 原生）证明**服务器聚合与两交易所逐根一致**（崩溃窗口 12 根差≤0.2），差异只可能出在 web 端 WS 合并副本：`mergeTicker/mergeBucketKline` 只防"更旧桶"，不防"**已收盘桶的迟到 ticker/forming 推送**"——收盘后 close 被迟到价改写→实体被拉到下影线＝与原生K线形状不同（REST 独立链路不受影响，故此前比对误判无 bug）。修：`closedThroughRef` 收盘水位——收到 closed 1m 记录桶水位；此后该桶及更旧桶的非 closed 写入（kline forming 与 ticker）一律拒绝；切币/切周期/刷新重置水位。契约测试锁定水位逻辑。Web release **`trade-web-20261127-closedwm-1e7cf7e`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `8d8c7b15…`／`2d078cd6…` 与本地单链构建一致，ba 复核同哈希。后端不切换，旧 release 保留可回退。

## 持仓标签左移＋浮盈亏底色按数值＋价格线稳定着色 Web 发布（2026-11-27，北京时间）

用户三件：① 开仓/止损文字底再左移；② 浮盈浮亏文字底按数值正负绿/红（而非 tick 方向）；③ 价格线上涨时应为绿色点线，不应红绿闪色。实现：标签 base 由 `8+2×条宽` 改 `8+1×条宽`（浮盈亏仍右错开一条宽）；desired 增 `labelColor`，浮盈亏盒色＝pnl 符号色、线色＝方向色分离；方向参照改**前一根收盘**（`candlesRef[len-2].close`，删逐 tick 的 prevCloseRef 比较＝闪色根因）。实测：entry/stop left=68px(=8+60)、pnl left=136；浮盈 +30.93 盒绿、浮亏 −29.13 盒红；截图价格线随相对前根收盘稳定红/绿。Web release **`trade-web-20261127-poslabel2-6e0e254`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `4786da67…`／`e005c6d6…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定新 base/labelColor/稳定参照。后端不切换，旧 release 保留可回退。

## 尾根种子蜡烛零高度实体修复（不再渲染成横线/重合碎烛）Web 发布（2026-11-27，北京时间）

用户报截图尾根"2 根 K 线重合"。根因：上一轮为防 hl2 污染把 ticker 种子根的 high/low 收紧为仅现价，而 open=前根收盘、close=现价→**实体零高度**，渲染成一条横线 dash，紧贴前一根蜡烛＝视觉重合/碎烛。修：种子根 high/low 恢复张开到 max/min(前根收盘, 现价)（实体有效、与前根连续），保留 seeded 标记与首根真实 1m 整体接管（hl2 短暂偏差≤1s 可接受）。单元测试锁种子实体跨度。Web release **`trade-web-20261127-seedbody-c63cddf`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `21430b75…`／`5d2670dc…` 与本地单链构建一致，ba 复核同哈希。后端不切换，旧 release 保留可回退。

## 交易侧栏松散规整版式 Web 发布（2026-11-27，北京时间）

用户报：右侧交易区信息太集中、输入框行高/样式参差，要求行距更高、字体略大、更规整松散。实现：字段改**标签在上、控件整行**（侧栏仅 238px，横排必参差）；限价输入/止损输入/止损金额盒/止盈策略盒统一 **40px 高、整行宽、6px 圆角、同描边**；面板行距 10→14px；标签 12→13px、输入/金额 13→14px、指标值 13→14px/指标名 10→11px、开多/空芯片 12→13px、提示小字 9→11px、提交钮 14→15px、市价/限价 12→13px、开仓设置 11→12px、Maker 行 12→13px 且行高≥26px、设置盒内距 12/14 行距 10。实测 computed：三控件同高 40px 同宽、gap 14px、字号全对；整页截图目检规整松散。Web release **`trade-web-20261127-tradespace-042aaaf`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `4b4ba745…`／`e1faecac…`／`3c8dae64…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定堆叠字段与 40px 统一控件。后端不切换，旧 release 保留可回退。

## 做多/做空信息条统一为画线编辑条样式＋选中互斥 Web 发布（2026-11-27，北京时间）

用户两件：① 测量顶部信息条样式与横线/竖线选中编辑条完全一致；② 选中一个工具时另一个的选中态与信息条必须消失（当前两条可同显）。实现：测量详情复用 `chart-line-editor` 容器（5px 圆角/line-bright 描边/阴影/深底），字段改 `chart-line-editor-item` 芯片（1px 描边 3px 圆角 9px 字），标题芯片加粗、删除钮红色、关闭 ×；新增 `clearLineSelection()`，在区域点击选中、手柄按下（beginHandle）、新框落定三处同步清除画线选中与弹层（画线→测量方向原已互斥）。实测：先选横线（编辑条在）再点测量区——详情条出现且 `editorGone:true`；详情 computed 圆角 5px/阴影在位/芯片 1px 描边；截图目检同款。Web release **`trade-web-20261127-barmutex-f6a5e3d`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `9588aa9d…`／`e1faecac…`／`52a4dec0…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定统一类与 clearLineSelection。后端不切换，旧 release 保留可回退。

## 中左滑点不可突破右线（最小跨度改一根K线）＋细条工具命中容错 Web 发布（2026-11-27，北京时间）

用户报：做多/做空左侧中间滑点可拖过右边线，框瞬间变无限长。根因：leftFree/leftX 夹持用 `endTime − 60s`，60s 不在 15m/1H 网格上，取整后左右边落同一根序号→宽度塌成 8px 细条贴右线（＝视觉突破＋畸形）；且命中测试用真实 x1==x2 零宽，历史遗留细条永远无法再选中。修：夹持最小跨度改**一根周期**（`timeGrid().interval`，leftX/leftFree/rightX 三分支＋sanitizeDraft minSpan 同步）；命中测试与渲染一致取 `Math.max(x2, x1+8)`。实测：旧细条点击即选中（4 柄）；中左点猛拖 500px 后 span 锁在 900s＝一根，start<end 恒成立。Web release **`trade-web-20261127-minspan-3fe6f0d`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `c5ebc63e…`／`e5015648…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定 minSpan 与命中容错。后端不切换，旧 release 保留可回退。

## 测量工具跨周期架构修复（实时网格换算＋数据身份重绘键＋整数网格取整）Web 发布（2026-11-27，北京时间）

用户报：低周期切高周期后做多/做空工具消失；切回后中间区无法选中/拖动（仅边条可点）；要求从底层重审架构。三个真实缺陷：① **挂载期闭包捕获数据快照**——window 指针监听只注册一次，换算函数捕获当次 `candleSeries.data()` 数组，切周期后仍用旧"末根时间/周期差"→命中测试/拖拽坐标全错（中间区点不中、拖不动）；改 `timeGrid()` 每次调用实时读 `data()`，监听闭包不再可能过期。② **重绘触发键不含数据身份**——rAF 同步环只比对逻辑范围＋价格范围，切周期后两值常不变→覆盖层不重渲染→旧网格换算把工具甩出屏幕；键加入 `data.length＋首末时间`。③ **`logicalToCoordinate` 对非整数逻辑坐标返回 0**——15m 工具时间不落 1h 网格，x 被打成 0＝贴左缘 8px 细条（＝"消失"）；timeToX 改 `Math.round` 到最近根（与 xToTime 的 round 对称，网格语义一致）。实测：15M→1H 工具 left=286/width=30（4 根）位置正确；切回 15M 中间区点击即选中（4 柄）、右柄拖动 dEnd=+7200s；空白区行为不回退。Web release **`trade-web-20261127-intgrid-7e5d9f1`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `27bdd226…`／`3dfef1b8…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定 timeGrid/Math.round(grid.lastIdx。后端不切换，旧 release 保留可回退。**遗留架构债（已备案未动）**：工具存储为全局（跨币种共享时间锚点，属产品现状）；价格轴无订阅 API 仍靠 rAF 轮询。

## 测量工具可移入右侧空白区＋中线距边线5%锁死 Web 发布（2026-11-27，北京时间）

用户问：右侧空白区也是 K 线显示区，为何做多/做空区域拖不进去？并要求中线拖动不得越过止盈/止损两条边线（距两边各约 5% 即锁死）。底层根因：覆盖层时间↔像素换算用库的 `coordinateToTime/timeToIndex`，二者**只认有数据的根**——空白区 coordinateToTime 返回 null（拖拽/落点判定直接失效）、timeToIndex(findNearest) 把超末根时间钳回最后一根（渲染无法越过末根）。改按周期等差外推：`xToTime＝末根时间＋(round(coordinateToLogical)－末根序号)×周期`，`timeToX＝logicalToCoordinate(末根序号＋(t－末根时间)/周期)`，空白区可绘制、可拖入、可渲染。中线夹持：`clampEntryToEdges` 将 entryPrice 限制在 [min(边)+5%span, max(边)−5%span]，entryY 与 leftFree 共用。实测：右柄拖 +200px 入空白 endTime 超末根 26 根；中线猛拖精确停在 target−5%span（1.338522＝上限）；整体平移两端同步 +34 根；空白绘制不再被 null 拦截。Web release **`trade-web-20261127-whitesp-d51c50b`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `246587d7…`／`6b860fed…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定 coordinateToLogical/logicalToCoordinate/clampEntryToEdges。后端不切换，旧 release 保留可回退。

## 清除钮纯图标化＋信息条统一样式顶部居中＋工具栏放大20% Web 发布（2026-11-27，北京时间）

用户三件：① 一键清除钮去红底去汉字，只留与其他图标同尺寸（16px）的红色垃圾桶；② 解释右上做多/做空信息栏消失（上轮按"未选中不显示"指令删除了全量卡片列表），现要求所有信息栏统一为横线/竖线编辑条样式并置于 **K 线区域顶部居中**；③ 工具栏字体与整条大小 +20%。实现：`.chart-tool-clear` 透明底纯红图标（aria-label/title 保留名称）；测量详情条与画线编辑条同用 line-bright 边框/5px 圆角/阴影 chip 样式，left:50%＋top:8px＋translateX(-50%) 居中于主图顶部（详情条含红色删除钮＋关闭钮，仍仅选中显示）；工具栏 44→53px、周期/指标 13→16px、自动/手动 12→14px、trigger 29→35px、分隔线 17→20px。实测 computed：barH 53px、tf/im 16px、vm 14px、trig 35px、clear 无文字透明底红字 16px 图标；detail/editor 均 topGap=8px、dx=0、radius 5px、阴影在位，选中互斥；截图目检通过。Web release **`trade-web-20261127-toolstrip-af074b3`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `14ba6298…`／`23b2f39d…`／`8255a3d6…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定。后端不切换，旧 release 保留可回退。

## 划线工具栏合并底框＋信息条仅选中＋选项居中＋一键清除 Web 发布（2026-11-27，北京时间）

用户三件：① 看多/看空信息条只显示选中的（未选中不显示信息条与删除按钮）；② 多/空/横/竖四图标合并一个底框、竖线分隔；③ 底框最右浅红「一键清除所有划线工具」按钮，清除当前图面全部横线/竖线/测量条；且所有工具选中后选项条置于 K 线中央。实现：删除右上全量卡片列表（ToolCard 整链移除），测量信息条（stats chip）改仅选中渲染；选中测量详情条与画线编辑条统一移入主图 surface 并 left/top 50%＋translate(-50%,-50%) 居中（详情条补删除按钮）；工具栏四 trigger 收进 `.chart-tool-group` 单底框＋`.tool-sep` 竖分隔＋`.chart-tool-clear` 浅红清除钮（red 12% 底）；清除经 `clearSignal` 计数 prop 触发覆盖层清空 positions＋chartLines＋选中态。实测：底框 1px 边框/4 图标/4 分隔/trigger 无边框、清除钮红字 12% 红底；未选中 stats/list/detail/editor 全 0；测量选中详情 dx=dy=0 居中含删除钮、stats=1；画线选中编辑条 dx=dy=0 居中；一键清除后图面与两个存储键全 0；截图目检通过。Web release **`trade-web-20261127-toolgroup-cdae754`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `1ca5c88f…`／`426b45ea…`／`92ea542c…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定组框/分隔/清除/居中/仅选中。后端不切换，旧 release 保留可回退。

## 轻量观测 healthlog 上线（2026-11-27，47.80.22.243 首尔服务器）

应用户“轻量化观测最近一周／长期运行情况”要求，部署单文件 Python 标准库脚本 `deploy/integrated/observability/healthlog.py`（服务器位于 `/opt/trade-tools-integrated/observability/`，无第三方依赖，总占用约 160KB）。

- **采集**：root crontab 每分钟 `flock -n /run/lock/tradetools-healthlog.lock … healthlog.py collect`。每分钟采主机 load、CPU 忙／iowait（/proc/stat 差分）、内存／swap、磁盘（statvfs）、nginx 状态、六容器健康与 StartedAt（docker inspect）、`https://127.0.0.1/integrated/v1/health` 的 HTTP 码＋延迟＋checks 全 true；容器 CPU／内存限额占比（docker stats，单次约 2s）每 5 分钟采一次以控开销。所有子进程带超时，flock 防重叠。
- **事件**：容器重启、健康状态变化、health 异常／恢复、nginx 变化、内核 OOM（journalctl -k 扫描，按当前容器 ID 归名）记入 `data/events.log`（1MB 轮转）。
- **存储与保留**：`data/metrics-YYYYMM.csv` 每分钟原始样本保留 3 个月，更早 gzip 保留 12 个月；`data/daily.csv` 每日汇总（load／iowait 均峰、内存最低、磁盘峰、health 异常、异常分钟、重启／OOM 数）永久保留，作长期趋势来源。
- **历史回填**：`healthlog.py backfill` 从系统自带 sysstat（`/var/log/sysstat/sa*`，10 分钟粒度、保留约 9 天）解析 load／CPU／内存／swap 回填，并从 journal 回填近 22 天 OOM 事件。已回填 11-19 起 1264 行样本＋8 天日报。sar 无磁盘空间／容器／health 历史，回填行这些列为空。
- **查看**：`tradetools-health [天数|all]`（软链 `/usr/local/bin/tradetools-health` → 脚本 `report`，默认 7 天）：当前快照＋告警、近 N 天汇总、每日趋势；>31 天或 `all` 按月汇总。
- **安装步骤（已执行）**：上传 `healthlog.py`＋`tradetools-health` → `python3 healthlog.py backfill` → `python3 healthlog.py collect` 试采 → 追加 crontab → `ln -sf /opt/trade-tools-integrated/observability/tradetools-health /usr/local/bin/tradetools-health`。未改任何业务容器、Nginx、数据库。
- **首轮发现（仅观测，未做任何变更，待用户决策）**：① 近 14 天应用容器 OOM 杀进程 **106 次、每日 4–11 次**慢性发生，docker 自动重启恢复故表面 healthy；历史容器 ID 已随部署替换无法归名，新 OOM 将由采集器按当前 ID 归名；api 容器内存当前 **89.5%**（256MiB 限额）最逼近。② iowait 长期均值约 15%、峰值近 50%，load 峰值 4.96（2 核）主要由磁盘 I/O 等待贡献。③ 22 端口公网暴露，journal 见 root 暴力破解尝试（223.83.183.254）。建议后续经批准评审容器内存限额与 I/O 来源。

## 桶滚种子根开收盘错位根因修复（mergeBucketKline 单源重构）Web 发布（2026-11-27，北京时间）

用户报：K 线开盘/收盘不对齐、实体间非常大重叠区（崩溃段填充带大块错位），要求深度解决可重构。根因：大周期桶滚时 **ticker 先于首根 1m 种子新根**（旧代码 open=high=low=close=现价），随后真实 1m 到达只并 high/low/close、**永不纠正 open**→open 停在滚桶瞬间价、与前根收盘脱节＝开收盘错位＋快市实体互相重叠；种子 high/low 混入前根收盘又污染 hl2 填充锚＝大块重叠填充区。重构：合并逻辑收进 `lib/candleMerge.ts` 纯函数 `mergeBucketKline`（KlineChart 不再内联）；种子根 `open=前根收盘`（连续）、`high/low=现价`（不污染 hl2）、显式 `seeded` 标记；首根真实 1m **整体接管 open/high/low** 并清标记；forming 1m 不重复累加成交量保留。实测：单元测试锁种子连续/接管/成交量/旧桶忽略；浏览器内动态 import 真实模块跑序列 seedOpen=12=prevClose、takenOpen/High/Low=首根 1m 真值；崩溃段喂数目检因 Browser 面板隐藏激活失败归线上验收（结构/序列已实证）。Web release **`trade-web-20261127-candleopen-cc6f277`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `f4c1bdf7…`／`27629ec4…` 与本地单链构建一致，ba 复核同哈希。契约测试改锁 mergeBucketKline＋seeded＋open: last.close。后端不切换，旧 release 保留可回退。

## 持仓/历史/委托多空徽标修正（整数 side 0=多）Web 发布（2026-11-27，北京时间）

用户报：开多单在 web 历史与持仓界面显示空单。根因：后端 `side` 为**整数** 0=多 1=空（positions/models.py），web `isLong` 只比字符串 `"0"`，`0 === "0"` 恒假→全部显示空；KlineChart 持仓三线盈亏符号同误。修：tradeApi 增统一 `isLongSide`（String(side).toLowerCase() ∈ {0,long,buy}），PositionRow/HistoryRow/OrderRow 类型改 `number | string`，Pages 徽标与 KlineChart 三线共用。实测（fetch 替身注入整数 side＋{code:200,data} 信封）：持仓 [多,空]、历史 [多,空]、委托 [多] 全对。Web release **`trade-web-20261127-sidefix-0e82157`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `67604a7f…`／`f995cdea…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定 isLongSide 单源。后端不切换，旧 release 保留可回退。

## 单击落初始尺寸测量框恢复＋非整根时间渲染修复 Web 发布（2026-11-27，北京时间）

用户报：点多头工具后在图上单击不再生成初始大小测量框（v2 重构改没）。两层根因：① 单击 draft 三价相等/时间零宽，sanitize 只补 0.2% 价距＋60s，15m 下压成 8px 细条≈不可见；② `timeToCoordinate` 对**非整根时间**（＋60s 落在两根之间）返回 null→整个工具不渲染；右缘单击时＋18% 宽换算进留白区 coordinateToTime 亦 null。修：单击（未拖动）落初始框＝**可见根数×18% 整根宽**（按周期秒换算）＋主图高上下各 15% 价距（RR 1.00）；渲染/命中改 `timeToIndex(t, true)` 最近根索引＋logicalToCoordinate，任意存储时间都可见。实测：中部单击宽 17.1%/高 30%、右半数据区单击 14 根宽/高 30% 均落框并自动选中、工具按钮复位；空头单击方向正确。Web release **`trade-web-20261127-chart-lines-v2`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `e5a3b2df…`／`f1a408a0…` 与本地单链构建一致，ba 复核同哈希；该 release 为完整同源构建，含横线／竖线工具。契约测试锁定 timeToIndex＋bars*interval。后端不切换，旧 release 保留可回退。

## 横线／竖线工具 Web 发布（2026-11-27，北京时间）

Web release **`trade-web-20261127-chart-lines-v2`** 已原子切换到 `/opt/trade-tools-integrated/web/integrated/market`，目标 **47.80.22.243（首尔服务器）**。静态资源已核对 `activeLineTool`、`chart-line-editor`、横线／竖线按钮和线条编辑菜单，入口返回 200，`/integrated/v1/health` 的 database、migrations、scheduler 均为 true。后端不切换，线条数据只保存在浏览器本地缓存。

## 十字线拖拽期间不消失（改 window pointermove 驱动）Web 发布（2026-11-27，北京时间）

用户口径：拖测量框柄/拖整个工具时十字线必须在，靠它肉眼定位；十字线永远只跟随鼠标位置，不随鼠标按键状态出现/消失。根因：自绘十字线原挂容器 `mousemove`，而拖拽起点 `preventDefault`（防图表 pan）后浏览器停发兼容 mouse 事件→拖拽期间十字线消失。改挂 **window `pointermove`**（不受 preventDefault/按键状态影响）＋document mouseleave 清除，边界检查补 y<0。实测：拖中左柄期间横线 y 与鼠标精确一致、竖线 round 吸附 bar 中心＋右轴价签在位；松手后十字线保留；整体 moveDrag 期间同样跟随；指针移到主图区外清除。Web release **`trade-web-20261127-crossdrag-ee0b856`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `89efa329…`／`d01924a4…` 与本地单链构建一致，ba 复核同哈希（CSS 未变沿用 `e7f3e274…`）。契约测试锁定 window pointermove 监听。后端不切换，旧 release 保留可回退。

## 测量工具改数据坐标同层锚定＋标签字号减半 8px Web 发布（2026-11-27，北京时间）

用户口径：字号太大缩为现在一半（16→8px）；测量工具不是浮层，尺寸随 K 线同比缩放、与蜡烛同一层。实现：`PositionTool` 改存 `startTime/endTime/entryPrice/targetPrice/stopPrice`（弃屏幕比例字段），渲染经 `timeToCoordinate/priceToCoordinate` 换算，拖拽/绘制/命中全走数据坐标（localStorage 键升 `trade-web-position-tools-v2`）；库价格轴无订阅 API，覆盖层加 rAF 同步环比对 `getVisibleLogicalRange`＋`priceScale().getVisibleRange` 变化即重排；surface 加 `overflow:hidden`，手动压价窗时止损区不再溢入 MACD 副图。实测：barSpacing×2 工具宽 205.875→411.75px 精确加倍；DOM left/width/三线 y 与库换算误差 <0.01px；纵向压窗后 y 随价格窗同比移动；中左柄 dStart+4500s/dEntry+0.0085 其余 0、右柄 dEnd+3600s 其余 0、左上柄 dTarget+0.0056 其余 0；三标签 computed 8px。Web release **`trade-web-20261127-toolanchor-ef0568a`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `38d20547…`／`e04b6988…`／`e7f3e274…` 与本地单链构建一致，ba 与 IP 双入口复核同哈希。并发会话同期给覆盖层加横/竖画线工具，一并纳入同源构建与契约测试。后端不切换，旧 release 保留可回退。

## 止损/止盈/入场 chip 文字加倍（8→16px）条放大 Web 发布（2026-11-27，北京时间）

三条文字条（止损/止盈线标签＋中线入场 chip）字号 8→16px（加倍），条 padding 2/4→3/6（chip 3/7、圆角 5），止盈/止损标签偏移适配（-32/6px）。实测三条 computed 16px、chip 高 28px。Web release **`trade-web-20261127-labelsize-c0364e1`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/CSS 哈希 `7a06405f…`／`e8a5af3b…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定 16px。后端不切换，旧 release 保留可回退。

## 四柄最终规格（中左 move 光标＋仅左/中线，不带动整体）Web 发布（2026-11-27，北京时间）

用户最终明确：左上/左下仅上下；右仅左右；中左悬停四向箭头（cursor:move）、按下拖拽只动左边界＋中线，**不带动止盈/止损/整体**。修：leftFree 分支去掉 target/stop 随移；middle-left cursor grab→move。实测：中左 dLeft30/dEntry25/dTarget0/dStop0；左上 dTarget25 其余 0；右 dWidth30 其余 0；cursor=move。Web release **`trade-web-20261127-handles2-bd8ab20`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `6e69f158…`／`5de8bf4c…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定。后端不切换，旧 release 保留可回退。

## 左柄被边线遮挡＋拖工具带动图表 双修 Web 发布（2026-11-27，北京时间）

① 左柄无法上下根因：左边线条 z-index:2 盖住柄（无 z），点击命中 leftX 边线而非 leftFree 柄；柄提 z-index:3 后自由四向生效（实测上下 24/横向 0 的纯竖向拖拽✓）。② 拖工具时图表跟平移根因：真实 mousedown 落到图表画布启动 pan；在 window down 命中/绘制分支与 beginHandle 加 preventDefault 阻断兼容鼠标事件（mousemove 仍供十字线）。实测区内拖拽工具 +40 且图表 visibleLogicalRange 不变✓。Web release **`trade-web-20261127-dragfix-c59d1eb`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `bea2bca4…`／`ec98a4d1…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定 z3＋preventDefault。后端不切换，旧 release 保留可回退。

## 测量四柄轴向规则定案 Web 发布（2026-11-27，北京时间）

用户明确四柄规则：左上/左下仅上下；右仅左右；左自由四向（按住即拖、光标不变箭头）。实现：top-left/bottom-left 保持 targetY/stopY；middle-right 改 rightX（仅宽度）；middle-left 新增 leftFree（leftX＋entryY 联动，止盈/止损随中线平移）；middle-left 光标 grab。本地实测：top-left dTarget20/dx0；bottom-left dStop14/dWidth0；middle-right dWidth30/dStop0；middle-left dx30/dEntry20/dTarget20。Web release **`trade-web-20261127-handles-e1218f6`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `a6286976…`／`e8a9a063…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定四柄。后端不切换，旧 release 保留可回退。

## 右键菜单闭环（复制即关／设为止损价直填）＋右区提示全删 Web 发布（2026-11-27，北京时间）

① 复制当前价格完成后菜单立即关闭，删"已复制"态；② 新增右键项"设为止损价"：直接把右键横线价格（分档精度）经 App stopPriceRequest 注入 TradePanel 止损输入框，无需复制；③ 右侧交易/盘面区域提示全删（notice state/setNotice/pg-notice 全链移除，含"已粘贴止损价"）。本地实测：菜单三项（刷新/设为止损价/复制当前价格）、设值 1.333≈横线价 1.3328、两操作后菜单均关闭、右区无 notice。Web release **`trade-web-20261127-ctxstop-ec03da3`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `2f007d0d…`／`b125a77a…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定。后端不切换，旧 release 保留可回退。

## 十字线中点跳变（自绘 round 取整替代库 ceil）Web 发布（2026-11-27，北京时间）

用户报十字线需到下一根中轴线才跳，期望越过两根中点即跳。根因：lightweight-charts coordinateToIndex 用 Math.ceil（中心才跳）。修：隐藏库十字线（vertLine/horzLine visible:false），改容器 mousemove 自绘：coordinateToLogical→**Math.round**→logicalToCoordinate 得吸附中心，自绘竖/横虚线＋原价格/百分比标签；mouseleave 清除。本地实测中点 582：581→前根 578.5、583→后根 586.125＝中点跳变✓。Web release **`trade-web-20261127-crosssnap-b8c1e54`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `bbe06b39…`／`bbf1ca0e…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定 round＋自绘线。后端不切换，旧 release 保留可回退。

## 网站 favicon 与页头 logo 换用 iOS AppIcon Web 发布（2026-11-27，北京时间）

复用 iOS 工程 AppIcon-1024.png：复制为 trade-web/public/favicon.png；index.html 增 rel=icon＋apple-touch-icon；页头 brand-glyph 三菱形改 img.brand-logo（26px 圆角 6）；登录门禁/加载态 account-page-glyph 改 img.account-page-logo（34px 圆角 8）；删旧 glyph CSS。本地实测 img loaded naturalWidth=1024。Web release **`trade-web-20261127-icon-acb6224`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/favicon 哈希 `c1d7be17…`／`83194a74…` 与本地一致，线上 favicon 200。后端不切换，旧 release 保留可回退。

## 测量工具选中语义修正（区内选中/区外取消）＋去空态提示 Web 发布（2026-11-27，北京时间）

① 选中仅发生在测量区间内点击（left/right×min/max Y 命中）；**区外点击取消选中**（setSelectedId(null)）；② 悬停不再显示手柄/高亮（interactive=selected，删 hoveredId），避免"看起来被选中"；③ 删除空态提示文字"选择多头或空头，然后在 K 线区域拖出测量区间"（JSX＋CSS）。本地实测：区内点击 4 柄、区外点击 0 柄、空态不存在。Web release **`trade-web-20261127-select-d30ee61`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `1877ac97…`／`a83a75bb…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定。后端不切换，旧 release 保留可回退。

## 测量中线 chip 重设计（右端绿底白字含入场/RR/浮盈亏）＋中线柄上下移动 Web 发布（2026-11-27，北京时间）

① 中线统计 chip：去多头/空头字、常显、右端对齐（right:0）置于中线上方 2px、绿底白字圆角 4px、单行紧凑「入场 x · RR x · ±x」，min-width 删除；② 原入场价位信息条删除（信息并入 chip）；③ 止盈标签绿底白字、止损标签红底白字（圆角 3px）；④ 中线左右两个调整柄改 entryY 上下移动中线（原 leftX/rightX 由左右边线保留）。本地实测：chip 右对齐/线上/绿底白字/无方向字、入场条消失、止损红底/止盈绿底、中线柄拖动 entry 移动 30px。Web release **`trade-web-20261127-chip-3ea09da`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/CSS 哈希 `7e23aba0…`／`33d48cae…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定。后端不切换，旧 release 保留可回退。

## 测量工具区保留图表十字线（悬停＋拖拽全程）Web 发布（2026-11-27，北京时间）

根因：测量覆盖层 pointer-events:auto 拦截鼠标事件，lightweight-charts 收不到 mousemove 故十字线消失（合成事件转发不可靠：库仅在 mouseenter 后订阅 mousemove 且挂 topCanvas）。根因修复：覆盖层 surface/drawing 改 pointer-events:none（真实鼠标事件直达图表，十字线原生保留），工具交互改 window 级 pointerdown/move/up 监听＋矩形命中测试（liveRef 镜像状态避免闭包过期）；手柄/边线/三线保留 pointer-events:auto 供拖拽；悬停高亮改 window move 命中。本地实测（rAF shim）：工具区悬停十字线 true、拖拽中 true、工具平移 40px 生效。Web release **`trade-web-20261127-crosshair-2ebd87b`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `e50559cd…`／`ef8529f7…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定 pointer-events:none＋window 监听。后端不切换，旧 release 保留可回退。

## 测量工具中面板置分割线上方＋拖拽柄减半 Web 发布（2026-11-27，北京时间）

Codex 版 PositionToolOverlay 两处 UI 修正：① RR/方向/浮动盈亏小面板原 translate(-50%,-50%) 压在入场盈亏分割线上，改 translate(-50%,calc(-100% - 4px)) 整体置于分割线上方 4px；② 四个拖拽圆角方柄 22px→11px（边框 3→1.5、圆角 6→3、偏移 -11→-5.5）。本地实测 statsBottom 318 ≤ entryTop 322、柄 11×11。Web release **`trade-web-20261127-postool-ed9da75`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/CSS 哈希 `b361f099…`／`09ccda94…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定。后端不切换，旧 release 保留可回退。

## 精简稳固批次：删游客入口／死代码／fee 单源／workers2／模式头 Web+后端发布（2026-11-27，北京时间）

按用户授权"先 iOS/Web、删游客、其余架构项自决推进、精简单稳固"执行：① Web 删除游客登录入口与共享账号 88888888 虚构（AccountDialog enterGuest/分隔/按钮、AccountProvider guest 同步分支、account.ts role guest、App/TradePanel/KlineChart guest 判定、死 guest CSS）；iOS 本无游客不动。② 删死代码 CompactIndicatorStrip 全链（组件/css/lib/两测试/runner 行）。③ server fee 常量单源 common/fees.py（trading/positions views 改导入，含 L2213 内联字面量）。④ uvicorn workers 1→2（Dockerfile；切币 hang 饱和证据触发 2026-11-14 审查 P2 扩容条件；fanout 每 loop 单 reader 假设按 worker 成立）。⑤ Web REST 显式 X-Trading-Mode: ordinary 补契约缺口（iOS/harmony 已带）。Web release **`trade-web-20261127-lean-85bc0dc`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `5bf1b1ec…`／`c74a3fec…` 与本地一致，ba 复核同哈希且页面"游客"0 命中。后端随 quick_deploy 切换为 **`integrated-quick-f8c114d`**（四容器、切换前活动命令 0、health 全 true；docker top 确认 uvicorn master＋2 worker）。server 定向测试 849 例：1 环境性 error（本地缺 MARKET_TEST_REDIS_BINARY，既有）＋1 过时 SWR 断言已对齐有界同步补页设计后全绿。旧 release 保留可回退。

本次多空测量工具改动已发布到 **47.80.22.243（首尔服务器）**。Web 静态 release 为 **`trade-web-20261127-local-b74be41`**，后端 release 为 **`integrated-quick-b74be41`**。线上周期栏后的多头／空头图标、默认 1:1 最小高度、抓手光标、测量区域平移和浏览器本地缓存已由静态产物与入口核对，health 的 database、migrations、scheduler 均为 true。Web 不再发送 `positionTools` 账号设置，后端也已移除对应接收校验。

测量框编辑态随后发布为 Web release **`trade-web-20261127-resize-fce2cb6`**。静态资源已核对 `position-tool-resize-handle`、`position-tool-edge` 和左右边 `ew-resize` 样式，线上入口 200，`/integrated/v1/health` 的 database、migrations、scheduler 均为 true。

## 新版多空测量工具整合发布（2026-11-27，北京时间）

本地提交 **`85bc0dc`** 接入 `PositionToolOverlay`、`positionTools` 账号偏好和 Django 设置校验，删除旧版 `KlineChart` 多空／斐波那契测量。Web 静态 release **`trade-web-20261127-position-tools-eb450bc`** 已原子切换到 `/opt/trade-tools-integrated/web/integrated/market`，目标 **47.80.22.243（首尔服务器）**。线上与本地哈希一致：index `5bf1b1ec…`、JS `c74a3fec…`、CSS `2002943e…`。线上 JS 含 `position-tool-trigger` 和 `positionTools`，旧版斐波那契入口已移除。

本轮快速后端发布创建 **`integrated-quick-eb450bc`**。服务器当前容器为同工作区后续发布的 **`integrated-quick-f8c114d`**，运行中的 `server/web/validation.py` SHA-256 `1f9fcd0d…` 与本地一致，`positionTools` 校验已生效。公网 `/integrated/v1/health` database、migrations、scheduler 全 true，四个应用容器 healthy，未新增 migration，未做数据库备份。Web 测试、构建、Django `web` 测试和 `trading positions web` 710 项回归通过。未推送 GitHub，也未执行真实交易、资金或保护单操作。

## 历史卡开平仓时间左下＋全量提交 Web 发布（2026-11-27，北京时间）

历史仓位卡开/平仓时间原被 `.pg-card footer` 的 align-items:center 覆盖居中；改 `.pg-card footer.pg-times` 提 specificity＝column＋flex-start＋justify-end＝左下角。Web release **`trade-web-20261127-histleft-b342a82`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/CSS 哈希 `229a3412…`／`4e3dfc9f…` 与本地单链构建一致，ba 复核同哈希。**按用户指令全量提交 b342a82**（18 文件：测量工具/右键菜单/复制粘贴/面板与列表样式/历史左下/切币 autoScale 与 hang 重试/tiny 价格/方框偏移/线序＋契约与单测），未推送。后端不切换，旧 release 保留可回退。

## 导航芯片加高／去列表编号／币名加粗 USDT 缩小 Web 发布（2026-11-27，北京时间）

① 主导航选中圆角芯片加高：main-nav align-self:stretch＋padding 4px 0、nav-item height:100% → 芯片比顶栏上下各窄 4px（实测栏 56/芯片 47）；② 去掉所有筛选组（市值前20/山寨/涨幅/跌幅）交易对编号（market-rank 全删含 CSS）；③ 币名 strong 700 加粗、"/USDT" span 9px 缩小弱化。本地实测 ranks=0（山寨组）、nameWeight 700、usdtSize 9px。Web release **`trade-web-20261127-navlist-94b3ee3`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `a3252c71…`／`aafd20fb…`／`bb380b21…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定。后端不切换，旧 release 保留可回退。

## tiny 价格右轴无价格修复（分档精度＋动态 minMove）Web 发布（2026-11-27，北京时间）

用户报价格 0.00012 级时右轴不显示任何价格。根因：分档精度只到 4 位小数（0.0000123→"0.0000"）＋minMove=0.0001 过粗把刻度全舍入抹平。修：抽 lib/priceFormat（priceScaleFormatter 增 <1e-4→8 位、<0.01→6 位档；minMoveFor 按量级 1e-8/1e-6/1e-4）；renderData 全量路径按尾根量级对主图全部系列 applyOptions priceFormat.minMove；持仓/测量/斐波那契标签改用分档 formatter。单测 priceFormat.test.ts 七组量级断言入 runner；本地 stub 0.00012 实测 candle priceFormat.minMove=1e-6。Web release **`trade-web-20261127-tinyprice-94b3ee3`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `f2fef010…`／`72ba9f8c…` 与本地单链构建一致，ba 复核同哈希。后端不切换，旧 release 保留可回退。

## 交易面板四项 UI（标签单行/粘贴图标/报错底部/可关闭）Web 发布（2026-11-27，北京时间）

① 止损价等字段标签 flex:none＋nowrap 单行；② 「粘贴」文字按钮改 ClipboardPaste 小图标，置于止损输入框内右 6px（与止损金额箭头同位），点击直接填入；③ 报错/提示 notice 移至交易面板最底部（开仓设置之下）；④ notice 整行右上角加关闭按钮（pg-notice-close）点击消失。本地实测：nowrap、图标在框内 rightGap=6、notice isLast=true＋close 生效、粘贴值 486.54 联动。Web release **`trade-web-20261127-panelui-94b3ee3`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `23ee0845…`／`0d2b5da1…`／`45d28345…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定四项。后端不切换，旧 release 保留可回退。

## 复制改鼠标横线价＋止损价粘贴按钮 Web 发布（2026-11-27，北京时间）

用户澄清复制语义＝鼠标所处横线价格（非最新市价）；止损输入框右加「粘贴」。修：contextmenu 时 coordinateToPrice(cursorY) 存入 clickMenu.price；copyCurrentPrice 用该价（缺省回退尾根）经 priceScaleFormatter 格式化后写系统剪贴板＋会话共享模块 lib/priceClipboard；TradePanel 止损价 input 右侧「粘贴」按钮读共享值填入并重置幂等键＋提示"已粘贴止损价"。本地闭环实测：右键横线→复制→粘贴→input=486.54（=复制存储值）＋提示出现。Web release **`trade-web-20261127-paste-94b3ee3`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `e43ae782…`／`6fd4e4a6…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定横线价捕获与粘贴链路。后端不切换，旧 release 保留可回退。

## 做多/做空/斐波那契三测量工具 Web 发布（2026-11-27，北京时间）

对齐 TradingView 测量工具新增三工具，图标置于周期同一横条（toolbar-left 周期后 divider＋TrendingUp/TrendingDown/Rows3）。交互：点图标激活（绿芯片选中）→图面拖拽定锚（期间禁平移/缩放）→抬起提交；做多/做空＝入场/止损线＋红亏区/绿盈区＋目标按 RR=2，标签含开仓价/止损%/止盈% RR2；斐波那契＝0/0.236/0.382/0.5/0.618/0.786/1 七档横线＋价格标签；锚点用 time+price 存储，平移/缩放/resize/尾根经 drawTick 重算覆盖层；右键菜单增「清除测量」。本地合成拖拽实测：多头 tags 开仓476.3673/止损-3.81%/止盈+7.62% RR2＋2 zones；fib 7 档；清除归零。Web release **`trade-web-20261127-measure-94b3ee3`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `41cb22d8…`／`dbdca736…`／`fd6148c3…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定三工具/RR/fib/清除。后端不切换，旧 release 保留可回退。

## 切币空白第五层根因＝价格轴 autoScale 冻结旧币价格窗 Web 发布（2026-11-27，北京时间）

用户报切币仍空白、但点手动→自动即出图，要求务必根治。关键线索定位：resetView 会恢复各 pane priceScale autoScale；而手动模式竖向拖动/价格轴缩放会 setAutoScale(false) **冻结旧币价格窗**，切币 effect 此前只换数据不恢复 autoScale → 新币蜡烛全落在冻结窗外＝空白（数据其实已加载）。修：切币/切周期 effect 内恢复全部 pane autoScale:true。DEV-only `window.__chart` 钩子（生产构建 grep=0 确认剔除）本地实证：手动竖拖后 autoScale=false、窗 0.00139–0.00185（旧币）；切 XMR 后 autoScale=true、窗 436.7–529.6、ready 无 error。Web release **`trade-web-20261127-autoscale-94b3ee3`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `40f926c0…`／`f414eb7a…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定切币 autoScale 恢复（≥2 处）。至此切币链路五层根因（跨币污染/尾根桶/冷币空表/队列 hang/价格窗冻结）全部闭环。后端不切换，旧 release 保留可回退。

## 菜单改右键触发＋竖排＋屏蔽浏览器原生右键 Web 发布（2026-11-27，北京时间）

用户纠正：菜单应右键触发（此前左键误触发），且浏览器原生右键（图片另存为/复制图片/检查）需屏蔽；菜单上下排列。修：删除左键 pointerup 开菜单逻辑（downAt 全删），改 container contextmenu 监听 preventDefault＋开菜单（clamp 130×76）；左键 pointerdown 仅关菜单；菜单 CSS flex-direction:column、按钮左对齐满宽。本地合成事件实测：左键不开、右键 defaultPrevented=true＋菜单 column＋刷新/复制当前价格于点击坐标。Web release **`trade-web-20261127-ctxmenu-94b3ee3`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `826b5b47…`／`eb00da91…`／`dec9b946…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定右键/竖排/无左键逻辑。后端不切换，旧 release 保留可回退。

## 切币挂起超时重试＋三框右移两条款 Web 发布（2026-11-27，北京时间）

用户报切币仍加载不出。深查第四层根因：生产 api 为 uvicorn 单 worker＋Django thread_sensitive 同步单线程，冷币同步补页（Binance REST 数秒）占住线程时后续请求**排队挂起不返回**——空表重试救不了 hang（蒙层长转）。修：fetchHistory 每 attempt 加 12s Promise.race 超时守卫，超时/瞬断（非 Abort）均退避重试≤6 次保留蒙层，超限才 error；guard 计时器 settle 即清。另三框（开仓/止损/浮盈亏）整体再右移两个条宽：base=8+2*strip，pnl=base+strip+8，止盈仍 1/6。本地 stub 实测：非预取币 AKE 首请求挂起→2s 蒙层在→12s 超时重试→15s 出图无 error；偏移 156/156/238 @strip74。Web release **`trade-web-20261127-hangretry-94b3ee3`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `ba83eeb9…`／`e7def7ae…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定超时守卫与偏移。后端不切换（线程模型属后端架构，如需扩容另议），旧 release 保留可回退。

## 指标线序（快/绿在上）＋方框贴左缘/浮盈亏条宽右移 Web 发布（2026-11-27，北京时间）

源码基线 **`94b3ee3`**＋本会话未提交改动。Web 静态 release **`trade-web-20261127-lineorder-94b3ee3`** 原子切换到 `/opt/trade-tools-integrated/web/integrated/market`（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `7b1fd7e8…`／`57698240…` 与本地单链构建一致，ba 复核同哈希。① MACD 慢线 DEA 先加、快线 DIF 后加（后加绘制在上）→DIF 压 DEA；StochRSI 紫 D 先加、绿 K 后加→K 压 D。② 开仓/止损方框贴左缘 8px；浮盈亏方框＝8＋字条实测宽＋8（一个条宽右移错开）；止盈保持 1/6。本地 stub 实测 entryW=74→pnl left=90、entry/stop=8、tp=82。契约测试锁定线序与偏移。后端不切换，旧 release 保留可回退。

## 持仓方框分组偏移（开仓/止损 1/8、浮盈亏/止盈 1/6）Web 发布（2026-11-27，北京时间）

用户要求错开方框避免重叠：开仓/止损左偏移改 **1/8 屏宽**，浮盈亏与止盈保持 1/6。layoutPosLabels 按 key 分组取 leftEighth/leftSixth。本地 stub 实测 w=492 时开仓/止损 left=62(=492/8)、浮亏/止盈 left=82(=492/6)。Web release **`trade-web-20261127-labeloffset-94b3ee3`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `d9b6f516…`／`c5ea77fa…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定分组偏移。后端不切换，旧 release 保留可回退。

## 刷新＝完整重置＋点击图面菜单（刷新/复制当前价格）Web 发布（2026-11-27，北京时间）

源码基线 **`94b3ee3`**＋本会话未提交改动。Web 静态 release **`trade-web-20261127-clickmenu-94b3ee3`** 原子切换到 `/opt/trade-tools-integrated/web/integrated/market`（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `062ced96…`／`d697fa3d…` 与本地单链构建一致，ba 复核同哈希。① 刷新按钮修复：refreshChart 成功后追加 resetView()（模式回自动＋各 pane autoScale＋自动留白视口），空表置 error 不再假成功；此前仅 renderData(resetView=true) 不复位手动模式/价格轴缩放致"重置不成功"。② 点击图面（pointerdown/up 位移≤5px 判定点击，拖拽不触发）在点击处弹小菜单：「刷新」同顶部刷新；「复制当前价格」复制尾根收盘（priceScaleFormatter 分档精度），clipboard API 失败回退 execCommand，成功显示"已复制"；菜单边界 clamp、点外部/拖拽自动关闭。本地合成指针实测菜单于点击坐标出现、两按钮齐全；隐藏面板无焦点剪贴板回退失败属环境限制，复制成功归线上验收。后端不切换，旧 release 保留可回退。

## 持仓线方框左 1/6＋现价涨跌色＋挂止盈单画线 Web 发布（2026-11-27，北京时间）

源码基线 **`94b3ee3`**＋本会话未提交改动。Web 静态 release **`trade-web-20261127-poslabel-94b3ee3`** 原子切换到 `/opt/trade-tools-integrated/web/integrated/market`（目标 **47.80.22.243（首尔服务器）**），index/JS/CSS 哈希 `6a11cce8…`／`bbe813bb…`／`0a88ab0c…` 与本地单链构建一致，ba 复核同哈希。① 开仓/止损/浮盈亏/止盈所有方框改 DOM 层（.pos-label-layer/.pos-label）定位**左 1/6 屏宽**（axisLabelVisible:false 去右轴框），y 由 sync 记录的价格表＋priceToCoordinate 布局，随 tail/resize/可见范围变化重排；② 现价线颜色随 tick 涨跌绿/红（prevClose 基线，首帧用前一根收盘）；③ 已挂止盈单（/v1/trade/order/list kind *take_profit 且 can_cancel）逐单画绿虚线＋「止盈 L1/L2 价」方框，5s 轮询同步撤单消失。本地 stub 实测五方框 left=82(=492/6)、文案/颜色正确；隐藏面板价格坐标退化致 y 序不可本地判定，y 对齐归线上验收。后端不切换，旧 release 保留可回退。

## 切币K线空白深查根因＝冷币空表无重试 Web 发布（2026-11-27，北京时间）

用户报切币仍加载不出K线，深查后端 `service.load_history`：冷币首请求若同步补页失败/锁被占（连续切币竞争）即返回 `items: []`＋`historyPending: true` 并异步修复；前端旧逻辑把空表当成功渲染→撤蒙层→永久空白，且 prefetch 会缓存空快照。修：数据 effect 改 fetchHistory(attemptNo) 退避重试（空表保留 loading 蒙层，1.2s×(n+1) 最多 6 次，超限才 error）；空表不写缓存；klineCache.prefetch 空表不入缓存；cleanup 清 retryTimer。本地 stub 实测：前两次空表期间蒙层保留、第 3 次出图（calls=3）、无 error。Web release **`trade-web-20261127-emptyretry-94b3ee3`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `47da56c2…`／`cf4195dc…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定空表重试与空缓存禁令。叠加此前世代令牌（跨币污染）与 ticker 桶守卫（尾根开收盘），切币链路三层根因均已修。后端不切换，旧 release 保留可回退。

## 持仓卡 footer 重排＋K线持仓三线 Web 发布（2026-11-27，北京时间）

源码基线 **`94b3ee3`**＋本会话未提交改动。Web 静态 release **`trade-web-20261127-poslines-94b3ee3`** 原子切换到 `/opt/trade-tools-integrated/web/integrated/market`（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `e96edfbd…`／`1b69cb19…` 与本地单链构建一致，ba 复核同哈希。① 持仓卡：去「止盈」标题，自动止盈(中)按钮缩小（11px/5px  padding）移入 footer 置于「立即平仓」左侧。② K线图持仓三线（该币有持仓时）：开仓价蓝虚线＋轴框「开仓 x.xxxx」；止损红虚线＋轴框「止损 -亏损额U」（亏损额=名义×|开仓-止损|/开仓）；现价点线＋轴框「浮盈/浮亏 ±x.xxU」随尾根实时刷新（renderData tail/全量两路径＋5s 持仓轮询）；无持仓/切币清理 removePriceLine。契约测试锁定三线与 footer 顺序。只读展示不触发资金操作。三线观感归线上验收（隐藏面板 canvas 不绘制）。后端不切换，旧 release 保留可回退。

## 自动视图右侧留白 1/5 Web 发布（2026-11-27，北京时间）

用户澄清期望：点自动复位后最新根**不应顶到右缘**，应留 1/5 空白（现状 setVisibleLogicalRange(to=len-1) 不应用 rightOffset 故顶满）。修：autoRange(length)＝{from: max(0, last-0.8*bars+0.5), to: last+0.2*bars-0.5}，跨度仍=autoVisibleBars 保持 7.6px 密度，最新根落视口 80% 处＝右侧 20% 留白；renderData auto 分支/resize/resetView 三处统一改用。契约测试含 80% 位置与跨度数值自检。Web release **`trade-web-20261127-rightgap-94b3ee3`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `310dfb03…`／`940760af…` 与本地单链构建一致，ba 复核同哈希。手动模式 rightOffset=5 滚动余量保留。留白观感归线上验收。后端不切换，旧 release 保留可回退。

## 最新K线开收盘对不上修复（ticker 桶守卫＋成交量收盘计入）Web 发布（2026-11-27，北京时间）

用户报K线开盘/收盘对不上、尤其最新根。根因：mergeTicker 无条件改写最后一根——大周期桶滚后新桶蜡烛尚未由 1m 聚合生成（等首条 1m 推送）期间，ticker 价格写进**上一已收盘根**，其 close/high/low 被实时价污染＝开收盘对不上；另聚合分支对同一 forming 1m 反复累加 volume 致成交量虚高。修：mergeTicker 增 bucketTime 参数（由 eventTime 推导当前桶），桶<尾根＝忽略、桶>尾根＝ticker 种子新根（open=high=low=close=价）、桶=尾根才改 close/high/low；聚合 volume 仅 event.closed 时累加。新增 tests/candleMerge.test.ts 确定性单测（闭根不被改写/滚桶种子/过期桶忽略/空列表种子/mergeCandle 三态）入 runner。Web release **`trade-web-20261127-tailfix-94b3ee3`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `15c4c1d3…`／`e5739073…` 与本地单链构建一致，ba 复核同哈希。本地 WSGI 无 WSS 不能实测尾根跳动，单测＋契约断言锁定语义，尾根观感归线上验收。后端不切换，旧 release 保留可回退。

## 切币K线空白竞态修复 Web 发布（2026-11-27，北京时间）

用户报切换标的较大概率K线完全加载不出来。根因：左滚历史补载 loadOlder 在 await 期间若切币/切周期，旧币历史会 prepend 进新币数组并 **putCachedKlines 污染新币会话缓存**；混合价格域（如 BTC 十万级混入 SOL 几十级）把新币蜡烛压成平线/空白，且污染缓存使回切持续复现（会话内 Map，MAX_ENTRIES 12）。修：loadGenRef 世代令牌——数据 effect 与 refreshChart 推进世代，loadOlder await 后世代不符或 symbol 不符即丢弃。Web release **`trade-web-20261127-switchfix-94b3ee3`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `a55e5eae…`／`486d3a0d…` 与本地单链构建一致，ba 复核同哈希。契约测试锁定世代守卫。本地冒烟：ETH/XRP/ZEC 等切币 1.2s 内收敛 ready 无 error；冷门币（MANTRA/INIT/ENA）本地冷 fetch >1.2s 仍 loading 属后端历史冷加载延迟（生产 SWR+预热覆盖 majors），非本竞态。隐藏面板无法实测污染复现，归线上验收；若仍复现请提供币种与截图。后端不切换，旧 release 保留可回退。

## 持仓卡止盈模块／平仓绿色右下角／保证金弹窗／计数反色 Web 发布（2026-11-27，北京时间）

源码基线 **`94b3ee3`**＋本会话未提交改动。Web 静态 release **`trade-web-20261126-tpcard-94b3ee3`** 原子切换到 `/opt/trade-tools-integrated/web/integrated/market`（目标 **47.80.22.243（首尔服务器）**），线上 index/JS/CSS SHA-256 与本地单链构建一致（`c88a2698…`／`729e0f48…`／`426b4ed3…`），ba.wow211.com 复核同哈希。① 持仓卡新增「止盈」模块＋「自动止盈」按钮（运行中显示「自动止盈中」绿芯片），点击弹窗展示该持仓绑定策略快照（strategy_name/strategy_config 来自 /v1/position/list）各档 RR/减仓/止损类型；未绑定时展示当前启用策略或引导账户页。② 「立即平仓」移右下角改实底绿（浅色白字）。③ 保证金率徽标改按钮→「保证金详情」弹窗（保证金率/钱包/保证金/可用余额＋强平警示）。④ 导航持仓计数徽标选中反色（未选绿底深字→选中近白底绿字）。本地 stub 持仓实测：反色 computed、绿平仓 flex-end、止盈弹窗两档、保证金弹窗四字段全正确。只读展示，未触发任何真实平仓/改策略。后端不切换，旧 release 保留可回退。

## 实时推送全层恢复（ticker 通配＋1m feed 客户端聚合）（2026-11-27，北京时间）

源码 `7f525e0`/`0d24908` 已推送，Web `trade-web-20261127-agg-0d24908` 已上线（哈希 `c88a2698…` 一致）。ticker 改后端通配单 topic（空 symbols）收全量；kline 订阅 1m 实时 feed，大周期客户端聚合到对应桶（open/high/low/close），尾根实时且带影线。生产分层诊断全绿：WS 已连接、ticker 收到报价、kline 收到K线。连接层无需再改。

## 实时层重构：单一共享 WS＋token 主动续期（2026-11-27，北京时间）

架构评审结论：WS subprotocol 鉴权链路本身正确（浏览器手动带 subprotocol 可 open、refresh 200），不稳定根因是**多组件各自建流＋token 被动续期竞态**（App/图表/分析各开一条 WS，token 过期被拒后重连竞态）。重构为 `lib/realtime.ts` 单一 MarketRealtime：合并订阅单连接、连接前 `ensureFreshToken`、到期前 90s 主动续期、指数退避重连、延迟/分层状态广播；移除 BinanceStream。生产实测由"连接中断"恢复为**实时连接 148ms**。源码 `ffdec2a`/`a900457` 已推送，Web `trade-web-20261127-realtime2-a900457` 已上线（哈希 `8cfcd2b3…` 一致）。

## 连接分层诊断 Web 发布（2026-11-26，北京时间）

源码 **`b50ea94`** 已推送。Web **`trade-web-20261126-diag-b50ea94`** 原子切换（哈希 `42e0060d…` 与本地一致）。点击连接状态打开分层诊断：域名/TLS/证书、REST 行情目录、WS 握手/鉴权、WS ticker 推送、WS kline 推送，各段红绿点＋明细＋重新检测。生产实测：TLS 147ms ok、REST 已同步、**WS 握手/鉴权=被拒**（后端 ValueError=缺 bearer）。服务端直连/经 nginx 带 subprotocol 均 101，残差在浏览器侧 token/subprotocol 送达（疑似新域名 refresh cookie path 致 token 未续），待针对性排查。大周期下影线数据核验正确（low=min 源 low），实图有下影线；刷新按钮可强制重拉。

## 右侧价格标尺鼠标缩放恢复 Web 发布（2026-11-26，北京时间）

用户反馈价格标尺拖拽缩放消失。根因：ux4 为满足「图面拖动不缩放」误将 handleScale.axisPressedMouseMove 全关（连价格轴拖拽缩放一起禁掉）。恢复 axisPressedMouseMove:true（自动/手动两模式），图面左键拖动仍只平移不缩放；手动竖向平移 handler 增几何守卫（pointer 落在右价格标尺宽度内即跳过，交还轴缩放）。Web release **`trade-web-20261126-axiszoom-af642f7`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/JS 哈希 `b17f4784…`／`9803491b…` 与本地单链构建一致，ba 复核同哈希。契约测试改锁 axisPressedMouseMove:true＋轴区守卫。轴拖拽为库原生指针交互，隐藏面板不可合成驱动，归线上验收。后端不切换，旧 release 保留可回退。

## 主导航按钮长度恢复 Web 发布（2026-11-26，北京时间）

用户反馈 ux4 为做首项对齐把导航改自然宽（flex:0 0 auto）致选项按钮变短。恢复 ux3 拉伸规格：`.main-nav` width clamp(320,(100vw-480)/2,860)＋space-between、`.nav-item` flex:1 居中；首项对齐 margin 逻辑保留（实测差值补 marginLeft）。Web release **`trade-web-20261126-navlen-af642f7`** 原子切换（目标 **47.80.22.243（首尔服务器）**），index/CSS 哈希 `3965c96c…`／`e0686902…` 与本地单链构建一致，ba 复核同哈希。契约测试新增拉伸规格断言防再缩。后端不切换，旧 release 保留可回退。

## K 线连续性修复＋刷新按钮发布（2026-11-26，北京时间）

源码 **`a52f77b`** 已推送。后端 **`integrated-quick-a52f77b`**、Web **`trade-web-20261126-refresh-a52f77b`** 均已上线（ba/IP 200、哈希 `e38dd53e…`／`9867a379…`／`5e73db37…` 与本地一致、health 全 true）。① 恢复尾根过期/缺口的同步补线（修 SWR 跳过补线导致的最新开盘与上根收盘不衔接）；② 自动/手动左侧新增刷新按钮（强制重拉数据并复位视图）。实测相邻收盘/开盘仅 ±1 tick 差（下一根开盘=区间首笔、上根收盘=末笔，属正常市场微观结构），大缺口已消除。未执行真实交易/资金操作。

## 手动全向拖拽／历史补载／列表 WS 持续刷新／字号与对齐 Web 发布（2026-11-26，北京时间）

源码基线 **`2dd326e`**＋本会话未提交改动。Web 静态 release **`trade-web-20261126-ux4-2dd326e`** 原子切换到 `/opt/trade-tools-integrated/web/integrated/market`（目标 **47.80.22.243（首尔服务器）**），线上 index/JS/CSS SHA-256 与本地单链构建一致（`3dfc3d4e…`／`d5326c34…`／`849125eb…`），ba.wow211.com 复核同哈希。① 手动模式左键拖动＝横向（库）＋竖向（pointer 拖动经 priceScale.setAutoScale(false)+setVisibleRange 平移）全向移动，拖动期间不缩放（manual axisPressedMouseMove=false，滚轮/ pinch 仍可缩放）；切自动复位 autoScale。② 历史补载：可见范围 from<24 时经 getKlines beforeOpenTime 分页 prepend（300/页、上限 3000），视口 logical range 平移保持不跳；preserveView 参数防 auto 重置。③ 左侧列表持续刷新：BinanceStream 增 tickerSymbols 全列表订阅；**币安限额论证**：后端 collector 单条 `!ticker@arr` 已采集全合约（1 条 stream），web 订阅经内部 fanout 不新增币安连接/REST weight；UI 500ms 聚合批渲染防逐消息重渲染。④ 自动/手动 10→12px、指标 11→13px。⑤ 主导航首项与 K 线左缘对齐（useLayoutEffect 实测 margin＋ResizeObserver，<920px 归零）；列表选中改整行 26% 绿条；顶部筛选 active 改绿描边芯片（同自动手动强度）。本地 DOM 核对字号/筛选芯片通过；隐藏面板视口为 0 致对齐/拖拽/补载/WS 刷新不可本地实测，归线上验收。契约测试锁定全部。后端不切换，旧 release 保留可回退。

## 图表拖拽语义／交易面板跳转／卡片与导航修正 Web 发布（2026-11-26，北京时间）

源码基线 **`04c6d13`**＋本会话未提交改动。Web 静态 release **`trade-web-20261126-ux3-04c6d13`** 原子切换（目标 **47.80.22.243（首尔服务器）**），哈希 `dbbd7375…`／`644ab582…`／`767d95a0…`；并行会话随后的 connfix-04c6d13 同源同哈希接管 symlink，线上即本批 UI。① 图表：自动＝左右拖动＋滚轮缩放、锁上下（vertTouchDrag／价格轴按压缩放关），手动全向；手动→自动复位时间范围＋各 pane autoScale；删重置按钮与 wheel/pointermove 切手动监听。② 交易面板：市价/限价绿圆角芯片；空止损价按钮文案「输入止损价」；止损金额输入框同款框体＋右箭头跳账户页真实设置（删现场滑杆条）；开仓设置按钮移至开仓按钮下方同宽更矮；止盈策略行跳策略列表；账户页锚点＋focus 滚动、滑杆步长 1。③ 价格卡片涨跌两行竖排右上角与币种同行。④ 主导航加宽 clamp(320–860)、nowrap 单行、去容器底色/边框。浏览器实测跳转视口命中、重置消失、computed 正确；契约测试锁定。**连接中断**已由并行会话根因修复（ba 曾为 443 默认 server 致 IP/iOS 拿域名证书→IP 标 default_server；WS bearer subprotocol 未入鉴权 headers→websocket.py 合并 scope subprotocols），后端 integrated-quick-04c6d13 四容器 healthy；本轮复核 symlink/default_server/IP 证书（Dec 1 到期 IP lineage）/health 均正常。后端不重复切换，旧 release 保留可回退。

## 连接中断根因修复发布（2026-11-26，北京时间）

源码 **`04c6d13`** 已推送。后端 **`integrated-quick-04c6d13`** 切换四容器（healthy、health 全 true）；Web **`trade-web-20261126-connfix-04c6d13`** 原子切换（ba/IP 双入口 200，哈希 `dbbd7375…`／`644ab582…`／`767d95a0…` 与本地一致）。根因与修复：① ba server block 曾成 443 默认 server 致 IP 直连（iOS）拿域名证书 TLS 失败→IP server 标 `default_server`（已 reload，IP 连接恢复 IP 证书）；② ASGI bearer subprotocol 在 scope["subprotocols"] 被 WS 鉴权忽略致 web 永远 403→合并进 headers。服务器内实测 Authorization 头与 subprotocol 均 101，经 nginx subprotocol 复测通过。iOS 与 web 连接恢复；未执行真实交易/资金操作。

## 交易/账户对齐批次 Web 发布（2026-11-26，北京时间）

源码 **`6841bd7`** 已推送。Web 静态 release **`trade-web-20261126-parity-6841bd7`** 原子切换到 `/opt/trade-tools-integrated/web/integrated/market`（目标 **47.80.22.243（首尔服务器）**，ba.wow211.com 与 IP 双入口），线上 index/JS/CSS SHA-256 与本地一致（`17c4263c…`／`02502497…`／`b61b7d3c…`），`nginx -t` 通过并 reload。含：WS 断线刷新会话（修旧 bundle token 过期导致的"连接中断"）＋ping/pong 延迟按 iOS 阈值显示；主导航加宽＋持仓绿点；交易/盘面图形切换按钮；交易面板市价/限价＋开仓设置 Maker＋去方向待定；账户页止盈止损策略 CRUD/启用＋API 绑定/解绑全流程。后端容器不切换。开仓/挂单/绑定等写操作仅用户确认后执行；本轮验收未触发真实交易。

## 价格卡片三段式修正＋涨跌右置防溢出 Web 发布（2026-11-26，北京时间）

源码基线 **`3e1949b`**＋本会话未提交改动。Web 静态 release **`trade-web-20261126-pricecard2-3e1949b`** 原子切换到 `/opt/trade-tools-integrated/web/integrated/market`（目标 **47.80.22.243（首尔服务器）**），线上 index/JS/CSS SHA-256 与本地单链构建一致（`17c4263c…`／`02502497…`／`b61b7d3c…`），ba.wow211.com 复核同哈希。按用户最新口径重排：上币种（BTC）→「当前价格」小标→价格数字行，**增减数值＋百分比竖排置于数字右侧**；替换并行会话的"币种左／价格右上"横排（该布局右列超出卡片）。防溢出：卡片改块级、行 flex baseline＋space-between、数字 nowrap＋min-width 0、涨跌列 flex:none＋nowrap；296/260/232px 卡宽压测 row scrollWidth==clientWidth 无溢出。契约测试改锁新布局（price-card-row/label，禁 price-card-right）。并发会话同期给 TradePanel 加限价单、反转切换按钮语义（标签显示目标态），tradePanel 断言随演进对齐（稳定幂等键／二次确认／UNKNOWN 不重发保留）。后端不切换，旧 release 保留可回退。

## 工具栏按钮归位＋自动/手动圆角选中框 Web 发布（2026-11-26，北京时间）

源码基线 **`3e1949b`**＋本会话未提交改动。Web 静态 release **`trade-web-20261126-toolbar-3e1949b`** 原子切换到 `/opt/trade-tools-integrated/web/integrated/market`（目标 **47.80.22.243（首尔服务器）**），线上 index/JS/CSS SHA-256 与本地单链构建一致（`99c03ceb…`／`bb2e19d5…`／`b6fa28d6…`），**ba.wow211.com 域名复核同哈希＋选中框标记在位**。① 「重置」移入图表工具栏、置于自动/手动左侧；「向右拓展 K 线」（insight-toggle）移到「指标」右侧；删除顶栏 chart-actions portal 容器与 actionsContainer prop。② 自动/手动选中态加圆角矩形框：1px 绿描边＋5px 圆角＋12% 绿底（基础态透明描边防漂移），保留绿字加粗。浏览器实测顺序 重置→自动/手动→指标→拓展、选中框 computed 正确、拓展按钮新位置收放面板正常（本地隔离库建验收户 qoder-verify 登录）。域名说明：本会话早前按用户要求接入 tt.wow211.com（block/证书/ALLOWED_HOSTS 均就绪），用户随后在并行会话改用 ba.wow211.com 并删除 tt 的 DNS 记录（现 NXDOMAIN）；服务器 tt/ba/IP 三 block 并存，tt 若恢复 A 记录即通。后端不切换，旧 release 保留可回退。

## 域名切换 ba.wow211.com 调通（2026-11-26，北京时间）

用户改用 **ba.wow211.com**（DNS 已解析到 47.80.22.243）。原 nginx 仅有 tt/IP server block，ba 落到 IP 证书导致证书名不匹配无法访问。已：① 装 ba:80 block（acme webroot＋301 到 https）；② certbot webroot 签发 ba.wow211.com LE 证书；③ 装完整 ba:443 block（`deploy/integrated/nginx-domain.conf` 已改为 ba，安装为 sites-enabled/ba-wow211）；④ server.env `ALLOWED_HOSTS`/`CORS_ALLOWED_ORIGINS` 增加 ba（保留 tt/IP），按 quick_deploy 同参数重建 api/market/worker/scheduler 四容器（healthy）。核验：https://ba.wow211.com/ 308→/integrated/market/、market 200 且 `ssl_verify_result=0`、/integrated/v1/health 全 true。tt 与 IP 入口保留可用。cert-renew timer 覆盖 ba lineage 自动续期。

## Web HTTPS 证书与自动续期补齐（2026-11-26，北京时间）

Web 两个入口均已持受信任 Let's Encrypt 证书：域名 **tt.wow211.com**（SAN DNS，89 天）与 IP **47.80.22.243**（SAN IP，短寿命），`curl` 校验 `ssl_verify_result=0`；域名 80→443 301、根路径 308 到 `/integrated/market/`。缺口为 **cert-renew.timer 此前未安装/未启用**（IP 证书仅 4 天到期不会自动续）：已从 `deploy/integrated/cert-renew.{service,timer}` 安装并 `enable --now`（每 6h 检查），service 加 `--deploy-hook "systemctl reload nginx"` 续期后自动重载；`certbot renew --dry-run` 通过（webroot authenticator）。IP 短寿命证书按 certbot 比例窗口在到期前由 timer 自动续。`quick_deploy_remote.py` 增加幂等安装/启用 cert-renew 单元，保证后续主机可复现。

## 主导航加宽去闪／历史时间堆叠／十字线百分比 Web 发布（2026-11-26，北京时间）

源码 **`e8e97a0`** 已推送。Web 静态 release **`trade-web-20261126-nav-e8e97a0`** 原子切换到 `/opt/trade-tools-integrated/web/integrated/market`（目标 **47.80.22.243（首尔服务器）**），线上 index/JS/CSS SHA-256 与本地一致（`52f51f02…`／`f835b56d…`／`298cdcc0…`），`nginx -t` 通过并 reload。仅前端呈现，后端不切换。十字线百分比价框待线上真实鼠标验收。未执行真实交易/资金操作。

## 交易面板 v1（交易/盘面切换）Web 发布（2026-11-26，北京时间）

源码基线 **`3b0207c`**＋本会话未提交改动（TradePanel.tsx 新增、tradeApi 策略列表/稳定幂等键、App 切换、styles、契约测试）。Web 静态 release **`trade-web-20261126-trade2-3b0207c`** 原子切换到 `/opt/trade-tools-integrated/web/integrated/market`（目标 **47.80.22.243（首尔服务器）**，域名 tt.wow211.com 同入口），线上 index/JS/CSS SHA-256 与本地构建一致（`52f51f02…`／`298cdcc0…`／`f835b56d…`，`?cb=` 复核＋关键标记 grep）。**并发教训**：首次上传误拿并行会话重建的共享 dist（哈希不符），改为 build→标记 grep→rsync→切换单链执行后一致。功能：盘面速览标题右侧「交易/盘面」切换（默认交易）；交易面板复刻 iOS USDTEntryDraft 公式（名义=止损额/(|现价-止损|/现价+0.001)、手续费=名义×0.001、止损<现价=多），止损金额 50–300 滑杆点击调整走 /v1/account/stop-loss，止盈策略取 /v1/strategy/list 的 is_active 三件套（未启用禁止开仓），开仓走 /api/commands action=open＋每次意图稳定幂等键＋二次确认弹窗＋UNKNOWN 不重发。浏览器实测：71.10/止损69/120U → 3929.81U／3.93U／2.95%／开多，与公式手算一致；滑杆、切换、无策略禁开均核对；**未执行真实开仓**（验收止于确认弹窗前）。后端不切换，旧 release 保留可回退。

## 价格卡片重排 Web 发布（2026-11-26，北京时间）

源码 **`4e9f8c6`** 已推送。Web 静态 release **`trade-web-20261126-pricecard-4e9f8c6`** 原子切换到 `/opt/trade-tools-integrated/web/integrated/market`（目标 **47.80.22.243（首尔服务器）**），线上 index/JS/CSS SHA-256 与本地一致（`80969df0…`／`886f6e94…`／`02ec0b2f…`），`nginx -t` 通过并 reload。仅前端呈现，后端不切换。未执行真实交易/资金操作。

## tt.wow211.com 域名接入（2026-11-26，北京时间）

用户已将 **tt.wow211.com** 解析到 **47.80.22.243（首尔服务器）**。新增 `/etc/nginx/sites-enabled/tt-wow211`（仓库模板 `deploy/integrated/nginx-domain.conf`）：80 端口 ACME webroot＋301 跳 https；443 复用 `snippets/tradetools-integrated.conf` 全部 location，根路径 308 到 `/integrated/market/`。certbot（`/opt/certbot` venv）webroot 签发 LE 证书 `tt.wow211.com`（ECDSA，89 天），续签单元 `tradetools-integrated-cert-renew.service` 的 ExecStart 去掉 `--cert-name` 限定改为全量 renew（仓库 cert-renew.service 同步）。Django `ALLOWED_HOSTS` 原仅 IP，域名 health 400；server.env 加 `tt.wow211.com`（备份 `backups/server.env.bak-20261126-domain`）后 `up -d --no-build api market` 重建两容器（env 变更需 recreate），health database/migrations/scheduler 全 true。验证：`https://tt.wow211.com/` 308、`/integrated/market/` 哈希与线上 release 一致（`84fe37d7…`）、域名 health 200。IP 入口保持不变。

## 网格变细＋副图 TradingView 式图例＋价格卡片三段式 Web 发布（2026-11-26，北京时间）

源码基线 **`ffaa1e6`**＋本会话未提交改动。Web 静态 release **`trade-web-20261126-legend-ffaa1e6`** 原子切换到 `/opt/trade-tools-integrated/web/integrated/market`（目标 **47.80.22.243（首尔服务器）**），线上 index/JS/CSS SHA-256 与本地一致（`84fe37d7…`／`d2c56b5d…`／`7ac01688…`，`?cb=` 复核）。① 主/副图网格改低对比 rgba（深 rgba(240,244,250,.045)／浅 rgba(24,26,32,.045)）视觉更细，MACD 零轴保留原对比单独 zero 色；② 两副图左上角 TradingView 式图例 `MACD(12,26,9)`／`StochRSI(14,14,3,3)`，参数随指标设置联动、禁用隐藏；注意 `pane.getHTMLElement()` 返回 tr 不可挂绝对定位子节点，图例挂 pane 画布的 relative 容器（DOM 核对 offset 8/4）；③ 价格卡片改三段：头部币种＋24H、"当前价格"小标、大号价格数字。契约测试锁定。后端不切换，旧 release 保留可回退。视觉待用户线上验收。未执行真实交易/资金操作。

## 切币加载改半透明浅白灰蒙层 Web 发布（2026-11-26，北京时间）

源码基线 **`ffaa1e6`**＋本会话未提交改动。Web 静态 release **`trade-web-20261126-veil-ffaa1e6`** 原子切换到 `/opt/trade-tools-integrated/web/integrated/market`（目标 **47.80.22.243（首尔服务器）**），线上 index/JS/CSS SHA-256 与本地一致（`5d773abc…`／`f75bc303…`／`9490358a…`，`?cb=` 复核）。切币无缓存时不再用不透明底"清空"旧图：`.kline-loading` 改半透明浅白灰 veil（深色 rgba(240,243,247,.1)／浅色 rgba(255,255,255,.6)）＋2px 背景模糊＋.18s 淡入，保留 iOS 竖条动画；旧 K 线/副图数据本就保留到 setData，加载成功蒙层撤下显示新币。有缓存切币仍瞬时直达。契约测试锁定 veil。探针元素双主题核对渲染参数。后端不切换，旧 release 保留可回退。视觉待用户线上验收。未执行真实交易/资金操作。

## 周期选中改绿色短下划线＋自动/手动绿色 Web 发布（2026-11-26，北京时间）

源码基线 **`ffaa1e6`**＋本会话未提交改动。Web 静态 release **`trade-web-20261126-tfline-ffaa1e6`** 原子切换到 `/opt/trade-tools-integrated/web/integrated/market`（目标 **47.80.22.243（首尔服务器）**），线上 index/JS/CSS SHA-256 与本地一致（`95ba6cc9…`／`f75bc303…`／`47b4e907…`，`?cb=` 复核；JS 内容与上轮字节一致仅文件名随 CSS 变）。主导航保留实底胶囊后，周期选中态与其区分：去实底改**绿色短下划线（文字宽、2px、var(--green)）＋文字加粗**，删浅色实底覆盖；自动/手动选中改绿色加粗透明底。契约测试锁定。DOM 核对深浅两主题。后端不切换，旧 release 保留可回退。视觉待用户线上验收。未执行真实交易/资金操作。

## 主导航胶囊分段样式＋顺序调整＋账户去色系开关 Web 发布（2026-11-26，北京时间）

源码基线 **`ffaa1e6`**＋本会话未提交改动。Web 静态 release **`trade-web-20261126-nav-ffaa1e6`** 原子切换到 `/opt/trade-tools-integrated/web/integrated/market`（目标 **47.80.22.243（首尔服务器）**），线上 index/JS/CSS SHA-256 与本地构建一致（`ec348635…`／`f75bc303…`／`15e20287…`，`?cb=` 复核）。主导航改胶囊分段组（面板底＋圆角容器，选中实底绿 chip、14px/600，浅色主题深绿白字，与周期选中态同款），去 01–06 编号，顺序改 行情／信号／引擎／持仓／历史／账户；信号/引擎空态去 MODULE 编号；账户页移除颜色模式行（外层顶栏主题按钮保留）。契约测试锁定顺序／去编号／账户无色系开关。DOM 核对：顺序、无编号、深浅选中对比、账户页无颜色模式且退出登录在。后端不切换，旧 release 保留可回退。视觉待用户线上验收。未执行真实交易/资金操作。

## 撑压线尾部断线根因修复＋价格卡片币种 Web 发布（2026-11-26，北京时间）

源码基线 **`ffaa1e6`**＋本会话未提交修复（`supertrendLine.ts`／`KlineChart.tsx`／`App.tsx`／`styles.css`／`klineChart.test.mjs`）。Web 静态 release **`trade-web-20261126-sttail-ffaa1e6`** 原子切换到 `/opt/trade-tools-integrated/web/integrated/market`（目标 **47.80.22.243（首尔服务器）**），线上 index/JS/CSS SHA-256 与本地构建一致（`941cc1d0…`／`f97e723a…`／`71003771…`，`?cb=` 缓存破坏复核），`/integrated/v1/health` database/migrations/scheduler 全 true。根因：lightweight-charts 自定义系列 update 的 `visibleRange` 是 bars 数组下标，撑压线系列却拿逻辑序号（含头部 9 根空白偏移）做右侧裁剪，尾部最新根被误删；填充带因绘制时直读实时逻辑范围而正常，故"有填充无线"。修复对齐填充带模式：绘制时直读实时逻辑范围＋update 兜底范围下标→逻辑换算；契约测试新增回归断言。本地复现页 9 场景（自动视图／缩放右留白／左拖／tick／新根 rollover／缩容／右拖空白／全量缩放）像素级断言尾部撑压线全部在屏。价格卡片现价前加币种名称、字号 25→27px（clamp 上限 34→36）。含并行会话已提交的 tabs／加载动画（`615e304`），不回滚。后端容器不切换，旧 release 保留可回退。浏览器面板隐藏无法截图，尾部撑压线与卡片视觉待用户线上验收。未执行真实交易/资金操作。

## iOS 加载动画＋持仓/历史/账户标签 Web 发布（2026-11-26，北京时间）

源码 **`615e304`** 已推送。Web 静态 release **`trade-web-20261126-tabs-615e304`** 原子切换到 `/opt/trade-tools-integrated/web/integrated/market`（目标 **47.80.22.243（首尔服务器）**），线上 index/JS/CSS SHA-256 与本地一致（`448d9216…`／`a03b5f74…`／`416cff03…`），`/integrated/v1/health` 200，`nginx -t` 通过并 reload。新增持仓/历史/账户页走既有 `/v1` JWT 接口与 `/api/commands` 幂等命令，后端容器不切换。平仓等写操作仅在你点击确认后执行；本轮验收未执行真实交易/资金操作。

## 按用户 Pine 复原 Supertrend Web 发布（2026-11-26，北京时间）

源码 **`cd83b48`** 已推送。Web 静态 release **`trade-web-20261126-pine-cd83b48`** 原子切换到 `/opt/trade-tools-integrated/web/integrated/market`（目标 **47.80.22.243（首尔服务器）**），线上 index/JS/CSS SHA-256 与本地一致（`34c22b70…`／`0333cd36…`／`fde5bbc9…`），`nginx -t` 通过并 reload。本轮仅前端（撑压线 linebr 平滑折线、hl2 填充锚、末根撑压），后端不切换。未执行真实交易/资金操作。

## 自动视图跨周期科学化＋Supertrend 对齐官方 Web 发布（2026-11-26，北京时间）

源码 **`0601b54`** 已推送。Web 静态 release **`trade-web-20261126-auto-0601b54`** 原子切换到 `/opt/trade-tools-integrated/web/integrated/market`（目标 **47.80.22.243（首尔服务器）**），线上 index/JS/CSS SHA-256 与本地一致（`d9b8ca52…`／`0333cd36…`／`b0ee30cc…`），`nginx -t` 通过并 reload。本轮仅前端（自动视图 bar 间距自适应、可见范围 autoscale、Supertrend 翻转对齐 ta.supertrend），后端不切换。未执行真实交易/资金操作。

## 反转填充／选中态深浅适配／撑压线末尾 Web 发布（2026-11-26，北京时间）

源码 **`1a0ea26`** 已推送。Web 静态 release **`trade-web-20261126-fix2-1a0ea26`** 原子切换到 `/opt/trade-tools-integrated/web/integrated/market`（目标 **47.80.22.243（首尔服务器）**），线上 index/JS/CSS SHA-256 与本地一致（`db63aa6e…`／`0333cd36…`／`aac029c2…`），`nginx -t` 通过并 reload。本轮仅前端呈现，后端不切换。未执行真实交易/资金操作。

## 价格分档／撑压线断开／周期选中态 Web 发布（2026-11-26，北京时间）

源码 **`b9aa796`** 已推送。Web 静态 release **`trade-web-20261126-present-b9aa796`** 原子切换到 `/opt/trade-tools-integrated/web/integrated/market`（目标 **47.80.22.243（首尔服务器）**），线上 index/JS/CSS SHA-256 与本地构建一致（`857652e4…`／`3f76626c…`／`9d4e2df7…`），SPA 深层 200，`/integrated/v1/health` 全 true；`nginx -t` 通过并 reload。本轮仅前端呈现（右轴分档、撑压线自定义系列断开、周期选中实底），后端容器不切换。未执行真实交易/资金操作。

## 超级趋势首屏残影修复 Web 发布（2026-11-26，北京时间）

源码 **`13ffd3c`** 已推送。Web 静态 release **`trade-web-20261126-ghost-13ffd3c`** 已原子切换到 `/opt/trade-tools-integrated/web/integrated/market`，目标 **47.80.22.243（首尔服务器）**；线上 JS SHA-256 `b5a773cf…` 与本地构建一致，页面 200。填充带跳过每段趋势前两根 bar 消除竖直窄带／短 dip 残影，首屏就绪后 rAF 强制重绘。后端不切换，旧 release 保留可回退。浏览器面板隐藏未能截图，待用户线上首屏验收。

## 左拖边缘堆积修复 Web 发布（2026-11-26，北京时间）

源码 **`0d807c7`** 已推送。Web 静态 release **`trade-web-20261126-pan-clip-0d807c7`** 已原子切换到 `/opt/trade-tools-integrated/web/integrated/market`，目标 **47.80.22.243（首尔服务器）**；线上 JS SHA-256 `95f5624a…` 与本地构建一致，页面 200、`/integrated/v1/health` 全 true。自定义系列（MACD 柱／Supertrend 填充带）绘制时直读图表实时可见范围做双侧裁剪，修复左拖时屏外 bar 夹到左缘的堆积色块。后端已由并行会话随切币提速完整同源发布，本轮不重复切换；旧 release 保留可回退。浏览器面板隐藏未能真实拖动截图，待用户线上左拖验收。

## K 线切币提速完整同源发布（2026-11-26，北京时间）

源码 **`5a130d1`** 已推送并完整交付。Web 静态 release **`trade-web-20261126-latency-5a130d1`** 原子切换到 `/opt/trade-tools-integrated/web/integrated/market`（目标 **47.80.22.243（首尔服务器）**），线上 index/JS/CSS SHA-256 与本地构建一致（`78c1a78c…`／`6520c946…`／`33c746d5…`），SPA 深层 200。后端经 `quick_deploy.py` 发布为 **`integrated-quick-5a130d1`**：`load_history` SWR（有本地历史立即返回＋异步 repair）、scheduler `prewarm_major_histories`（60s，置顶+成交量前20）、客户端共享 SWR 缓存/悬停与空闲预取/首屏 300 根。四容器 healthy，MySQL/Redis 未替换，切换前活动命令 0，health database/migrations/scheduler 全 true；`nginx -t` 通过并 reload。`market_stream` 回归 0 失败（仅本地缺 redis 二进制的环境性跳过/错误）。未执行真实开平仓/划转/撤保护。

## MACD 右侧柱与超级趋势末段填充修复 Web 发布（2026-11-26，北京时间）

源码 **`dbb0b28`** 已推送。Web 静态 release **`trade-web-20261126-indicator-fix-dbb0b28`** 已原子切换到 `/opt/trade-tools-integrated/web/integrated/market`，目标 **47.80.22.243（首尔服务器）**；线上 JS SHA-256 `6520c946…` 与本地构建一致，页面 200、`/integrated/v1/health` 全 true。修复自定义系列右侧序号裁剪误删最新 bar（MACD 右侧能量柱缺失、超级趋势末段填充空白），改左侧序号＋右侧像素裁剪。StochRSI 计算与呈现核对无误。一并含并行会话 Web SWR 缓存／悬停预取。**本轮仅 Web，未部署后端**；并行会话的后端在制品（market_stream／scheduler）保留本地未提交，由其会话自行交付。旧 release 保留可回退。

## MACD 增减实心空心与超级趋势同向断开 Web 发布（2026-11-26，北京时间）

源码 **`aab7e57`** 已推送。Web 静态 release **`trade-web-20261126-macd-st-aab7e57`** 已原子切换到 `/opt/trade-tools-integrated/web/integrated/market`，目标 **47.80.22.243（首尔服务器）**；线上 JS SHA-256 `1e95f068…` 与本地构建一致，页面 200、`/integrated/v1/health` 全 true。MACD 柱改按能量柱增减实心/空心；超级趋势填充带仅连接原始序号相邻且同向 bar，两段同向趋势不再被连接。后端容器与 Nginx 不切换，旧 release 保留可回退。浏览器面板隐藏未能截图，待用户线上验收。

## 超级趋势反转断开 Web 发布（2026-11-26，北京时间）

源码 **`0c104d0`** 已推送。Web 静态 release **`trade-web-20261126-st-break-0c104d0`** 已原子切换到 `/opt/trade-tools-integrated/web/integrated/market`，目标 **47.80.22.243（首尔服务器）**；线上 JS SHA-256 `8ebb9c4c…` 与本地构建一致，页面 200、`/integrated/v1/health` 全 true。修复超级趋势填充带在趋势反转处的竖直连接段（反转 bar 留空）。一并含并行会话 MACD 实心空心／左拖堆积／切币提速。后端容器与 Nginx 不切换，旧 release 保留可回退。浏览器面板隐藏未能截图，反转断开待用户线上验收。

## Web K 线顶部周期按钮加大发布（2026-11-26，北京时间）

源码 **`074de4e`** 已推送。仅 Web 静态变更：顶部周期按钮字号 13 px／内边距 8x13 px／圆角 4 px。静态 release **`trade-web-20261126-timeframe-074de4e`** 已原子切换到 `/opt/trade-tools-integrated/web/integrated/market`，目标 **47.80.22.243（首尔服务器）**；线上 CSS SHA-256 `28570ba1…` 与本地构建一致且含 `.timeframe{…padding:8px 13px}`，页面 200、`/integrated/v1/health` 全 true。后端容器与 Nginx 不切换（无后端改动），旧 release 保留可回退。

## Web K 线尾根实时跳动发布（2026-11-26，北京时间）

Web 静态 release **`trade-web-20261126-lwcharts-live-2e7e3be`** 已原子切换到 `/opt/trade-tools-integrated/web/integrated/market`（目标 **47.80.22.243（首尔服务器）**），核心为尾根随 `market.ticker` 报价跳动（`mergeTicker`），并含 Supertrend 填充／断开、指标总设置、70/15/15 自适应、首屏 64 根；线上 index/JS/CSS SHA-256 与本地构建一致（`87221cf4…`／`5174872f…`／`b3e168f7…`），SPA 深层 200，与并行会话 `trade-web-20261126-kline-ux-918eb6c` 字节同源。后端经 `quick_deploy.py` 发布为 **`integrated-quick-e1526b0`**，api／market／worker／scheduler 四容器 healthy，MySQL／Redis 未替换，切换前活动命令 0，health database／migrations／scheduler 全 true；`nginx -t` 通过并 reload。登录后真实账号尾根跳动由用户线上验收；未执行真实开平仓／划转／撤保护。

## 持仓刷新手感／划转上限／开仓超限文案与 Web K 线交互发布（2026-11-26，北京时间）

源码 **`918eb6c5a877a8a612c657f81a832c374ec9dd5c`** 已推送 `codex/integrated-ios` 并完整交付整合工作区（含并行会话的指标设置、Supertrend 填充带、自适应高度与 K 线合并模块）。后端经 `quick_deploy.py` 发布为 **`integrated-quick-918eb6c`**，目标 **47.80.22.243（首尔服务器）**，api／market／worker／scheduler 切换，health database／migrations／scheduler 全 true；本次仅文案与预检 message，无新增 migration，未做数据库备份（快速路径）。Web 静态 release **`trade-web-20261126-kline-ux-918eb6c`** 已原子切换到 `/opt/trade-tools-integrated/web/integrated/market`，线上 `index.html`／JS／CSS SHA-256 与本地构建一致（JS `5174872f…`／CSS `b3e168f7…`），`/integrated/v1/health` 全 true；Nginx location snippet 不变、未 reload。旧 release 保留可回退。同一提交 Xcode Cloud `Archive - iOS`／`Test - iOS` 已触发（交付时 in_progress），TestFlight 分发与手机安装另行核验。iOS 模拟器 XCTest 执行受 CoreSimulator 环境故障阻塞，编译与 build-for-testing 通过；未执行真实交易、划转或保护单操作。

## Web K 线改用 lightweight-charts 自建（2026-11-26，北京时间）

Web K 线区域改为 `lightweight-charts` v5 自绘，替换 TradingView 托管 iframe；产物不再依赖外部 `www.tradingview-widget.com` loader，副图固定 72px、首屏 32 根、切币单次加载。静态 release **`trade-web-20261126-lwcharts-8472ec8`** 已原子切换到 `/opt/trade-tools-integrated/web/integrated/market`，部署目标为 **47.80.22.243（首尔服务器）**；旧 `trade-web-20261126-tv-bar-density-ad2380a` 保留可回退。`nginx -t` 通过并 reload，后端容器与 Nginx 路由不切换（配套后端 `cce9a5d`／`16aca68` 已含在线上 `integrated-20261125-aff69f5`，无已推送未上线后端）。线上 `index.html`／JS／CSS SHA-256 与本地构建一致（`35a18bd2…`／`fb241891…`／`6987e88a…`），SPA 深层路径 200，`/integrated/v1/health` database／migrations／scheduler 全 true；线上登录页首屏渲染正常。实时尾根推送沿用既有 `/ws/v1`（需 ASGI 入口）；登录后真实账号图表由用户验收，未执行真实交易或资金操作。

## Web K 线初始可见数量调整（2026-11-26，北京时间）

Web Component 初始时间范围压缩为原来的约一半，`2d → 1d`、`7d → 3d`、`1M → 15d`、`1y → 6M`，降低初始 K 线密度并保持用户缩放能力。静态 release **`trade-web-20261126-tv-bar-density-<commit>`** 将在本次验证后原子切换到 `/opt/trade-tools-integrated/web/integrated/market`，部署目标为 **47.80.22.243（首尔服务器）**。后端容器和 Nginx 配置不切换。

## Web K 线切币重复加载修复（2026-11-26，北京时间）

切换交易对时复用已挂载的 TradingView Web Component，只更新官方 `symbol` 属性，不再同时重建组件和再次写入交易对。静态 release **`trade-web-20261126-tv-symbol-switch-<commit>`** 将在本次验证后原子切换到 `/opt/trade-tools-integrated/web/integrated/market`，部署目标为 **47.80.22.243（首尔服务器）**。后端容器和 Nginx 配置不切换。

## Web K 线顶部操作与底部空白修复（2026-11-26，北京时间）

移除 K 线内部的自建周期栏，TradingView Web Component 官方周期栏独占图表顶部。重置和盘面速览展开按钮统一放入页面顶部操作容器，Web Component 从 stage 顶部铺满到状态栏上方，取消 legacy iframe 专用底部安全留白。静态 release **`trade-web-20261126-tv-toolbar-layout-<commit>`** 将在本次验证后原子切换到 `/opt/trade-tools-integrated/web/integrated/market`，部署目标为 **47.80.22.243（首尔服务器）**。后端容器和 Nginx 配置不切换。

## Web TradingView Web Component 切换（2026-11-26，北京时间）

当前网络下复测 `tv-advanced-chart` Web Component 已正常加载主图、EMA Ribbon、Supertrend、MACD、StochRSI、官方顶部工具栏、左侧绘图工具栏和右下角设置按钮。Web Component 使用官方 ES module，不再依赖 legacy iframe 的右下角控件兼容行为。静态 release **`trade-web-20261126-tv-web-component-9a1b30a`** 已原子切换到 `/opt/trade-tools-integrated/web/integrated/market`，部署目标为 **47.80.22.243（首尔服务器）**。后端容器和 Nginx 配置未切换。线上资源和 `/integrated/v1/health` 均已复核。

## Web TradingView 官方设置入口恢复（2026-11-26，北京时间）

确认设置入口缺失的根因是整合版把 `hide_top_toolbar` 固定为 `true`，可编辑账号的 TradingView 官方工具栏因此被一并隐藏。现按原 Web 行为恢复可编辑账号的官方工具栏，同时保留自建周期栏、右下角 `main_series_scale_menu` 设置入口和只读游客模式的绘图限制。新增 `header_settings` 与 `show_chart_property_page` 官方 featureset 配置。

静态 release **`trade-web-20261126-tv-settings-9945f7c`** 已原子切换到 `/opt/trade-tools-integrated/web/integrated/market`，部署目标为 **47.80.22.243（首尔服务器）**。后端容器和 Nginx 配置未切换。线上 HTML、JS/CSS、本站 TradingView loader 和 `/integrated/v1/health` 均已复核，资源 SHA-256 与本地构建一致。

## Web TradingView 深浅色主题同步发布（2026-11-26，北京时间）

Web 页面主题现在同时驱动 TradingView 官方 iframe 和外层 K 线工作区。浅色模式使用 Web 的 `#eef0f3` 图表表面色，深色模式使用 `#0c0d0f`，周期栏、iframe 占位区和图表容器共享同一主题表面色。主题切换会按 TradingView 官方 `theme` 参数重新创建图表，主图、MACD、StochRSI、官方设置入口和画线能力保持原有链路。

静态 release **`trade-web-20261126-theme-35f7715`** 已原子切换到 `/opt/trade-tools-integrated/web/integrated/market`，部署目标为 **47.80.22.243（首尔服务器）**。后端容器和 Nginx 配置未切换。线上页面、JS/CSS、本站 TradingView loader 均返回 200，线上资源 SHA-256 与本地构建一致，`/integrated/v1/health` 的 database、migrations、scheduler 均为 true。

## Web TradingView 原生附图与首次加载修复（2026-11-26，北京时间）

本次 Web 静态包将 EMA 21／55／144 聚合到 TradingView MA Ribbon，并预置 Supertrend、MACD 和 StochRSI 原生 studies。针对附图默认缺失，MACD／StochRSI 改为 legacy embed 可稳定解析的对象描述并固定为独立 pane。针对 1D 切换错误，日线配置省略与 `interval: "D"` 冲突的 `range` 参数。图表工作区边界固定在全局状态栏上方，官方设置齿轮和 MACD 底部控件保留 24px 安全区，盘面速览展开入口移动到周期栏最右侧，顶部周期栏文字放大。页面不再覆盖设置入口，主图右下角保留 TradingView 官方设置齿轮，背景使用 Web 暗色画布。首次挂载增加偏好同步门槛，避免 TradingView iframe 在账号设置回填期间被重复卸载而出现“重新连接”弹窗。

静态 release **`trade-web-20261126-chart-controls-282787f`** 已原子切换到 `/opt/trade-tools-integrated/web/integrated/market`，部署目标为 **47.80.22.243（首尔服务器）**。后端容器和 Nginx 配置未切换。线上 HTML、JS/CSS、本站 loader 和 `/integrated/v1/health` 已复核，静态产物哈希与本地构建一致。

## Web TradingView legacy iframe 修复发布（2026-11-26，北京时间）

原始 Web 版本使用 TradingView 官方 legacy Advanced Chart iframe。整合版在最近一次图表恢复中切换到 `widgets.tradingview-widget.com` Web Component，浏览器需要额外加载 module loader 和内部嵌入页，部分网络会在图表内部返回 `Something went wrong`。本次将官方 legacy loader 原样随静态包提供，由本站加载并继续连接 TradingView 官方 iframe，保留自建六周期栏、底部 MACD／StochRSI 和 TradingView 画线能力。后端、行情接口、账号体系和交易逻辑未改。

静态 release **`trade-web-20261126-tv-selfhost`** 已原子切换到 `/opt/trade-tools-integrated/web/integrated/market`，部署目标为 **47.80.22.243（首尔服务器）**。后端容器和 Nginx 配置未切换。公网页面、JS/CSS 资源、本站 loader 和 `/integrated/v1/health` 已复核，浏览器需要允许 TradingView iframe 域名 `www.tradingview-widget.com`。

## Web 图表控件与附图联动发布（2026-11-26，北京时间）

Web 主图继续使用 TradingView；页面顶部周期栏改为自建并提供 `3m / 5m / 15m / 1h / 4h / 1D`，TradingView 自带顶部工具栏隐藏。底部自建 MACD／StochRSI 支持正柱实心绿、负柱空心紫、快线绿、慢线紫及附图总高度拖拽调整；主图 stage 与两个附图共享横向十字线索引。官方 Web Component 不接受 EMA study 的 plot color override，因此本轮保留 TradingView 默认 EMA 配色，不注入自建主图线。静态 release **`trade-web-20261126-chart-controls-safe`** 已原子切换到 `/opt/trade-tools-integrated/web/integrated/market`；后端容器和 Nginx 配置未切换。

## Web TradingView-only K 线修复发布（2026-11-26，北京时间，历史版本）

该版本使用 TradingView Web Component。它已由上方 legacy iframe 修复替代，自建 SVG K 线及其回退逻辑仍已从 Web 源码和静态产物移除。

静态 release **`trade-web-20261126-tv-widget`** 已原子切换到 `/opt/trade-tools-integrated/web/integrated/market`，旧的 `trade-web-20261126-kline-fix` 保留为可回退目录但不再是 active 版本；后端容器和 Nginx 配置未切换。公网 `/integrated/market/`、深层路径、JS/CSS 均返回 200。Chrome 线上验收确认 `BINANCE:XAUTUSDT.P` 的 15m TradingView 蜡烛图、EMA ribbon、Supertrend、画线工具和底部指标条均已显示。

## Web K 线回退修复发布（2026-11-26，北京时间）

（中间版本，已由上方 TradingView-only 发布替代。）线上发现外部 TradingView widget 在部分网络下长期停留在“正在连接”，曾临时发布 `trade-web-20261126-kline-fix` 提供本地 SVG 回退；该回退版本不再作为线上 active 版本。

## Web 与同源后端完整发布（2026-11-26，北京时间）

按用户授权，将当前完整工作区发布到 **47.80.22.243（首尔服务器）**。后端源码提交为 **`aff69f5`**，运行 release 为 `/opt/trade-tools-integrated/releases/integrated-20261125-aff69f5`，`current` 已切换；api、market、worker、scheduler 使用同一镜像 `tradetools-integrated:integrated-20261125-aff69f5`。`web.0001_initial` 已应用，MySQL／Redis 容器和数据卷未替换。

Web 静态产物为 **`trade-web-20261125-aff69f5`**，目录 `/opt/trade-tools-integrated/web/trade-web-20261125-aff69f5`，原子软链 `/opt/trade-tools-integrated/web/integrated/market` 已切换。Nginx 已加入 `/integrated/market/` SPA 路由并通过 `nginx -t`、reload；数据库备份位于 `/opt/trade-tools-integrated/backups/integrated-20261125-aff69f5/database.sql.gz`，权限 600，沿用发布前完成的备份。

线上验收通过：`/integrated/market/`、SPA 深层路径、JS/CSS 资源均返回 200；`/integrated/v1/health` 返回 database／migrations／scheduler 全 true；未认证 `/integrated/api/market/tickers` 返回预期 401；浏览器已打开线上登录页并确认首屏。线上地址为 **https://47.80.22.243/integrated/market/**。没有执行真实开仓、平仓、划转、归集或保护单操作；登录后的真实账号行情／WSS 仍需用户验收。

## 信号提醒数据清理（2026-11-25）

按用户要求，在 **47.80.22.243（首尔服务器）** 暂停 scheduler／worker 后清理旧信号链路：删除 `tradingview_message` 全部 72 条、`market_analysis_signal` 0 条、`strategy.signal` App 通知事件 364 条及其 813 条投递记录（级联删除共 1177 行）。交易开平仓通知、浮盈提醒和保证金提醒未删除；清理前的四张信号相关表备份位于服务器受限目录 `/opt/trade-tools-integrated/backups/signal-cleanup-20261125/signal-tables.sql.gz`，权限 600 且 gzip 校验通过。

清理后复核信号消息、分析信号、`strategy.signal` 事件和投递均为 0；api、market、worker、scheduler、MySQL、Redis 恢复 healthy，`/integrated/v1/health` 返回 database／migrations／scheduler 全 true。旧趋势扫描代码仍保留，后续构建新信号系统时应替换其扫描与入库链路。

同一工作区的止损前移修复、持仓保证金／杠杆字段及测试配套随后以 **`integrated-quick-6156709`** 发布到 **47.80.22.243（首尔服务器）**；四个应用容器使用同一镜像，MySQL／Redis 未替换，活动命令门禁为 0，公网 health 的 database／migrations／scheduler 均为 true。Nginx 路由内容未改，仅清理了线上模板末尾多余空行，改前快照位于 `/opt/trade-tools-integrated/backups/nginx-template-newline-20251125/`。

## 合约余额上限 3000 USDT 完整发布（2026-11-22）

北京时间 **09:48:05**，完整源码 **`1c1b0d641508a346e9991be5d028612b608c94bf`** 已发布到 **47.80.22.243（首尔服务器）**；`current` 指向 `/opt/trade-tools-integrated/releases/integrated-20261122-full-1c1b0d6`。api／market／worker／scheduler 共用该版本镜像，四个运行容器实际读取的 `FUTURES_RETENTION_CAP` 均为 **3000**。现有客户端重新读取资金预检即可采用新上限与补足目标；iOS 说明调整仍需后续客户端新包，本轮没有上传 TestFlight。

- 完整归档 363 个文件，SHA-256 `8a24bd138f724df4d369e8bdfb439bed304550e694bd54172764b49a37ade60f`；四个应用服务各 347 个 Python／requirements 文件与归档全部一致。
- 一致性数据库 gzip 备份 **416841393 bytes**，完整解压及 SHA-256 校验通过；备份、原镜像和 `rollback.sh` 保留在 `/opt/trade-tools-integrated/backups/integrated-20261122-full-1c1b0d6/`。备份目录 0700、文件 0600，无新增迁移，仅执行迁移检查。
- 本地禁外网 SQLite／LocMem 完整 `accounts trading positions mobile` **889 项通过**；新镜像在独立 MySQL／Redis、内部无外网测试网络中 **249 项通过**，未使用生产数据库、凭证或数据卷。
- 切换前后本地数据库活动仓位、待成交限价和 PENDING／RUNNING／UNKNOWN 命令均为 0。六个容器 healthy；MySQL／Redis 容器 ID、镜像及数据卷保持原样，运行环境和含 `/calc/` 的 Nginx 配置哈希无变化。
- 公网 health 连续三次 database／migrations／scheduler 全 true；`/plan/` 和 `/calc/` 均返回 200。13 个行情周期、192 个历史缓存窗口及既有通知开关保留。本轮没有人工开平仓、划转、撤保护或数据库清理。

证据位于忽略目录 `.integration-runtime/CapitalCap3000Nov22/`。全部工作区改动已本地提交，未推送 GitHub；独立 macOS 项目不在本次源码或部署范围内。

## 房贷税费计算器已下线（2026-11-23）

- 应用户要求，房贷税费计算器（2026-11-19 部署的 `/calc/` 静态页与共享状态同步服务）已全部下线：服务器端删除 `tradetools-calc-sync` systemd 单元与 `/opt/trade-tools-calc/`、备份目录 `/opt/trade-tools-integrated/backups/calc-deploy-20261119/`，Nginx snippet 摘除 `/calc/` 两段后 `nginx -t` 通过并 reload；公网验证 `/calc/` 返回 404，`/plan/` 与 `/integrated/v1/health` 回归 200，交易容器与 8791 端口无残留。
- 摘除前 snippet 快照保留在服务器 `/root/snippet-before-calc-removal.conf`；本地项目目录 `~/work/房贷税费计算器/` 已移入用户废纸篓。此前文档中任何 `/calc/` 记录均为 2026-11-23 之前的历史状态。

## 日常快速服务端发布（默认推荐）

日常只改 Python 服务端时，使用仓库内的快速发布入口：

```bash
cd /Users/apple/work/TradeTools-Binance-iOS
python3 deploy/integrated/quick_deploy.py
```

它只上传当前已提交源码，构建新的共享应用镜像，并切换 `api`、`market`、`worker`、`scheduler` 四个容器。流程会保留发布锁、当前容器健康、活动命令／持仓只读门禁、`migrate --check`、MySQL／Redis 容器不替换、四服务健康检查和一次 HTTPS health；不会执行数据库备份、隔离 MySQL／Redis 回归、`migrate`、`bootstrap_mobile`、生产数据清理或自动重发交易命令。构建会优先使用旧应用镜像作为 Docker cache，已经存在同名镜像时直接复用。

快速流程失败时只恢复旧的四个应用容器，不恢复数据库。旧 release 和旧镜像会保留，便于代码回退；没有数据库备份，因此不适合新增或修改 migration、交易生命周期、资金划转、保护单和数据库结构。此类变更改用既有完整发布流程，执行数据库备份和隔离回归：快速部署是速度优先的日常路径，完整发布是重大变更路径。

先查看将要发布的归档而不连接服务器：

```bash
python3 deploy/integrated/quick_deploy.py --dry-run
```

脚本要求工作区干净且改动已经提交，目标默认是 **47.80.22.243（首尔服务器）**。该入口不使用 `deploy/integrated/release.sh`，后者属于首次初始化流程，会启动 MySQL／Redis、执行迁移和 bootstrap。

Web 静态产物不由 `quick_deploy.py` 构建或上传。发布 Web 时先在本地 `frontend/trade-web/` 执行 `npm ci && npm run build`，将 `dist/` 上传到 `/opt/trade-tools-integrated/web/trade-web-<release>/`，再原子切换 `/opt/trade-tools-integrated/web/integrated/market`，最后安装同一 release 的 Nginx snippet、执行 `nginx -t` 和 reload；静态目录与后端 release 分开保留，便于独立回退。

## 完整同源发布：固定资金、Maker 拒单与客户端恢复（2026-11-14）

北京时间 **19:56:33**，源码 **`31f0625c802797abc3f89661f5959e4c86eb203f`** 已完整部署到 **47.80.22.243（首尔服务器）**，`current` 指向 `/opt/trade-tools-integrated/releases/integrated-20261114-full-31f0625`。api、market、worker、scheduler 统一使用 `tradetools-integrated:integrated-20261114-full-31f0625`，包含前版 `f542783` 的全部保护／平仓清理和本批固定资金规则、Maker 明确拒单重报价后端。

- 完整归档 **361 文件**，SHA-256 `8b5dccff6d363b7deb3dc2d8619d2c619fd42917dba774d51db65d659f4e27ea`；四个 Python 进程各 **347 个运行 Python／requirements 文件**全部与归档匹配。MySQL／Redis 容器、镜像与数据卷保留，运行配置、受限环境文件和 nginx 无变化。
- 一致性数据库 gzip 备份 **406594135 bytes**，完整解压和 SHA-256 校验通过，位于 `/opt/trade-tools-integrated/backups/integrated-20261114-full-31f0625/`；目录 0700、文件 0600，保留前版与兼容回滚脚本。migration 计划为空，只检查，无数据清理或账号初始化。
- 本地后端 **887 项**、iOS 受影响单测最终 **67／67**、实际 UI **9 个独立用例**、实际网络源码传输 **13 项**及最后静默 WSS＋GET 联动定向 **1 项**、鸿蒙 **122／122**通过。新镜像在独立 MySQL／Redis、无生产环境／卷、无外网的环境中 **223 项通过**。
- 切换前后活动持仓、待成交限价和 PENDING／RUNNING／UNKNOWN 命令均为 0。切换后六容器 healthy，公网 HTTPS health 连续三次 database／migrations／scheduler 全 true；只读核对 13 周期、192 个历史窗口和既有通知开关保留。未人工开平仓、划转、撤保护或修改交易数据库。

客户端完整源码已同步推送；同一提交的 Xcode Cloud Test／Archive 均成功，详见 [TestFlight](testflight.md#固定资金开仓反馈与网络恢复2026-11-14)。尚未确认准确构建号、TestFlight 处理／组内分发及手机安装；原有 App 不因后端部署获得居中、刷新和重连改动。旧百分比止损设置请求明确提示更新客户端，旧配置与已有保护保留。实际手机闪烁未完整复现，电梯弱网恢复仍需新包验收。发布证据在本机忽略目录 `.integration-runtime/FixedRulesRecoveryReleaseNov14/`。

## 完整同源发布：平仓清理与手动仓保护（2026-11-14）

北京时间 **18:16:17**，源码 **`f542783f2f120b8a063a91e7bf19f6f9753dec0e`** 已完整部署到 **47.80.22.243（首尔服务器）**，`current` 指向 `/opt/trade-tools-integrated/releases/integrated-20261114-full-f542783`。包含此前尚未上线的 `e2b9ddc` 手动仓保护／Maker 追单后端及本次平仓清理修复；api、market、worker、scheduler 统一使用 `tradetools-integrated:integrated-20261114-full-f542783`。

- 归档 **359 文件**，SHA-256 `fffbd62d03cf042b870c33104d37ee536a936aec13fef020377f44984605787b`；四个 Python 进程各 **345 个运行 Python／requirements 文件**与归档完全一致。运行配置无变化，MySQL／Redis 容器 ID、镜像与数据卷保留，环境文件和 nginx 未改变。
- 一致性数据库 gzip 备份 **406789688 bytes**，完整解压与 SHA-256 校验通过，位于 `/opt/trade-tools-integrated/backups/integrated-20261114-full-f542783/`（目录 0700、备份 0600）；保留旧版 `integrated-20261114-full-6e3f452` 和兼容回滚脚本。本次 migration 计划为空，只执行检查，没有初始化账号或清理数据库。
- 本地完整 `trading positions mobile` **776 项通过**；新镜像在一次性 MySQL／Redis、无生产环境／数据卷、无外部网络下 **101 项通过**。正式切换前停止旧 worker／scheduler；切换后六容器 healthy，HTTPS health 连续三次 database／migrations／scheduler 全 true。
- 发布准备时原 ZEC 多仓已由既有系统于 **18:11:29** 确认关闭并清理保护；18:16 切换前后，本地活动仓位、待成交限价及 PENDING／RUNNING／UNKNOWN 命令均为 0。只读核对该绑定账户无 ZEC 持仓、活动条件单或普通挂单。本轮没有人工开平仓、划转、撤保护或改写订单，系统原有自动保护正常运行。

后端已上线；Maker 持续监控弹窗及委托卡按钮仍需新版 iOS 客户端，不能把本次服务器部署记作 TestFlight 上传或手机安装。证据保存在本机忽略目录 `.integration-runtime/ClosedCleanupReleaseNov14/`。

<a id="20261114手动仓保护与maker追单"></a>

## 手动仓保护与 Maker 追单（后端已部署，客户端待发布）

本轮代码已在隔离数据库和交易所替身中完成后端保护、Maker fallback 与委托卡回归，并通过完整后端及两个 iOS generic simulator build-for-testing。定向后端共 **97 项通过**，当批完整 `trading positions mobile` 共 **772 项通过、0 失败**。后端现随 `f542783` 完整发布到 **47.80.22.243（首尔服务器）**，发布与新一轮 776／101 项验证见上方记录；客户端仍需独立打包与安装。

<a id="止损自动平仓恢复部署20261114"></a>

## 止损自动平仓恢复部署（2026-11-14）

源码提交 **`6e3f452780977c3bdc28f28e59f304a5250be422`** 已推送 `codex/integrated-ios`，完整后端归档 **`integrated-20261114-full-6e3f452`** 已发布到 **47.80.22.243（首尔服务器）** 的 `/opt/trade-tools-integrated/releases/integrated-20261114-full-6e3f452`，`current` 已切换。发布前数据库 gzip 备份 **407082977 bytes**，位于 `/opt/trade-tools-integrated/backups/integrated-20261114-full-6e3f452/`。

发布前已核对活动持仓、待成交委托及 PENDING／RUNNING／UNKNOWN 命令均为 0，运行配置与前版一致且无待迁移项。切换后 api、market、worker、scheduler、MySQL、Redis 六个容器均 healthy，运行 Python／requirements 文件哈希与归档一致，公网 `/integrated/v1/health` 返回 database、migrations、scheduler 全部 true。未执行真实开仓、撤单、止损、平仓或资金操作。

该版本同时包含实际的 bug 6 修复 **`2cdd280`**：策略止盈预挂失败保持运行，由 10 秒策略引擎重试并写入策略日志。用户提供的 **`7cad9a5`** 实际是系统主动平仓变更，已被 **`6e3f452`** 回滚，与 bug 6 无关；不能用它单独判断策略修复是否上线。

<a id="手动仓保护可靠性加固20261113"></a>

## 手动仓保护链路可靠性加固（2026-11-13，已部署）

按用户"提交并部署"授权，完整整合工作区先后以 **`3f46db4`**（服务端开仓请求收敛、纳管方向隔离、有界保护核对、Echobell 缺口告警）与 **`dd072dd`**（接管前核对持仓仍存在，杜绝幻影仓）发布到 **47.80.22.243（首尔服务器）**，`current` 指向 `/opt/trade-tools-integrated/releases/integrated-20261113-full-dd072dd`，api／market／worker／scheduler 统一镜像 `tradetools-integrated:integrated-20261113-full-dd072dd`，MySQL／Redis 镜像与数据卷不变。发布包含其他会话已提交未上线的 `ae6c8b4`／`3001ad2`；交易计划静态页 v11 已由前序会话切换，三文件 md5 与本次 HEAD 完全一致，未重复发布。

- 第一版归档 SHA-256 `21d5b276d75eab35a8817401a9018322b7fac9016c636fe11ed8373fe97094e9`，**357 个**后端／部署文件逐项匹配；发布前数据库 gzip 备份 **423189316 bytes**，SHA-256 `d02a8834fa6e560b0650db43a2b5914a6425743c27cf2b80579e9a090c58dc13`，位于 `backups/integrated-20261113-full-3f46db4/`。北京时间 22:26 切换，六容器 healthy、公网健康 ×3 全 true、运行文件哈希匹配、`migrate --check` 通过。
- 第二版归档 SHA-256 `205ede1356ebd57b955c4c7d963e3ca005c17e0de86976d6e1798acbd8c99a3a`，357 文件逐项匹配；数据库 gzip 备份 **423218145 bytes**，SHA-256 `60f09c32e79a4091af3a5e28cc94a6cdd5612134be1987a0f20ee08d22833634`，位于 `backups/integrated-20261113-full-dd072dd/`。北京时间 22:54 切换，六容器 healthy、公网健康 ×3 全 true、api 容器 344 个运行 Python／requirements 哈希匹配、`migrate --check` 通过（本次无新增 migration）。
- 线上只读验收：新任务"开仓请求服务端收敛"每 30 秒运行；卡住的请求 13／14 在首版部署后约 1 分钟内被自动核对并关联本地订单 23／24，无需用户打开页面。订单 23（历史成交、仓位已平）30 秒内自动收敛关闭；订单 24 因首版缺少持仓存在性核对成为幻影仓，第二版已根因杜绝新增；24 的幻影止损已不在交易所活动条件单中，真实持仓订单 22 的止损 `4000002119913908`（SELL LONG 5.115 @ 1929.26）只读核实仍在。幻影订单 24 的本地关闭需单独授权，见变更记录。
- 隔离回归（前一版已部署代码）：定向 **79 项**、完整 `trading positions mobile` **762 项**通过；未执行真实开仓、撤单、止损、平仓、划转或保护单操作（系统自身保护逻辑按既有规则运行）。本机证据在忽略目录 `.integration-runtime/ProtectionReliabilityNov13/`。后续边界修复另见上方“手动仓保护与 Maker 追单”，已随 `f542783` 完整发布。

<a id="交易经验页头精简20261113"></a>

## 交易经验页头精简（2026-11-13）

交易计划静态页切换到 **47.80.22.243（首尔服务器）** 的 `/opt/trade-tools-integrated/web/trade-plan-20261113-v11`（`plan` 软链原子切换，v10 保留可回退），未重启整合容器。经验页移除大标题区块（kicker／大标题／副标题／独立计数行），条数与「记录经验」按钮移入顶部标题行右侧，下方仅显示经验横条。线上浏览器验证：顶栏计数随创建／删除实时更新、弹窗与两步删除正常、无控制台错误；临时验证账号已删除。本机到该 IP 直连间歇超时，本轮经系统 HTTPS CONNECT 代理（127.0.0.1:7897）完成 SSH 与接口验证。

<a id="交易计划账号制发布20261113"></a>

## 交易计划账号制发布（2026-11-13）

本地提交 **`dee9cae`**（未推送 GitHub）完整同源发布到 **47.80.22.243（首尔服务器）** 的 `/opt/trade-tools-integrated/releases/integrated-20261113-accounts-dee9cae`，`current` 已切换；`plans.0001_initial` migration 已应用（新增 `trading_plan` 表）。交易计划静态页最终切换到 `/opt/trade-tools-integrated/web/trade-plan-20261113-v10`（v9 为中间版，v8/v7 保留可回退）。

网站改为账号制：独立登录／注册页（整合平台 `/v1/auth/login`、`/v1/auth/register`，登录与注册均按平台契约携带 `agreed` 字段），未登录只能看到登录页；登录后计划与经验按账号云端保存。新增 `plans` Django 应用提供用户隔离的计划 CRUD（`/integrated/v1/plan/...`），经验沿用 `experiences` 接口；图片校验抽到 `common/images.py` 共享。前端计划支持状态切换、两步确认删除，经验支持编辑与删除；首次登录时若账号为空且存在旧 localStorage 记录，会一次性迁移到账号。

线上浏览器端到端验收（临时账号，验收后已删除账号与 OSS 测试对象）：注册→自动登录→新建计划带图（浏览器直传 OSS 200）→状态切换与筛选→经验创建／编辑／两步删除→计划两步删除→退出登录→重新登录数据持久化，全部通过；窄屏（≤820px）布局与登录页交互通过、无控制台错误。桌面宽屏视口受浏览器连接器限制未能实截，桌面布局以 CSS 审查为准。本轮无交易、资金或保护单操作。

<a id="交易经验横条与oss真实上传启用20261113"></a>

## 交易经验横条布局与 OSS 真实上传启用（2026-11-13）

本地提交 **`34f7797`**（未推送 GitHub，用户未下推送指令）完整同源发布到 **47.80.22.243（首尔服务器）** 的 `/opt/trade-tools-integrated/releases/integrated-20261113-ossfix-34f7797`，`current` 已切换；api／market／worker／scheduler 使用同一新镜像，MySQL／Redis 未重建。交易计划静态页切换到 `/opt/trade-tools-integrated/web/trade-plan-20261113-v8`（`plan` 软链原子切换，保留 v7 可回退），线上三文件 md5 与本地一致。本轮无新增 migration，`migrate` 为空操作，未单独做数据库备份；没有执行交易、资金、撤保护或订单改写。

阿里云 OSS 在用户浏览器授权的新账号（AccountId `34067878`，本机 aliyun CLI 独立 profile `trade-plan`，与旧 `codex-cdn` 配置隔离）下完成配置并启用：

- Bucket `tradetools-plan-images`（oss-cn-hangzhou，public-read，已关闭 Bucket 级 BlockPublicAccess；对象 key 为随机 UUID 不可枚举）。
- RAM 子账号 `trade-plan-oss`，自定义策略 `TradePlanOssUpload` 仅允许 `oss:PutObject`／`oss:GetObject` 于 `tradetools-plan-images/trade-plan/*`；独立 ossutil 实测越权列其他 Bucket 返回 403、授权上传成功。
- Bucket CORS 允许来源 `https://47.80.22.243` 的 `PUT`／`GET`／`HEAD`，`content-type` 与 `x-oss-*` 请求头，暴露 ETag。
- 9 个 `OSS_*` 变量写入受限 `/opt/trade-tools-integrated/server.env`（0600），密钥未进入 Git、前端、文档或日志；本机临时凭证文件已删除。

同时修复 `server/experiences/oss.py` 的 OSS V1 签名 bug：StringToSign 在 CanonicalizedResource 前多一个空行导致所有直传 `SignatureDoesNotMatch`；新增签名格式回归测试，`experiences` 隔离测试 6 项通过。计划页新增轻量登录（`/integrated/v1/auth/login` + HttpOnly refresh cookie 续期），登录后图片直传 OSS，未登录继续 Data URL 本地回退；交易经验列表由横向滚动卡片改为整行横条。

端到端验证（API 容器内临时验证账号，验证后已删除账号与测试对象）：`upload-url` 200 → 浏览器式 PUT 200 → 公共读 GET 200 且字节一致。公网 `/integrated/v1/health` database／migrations／scheduler 全 true，六容器 healthy，线上页面横条与登录弹窗交互通过、无控制台错误。真实用户账号的页面登录上传由用户自行验收；OSS 长期容量、CDN 与私有读策略不在本轮范围。

<a id="交易经验与oss图片上传发布20261113"></a>

## 交易经验与 OSS 图片上传发布（2026-11-13）

提交 **`0ab6f9f`** 已推送到 GitHub `codex/integrated-ios`，完整后端发布到 **47.80.22.243（首尔服务器）** 的 `/opt/trade-tools-integrated/releases/integrated-20261113-full-0ab6f9f`，`current` 已切换到该目录；交易计划静态页切换到 `/opt/trade-tools-integrated/web/trade-plan-20261113-v7`，访问地址为 `https://47.80.22.243/plan/`。发布前数据库 gzip 备份为 **423404704 bytes**，位于 `/opt/trade-tools-integrated/backups/integrated-20261113-full-0ab6f9f/`；没有执行交易、资金、撤保护或订单改写。

新版本新增独立 `experiences` Django 应用和 `experiences.0001_initial` migration，经验接口与 OSS 上传签名接口随 API 发布；六个整合容器均 healthy，公网 `/integrated/v1/health` 返回 database、migrations、scheduler 全部 true，计划页 HTTP 200 且包含“交易经验”、经验弹窗和图片输入标记，线上 `app.js`／`styles.css` SHA-256 与本地提交一致。未认证调用 `/integrated/v1/experience/upload-url` 返回 401，符合鉴权边界。

阿里云 OSS 的代码链路已经部署，但服务器 `/opt/trade-tools-integrated/server.env` 当前没有 `OSS_*` 变量，因此真实上传保持关闭，网页使用本地 Data URL 回退。启用时只需在该受限环境文件填写 `OSS_ENDPOINT`、`OSS_BUCKET`、`OSS_REGION`、`OSS_ACCESS_KEY_ID`、`OSS_ACCESS_KEY_SECRET` 和可选 `OSS_PUBLIC_BASE_URL`，并设置 `OSS_KEY_PREFIX`、`OSS_SIGNED_URL_TTL`、`OSS_MAX_IMAGE_BYTES`；RAM 子账号只授予目标 Bucket 的对象写入／读取权限，Bucket CORS 允许计划页来源的 `PUT`／`GET`／`HEAD` 和 `Content-Type`。修改环境文件后按完整发布流程重启 API／worker／scheduler 并复验，不把凭证写入 Git、前端或日志。

<a id="交易计划网站筛选器分组部署20261113"></a>

## 交易计划网站筛选器分组部署（2026-11-13）

2026-11-13 08:05（北京时间）将交易计划网站更新到 **47.80.22.243（首尔服务器）** 的 `/opt/trade-tools-integrated/web/trade-plan-20261113-v6`。方向、状态、周期三个筛选类型分别放入独立选择器容器，搜索单独成框，筛选逻辑保持不变。线上页面、Nginx 和整合 API 健康检查通过，未重启整合容器。

<a id="交易计划网站顶部统计布局部署20261113"></a>

## 交易计划网站顶部统计布局部署（2026-11-13）

2026-11-13 07:51（北京时间）将交易计划网站更新到 **47.80.22.243（首尔服务器）** 的 `/opt/trade-tools-integrated/web/trade-plan-20261113-v5`。计划记录页移除重复的大标题和下方统计卡，将全部／未做／已做统计与“新建计划”放到顶部“计划记录”标题同一行；新建计划页同步移除大号标题，仅保留顶部页签标题和表单内容。线上页面、Nginx 和整合 API 健康检查通过，未重启整合容器。

<a id="交易计划网站苹方字体部署20261113"></a>

## 交易计划网站苹方字体部署（2026-11-13）

2026-11-13 07:27（北京时间）将交易计划网站更新到 **47.80.22.243（首尔服务器）** 的 `/opt/trade-tools-integrated/web/trade-plan-20261113-v4`。前端字体统一使用系统苹方字体栈，移除 Google Fonts、DM Mono 和 Manrope，页面不再依赖外部字体下载。`nginx -t`、公网页面检查和整合 API 健康检查通过，database、migrations、scheduler 均为 true，未重启整合容器。

<a id="交易计划网站页签版部署20261113"></a>

## 交易计划网站页签版部署（2026-11-13）

2026-11-13 07:23（北京时间）将交易计划网站更新到 **47.80.22.243（首尔服务器）** 的 `/opt/trade-tools-integrated/web/trade-plan-20261113-v3`，`/plan/` 已原子切换。页面改为左侧“计划记录／新建计划”两个页签，右侧显示当前内容；新建计划使用表单＋计划摘要布局，不再使用覆盖层。移除总览、风险检查、预览状态、流程说明和页脚等非操作文案，放大导航、表格、筛选、表单和按钮字号，保留白底黑色装饰。数据仍只保存在当前浏览器内存，没有后端逻辑。

本地 `node --check frontend/trade-plan-web/app.js`、`git diff --check` 通过；浏览器验证页签切换、保存回到记录页并插入新记录、移动端／桌面端可读性和控制台错误。线上 `/plan/` 返回 200，页面含计划摘要和新建计划且不含风险检查；`nginx -t` 通过，整合 API 健康检查为 `ok`，database、migrations、scheduler 均为 true，未重启六个整合容器。

<a id="交易计划网站列表版部署20261113"></a>

## 交易计划网站列表版部署（2026-11-13）

2026-11-13 07:02（北京时间）将交易计划网站前端更新到 **47.80.22.243（首尔服务器）** 的 `/opt/trade-tools-integrated/web/trade-plan-20261113-v2`，`/plan/` 已原子切换到该目录。新版以计划记录列表为核心，移除风险检查，增加方向（多／空）、状态（已做／未做）、周期（3 分钟／15 分钟／1 小时／4 小时／1 天）和文本搜索筛选；新建计划使用全屏编辑页，保存只更新当前浏览器内存中的演示列表，不调用后端、数据库或交易接口。颜色改为白底和黑色装饰，移动端保持可用。

本地 `node --check frontend/trade-plan-web/app.js`、`git diff --check` 通过；浏览器回归覆盖首屏、组合筛选、搜索、全屏新建、保存回写和控制台错误检查。线上页面刷新后显示新版列表，公开 `/plan/` 内容检查通过，`nginx -t` 通过；整合 API `/integrated/v1/health` 返回 `status=ok`，database、migrations、scheduler 均为 true，六个整合容器保持 healthy，未重启交易服务。

<a id="首尔服务器清理与交易计划网站评估20261113"></a>

## 首尔服务器清理与交易计划网站评估（2026-11-13）

在 **47.80.22.243（首尔服务器）** 只读盘点到宿主为 2 CPU、约 3.4 GiB 可用内存、40 GiB 根分区。清理前约 18 GiB 已用、21 GiB 可用；保留当前 `integrated-20261113-full-c6577ac` 和前两版完整回滚备份 `integrated-20261112-full-3a25bcd`、`integrated-20261112-full-5bedd7c4`，删除更早的完整发布备份／发布目录和已消费的 incoming 暂存；无副本同步后清理旧 MySQL binlog，仅保留当前 `binlog.000021`；Docker 构建缓存、无标签镜像和 systemd journal 一并清理。清理后约 13 GiB 已用、25 GiB 可用，journal 约 33 MiB，六个整合容器仍 healthy，公网 `/integrated/v1/health` 的 database、migrations、scheduler 均为 true。没有停止容器、重启服务、修改业务表或执行交易／资金／保护单操作。

短时资源采样显示当前瓶颈在行情历史维护而非磁盘容量：MySQL `market_stream_marketcandle` 约 3.8 GiB，持续采样出现约 67 MB/s 读取和 39–42% I/O wait；`market` 容器会出现接近 2 个 CPU 的峰值。现有 `prune_history()` 按 `interval + open_time` 过滤却按自增 `id` 排序，缺少适合清理的组合索引，生产查询曾持续执行十几秒。后续应在源码中增加版本化 migration／合适的批量删除路径，先用隔离 MySQL 回归和执行计划验证，再部署；MySQL 当前 128 MiB buffer pool 也是候选调优项，但本轮没有直接改配置或重启。

交易计划网站已按上述低资源边界部署为静态前端预览：版本目录为 `/opt/trade-tools-integrated/web/trade-plan-20261113-v1`，Nginx 路由为 `/plan/`，访问地址为 `https://47.80.22.243/plan/`。页面包含总览、风险摘要、进行中计划、计划流程、筛选记录和新建计划弹窗；保存动作只写当前浏览器内存，刷新后恢复演示数据，没有后端请求、数据库写入或交易命令。部署前备份了 Nginx 片段，`nginx -t`、reload、页面 200、页面标记和整合 API 健康检查均通过；六个整合容器未重启。若使用独立域名，需要另配 DNS、证书和 server block。后续先处理行情表清理查询，再按确认后的界面增加计划模型／migration 和用户隔离索引。

<a id="完整同源发布20261113-unknown开仓收敛"></a>

## 完整同源发布（2026-11-13，UNKNOWN 开仓命令收敛）

提交 **`c6577ac20f91ff0ebbb7d4f72607b0332c33b9e8`** 已推送至 GitHub `codex/integrated-ios`，并部署到 **47.80.22.243（首尔服务器）**。发布目录为 `/opt/trade-tools-integrated/releases/integrated-20261113-full-c6577ac`，API／market／worker／scheduler 使用统一镜像 `tradetools-integrated:integrated-20261113-full-c6577ac`；运行源码清单 320 个文件逐项匹配，MySQL／Redis 镜像和运行配置保持不变。

发布前数据库 gzip 备份 **403544009 bytes**，SHA-256 为 `40d1457e2f318c766d1471f50ab97f7a5d8848f2194ec0cd9dee327224fa1bdf`，位于 `/opt/trade-tools-integrated/backups/integrated-20261113-full-c6577ac/`。已应用唯一新增 migration `trading.0017_alter_tradeopenrequest_status`；没有恢复数据库、反迁移或重放交易命令。

切换后六个容器均 healthy，公网 `/integrated/v1/health` 返回 database、migrations、scheduler 全部 true，`current` 已指向新 release。切换前 `UNKNOWN=1`、PENDING／RUNNING 为 0；Worker 只读查询 Binance 原订单号后，旧命令进入 `SUCCEEDED`，`TradeOpenRequest` 进入 `completed`，全局 `UNKNOWN=0`。对应订单为 `ETHUSDT`，成交数量 `0.706`、成交均价 `2051.56000`；本次没有发送真实开仓、撤单、止损、平仓或资金请求。备份目录保留回滚脚本，回滚只恢复应用镜像，不恢复数据库或反迁移。

<a id="完整同源发布20261112-手动仓历史结算"></a>

## 完整同源发布（2026-11-12，手动仓历史结算与交易链路收敛）

提交 **`3a25bcd`** 已推送至 GitHub `codex/integrated-ios`，并部署到 **47.80.22.243（首尔服务器）**。发布目录为 `/opt/trade-tools-integrated/releases/integrated-20261112-full-3a25bcd`，API／market／worker／scheduler 统一使用镜像 `tradetools-integrated:integrated-20261112-full-3a25bcd`。源码归档 SHA-256 为 `bdb52d4c36bd9a1c99dc0e71d08aabbb0842cbd1600bdcbf80ad27bcfc2ead84`。

发布前数据库 gzip 备份为 **421644376 bytes**，SHA-256 为 `ef4ca92e60f25d1aad8e4263b52edb2a15d9fdf65d71cf11fd02b8f3e0937345`，位于 `/opt/trade-tools-integrated/backups/integrated-20261112-full-3a25bcd/`；前版为 `integrated-20261112-full-5bedd7c4`。迁移检查及正式迁移均显示无待应用项，MySQL／Redis 数据卷保持原样。

切换后 `current` 已指向新 release，六个容器均 healthy，公网 `/integrated/v1/health` 返回 database、migrations、scheduler 全部 true；根分区约 **22 GB 可用／43% 使用率**。线上只做健康、迁移、容器和磁盘只读验收，没有执行真实开仓、撤单、止损、平仓、划转或保护单操作。iOS 源码已随提交推送；后端部署不等同于 TestFlight 上传或实机安装。

<a id="完整同源发布20261112-失败弹窗与-maker修复"></a>

## 完整同源发布（2026-11-12，失败弹窗与 Maker 开仓收敛）

完整工作区提交 **`5bedd7c4c54817cc34a1ca3aa44efcac49deb722`** 已推送至 GitHub `codex/integrated-ios`，并发布到 **47.80.22.243（首尔服务器）**。发布目录为 `/opt/trade-tools-integrated/releases/integrated-20261112-full-5bedd7c4`，API／market／worker／scheduler 使用镜像 `tradetools-integrated:integrated-20261112-full-5bedd7c4`；源码归档 SHA-256 为 `e91729d8c867d6688fe7c2f23ba6ca57b89653c092cb49738bc824876c4dfa1e`，前一版本为 `integrated-20261112-full-736a095`。

发布前完成数据库 gzip 备份并保存至该版本 backup 目录；没有待应用 migration。切换后 `current` 已指向新 release，公网 `/integrated/v1/health` 返回 database、migrations、scheduler 全部 true，API／market／worker／scheduler／MySQL／Redis 六个容器均 healthy。切换后根分区约 **23 GB 可用／41% 使用率**，上传归档已删除；线上只做健康、迁移、容器和磁盘只读验收，没有执行真实开仓、撤单、止损、平仓、资金或保护单操作。iOS 提交不等同于 TestFlight 上传或实机安装。

<a id="完整同源发布20261112-图表前台止盈修复"></a>

## 完整同源发布（2026-11-12，图表标记、前台连接与止盈标签修复）

提交 **`736a095d66db2c543604de400f5b3c0d74dc75e8`** 已推送至 GitHub `codex/integrated-ios`，并按用户授权将包含配套后端的完整同源版本发布到 **47.80.22.243（首尔服务器）**。发布目录为 `/opt/trade-tools-integrated/releases/integrated-20261112-full-736a095`，API／market／worker／scheduler 统一使用镜像 `tradetools-integrated:integrated-20261112-full-736a095`；归档包含 **333 个**后端／部署文件，归档 SHA-256 为 `cacdfb91c24631cd6fb0bc182ef9589d7de7da9edc978cc7a30795a33d9b70c8`。

北京时间 **2026-11-12 10:39** 验收：`current` 已指向该 release，六个容器均 healthy，公网 `/integrated/v1/health` 返回 `{"status":"ok","checks":{"database":true,"migrations":true,"scheduler":true}}`；`migrate --check` 无待应用迁移。发布前数据库 gzip 备份 **421113882 bytes**，SHA-256 为 `c3499029989b5c64d71c4ab975b846724586fe0d59315d871dab6f60ca0ed478`，位于 `/opt/trade-tools-integrated/backups/integrated-20261112-full-736a095/`。Compose 切换时重建了 MySQL／Redis 容器，但沿用原有持久化数据卷；没有改写业务数据或执行交易写入。

清理了发布过程中产生的临时构建镜像和 Docker build cache；当前根分区约 **24 GB 可用／38%**，构建缓存为 0。线上只做健康、迁移、容器、镜像和磁盘只读验收，没有真实开仓、撤单、止损、平仓、划转或保护单操作。后端发布不代表 iOS 已上传 TestFlight 或安装到实机。

<a id="首尔服务器磁盘清理20261112"></a>

## 首尔服务器磁盘清理（2026-11-12）

在 **47.80.22.243（首尔服务器）** 检查到宿主物理盘约 **50 GB**，根分区约 **40 GB**；清理前已用 **37 GB／99%**，仅剩约 **717 MB**。主要原因是 MySQL 二进制日志累计约 **16 GB**，应用数据库实际表约 **3.8 GB**，整合发布历史备份约 **7.1 GB**。检查 `SHOW REPLICA STATUS` 为空，当前没有副本同步；完整逻辑备份是现行恢复方式。

按用户“清理一下”授权，在线清理 MySQL 当前 binlog 之前的历史文件，并将 `binlog_expire_logs_seconds` 从 30 天调整为 **259200 秒（3 天）**；保留当前 binlog，未停止或重建 MySQL／Redis，也未修改业务表。删除早期发布的大型数据库备份和旧 release，保留当前 `integrated-20261112-full-7ed091f` 及最近三个完整回滚版本（`b85356f`、`06619e7`、`14e1182`）；删除与这些旧备份对应的非运行整合镜像、无主 Docker 卷和构建缓存，并将 systemd journal 控制在约 128 MB。

清理后根分区约 **14 GB 已用／24 GB 可用／36%**，Docker 仅保留 6 个镜像、2 个活动数据卷，构建缓存为 0；MySQL 数据卷约 **5 GB**，其中业务数据仍保留。当前 release 仍指向 `integrated-20261112-full-7ed091f`，六个容器均 healthy，公网 `/integrated/v1/health` 返回数据库、migration、scheduler 全部 true。没有执行真实开仓、撤单、止损、平仓、划转或保护单操作。

<a id="完整同源发布20261112-条件单终态查询"></a>

## 完整同源发布（2026-11-12，手动仓条件单终态查询修复）

提交 **`7ed091ff61dabf54fb0653d01c9af336913aadc3`** 已推送至 GitHub `codex/integrated-ios`，并按用户授权将完整同源后端发布到 **47.80.22.243（首尔服务器）**。当前发布目录为 `/opt/trade-tools-integrated/releases/integrated-20261112-full-7ed091f`，API／market／worker／scheduler 统一使用镜像 `tradetools-integrated:integrated-20261112-full-7ed091f`。

本次修复 Binance 条件单已经触发、取消或过期后精确查询返回 `order does not exist` 的正常终态：适配层按空结果处理，已结束的旧止损进入恢复补挂；提交结果仍未知的请求继续等待幂等核对，不重复提交，也不再把原始错误展示在持仓卡片。数据库 gzip 备份 **401138839 bytes**，无待应用 migration；MySQL／Redis、数据卷、环境文件和 Nginx 配置保持不变。六个容器均 healthy，公网健康检查返回 `{"status":"ok","checks":{"database":true,"migrations":true,"scheduler":true}}`；活动仓位、待成交委托及 PENDING／RUNNING 命令均为 0，原有 **UNKNOWN 1** 保持原样。

本地相关后端回归 **341 项／0 失败**，线上只做健康、数据库、迁移、scheduler 和状态只读核验，没有执行真实开仓、撤单、止损、平仓、划转或保护单操作。按用户授权清理了两份旧数据库备份，并清理可重建的 Docker 构建缓存以完成发布空间回收；当前发布备份仍保留，可按其回滚脚本恢复旧应用镜像和 `current`，不恢复数据库、不反迁移、不重放交易命令。这里的切换仍是同一台 **47.80.22.243（首尔服务器）** 内的 release／镜像切换，不是从 USDT 项目服务器迁移。

<a id="完整同源发布20261112b85356f"></a>

## 完整同源发布（2026-11-12，手动仓位与 Maker 投影修复）

按用户“提交所有更改并部署”授权，将提交 **`b85356f5b387e4a7ea412163ec1b7262b4dadbbd`** 推送至 GitHub `codex/integrated-ios`，并把完整同源后端发布到 **47.80.22.243（首尔服务器）**。发布目录为 `/opt/trade-tools-integrated/releases/integrated-20261112-full-b85356f`，API／market／worker／scheduler 统一使用镜像 `tradetools-integrated:integrated-20261112-full-b85356f`；319 个运行 Python／requirements 文件与提交清单完全匹配。

北京时间 **2026-11-12 06:15:40** 切换完成。数据库 gzip 备份 **400880380 bytes**，无待应用 migration；MySQL／Redis 容器、卷、环境文件和 Nginx 配置保持不变。切换前后活动持仓、待成交限价、PENDING／RUNNING 命令均为 0，原有 **UNKNOWN 1** 保持原样，没有重放或强改未知命令。六个容器均 healthy，公网健康、数据库／migration／scheduler 验收及 13 个行情周期／192 个历史窗口核对通过；隔离 MySQL／Redis 回归 **53 项通过**，没有真实开仓、撤单、止损、平仓、划转或保护单操作。

这里的“切换”是同一台 **47.80.22.243（首尔服务器）** 内由旧 release／镜像切到新 release／镜像，不是从 USDT 项目的服务器迁移。iOS 整合项目此前一直使用这台首尔服务器；原 USDT／USDC 来源目录和旧生产栈不属于本次运行目标。后续回滚使用该备份中的脚本恢复旧四个应用镜像和 `current`，保留数据库、基础设施及交易事实，不恢复数据库、不反迁移、不重放 UNKNOWN 命令。

<a id="完整同源发布20261112"></a>

## 完整同源发布（2026-11-12）

按用户“提交部署”授权，将完整整合工作区提交 **`06619e7d402ce184a042a112f719d4bb7dd3783c`** 推送至 GitHub `codex/integrated-ios`，并将同源后端发布到 **47.80.22.243（首尔服务器）**。发布目录为 `/opt/trade-tools-integrated/releases/integrated-20261112-full-06619e7`，API／market／worker／scheduler 统一使用镜像 `tradetools-integrated:integrated-20261112-full-06619e7`；运行源码清单 **319 个 Python／requirements 文件**逐项匹配，归档包含 **333 个**后端／部署文件。

北京时间 **2026-11-12 05:35:07** 切换完成。数据库 gzip 备份 **401400449 bytes**，没有待应用 migration；MySQL／Redis 容器、卷、环境文件和 Nginx 配置保持不变。切换前后活动持仓、待成交限价、PENDING／RUNNING 命令均为 0，原有 **UNKNOWN 1** 保持原样，没有重放或强改未知命令。六个容器均 healthy，公网 `/integrated/v1/health` 返回 200，数据库／migration／scheduler 检查通过；13 个行情周期、192 历史窗口和保证金／浮盈监控只读核验通过。

部署前可用磁盘约 **1.61 GiB**，低于历史发布脚本的 3 GiB 预警值；本次确认构建镜像约 319 MB、备份完成后切换成功，未删除历史备份或 Docker 数据。后续发布前仍需优先补充磁盘或制定受控的历史归档清理方案。隔离 MySQL／Redis 回归 **53 项通过**，没有真实开仓、撤单、止损、平仓、划转或保护单操作。证据保存在本机忽略目录 `.integration-runtime/FullDeliveryNov12/` 与服务器备份 `/opt/trade-tools-integrated/backups/integrated-20261112-full-06619e7/`。

<a id="完整同源发布20261111"></a>

## 完整同源发布（2026-11-11）

按用户“把未提交的全部提交部署”授权，整合工作区全部 25 个待交付文件以 `4fc9e9b` 提交推送，包含独立目录整理、统一委托 API／iOS 卡片、限价图表冻结与挂单导航，以及发布核验定位的市价提交回调修复。隔离 MySQL 验证发现两处测试可移植性假设后，以 `14e1182` 补齐测试和验证文档；没有略过失败，也没有实现此前仅讨论的逐仓保证金规划。

北京时间 **01:54:57**，将完整同源后端 `14e1182dc45960cc19c0ff60621a4bc0f4cec439` 部署至 **47.80.22.243（首尔服务器）**。`current` 为 `/opt/trade-tools-integrated/releases/integrated-20261111-full-14e1182`，API／market／worker／scheduler 统一使用 `tradetools-integrated:integrated-20261111-full-14e1182`。归档 **333 个文件**逐项匹配 Git；四个应用容器各 **319 个 Python／requirements 文件**全部匹配 manifest，不采用选择性覆盖。归档 SHA-256 为 `242fd91379b9ad976a4748084b986a3f518e486003326110fdfc349eb81c60a5`。

完整后端隔离回归 **1166 项、0 失败、6 项 opt-in 跳过**；最终包在没有生产配置／数据卷、没有外网的一次性 MySQL／Redis 上 **52 项／29.668 秒／0 失败／0 跳过**。首轮测试假设修正与 iOS 的 34 项 host、Release／build-for-testing 编译边界见 [开发](development.md#完整交付验证20261111)。

一致性数据库备份 **396362800 bytes**，完整 gzip 解压及 SHA-256 校验通过。受限备份目录 `/opt/trade-tools-integrated/backups/integrated-20261111-full-14e1182/` 包含旧容器与来源、环境／nginx 副本、结果及 `rollback.sh`。仅执行 `migrate --check`，没有应用 schema／数据迁移、初始化账号或重置队列。先停止旧 worker／scheduler，再以 `--no-deps --no-build --pull never --wait` 切换同源四服务；MySQL／Redis 容器 ID、镜像及卷保持原样，环境文件 inode／大小／mtime／权限和 nginx 哈希不变，`nginx -t` 通过。

切换前后数据库计数相同：活动持仓 0、待成交限价 0、PENDING／RUNNING 0、**UNKNOWN 1**。原未知命令保持待核对，没有手工重放或强改状态；没有执行真实开平仓、划转、撤保护单或发送测试通知。这些本地订单计数不代替交易所完整对账。

**01:55** 只读验收：六服务 healthy；公网 HTTPS 健康 200，统一委托匿名 401，两个现有有效绑定分别以不持久化的短期 access JWT 读取 `GET /v1/trade/order/list` 均返回 HTTP／业务 200，未解密 API Key 或请求交易所。QA 鉴权、BTC1h 1500 根与尾部 2 根、六类统计后台收敛、2h 周期、WSS ready／订阅 ACK／ping-pong／K 线／ticker 通过。三连接同时收行情，Redis 实际仅一条 Pub/Sub 连接；gzip **69918 bytes**、解压 JSON **423012 bytes**，identity 兼容。13 周期与 192 窗口保持，注册及通知开关不变。

后续 Compose 必须使用该 release 的 `compose.integrated.yaml` 加 `compose.runtime.yaml`，设置 `INTEGRATED_RELEASE=integrated-20261111-full-14e1182`；后者固定当前 MySQL／Redis 镜像。回滚执行上述备份中的 `rollback.sh`，恢复旧四应用镜像和 `current`，保留数据库、基础设施与实际订单／通知事实，不恢复数据库、不反迁移、不重放未知命令。完整证据保存在忽略目录 `.integration-runtime/FullDeliveryNov11/`。iOS 由现有 Xcode Cloud 自动构建，后端部署不代表手机更新，见 [TestFlight](testflight.md#统一委托源码自动构建20261111)。

## 确认弹窗修复发布核验（2026-11-10）

用户授权全部提交部署，客户端修复 **`bc6f49b`** 已推送 GitHub `codex/integrated-ios`。2026-11-10 **17:28～17:30（北京时间）** SSH 只读核验 **47.80.22.243（首尔服务器）**：`current` 仍为 `integrated-20261109-maker-f1f8254`；其 329 个受追踪后端／部署文件与交付源码一致，api／market／worker／scheduler 运行容器的各 317 个 Python／requirements 文件也逐项匹配，全部零差异。六容器 healthy，公网 HTTPS 健康 200，database／migrations／scheduler 检查通过。

本轮及该运行版本之后的全部提交只改客户端、测试或文档，没有尚未上线的配套后端，所以保留相同运行版本，不为相同源码重建镜像、重启容器或切换 `current`。未执行迁移、初始化、真实交易、划转、撤保护单或修改既有持仓。客户端发布需等待本次 Xcode Cloud 构建与分发，不能把后端同源核验写成手机已经生效；见 [交付记录](changes.md#2026-11-10确认弹窗修复完整源码交付与发布核验)及 [TestFlight](testflight.md#确认弹窗修复自动构建2026-11-10)。本地只读证据位于忽略目录 `.integration-runtime/ModalDeliveryNov10/`。

## Maker 开仓链路发布（2026-11-09）

2026-11-09（北京时间）按用户“推送 GitHub 并部署到云能服务器”的授权，将 GitHub `qoqkeep-create/binance` 的 `codex/integrated-ios` 提交 **`f1f8254`** 部署至 **47.80.22.243（首尔服务器）**。发布目录为 `/opt/trade-tools-integrated/releases/integrated-20261109-maker-f1f8254`，`current` 已切换到该目录；API、market、worker、scheduler 四个应用容器均使用镜像 `tradetools-integrated:integrated-20261109-maker-f1f8254`。

首次远程发布在补齐 release 的 `server.env` 符号链接前停止，未切换应用容器。重试阶段 Compose 重新核对了 MySQL 容器，但继续使用既有命名卷 `tradetools-integrated_integrated-mysql`；Redis 及其 AOF 卷未重建。最终应用切换使用 `--no-deps`，没有再次操作 MySQL／Redis。发布前备份位于 `/opt/trade-tools-integrated/backups/integrated-20261109-maker-f1f8254/`，包含数据库 gzip、受限环境副本、前版路径和发布前计数。

切换前只读计数为活动持仓 1、PENDING／RUNNING／UNKNOWN 命令 0、待成交限价 0；没有真实开仓、撤单、资金划转或撤保护单。`migrate --check` 通过，`bootstrap_mobile` 报告已有用户且未改账号或密码。切换后六个容器均 healthy，公网 `https://47.80.22.243/integrated/v1/health` 返回 **200**，数据库／迁移／scheduler 检查均通过；应用数据库复核活动持仓仍为 1、未完成交易命令为 0。日志尾部未发现应用错误。

本次线上验收只覆盖服务切换、健康检查和只读数据保护；真实 Binance Maker 成交、拒单重试、持续状态弹窗及 iOS 新包仍需在受控账户和客户端构建中分别验收。回滚应恢复备份记录的前版 `integrated-20261106-full-7e29236` 与 `current`，不恢复数据库、不反迁移、不重放交易命令。

## 完整同源发布（2026-11-06）

2026-11-06 **17:43:52（北京时间）**，按用户“全部提交推送部署，不绕过其他更改”的要求，将完整源码 `7e29236` 部署至 **47.80.22.243（首尔服务器）**。`current` 为 `integrated-20261106-full-7e29236`，API／market／worker／scheduler 均使用同一完整镜像 `tradetools-integrated:integrated-20261106-full-7e29236`，不再组合不同限定源码；331 个归档文件与 Git 存档逐项相符，四个进程各 **317 个运行 Python／requirements** 哈希完全匹配。包含此前已推送但未上线的 API 共享行情分发、私有事件批量投递／余额事实分流、账户流连接守卫、调度预热去重、全部 13 种行情周期、注册权限／短 Key、浮盈与 >75% 保证金独立 Echobell 任务，以及已有首屏同步补线／缓存／gzip 改动。

发布前只读确认本地活动仓位、待成交限价和 RUNNING 命令均为 0，未把这些计数当成交易所完整对账。完整后端 SQLite／隔离 Redis 回归最终运行器计数 **1141 项、零失败、6 项 opt-in 跳过**；另在无生产环境、无生产数据卷、无外部网络的临时 MySQL／Redis 上 **55 项通过、0 跳过**，涵盖这些并发／迁移合约及新增通知。账户事件测试因 `TestCase` 包装事务与真实连接清理不兼容而在 MySQL 首轮失败，已改为 `TransactionTestCase` 并重跑通过，未绕过测试。验证详见 [开发](development.md#完整版本发布验证2026-11-06)。

一致性数据库备份 **371387962 bytes**，完整 gzip 解压与 SHA-256 校验通过；目录 `/opt/trade-tools-integrated/backups/integrated-20261106-full-7e29236/` 为 0700，含前版容器、来源、受限配置与回退脚本。仅应用 `positions.0029_positionprofitwatch_positionprofitalert` 和 `positions.0030_position_margin_alerts`，各新增两张通知状态／投递表；没有改写既有订单、策略、账号或迁移回填。随后 `migrate --check` 通过。停止旧 worker／scheduler 后启动同源四服务，避免旧新后台混跑；没有初始化账号、重置队列、手工交易、资金划转或撤保护单。

MySQL／Redis 容器 ID、镜像及数据卷原样，Redis 保持 AOF、256 MiB maxmemory／320 MiB 容器限额，MySQL 保持 1／2 GiB 内存／swap 限额；本轮无需再次重建 Redis。环境文件 inode／大小／mtime／权限不变。宿主 nginx snippet 与完整源码模板哈希相同，`nginx -t` 通过，继续 gzip；没有为相同配置再 reload。后续 Compose 使用本 release 的 `compose.integrated.yaml` **加 `compose.runtime.yaml`**，设置 `INTEGRATED_RELEASE=integrated-20261106-full-7e29236`；后者仅固定当前 MySQL／Redis 镜像，四个 Python 服务同源，原六层限定 override 留在旧 release 作历史证据。

六服务 healthy，公网 HTTPS／QA 鉴权、BTC1h 1500 根／尾部 2 根及六类统计、鉴权 WSS ready／订阅 ACK／ping-pong 和 K 线／ticker 通过。**3 个同时连接均收到订阅行情，Redis 实际仅 1 条 Pub/Sub 连接（公共主题使用模式订阅）**，确认共享分发实际运行；不是纯进程内采集网关。新增 BTC2h 两根读取通过。公网 gzip **69850 bytes**、解压 JSON **423035 bytes**，identity 响应与 Vary 正常。注册开关仍为 true，QA 无管理权；普通／live APNs、浮盈和保证金监控开启，仓位通知、外部交易通知和外部 HTTP 接收继续关闭。自动通知自然触发、手机点击和首帧性能仍待实机验收，本轮没有发送测试通知。

回滚执行备份中的 `rollback.sh`，恢复原四个 Python 镜像和 `current`，保留 MySQL／Redis、已新增通知表及实际投递记录；**不恢复数据库、不反迁移、不重放未知通知或交易命令**。本地证据在忽略的 `.integration-runtime/FullReleaseNov6/`。客户端换根修复在 `79f812b`，完整后端在 `7e29236`；全部源码已推送 `codex/integrated-ios`，后续验收文档另提交。客户端 Cloud／TestFlight 与手机状态见 [TestFlight](testflight.md#换根修复与完整源码交付2026-11-06)，后端部署不能使旧安装包获得换根修复。

唯一目标为 **47.80.22.243（首尔服务器）**。原 USDT 生产环境及本地来源目录不属于本轮操作范围。用户已授权整合版部署与旧 USDC Java 环境退役；普通验收禁止真实开平仓、划转或撤保护单。各日期段落描述当时状态，当前运行版本以上方最新实际发布为准。

## 首屏补齐、Redis 扩容与 nginx 压缩发布（2026-11-06）

2026-11-06 16:44:27（北京时间）已将 Qoder 提交 `bb5e53b483ecc4f6367f7ce6e56ab52d1ab2c330` 的限定行情改动部署至 **47.80.22.243（首尔服务器）**。`current`／API 为 `integrated-20261106-firstscreen-api-bb5e53b`，market 为 `integrated-20261106-firstscreen-market-bb5e53b`；分别以上一版保证金 API 与历史缓存 market 的实际来源为基线，`scope=limited-first-screen-redis-gzip`。每包只变更 4 个运行 Python 文件、2 个测试文件与 Compose／nginx 共 8 条路径；API 的 307、market 的 296 个运行 Python／requirements 哈希全部匹配 manifest。没有整包覆盖 HEAD，也没有纳入共享分发、新增周期或账号／保证金通知后端。

发布前完成 299 项 HEAD 定向回归、两个实际限定包各 277 项回归。重新核对运行基线、环境文件和配置差异，构建两镜像，执行 `migrate --check` 后生成数据库一致性备份（gzip **370360137 bytes**，完整解压验证）。切换前 RUNNING 命令计数为 0。没有应用 schema／数据迁移，没有真实交易、资金划转、保护单或策略操作。

先备份并同步 `/etc/nginx/snippets/tradetools-integrated.conf`，`nginx -t` 通过后 reload，再移除旧 API 的 Django gzip，避免交接出现未压缩响应。宿主 snippet 与发布模板哈希一致，最终为 `fefffe62213ab892f9411d46ebf68a354ea9b321ff073cb6b5105c62ed0c397f`。Redis 正常停机（exit 0、非 OOM），离线备份原 `/data` 卷为 `redis-data.tar`（**25405440 bytes**，读取及 SHA-256 校验通过），随后强制重建 Redis。原 `tradetools-integrated_integrated-redis` 卷、Redis 二进制镜像哈希、AOF／everysec／noeviction 保留；新容器实际 `maxmemory=268435456`（256 MiB）、cgroup memory **335544320**（320 MiB），AOF 加载完成、写状态正常且数据库有数据。停机发起至 Compose 健康确认约 **11.14 秒**，含健康检查等待，不能等同于全部时间都不可用。未删除卷、清缓存或恢复旧键。

随后配套替换 API／market，六服务 healthy；worker、scheduler、MySQL 容器 ID 和镜像哈希原样，环境文件 inode／大小／mtime／权限原样。备份、前后容器／Redis 状态、来源 manifest、部署日志与结果保存在 `/opt/trade-tools-integrated/backups/integrated-20261106-firstscreen-api-bb5e53b/`（0700）；本机证据在忽略的 `.integration-runtime/FirstScreenDeployNov6/`。

后续 Compose 必须带齐新 API release 下的 `compose.integrated.yaml`、`compose.signal-leverage.yaml`、`compose.entry-ema.yaml`、`compose.history-cache.yaml`、`compose.margin.yaml`、`compose.firstscreen.yaml`，并设置 `INTEGRATED_RELEASE=integrated-20261106-firstscreen-api-bb5e53b`。最后一份固定两目标镜像／构建目录及其他实际镜像，Redis 固定原镜像 ID，禁止无意拉新版本。旧长运行容器的 Compose 标签可能指向已清理的十月归档；操作以这里现行完整文件链为准。

回滚执行上述备份的 `rollback.sh`：恢复原 API／market、旧 nginx snippet 和 `current`，**保留 Redis 扩容与原 AOF 卷**，不还原数据库、不反迁移、不重置队列。扩容后不自动缩回 80 MiB，以免新缓存已超过旧上限；若需独立重建 Redis，应使用备份中的 `compose.rollback.yaml` 与原完整配置链，不删除卷。

16:45:12（北京时间）公网验收通过：HTTPS 200、既有 QA 鉴权、BTCUSDT 1h 的 1500 根与尾部 2 根、六类统计、鉴权 WSS ready／订阅 ACK／ping-pong 及真实 K 线／ticker。原始 wire 检查 gzip **69910 bytes**、解压 JSON **423036 bytes**，identity 响应 **423036 bytes**，`Vary: Accept-Encoding` 正常；六服务和 192 窗上限再次核验。手机首帧收益及发布前后 `ChartLoadReport` 边界见 [行情](market-data.md#首屏同步补齐与传输调整2026-11-06)，不能由接口冒烟推导手机提速。

本轮按授权推送 GitHub `codex/integrated-ios`，包括此前仅本地提交的 `261cf59` 客户端及 Qoder 的 `bb5e53b`；交给现有前端自动构建流程。推送不代表 Cloud／TestFlight 已成功或手机已安装；没有手动上传。`261cf59` 的注册权限、短 Key 字段和保证金 Echobell 后端／迁移仍未部署，详见 [已知事项](known-issues.md)。

## 保证金只读接口限定发布（2026-11-06）

2026-11-06 15:36:55（北京时间）已将 `ba4b9e0` 中的保证金读取范围部署至 **47.80.22.243（首尔服务器）**。`current`／API 为 `integrated-20261106-margin-api-ba4b9e0`，以上一版 `integrated-20261106-history-cache-api-a91850b` 的实际归档为基线；market 继续为 `integrated-20261106-history-cache-market-a91850b`，worker／scheduler／MySQL／Redis 保留原镜像，六服务 healthy。本节保留当时状态，当前 API 以上方最新实际发布为准。

此前运行包缺少 `GET /v1/position/margin`，本次只叠加该接口、路由、只读账户适配器、带单读取允许路径及两个 GET 的权重声明，附对应测试；共 6 个允许路径，321 个来源文件中 315 个原样。适配器只 GET `accountConfig`／`fapi/v2/account`，使用 BACKGROUND 预算且各权重 5，不执行交易对账或订单／资金／保护操作。缓存 1 秒，事件／详情／手动请求 `fresh=1` 可绕缓存；无需 schema／数据迁移。限定包 63 项隔离回归通过，见 [开发](development.md#持仓紧凑切页与保证金双卡片2026-11-06)。没有整包替换为 HEAD，未带入共享行情分发或其他交易修改。

归档 SHA-256 为 `aed3f83215e391cae32fc4e8957a4c26e39cd79849d4fcf681c0a23c9cf9c959`，两端相同；307 个运行 Python／requirements 哈希与 manifest 一致。备份位于 `/opt/trade-tools-integrated/backups/integrated-20261106-margin-api-ba4b9e0/`（0700），含前版、容器、来源、配置回退命令与结果；数据库 gzip **369640322 bytes**，进程返回和完整解压校验通过。仅 `migrate --check`，没有应用迁移／恢复数据库／重放队列。切换前 RUNNING 命令计数为 0；仅替换 API，其余五服务容器 ID 与镜像哈希不变，环境文件的 inode／大小／mtime／权限未变。

沿用前三份 Compose 加 `compose.history-cache.yaml`，再叠加 `compose.margin.yaml` 固定新 API 及其他实际镜像，API 配置除镜像／构建路径外与原版一致；后续 Compose 操作不能遗漏任一 override。`INTEGRATED_RELEASE=integrated-20261106-margin-api-ba4b9e0`。回滚执行上述备份的 `rollback.sh`，只恢复原 API 镜像和 `current`，保留数据库、其他服务及环境；保证金接口会随回滚消失，需评估客户端兼容，不反迁移。

15:37:15（北京时间）复核六服务健康，公网 HTTPS 健康 200、匿名保证金读取 401；新 API 进程内以 SQL／网络均禁止的替身验证普通／带单读取、绑定变更 409、匿名拒绝、适配器只有 GET 及完整后台权重。没有真实绑定查询或交易所调用，不能把替身验收写成真实账户保证金／手机时效通过。证据在本机忽略目录 `.integration-runtime/PositionMarginTabsNov6/` 的 manifest、`deploy-remote.log`、`deployment-result.json` 与 `verify-release.log`；远端备份保留部署结果。客户端空仓／双卡片及切页改动需要新包，TestFlight 分发和 iPhone 安装仍待验。

## 历史缓存与统计限定发布（2026-11-06）

发布前 SSH 只读核验 **47.80.22.243（首尔服务器）**：`current`／API 为 `integrated-20261103-retire-entry-ema-2d2d93f13dbf`，market 为 `integrated-20261102-git-171be8d74c50`；worker 为 `integrated-20261103-worker-retire-entry-ema-f7a289ab3c7d`，scheduler 为 `integrated-20261103-position-live-activity-3a1a95e914ba`。六个服务健康，API／market 分别核对 304／295 个 Python／requirements 哈希。源码已推送的共享分发及近期周期扩展未在该运行基线生效；不能据 GitHub HEAD 推断实际发布或提速归因。

用户授权完成后推送部署。本次只叠加统计最小上下文、历史 revision 回收／回填保护及关联 maintenance 让位，按 API／market 各自实际基线构建两个独立镜像；各包 92 项隔离回归通过，详见 [开发](development.md#历史缓存生命周期与统计隔离2026-11-06)。不得整包覆盖为 HEAD，或漏带既有 Compose override 而回退其他业务。发布时已重新核对容器／源码基线并备份数据库，保留环境、迁移及原镜像，只替换 API／market；worker、scheduler、MySQL、Redis 容器不变。实际发布结果如下。

### 实际发布与验收

2026-11-06 02:14:01（北京时间）已将源码 `a91850bce48235e313478ebd5f523e2b5b2930aa` 的限定改动部署至 **47.80.22.243（首尔服务器）**：API 为 `integrated-20261106-history-cache-api-a91850b`，market 为 `integrated-20261106-history-cache-market-a91850b`，`current` 指向新 API release。两镜像各保留原有基线，manifest 的 `scope=limited-history-cache-statistics` 明确不是完整 HEAD 发布。原 Compose override 全部保留，再叠加 `compose.history-cache.yaml` 固定两目标镜像及其余服务实际镜像；切换前比较解析后的目标配置，除镜像／构建目录外一致，环境文件未变。

切换前数据库一致性备份与 gzip 校验通过；只执行 `migrate --check`，没有应用迁移、重置队列或交易／资金／保护单操作。切换后六服务健康，新 API／market 全部 Python／requirements 哈希与限定 manifest 一致；worker、scheduler、MySQL、Redis 的容器 ID 与镜像哈希保持原样。备份、前后容器、来源 manifest、部署日志及 `rollback.sh` 均在 `/opt/trade-tools-integrated/backups/integrated-20261106-history-cache-api-a91850b/`；回滚仅恢复 API／market 原镜像及 `current`，不恢复数据库、不反迁移。后续 Compose 操作须使用新 API release 的原三份配置加 `compose.history-cache.yaml`，避免误用旧镜像。

2026-11-06 02:15:17（北京时间）公网验收通过：HTTPS 健康 200、既有 QA 鉴权、BTCUSDT 1h 完整 1500 根／尾部 2 根历史、gzip、六类统计响应、WSS ready／订阅 ack／ping-pong 及 BTCUSDT 实时 K 线／ticker。统计最终 pending=false，响应中有 501 根含统计；这是接口与后台可用性验收，不能视为手机延迟 A/B。只读缓存检查记录 64 个索引窗口、0 个旧 revision 窗口；其范围为该次采样，不作长期命中率承诺。完整证据在本机忽略目录 `.integration-runtime/HistoryCacheNov6/`。本轮无需新客户端，未上传 TestFlight；共享分发／编码复用仍未纳入这两个线上镜像，真实手机收益与此前提速归因仍待测。

## 周期切换只读测量（2026-11-05）

22:03:39（北京时间）最后通过已有 SSH 认证，在 **47.80.22.243（首尔服务器）** 的 API 容器只读取得最近 50 份公共图表诊断。报告均为 Build 44，接收区间 20:00:06–22:02:03；此时 release 仍为 `integrated-20261103-retire-entry-ema-2d2d93f13dbf`，限定来源 `limited-entry-ema-retirement`／`15b4784c70433233c34cb5c6c738cb1a9b92848b`，基线为 `integrated-20261103-position-live-activity-3a1a95e914ba`。没有据 GitHub 最新源码推定线上版本。

数据库会话显式 `SET SESSION TRANSACTION READ ONLY`，除诊断外只查询四组公共历史各 1500 根并在同一会话紧接复读，测量 Python 转换与压缩；Redis 只用 GET／ZSET 查询缓存容量、窗口键和 revision。没有调用会排补线任务／写缓存的 `load_history` 或历史 HTTP 接口，没有清缓存、注入生产计时日志、修改服务／数据库／网络配置、重启或部署，也没有交易所请求、交易／资金／保护单操作。

受限原始诊断、脱敏汇总、SQL／Redis 测量与复现脚本保存在本机忽略目录 `.integration-runtime/ChartIntervalLatencyNov5/`，目录 0700、文件 0600。`reports-50.ndjson`／`reports-summary.json` 为报告证据，`history-cost-summary.json` 为已得成本样本；只读脚本为 `read_production_reports.py`／`read_production_history_cost.py`。查询仍可能占用数据库资源，未使用压力测试，也未反复清缓存制造冷启动。业务结论、缓存优先级的本地修复与待验证范围统一见 [行情](market-data.md#周期切换耗时与十字线百分比2026-11-05)，测试见 [开发](development.md#周期切换排查与百分比回归2026-11-05本地)。源码及文档保留本地，未提交／推送或上传新包；本次查询不构成修复后线上验收。

## 公网访问边界与安全核验（2026-11-05）

2026-11-05 13:54～14:00（北京时间）从本机对 **47.80.22.243（首尔服务器）** 做低频 TCP 探测、匿名 HTTP GET／一次 WSS 握手，并审阅本地部署、认证和资源使用代码。用户明确说明已在云后台关闭 22，目的为测试 Codex 是否仍可接入；22 的连接超时符合该设置，不能当作 SSH 服务故障。没有取得 SSH 会话，也没有核验宿主实时配置、线上镜像源码或全部云防火墙规则。

| 检查 | 本次实际结果 |
| --- | --- |
| 公网端口抽查 | 80／443 可连接；22、3306、33060、6379、8787、2375、2376、8443、3000、8000、9000 超时，8080 拒绝连接。仅代表本机到该 IPv4、该时点和所列端口的观测，不是全端口、IPv6 或其他来源的验证 |
| HTTPS 深度健康 | `/integrated/v1/health` 连续三次 200，约 403／430／456 ms，证书校验通过；14:00 复查仍 200，database／migrations／scheduler 全部 true。不能据此声称本轮查过六个容器或数据库内容 |
| 业务认证 | 匿名访问 `/integrated/api/auth/me`、`/integrated/api/commands`、账户 info、持仓 list、API 绑定 info、策略 list 均 401；`/integrated/ws/v1` 匿名握手 403。未携带用户会话或查询他人对象 |
| 消息与配置文件 | TradingView pending 在未配置消息凭证时返回 503，不开放读取；根路径和 `/integrated/` 下的 `.env`、`.git/HEAD` 抽查均 404 |
| 管理与注册入口 | `/integrated/admin/login/` 匿名 200，为 Django 登录页；`/integrated/v1/auth/admin-settings` 返回 `open_registration=true`、匿名 `is_admin=false`。看到登录页或注册开放不等于绕过权限 |

本轮未发现已证实的匿名任意数据库读写或远程命令执行入口；代码审阅确认以下待加固项，影响条件与线上验证必须分开：

| 优先级 | 代码与公网证据 | 风险和建议（均未实施） |
| --- | --- | --- |
| 优先 | `riskon/urls.py` 挂载标准 Django admin，公网登录页可达；`users/views.py` 的登录失败锁定只包围应用 LoginView，未包围 admin | 后台增加了独立的密码攻击面。建议不用时在入口封闭，用时限制 VPN／允许来源并配置独立登录防护；应用 `is_admin` 与 Django `is_staff` 是不同权限，不能据应用管理员身份推定可进入后台 |
| 优先 | `common/health.py` 每次匿名 GET 都执行 `SELECT 1`、实例化 `MigrationExecutor` 并查 Redis；本地 Nginx 模板未定义 `limit_req`／`limit_conn` | 请求可反复消耗 API、MySQL 与 Redis 资源，可能影响业务可用性。建议公网仅返回轻量或短时缓存状态，将完整深度检查限制在内部，并在代理层分路径限速／限并发。没有压测复现故障；线上全局 Nginx／WAF 保护尚未核实 |
| 需加固 | 注册已按既有业务要求开放；代码有每 IP 注册限制，默认 10 次／小时，创建账户前未验证邮箱。默认 REST 配置无通用请求限流；策略新增无用户总量上限、列表无分页；WSS 有消息／队列／超时边界但无每账户连接数上限 | 注册开放本身属于当前功能。新账户可使用其获授权的数据库写入和行情订阅；若被滥用，可能累积数据或占用共享资源。建议补邮箱所有权校验、每账户写入及连接配额、列表分页和入口防护；保留既有用户／模式／绑定隔离。不推定新账户能访问他人数据，也未创建测试账户或写入策略／命令 |

依据：[Django 官方安全说明](https://docs.djangoproject.com/en/5.2/topics/security/#additional-security-topics)明确标准认证不自带登录请求节流；[Nginx 请求限速模块](https://nginx.org/en/docs/http/ngx_http_limit_req_module.html)用于入口速率限制；[DRF 节流说明](https://www.django-rest-framework.org/api-guide/throttling/)指出应用节流不能单独承担暴力破解／DoS 防护。关闭 SSH 只缩小主机管理入口，正常开放的 HTTPS 仍能触发应用及其数据库访问；不能把端口关闭当作完整安全审计。

本轮没有登录尝试、注册、写入探测、压力测试、生产交易／资金／保护单动作或配置修改。本轮仅更新文档，未提交、推送或部署。依赖／宿主补丁、实际数据库权限、备份隔离及云控制台／CI 等管理入口不在本次在线验证范围；后续应通过受控云控制台或既有授权管理通道核验，无需为本次结论重新开放公网 SSH。

### 连通性复测（14:05～14:07）

2026-11-05 14:05～14:07（北京时间）按用户要求重新测试 **47.80.22.243（首尔服务器）**：22／80／443 均可建立 TCP 连接，22 建连约 135 ms。默认 SSH 身份被拒绝；随后使用本机已有项目专用密钥，在严格主机指纹校验与非交互模式下认证成功，远端只执行 `id -un`，返回 `root`、退出码 0。说明本机在此时可以通过既有授权密钥取得 root SSH 会话，不是匿名访问或认证绕过；未修改密钥、主机信任或服务器配置。

HTTPS `/integrated/v1/health` 连续三次返回 200，总耗时约 461／263／1338 ms，证书校验均通过，database／migrations／scheduler 全部 true。上方 22 阻断、未取得 SSH 的结论仅适用于 13:54～14:00；最新连通性以上述复测为准。本次未重查其他端口、全局防火墙、容器、数据库内容或安全加固状态，没有运行交易／资金／保护单动作、重启或部署；仅补记文档，未提交推送。

## 强平与费用只读对账（2026-11-05）

21:49（北京时间）最后按用户授权，在 **47.80.22.243（首尔服务器）** 现有 API 容器查询指定账户的两笔近期平仓。数据库会话显式设置 `SET SESSION TRANSACTION READ ONLY`；只读匹配订单后，核对现有绑定的 Key 指纹，凭证仅在进程内解密，不使用会迁移旧密文／写绑定健康状态的通用凭证读取器。交易所请求限制为 GET 白名单，使用现有预算机制读取 `account`、`income`、`userTrades`、`forceOrders` 和 `leverageBracket`；没有调用会补写结算的普通仓位历史接口。

订单身份、成交数量、已实现盈亏、独立清算费和当前余额核对通过，确认历史净盈亏漏计清算费；当前档位只用于近似复算维持保证金，不代替历史标记价快照。业务结论及待修复边界统一见 [资金文档](capital-and-transfers.md#强平清算费用与历史净盈亏2026-11-05线上只读核验)。受限产物位于本机忽略目录 `.integration-runtime/LiquidationReviewNov5/`（目录 0700，原始结果及对账 JSON 为 0600）；其中真实账户交易资料不进入项目文档或版本控制。未修改数据库业务数据、交易／资金／保护单状态或服务配置，没有重启、部署、迁移或测试造仓；文档保留本地，未提交推送。

22:06（北京时间）经 **47.80.22.243（首尔服务器）** 现有 API 容器补查一次未签名的公开 GET `exchangeInfo`，仅输出目标合约的公开参数。结合既有私密对账产物，复算清算费的名义价值基数、独立费率和剩余保证金上限，结果相符；未再次读取私有账单、写业务数据或执行交易。计算结果保存在同一受限目录的 `clearance-calculation.json`，查询时费率不能冒充事发时历史快照。

## 重启恢复与开机自启（2026-11-05）

2026-11-05 12:59（北京时间）最后核验 **47.80.22.243（首尔服务器）** 六个整合容器均 `running/healthy`，公网 HTTPS `/integrated/v1/health` 返回 200，数据库、迁移和 scheduler 心跳检查全部通过；Redis 持久化状态为 `loading=0`、AOF enabled、最后写入与 rewrite 状态均为 `ok`。本次恢复现有容器，没有发布新代码；`current` 仍为 `integrated-20261103-retire-entry-ema-2d2d93f13dbf`，API／worker／scheduler／market 的组合继续以下节限定发布为准。

主机于本日 12:40 启动，Docker／containerd／Nginx 和六个容器原本已经自动启动；故障并非缺少自启配置。Redis 读取 `appendonly.aof.2055.incr.aof` 时遇到格式错误并循环退出，另外四个 Python 服务随之不健康，MySQL 始终健康。只读诊断确认 BASE RDB 全部有效，INCR 的 53,309,440 字节中，前 53,307,426 字节为完整记录，剩余 2,014 字节全部为零；没有完整命令或事务需要从该尾部保留。本次可确认磁盘上可校验的完整前缀已保留；故障前尚未落盘的内存写入不在这项校验范围内。

恢复时先停止四个 Python 写入进程和故障 Redis，完整备份 Redis 卷并逐文件核对压缩归档内容哈希；备份位于 `/opt/trade-tools-integrated/backups/reboot-recovery-20261105-124725/`（目录 0700、文件受限）。归档 `redis-volume-before.tar.gz` 为 **30,081,131 bytes**，SHA-256 为 `18b079494c6ec42dd0c965638c767769494baf5894b42aa5f57388dcdbe4159c`，包含原 manifest、BASE、INCR 和 dump。备份内原容器元数据含受限配置，禁止上传仓库或输出其完整内容。

在单独副本中用原 Redis 7.4.12 镜像、以 manifest 为入口修复并复查，再以禁网络、无端口的隔离实例验证加载、PING 和持久化状态；生产卷只原子替换经确认的 INCR 完整前缀，保留原属主／权限，BASE、manifest、dump 保持原样，未对 MySQL 执行恢复或人工数据改写。修复后的原 manifest 再次检查通过，之后依次恢复 Redis、等待 MySQL／Redis 健康，再启动四个原 Python 容器。六个容器的 ID、镜像、环境和挂载与备份逐项一致，MySQL 仍为 1 GiB 内存限额；没有迁移、数据库恢复、命令／幂等状态重置、手动交易、划转、撤保护或通知测试。

已重新确认并持久化以下开机配置：

```bash
systemctl enable docker.service containerd.service nginx.service tradetools-integrated-cert-renew.timer
systemctl start docker.service nginx.service
docker update --restart unless-stopped \
  tradetools-integrated-api-1 tradetools-integrated-market-1 \
  tradetools-integrated-worker-1 tradetools-integrated-scheduler-1 \
  tradetools-integrated-mysql-1 tradetools-integrated-redis-1
```

四个宿主 units 均为 `enabled/active`，六个容器均为 `unless-stopped`，Nginx 配置检查通过。该策略会在 Docker／宿主恢复时启动未被人工停止的容器，并在进程异常退出时重启；人工 `docker stop` 的容器需要明确 `docker start` 才恢复。自启不能修复损坏的持久化文件，不设置无条件 AOF 截断脚本；本次未再次重启宿主作验证。

以后单纯重启业务应优先恢复现有容器，不运行会构建、迁移和切换 `current` 的 `release.sh`。必须使用 Compose 时仍保留现行三份配置及独立 worker／scheduler 镜像，不能用单个基础文件重新 `up`。AOF 排障遵循 [Redis 官方持久化说明](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/)：先完整备份，在副本检查损坏位置及预计损失，再决定是否修复；工具即使不带 `--fix` 也可能以 `r+` 打开文件，因此使用可写诊断副本，检查原卷时使用文件属主。容器中确认修复需转发标准输入（`docker run --interactive`），不能把没有执行修复的退出当成成功。此次应用与验证证据保存在上述备份的 `applied-recovery.json`、`isolated-validation.json`、`restoration-verification.json` 及 AOF 检查日志。

## 开仓周期初筛退役限定发布（2026-11-03）

2026-11-03 23:31（北京时间）核验 **47.80.22.243（首尔服务器）** 的 `current` 为 `integrated-20261103-retire-entry-ema-2d2d93f13dbf`（API）；worker 独立为 `integrated-20261103-worker-retire-entry-ema-f7a289ab3c7d`。本次按用户要求移除 EMA 方向／周期初筛接口及新单门控，未替换完整 Git HEAD。下方发布记录均保留各次操作时点，当前组合以本节为准。

- API 从紧接下方的 LivePositions 实际运行版叠加 5 条允许路径，317 个源文件中 312 个原样；worker 从自身 `integrated-20261102-git-171be8d74c50` 叠加同一范围，307 个文件中 302 个原样。只改 3 个运行及 2 个测试文件，72 个非目标 views 声明逐字节不变；发布前只读核对 worker 镜像 295 个源码哈希。API 归档 SHA-256 为 `8570b8ae4ce991286546570cfeec4bff72ecaf122e698e8534e381cc44668202`，worker 为 `8d028ce19df756435bd7256daf40c4fea387f58bc47d90f661cd06cd2e0456c7`，两端一致。两个独立限定包各 264 项隔离回归通过，重叠不相加，见 [开发](development.md#开仓初筛退役止盈选择与策略确认2026-11-03)。
- 备份与结果在 `/opt/trade-tools-integrated/backups/integrated-20261103-retire-entry-ema-2d2d93f13dbf/`（0700），保存前版、两个来源清单、原容器、回退命令和结果。无 schema／数据迁移，仅执行 `migrate --check`，沿用上次 LivePositions 的 **334441616-byte** 数据库 gzip 并再次完整解压核验；保存引用，不恢复数据库或重放队列。环境文件的 inode、大小、mtime 与权限未变。
- build 和切换前两次只读核对 RUNNING 命令均为 0；只重建并替换 API／worker，scheduler／market／MySQL／Redis 的 ID 与镜像均未变。六服务 healthy，公网 HTTPS 深度健康 200。API 与 scheduler 的 live／APNs 继续 true，仓位事件／合作方外发／外部入站三个暂停开关继续 false。
- 新 API 与 worker 各自运行禁用 SQL／网络的实际视图替身检查：EMA 路由 404，原开仓别名保留，9 种旧字段形态都直接到原资金／Decimal 计算边界。没有读取初筛缓存或 K 线，没有执行真实交易、划转、撤保护或测试通知；旧已持久化请求的字符串归一化和指纹恢复保留。旧客户端仍主动请求初筛时会 404，新开仓需配套更新本轮 iOS；客户端 push 不代表 TestFlight 分发完成。

当前 Compose 使用本版 `compose.integrated.yaml`＋`compose.signal-leverage.yaml`＋`compose.entry-ema.yaml`，第三份 override 将 worker 固定为独立新镜像、scheduler 固定为前版 LivePositions、其他服务固定为实际原镜像，不能漏带而将 worker 改回旧初筛。`INTEGRATED_RELEASE` 使用 API release。回滚执行本次备份中 `rollback.sh`，它只恢复 API／worker 的原镜像与 `current`，保留环境、数据库和其他容器；不执行反迁移、订单重试或数据库恢复。回退后旧初筛会恢复，需同步评估客户端版本。源码交付和手机待验范围见 [本轮记录](changes.md#2026-11-03开仓初筛退役止盈显示与策略二次确认)。

## live 后台持仓卡片限定发布（2026-11-03）

2026-11-03 22:49（北京时间）核验 **47.80.22.243（首尔服务器）** 当前为 `integrated-20261103-position-live-activity-3a1a95e914ba`。仅增加 ActivityKit 注册／注销、登出结束标记、独立注册表及只读持仓后台推送任务。`LIVE_ACTIVITIES_ENABLED=true`、APNs 保持 true；`TRADE_NOTIFICATION_ENABLED`、`EXTERNAL_TRADE_SIGNAL_ENABLED`、`EXTERNAL_SIGNAL_INGEST_ENABLED` 三项继续 false。下方旧发布段落保留各次操作时点，当前版本以本节为准。

- 以 `app-notification-routing-5f05a076af1a` 的实际存档为基线，317 个源文件逐项核对，仅 9 个允许路径变化，其余 308 个保持原样。scheduler 只叠加 settings 引入、独立 live job 和开关注册分支，原有任务编排不变；没有带入完整 Git HEAD 中尚未部署的浮盈任务或交易修改。清单在 release 的 `source-release.json`，归档 SHA-256 为 `10a54e16af1a4238906b276a13e5b42318ec7840d26e4ec8e1e3d469c892225a`，两端一致。限定包 108 项隔离回归通过，详见 [开发](development.md#macd-操作色十字线缩放与-live-持仓卡片2026-11-03)。
- 迁移前新建 `/opt/trade-tools-integrated/backups/integrated-20261103-position-live-activity-3a1a95e914ba/`（0700），保存原环境（0600）、前版路径、来源、容器记录和 **334441616 bytes** 的数据库 gzip；进程返回、完整解压 CRC 和体积校验通过。迁移计划严格只有 `mobile.0003_liveactivityregistration`，只创建独立 live 注册表，执行后 `migrate --check` 通过；不初始化、反迁移或改写既有订单。
- 仅替换 API／scheduler，六服务 healthy，market／worker／MySQL／Redis 的容器 ID 和镜像均未变化。公网 HTTPS 深度健康 200；API 与 scheduler 分别确认新开关 true、三个暂停开关 false、APNs true、新表及迁移存在。匿名新路由 401，内存鉴权替身的无效请求 400；当前注册数为 0，投递／交易所读取替身下 dispatcher 返回 0，零发送、零交易所调用。未创建假 token、发送真实通知或执行交易／资金／保护单操作。

Compose 继续使用本版 `compose.integrated.yaml`＋`compose.signal-leverage.yaml` 和对应 `INTEGRATED_RELEASE`。兼容代码回退读取备份中的 `previous-release`，只切回 API／scheduler 及 `current`；新增表保留，不能以数据库恢复或反迁移回退代码。部署脚本的启动失败回退仅恢复旧镜像，保留新增表及 live 环境开关（旧代码忽略该项），不覆盖原三个暂停设置；计划回退前应评估并结束已展示的活动、停用 live 调度。回滚不会撤回已送达的系统卡片。

此前 `15b4784` 已推送，本轮新源码保留本地，尚未提交／推送或手动上传 TestFlight。新签名包的活动 token、`liveactivity` topic 苹果接受、锁屏／灵动岛及长时间后台更新仍待 iPhone 验收；服务器健康不代表手机已收到。客户端生命周期及系统预算边界见 [持仓浮窗](ios-floating-positions.md#activitykit-live-持仓卡片2026-11-03源码实现)与[通知](signals-and-notifications.md#activitykit-live-持仓卡片2026-11-03源码实现)。

## 外部接收暂停与 App 通知分流（2026-11-03）

2026-11-03 21:57（北京时间）核验 **47.80.22.243（首尔服务器）** 当前为 `integrated-20261103-app-notification-routing-5f05a076af1a`。`EXTERNAL_SIGNAL_INGEST_ENABLED=false` 已应用到 API／scheduler；开平仓总开关与合作方发送开关继续 false，APNs 保持 true。普通内部信号走 App；旧外部／Echo 普通信号队列领取时取消，仓位通知以后只移交所属用户 App 队列，暂停期间也不领取已移交记录。浮盈配置和任务编排未变，浮盈自动任务仍未上线。

- 基于上一版 `trade-notifications-off-b14c8dea2898`，限定 314 个源码文件，只有 6 个运行／模板路径与 3 个测试路径变化；scheduler、trend、Compose、全部 migration、交易与保护逻辑逐项哈希保持基线。归档 SHA-256 `66359127ec4d1d366e040a8051adb1fd52617659a29f57bde1140a4201f935c7` 两端一致；完整来源在 release 的 `source-release.json`，不是完整 Git HEAD。限定包 70 项隔离回归通过。
- 备份目录 `/opt/trade-tools-integrated/backups/integrated-20261103-app-notification-routing-5f05a076af1a/` 为 0700，保存原环境（0600）、前版路径、清单和容器记录。无 schema／数据迁移，仅 `migrate --check`；数据库沿用已核验的 `app-push-d277ad4ed87a` 321659196-byte 备份并保存引用。
- 仅 API／scheduler 替换，六服务 healthy，其他四个容器 ID／镜像不变，公网 HTTPS 深度健康 200。两个容器分别核对三个 false 开关与 APNs true；内存鉴权替身下，external 及自报 internal 入站均为 503；数据库领取对象替身确认四类旧外部记录取消且尝试为 0、暂停 App 交易投递不改状态。两个仓位 dispatcher 不读队列，直接 sender 拒绝发送。未发送真实通知、创建信号或执行交易／资金动作。

回滚仍使用前版两个 Compose 文件及前版 `INTEGRATED_RELEASE`，仅切回 API／scheduler 和 `current`。保留三个暂停开关，不整份覆盖环境、不反迁移或重放队列；旧代码不认识新入站开关，代码回退会失去本轮接收暂停保护，需同步评估。客户端源码交付、编译与实机边界见 [开发](development.md#信号红点与通知分流回归2026-11-03)；本次不手动上传 TestFlight，iOS 红点／配色待新包验收。

## 仓位事件通知关闭（2026-11-03）

2026-11-03 16:14（北京时间）核验 **47.80.22.243（首尔服务器）** 当前为 `integrated-20261103-trade-notifications-off-b14c8dea2898`。按用户要求，持久化设置 `TRADE_NOTIFICATION_ENABLED=false`、`EXTERNAL_TRADE_SIGNAL_ENABLED=false` 并应用到 API／scheduler，关闭开仓、平仓、止盈、止损、减仓的内部及合作方通知。原版内部通道无 token、合作方开关为 false，但内部队列仍尝试至 exhausted；新增总开关使暂停期间不领取、不发送、不重试，事件保存保留。普通信号 APNs 仍为 true；浮盈配置未动、自动任务仍未上线。

- 基于紧接下方的 `app-push-privacy-2c242c254dcb`，逐项核对 313 个文件，只改变 `riskon/settings.py`、两个通知适配器、通知回归和环境模板；没有改变交易、持仓保护、结算或任务编排。归档 SHA-256 `98e50d37a29c8d216adb52d77be12070ceb45a86d4774c5af031ff4939be3bad` 两端一致，完整清单在 release 的 `source-release.json`，不是完整 Git HEAD。
- 备份 `/opt/trade-tools-integrated/backups/integrated-20261103-trade-notifications-off-b14c8dea2898/` 为 0700，保存修改前 0600 环境文件、来源和容器记录；数据库沿用已验证的 `app-push-d277ad4ed87a` 备份并保存引用。本轮无 schema／数据迁移，只执行 `migrate --check`，不恢复数据库或重放事件。
- 仅重建 API／scheduler，六服务 healthy，其余四个容器 ID／镜像不变；HTTPS 健康 200。两个实际进程的开关均为 false；使用网络替身核对两个 dispatcher 及两个直接 sender 均不访问 HTTP，队列状态前后相同（4 条 exhausted、外部 0 条）。没有真实开平仓、划转、撤保护单或测试通知发送。本地 39 项隔离回归见 [开发](development.md#仓位通知暂停回归2026-11-03)。

沿用 `compose.integrated.yaml`＋`compose.signal-leverage.yaml` 及本版 `INTEGRATED_RELEASE`。旧版代码不认识总开关，回退代码会失去本次暂停保护，必须同步评估用户的暂停要求；不得直接恢复整份旧环境覆盖后续配置。恢复通知须明确修改对应开关并重新加载 API／scheduler，先核对积压队列及历史 exhausted 记录，不自动重置尝试。源码和记录保留本地，未追加提交／推送或上传 TestFlight。

## APNs 拒绝定位与请求日志修正（2026-11-03）

**47.80.22.243（首尔服务器）** 当前已更新为 `integrated-20261103-app-push-privacy-2c242c254dcb`。相对下方 App 通知限定版，仅修改 `riskon/settings.py` 的 HTTPX／HTTPCore 传输日志配置，防止 APNs 路径中的设备标识进入应用日志；既有交易源码与任务编排未改变。归档 SHA-256 为 `bf0d084fd568b8b9000aa0a78465aa8a079fa90eaa39ff7aa695faaca918365e`，两端校验一致，来源 313 个文件逐项核对。安全回归先复现路径泄露，修正后的限定包 **17 项通过（0.063 秒）**，线上验证两个 transport logger 均为 NullHandler 且不传播。

仅重建 API／scheduler，六服务 healthy、另外四个容器 ID／镜像不变，没有 migration 或交易／资金操作；本轮日志修正复用前一限定版已经验证的数据库备份，不以代码回滚还原数据库。备份目录 `/opt/trade-tools-integrated/backups/integrated-20261103-app-push-privacy-2c242c254dcb/` 保存前版路径、来源、容器记录及备份引用；Compose 文件及仅恢复 API／scheduler 的回滚方式与下方相同。完整源码未提交／推送，未上传 TestFlight。

手机已在 15:26 注册 production 设备，三条测试通知均被苹果拒绝；安全诊断为 HTTP 400／TopicDisallowed。后台确认现有 APNs key 只允许旧 App。用户明确允许后，15:42 在 Apple 后台保留旧 topic 并新增整合 topic，页面确认 key updated、2 Topics / Production，没有更换密钥或撤销旧权限。恢复原三条测试后苹果均返回 200／sent，15:44 用户确认手机 **3 条全部收到**；本次 App 通知实测通过。浮盈任务仍未启用，自然信号触发与长稳不据此验收，详见 [通知](signals-and-notifications.md#普通通知真机测试2026-11-03)。

## App 普通信号通知限定发布（2026-11-03）

2026-11-03 15:21～15:22（北京时间），**47.80.22.243（首尔服务器）** 已更新为 `integrated-20261103-app-push-d277ad4ed87a`。用户要求发送三条普通信号测试通知；实查旧运行版本没有设备注册路由、没有 HTTP/2 依赖且设备表为空，因此先补齐 App 通知链路。

- 以紧接下方的信号／杠杆运行包为基线，逐一核对 313 个来源文件；仅叠加已有提交 `9151efa` 的 `mobile/urls.py`、`auth.py`、`push.py` 和 `requirements.txt`，以及仅含 App 派发任务的 scheduler 局部变更、scheduler 私钥只读挂载 override。既有 scheduler 的所有函数和任务编排在移除新增 App 任务后 AST 完全一致；未带入浮盈任务、交易执行或新 migration。完整清单在 release 的 `source-release.json`，此包不是完整 Git HEAD。
- 归档 SHA-256 为 `4c60ca9424e14c4c5fd74afca3b177269432731350728cce5af08e958abdc970`，两端一致。备份目录 `/opt/trade-tools-integrated/backups/integrated-20261103-app-push-d277ad4ed87a/` 保存前版路径、来源、容器记录及 321659196 bytes 的数据库 gzip，完整性通过；目录 0700、文件 0600。仅执行 `migrate --check`，没有迁移或初始化。
- 仅替换 API／scheduler，六服务 healthy，其余四个容器 ID／镜像不变；HTTPS 健康 200，匿名设备注册 POST 401（路由存在且要求鉴权），scheduler 可读受限 p8。普通 App 信号每 10 秒派发，旧队列两条 Echo 信号记录已取消，尝试次数均为 0；浮盈外发仍未启用。发布前后本地库活动仓位、待成交限价、待提交开仓请求和未决命令计数均为 0。
- 限定包在本机通过 16 项隔离回归，见 [开发](development.md#app-通知限定包验证2026-11-03)。15:22 核对仍无设备，三条测试通知尚未发送；需要手机重新打开 App 完成鉴权注册，再通过独立测试通知事件投递。苹果接受和手机收到分别记录在 [通知](signals-and-notifications.md#普通通知真机测试2026-11-03)，不能互相替代。

本版沿用 `-f compose.integrated.yaml -f compose.signal-leverage.yaml` 和对应 `INTEGRATED_RELEASE`。回滚读取本版备份的 `previous-release`，在前版使用相同两个 Compose 文件及前版版本值，仅恢复 API／scheduler、恢复 `current` 并验证健康；不反迁移、不恢复数据库、不重放已尝试通知。此次发布不上传 TestFlight、不执行交易或资金操作。

## 信号入库与杠杆金额限定发布（2026-11-03）

2026-11-03 12:23（北京时间）核验 **47.80.22.243（首尔服务器）** 当前为 **`integrated-20261103-signal-leverage-0ead6851a38e`**。旧版扫描入口因 `MARKET_ANALYSIS_ALERT_TOKEN` 未配置而整轮跳过，信号库为空；旧杠杆路由只返回标准名义档位。本次更新独立信号入库及每次读取真实可用保证金后的前三档金额，未改变信号触发规则或交易执行。

- 以实际运行的 `integrated-20261102-leverage-api-3fb1859` 为基线，重新核对 **311** 个存档文件。限定叠加 `market_analysis/trend.py`、杠杆视图及回归、`mobile` 新模型／`push.py`／0002 迁移和通知配置读取；313 个发布文件逐文件记录 SHA-256，清单位于 `source-release.json`。未带入工作区的账户流、开仓、保护、结算或调度任务编排修改；该包不是完整 Git HEAD。
- 包 SHA-256 为 `a64875ea17edfe611317c4bee01a04ffa67e8a15eb7b9f6a9cd01dc7728de13e`，两端一致。备份目录 `/opt/trade-tools-integrated/backups/integrated-20261103-signal-leverage-0ead6851a38e/` 为 0700，数据库压缩备份为 0600、317263357 bytes，gzip 完整性通过；保存前版路径、来源、容器 ID 和发布结果。只应用 `mobile.0002_notificationevent_pushdevice_notificationdelivery_and_more`，仅新增设备、通知事件、投递三张表及约束；随后 `migrate --check` 通过，没有初始化、反迁移或交易所写操作。
- 仅重建 API 与 scheduler，六服务 healthy；market、worker、MySQL、Redis 的容器 ID 和镜像与发布前完全相同。旧 scheduler 的订单维护源码与任务编排保持原样，仅其内部信号计算模块改变。发布前后数据库活动订单、待成交限价、未决命令、待提交开仓请求计数均为 0；这只是本地库状态检查，不代替交易所全面审计。
- 实际绑定账户经 API 容器内真实 HTTP／JWT 路由读取 BTCUSDT 杠杆返回 200、**3 项**，金额是有效 Decimal 字符串且按可开金额降序；没有设置交易所杠杆。公网 HTTPS／证书验证与健康均 200。自然调度完成 **56** 条币种／周期序列，`evaluated=56, alerted=0, failed=0`，缓存也有 56 项扫描标记；内部信号 GET 200、当前 0 条。当轮没有规则触发，未插入测试消息或补造历史信号，下一次真实触发的生产入库／手机显示仍待自然验收。
- 本包仅包含信号保存及通知排队依赖，**没有启用通知 dispatcher、设备注册路由或浮盈外发任务**；投递尝试为 0，不能称为 APNs／Echobell／浮盈通知已完整上线。完整通知发布仍需配套路由、依赖、任务、密钥挂载及 `positions.0029`，见 [通知](signals-and-notifications.md)。客户端、测试与文档保留本地，未提交／推送或上传 TestFlight。

该 release 的 Compose 操作使用 `-f compose.integrated.yaml -f compose.signal-leverage.yaml`，指定本版 `INTEGRATED_RELEASE`；override 固定 market／worker 的原镜像，不沿用前版将 scheduler 固定旧镜像的 override。回滚时读备份的 `previous-release`，在前版使用其 `compose.api-leverage.yaml` 和对应 release 值，仅恢复 API／scheduler，然后恢复 `current` 并验证健康。新增三表可保留，不能以反迁移或恢复数据库撤销代码发布；代码回滚后信号扫描恢复旧限制。客户端本地验证见 [开发](development.md#图表账户反馈回归2026-11-03)。

## 通知配置准备（2026-11-02）

2026-11-02 23:15（北京时间）已在 **47.80.22.243（首尔服务器）** 保存本轮通知所需配置，没有部署源码、应用迁移或重启容器。`current` 仍为 `integrated-20261102-leverage-api-3fb1859`，六服务只读核对均 healthy；当前进程未加载新增参数，不能将此记录写成 APNs／Echo 已上线或手机通知通过。

- Echo 地址来自用户本轮提供，浮盈接收范围使用整合库当前唯一有效绑定用户。环境文件 `/opt/trade-tools-integrated/server.env` 保持 0600，只增加／更新通知配置项，不公开地址或密钥。
- APNs 材料从原 iOS 项目只读取得，核对现有 P-256 私钥、Key 标识及团队与整合 Xcode 工程一致；topic 指向整合应用。p8 保存在 `/opt/trade-tools-integrated/secrets/AuthKey.p8`，目录 0700、文件 0400、UID 10001，配套 Compose 仅给 scheduler 只读挂载；未改变原项目文件。
- 首次 Echo 配置前环境备份为 `/opt/trade-tools-integrated/backups/notification-config-20261102-231232/server.env`；加入 APNs 前再次备份到 `notification-config-apns-20261102-231520/server.env`。备份目录 0700／文件 0600。回退配置须按上述阶段选取备份，保留其他后续配置；恢复文件不改变正在运行进程的环境。
- 后续完整通知发布须包含新依赖、`positions.0029` 的仅新增模型迁移及 API／scheduler 配套路由、任务与挂载；`mobile.0002` 已在 2026-11-03 信号限定发布应用，不能再把其完成当作整套通知已上线。代码回滚保留新增表，不重放已尝试通知。真实后台送达另作验收，本轮没有发送测试通知或执行交易／资金／保护单操作。配置及本地验证见 [配置](configuration.md#ios-信号和浮盈通知)、[通知](signals-and-notifications.md) 与 [开发](development.md#图表持仓杠杆与通知回归2026-11-02)。

## 自动杠杆只读接口补发（2026-11-02）

2026-11-02 20:18（北京时间）核验 **47.80.22.243（首尔服务器）** 当前为 **`integrated-20261102-leverage-api-3fb1859`**。此次修复客户端已有杠杆面板请求 404：旧运行版本未包含 `GET /v1/trade/leverage-brackets`，不是档位计算失败。以下账户、市值及其他发布记录为历史基线。

本次是限定范围的 API 发布，不代表整个 GitHub HEAD 已部署。以旧线上 **`171be8d74c506dc950be2395bf6e55ee57a7acc2`** 为后端基线，逐文件核对 306 个后端／部署文件与运行存档一致；仅叠加 `3fb1859` 的杠杆视图、路由、兼容测试和 `get_leverage_bracket` 中的完整档位字段，再加入本轮 URL 鉴权／拒绝 POST 回归。适配器只增加 `brackets`，保留基线其余方法；没有带入共享工作区的账户流、scheduler 等其他修改。`source-release.json` 记录来源、基线、限定路径、方法范围及每文件 SHA-256，不把混合来源归档标成完整源码提交。

- 归档 SHA-256 为 `301ad15038a23cfc662446e0e2fd25116ace95305e41a44775db869330c7a6dd`，远端核验通过。备份位于 `/opt/trade-tools-integrated/backups/integrated-20261102-leverage-api-3fb1859/`，目录 700、数据库压缩备份 600、291471834 bytes，gzip 完整性通过；前版 release／镜像保留。
- 无 migration 变化，仅执行 `migrate --check`；没有初始化、反迁移或生产交易写入。发布前后各有 1 个活动仓位，待成交限价、未决命令和待提交开仓请求均为 0；检查仅为数据库计数，不等于交易所持仓全面审计。
- 仅重建 API 容器。release 中 `compose.api-leverage.yaml` 将 market／worker／scheduler 固定为前版镜像；其余五个服务的容器 ID、镜像和 healthy 状态前后完全一致。六个服务均 healthy，公网健康接口 200，匿名杠杆请求由 404 变为预期 401；在 API 容器内通过实际 HTTP 路由和当前绑定账户完成 BTCUSDT 签名只读查询，200 返回 12 档、最高 150 倍，金额仍为 Decimal 字符串。

该限定 release 的 Compose 操作须同时使用 `-f compose.integrated.yaml -f compose.api-leverage.yaml` 并指定对应 `INTEGRATED_RELEASE`，以保留后三个服务的镜像。若需回退本次接口，先读取备份的 `previous-release`，在前版 release 中以其版本值执行 `docker compose ... up -d --no-deps --no-build --wait api`，再恢复 `current` 并检查健康、认证与 WSS；无需还原数据库或改变现有订单。后续正常完整发布重新从确定源码生成存档，不把该限定包视为完整 `3fb1859`。

客户端的时间／价格标签与纵排杠杆卡片仍为本地修改，未提交、推送或上传 TestFlight；验证及手机待验范围见 [开发](development.md#十字光标标签与杠杆面板回归2026-11-02)。

## 账户归集与服务器自选配套发布（2026-11-02）

2026-11-02 16:47（北京时间）最后核验 **47.80.22.243（首尔服务器）** 当前为 **`integrated-20261102-git-171be8d74c50`**，来源提交 **`171be8d74c506dc950be2395bf6e55ee57a7acc2`**。界面与初版后端提交为 `8a5c6ea`，后续 `171be8d` 修正公共市值接口限流；两者均已推送 `codex/integrated-ios`。下方三分钟及资金发布保留为历史基线。

- 初版发布前逐个核对 305 个已追踪后端／部署文件，除旧归档缺少 `.dockerignore` 外，均与原线上基线一致；随后只从确定提交导出发布。最终归档 SHA-256 为 `b03c6564563957b454610882f14a13fbf610562de102b7d1f1b5fe60a4a6bf98`，远端校验通过；`current`、`source-release.json` 和四个 Python 镜像对应最终提交，六个容器均 healthy。
- 初版应用 `market_stream.0005_watchlist_and_market_cap`，只新增用户自选与公共市值两张表；最终修正版无待应用迁移。最终数据库备份为 `/opt/trade-tools-integrated/backups/integrated-20261102-git-171be8d74c50/database.sql.gz`，目录 700、文件 600、300459099 bytes，发布前 gzip 完整性通过；同目录保留来源及前版路径 `integrated-20261102-git-8a5c6eabd91a`，原三分钟版本也保留。
- 初次公共采集遇到 429，实测响应要求等待 60 秒；改为批间 13 秒及有上限的重试。修正后仅清除已诊断、无成功快照的首次失败时间，再调用正式采集函数初始化，没有改写交易数据。16:44:52 开始的完整快照成功覆盖 522 个合约中的 505 个，其余 17 个无有效市值排在末尾；后续每七天更新，失败保留快照并退避，规则见 [行情](market-data.md#自选持久化与市值排序2026-11-02)。
- 无绑定 QA 公网核验：HTTPS 健康 200、自选写入／读取顺序一致并恢复原可见列表、522 项目录市值降序、BTC 3m 历史 200；鉴权 WSS ready、ETH ticker、订阅 ack 与应用心跳通过。QA 原用默认列表时，恢复结果会显式保存该列表；不涉及真实绑定账号资金。证据位于忽略目录 `.integration-runtime/InterfaceRefinement/`。
- 手动止盈只改变当前用户以后开仓使用的默认策略，不修改已有订单策略快照、保护单或持仓；本次没有真实开平仓、划转或撤单。新增表与旧代码兼容，代码回滚保留自选／市值数据，不反迁移；回到三分钟旧版后，新自选写入与手动默认项接口不可用，需同步考虑客户端功能。iOS 本地构建与手机待验范围见 [开发](development.md#账户归集服务器自选与图表修正2026-11-02)，没有以服务器通过代替 TestFlight 或 iPhone 16 Pro Max 验收。

## K 线三分钟配套发布（2026-11-02）

2026-11-02 14:22（北京时间）最后核验 **47.80.22.243（首尔服务器）** 当前为 **`integrated-20261102-git-e57289609d41`**，来源提交 **`e57289609d414b3a84509cfaf33f11309c1a8c13`**。以下先前账户资金发布及 2026-11-01 记录保留为历史基线。

- 发布前发现线上已从 `b849f17` 更新为 `ac93920`，旧基线校验在任何变更前中止。重新以当前线上 `ac939205db9df4e27cfe2877d61a22b8883cd24d` 为基线，仅叠加本任务四个 `market_stream` 文件；发布包全部后端／部署文件逐个与本次完整提交核对一致，归档 SHA-256 为 `7092ad98847214cd24833a9979cbd28b9ae1e6601de67487a5517a9c20f2ccaa`，远端校验通过，来源写入 `source-release.json`。
- 发布前／后只读核对各有 1 个绑定，活动仓位、待成交限价、未决命令和开仓请求均为 0。数据库备份位于 `/opt/trade-tools-integrated/backups/integrated-20261102-git-e57289609d41/database.sql.gz`，600 权限、260820019 bytes，gzip 完整性通过；前版 `integrated-20261102-git-ac939205db9d` 及镜像保留。本次无待应用 migration，保留既有账户、资金接口、配置、订单及保护规则。
- `current` 与四个 Python 镜像对应本版，六服务 healthy、HTTPS 健康 200。无绑定 QA 通过既有 HTTPS CONNECT 代理读取 BTC3m／300 根，开盘时间升序、无重复且对齐 180000 ms，最终单次完整响应 499.99 ms；`historyPending=false`，统计无待补。单次冒烟不代表手机首帧或延迟分位数。
- 鉴权 WSS 直连的 ready、3m／1m 订阅 ack、应用 ping／pong、1m 实时 K 线与一次 3m 对齐收盘事件通过。首轮 30 秒未跨收盘边界；第二轮脚本长等待漏续应用心跳被 1013 关闭，修正脚本后跨桶验证通过。没有修改产品心跳或用合成事件代替生产公共行情。
- 客户端／后端源码已推送 `codex/integrated-ios`，本轮本地构建与替身 UI 见 [开发](development.md#图表下单与周期回归2026-11-02)。未执行真实开平仓、划转或撤保护单；Apple 构建／TestFlight 分发与手机安装待另验。回滚代码不会还原数据库；回到前版后 3m 不受支持，客户端需选择旧有周期。

## 最新发布与核验（2026-11-02，资金界面配套）

2026-11-02 14:03～14:07（北京时间）发布并核对 **`integrated-20261102-git-ac939205db9d`**，位于 **47.80.22.243（首尔服务器）**，后端源码提交 **`ac939205db9df4e27cfe2877d61a22b8883cd24d`**。本次发布只包含该提交的后端与部署文件，不包含同工作区另一图表任务的未提交改动；后续共享 Git 分支的客户端 / 文档提交不自动改变此运行版本。

- 发布归档 SHA-256 两端一致；`current`、四个 Python 镜像与 `source-release.json` 均对应该版本。数据库压缩备份位于 `/opt/trade-tools-integrated/backups/integrated-20261102-git-ac939205db9d/`，权限 600，同目录保存前版路径、来源与变更哈希；前版 `integrated-20261101-git-b849f175f4a1` 保留。
- 发布前两次只读核对交易所真实持仓、普通挂单和条件单均无；本地活动订单 / 委托及 PENDING / RUNNING / UNKNOWN 命令为 0。有 1 个普通活动绑定、1 笔旧归集待确认，不读取或执行该流水的后续资金动作。
- 仅应用 `trading.0016_capital_wallet_operation`，新增动作与请求 UUID；旧动作为数据库空字符串默认值，UUID 可空，旧代码写入兼容。发布后旧活动归集仍为 1、新动作活动流水为 0；迁移不访问交易所或划转资金。回滚保留新增列 / 索引，不能反迁移或删流水；有新待确认动作时先核对，旧版没有新动作的恢复入口。金额及旧链边界见 [资金](capital-and-transfers.md#原生划转与转账2026-11-02)。
- 六容器 healthy，HTTPS 健康 200；无绑定 QA 验证两个新端点均返回“请先绑定 Binance API”，带单路径拒绝；鉴权 WSS ready / ping-pong 通过。历史端点对无绑定 QA 按既有规则拒绝，首次冒烟脚本误期望 200，改为核对绑定拒绝后完成；不把这次检查写成绑定账号历史或真实划转验收。
- 本次没有真实开平仓、划转、撤保护单、人工接管或策略修改。iOS 交付及 Release / 模拟器范围见 [变更记录](changes.md#2026-11-02账户与资金归集重设计)，Apple 打包、TestFlight 上传 / 安装和实机资金动作待验。

## 最新发布与核验（2026-11-01）

2026-11-01 22:16～22:22（北京时间）更新为 **`integrated-20261101-git-b849f175f4a1`**，位于 **47.80.22.243（首尔服务器）**，后端源码提交 **`b849f175f4a142a1de65f8cb9769f31cd29d957c`**。配套客户端共用交易对列表、自选与开仓状态修复；同批交付历史仓位快照。下方 16:42 发布改为历史基线。

- 从确定 commit 导出后端／部署文件，上传归档 SHA-256 核对通过；`current`、四个 Python 镜像与 `source-release.json` 对应该版。发布前只读核对绑定、活动仓位、待成交委托及未决命令均为 0。
- 受限备份位于 `/opt/trade-tools-integrated/backups/integrated-20261101-git-b849f175f4a1/`，包含 600 权限数据库压缩备份（238445308 bytes）、前版路径和来源／变更哈希；前版 `integrated-20261101-git-7daa36228c9f` 及镜像保留。新增 `market_stream.0004_marketsymbol` 只建公共目录表，代码回滚可保留该表，不能用代码回滚还原交易数据库。
- 新目录已保存 **522** 个活动 USDT 永续合约。六服务 healthy；本次 Compose 应用此前已在线调整的 MySQL 1 GiB／含 swap 2 GiB 配置并重建 MySQL，数值复核为 1073741824／2147483648；Redis 保留。没有真实开平仓、划转、撤保护单、订单策略或账号密码变更。
- HTTPS 深度健康 200，服务器回环 HTTPS 约 52～55 ms。无绑定 QA 公网验证目录、默认自选同目录、旧搜索分页字段和历史本地快照；目录单次 186.72 ms、空历史 325.05 ms，均为本机经现有 HTTPS CONNECT 代理的冒烟样本，不是手机／实际绑定账号分位数。鉴权 WSS 直连的 ready、订阅 ack、ETH ticker 和 ping-pong 通过。
- 本机直连 HTTPS 两次超时、WSS 经代理首次握手超时后，分别改用上述链路完成验证；SSH 传输重试后归档和来源均核对。未因本机链路抖动改生产网络配置或清空行情缓存。客户端与交付文档按本次用户授权推送，Apple 打包／TestFlight 分发和手机安装另验。


2026-11-01 16:42～16:44（北京时间）当前更新为 **`integrated-20261101-git-7daa36228c9f`**，位于 **47.80.22.243（首尔服务器）**，后端源码提交 **`7daa36228c9ff48637439da9d8e3cb5d229fdc4d`**。本次用户授权为手机测试直接推送客户端；配套部署诊断接收、冷读减量及此前已交付的行情读取协调／公共出口保护，按现有部署授权执行。下方 14:20 发布为历史基线。

- 发布包从确定 Git commit 导出，SHA-256 两端一致；`current`、四个 Python 镜像、release／备份中的 `source-release.json` 均对应本版。后续部署验收文档提交不改变该后端源码。
- 发布前只读核对 API 绑定、活动仓位、待成交委托和 PENDING／RUNNING／UNKNOWN 命令均为 0。备份位于 `/opt/trade-tools-integrated/backups/integrated-20261101-git-7daa36228c9f/`，含数据库逻辑压缩备份、`previous-release`、来源和变更哈希，权限受限。兼容回滚目标 `integrated-20261101-git-90911798159b` 及镜像保留；回滚代码不恢复数据库。
- 唯一待应用 migration `market_stream.0003_chartloadreport` 已完成，仅新增诊断表；初始化检测已有用户，不改账号密码，注册仍开启。六容器 healthy、HTTPS 深度健康 200。
- 无绑定 QA 公网读取 BTC1h／1500 根，gzip 完整接收 709.45 ms，history 277.84 ms，无 stale／pending；合法 trace／request 和服务端时间头正确。该单次冒烟不等于手机首帧或稳定分位数。鉴权 WSS ready／订阅 ack／BTC ticker 与 1m K 线事件／ping-pong 均通过。
- 诊断固定样本使用 build `0`／cancelled，鉴权 POST 两次均 200、数据库同 trace 只存一条，匿名 POST 401；这是接口与落库验收，不是手机呈现样本。未执行真实交易。
- 源码交付分支为 `codex/integrated-ios`，按本次授权推送以交给用户既有 Jenkins／Apple 打包流程；本轮不修改其配置，不把 GitHub 推送当作云端完成、TestFlight 可安装或手机测试通过。


2026-11-01 14:20～14:22（北京时间），按用户本次“全部推送并部署”授权，将整合 GitHub 分支 `codex/integrated-ios` 的源码提交 **`90911798159bd08d17fd369193bb83c7c0e7711b`** 发布到 **47.80.22.243（首尔服务器）**。当前版本为 **`integrated-20261101-git-90911798159b`**，`current`、四个 Python 容器镜像及 release 内 `source-release.json` 均对应这一版本。下方先前发布记录保留为历史，不表示仍运行旧版。

- 从确定 Git commit 导出已追踪的后端、Compose 和部署文件；上传包 SHA-256 已与本地核对。后端源码与此前 range 版内容清单相同，本次为建立 Git／运行版本对应而发布，没有追加交易逻辑改动。
- 发布前逻辑备份及 `previous-release` 保存在 `/opt/trade-tools-integrated/backups/integrated-20261101-git-90911798159b/`，目录 700、备份 600。兼容前版为 `integrated-20261101-kline-range-6413a8768d2b`，保留其源码和镜像；代码回滚不会恢复数据库。
- migration 输出为无待应用项；空库初始化确认已有用户，不修改账号密码。六容器均 healthy，HTTPS 深度健康 200；无绑定 QA 的鉴权 WSS ready、订阅 ack、应用 ping／pong、BTC ticker 与 1m K 线事件通过。注册开关仍为 true。
- 公网 gzip 单次读取：BTC1h 1500 根约 66.45 KB／853.58 ms，BTC1m 1500 根约 53.02 KB／1369.92 ms；时间是完整网络响应，均非 stale／pending，时间升序且无重复。这是发布冒烟样本，不是首帧或稳定性分位数。
- 全部 iOS、鸿蒙及文档源码已推送。iOS 使用此前同内容的 145 项图表／快速路径回归与 Release 无签名构建证据，本次新增后端 69 项、鸿蒙 40 项及工程检查通过。没有重新上传 TestFlight、签名鸿蒙 HAP 或安装手机；GitHub 推送可能触发既有 Xcode Cloud，Cloud 处理与手机版本未核实。

## 当前部署结构

- `/opt/trade-tools-integrated/releases/<内容版本>`：发布源码；`current` 指向当前 API／主要 Compose 版本。各服务可以使用不同限定基线镜像，须同时核对实际容器及当次 override，不能据此推定四个 Python 进程均为同一源码版本。
- `/opt/trade-tools-integrated/server.env`：600 权限的独立配置，各 release 通过链接读取。
- Compose 项目 `tradetools-integrated`，使用 `--profile pro`；API、market、worker、scheduler、MySQL、Redis 共六个服务，仅使用项目默认网络。
- API 仅发布 `127.0.0.1:8787`。MySQL、Redis 不发布宿主端口，使用各自命名卷 `integrated-mysql`、`integrated-redis`。
- MySQL 8.4 镜像在 Compose 中固定 digest，独立 `tradetools_integrated` schema / `tt_integrated` 用户，当前内存 1 GiB、内存加 swap 总限额 2 GiB；本次在线调整和后续发布配置见 [压力恢复](#mysql-内存限额与压力恢复2026-11-01)。应用不再依赖 `trade_mysql` 或 `trade_network`。
- 宿主 Nginx 为 HTTPS / WSS 代理，仅 `/integrated/` 指向 API；旧根路径和 `/ws/` 返回 404。
- 保留 Docker / containerd、Nginx、`/opt/certbot` 和有效 TLS 证书，它们现在支撑整合版。

前版为 `integrated-20261101-pruned-8ff1d7379c22`，2026-11-01 12:31（北京时间）在 47.80.22.243（首尔服务器）确认六个容器 healthy、HTTPS 健康 200、鉴权 WSS 声明 `market.history` 与一次应用层 ping / pong。它包含此前 `74b8e5d` 的行情优化、WSS 鉴权连接清理，以及本地看盘计划／校准问答的运行逻辑退役；发布名末尾为后端与部署文件内容清单的 SHA-256 前缀，不代表 Git 提交。源码未提交或推送。用户安排先不测试，手机速度和完整功能待其验收；客户端本轮修改仅保留本地，不能把本次部署当作手机升级。

12:17 行情发布前核对 API 绑定、活动仓位、待成交限价及 PENDING / RUNNING / UNKNOWN 命令均为 0；当时迁移只新增 `market_stream.0002_markethistorytask`，不修改交易表或已有账户密码。数据库逻辑备份、原 release 路径与 WSS 修正文件 SHA-256 位于目标机受限目录 `/opt/trade-tools-integrated/backups/integrated-20261101-74b8e5d-wss/`；不得上传其中数据库内容。保留原 `integrated-20261031-d2498172efa6` release / 镜像用于兼容回滚；API / market 必须成对切换，代码回滚不还原数据库。

随后退役功能发布前再次核对绑定、活动仓位、待成交限价及未决命令均为 0；执行 `users.0009_retire_watch_calibration`，其数据库操作为空，仅删除 ORM 状态，历史 nullable 列和计划表继续保留。新备份及前版路径存放于 `/opt/trade-tools-integrated/backups/integrated-20261101-pruned-8ff1d7379c22/`，可回滚前版为 `integrated-20261101-74b8e5d-wss`。代码回滚不自动反迁移；新库回到包含计划模块的旧代码时，需要使用旧版迁移补建计划表，见 [功能退役](research.md)。

此前完整部署与行情验收基线为 2026-10-31，范围见 [变更](changes.md)。

2026-11-01 13:26（北京时间）当前版本更新为 **`integrated-20261101-kline-range-6413a8768d2b`**，位于 47.80.22.243（首尔服务器）。本轮先发布 gzip 版 `integrated-20261101-kline-gzip-0afeeba67c44`，再经分段测量修复当前部分桶多读 3000 根分钟线；相对前版只改变公共行情响应压缩、当前桶读取范围及对应测试，没有新增 migration 或修改交易规则。两次发布均显示无待应用迁移，保留账号与配置。

最终版六容器 healthy、HTTPS 深度健康 200、无绑定 QA 鉴权 WSS ready／六次 ping-pong 通过；1500 根 BTC／ETH／SOL 及统计读取有响应，实测范围和抖动见 [行情](market-data.md#测量与结论边界)。这不等于物理手机或 TestFlight 通过。源码、客户端均未提交／推送／分发。

最终发布备份位于 `/opt/trade-tools-integrated/backups/integrated-20261101-kline-range-6413a8768d2b/`，包含受限数据库逻辑压缩备份、`previous-release` 和变更文件哈希；前置 gzip 版备份位于同级同名目录。当前兼容回滚候选为 gzip 版及 pruned 版，均保留原 release／镜像；代码回滚不会恢复数据库。本轮未修改 Nginx 全局配置、凭证、保护单或既有交易策略。

随后执行首屏交接计划，2026-11-01 13:43～14:04（北京时间）仅只读核对 47.80.22.243（首尔服务器）：`current` 与运行 API 仍为 range 版，六容器 healthy，内部健康 200／约 13 ms；真实 gzip、不同币种／周期和 ZEC／SOL 按需补线完成状态已复核，范围见 [首屏补验](market-data.md#按首屏交接计划补验2026-11-01)。本轮没有修改服务器配置、清空 Redis、迁移或重新发布。新增客户端分页恢复修复仍在本地，手机 TestFlight 12 未升级；不能将此轮验收当作新的后端或客户端部署。

## MySQL 内存限额与压力恢复（2026-11-01）

本次 16:42～16:44 发布初期六容器及接口通过；后续检查发现 47.80.22.243（首尔服务器）的 MySQL 接近旧 512 MiB cgroup 上限并持续回收，数据库和应用健康检查随后超时。现场 `memory.current=536489984`／`memory.max=536870912`，`memory.events.max=355300`，PSI full avg10 为 89.79%，MySQL CPU 约 194.55%；没有 OOM kill 或数据库重启。宿主仍有约 1.9 GiB 可用内存，不能把它误判成主机内存已耗尽。

先暂停公共 market 减少请求，再用 `docker update --memory 1g --memory-swap 2g tradetools-integrated-mysql-1` 在线增加限额；没有重启 MySQL、修改数据库卷／账号／订单或调整交易规则。阻塞的诊断查询立即完成，确认同 trace 只有一条 build 0 样本、注册仍开启；随后恢复 market。

恢复采集后的 30 秒观察：cgroup 约 609～612 MB，已超过旧限额；`memory.events.max` 保持 384713、没有新增限额命中，PSI some／full avg10 均为 0。随后再次验证 HTTPS 健康、BTC1h 1500 根 gzip（单次 633.84 ms，history 171.37 ms，无 stale／pending）、诊断提交／重复上报及 WSS ready／ack／ticker／1m K 线／ping-pong。该短观察不能代替长期容量验收，也不能据此宣称最初 TestFlight 13／14 的慢加载只有这一个原因。

当前部署源码仍为 `7daa362`；此次数据库内存采用在线更新，release 存档中的原 Compose 作为来源证据保留。本轮源码 `compose.integrated.yaml` 已将 MySQL `mem_limit: 1g`、`memswap_limit: 2g` 固化，并在 47.80.22.243（首尔服务器）通过实际 Compose `config --quiet` 校验。后续发布使用更新后的 Compose；回滚 Python 代码也必须保留至少该内存限额，不能把旧 512 MiB 设置重新应用到运行容器。备份中的 `compose-memory-1g.yaml` 仅作本次校验证据，不另立部署手册。

## 注册开关

注册状态存于 `users.SystemSetting` 的 `open_registration` 数据库项，`1` 为开启，默认关闭；不属于 `server.env` 配置。匿名 `GET /v1/auth/admin-settings` 可读取当前状态。2026-11-06 已随[完整同源发布](#完整同源发布2026-11-06)将写权限收紧为有效登录邮箱 `qqqqqq@qq.com`，不继承其他管理员标志；本轮没有改变持久化的开关值。新版本可在 App 设置或通过同路径的鉴权 `POST` 提交 `{"open_registration": true}` / `false` 修改，重启和代码发布不重置已有设置。

2026-11-01 03:04（北京时间）在 47.80.22.243（首尔服务器）核对六个整合容器均 healthy、当前发布仍为 `integrated-20261031-d2498172efa6`，再经 SSH 在现有 API 容器调用 `SystemSetting.set_open_registration(True)`，只改变这一设置。匿名公网状态返回 true、HTTPS 健康检查为 200；未重建容器或执行真实注册、邮件发送及交易操作。管理员需要关闭时修改同一设置即可。

## 初次配置与发布

源码必须先审阅并放入独立 release。首次运行 `python3 deploy/integrated/prepare_host.py`，生成随机应用密钥、数据库密码与初始管理员资料，并启动独立 MySQL，由官方镜像初始化 schema / 用户。已有 `server.env` 时拒绝覆盖。管理员仅在用户表为空时创建，不重置已有密码；默认不开放注册。

在 release 中运行：

```bash
bash deploy/integrated/release.sh
```

脚本构建应用镜像，等待独立 MySQL / Redis 健康，执行 Django 版本化 migration、空库管理员初始化，再启动四个 Python 进程并更新 `current`。发布前评估迁移与旧代码兼容性；不要打印完整 env、容器环境或凭证。

## HTTPS 与证书续期

47.80.22.243（首尔服务器）的当前文件对应关系：

| 源文件 | 安装位置 |
| --- | --- |
| `deploy/integrated/nginx-site.conf` | `/etc/nginx/sites-available/tradetools-integrated`，由同名 sites-enabled 链接启用 |
| `deploy/integrated/nginx-location.conf` | `/etc/nginx/snippets/tradetools-integrated.conf` |
| `deploy/integrated/cert-renew.service` / `.timer` | `/etc/systemd/system/tradetools-integrated-cert-renew.service` / `.timer` |
| `deploy/integrated/reload-nginx.sh` | `/etc/letsencrypt/renewal-hooks/deploy/tradetools-integrated-reload.sh`，权限 755 |

站点模板定义 WSS Upgrade 的 map，与 location 配套更新；配置修改后先 `nginx -t`，通过才 reload。80 端口保留 ACME challenge，其他路径转 HTTPS。ACME webroot 为 `/var/www/tradetools-integrated-acme`，续期配置中的 webroot 必须一致。

有效 IP 证书沿用 Certbot lineage `trade-tool-seoul-ip`，证书 / 私钥仍位于 `/etc/letsencrypt/live/trade-tool-seoul-ip/`。这个历史名称仅标识证书，不代表 Java 系统仍存在。不要手工改名证书目录或关闭 TLS 校验。新的 `tradetools-integrated-cert-renew.timer` 每六小时检查，成功续期后 deploy hook 检查并 reload Nginx。

```bash
nginx -t
systemctl status tradetools-integrated-cert-renew.timer
systemctl start tradetools-integrated-cert-renew.service
```

普通 renew 成功只表示本轮命令完成；未到续期时间可能跳过签发。2026-10-31 已在 47.80.22.243（首尔服务器）执行 `certbot renew --dry-run --run-deploy-hooks --cert-name trade-tool-seoul-ip`：ACME staging 模拟续期及 deploy hook 检查 / reload 均成功；没有将 staging 证书替换为线上证书。以后改动 webroot 或站点时需复验该流程。

## HTTPS 传输拥塞控制（2026-11-01）

47.80.22.243（首尔服务器）原宿主默认 CUBIC，在实际手机链路出现重传、缩窗和发送排队。先用一个带 10 分钟自动撤销的目的地址路由指标做 BBR 对照，保持网关与全局默认不变；内核确认手机新连接为 BBR，构建 15 三次 BTC1h 首帧为 503.60／433.48／453.03 ms，用户反馈零点几秒。详情及未覆盖范围见 [行情排查](market-data.md#构建-15-真机传输排查2026-11-01)。

随后固化宿主默认 BBR，不改变既有 `fq_codel`。持久配置与当前交付模板对应：

| 源文件 | 安装位置 |
| --- | --- |
| [network-modules.conf](../deploy/integrated/network-modules.conf) | `/etc/modules-load.d/tradetools-integrated-network.conf` |
| [network-sysctl.conf](../deploy/integrated/network-sysctl.conf) | `/etc/sysctl.d/99-tradetools-integrated-network.conf` |

取得包含这两个模板的源码后，以 root 从源码根目录执行；先确认目标文件是否存在并备份，保留其他网络设置。宿主配置独立于容器 release，不由当前 `release.sh` 自动安装。

```bash
modprobe tcp_bbr
install -m 644 deploy/integrated/network-modules.conf /etc/modules-load.d/tradetools-integrated-network.conf
install -m 644 deploy/integrated/network-sysctl.conf /etc/sysctl.d/99-tradetools-integrated-network.conf
sysctl -p /etc/sysctl.d/99-tradetools-integrated-network.conf
sysctl -n net.ipv4.tcp_congestion_control
```

本次安装前两个目标文件均不存在，宿主值为 CUBIC；备份清单和应用结果保存在 `/opt/trade-tools-integrated/backups/chart-transport-probe-20261101/host-network/`。本次仅加载指定 sysctl 文件，没有运行 `sysctl --system`、切换 qdisc、升级内核或重建容器。四个正在运行的 Python 容器网络命名空间默认值复核仍为 CUBIC；宿主默认不是所有既有 socket 的算法，也不能替代容器重建后的核对。

临时目的路由、其回滚状态文件、定时器和 TCP 采样已撤销；Nginx 恢复前原文与 SHA-256 `2752682e40e3ce8d9a599321820ea48e9ad01dbe5b31418fb2589f91045b6e53` 一致，检查及平滑 reload 通过。撤销后独立新建 HTTPS keep-alive 连接，内核明确为 BBR、健康接口 200；六个整合容器 healthy。无绑定 QA 的鉴权 WSS ready、订阅 ack、BTC ticker／1m K 线及应用 ping-pong 也通过。`current` 和镜像仍为 `integrated-20261101-git-7daa36228c9f`，这次是宿主传输配置应用，不能写成新应用版本部署或新客户端分发。文件已配置开机加载，但没有为测试重启宿主，重启恢复与其他网络长稳仍待验收。

取舍与影响范围：宿主默认算法作用于该网络命名空间的新 TCP 连接，范围不限于 K 线或 443 端口；容器和既有连接要分别核对。BBR 不直接改变开平仓、订单维护或资金计算规则，但传输延迟与吞吐仍可能随链路改变，不能承诺所有网络都更快；共享瓶颈下各连接的带宽分配也可能变化。本次三次手机对照支持保留配置，不代表多用户并发或长期稳定性已验收。

当前使用内核自带实现，没有更换自定义内核。保留 `fq_codel` 时，Linux 6.8 BBR 可依赖每 TCP socket 的内部 pacing 定时器，可能增加资源消耗，具体 CPU 增量本次未测量；依据见 [Linux 6.8 实现说明](https://github.com/torvalds/linux/blob/v6.8/net/ipv4/tcp_bbr.c)。后续性能异常需要结合首帧阶段耗时、重传、连接数及 CPU 判断，不能仅凭启用 BBR 推断故障原因。

本次状态的回退方式：先核对上述清单和文件哈希；将运行默认恢复为 `sysctl -w net.ipv4.tcp_congestion_control=cubic`，再删除本次新增的这两个指定文件。若未来已有其他原配置，应恢复其备份。无需反向迁移数据库或重启交易容器；已存在的 BBR socket 不会据此全部切换，回退验证应重新建立连接。不要为了卸载模块强制中断现有业务连接。

## 健康与资源检查

```bash
curl --fail https://47.80.22.243/integrated/v1/health
cd /opt/trade-tools-integrated/current
INTEGRATED_RELEASE=$(basename "$(pwd -P)") docker compose --project-name tradetools-integrated --env-file /opt/trade-tools-integrated/server.env -f compose.integrated.yaml --profile pro ps
```

API 检查数据库、迁移和 scheduler heartbeat；market 检查 flush 心跳与最近 Socket 消息；worker / scheduler 单独检查心跳。六个容器 healthy 不等于所有交易对历史已补完，还需读取真实 K 线 / ticker 事件、eventTime 与历史分页。

只查看必要日志尾部，保护账户信息。`docker stats --no-stream`、`docker system df` 和磁盘检查用于资源排障。禁止盲目执行包含 volumes 的全局 prune；数据库卷和 Redis 卷保存持久数据。

## 更新与回滚

更新使用新 release、受限配置和同一个 Compose 项目，完整交付范围遵守[协作规则](../AGENTS.md#发布与验证)。从确定 Git 提交生成全部后端／部署源码存档，核对四个 Python 服务的完整来源和配套迁移后统一发布；当前配置链见[完整同源发布](#完整同源发布2026-11-06)。用户明确要求限定发布时，才保留完整 override 并固定非目标镜像。不要向来源 USDT Gitee 仓库的 main 推送整合版改动，避免触发来源系统自动部署。

回滚先核对 migration 与目标镜像兼容，保存数据库备份；代码回滚不会还原数据库。兼容时选择保留的 release / 镜像，指定对应 `INTEGRATED_RELEASE` 执行 `docker compose ... up -d --no-build`，更新 `current` 后复验健康、认证和 WSS。不得通过撤单或重发 UNKNOWN 命令实现回滚。

2026-10-31 迁移前的 release 依赖已删除的外部 MySQL / 网络，不能直接作为当前部署的回滚目标。本轮清理后仅保留当前 release 和使用中的镜像；后续发布需要保留兼容的整合版本。数据库灾难恢复必须使用受限备份并评估数据时间点，不能恢复旧 Java 栈来代替整合版恢复。

## 旧 USDC Java 环境退役记录

2026-10-31 在 47.80.22.243（首尔服务器）执行：

1. 核对旧交易账户 / 持仓 / 订单和整合版绑定 / 订单 / 限价单均为 0。
2. 将旧 schema、整合 schema 和配置备份到本机忽略且受限目录 `.integration-runtime/retirement-backup-20261031/`，权限分别为目录 700 / 文件 600；不加入 Git。旧数据不在目标机保留副本。
3. 停止旧 Java / Redis，冻结四个整合 Python 进程写入，最终逻辑导出整合数据库。从源 MySQL 26.7.0 恢复到独立 MySQL 8.4.13；没有搬用物理 data 目录。43 张表共 458,367 行的行数及按主键排序的完整行输出 SHA-256 全部一致，应用密钥、数据库应用密码和账号数据保留。
4. 切换到独立数据库与网络，复验六个服务健康、HTTPS / WSS 后，删除 `trade_app` / `trade_redis` / `trade_mysql`、其镜像、`trade_network`、整个 `/opt/trade-tool`、旧 Nginx 配置 / 日志 / 路由、旧续期 units / webroot、过期整合 release / 镜像和未使用构建缓存。
5. 宿主未安装 Java / JDK / JRE / Maven / Jenkins / MySQL / Redis 软件包；Java 运行时随旧镜像一起删除。Docker / Nginx / Certbot 仍被整合版使用，云厂商 agent 属于主机基础设施，予以保留。

本机最终 dump 的 SHA-256 与远端迁移报告一致；迁移报告 `/opt/trade-tools-integrated/migration-20261031.json` 只含表计数 / 哈希与版本，不含行内容或密码。远端临时 dump 和上传包已删除。数据库备份与应用解密配置必须一起保管，备份中可能含敏感数据，不能上传源码仓库。

## GitHub 源码交付

2026-11-10 用户授权提交推送当前全部未提交改动；提交 `d34be47` 已推送至 GitHub `qoqkeep-create/binance` 的 `codex/integrated-ios`。本批仅包含 iOS 图表恢复、测试和主题文档，没有 `server/` 或 `deploy/integrated/` 文件，因此不触发 47.80.22.243（首尔服务器）部署；本地 81 项 host 回归和主 App Debug 模拟器构建已通过。

2026-11-05 用户授权先提交推送当前全部未提交改动，以 `2c491c2` 为基线沿用独立 Git 元数据交付 `codex/integrated-ios`。范围及已有验证见 [本批记录](changes.md#2026-11-05当前全部改动源码交付)；原 USDT／USDC 来源目录、父 Gitee、凭证、运行证据和 `.build/` 不参与。本次不追加 47.80.22.243（首尔服务器）部署或手动 TestFlight 上传，GitHub 源码与实际运行版本分开验收。

2026-11-03 本次用户明确授权提交推送整合工作区全部未提交内容，以 `df77ba2` 为基线交付周期／auto、六种周期后端及 Super 双主题、MACD 边框、账户与策略界面等源码到 `codex/integrated-ios`；范围和已有验证见 [整批交付记录](changes.md#2026-11-03周期主题与账户策略整批源码交付)。沿用独立 Git 元数据，父 Gitee 及忽略的凭证／构建不参与。本次不追加部署、迁移或手动 TestFlight 上传；47.80.22.243（首尔服务器）的实际版本仍以上方运行记录为准，新增周期后端和手机新包待配套交付。

2026-11-03 后续用户明确要求本轮完成后直接提交推送，以 `dd4f048` 为基线交付策略编辑、指标卡片及透明度、连续 Super 填充、同触点十字线、默认杠杆、账户／持仓界面及普通信号 APNs／浮盈 Echo 分流源码。全部本地验证与范围见 [本批记录](changes.md#2026-11-03策略指标交互与通知分流源码交付)。沿用独立 Git 元数据推送 `codex/integrated-ios`；本次不追加部署、迁移或手动 TestFlight 上传，**47.80.22.243（首尔服务器）** 的运行范围继续以本页实际发布记录为准，完整通知及手机新包待配套验收。

2026-11-03 用户明确授权提交推送当前整合工作区全部未提交内容，本批以 `df1e032` 为基线，将 31 个客户端、测试及文档文件交付 `codex/integrated-ios`，包括其他会话留存的顶部控件、浮窗入口和周期／日期选项。范围与验证边界见 [本批交付记录](changes.md#2026-11-03图表账户反馈与顶部控件整批源码交付)。沿用既有独立 Git 元数据，父 Gitee 仓库及忽略的凭证、备份、构建不参与；本次不追加部署或手动上传 TestFlight。**47.80.22.243（首尔服务器）** 的实际运行代码继续以上方信号／杠杆限定发布为准。

2026-11-02 用户后续明确要求直接提交并推送全部改动，本批以 `d533b19` 为基线交付工作区 21 个文件到 `codex/integrated-ios`，包含此前开仓／持仓切页优化与十字光标／杠杆界面及配套测试、文档。验证证据及未验范围见 [整批交付记录](changes.md#2026-11-02开仓面板持仓缓存与十字光标整批源码交付)。本次不重新部署或手动上传 TestFlight；**47.80.22.243（首尔服务器）** 的运行状态继续以上方 API 限定发布为准，GitHub 全部源码交付不等于所有后端改动已上线。

2026-11-02 用户明确授权提交并推送当前整合工作区全部改动，包含其他会话内容；本批以 `f155c95` 为基线，通过既有独立 Git 元数据交付 `codex/integrated-ios`。范围和各任务已有验证见 [跨会话源码交付](changes.md#2026-11-02跨会话全部改动源码交付)。本次不执行新部署或手动 TestFlight 上传；源码交付不能替代 **47.80.22.243（首尔服务器）** 的运行版本核验，上方最后实际发布记录继续作为部署依据。

2026-11-01 本次用户授权整批提交并推送，收录工作区的界面／延迟、连续纵轴和行情协调／出口保护等全部安全改动，基线为 `fab71ee`；范围与既有验证见 [本次交付记录](changes.md#2026-11-01整批源码提交与-github-交付)。本次不执行服务器部署或手动 TestFlight 上传，源码交付与运行版本分别记录；上方 47.80.22.243（首尔服务器）的最后发布记录继续有效。

2026-11-04 用户授权“完成后全部提交推送”，以 `194d1e7` 为基线交付当前全部安全源码和文档，包含待提交的 iOS 调整与鸿蒙前三批复刻。沿用下方独立 Git 元数据及 `codex/integrated-ios`，父 Gitee、凭证／签名和构建产物不参与。本次只做源码推送，不追加 **47.80.22.243（首尔服务器）** 部署或手动 TestFlight 上传；范围及验证见 [交付记录](changes.md#2026-11-04图表顶部归集筛选与全部待提交源码交付)。

2026-11-04 后续用户授权将自适应高度浮窗与上轮未提交的图表标签／费用／持仓细调一起提交推送；本批基线为 `9a8e545`，继续沿用同一独立 Git 元数据与 `codex/integrated-ios`。只交付 iOS 源码、回归及主题文档，原有 `.build/` 产物不纳入；不追加 47.80.22.243（首尔服务器）部署或手动 TestFlight 上传。范围与验证见 [本批记录](changes.md#2026-11-04浮窗自适应高度与图表细调源码交付)。

整合版仓库为 `https://github.com/qoqkeep-create/binance.git`，分支 `codex/integrated-ios`。自 2026-11-10 起，本机根目录为 `/Users/apple/work/TradeTools-Binance-iOS`，与原 USDT／USDC 来源项目并列，根目录 `.git` 为本项目的独立元数据。迁移沿用原有历史、分支和索引，未重新初始化或复制来源仓库历史。

```bash
cd /Users/apple/work/TradeTools-Binance-iOS
git rev-parse --show-toplevel
git remote -v
git status
git diff --check
```

2026-11-10 搬迁后只读核对：GitHub `refs/heads/codex/integrated-ios` 仍为 `268a529fc16154bd5af27b25b5484927a48a9ea1`，与本地及原跟踪引用一致。最早导入提交 `1118eaa`（2026-10-31）已经直接以 `server/`、`frontend/`、`deploy/`、`docs/` 等为仓库根内容；最早与当前的 iOS 工程路径都是 `frontend/ios-app/TradeTool.xcodeproj`，没有来源父目录或本机项目目录名前缀。首次交付范围即整合工程，Mac 本地搬迁不改变仓库内路径；本轮未推送或修改 Apple 工作流，因此无需仅因本地搬迁调整 Cloud 工程路径。当前云端运行／分发结果不属于这次核对范围。

操作前确认根目录和 origin 属于整合版。普通 clone 同样使用根目录 `.git` 与上述命令。此前嵌套工作副本使用的 `.integration-runtime/github-publish.git` 已移至 `.git`，现行命令不再带 `--git-dir` / `--work-tree`；旧交付记录中的这些参数仅代表当时状态，路径映射见 [迁移索引](sources.md#本地目录独立2026-11-10)。

迁移前的 Git 元数据和工作区差异备份位于本机 `/Users/apple/work/.repo-backups/ios-standalone-20261110-193230/`，权限受限，不纳入交付。原 USDT 仓库会显示旧嵌套路径删除；来源索引、远程和历史保持原样，删除不混入来源发布。本轮仅本地迁移，不提交、推送、部署或触发客户端分发。

Xcode Cloud 必须单独获得指定 GitHub 仓库的访问授权；本机 Deploy key 可推送不代表 Cloud 已获授权。

整合工作区的交付范围以[协作规则](../AGENTS.md#发布与验证)为准；来源目录、父仓库改动与历史不混入。环境文件、私钥、备份、日志、构建和 IDE 用户状态保持忽略。GitHub Deploy key 与目标机 SSH 密钥是不同认证，均不随代码交付。本机 SSH 443 / 代理设置只存于根目录 `.git/config`，凭证路径已随本地搬迁更新；其他机器正常 clone 即可。

推送授权以 [项目协作规则](../AGENTS.md#发布与验证) 为准。2026-11-01 用户明确授权本次 K 线诊断在需要发布客户端时完成后直接推送，并说明由其既有 Jenkins 调用 Apple 打包服务；这是本次任务授权，后续任务仍默认经用户批准再推送。本轮不修改 Jenkins 或 Apple 工作流；推送成功不代表打包、分发或手机安装成功。2026-11-01 的名称 / 图标 / 认证 / 白底启动页及开启注册整批获单次推送授权；验收见 [变更记录](changes.md)。推送可能触发 Xcode Cloud，源码推送与开启注册的授权范围不包含真实交易。

源码推送、47.80.22.243（首尔服务器）的部署和 TestFlight 上传分别记录，不能互相替代。手机签名 / 上传见 [TestFlight](testflight.md)，当前待验收项见 [已知事项](known-issues.md)。

2026-11-02 用户在本地图表／持仓／通知验收完成后授权“提交推送”，本批以 `17a3eda` 为基线交付 51 个文件到 `codex/integrated-ios`，范围与既有验证见 [变更记录](changes.md#2026-11-02图表持仓杠杆选择与通知源码交付)。生产 Echo／APNs 配置和密钥不随源码上传；本次不部署后端、重启服务或手动上传 TestFlight，47.80.22.243（首尔服务器）仍以上方通知配置准备及杠杆限定发布记录为准。

## 图表加载诊断

2026-11-07 **21:50～21:58（北京时间）**，针对用户“放后台后返回 K 线等待 5～8 秒”，只读核对 **47.80.22.243（首尔服务器）**。API 容器通过只读数据库会话查询最近 50 份报告，再用只读 ORM 汇总当日及三天内慢记录；另提取 API 24 小时日志中固定 chart timing 字段、Nginx 当日 K 线状态／字节数、即时容器资源和默认拥塞算法。运行版本仍为 `integrated-20261106-full-7e29236`，宿主默认 `bbr`；没有部署、重启、缓存变更、真实交易／资金／保护单操作。不保存完整访问日志、客户地址或鉴权内容。

本机证据为忽略且受限的 `.integration-runtime/ChartLatencyNov7/`：`reports-50.ndjson`／`reports-summary.json`、`extended.ndjson`、`runtime.json`、`access.json`；访问记录时间已归一 UTC。现有 access log 无 request／upstream duration，也无 trace，200 与发送字节数不证明手机已收到。`TraceHost` 单条回放确认“初次＋后台恢复读取两次、诊断仅一份”，为预期失败的缺口复现，不是整套回归通过；模型、管线与诊断源码已核对。带 trace 的 122 条 history 不能代表所有恢复请求。样本与限制统一见 [行情排查](market-data.md#background-chart-latency-20261107)，该只读阶段未实施建议埋点，也未重启旧 USDC 服务。

用户随后确认补齐恢复计时；本地实现通过现有 `load_started.value` 区分五种来源，继续使用同一追踪头、字段、事件和结果枚举，原严格 serializer 兼容，无需更新 **47.80.22.243（首尔服务器）**、迁移或改变限流。独立恢复、截止与旧回调隔离见 [行情](market-data.md#chart-recovery-diagnostics-20261107)，81 项 host／9 项契约／Release 的本地范围见 [开发](development.md#chart-recovery-diagnostics-20261107)。手机安装新包后应优先筛 `load_started.value=2` 的后台返回记录，并分开看 `3` 重连、`4` 手动重试；无来源值的旧记录不能冒充新恢复样本。源码交付不等于新包已上报，本次没有新生产部署。

2026-11-05 本次通过既有 SSH 认证在 **47.80.22.243（首尔服务器）** 的 API 容器只读执行 `python manage.py chart_load_reports --limit 12`。返回既有 iPhone Build 44 记录（北京时间 19:55:14–20:01:42），本机受限原始输出位于忽略目录 `.integration-runtime/ChartResumeNov5/recent-reports.ndjson`。仅汇总公共计时字段；没有修改应用／系统／网络配置、数据库、缓存或凭证，没有部署与重启。样本、已修复的本地竞态和剩余线上波动统一见 [行情](market-data.md#首次握手与后台恢复2026-11-05本地)，本次没有复查宿主 BBR 或进行新的 TCP 采样。

2026-11-01 按用户实际点击，47.80.22.243（首尔服务器）临时启用仅针对 K 线的 Nginx 阶段日志，采到 build 14 响应头约 72 ms、完整传送 4.62 秒。临时配置已撤销，站点文件与原备份 SHA-256 相同，`nginx -t`／reload 通过。配置备份和脱敏计时位于 `/opt/trade-tools-integrated/backups/kline-diagnostic-20261101/`，目录／日志保持受限；没有清空缓存、修改交易或发布新应用。结论和 upstream 背压解释见 [行情](market-data.md#手机实际请求与响应体传送)。

客户端新诊断已按本次授权提交交付，新增表 migration `market_stream.0003_chartloadreport` 已在 47.80.22.243（首尔服务器）完成，发布与验收见本页顶部。后续发布继续按既有 release／数据库备份流程迁移，再启新 API／market 镜像；API 与 market 配套，行情维护负责有界清理。该迁移只新增表，与旧版回滚兼容；代码回滚可保留表和既有数据，不需要反迁移，更不能通过回滚还原交易数据库。没有新凭证、端口或外部服务。

迁移部署后在所选 release 的 API 容器执行只读查询（用既有 Compose 参数，不打印 env）：

```bash
python manage.py chart_load_reports --build <构建号> --limit 10
python manage.py chart_load_reports --trace-id <追踪UUID> --limit 1
```

命令限最多 50 条，输出服务端接收时间及固定公共诊断 payload，不输出账户标识。诊断表仍按登录用户关联，不能将其当匿名数据公开；访问仅限既有受控运维。保存边界和保留策略见 [行情协议](market-data.md#客户端加载诊断)。旧 TestFlight 14 不会上报；2026-11-01 已在 47.80.22.243（首尔服务器）收到实际 iPhone 构建 15 的三轮九次 BTC1h 报告，确认手机上报／落库贯通。前六次首帧 2.00～6.94 秒、主要耗时在传输；BBR 对照后三次为 0.504／0.433／0.453 秒，阶段表与证据限制见 [真机排查](market-data.md#构建-15-真机传输排查2026-11-01)。

同日真机排查临时配置仅记录 BTC1h 的合法 trace、端口、连接数字 ID、代理计时和 TCP 数字指标，不记录认证、手机号／IP、完整 URL 或完整 UA。配置在安装前保存站点原文与 SHA-256，`nginx -t` 后平滑 reload，并设置 30 分钟自动恢复；TCP 采样也有时间和条数上限。受限证据位于 `/opt/trade-tools-integrated/backups/chart-transport-probe-20261101/`，本机副本位于忽略目录 `.integration-runtime/KlineDiagnostics/Phone15/`。这些临时操作不改变应用 release／镜像或迁移版本。

采样及自动回退定时器已停止，Nginx 原文哈希已恢复；后续单目的地址 BBR 对照和持久配置的结果统一见 [HTTPS 传输拥塞控制](#https-传输拥塞控制2026-11-01)。回滚所需的手机网络地址只短暂存在于受限操作状态文件，该文件在删除临时路由后已删除，不进入诊断日志或源码。
