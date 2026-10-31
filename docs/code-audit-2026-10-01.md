# 全仓代码审计报告（2026-10-01）

审计对象：`server/` 全部项目代码（约 5.0 万行 Python，已排除 `.venv`/`__pycache__`）与 `tools/src/` 全部前端代码（约 2.15 万行 TS/TSX）。

审计标准（用户要求）：**简练**（无冗余/重复/死代码）、**强壮**（边界、异常、并发、资金安全）、**不繁杂**（结构清晰、职责单一、可一眼审）。

审计方法：按模块并行深度审查，逐条发现均带 文件:行号 与修复建议；结论以代码核对为准，未经证实的不写入。

---

## 一、总体结论

这是一个**资金安全意识明显高于平均水平**的真实交易系统：

- 幂等键 + clientOrderId 恢复、"结果未知绝不按余额重发"、先建新止损再撤旧止损、通知与交易成功路径解耦、全链路 Decimal、凭证零泄露——这些关键纪律执行到位，**未发现会直接造成资金损失的逻辑错误**。
- 主要债务集中在两处：①**输入侧/认证侧的安全收尾**（symbol 白名单、请求头信任、限流绕过、回测无界）——数量不多但都是真实资金环境不可接受的；②**简练性欠账**——后端约 600+ 行死代码/重复函数、4 个 150~320 行巨型函数、3282/3465/3769 行的三个巨石文件；前端约 300 行死代码、6 套数值解析并存、多处成段复制。

### 各模块评分（简洁性 / 健壮性 / 复杂度控制，各 1-10）

| 模块                                                                      | 简洁性 | 健壮性 | 复杂度控制 | 一句话总评                               |
| ----------------------------------------------------------------------- | --- | --- | ----- | ----------------------------------- |
| trading 核心（services/balance_cap/external_positions/execution）           | 5   | 8   | 6     | 资金纪律教科书级，事务跨网络 I/O 是最大隐患            |
| trading 视图（views.py 3282 行）                                             | 4   | 7   | 3     | 幂等/恢复出色，但 symbol 白名单与模式头两处缺口 + 上帝模块 |
| positions                                                               | 6   | 8.5 | 5     | 计算与状态机几乎无可挑剔，views.py 巨石是主要问题       |
| common（binance.py 3769 行）                                               | 6   | 8.5 | 5     | "结果未知"语义/脱敏/限频是全仓最强项，三成是样板与遗产       |
| accounts / users / invites                                              | 7   | 7   | 6     | 基本面扎实，密码重置/限流三个问题集中在一条攻击面           |
| signal_research / api_bindings / market_analysis / watch_plans / riskon | 7   | 8   | 7     | 无注入面、防前视完备；回测无界与信号丢失需修              |
| 前端 pages（1.44 万行）                                                       | 5   | 8   | 5     | 竞态防护示范级，复用不足导致体量膨胀                  |
| 前端 shared/components/app                                                | 6   | 8   | 6     | token/刷新/重试设计正确，收尾欠账多               |

**综合：健壮性 ≈ 8，简洁性 ≈ 5.5，复杂度控制 ≈ 5.5。** 即：强壮基本达标，"简练、不繁杂"是当前最明确的短板。

---

## 二、必须修复（P0，合并去重后 11 项）

### 后端

**P0-1 trading/views.py:1759、2171 — 开仓与限价委托接口未校验 symbol 白名单**
`TradeOpenView` 与 `LimitOrderCreateView` 只做 `to_inst_id()`，`ALLOWED_TRADING_SYMBOLS` 只在行情视图生效。用户可对白名单外任意 USDT 合约开仓。
修复：解析 symbol 后立即校验 `normalized_symbol in ALLOWED_TRADING_SYMBOLS`，否则 `fail("不支持的交易对")`。

**P0-2 common/trading_mode.py:15 + views.py 各调用点 — 交易模式由客户端请求头 `X-Trading-Mode` 决定**
任意用户可请求 lead 模式，走不同资金预检路径；视图层唯一闸门（是否持有 LEAD 绑定）可能低于 ordinary 的资金下限。
修复：模式改为服务端按绑定记录判定，或在 adapter 分发处校验用户对该模式的权限。

