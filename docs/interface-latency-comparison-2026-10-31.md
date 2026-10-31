# USDT 与两套 USDC 的接口延迟对照

测试日期：2026-10-31，北京时间。HTTP 与初次实时观察为 14:39–14:43，按应用协议补齐心跳的实时观察为 14:43–14:44。测试端为本机 Mac，使用同一 Python requests / websockets 客户端，保持 TLS 校验，显式不走环境代理。测试只读取行情和认证元数据；本轮没有部署、修改交易状态或执行订单。

本轮 USDT 的 CDN 历史快照很快，但动态 API 为秒级；两套 USDC 的动态接口较快。首尔冷连接比旧 USDC 慢，持续连接收到的数据新鲜度仍需与行情发布间隔分开判断。不能依据历史快照的最快值判断整个交易系统快慢。

## HTTP：同一客户端、相近时段、连接复用

每个接口先预热一次，再轮换环境顺序各采集 30 次。中位数和 nearest-rank P95 仅统计成功且通过业务内容校验的响应，失败另计。耗时包含完整响应接收与 JSON 校验。

| 场景 | USDT 中位 / P95 | 旧 USDC 中位 / P95 | 首尔 USDC 中位 / P95 |
| --- | --- | --- | --- |
| 鉴权后的轻量读取 | 1464.5 / 4194.4 ms | 34.7 / 159.1 ms | 156.4 / 232.0 ms |
| 10 个交易对行情 | 945.7 / 2132.4 ms | 42.0 / 410.6 ms | 169.1 / 542.2 ms |
| BTC / 1h / 300 根历史 K 线 | 19.3 / 124.5 ms | 52.8 / 188.7 ms | 196.4 / 269.1 ms |

USDT 的 `fresh=1` 最新 K 线校准另测 30 次：中位 **1085.3 ms**，P95 **5988.9 ms**。两套 USDC 本轮使用其常规 K 线接口，不声称绕过 Redis / 数据库缓存。三套基础接口共 270 次及 USDT fresh 30 次均成功，K 线均为 300 根且相邻开盘时间严格相差 3600 秒。

| 环境 | 鉴权读取 | 行情读取 | 历史 K 线 |
| --- | --- | --- | --- |
| USDT | `/api/api/info`，仅绑定元数据，无 validate 参数 | `/api/trade/market/prices?symbols=...`，10 个固定交易对 | `/market-data/klines/BTCUSDT/1h.json`，匿名 CDN |
| 旧 USDC / 首尔 | `/api/auth/me` | `/api/market/tickers/popular?size=10` | `/api/market/klines?symbol=BTCUSDC&interval=1h&limit=300` |

USDT fresh 使用 `/api/trade/market/klines?symbol=BTCUSDT&interval=1h&limit=300&fresh=1`。本轮 USDT 历史快照 30/30 为 CDN HIT，动态接口均为 MISS / 不共享缓存；因此表格比较的是实际功能请求体验，不能当作 Django 与 Java 算法性能的对照。USDT 行情只返回价格，USDC 还返回涨跌、成交额等字段；轻量鉴权读取的业务查询也不同。原始文件保留解码大小、TTFB、Age 和 X-Cache。

## 冷连接与 CDN / 源站对照

每条路径各启动 8 次独立 curl，请求不带凭证，轮换测试顺序。TCP 为 `time_connect - time_namelookup`；TLS 为 `time_appconnect - time_connect`。它们是建连阶段耗时，不能直接冒充 ICMP RTT。

| 路径 | TCP 中位 | TLS 中位 | 完整请求中位 | 成功 / 失败 |
| --- | --- | --- | --- | --- |
| USDT-CDN | 11.5 ms | 14.3 ms | 54.3 ms | 8 / 0 |
| USDT-origin | 334.0 ms | 271.4 ms | 2281.0 ms | 8 / 0 |
| USDC-original | 41.3 ms | 41.6 ms | 176.8 ms | 8 / 0 |
| USDC-Seoul | 137.9 ms | 183.7 ms | 517.9 ms | 8 / 0 |

USDT CDN 与源站请求相同历史快照路径；源站通过 curl `--resolve ba.wow211.com:443:47.236.86.243` 保留 Host、SNI 和证书校验。两套 USDC 匿名请求 `/api/auth/me`，预期返回 401，因此此表完整请求耗时跨项目不等量，只把 TCP / TLS 用于连接阶段对照。8 次样本是时点观察。

## 实时推送与重连

三套同时观察 BTC 原生 1m 流 60 秒。USDT 使用生产独立行情域名代理；USDC 使用各自认证 WSS。应用心跳与接收并行，避免等待 ping 人为阻塞行情接收。下表建连与首事件是一轮连接观察，不能当作 30 次中位数。

