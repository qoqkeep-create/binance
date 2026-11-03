# 交易通知推送接口对接文档

2026-11-03 当前状态：合作方出站渠道保持关闭（`EXTERNAL_TRADE_SIGNAL_ENABLED=false`），开平仓等仓位通知总开关也保持关闭。恢复普通通知时，内部适配器仅移交所属用户 App APNs 队列，Echobell 只保留浮盈。下方保留来源合作方协议，不代表当前正在向其发送；状态与恢复边界见 [信号与通知](../signals-and-notifications.md#低耦合投递与移除)。

协议核对：2026-09-06，代码基线 `8de868a`。此文档用于“TradeTools 发给合作方”；反方向的指标信号见 [外部信号接入](external-signals.md)。

## 1. 接口信息

TradeTools 会在交易事件发生后，通过 HTTPS POST 将通知推送到接收方。

```http
POST https://binance.oovso.com:8443/api/external/messages
Content-Type: application/json
X-External-Message-Key: <双方约定的 API Key>
```

API Key 只通过 `X-External-Message-Key` 请求头传递，不放入 URL 或请求正文。

这是独立的通知接口密钥，不是 Binance Key。上方是当前约定的接收地址，实际由服务端配置；地址必须使用 HTTPS，不能带 URL 用户密码、查询参数或 fragment，发送方不跟随 HTTP 重定向。

## 2. 统一消息结构

五类交易通知均使用相同的 JSON 结构：

```json
{
  "schemaVersion": 1,
  "eventId": "trade:open:1001:123456789",
  "type": "OPEN",
  "title": "🚀 BTCUSDT 多单 开仓",
  "content": "> **币种**：BTCUSDT\n> **订单方向**：多单\n> **止损价**：108000\n> **成交价**：110000\n> **订单编号**：1001\n> **成交时间**：2026-09-04 12:00:00",
  "occurredAt": "2026-09-04T12:00:00+08:00"
}
```

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `schemaVersion` | integer | 是 | 协议版本，当前固定为 `1` |
| `eventId` | string | 是 | 全局唯一事件编号，用于幂等和重试去重 |
| `type` | string | 是 | 交易事件类型，取值见下表 |
| `title` | string | 是 | 通知标题，可能包含 Emoji |
| `content` | string | 是 | Markdown 格式的完整通知正文 |
| `occurredAt` | string | 是 | ISO 8601 格式的事件时间，包含时区 |

接收端应将 `eventId` 当作不透明字符串，不应依赖其内部格式解析业务字段。

`content` 是展示文本，不是交易计算协议。所有类型含币种与多单 / 空单方向；正文时间默认北京时间，`occurredAt` 显式携带时区。盈亏比按该单净盈亏与止损金额计算，不能当作价格涨跌幅；估算结算会附加说明，接收端应保留该提示。

## 3. 事件类型

| `type` | 含义 |
| --- | --- |
| `OPEN` | 开仓 |
| `STOP_LOSS` | 止损平仓 |
| `STRATEGY_TAKE_PROFIT` | 策略止盈平仓 |
| `MANUAL_TAKE_PROFIT` | 手动止盈平仓 |
| `REDUCTION` | 减仓 |

## 4. 五类消息示例

带单交易沿用以下五类及相同 JSON 字段。其 `title` 增加 `【带单】`，`content` 首行增加 `> **交易账户**：带单组合`；普通合约格式不变。接收端应允许正文增加说明行，不按固定行数解析。

### 4.1 开仓 `OPEN`

```json
{
  "schemaVersion": 1,
  "eventId": "trade:open:1001:123456789",
  "type": "OPEN",
  "title": "🚀 BTCUSDT 多单 开仓",
  "content": "> **币种**：BTCUSDT\n> **订单方向**：多单\n> **止损价**：108000\n> **成交价**：110000\n> **订单编号**：1001\n> **成交时间**：2026-09-04 12:00:00",
  "occurredAt": "2026-09-04T12:00:00+08:00"
}
```

### 4.2 止损 `STOP_LOSS`

```json
{
  "schemaVersion": 1,
  "eventId": "trade:close:1001",
  "type": "STOP_LOSS",
  "title": "🛑 BTCUSDT 多单 止损",
  "content": "> **币种**：BTCUSDT\n> **订单方向**：多单\n> **开仓价**：110000\n> **止损价**：108000\n> **止损时间**：2026-09-04 12:30:00\n> **止损盈亏比**：-1.1:1",
  "occurredAt": "2026-09-04T12:30:00+08:00"
}
```

### 4.3 策略止盈 `STRATEGY_TAKE_PROFIT`

```json
{
  "schemaVersion": 1,
  "eventId": "trade:close:1002",
  "type": "STRATEGY_TAKE_PROFIT",
  "title": "🎯 BTCUSDT 多单 止盈",
  "content": "> **币种**：BTCUSDT\n> **订单方向**：多单\n> **止盈价**：116020\n> **止盈盈亏比**：0.9:1\n> **止盈时间**：2026-09-04 14:00:00",
  "occurredAt": "2026-09-04T14:00:00+08:00"
}
```

### 4.4 手动止盈 `MANUAL_TAKE_PROFIT`

```json
{
  "schemaVersion": 1,
  "eventId": "trade:close:1003",
  "type": "MANUAL_TAKE_PROFIT",
  "title": "✋ BTCUSDT 空单 手动止盈",
  "content": "> **币种**：BTCUSDT\n> **订单方向**：空单\n> **止盈价**：106500\n> **止盈盈亏比**：0.7:1\n> **止盈时间**：2026-09-04 15:00:00",
  "occurredAt": "2026-09-04T15:00:00+08:00"
}
```

### 4.5 减仓 `REDUCTION`

```json
{
  "schemaVersion": 1,
  "eventId": "trade:reduction:1001:1:0.7:202609041300",
  "type": "REDUCTION",
  "title": "📉 BTCUSDT 多单 减仓",
  "content": "> **币种**：BTCUSDT\n> **订单方向**：多单\n> **减仓百分比**：30%\n> **减仓价格**：112000\n> **减仓时间**：2026-09-04 13:00:00\n> **减仓类型**：浮盈减仓",
  "occurredAt": "2026-09-04T13:00:00+08:00"
}
```

## 5. 成功响应

接收成功时必须返回 HTTP `202 Accepted`，响应正文中的 `code` 也必须为 `202`：

```http
HTTP/1.1 202 Accepted
Content-Type: application/json
```

```json
{
  "code": 202,
  "message": "accepted",
  "data": null
}
```

发送方只有在 HTTP 状态码和响应正文 `code` 均为 `202` 时，才会将本次投递标记为成功。

## 6. 重试与幂等

- 网络错误、超时、非 HTTP `202` 响应或响应正文 `code` 不是 `202` 时，发送方会保留失败记录并按退避重试；当前最多尝试 8 次，耗尽后停止自动尝试并记录告警，不是无限重试。
- 同一个 `eventId` 可能因网络异常重复到达，接收端必须按 `eventId` 幂等处理。
- 对已经成功处理的重复事件，接收端仍应返回 HTTP `202`，避免发送方持续重试。
- 接收端应接受上述全部五种 `type`，不能只允许 `OPEN`。
- `content` 是可直接展示的 Markdown 文本，不建议通过解析正文执行交易计算。
- 为兼容后续协议扩展，接收端应忽略无法识别的新增字段，不应因此返回 HTTP `400`。

该渠道与交易处理及企业微信投递隔离；接收失败不改变真实交易结果。运维关闭渠道不删除历史，重新开启可能派发此前待发送事件，不保证自动补发全部历史交易。

## 7. 测试消息

测试消息与正式消息使用相同结构，但标题会包含 `【模板测试】`，正文第一行会注明：

```text
> **测试说明**：仅验证通知样式，不对应真实交易
```

接收端应正常接收测试消息，并按 HTTP `202` 响应。
