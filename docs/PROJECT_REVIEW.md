# 项目审阅报告

- 审阅日期：2026-10-30（Asia/Shanghai）
- 来源：`https://gitee.com/td0328/trade-tool.git`
- 审阅基线：`master` / `3769ee636f12f8748725a68ce8c254b0117c6385`
- 本地目录：`/Users/apple/work/tradetools-usdc`
- 方法：静态阅读核心链路、文档与配置交叉核对、运行现有脚本测试和构建检查；原有文件行号按审阅基线记录。
- 范围限制：未连接生产数据库、未验证凭证在线有效性、未调用真实交易接口；不是逐行安全认证或依赖漏洞全量扫描。

## 1. 结论

项目已具备 Java 后端、SwiftUI/Metal iOS 客户端、数据库迁移、交易命令与风控、实时推送及部署流水线。它已有较丰富的说明、专项计划和局部开发记录，缺少的是统一的项目计划、问题状态与持续跟进入口。

本轮确认 6 项问题：1 项 P0、3 项 P1、2 项 P2。最优先处理的是 Git 中已保存的凭证材料，其次是邮箱授权、WebSocket 用户禁用和敏感操作认证。交易及图表还有验收证据缺口，不能把“已有实现/历史测试通过”视为本轮完成运行验收。

本轮新增[统一计划](PROJECT_PLAN.md)和[开发跟进日志](DEVELOPMENT_LOG.md)，保留已有专项设计作为详细依据。除 README 文档入口外，本轮没有修改业务实现。

## 2. 已有文档、计划与记录

| 类别 | 已有位置 | 审阅结论 |
| --- | --- | --- |
| 项目说明 | [根 README](../README.md)、[iOS README](../frontend/ios-app/README.md) | 已有功能、技术栈、API、启动及环境说明；部分状态过期 |
| 项目上下文 | [PROJECT_CONTEXT.md](PROJECT_CONTEXT.md) | 记录数据链路、策略、迁移、历史问题与后续建议；最后核对日期为 2026-10-22 |
| 交易方案和实施计划 | [后端设计](TRADING_BACKEND_DESIGN.md)、[账户同步设计](TRADING_ACCOUNT_SYNC_DESIGN.md)、[R 执行说明](TRADING_R_EXECUTION.md) | 已有 Phase 1–3 设计、实现说明和上线前验收项 |
| 实时协议 | [REALTIME_WEBSOCKET.md](REALTIME_WEBSOCKET.md) | 已有鉴权、频道、心跳、重连和私有消息约定 |
| 图表计划与开发记录 | [KLINE_CHART_ARCHITECTURE.md](../frontend/ios-app/docs/KLINE_CHART_ARCHITECTURE.md) | 已有分阶段实施方案，以及多批次的实现、修正、失败与待补证据记录 |
| 决策与测试记录 | [Metal ADR](../frontend/ios-app/docs/ADR-0001-KLINE_METAL_STABILITY.md)、[阶段 0.5 报告](../frontend/ios-app/docs/KLINE_CHART_STAGE_0_5_TEST_REPORT.md) | 已有专项决策、性能/长稳证据；需按具体场景核对完成状态 |
| 维护和部署 | [Nginx 说明](../deploy/nginx/README.md)、[外部消息接口](../deploy/EXTERNAL_MESSAGE_API.md)、[AGENTS.md](../AGENTS.md) | 已有操作和维护约定；AGENTS 中核心策略描述落后于实现 |
| Git 历史 | `git log`，基线共 100 个可达提交 | 可追溯提交，但许多主题仅为“修复已知bug/新功能”，不能代替验收和改进日志 |

## 3. 实现概览

