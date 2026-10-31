# 交易系统底座收敛实施计划

> 执行方式：在当前工作区按批次实施；不触发真实开平仓、资金划转或撤销保护单。

**状态（2026-09-11）：** 六批代码、边界补强、本地全量验证、生产密钥轮换、最终发布与线上只读验收均已完成；发布版本为 `810738d`。隔离 MySQL / Redis 并发验证仍待执行。最终 Django 全量发现 597 项、执行 592 项并通过，1 项按设计跳过；前端全量 68 项、lint、typecheck、生产构建通过；webhook 28 项通过；Python 与 npm 依赖审计均无已知漏洞。跳过项正是需要隔离 MySQL / Redis 的并发契约，不能视为已通过。

**目标：** 在不改变现有产品规则的前提下，收紧交易身份、交易所请求、核心编排、故障分类和并发验证边界，为后续带单模式建立可验证的基础。

**架构：** 先用特征测试冻结当前行为，再引入由 API 绑定派生的 `TradingAccountContext`，使缓存、锁、幂等和客户端创建不再直接把 Web 用户当作交易账户。Binance transport 增加跨进程共享的保守预算与响应头校准；业务层将确定性凭证错误持久化熔断。复杂视图只保留 HTTP 适配，计算和状态转换逐步下沉到窄服务。

**技术栈：** Python 3.11、Django 5.2、DRF、MySQL 8.4、Redis 7、React 18、TypeScript。

---

### 第一批：冻结现有行为和交易身份边界

**文件：**

- 新增：`server/api_bindings/context.py`
- 修改：`server/api_bindings/services.py`
- 修改：`server/trading/locks.py`
- 测试：`server/api_bindings/tests.py`
- 测试：`server/trading/tests.py`

**步骤：**

1. 为有效、无效、缺失绑定编写账户上下文测试。
2. 建立不可变 `TradingAccountContext`，包含 Web 用户、绑定、Key 指纹、稳定命名空间和客户端工厂。
3. 保留旧凭证读取函数作为兼容入口，并让其统一经账户上下文解析。
4. 新增账户级锁键生成器，同时保留现行用户级资金/交易互斥语义。
5. 运行 API 绑定及交易特征测试，确认响应和数据库状态不变。

### 第二批：Binance transport 与限频收敛

**文件：**

- 新增：`server/common/binance_rate_limit.py`
- 修改：`server/common/binance.py`
- 修改：`server/riskon/settings.py`
- 修改：`server/.env.example`
- 测试：`server/common/tests.py`

**步骤：**

1. 编写共享分钟预算、低优先级拒绝、关键请求保留额度、响应头校准及缓存失效降级测试。
2. 用 Redis/Django cache 保存 IP 级 `REQUEST_WEIGHT` 观测值；缓存不可用时只降级观测，不阻断保护动作。
3. 从 Binance 响应头同步实际权重和订单计数；429/418 读取 `Retry-After` 并进入共享冷却。
4. 为低优先级历史/账本查询设置软阈值，为普通私有请求设置硬阈值，为交易写入与保护查询保留预算。
5. 所有阈值使用配置项，并在配置文档注明其为本地保护线，不伪装成交易所固定契约。

### 第三批：确定性凭证故障熔断和可观测性

**文件：**

- 修改：`server/api_bindings/models.py`
- 新增迁移：`server/api_bindings/migrations/`
- 修改：`server/api_bindings/services.py`
- 修改：`server/trading/scheduler.py`
- 修改：后台账户遍历入口
- 测试：`server/api_bindings/tests.py`
- 测试：对应 scheduler/service 测试

**步骤：**

1. 编写连续确定性认证失败、瞬时错误不计数、成功恢复清零和熔断后 scheduler 跳过测试。
2. 持久化连续认证失败次数、最后失败时间和简短失效原因，不保存交易所原始敏感响应。
3. 仅对明确认证代码累计；达到阈值后将绑定置为无效并只记录一次错误级事件。
4. 成功私有请求清零暂态失败计数；手动重新校验或重绑可恢复。
5. 将 scheduler 每任务重复 Traceback 调整为按账户归类、可检索且不持续刷屏。

