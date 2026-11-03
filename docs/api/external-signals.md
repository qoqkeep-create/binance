# 外部信号接口对接文档

2026-11-03 当前状态：整合版已默认暂停整个 HTTP 信号接收入口（`EXTERNAL_SIGNAL_INGEST_ENABLED=false`），鉴权后返回 503，包括自报 `source=internal` 的请求；不入库、不生成通知，历史数据保留。自有扫描直接入库，不受此开关影响。下方保留 `8de868a` 来源合作方协议作为恢复接入时的参考；其中旧 Web／企微转发不是当前 iOS 的运行能力。当前链路以 [信号与通知](../signals-and-notifications.md#本地未读红点与外部接收暂停2026-11-03) 为准。

协议核对：2026-09-06，代码基线 `8de868a`。此文档用于“合作方发给 TradeTools”；反方向的五类仓位事件见 [交易通知推送](trade-notifications.md)。

## 1. 接口用途

该接口用于把合作方系统产生的指标信号发送到 TradeTools。接收成功后，信号会显示在 Web 的“信号 > 外部”页签，并同步转发到企业微信。

接口只接收、展示和通知信号：

- 不会自动开仓、平仓或修改订单；
- 不会读取 Binance 账户；
- 会尽力转发到企业微信，但不会转发到 Telegram；
- 企业微信临时不可用不会阻止信号入库，也不会导致接口整体失败；
- 通常会在 Web 下一次自动刷新时出现，最长约 30 秒。

30 秒为页面刷新周期，不包含网络异常等延迟。Web 信号消息当前只保留最近 3 天，不作为长期原始事件档案。

## 2. 对接原则

合作方不需要按照 TradeTools 的字段名称重新拆解信号，也不需要把自己的数据结构改成固定模板。请直接发送合作方系统当前产生的原始 JSON 对象，TradeTools 会：

1. 完整保存原始 JSON；
2. 从顶层或嵌套对象中识别常见字段；
3. 将能识别的字段翻译成 TradeTools 的统一显示格式；
4. 暂时无法识别时仍然接收并保存，在 Web 中标记为待适配。

当前翻译采用有界字段映射和文本推断，不调用 AI，也不保证任意新结构都能准确理解；不确定内容保留原始数据，不强行补造字段。

因此，下面列出的字段名称只是当前能够自动识别的常见写法，不是强制请求格式。拿到合作方真实请求样例后，可以继续增加专用映射，合作方无需修改原有发送逻辑。

## 3. 请求方式

```http
POST https://ba.wow211.com/webhook/external?key=<外部信号专用TOKEN>
Content-Type: application/json
```

交付时应把本文档和完整接口链接分别发送给合作方。仓库文档不保存生产 token。

也兼容查询参数 `token` 或请求头 `X-API-Key`；请求头优先。三者只需选一种，避免同时传入不同值。这个 key 是外部信号专用凭证，不是 Binance API Key。

硬性要求只有以下几项：

- 使用 `POST`；
- 请求头为 `Content-Type: application/json`，允许附带 `charset=utf-8`；
- 请求正文必须是一个非空 JSON 对象；
- 最大请求正文为 64 KB；
- 不接受顶层数组、纯字符串、纯数字、表单或纯文本正文。

## 4. 可以直接发送原有结构

例如，合作方原本产生嵌套结构，可以原样发送：

```json
{
  "meta": {
    "eventId": "partner-20260904-btc-15m-001",
    "sourceName": "partner-engine"
  },
  "payload": {
    "instrumentCode": "BTC/USDT",
    "positionSide": "bullish",
    "modelName": "breakout-v2",
    "timeFrame": "15m",
    "triggerPrice": 111250.5,
    "signalTime": "2026-09-04T10:20:00+08:00",
    "reason": "volatility expansion"
  },
  "technical": {
    "metrics": {
      "RSI": 31.5,
      "MACD": "cross_up"
    }
  }
}
```

如果合作方当前只有一段信号文本，也应放入 JSON 对象中发送：

```json
{
  "eventId": "partner-message-001",
  "sourceName": "partner-engine",
  "message": "BTCUSDT 15分钟出现做多信号，触发价格 111250.5"
}
```

TradeTools 会尝试从文本中识别交易对和多空方向。纯文本不能直接作为整个请求正文发送。

## 5. 当前自动识别范围

以下是当前常见映射，仅用于说明服务端的翻译能力：

| TradeTools 字段 | 可识别的常见名称示例 | 说明 |
| --- | --- | --- |
| 事件编号 | `event_id`、`eventId`、`signal_id`、`messageId`、`uuid`、`id` | 建议提供，用于安全重试和去重 |
| 来源系统 | `provider`、`system`、`sourceName`、`platform`、`来源` | 展示信号来源 |
| 交易对 | `symbol`、`ticker`、`pair`、`instrumentCode`、`instId`、`market`、`交易对`、`币种` | 兼容 `BTCUSDT`、`BTC/USDT`、`BTC-USDT` 等写法 |
| 信号方向 | `signal`、`side`、`action`、`direction`、`positionSide`、`trend`、`方向`、`多空` | 识别多、空和信息提醒 |
| 策略名称 | `strategy`、`strategyName`、`modelName`、`indicator`、`策略` | 用于 Web 展示 |
| 周期 | `interval`、`timeframe`、`period`、`resolution`、`周期` | 例如 `5m`、`15m`、`1h` |
| 价格 | `price`、`close`、`lastPrice`、`triggerPrice`、`entryPrice`、`价格` | 可为数字或字符串 |
| 信号时间 | `timestamp`、`time`、`ts`、`signalTime`、`eventTime`、`触发时间` | 支持 Unix 秒、毫秒和 ISO 8601 |
| 说明 | `comment`、`message`、`text`、`description`、`reason`、`summary`、`备注` | 可用于文本推断 |
| 指标 | `indicators`、`indicatorValues`、`metrics`、`technicals`、`指标` | 支持键值对象或 `{name, value}` 数组 |

方向值会尽量翻译：

- `BUY`、`LONG`、`BULLISH`、`1`、`做多`、`看多`、`多单`、`金叉`翻译为多；
- `SELL`、`SHORT`、`BEARISH`、`-1`、`做空`、`看空`、`空单`、`死叉`翻译为空；
- 无法判断方向时翻译为信息提醒，不会拒收。

## 6. 去重与重试

建议每个信号提供一个长期唯一且不变的事件编号，例如合作方数据库主键或“策略 + 交易对 + 周期 + 信号时间”的组合值。

同一个事件编号重复发送时：

- 接口仍返回 HTTP `200`；
- `duplicate` 返回 `true`；
- 不会重复生成 Web 信号。
- 不会再次转发企业微信。

网络超时或 HTTP `502` 时，可以使用相同事件编号重试。未提供事件编号时，使用原始请求正文的 SHA-256 作为编号，相同字节内容会去重；空格、键顺序等改变也可能生成新编号。请优先提供稳定编号，不依赖此兜底。

去重按来源类型和事件编号生效。多个合作方共用 external 来源时，请给编号添加自身系统前缀，防止不同系统撞号。当前消息表有 3 天保留期，清理后的历史重放不能依赖永久去重保证。

## 7. 成功响应

```json
{
  "ok": true,
  "id": 12345,
  "duplicate": false,
  "wecom_forwarded": true,
  "normalized": {
    "format": "external_signal_v1",
    "source": "external",
    "mapping_status": "mapped",
    "symbol": "BTCUSDT",
    "signal": "BUY"
  }
}
```

`mapping_status` 可能为：

- `mapped`：交易对和信号含义均已识别；
- `partial`：只识别了部分关键信息；
- `unmapped`：原始 JSON 已保存，但当前字段尚未适配。

HTTP `200` 且 `ok=true` 表示接收成功。`unmapped` 也表示接收成功，不需要合作方反复重试。

`wecom_forwarded` 表示本次企业微信转发是否成功。该值为 `false` 时，信号仍已成功入库并会显示在 Web，合作方不需要因此重试。

当前企业微信转发没有持久化失败重试队列；重复事件不会补发。若需要可靠的失败补发，应由 TradeTools 另行实现投递队列，不通过合作方更换事件编号重发来绕过去重。

## 8. 调用示例

```bash
curl --request POST '<完整接口链接>' \
  --header 'Content-Type: application/json' \
  --data '{
    "eventId": "partner-btc-001",
    "data": {
      "instrumentCode": "BTCUSDT",
      "positionSide": "long",
      "signalTime": "2026-09-04T10:20:00+08:00"
    }
  }'
```

## 9. 错误响应

| HTTP 状态码 | 含义 | 是否重试 |
| --- | --- | --- |
| `400` | JSON 无效、正文为空、顶层不是对象或对象为空 | 修正请求后再发送 |
| `403` | 接口链接中的 key 错误 | 不重试，检查完整链接 |
| `413` | 请求超过 64 KB | 缩小正文后再发送 |
| `415` | `Content-Type` 不是 `application/json` | 修改请求头后再发送 |
| `429` | 请求过于频繁 | 延迟后重试 |
| `502` | TradeTools 暂时无法保存 | 使用相同事件编号重试 |
| `503` | 接口尚未在服务端启用 | 联系 TradeTools 维护方 |

## 10. 安全要求

- 完整接口链接等同于该接口的写入凭证，不要放入公开仓库、网页前端或公开日志；
- 请求正文只发送指标信号，不要包含 Binance API Key、Secret Key、账户密码或其他凭证；
- 该 token 只能写入外部信号，不能读取账户信息，也不能执行交易；
- 如完整链接泄露，应立即更换 token。
