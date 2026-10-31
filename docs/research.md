# 信号研究与观察计划

> 本文维护整合版沿用的业务规则；当前运行与验证边界见 [整合说明](INTEGRATION.md)。来源项目历史资料从 [来源索引](sources.md) 查询。

本模块与实盘交易隔离。AI 生成、回测或趋势信号不构成自动下单指令，不能把研究按钮接到交易执行而不进行独立设计。

## 当前入口

- 原生“我的 → 信号研究”：[研究页面](../frontend/ios-app/TradeTool/Features/USDT/USDTResearchViews.swift)。
- API `/v1/signal-research/`：[urls.py](../server/signal_research/urls.py)，提供样本、规则、策略、预览 / 生成 / 发布、模型列表 / 激活、回测及图表。
- 数据和服务：[models.py](../server/signal_research/models.py)、[services.py](../server/signal_research/services.py)、[ai.py](../server/signal_research/ai.py)。
- 观察计划独立位于 [watch_plans](../server/watch_plans/models.py)，包含计划、复盘、评分等用户资料，不归并为交易订单。

## 工作流

```text
用户样本 / 规则 --> 拉取历史与构建研究数据包 --> 预览或显式 AI 生成
                --> 策略草稿 --> 发布不可变版本 --> 回测与图表复核
```

样本和策略按用户归属限制读写。已发布策略保持不可变，回测使用已发布版本；不能编辑旧发布记录使同一个版本号对应不同规则。

编辑和发布均以 `status=draft` 为 SQL 更新条件。发布已先完成时，并发编辑返回不可编辑，不能用旧对象整行保存覆盖发布时间或发布内容；不另设一套发布锁或版本状态机。

研究数据限定于当时已知的闭合 K 线，避免引入未来数据。AI 输出被解析为有限的 JSON 策略定义，不执行任意生成代码。修改研究数据包、回测信号对齐、费用或撮合规则时更新测试和可复现样例，禁止仅凭收益曲线证明正确。

创建与采集拒绝未来样本时间；采集只保留收盘时间不晚于样本时间和本次请求开始时间的 K 线。没有闭合候选时明确失败，不回退到最后一根未闭合 K 线。规则证据、预览和 AI 生成仅使用 ready、样本时间已到且 `fetched_at >= signal_time` 的记录；旧记录缺少采集时间或提前抓取过，须重新采集后才能进入研究数据包，不删除原始样本。

## AI 模型归属

`ResearchAiModel` 是全局模型目录，没有用户外键，API Key 加密保存；`ResearchAiModelSelection` 保存每用户的选择。模型列表提供脱敏信息，激活影响当前用户选择。

当前路由没有用户自行创建私人模型的接口，不能按旧“每人私有模型库”方案编写使用说明。环境 `AI_*` 仍提供默认模型配置，但不意味着所有凭证仅存环境中。配置生效规则见 [配置字典](configuration.md)。

AI 调用由用户显式触发，可能耗时并消耗服务额度；预览数据包与实际调用需分开。失败应反馈研究状态，不影响实盘保护、资金操作或其他用户策略。

## 与内部趋势扫描的区别

`market_analysis` 当前承担 [trend.py](../server/market_analysis/trend.py) 的自有趋势扫描；旧设计里的 HTTP 市场分析服务 / 页面没有对应当前路由，不应恢复过期路径作为兼容层。

扫描只看闭合 K 线并按周期去重，输出显示于信号内部页签。研究样本、趋势状态与统一消息的保留期 / 用户归属不同，不能因模型历史命名相近而合并数据表。

验证以 [signal_research/tests.py](../server/signal_research/tests.py)、[market_analysis/tests.py](../server/market_analysis/tests.py)、[watch_plans/tests.py](../server/watch_plans/tests.py) 为入口，覆盖跨用户权限、时间边界、版本不可变、模型脱敏和生成失败。