**P0-3 common/binance.py:1111-1177（`_recover_algo_submit`）— 条件单失败恢复只查挂单列表，漏掉终态**
恢复窗口内条件单若已被触发/撤销，挂单列表查不到 → 把"已存在的止损单"误报为提交失败。止损被触发恰是资金最敏感时刻。文件内已有 `get_algo_order_by_client_id`（含终态查询）未用。
修复：恢复链路 = 挂单列表 → 兜底单条终态查询。

**P0-4 trading/services.py:2492 — `transaction.atomic()` 内跨越交易所网络 I/O 与 sleep 重试**
`run_strategy_engine` 在 DB 事务 + `GET_LOCK` 内做交易所调用（失败 sleep 1+2+4s）。10 个调度线程可钉住 10 个长事务，MySQL 下有连接池耗尽与锁超时风险；同文件 2997 行的对账路径却无事务包裹，口径不一致。
修复：去掉该层 atomic（该路径无需多行原子写），只包 DB 写入段。

**P0-5 users/views.py:413-418 — 密码重置接口可被恶意 uid 触发 500**
`urlsafe_base64_decode` 结果未校验数字即查库，`base64("abc")` 直接 500。
修复：`user_id.isdigit()` 校验后返回 400。

**P0-6 users/views.py:46-48 — 登录/注册/重置限流信任可伪造的 `X-Real-IP`**
任一部署点未强制反代覆盖该头，客户端即可伪造 IP 绕过 IP 维度限流。
修复：只信 `REMOTE_ADDR`，或加默认关闭的 `USE_X_REAL_IP` 开关 + 部署检查。

**P0-7 signal_research/views.py:307-327 + services.py:185-206 — 回测无时间范围/分页上限**
1 分钟级多年回测 ≈ 350+ 次币安请求，可打穿共享 2400/min 限流预算，殃及所有用户的交易请求。
修复：BacktestView 强制跨度上限（如 30 天）+ 根数上限；`fetch_candles` 循环加最大页数熔断。

**P0-8 market_analysis/trend.py:325 vs 327-342 — 信号去重标记先于推送执行**
发送失败后该 K 线入场提醒既未发出也永不重试。
修复：`_trend_mark_close` 移到发送成功之后。

### 前端

**P0-9 tools/src/shared/lib/manualEntryCapital.ts:33-35 — `Number.EPSILON` 精度补偿对大额资金失效**
`Number.EPSILON` 是 1 附近的 ULP，×100 后仅补偿 2.2e-14；差额 >2 USDT 时 `floor` 仍会少算 0.01，导致归集门槛判断偏差。
修复：改用量级匹配的容差 `Math.floor(diff * 100 + 1e-6) / 100`。

**P0-10 tools/src/pages/holdings/index.tsx:288-349 — 生产持仓页每次挂载向 localStorage 重新注入 Mock 演示数据**
用户在指标页删除的演示指标会被悄悄复活，演示代码驻留生产主流程。
修复：删除，或改为带版本号 key 的一次性迁移。

**P0-11 tools/src/pages/holdings/index.tsx:2036-2066、1080-1132 — 死代码弹窗 + 轮询依赖错误**
"取消止盈策略"弹窗无任何触发点（且向 `PositionData` 写不存在的 `direction` 字段）；持仓轮询 effect 依赖 `positions.length`，每轮开平仓都销毁重建轮询循环、清零退避状态。
修复：删除死弹窗块；去掉 `positions.length` 依赖。

---

## 三、建议修改（P1，按主题归并）

### 安全与健壮性

