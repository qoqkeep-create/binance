# 整合项目协作规则

先读 `docs/README.md` 与 `docs/plans/2026-10-31-python-ios-integration.md`；交易、资金和身份规则见 `docs/trading-safety.md`、`docs/capital-and-transfers.md` 和 `docs/lead-trading.md`。

## 当前架构与写入范围

- 主后端为 `server/` 中的 Python / Django，原生客户端为 `frontend/ios-app/`。`backend/app-service/` 保留 Java 参考实现。
- 原 `/Users/apple/work/TradeTools-Binance`（本子目录以外）与 `/Users/apple/work/tradetools-usdc` 为只读来源；所有交付修改留在本目录，保留已有改动。
- 行情采用原生 1m、多周期聚合、ticker 快照与 WSS；iOS 行情和 Metal 图表沿用 USDC 布局，其他业务原生复刻 USDT。
- Python 数据结构使用 Django 版本化 migration；Java 参考模块仍使用 Flyway。金额保持 Decimal，模式、绑定代际与幂等遵守原业务规则。

## 部署与验证

- 用户已批准部署至 `47.80.22.243`；使用独立目录、数据库和入口，保留旧环境。原 USDT 生产地址不是本任务发布目标。
- 优先使用 SSH 密钥；密码、Token、私钥和环境文件只放忽略且权限受限的位置，日志脱敏。
- 后端测试使用独立测试数据；前端执行 Xcode 构建与本地运行。验证不得真实开平仓、划转或撤保护单。
- 更新对应主题文档、目录和验收日期，区分本地、服务器与待验证范围。
- 结束检查 `git diff --check` 与 `git ls-files --others --exclude-standard`，安全的新交付文件加入追踪；仅暂存本目录相关改动。
