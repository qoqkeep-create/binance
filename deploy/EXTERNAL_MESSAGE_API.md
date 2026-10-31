# 通用外部 JSON 消息接收接口

## 接口

- 地址：`POST https://binance.oovso.com:8443/api/external/messages`
- Content-Type：`application/json`
- 鉴权请求头：`X-External-Message-Key`
- 成功状态：HTTP `202 Accepted`

API Key 只配置在服务端部署环境和发送方安全凭据中，不放入 URL、请求正文、日志或
代码仓库。

## 参考通知格式

参考交易通知使用统一 JSON 信封：

```json
{
  "schemaVersion": 1,
  "eventId": "trade:open:1001:123456789",
  "type": "OPEN",
  "title": "🚀 BTCUSDT 多单 开仓",
  "content": "> **币种**：BTCUSDT\n> **订单方向**：多单\n> **止损价**：108000\n> **成交价**：110000",
  "occurredAt": "2026-09-04T12:00:00+08:00"
}
```

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `schemaVersion` | integer | 是 | 当前固定为 `1` |
| `eventId` | string | 是 | 全局唯一幂等键；接收端不解析其内部格式 |
| `type` | string | 是 | 参考通知类型，见下表 |
| `title` | string | 是 | 完整标题，可包含 Emoji |
| `content` | string | 是 | 完整保存的 Markdown 正文；App 提取关键字段做紧凑展示 |
| `occurredAt` | string | 是 | 包含时区的 ISO 8601 事件时间 |

支持的类型：

| `type` | App 语义 |
| --- | --- |
| `OPEN` | 开仓 |
| `STOP_LOSS` | 止损 |
| `STRATEGY_TAKE_PROFIT` | 策略止盈 |
| `MANUAL_TAKE_PROFIT` | 手动止盈 |
| `REDUCTION` | 减仓，包括分批减仓 |

`content` 作为原始内容整体保存，服务端不从正文拆解币种、价格、数量或止损价。App
仅为列表展示提取交易对、方向和与通知类型对应的关键字段；标题包含 `【模板测试】`
的测试消息与正式消息按相同规则接收。

## 通用消息行为

请求体可以是任意单个合法 JSON 值。服务端在 Key 校验后先把原始请求正文和接收时间
保存到 `external_message`，再交给彼此独立的业务处理器：

- 上述五类参考通知会校验信封并写入 `reference_trade_notification`。
- 未识别的消息不会返回错误，只保留在通用收件箱，供后续处理器消费。
- 已识别参考类型缺少必填字段或时间格式错误时返回 `400`，原文和投影均回滚。
- 同一 `eventId` 重复到达时仍返回 `202`，但只生成一条参考投影和一次 App 通知。
- 参考通知落库提交后才异步发送 APNs；APNs 失败不影响接收结果和已有业务数据。

## 调用示例

```bash
curl --fail-with-body \
  -X POST 'https://binance.oovso.com:8443/api/external/messages' \
  -H 'Content-Type: application/json' \
  -H 'X-External-Message-Key: <API_KEY>' \
  -d '{
    "schemaVersion": 1,
    "eventId": "trade:reduction:1001:1",
    "type": "REDUCTION",
    "title": "📉 BTCUSDT 多单 减仓",
    "content": "> **减仓百分比**：30%\n> **减仓价格**：112000",
    "occurredAt": "2026-09-04T13:00:00+08:00"
  }'
```

## 响应

接收成功和重复事件都返回：

```json
{
  "code": 202,
  "message": "accepted",
  "data": null
}
```

常见错误：

| HTTP 状态 | 原因 |
| --- | --- |
| `400` | JSON 无效，或已识别参考通知不符合信封格式 |
| `401` | Key 缺失或不匹配 |
| `503` | 接收功能未开启，或服务端 Key 少于 32 字节 |
| `500` | 消息未能写入数据库 |

发送方应只在 HTTP 状态和响应正文 `code` 都为 `202` 时确认投递，否则保留自身 outbox
并重试。

## 服务端配置

```bash
EXTERNAL_MESSAGE_ENABLED=true
EXTERNAL_MESSAGE_API_KEY=<至少32字节的随机值>
REFERENCE_TRADE_NOTIFICATION_TARGET_EMAIL=475842526@qq.com
```

升级期间仍兼容旧 `EXTERNAL_TRADE_SIGNAL_ENABLED` 和
`EXTERNAL_TRADE_SIGNAL_API_KEY` 环境变量；新部署统一使用 `EXTERNAL_MESSAGE_*`。