### 第四批：核心编排拆分

**文件：**

- 新增：`server/trading/opening.py`
- 新增：`server/positions/projection.py`
- 拆分：`server/positions/cleanup.py`
- 修改：`server/trading/views.py`
- 修改：`server/positions/views.py`
- 修改：`server/trading/services.py`
- 测试：`server/trading/tests.py`
- 测试：`server/positions/tests.py`

**步骤：**

1. 为开仓幂等恢复、部分成交、保护失败和资金门槛响应补充特征测试。
2. 提取开仓请求身份、成交确认、订单落库和保护结果解释为窄函数；HTTP view 只做校验与响应映射。
3. 提取持仓金额、盈亏、保证金、止损/止盈展示为纯投影函数。
4. 将已关闭订单清理拆成条件单发现、普通单确认和结果归并三个阶段。
5. 将保护对账按账户快照、单订单决策和执行动作拆分，保留原重试及触价行为。
6. 对拆出的纯函数做边界测试，并比较 API 响应快照不变。

### 第五批：生产并发契约验证

**文件：**

- 新增：`server/integration_tests/`
- 修改：`docker-compose.yml` 或新增隔离测试 Compose 文件（不连接生产凭证）
- 修改：`docs/development.md`

**步骤：**

1. 增加 MySQL 下活动归集唯一槽位并发测试。
2. 增加 Redis 下跨进程账户锁和 IP 请求预算测试。
3. 增加交易请求幂等键并发创建测试。
4. 将集成测试设为显式环境开关，默认单元测试不依赖本机服务。
5. 在隔离容器中运行迁移和并发测试，记录实际结果。

### 第六批：安全配置、文档和全量复审

**文件：**

- 修改：`server/riskon/settings.py`
- 修改：`server/.env.example`
- 修改：`docs/architecture.md`
- 修改：`docs/development.md`
- 修改：`docs/configuration.md`
- 修改：`docs/known-issues.md`
- 修改：`docs/changes.md`（仅在真实部署后记录线上验收）

**步骤：**

1. 生产环境强制使用独立 AES 密钥；补充密码策略和登录 IP 级节流的兼容性测试。
2. 全量运行后端、前端、Webhook、Django、迁移、构建、lint、依赖审计和差异检查。
3. 重新统计复杂度、宽泛异常、静默异常、账户身份直连和 Binance 请求入口。
4. 对仍未达标的项目逐项修复或明确保留原因，不以机械格式化替代风险修复。
5. 更新唯一主题文档，区分当前实现、待验证和未来带单模式，不声称未进行的生产验收。

## 完成门槛

- 现有单账户业务 API 和界面行为保持不变。
- 交易账户身份可在不依赖 `user_id` 的情况下生成缓存、锁和幂等命名空间。
- Binance IP 权重和订单计数可跨进程协调，保护/交易请求不会被低优先级历史查询挤占。
- 确定性失效凭证不再无限进入 scheduler。
- 核心状态转换有纯函数或窄服务测试，不再只依赖大视图端到端 mock。
- MySQL、Redis 并发关键路径有可重复的隔离验证方式。
- 全量检查通过，剩余风险在 `docs/known-issues.md` 明确登记。

## 实施结果

- 六批功能均已落入现行模块，并由主题文档维护长期规则；本计划不替代这些文档。
- 最终复审补齐 API 绑定生命周期锁顺序、锁内绑定代际复核、资金流水 Key 指纹隔离、严格五分钟划转历史匹配、平仓归因事件持久化顺序、减仓投影与事件原子提交，以及前端账户请求的单调代际保护。
- 复审仍有 48 个 `C901` 高复杂度函数，集中在交易、持仓、资金状态机和 Binance 适配层；它们已有回归测试，本轮不做纯指标驱动的高风险拆分，后续带单模式必须从独立账户模式上下文和适配器接入。
- 本地无法启动 Docker，隔离并发测试保留在 `docker-compose.integration.yml` 与 `server/integration_tests/`，结果未伪装为已验收。
- 生产配置、部署 SHA、迁移、容器健康、scheduler 心跳、日志及未推进旧归集流水的只读结果已记录到 [变更记录](../changes.md)。
