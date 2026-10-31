# K 线与访问性能

> 整合版说明（2026-10-31）：本文保留来源系统的业务或实现资料。当前运行入口、服务器、原生页面与验证边界以 [整合说明](INTEGRATION.md)、[运维](operations.md) 和 [变更](changes.md) 为准；Java 模块仅作参考。


实现基线 `8de868a`；本文描述代码和上一轮验收结果，不承诺所有地区固定加载时间。DNS / TLS 配置与证书到期记录由 [运维文档](operations.md) 单独维护。

## 数据路径

```text
打开图表 --> 同币种 + 同周期的浏览器本地缓存 --> 公共历史快照补齐
实时增量 --> 独立行情域名 WS --> 失败尝试 Binance 直连 WS
       无有效 WS --> 每 2 秒 fresh REST 兜底
       有有效 WS --> 每 30 秒 fresh REST 校准
```

历史快照用于首屏和已收盘 K 线，不承担成交、止损触发或真实结算定价。所有公开路径不需要 Binance Key，也不携带账户凭证。

## 分层缓存

| 层 | 实现和边界 |
| --- | --- |
| 浏览器图表缓存 | [klineCache.ts](../tools/src/shared/lib/klineCache.ts)，localStorage 最多 60 组、每组 300 根，仅公共行情，币种 / 周期隔离，不能把 15m 数据当作 1h 首屏 |
| 请求与预取 | [klineSnapshotCache.ts](../tools/src/shared/lib/klineSnapshotCache.ts)，区分数据来源、币种、周期、limit；先活动周期再串行补缺失周期，避免并行抢占首屏带宽 |
| 公开历史快照 | `/market-data/klines/<SYMBOL>/<interval>.json`，网关有限参数映射，可被 CDN 缓存；内部 Django public 路径不能作为外部绕过入口 |
| 后端共享缓存 | [trading/views.py](../server/trading/views.py)，按币种 / 周期 / 数量隔离，热点队列及 scheduler 后台预热 |
| fresh 校准 | [market_snapshots.py](../server/trading/market_snapshots.py)；认证 `/v1/trade/market/klines?...&fresh=1`，独立约 2 秒 Redis 缓存、并发等待约 1 秒上限，绕开长 TTL 边缘快照 |

热点保留约 600 秒、最多 200 个组合；预热每轮最多 8 组，scheduler 每 2 秒唤醒，但各周期分别决定刷新节奏，不是每 2 秒拉全量。

公开快照的共享缓存时间见 `docker/nginx/default.conf`（来源路径，未随本整合交付）：

| 周期 | `s-maxage` 秒 |
| --- | --- |
| 1m | 30 |
| 3m | 120 |
| 5m | 240 |
| 15m | 600 |
| 30m | 1200 |
| 1h | 1800 |
| 2h | 3600 |
| 4h | 7200 |
| 1d | 21600 |

浏览器 `max-age=5`、`stale-while-revalidate=30`。长周期历史快照可能滞后，实时补齐不能继续读同一份长 TTL 内容。私有 `/api` / `/v1` 响应 no-store；不得为加快账户界面将其纳入 CDN。

## CDN 边缘预热

公开历史快照走阿里云 CDN，源站在新加坡。实测大陆侧未命中时需跨境回源，27KB 的 1h 快照 20 秒仍传不完；命中时约 0.07 秒。scheduler 任务 [snapshot_prewarm.py](../server/trading/snapshot_prewarm.py) 每 15 秒检查一次，按各周期 `s-maxage` 的节奏请求公开快照 URL（覆盖图表 3m / 15m / 1h / 4h / 1d，每轮限量），使 CDN 副本保持常热；即使边缘恰好在请求间隙过期，也由 CDN 直接返回或走 `stale-while-revalidate`，不再同步跨境回源。

请求的是公开行情 URL、不带任何凭证；命中 CDN 不回源，回源时后端先读共享缓存，因此不增加 Binance 调用。默认开启，可用 `MARKET_SNAPSHOT_PREWARM_ENABLED=false` 关闭，目标域名用 `MARKET_SNAPSHOT_PREWARM_URL` 覆盖。

## WS 生命周期

[binanceKlineStream.ts](../tools/src/shared/lib/binanceKlineStream.ts) 当前优先连接：

```text
wss://stream.ba.wow211.com/market-stream/<symbol>@kline_<interval>
wss://fstream.binance.com/market/ws/<symbol>@kline_<interval>
```

币种小写；周期白名单与网关一致。首选不是主站 CDN 域名；容器 Nginx 中仍保留旧主站 `/market-stream` 路由，不等于前端还在使用它作为首选，也不等于它已被删除。

建立连接超时 6 秒，8 秒收不到有效 K 线则重连；重试退避最高 30 秒。收到有效 K 线才标记 connected，`onopen` 或 HTTP101 本身不足以判定行情健康。离线、恢复联网、页面可见和销毁都处理监听器及定时器。