1. **notifications.py:222-232** 内部通知允许 http 且 `urlopen` 默认跟随重定向（会携带 X-API-Key 转发到重定向目标）。对比 `external_trade_signals.py` 已有强制 HTTPS + 禁重定向，应同样处理。
2. **positions/views.py:2440-2459** 平仓探测块 `except Exception: pass` 吞掉一切编程错误，估值以 `close_price=open_price` 入库。应收窄为 `BinanceApiError`。
3. **external_positions.py:657-661** 采纳已有止损时 `workingType` 缺失会 `raise ValueError` 卡死该仓位整个保护循环。应回退 `"CONTRACT_PRICE"` 并记日志。
4. **strategy_views.py:179-182** 策略设活切换两步无行锁，并发下可双活跃策略。用 `select_for_update`。
5. **binance.py:3508-3530** `_get_today_realized_pnl` 裸 `except: return "0"`，限频故障时今日盈亏静默归零。应记 warning 并返回 None。
6. **views.py:537** `hmac.compare_digest` 遇非 ASCII token 头抛 TypeError → 500。按字节比较。
7. **users/views.py:425-427** 密码重置成功不 blacklist 旧 refresh token，旧会话仍可操作资金账户。
8. **api_bindings/services.py:337-364** 绑定冲突检查在只读路径遍历全部 legacy binding 逐条解密并惰性写库。应一次性命令回填指纹后删除该分支。
9. **riskon/settings.py** 全局无 DRF throttle：`strategies/generate`（90s AI 调用）、`backtest`、`samples/fetch` 可被登录用户并发刷量。加 ScopedRateThrottle。
10. **binance.py:857-867** 三元 `or` 链优先级歧义，market 分支取到 None 时静默失去步长取整（当前靠上游不变量兜底）。改显式 if。
11. **accounts/views.py:347-351** 归集目标地址仅做 ASCII/空格级校验，应按网络（EVM `0x`+40hex / TRX base58check）前置格式校验。
12. **positions/views.py:2026、2084** GET 列表接口带写副作用（save + 把交易所上同规格 TP"认领"到本地单，可被本系统撤销）。认领应限 `ORIGIN_EXTERNAL`。
13. **trading/open_requests.py:62-76** `get_or_create` 未捕获并发 `IntegrityError`，竞态下 500 而非幂等提示。
14. **services.py:1522-1547**（存疑确认）1 分钟 K 线极值只取最新一根，轮询被跳过且恰逢 K 线切换时极端价永久丢失，可能漏触发层级止损。建议取最近 2-3 根。
15. **binance.py:1830** 限频冷却无差别阻塞撤单；撤单应比查询优先放行。

### 简练性与结构（去重/死代码/拆分）

1. **trading/views.py（3282 行）**：三大开仓视图（Open/LimitCreate/Chase，约 1085 行）共享同一骨架，重复约 600 行；serializer 错误提取 5 处复制。提取 `_run_entry_flow()` + `_handle_entry_exception()` 可减 40%。建议按"行情/开仓/限价/TV 信号"拆文件。
2. **positions/views.py（3465 行）**：约 1300 行后台结算/对账逻辑住在视图文件里，拆出 `settlement.py`/`maintenance.py`；残留保护单持久化逻辑两份实现（views.py:1957 vs cleanup.py:626）收敛为一处；`_to_decimal` 等 helper 三份重复。
3. **binance.py（3769 行）**：四个余额方法、三个条件单创建（stop_loss/stop_market/take_profit）、`_public_json_request` HTTP 回退共约 280 行样板可提取压缩；5 个无调用死方法删除——其中 `amend_stop_loss_order`（只开新单不撤旧单）最危险，谁误用谁双倍挂单。
4. **trading/services.py**：`_place_stop_loss_verified`（24 行）、`_strategy_level_reached` 死代码删除；`_calc_take_profit_trigger_price` 与 `_calc_trigger_price` 逐字重复；`_select_next_level` 的 `reduce_done` 死逻辑清除。
5. **scheduler.py:235-481** `start_scheduler` 245 行、17 个雷同 `add_job`，表驱动可压到约 60 行。
6. **前端死代码约 300 行**：`shared/hooks/index.ts` 7 个 hook 全部无调用方；utils 半套未用（formatMoney/maskString/debounce/throttle 等）；`react-hot-toast` 渲染了 `<Toaster>` 但全仓零调用，与自研 toast 构成双系统；`shared/types` 一批无引用类型。全部删除。
7. **前端 6 套数值解析并存**（parseNumber/safeParseNumber/parseOptionalBalance/amount/formatDisplayNumber/formatSmartAmount），语义互不一致。统一为 `shared/lib` 一个 `parseAmount()` + 2-3 个格式化函数。
8. **前端"账户会话作用域"12 参数闭包样板 6 处逐字复制**（StopLossSettingsModal×3、ApiBindModal×3、ApiUnbindButton、App.tsx×2）。抽 `useAccountScopedRequest()` 净减约 100 行。
9. **前端重复块**：持仓/限价两套轮询 effect、holdings 与 signals 两套下拉刷新（90 行×2）、两套 symbols 缓存、4+ 套日期格式化、holdings 与 trading 逐字重复的 API 绑定弹窗。抽 `usePolling`/`usePullToRefresh` 净减约 300 行。
10. **前端超长文件**：holdings 2357 行（25 个 useState，可拆 `useHoldingsData` 降到 <800 行）、KlineChartCard 1523 行（指标计算/自定义系列/设置面板可拆）、signal-research 1283 行。
11. **invite 模块整体是死代码**：只有生成命令，无任何兑换路径。接入注册流程或移除该 app。
12. **api_bindings/mode_middleware.py**：LEAD_PATHS 硬编码 40+ 条路径与 URLconf 双维护，改 `resolve()` 反向解析。
13. **周期时长表三处重复**（signal_research / market_analysis / trend），收敛到 `trading.constants`。

