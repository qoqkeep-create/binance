# 整合项目协作规则

先读 [文档目录](docs/README.md)，按任务查阅主题主文档。架构以 [整合说明](docs/INTEGRATION.md) 为准，开发和验证见 [开发文档](docs/development.md)。

## 代码与来源

- 当前交付仅包含 `server/` Python / Django 后端、`frontend/ios-app/` SwiftUI / Metal 客户端和 `deploy/integrated/` 部署配置。
- 原 USDT、USDC 目录只读；查历史代码使用 [来源索引](docs/sources.md)，所有修改留在本目录，保留用户已有改动。
- 行情为原生 1m、多周期聚合、ticker 与鉴权 WSS；资金使用 Decimal，账户模式、绑定代际、幂等和保护遵守 [交易安全](docs/trading-safety.md)、[资金](docs/capital-and-transfers.md) 与 [带单模式](docs/lead-trading.md)。
- 数据变更使用 Django 版本化 migration。通知使用事件和独立投递记录，交易成功路径不直接依赖外部发送结果。

## 发布与验证

- 整合环境目标为 `47.80.22.243`（首尔服务器），独立目录、数据库和入口见 [运维](docs/operations.md)。每次向用户提及服务器操作或状态都写出 IP＋备注，例如“已部署到 47.80.22.243（首尔服务器）”。使用已有 SSH 认证，真实凭证仅放忽略且受限的文件。
- 普通测试使用隔离数据库和交易所替身，不真实开平仓、划转或撤保护单。区分本地构建、服务器验收、TestFlight 上传和实机结果。
- 本目录位于来源 Gitee 仓库内；整合版 GitHub 的独立 Git 元数据与命令见运维文档，保留父仓库配置和其他改动。
- 完成后保留本地改动，收到用户明确“推送”指令再上传 GitHub；每次授权按本次任务范围执行。
- 完成后更新对应主题文档与验证范围，执行 `git diff --check` 和未追踪文件检查。安全的新交付文件加入追踪；凭证、构建和 IDE 用户状态保持忽略。