图表轮询以“是否有有效连接”的布尔状态驱动，不因 connecting / disconnected 的每次切换重置计时器。否则连续握手失败可能导致轮询一直无法执行。WS 不可用时用户仍有 fresh REST 兜底。

## 渲染和竞态约束

[KlineChartCard.tsx](../tools/src/pages/trading/KlineChartCard.tsx) 使用 Lightweight Charts。实时写图约 750ms 节流；普通最新 K 更新与历史全量修正分开，不为每条消息销毁重建图表。

价格轴、十字光标、底部价格与交易表单复用 [chartPrice.ts](../tools/src/shared/lib/chartPrice.ts)：小于 1 的价格保留四位有效数字，避免显示为零。蜡烛 / MACD 主序列显示刻度最小步长为 `1e-8`；这仅影响图表，不替代交易所下单价格精度。

- 切币种 / 周期后旧请求代际不再写当前图表，缓存不能串周期。
- 比较同一根 K 的累计成交量等状态，防止旧 REST 快照覆盖更新的 WS 内容。
- 历史 K 被校正时触发完整数据更新，不能只更新最后一根导致指标与历史失配。
- 切走页面释放图表、订阅、定时器与事件监听；重新打开验证恢复，不仅验证首次加载。
- 页面代码按需加载，入口压缩体积在上一轮从约 154KB 降到 22KB；这是当时构建指标，不是未来版本固定值。
- 页面 HTML 每次普通导航联网获取，不再由 PWA 预缓存提供；内容哈希静态资源保留 HTTP / CDN 缓存及历史 worker 缓存兼容，账户数据不进入 Service Worker 缓存。更新不等待整套资源下载，详见 [前端版本运维](reference/USDT_OPERATIONS.md#前端仍显示旧版本)；变更时同时审查 [vite.config.ts](../tools/vite.config.ts) 与 [sw.js](../tools/src/sw.js)。

Profile / Signals 在页面隐藏、离线或本次请求尚未结束时暂停周期刷新；恢复可见 / 联网时合并刷新，不引入另一套轮询框架。已有策略编辑路由必须先从服务器加载相应记录，加载失败或不存在时禁用编辑保存；用户会话与交易模式切换后的旧响应不能写入新表单。

## 排障方法

2026-10-31 在同一台 Mac 上补测 USDT 与旧 / 首尔 USDC 的接口、冷连接及实时流，
统一历史 K 线为 1h / 300 根，并把 CDN 命中与 fresh 校准分开。
USDT 历史 CDN HIT 中位约 19 ms，但动态行情 / fresh K 线约 0.95 / 1.09 秒；
这两个数字不能混作同一链路的性能。实际样本、实时消息间隔与校时限制、后续六项
验收口径见 [三环境接口对比](interface-latency-comparison-2026-10-31.md)。
本轮只做只读接口观察，未以本地未发布代码冒充线上状态。

2026-10-28 的成都移动 CDN / 源站只读对照与浏览器结果见 [大陆直连访问评估](china-direct-access-assessment-2026-10-28.md)。本文前述“27KB 跨境超过 20 秒、边缘命中约 0.07 秒”保留为历史观察，不代表本轮或全国速度；当期资源体积与时间以该评估快照为准。

先记录设备、网络、冷 / 热启动、币种、周期、首次有图时间、WS 首条数据时间。分别检查静态资源下载、认证刷新、历史 API、图表挂载与主线程工作量；不要仅凭感觉认定“跨境慢”或“渲染慢”。

若 K 线不动，查 WS 是否实际收到 `k` 消息、代理 / 直连切换、fresh 请求是否仍按期出现；若周期错乱，查缓存键与代际；若只有首次慢，查页面 chunk、PWA 和历史快照冷热差异。

后端出站请求共用服务器 IP，账户请求与后台查询也会争用 Binance 配额。查看 `binance_outbound_minute` 分钟日志及交易所返回权重，避免仅靠增加 worker / 缩短轮询解决。旧文档记录的单次权重实测不是永久官方配额，不据此写死新限频算法。

## 验收边界

至少覆盖桌面和手机、不同周期及币种、冷 / 热打开、连续切换、关闭重开、WS 完全不可用、直连失败、历史修正和延迟旧请求。图表须有非空像素与真实内容，检查无布局重叠；不能只验证组件存在。

上一轮使用桌面 1440x900、手机 390x844，在账户接口替身下连接真实公共历史和 WS，覆盖 5 个页面周期；并通过前端 36 项、后端 17 项相关测试。该测试不代表真实账户交易流程全面验收，也不能保证中国境内所有运营商均可直连 Binance。部署与日期见 [变更记录](changes.md)。
