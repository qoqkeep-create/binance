# Python 后端与原生 iOS 整合实施计划

> 使用 executing-plans 按任务实施；用户已于 2026-10-31 批准整套方案、目标服务器部署及本地 Xcode 运行验证。

**Goal:** 在本目录交付原 USDT Python 业务后端、Java 方案行情和原生 iOS 业务客户端，并部署至首尔测试服务器。

**Architecture:** 原 USDT 与 USDC 目录只读，所有交付修改位于本目录。Python Django 保留原业务服务；新增独立行情采集、持久化、Redis 分发与 ASGI WebSocket，以及持久化命令和账户事件归并。SwiftUI 保留现有行情及 Metal 图表，其余页面映射原 USDT Web 的业务与布局。

**Tech Stack:** Django / DRF / MySQL / Redis / ASGI / Python WebSocket；SwiftUI / Metal / Xcode。

## 授权与隔离

- 来源 `/Users/apple/work/TradeTools-Binance` 与 `/Users/apple/work/tradetools-usdc` 只读；父目录中的本整合子目录为唯一代码写入范围。
- 部署目标为 `47.80.22.243`；使用已有 SSH 密钥，凭证保留于忽略文件，部署使用独立目录和数据库，保留原服务器应用及数据。
- 本地原目录源码哈希基线位于 `/tmp/tradetools-originals-baseline.json`，结束后核对；不复制 Git、密钥、依赖与构建产物。
- 保留 USDT 资金、模式身份、极值、幂等和保护规则；账户流只驱动既有业务服务，不另造交易策略；验收不使用真实交易。

## Task 1：复制与项目边界

Files: `server/`, `tools/`, `indicators/`, `docs/`, `README.md`, `.gitignore`, `AGENTS.md`。

1. 从来源文件清单复制有效源码及必要未跟踪测试，跳过目标自身；碰撞的根文档保留来源副本。
2. 合并忽略规则和项目指引，声明 Python 为运行后端，现有 Java 代码保留作参考。
3. 逐文件校验复制清单和来源哈希，确保没有生产配置与私钥。

## Task 2：行情和 iOS 协议

Files: `server/market_stream/`, `server/mobile/`, `server/riskon/{settings,urls,asgi}.py`, `server/requirements.txt`。

1. 测试行情标准化、1m 完整桶聚合、缓存新鲜度、历史分页及去重。
2. 实现原生 1m / ticker 采集，MySQL 收线、Redis 热数据和跨进程发布；REST 历史补齐及缺口修复。
3. 实现与现有 iOS 协议一致的鉴权 HTTP、快照、订阅、心跳、序号和 WSS，限制慢客户端队列。
4. 验证原 HTTP 业务兼容、用户隔离和真实只读行情。

## Task 3：账户事件与持久化命令

Files: `server/mobile/{models,commands,account_stream}.py`, migrations, tests, management commands。

1. 测试命令幂等、账户/模式隔离、未知结果恢复和重复事件。
2. 持久化命令并逐账户串行调用原业务入口；安全续期、数据库身份和绑定代际参与执行校验。
3. 接入用户事件流，Inbox 去重、事件提示和 Outbox；保留原 REST 维护与安全边界。
4. 用伪交易所测试故障路径，不绑定真实资金做验收。

## Task 4：SwiftUI 业务页面

Files: `frontend/ios-app/TradeTool/Features/USDT/`, `App/RootView.swift`, `Core/Auth/`, config and native tests。

1. 盘点原 Web 页面、字段、弹窗、权限和接口，形成对应表。
2. 底部依次为行情、持仓、开仓、信号、我的；带单隐藏信号；行情页面和图表保留 USDC 布局。
3. 实现登录/注册、交易表单、持仓及历史、策略及编辑、信号、观察、研究、资金、转账、日志和设置等原生界面与操作。
4. 对接 Python 模式选择、账户绑定与生命周期，所有页面使用原生组件。

## Task 5：构建、运行和部署

Files: `deploy/integrated/`, `compose.integrated.yaml`, `docs/INTEGRATION.md`, `docs/changes.md`。

1. 执行 Python 定向和原业务回归、迁移检查；iOS XCTest 与编译。
2. 本机 Xcode 运行原生客户端并观察登录、Tab、行情和主要页面；设备/模拟器环境不足时先处理运行环境。
3. 构建独立服务镜像，在服务器独立数据库执行迁移并启用 API / 行情 / 命令进程；保留回滚材料。
4. 以 HTTPS / WSS 验收认证、分页、行情及隔离；不做真实开平仓或资金操作。
5. 更新文档、来源哈希、未跟踪文件和格式检查；仅暂存本目录交付文件。

## 进度

- [x] Task 1：复制及隔离已完成，最终哈希核对见验收记录
- [x] Task 2：行情采集、协议、历史和真实只读行情已验证
- [x] Task 3：命令、事件流及恢复测试已完成；真实交易未做验收
- [x] Task 4：原生页面映射及补齐完成，运行验证范围见验收记录
- [x] Task 5：独立首尔发布、HTTPS / WSS、MySQL 迁移和本地 Xcode UI 流程已验证；2026-10-31 的真实范围及剩余边界见 `docs/changes.md`
