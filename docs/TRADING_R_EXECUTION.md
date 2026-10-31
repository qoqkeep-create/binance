# 以损定仓（R）与动态保护执行说明

最后审计日期：2026-08-08。

实现状态：Java 执行链路与 iOS 划线下单入口已经落代码，数据库由 Flyway V4/V5/V6
管理；全局和账户级下单开关已经移除。尚未执行 Binance Futures Testnet/主网真实订单
验收，不能把自动化测试通过等同于真实资金环境验收。

## 1. R 与仓位计算

`R` 是下单时冻结的 `trading_loss_limit.current_amount`，结算单位是账户当前报价资产。
USD-M 线性合约的计划数量为：

```text
riskPerUnit = abs(referenceEntryPrice - normalizedInitialStopPrice)
rawQuantity = configuredR / riskPerUnit
plannedQuantity = floor(rawQuantity / quantityStep) * quantityStep
plannedRisk = plannedQuantity * riskPerUnit <= configuredR
```

- 市价建仓的 `referenceEntryPrice` 使用 Java 从 Binance 读取的 Mark Price；
- 限价和 Maker 建仓使用 K 线划线价格，并按 tickSize 规整；
- 做多止损必须低于建仓价，做空止损必须高于建仓价；
- 数量始终向下规整，并校验 `LOT_SIZE`/`MARKET_LOT_SIZE`、最小数量、最大数量和
  最小名义价值；
- 不使用 `pricePrecision` 代替 `tickSize`，也不使用 `quantityPrecision` 代替
  `stepSize`；
- 首版禁止同一账户、symbol、positionSide 叠加系统管理的仓位，避免两个 R 生命周期
  共用同一 Binance 仓位。

市价成交存在滑点，因此数据库同时保留配置 R、计划风险和按实际均价重新计算的
`actualInitialRAmount`。系统不会在市价成交后为了补足 R 而追加仓位。

## 2. 建仓方式

| 设置 | Binance 普通订单 |
| --- | --- |
| 只做 Maker | `LIMIT + GTX` |
| 限价单 | `LIMIT + GTC` |
| 市价单 | `MARKET` |

iOS 每次划线生成一个 `Idempotency-Key`。Java 在同一事务中先保存
`trading_command`、`trading_position_plan` 和全部级别快照，再唤醒当前账户的串行
worker；Controller 不解密 Secret，也不直接调用 Binance。clientOrderId 由 command
ID 确定性生成且不超过 36 字符。

建仓事务会先用 `FOR UPDATE` 锁定所属交易账户，再次检查同一
`account + symbol + positionSide` 是否已有活动计划或仓位，然后才写入命令与计划。
因此即使两个请求使用不同幂等键并发到达，也只能有一个请求完成活动计划预留。

建仓命令不在提交前读取或修改 Binance 持仓模式，始终按用户选择发送
`LONG/SHORT positionSide`，且只提交一次。Binance 明确拒绝时命令直接失败并返回
中文错误；`-4061` 由用户在 Binance 手动切换为双向持仓模式后重新创建下单命令。

计划同时保存完整 JSON 快照及 SHA-256，内容包含本次 R 与版本、三类下单方式、保底
止损 R、默认策略及版本、每一级动作、价格与数量步长和最小下单限制。执行中的规整列
和级别动作在 update SQL 中不可修改，后续移动止损与异常补单不再读取当前默认设置。
因此下一次修改 R、下单方式或默认策略，只影响下一次建仓，不会改变已有计划。

出现 HTTP 超时、网络异常、5xx 或 Binance timeout 时，命令进入 `UNKNOWN`，后续按
同一个 clientOrderId 查询。查询前不得生成新 ID 或盲目重发。

## 3. 初始止损

建仓部分成交后，不等待整张建仓单结束，下一次账户 worker tick 就按已成交数量安装
保护：

| 设置 | Binance Algo 条件单 |
| --- | --- |
| 市价止损 | `STOP_MARKET + closePosition=true` |
| 限价止损 | 主单 `STOP`，另挂 `STOP_MARKET + closePosition=true` 保底单 |
| 无止损 | 不安装保护单；R 仍用于仓位计算和后续策略坐标 |

