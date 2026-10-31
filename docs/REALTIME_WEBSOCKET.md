# APP WebSocket v1

> 整合版说明（2026-10-31）：本文保留来源系统的业务或实现资料。当前运行入口、服务器、原生页面与验证边界以 [整合说明](INTEGRATION.md)、[运维](operations.md) 和 [变更](changes.md) 为准；Java 模块仅作参考。


## 目标

APP 与后端只建立一条长连接，行情、K 线、策略提醒以及后续的账户、持仓和订单事件都通过频道复用该连接。协议不使用 STOMP，iOS 直接使用 `URLSessionWebSocketTask` 发送和接收 JSON。

```text
REST：登录、首屏快照、历史查询、下单命令
WebSocket：首屏之后的实时增量、异步状态变化和提醒
```

WebSocket 不能代替所有 REST 接口。客户端断线重连后应重新获取关键业务快照，再恢复增量订阅；订单创建等有副作用的操作仍使用带幂等键的 HTTPS API。

当前行情 REST 快照：

```text
GET /api/market/tickers
GET /api/market/tickers/popular?page=0&size=10
GET /api/market/tickers/search?query=BTC&page=0&size=20
GET /api/market/klines?symbol=BTCUSDC&interval=1h&limit=500
```

热门和搜索接口按 24h 成交额降序分页；WebSocket 继续负责首屏之后的自选行情增量。
K 线详情页通过历史接口建立多周期快照，不再提供盘口深度查询。历史查询优先读取
币安连续合约最新数据，网络异常时回退本地已收线数据；查询结果不会写库，也不会
触发策略或提醒。

## 连接与鉴权

开发环境示例：

```text
HTTP API:  http://192.168.1.110:8686
WebSocket: ws://192.168.1.110:8686/ws/v1
```

生产环境必须使用 `https` 和 `wss`。握手请求携带现有 Sa-Token：

```http
Authorization: Bearer <accessToken>
X-Platform: ios
```

Token 不能放在 URL 查询参数中，避免被网关、代理和访问日志记录。Token 无效、已退出或超过活跃时间时，握手返回 `401`；连接期间失效时使用关闭码 `4401`，iOS 随即清除登录态。

协议 JSON 必须使用 WebSocket 文本帧发送。后端基于 `TextWebSocketHandler`，
不接受把 JSON 编码成 WebSocket 二进制帧。

## 生命周期

1. iOS 登录成功后连接 `/ws/v1`。
2. 服务端返回 `ready`，其中包含连接 ID、心跳间隔和超时时间。
3. iOS 发送 `subscribe`，服务端使用 `ack` 返回当前有效订阅。
4. iOS 按 `ready` 指定的间隔发送应用层 `ping`，服务端返回 `pong`。
5. 服务端超过 `clientTimeoutMillis` 没有收到客户端消息时关闭假活连接。
6. 网络断开后 iOS 使用带随机抖动的指数退避重连，收到新的 `ready` 后自动恢复订阅。
7. 用户退出或登录态失效时立即关闭连接，不再重连。

## 消息信封

客户端消息：

```json
{
  "version": 1,
  "type": "subscribe",
  "requestId": "7D5D0A3C-5F49-44C9-AB2C-8F3D360DC8BA",
  "subscriptions": [
    {
      "channel": "market.kline",
      "filters": {
        "symbols": ["BTCUSDC", "ETHUSDC"],
        "intervals": ["1m", "1h"]
      }
    },
    {
      "channel": "strategy.signal",
      "filters": {}
    }
  ],
  "timestamp": 1785231000000
}
```

服务端事件：

```json
{
  "version": 1,
  "type": "event",
  "channel": "market.kline",
  "event": "upsert",
  "key": "BTCUSDC:1m",
  "sequence": 128,
  "timestamp": 1785231000123,
  "data": {
    "symbol": "BTCUSDC",
    "contractType": "PERPETUAL",
    "interval": "1m",
    "eventTime": 1785231000100,
    "openTime": 1785231000000,
    "closeTime": 1785231059999,
    "openPrice": 118420.1,
    "highPrice": 118430.2,
    "lowPrice": 118410.0,
    "closePrice": 118425.5,
    "volume": 12.4,
    "quoteVolume": 1468362.2,
    "tradeCount": 382,
    "closed": false
  }
}
```