- 后端：`backend/app-service`，Java 25、Spring Boot 3.5.14、MyBatis-Plus、MySQL、Redis、Flyway、Sa-Token，ta4j 负责指标计算。
- iOS：`frontend/ios-app`，SwiftUI 页面、Keychain 会话、REST/WebSocket 客户端与自研 Metal 图表。
- 行情：原生 `1m` 连续 K 线覆盖配置报价资产的全部目标合约，完整分钟数据聚合 `5m/15m/1h/4h/1d`；策略白名单不限制采集范围。
- 提醒：`15m/1h` 完整收线后检查 EMA144 回踩；`4h` 有独立盘中触达与持久化 24 小时冷却。数据库事务提交后分发通知。
- 交易：服务端加密保存凭证，账户流与 REST 对账构建事实镜像；命令幂等、账户行锁、租约/fencing、冻结执行快照和订单修复负责执行边界。
- 部署：本地/远程 Compose、Jenkins、Nginx；Dockerfile 在构建阶段运行 Maven 测试。

已有的合理设计包括：密码使用随机盐和 PBKDF2；凭证采用 AES-GCM 并绑定账户 AAD；主要 Mapper 使用参数绑定；交易归属在服务端检查；Flyway 承担结构变更。这些是本轮阅读确认的设计，不代表所有异常分支均已验证。

## 4. 已确认问题

优先级：P0 为立即处理，P1 为高优先级安全修正，P2 为应安排的防护或一致性修正。以下结论基于本地代码；除注明的离线校验外，未做在线利用或接口复现。

### R01 / P0：Git 跟踪了生产凭证材料

- 位置：`deploy/env.production`（来源路径，未随本整合交付） 第 4、19、20、22、25、32、42 行；[`application-dev.yml`](../backend/app-service/src/main/resources/application-dev.yml) 第 5、10、21 行。
- 证据：`git ls-files` 确认两份文件均已被跟踪；生产文件含非占位的数据库/Redis/管理员密码、交易凭证主密钥、APNs 私钥与旧版外部接口密钥。离线校验确认主密钥可解码为 32 字节、APNs 材料可被 OpenSSL 解析为私钥。未验证这些凭证是否仍在使用。
- 影响：任何可读取仓库及其历史的主体都能取得这些材料；若仍使用对应主密钥，取得数据库密文后可能进一步解密交易凭证。开发配置中的硬编码材料也会作为资源随应用打包。
- 建议：按已泄露处理仍有效的凭证；将实际配置迁至受控 Secret 注入，开发配置改为独立环境变量；停止跟踪真实配置并补充精确忽略规则、提交前与 CI 密钥扫描。移除当前文件不能清除历史，历史清理需协调使用该仓库的所有副本。
- 主密钥轮换须先设计旧凭证解密、重加密或重新绑定流程；直接替换主密钥会使现有密文不可读。本轮仅记录问题，没有轮换或删除配置。
- 跟进：`SEC-001`。

### R02 / P1：未经验证的注册邮箱可获得参考通知权限

- 位置：[`AuthService.java`](../backend/app-service/src/main/java/com/oovso/auth/AuthService.java) 第 61、112 行；[`ReferenceTradeNotificationAccess.java`](../backend/app-service/src/main/java/com/oovso/reference/ReferenceTradeNotificationAccess.java) 第 19 行。
- 触发：自助注册开启、配置的目标邮箱尚未被现有用户占用时，任意注册者可以把该邮箱作为账号。注册流程直接将其保存为邮箱并启用用户，没有验证邮箱归属；参考通知权限只比较该邮箱字符串。
- 影响：可取得原本限制给指定用户的参考交易通知及对应推送资格。已有账号唯一性检查会阻止抢注已占用的目标邮箱；本问题不等同于绕过已有账号的密码。
- 建议：按服务端明确授权的用户 ID/角色赋权，或先完成邮箱验证再授予权限；增加“未验证注册不能获得目标权限”的端到端回归。
- 跟进：`SEC-002`。

### R03 / P1：已连接的 WebSocket 不重新检查用户是否被禁用