### 其他值得注意

- **前端涨跌颜色为"绿涨红跌"（币安国际惯例），且同一语义 4 套色值**。若面向大陆用户需"涨红跌绿"，建议先收敛为 CSS 变量 `--t-up/--t-down` 一处切换。
- **transfer_history 换绑 API key 后旧指纹记录永不清理**，表只增不减。
- **binance.py 的 OKX 兼容层**（`instId "X-USDT-SWAP"`、`_legacy_*`）是 3769 行复杂度的主要来源，边界收敛可再删 20-30%，留作独立重构窗口。
- **binance.py:2457 等 5 处限频日志同步外呼 ipify.org**（配置了 SERVER_PUBLIC_IP 却未使用），应优先读配置、外呼放后台。
- **watch_plans 更新视图 140 行手工 if 树**且非法值静默通过，改 DRF serializer。
- 前端 `formatSmartAmount` 极小值可能输出科学计数法上屏；`totalPositionsPnl` 用浮点累加多笔盈亏，合计与逐笔之和可能差 1 美分。

---

## 四、值得肯定（审计确认的优势）

1. **资金安全纪律**：journal-before-write（划转先落 `*_attempted_at`）、结果未知不重发、先建新保护再撤旧保护、紧急平仓双确认、仓位消失连续两次确认。
2. **幂等与恢复**：clientOrderId 幂等键 + 恢复时校验 size/side/posSide 防串单；TradeOpenRequest 状态机 + 409 不确定结果语义。
3. **凭证治理**：AES-GCM + AAD + key 版本化轮转、日志白名单 + `safe_error_summary` 正则脱敏、API key 只出 fingerprint 不出网、`sanitizeApiConfigs` 落盘前清密钥。**全仓未发现凭证泄露路径**。
4. **signal_research 安全设计**：AI 生成的"策略代码"从不执行，唯一执行路径是硬编码 `strategy_signal()` + 白名单参数钳制，注入面为零；三重防前视（拒未来样本/收盘过滤/采集时间下界）并有专项测试。
5. **通知链路**：`transaction.on_commit` + 事件队列 + 租约重试 + 乐观条件更新，完全符合"不绑定交易成功路径"的项目规则。
6. **前端竞态防护**：requestId + 账户会话/交易模式双 revision、定时器/WS 全清理、可见性暂停、指数退避 + 抖动、token 内存存储 + 单飞 refresh、POST 不盲重试——示范级。
7. **生产配置守卫**（riskon/settings.py）：SECRET/AES 强度、CORS、多进程强制 Redis 硬校验，可作为模板。
8. 测试覆盖扎实（幂等、限频中断、回滚、权限矩阵、并发竞态均有专项）。

---

## 五、修复路线图（建议顺序）

| 批次    | 内容                                                                                        | 性质                  |
| ----- | ----------------------------------------------------------------------------------------- | ------------------- |
| 第 1 批 | P0-1 ~ P0-8（后端安全收尾）                                                                       | 真实资金环境不可接受的缺口，修复成本低 |
| 第 2 批 | P0-9 ~ P0-11 + P1 前端健壮项（EPSILON/Mock/轮询/吞异常/HTTP 通知）                                      | 前端资金判断与生产卫生         |
| 第 3 批 | P0-4（事务跨网络 I/O）+ P1 中 workingType/1m 极值采样两个存疑项                                            | 并发与保护触发边缘           |
| 第 4 批 | 纯减法：删死代码（后端 ~600 行 + 前端 ~300 行）、合并重复函数/样板                                                 | 零风险纯收益              |
| 第 5 批 | 结构重构：views.py×2 拆分、binance.py 样板提取、前端 usePolling/useAccountScopedRequest/金额工具统一、OKX 兼容层收敛 | 独立重构窗口，配测试          |

---

*报告基于 2026-10-01 工作区代码（分支 codex/manual-position-protection，含未提交改动）。行号以当日工作区为准。*