| 指标 | USDT | 旧 USDC | 首尔 USDC |
| --- | --- | --- | --- |
| WSS 握手 | 1272.3 ms | 138.2 ms | 565.7 ms |
| 连接开始到首条有效 K 线 | 1668.5 ms | 591.0 ms | 4213.7 ms |
| 60 秒有效 K 线消息数 | 80 | 23 | 22 |
| 消息间隔中位 / 最大 | 580.9 / 4226.5 ms | 1852.0 / 8299.4 ms | 1702.0 / 8299.4 ms |
| 本机接收时间减 E 中位 / P95 | 87.6 / 1021.9 ms | 76.6 / 191.1 ms | 88.5 / 191.1 ms |

USDT 本轮有 1 次控制帧 ping 超过 3 秒，但同一连接继续收到行情；两套 USDC 此观察窗口未断开。随后每套各主动重连两次，均收到有效 K 线：USDT 从重连开始到首事件为 1.92 / 4.14 秒，旧 USDC 为 1.61 / 1.77 秒，首尔为 1.62 / 1.77 秒；后一次两套 USDC 在收到首事件后都出现过超过 8 秒无消息。这里测试的是客户端重新建连，未模拟真实断网或改系统网络。

初次观察保存在原始数据中：两套 USDC 均约 12.5 秒才收到首条 K 线，尽管握手分别只需约 164 / 688 ms，且两边同时出现约 12.8 秒消息间隔。这说明此前“12 秒未完成测试”不能直接等同于握手失败。仍需结合源流、交易活跃度与服务端转发日志确定安静间隔的原因。USDT 为 BTCUSDT，USDC 为 BTCUSDC，成交活跃度与 Binance 流类型不同，不能把消息条数差异直接归因于网络丢包。

事件新鲜度取 Binance `E` / Java payload `eventTime`，不是 K 线开盘时间。直接校准 Binance 时间的 5 次请求均连接超时，因此该项使用未校准的本机时钟，只作相对观察，不能承诺绝对单向延迟为几十毫秒。控制帧 ping 的 USDT 终点穿过代理到 Binance，USDC 终点为 Java 服务，两者也不是相同 RTT 测量路径。

## 后续统一按六个方面验收

| 方面 | 要测什么 | 本轮范围与后续 |
| --- | --- | --- |
| 网络连接 | DNS、TCP、TLS，首次连接与复用连接，三网与晚高峰 | 本机冷连接各 8 次；三网 / 高峰待补 |
| HTTP 功能场景 | 认证元数据、10 条行情、同周期同数量 K 线；中位 / P95 / 失败 / 字节数 | 基础接口各 30 次；CDN HIT 与 fresh 分列 |
| 实时数据质量 | 握手、订阅确认、首条有效 K 线、事件 E 到接收时间、最大静默、乱序 | 本轮 60 秒观察；校时与同合约同源对照待补 |
| 稳定性与恢复 | 连续 30–60 分钟，主动重连、实际断网、切换 Wi-Fi / 蜂窝；恢复时间与失败率 | 本轮每套 2 次客户端重连；长时间与断网待补 |
| 交易执行链路 | 请求入站、鉴权 / 排队、发往 Binance、接单确认、保护单安装、成交回报分段 | 待专门测试；使用现有日志或 Testnet，接单与成交分开，不用真实造仓测速 |
| 容量与资源 | 隔离环境按 1 / 5 / 10 并发观察 P95、错误率、CPU、内存、DB / Redis 与限频 | 本轮为少量只读访问；未对交易生产环境施压 |

应保持同一设备、网络、近似时间、相同 K 线根数与周期，并记录缓存语义和交易对差异。正式 P95 / 稳定性结论需扩大样本与时段；30 次 P95 是本轮尾部观察，不能视作长期 SLA。

## 复测与环境边界

脚本为 [compare_market_interfaces.py](../scripts/compare_market_interfaces.py)，需要 `requests` 与 `websockets>=15,<16`，本机已具备。运行目录为 USDT 项目根目录，账号文件必须在 Git 忽略路径且权限为 600；只传文件路径，密码不放命令行。

```bash
python3 scripts/compare_market_interfaces.py \
  --usdt /path/to/usdt-test.env \
  --original /path/to/usdc-original-test.env \
  --seoul /path/to/usdc-seoul-test.env \
  --samples 30 --seconds 60 \
  --output /tmp/market-interface-comparison.json
```

`--skip-http` 可单独复测实时链路。公开 CDN 请求使用独立无认证 Session，令牌与 Cookie 不发往公开快照路径；测试完成退出自己的会话，报告中不保存令牌、密码、账号或行情价格。

USDT 本地工作区存在大量未提交修改，未以它们代表线上版本；生产 SSH 本轮连接超时，未取得内部处理计时。线上登录需 agreed 字段，`/api/auth/preflight-status` 返回 404，故正式鉴权读场景改用已验证存在的 `/api/api/info`。不得据本轮公网结果断言 CPU、Django 或某段跨境线路是唯一瓶颈。

首尔同期应用约 762 MiB、MySQL 652 MiB、Redis 335 MiB，三个容器运行正常；该快照不等于并发容量结论。原始结果见 [JSON](interface-latency-comparison-2026-10-31.json)。