- 位置：[`RealtimeHandshakeInterceptor.java`](../backend/app-service/src/main/java/com/oovso/realtime/RealtimeHandshakeInterceptor.java) 第 56 行；[`RealtimeWebSocketHandler.java`](../backend/app-service/src/main/java/com/oovso/realtime/RealtimeWebSocketHandler.java) 第 135 行；[`RealtimeEventPublisher.java`](../backend/app-service/src/main/java/com/oovso/realtime/RealtimeEventPublisher.java) 第 150 行。
- 触发：用户先登录并订阅频道，随后数据库用户被禁用/软删除，但其 Sa-Token 仍有效。握手会检查数据库用户状态，后续消息校验只检查 Token 和登录 ID；定期心跳能持续保活。出站分发也不检查用户启用状态。
- 影响：HTTP API 已拒绝该用户时，原 WebSocket 仍可接收已订阅数据，包括发给该用户的交易私有事件。
- 建议：在有界周期复核会话与用户状态，并在禁用/注销事件发生时关闭相应连接；增加建连后禁用用户、继续心跳和私有事件分发的集成测试。
- 跟进：`SEC-003`。

### R04 / P1：绑定、换 Key 和解绑缺少设计要求的近期密码确认

- 位置：[`TradingController.java`](../backend/app-service/src/main/java/com/oovso/trading/TradingController.java) 第 76、97 行；[`TradingAccountService.java`](../backend/app-service/src/main/java/com/oovso/trading/TradingAccountService.java) 第 84 行。
- 依据：[`TRADING_BACKEND_DESIGN.md`](TRADING_BACKEND_DESIGN.md) 第 160 行明确要求这些动作进行最近一次密码确认。
- 证据：当前绑定/更新凭证和解绑只要求普通登录 Token 及账户归属，没有短期操作凭证或重新认证校验；普通登录最长有效期为 30 天。
- 影响：被盗的长期会话足以替换交易凭证或停止账户管理。绑定还会调用交易所接口修改持仓模式和杠杆，属于有实际外部副作用的操作。
- 建议：实现短期重新认证凭据并绑定用户、敏感操作类型与过期时间；服务端强制校验，客户端提供对应流程。
- 跟进：`SEC-004`。

### R05 / P2：公开登录和注册入口没有仓库内可见的防爆破限制

- 位置：[`AuthController.java`](../backend/app-service/src/main/java/com/oovso/auth/AuthController.java)、[`AuthService.java`](../backend/app-service/src/main/java/com/oovso/auth/AuthService.java)、[`Nginx 示例`](../deploy/nginx/trade-tool.conf.example)。
- 证据：上述链路及仓库内 Nginx 配置没有登录失败计数、账号/IP 限速或注册配额。未知账号也执行 210,000 次 PBKDF2，避免时序枚举的同时使无限制请求消耗 CPU。币安 REST 的出站限流不能保护这些入口。
- 影响：可持续猜测密码或通过注册/登录请求消耗资源。仓库外的网关可能有额外防护，本轮无法确认。
- 建议：账号与来源维度联合限流、失败退避、注册配额和审计；不要只按账号永久锁定而引入恶意锁号。
- 跟进：`SEC-005`。

### R06 / P2：说明和配置漂移会误导开发及运行判断

| 位置 | 文档/默认声明 | 当前实现或配置 |
| --- | --- | --- |
| `AGENTS.md:13,34` | 仅原生 `1h`，三种回踩目标，不恢复聚合 | 原生 `1m` 并聚合多个周期，主目标为 EMA144，另有 4h 盘中逻辑 |
| `AGENTS.md:63`、`PROJECT_CONTEXT.md:1074` | 测试基线分别为 138 和 331 | 两者不是同一次运行；本轮未成功执行后端测试，不能替任一数字背书 |
| `PROJECT_CONTEXT.md:225` | 会话闲置 24 小时失效 | `application.yaml:30` 配置 72 小时 |
| `PROJECT_CONTEXT.md:298` | 账户同步默认关闭 | 直接运行的 YAML 回退值为 `true`；两份 Compose 与 `.env.example` 显式为 `false` |
| `frontend/ios-app/README.md:84` | Phase 1 只读、执行硬关闭 | 后端及 iOS 已有交易命令、划线下单；全局/账户执行开关已经删除 |
| 根 `README.md:247` | 本地运行不指定 profile | `spring.profiles.active=pro`，不会自动启用前文描述的 dev/Testnet |
| 根 `README.md:279`、`PROJECT_CONTEXT.md:877` | 动态币池要求上市 90 天 | YAML 实际为 180 天 |