限价止损的主单触发价是当前止损位，限价使用保底触发价，给成交保留一个价格带。
若设置的保底值为 `fallbackR`，每次收紧后的保底价为：

```text
longFallback  = currentStop - (fallbackR - 1) * riskPerUnit
shortFallback = currentStop + (fallbackR - 1) * riskPerUnit
```

条件单已迁移到 Binance Algo Service，当前接口不提供原地修改。替换保护位采用：

```text
提交确定性新保护单
-> 查询/确认新保护单生效
-> 保存新保护引用
-> 撤销旧保护单
```

因此更新期间允许短时双保护，但不允许出现无保护窗口。结果未知时保留旧保护单并查询
新单，不能先撤旧单。

保存新引用后如果旧单撤销超时，活动计划会从 `exchange_order` 中按计划 client ID
前缀重新发现所有旧 revision，并在后续健康巡检继续撤销；不能因为进程重启或当前
引用已更新而永久遗留旧止损。仓位关闭时也会先撤销未成交的建仓余量、全部止损和
全部止盈；任一撤销未确认时计划保持 `DEGRADED`，按持久化指数退避继续清理，全部
收敛后才进入 `CLOSED`。

每个活动计划默认每 5 秒按持久化 client ID 向 Binance REST 核对主止损；限价止损还
必须同时核对保底 `STOP_MARKET`。父 Algo 单进入 `FINISHED` 后会继续通过
`actualOrderId` 查询实际普通子单：子限价单仍为 `NEW/PARTIALLY_FILLED` 时视为保护仍
有效，不能误补第二组保护。确认缺失、撤销、拒绝或过期后，按 15 秒起的指数退避生成
新 revision 补挂；仍然执行“新单确认后撤旧单”。查询超时或结果未知时只继续查询原
client ID，禁止盲目生成新单。

## 4. 分级止盈、减仓与止损棘轮

开仓时把默认策略及其 1–5 级动作复制到计划快照。后来编辑默认策略不会改变已经打开
的仓位。

盈利 R 使用实际建仓均价与初始每单位风险：

```text
longProfitR  = (markPrice - averageEntryPrice) / riskPerUnit
shortProfitR = (averageEntryPrice - markPrice) / riskPerUnit
```

建仓首次部分成交后，先按冻结级别安装全部止盈；达到某级 `triggerR` 后才激活该级
移动止损动作：

- 建仓只要出现部分成交，就同时安装止损和全部 `reducePercent > 0` 的分级止盈；后续
  建仓继续成交时，该级冻结计划量按最新累计成交量单调增加；
- `reducePercent` 按累计实际建仓数量计算，向下规整并限制为不超过剩余仓位；若已有
  限价止盈覆盖不足，必须先确认撤销旧单，再用新 revision 补足，不能并行盲挂；
- 止盈方式分别映射为 `LIMIT + GTX`、`LIMIT + GTC` 和带数量的 Algo
  `TAKE_PROFIT_MARKET`；恢复旧计划时若 MARKET 目标已越过，直接提交普通市价减仓；
- 全部预挂止盈都参加默认每 5 秒的 REST 健康核对；确认缺失、撤销、拒绝或过期后
  使用新 revision 补挂，Algo 触发后继续沿 `actualOrderId` 核对子订单实际成交；
- 每次补挂数量为“该级冻结计划量 - 该级历史累计成交量”，再限制为不超过当前剩余
  仓位。每张尝试单保存提交前累计成交基线，部分成交后不会重新下完整计划量；
- 多级同时触发时，会先扣除其他活动止盈的未成交预留量；同一轮市价止盈的已确认
  成交也会立刻从后续级别的可用数量中扣除。若人工减仓导致活动止盈总量超过仓位，
  系统先撤销超额订单，下一轮再按真实剩余仓位补挂；
- `FIXED_R` 只尝试移动到一次固定 R 位置；
- `TRAILING_PROFIT_R` 激活后每 60 秒以最新 Mark Price 重新计算；
- 多个级别同时给出候选止损时，只采用最紧的一条。

所有止损更新最后经过棘轮：

```text
longConfirmedStop  = max(oldStop, candidateStop)
shortConfirmedStop = min(oldStop, candidateStop)
```

候选价还会限制在当前价外至少一个 tick，避免生成“立即触发”的错误条件单。无论行情
如何回撤，系统都不会把已确认止损放宽。