所有时间字段均为 Unix 毫秒。价格和数量在 JSON 中使用十进制数字，数据库与后端仍使用 `BigDecimal`。

`key` 标识一条有序事件流，`sequence` 在当前服务进程内按 `channel + key` 单调递增。客户端发现同一 `key` 序号跳跃时应重新获取该业务快照。服务端当前不保存 WebSocket 事件用于重放，不能把它当作消息队列。

## 当前频道

| 频道 | 事件 | 过滤条件 | 数据来源 |
| --- | --- | --- | --- |
| `market.ticker` | `update` | 必填 `symbols` | 币安全市场 24h ticker，包含最新价、成交额和涨跌幅 |
| `market.kline` | `upsert` | 必填 `symbols`，可选 `intervals` | 币安实时未收线 K 线 |
| `market.kline` | `closed` | 必填 `symbols`，可选 `intervals` | 各周期 K 线事务提交后的收线事件 |
| `strategy.signal` | `created` | 可选 `symbols`，空表示全部 | 策略信号事务提交后 |
| `trading.account` | `sync_status/reconciled/updated/notice` | 不支持行情过滤 | 账户事件/对账事务 Outbox，仅所属用户 |
| `trading.position` | `updated` | 不支持行情过滤 | 持仓归并事务 Outbox，仅所属用户 |
| `trading.order` | `updated` | 不支持行情过滤 | 普通/Algo 订单归并事务 Outbox，仅所属用户 |
| `trading.fill` | `created` | 不支持行情过滤 | 成交幂等落库事务 Outbox，仅所属用户 |

补历史 K 线不会发布实时事件，也不会触发策略提醒。当前市场连接器订阅原生
`1m`，常用周期由本地完整 `1m` K 线聚合，单频道最多订阅 `200` 个交易对。
K 线详情页选择 `5m/15m/1h/4h/1d` 时，会同时订阅所选周期和原生 `1m`：所选
周期接收可靠的收线事件，原生 `1m` 的最新成交价作为当前高周期 provisional K 线
的实时价格源。客户端把所有周期的图表发布统一合并为最多每 `250ms` 一帧；
`market.ticker` 继续提供 24h 成交额和涨跌幅，并在 `1m` 行情暂时不可用时作为价格
兜底。所有周期每 `15s` 重新获取一次 REST 快照校准，不再对 `1h` 做例外处理。

iOS 收到 `strategy.signal/created` 后只更新当前进程内的信号列表，不再由 WebSocket
生成系统通知。真正的系统通知由 Java 在信号事务提交后直接发送 APNs；即使 App 已被
终止也可由 Apple 投递。通知点击打开信号根页面，信号卡片点击进入对应交易对 `1h`
K 线详情。

私有交易事件统一通过后端 `publishToUser` 定向投递，不能使用公开广播。APP 重连后
先请求 `/api/trading/accounts/{accountId}/snapshot`，再订阅增量；发现 sequence
缺口时重新取快照，不依赖 WebSocket 历史重放。

## 行情页边界

当前 iOS 行情列表使用“快照 + 增量”：

```text
GET /api/market/tickers
  返回当前报价资产下所有交易中永续合约的最新价、24h成交额和24h涨跌幅

market.ticker
  APP只订阅当前显示的交易对
  后端只推送快照之后的变化
  iOS每200ms按交易对合并最新值并批量更新页面
```

APP 冷启动、WebSocket 重连和手动下拉刷新都会重新获取快照。事件中的
`eventTime` 用于拒绝晚于快照到达但实际更旧的增量，避免价格倒退。
`market.kline` 不再承担行情列表 ticker 的职责，继续用于实时 K 线图。

## 反向代理

生产网关需要保留升级头，并让读取超时大于服务端客户端超时：

```nginx
location /ws/ {
    proxy_pass http://127.0.0.1:8686;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Authorization $http_authorization;
    proxy_read_timeout 75s;
}
```

实时发送使用独立有界线程池。慢客户端或队列拥塞只影响实时推送，不反压币安 WebSocket、MySQL K 线落库和策略线程；客户端通过序号缺口和快照恢复一致性。