此外，本地 `compose.yaml` 的应用默认绑定 `0.0.0.0`，远程 Compose 使用独立端口映射；应明确区分两种入口，不能将远程部署的回环地址说明套用到本地 Compose。配置漂移修正应先统一预期行为，再改文档或默认值；本轮没有调整交易开关或策略参数。

- 跟进：`DOC-001`。

## 5. 验收缺口与后续改进

这些是需要补齐的证据或工程改进，区别于上面的已确认问题。

1. **真实交易验收**：现有交易设计明确写明尚未完成 Futures Testnet 故障注入验收。需覆盖部分成交、响应丢失、重启、租约切换、保护单换单失败、撤单失败及人工平仓。记录构建、配置、命令/订单 ID 和结果，参见 `VAL-002`。
2. **iOS 图表验收**：已有专项日志与测试报告，不能宣称完全没有过程记录；不同真机、120Hz、长稳及视觉/手势校准项应逐项关联证据，参见 `VAL-003`。
3. **本地可重复验证**：缺少 Maven Wrapper，本机 JDK 与文档要求不一致；建议固定 JDK 25 构建入口并归档带提交号的测试摘要，参见 `VAL-001`。
4. **可维护性与观测**：`TradingExecutionCoordinator.java` 有 3,771 行，`TradingExecutionService.java` 有 1,015 行。可在回归保护下按命令派发、保护单修复、退出策略与关闭清理拆分；行情分析使用逐任务虚拟线程，建议测量数据库拥塞下的并发与积压。健康指标、可复用回测入口分别见 `ENG-001/002/003`，本轮未做压测或收益评价。

## 6. 本轮实际验证

| 检查 | 结果 | 解释 |
| --- | --- | --- |
| Git 来源、分支、提交及初始状态 | 通过 | 克隆至目标根目录，初始工作区干净，基线有 440 个跟踪文件 |
| iOS Metal 安装脚本回归 | 通过，4 个场景 | 已安装、下载成功、并发导入、连续下载失败；使用已有 mock 测试，不依赖实际 Xcode |
| 仓库 5 个 shell 脚本 `bash -n` | 通过 | 只证明语法检查通过 |
| Maven POM、Info.plist、entitlements、5 个共享 scheme 的 XML 解析 | 通过，8 个文件 | 不等同于 Java 或 iOS 编译通过 |
| 后端 `mvn -B -ntp test` | 未完成 | 停在依赖解析后终止；未运行到测试阶段 |
| 后端 `mvn -o -B -ntp test` | 环境阻塞 | 本地缺少所需依赖，报告 `DependencyResolutionException` |
| JDK 条件 | 不满足 | 本机只有 Java 21.0.10，项目 POM 要求 Java 25；没有通过降级 POM 绕过 |
| iOS build / XCTest / 真机 | 未执行 | 没有完整 Xcode，仅 Command Line Tools |
| Docker 构建与 Compose 运行 | 未执行 | 本机未提供 Docker 命令 |
| 生产凭证材料格式 | 离线确认 | 仅检查结构、长度和解析结果，不回显内容、不测试在线权限 |

后端测试源码共 77 个文件，这不是测试用例通过数量。本轮没有生成新的后端测试基线，现有“331 通过”等数字只能视为历史文档记录。后续复测应把提交号、JDK、完整测试摘要及失败原因写入[开发日志](DEVELOPMENT_LOG.md)。