## 5. 串行执行、对账与开关

每个账户只有持有 Redis lease 与最新 MySQL fencing token 的 worker 能写交易所。
同一个 worker 串行处理：

```text
User Data Stream 事件
-> REST 对账
-> 幂等命令派发/未知结果查询
-> 部分成交保护
-> 每5秒保护单与全部已配置止盈单 REST 健康巡检/退避补挂
-> 每分钟 R 策略评估
-> 仓位结束后的建仓余量、止损与止盈撤单收敛
```

允许新建仓必须同时满足：

```text
trading.enabled
&& TRADING_ACCOUNT_SYNC_ENABLED=true
&& account.status=ACTIVE
&& account.sync_status=SYNCED
&& worker lease/fencing token 有效
```

iOS、Java 配置和数据库都不再提供下单开关。账户未同步完成、凭证失效、lease/fencing
失效或服务不可用时会自动拒绝新命令；已经打开的系统计划只由同一个 fenced worker
串行维护。

## 6. API 与数据库

```text
POST /api/trading/accounts/{accountId}/orders
     Idempotency-Key: <UUID>
DELETE /api/trading/accounts/{accountId}/entry-orders/{orderId}
       Idempotency-Key: cancel-entry:<本地订单ID>
GET  /api/trading/accounts/{accountId}/commands/{commandId}
```

活动建仓 `LIMIT/MAKER_ONLY` 委托可从持仓中心取消。后端只接受本系统的
`SYSTEM + ENTRY + LIMIT` 普通单，命令在账户 worker 内与下单、成交事件和保护逻辑
串行执行。取消仅针对剩余未成交数量；已经部分成交的数量继续按冻结 R 和策略快照
管理。止盈减仓限价单、止损单与外部挂单不会获得取消建仓入口。

人工市价或 Maker 平仓若命中系统管理计划，计划会先进入 `MANUAL_CLOSING`，并在
确认撤销未成交建仓余量和该仓位代际的全部止盈单后才提交平仓单；任一撤销结果未知
时不提交平仓。等待 Maker 成交期间保留止损保护、暂停生成新止盈；平仓被明确拒绝或
Maker 被撤销后恢复原计划。仓位归零、代际变化或剩余 Maker 数量超过当前仓位时，
worker 会主动撤销残留人工平仓单，防止旧单作用于后续仓位。

Flyway V4/V5 新增或扩展：

```text
trading_command                 幂等请求、请求哈希、派发与终态时间
trading_position_plan           冻结的R、价格规则、订单方式、成交与保护状态
trading_position_plan_level     冻结的每级触发、减仓订单与移动止损状态
```

V5 为计划增加完整执行快照、快照哈希、健康巡检游标和保护单补挂退避状态；为每一级
增加止盈订单 revision、当前尝试前的累计成交基线和补挂退避状态。所有游标均持久化，
服务重启后继续原计划，不会退回当前账户默认设置。

所有新表和字段只通过版本化迁移创建；没有启动时补列、`schema.sql` 或 Spring SQL init。

## 7. 上线前仍必须完成

1. REST 与 User Data Stream 使用同一个 Binance Futures Testnet 环境；
2. 验证 Maker、限价、市价建仓及部分成交；
3. 验证三种止损设置、限价止损双保险和新单确认后撤旧单；
4. 注入请求超时、5xx、WS 断线、Redis lease 丢失、进程强杀与重启；
5. 验证主动撤销/拒绝/过期的主止损、保底止损和各级止盈都能经轮询退避补挂；
6. 验证每个未知结果都按原 client ID 收敛且没有重复订单；
7. 验证止盈部分成交后只补剩余计划量，且不会超过当前仓位；
8. 验证建仓继续成交时，已挂限价止盈会先撤旧再按增量后的计划量换单；
9. 验证人工减仓、多级同时触发和同一轮市价成交都不会让止盈总量超过仓位；
10. 验证仓位结束时未成交建仓余量和全部退出单均经退避重试收敛；
11. 验证建仓后修改 R、默认策略和订单方式不会改变旧计划；
12. 验证连续移动只收紧，并在减仓后正确覆盖剩余数量；
13. Testnet 稳定运行通过后，才允许独立小额主网账户开启总闸门。
