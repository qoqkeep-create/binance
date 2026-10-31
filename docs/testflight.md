# 原生 iOS 的 TestFlight 发布与手机测试

核对日期：2026-10-31。工程配置以当前源码为准，Apple 操作依据文末官方文档。已补主 App 隐私清单，并核对 Xcode Cloud 所需的共享 Scheme、Metal 准备脚本和自动构建号机制。Apple 团队已核实为 GUANGDONG ZHANG / `756Y5JKBUD`；新 App ID 已注册并启用 Push Notifications，App Store Connect 已创建 `TradeTools USDT`（App ID `6829222305`）。已保存新应用的 `iOS TestFlight` 工作流，仓库授权、分支 / 路径触发、必过单测、App Store Connect 归档和内部测试自动分发均已配置；编号从 `4` 开始自动递增；构建 `7` 已完成云端测试、归档、上传和内部自动分发，TestFlight 显示 `1.0.1 (7)`“正在测试”。手机接受邀请和安装由测试者完成，尚无本轮 iPhone 实机结果。

## 本项目固定信息与待办

| 项目 | 当前值 / 操作 |
| --- | --- |
| Xcode 工程 | `frontend/ios-app/TradeTool.xcodeproj` |
| 主 Target | `TradeTool` |
| 建议归档 Scheme | `TradeTool Release`；其 Archive 配置为 `Release` |
| Bundle ID | `com.waibao2025.trade.integrated`；使用独立 App 记录 |
| Version / Build | 源码为 `1.0.1` / `3`；Cloud 起始 Build 已保存为 `4`，随后平台自动递增 |
| Team | `756Y5JKBUD` / GUANGDONG ZHANG；已在开发者后台核实 |
| 签名 | Automatic；TestFlight 需要 Apple Developer Program 的有效分发签名 |
| 手机系统 | 最低 iOS 17.0；当前目标设备族为 iPhone |
| Release API | `https://47.80.22.243/integrated/` |
| APNs 环境 | Release 为 `production`；新 App ID 与描述文件需要匹配 Push Notifications capability |
| 加密声明 | 现有 `ITSAppUsesNonExemptEncryption = NO`，表示不使用需声明的非豁免加密，不代表使用明文网络 |
| 应用图标 | 已有 1024 图标，检查结果无 Alpha 通道 |
| 隐私清单 | 已有 `TradeTool/Resources/PrivacyInfo.xcprivacy`，已加入主 App Copy Bundle Resources，并在本地未签名归档中确认存在 |

旧项目目录保持只读。所有打包准备只修改当前整合副本，Apple 后台使用新 Bundle ID 对应的 App。模拟器临时签名不能用于 TestFlight。

## 1. 确认 Apple 开发者账号

1. 登录 [Apple Developer Account](https://developer.apple.com/account/)，确认 Apple Developer Program 会员有效。免费 Personal Team 不提供 TestFlight 分发；Apple 公示标准会员费为每年 99 美元或当地价格。
2. 登录 [App Store Connect](https://appstoreconnect.apple.com/)，确认能访问 Apps 和 Users and Access。
3. 账号持有人处理后台显示的最新协议。新建 App 通常需要 Account Holder、Admin 或 App Manager；手动注册 App ID 需要 Account Holder 或 Admin。
4. Xcode → Settings → Accounts / Apple Accounts → 添加 Apple Account，完成本人双重认证。
5. 在 Xcode 选择有权使用的开发者团队。若使用已有团队，沿用团队可用的签名资源，不撤销其他应用在用的证书。

自己现有的 App Store Connect 账号可加入内部测试组；单纯测试手机无需另买会员。

## 2. 注册独立 App ID

Apple Developer → Certificates, Identifiers & Profiles → Identifiers → `+` → App IDs → App。

| 字段 | 建议内容 |
| --- | --- |
| Description | `TradeTools Integrated iOS` |
| Bundle ID 类型 | Explicit |
| Bundle ID | `com.waibao2025.trade.integrated` |
| Capabilities | 与工程匹配；当前保留 Push Notifications |

点击 Continue / Register。若标识已在当前团队存在，核对后直接使用。Xcode 自动签名也可能在权限允许时完成注册；创建 App Store Connect 记录前要能选择正确标识。

Bundle ID 在 Xcode、开发者后台、App Store Connect 三处必须一致；上传首个构建后不要随意更换它。

## 3. 创建 App Store Connect 应用记录

App Store Connect → Apps → `+` → New App。

| 字段 | 建议内容 |
| --- | --- |
| Platforms | iOS |
| Name | `TradeTools USDT`（用户已确认，App Store Connect 已创建） |
| Primary Language | Simplified Chinese / 简体中文 |
| Bundle ID | `com.waibao2025.trade.integrated` |
| SKU | `waibao2025-trade-integrated-ios`，团队内唯一的内部编号 |
| User Access | 按实际团队人员选择 Full Access 或 Limited Access |

创建完成后保留新 App 的 TestFlight 页面。上传构建本身不会自动把应用公开发布到 App Store。

## 4. 核对 Xcode 发布配置

打开当前工程：

```bash
open frontend/ios-app/TradeTool.xcodeproj
```

1. 左侧蓝色项目 → TARGETS → `TradeTool` → Signing & Capabilities。
2. 保持 Automatically manage signing，Team 选择实际有权限的团队，Bundle Identifier 核对为 `com.waibao2025.trade.integrated`。消除签名红色错误；自动分发签名由后续 Organizer 流程完成。
3. General → Identity：Version 现为 `1.0.1`，本地 Build 现为 `3`。Xcode Cloud 分发按下节自动编号，无需每次修改源码；本地手动上传仍需使用未占用且足够大的 Build，不能与云端编号冲突。
4. 选择 `TradeTool Release` Scheme；Product → Scheme → Edit Scheme → Archive，确认 Build Configuration 为 `Release`。
5. 顶部运行目的地选 Any iOS Device / Generic iOS Device（arm64）或可归档的 iPhone 设备。
6. `Config/Release.xcconfig` 当前已指向首尔 HTTPS；不要在发布配置中保留本地 QA 的 `127.0.0.1` 启动覆盖。
7. 如需区别手机图标名称，可在本整合副本调整 Display Name 为 `TradeTools USDT`；当前名称为 `Trade Tool`。

## 5. 隐私清单与披露

当前源码使用 UserDefaults 保存本 App 的偏好、自选和交易模式；Metal 图表使用 `ProcessInfo.systemUptime` 计算帧和事件之间的耗时。`TradeTool/Resources/PrivacyInfo.xcprivacy` 已声明以下实际访问理由，并通过主 App 的 Copy Bundle Resources 打包。


| API 类别 | Reason | 本项目用途 |
| --- | --- | --- |
| `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1` | 读写仅本 App 可访问的偏好 |
| `NSPrivacyAccessedAPICategorySystemBootTime` | `35F9.1` | 测量 App 内事件间隔与图表计时 |

归档后确认清单实际进入 `.app`，如依赖发生变化同时检查依赖声明。App Store Connect 的 App Privacy 是另一份披露，按邮箱、账户标识和交易数据等实际收集用途填写；此清单不声明 App“不收集数据”。

## Xcode Cloud：自动构建与 TestFlight 分发

推荐日常更新使用这一流程。首次从 Xcode 的 Report navigator → Cloud → Get Started / Manage Workflows 连接本产品，后续可在 App Store Connect 的 Xcode Cloud 页面维护。本地原有 manifest 指向旧 `td0328/trade-tool` 产品，本次已为新 App ID 重建 Cloud 关联，不修改旧产品的工作流或历史构建。新 product ID 为 `f01be7a9-f719-4ecc-932e-17c7bac455a6`，新 manifest 由 Xcode 生成并加入追踪。

### 一次性后台设置

1. 完成前述付费团队、独立 App ID 和 App Store Connect App 记录核对；团队应有 Xcode Cloud 使用权限和可用额度。确认 `756Y5JKBUD` 是该 App 所属团队，Push Notifications capability 与自动签名匹配。
2. 授权 Xcode Cloud 访问 `qoqkeep-create/binance` GitHub 仓库。本机 GitHub Deploy key 不等于 Apple 服务已获授权；云端只能构建已经推送的提交。
3. 已在 TestFlight 建立 `内部测试` 组，加入当前 Apple 账号，工作流 post-action 已绑定该组。
4. 首次启动前，在 Cloud Settings → Build Number 保存下一个构建号 `4`；后续由平台递增。本轮构建 7 已核对归档、上传、Apple 处理与组内“正在测试”状态。

用户确认后已在仓库所有者 `qoqkeep-create` 下安装官方 Xcode Cloud GitHub App，仅选择 `binance`。权限为读取代码 / 元数据 / PR，读写 checks 和 commit statuses；未修改 `td0328` 原有安装范围。下表为已保存配置，可在[工作流后台](https://appstoreconnect.apple.com/teams/a1d39eb0-e706-4568-ae9b-edba97561247/xcode-cloud/products/f01be7a9-f719-4ecc-932e-17c7bac455a6/workflows/E3D5006F-507F-48D4-9B29-6DBD7D9C4CEB)维护。

### 已保存工作流

| 设置 | 当前配置 |
| --- | --- |
| 名称 | `iOS TestFlight` |
| Repository / Branch | `qoqkeep-create/binance` / `codex/integrated-ios`（当前交付分支；发布分支改变时同步修改） |
| Project | `frontend/ios-app/TradeTool.xcodeproj` |
| Start Conditions | `codex/integrated-ios` 有提交且 `frontend/ios-app` 内文件变更时触发；同分支新推送自动取消旧构建 |
| Environment | 固定 Xcode 27.1（27A9275）/ macOS Golden Gate 27.0.1（26A434），Clean 已开启 |
| Test action | Scheme `TradeTool`，iPhone 18 Pro / 所选 Xcode 最新 iOS（27.1），Required To Pass |
| Archive action | Scheme `TradeTool Release`，iOS / Release，Distribution Preparation 选 `App Store Connect`（普通 TestFlight / App Store 分发资格） |
| Post-actions | TestFlight Internal Testing，工件 Archive - iOS，绑定 `内部测试`（1 名成员）；成功后自动分发 |
| 外部测试 | 如需外测，配置外部组及相应 post-action，Environment 开启 Clean；仍受 TestFlight App Review 约束 |

`TradeTool Release` 的 TestAction 没有测试列表，不能把它选为 Test action 后就认为运行了单测。`TradeTool` 提供单测列表，Archive 仍用独立 Release Scheme。真实登录 UI 检查需要专用无绑定 QA 账户，单独配置；默认云端不依赖本机 ASGI、`.env` 或 QA 密码。

Cloud 首次启用测试时，构建 6 的图表压力测试出现 426ms P95，超过本地模拟器 150ms 阈值，归档成功但测试未通过；新推送随后自动取消该构建。现将共享云端运行器的耗时保留为报告，继续执行所有确定性的帧数 / 并发 / 错误检查，本地保留原耗时断言；不把 Cloud 模拟器计时当作实机性能结论。修正提交 `509f2da` 自动触发构建 7，测试、Archive 与 TestFlight Internal Testing 后续操作全部成功，耗时约 4 分钟。

`frontend/ios-app/ci_scripts/ci_pre_xcodebuild.sh` 已位于工程旁且以 Git 可执行文件追踪，Xcode Cloud 自动识别。它检查并按需安装 Metal Toolchain，对下载失败最多尝试三次；无需在后台重复粘贴脚本。当前无 CocoaPods 或第三方 Swift Package 依赖安装步骤。自动签名和上传由 Xcode Cloud 完成，无需额外上传脚本或在仓库保存 `.p8`、`.p12` 和描述文件。

### 本轮分发结果

- [Cloud 构建 7](https://appstoreconnect.apple.com/teams/a1d39eb0-e706-4568-ae9b-edba97561247/xcode-cloud/products/f01be7a9-f719-4ecc-932e-17c7bac455a6/builds/3684c2fc-6c88-4ba5-b126-a539694097f5/summary)：代码推送触发，提交 `509f2da`，Test / Archive / TestFlight Internal Testing 均成功。
- [内部测试组](https://appstoreconnect.apple.com/apps/6829222305/testflight/groups/df7e47dd-6266-41c0-9e5c-344dac1ad6f1/builds)：`1.0.1 (7)` 已自动加入，状态“正在测试”，1 名测试员已邀请，Apple 处理已完成。未手工绕过测试门槛分发构建 6。
- 当前测试者在 iPhone 使用被邀请的 Apple 账号接受 TestFlight 邀请并安装。后台分发完成不代表手机已接受邀请、安装或运行；此三项仍由测试者实机验收。

### 构建号自动递增

使用 Xcode Cloud 原生编号：每次云端构建自动增加整数 Build，TestFlight 使用该编号。`MARKETING_VERSION = 1.0.1` 仍由发布时按需调整；源码的 `CURRENT_PROJECT_VERSION = 3` 仅作本地构建基线，不需要自动写回 Git，也不叠加 `agvtool`、时间戳或“当前值 + 1”脚本。

由 Admin / App Manager 在 App Store Connect → 本 App → Xcode Cloud → Settings → Build Number → Next Build Number 设置起始值。为延续当前源码编号，且避免和同版本已有上传冲突，首次设为 **大于 `3`、同版本已上传最大 Build、以及已分配云端 Build 的整数**；若都没有更大编号，可以设为 `4`。之后由 Cloud 持续递增。失败的云构建也可能留下编号空缺，按递增理解，不要求每个编号都有可安装包。

如交替使用本地 Organizer 和 Cloud 上传，先协调编号并在必要时提高 Next Build Number。首次成功后核对 Cloud build number、TestFlight 显示号和归档元数据；只有 Apple 处理完成、构建分配到测试组、手机可安装，才记为分发验收通过。

## 6. Archive 与上传

1. Product → Archive。等待成功后打开 Window → Organizer → Archives。
2. 选中新生成的 iOS App Archive，核对名称、Bundle ID、Version / Build 和团队。可先执行 Validate App。
3. Distribute App → **TestFlight & App Store**。较旧界面对应 **App Store Connect → Upload**。这个选项方便后续同时使用内测和外测。
4. 如果明确只给当前团队内测，也可以选择 TestFlight Internal Only；该包之后只能给内部组，不能用于外测，改外测需重新上传普通分发包。
5. 选择自动管理分发签名，按提示检查 Apple Distribution 证书、描述文件和 entitlements；保留符号上传，便于后续定位崩溃。
6. 如提示登录、本人双重认证或钥匙串访问，由本人在系统界面完成。模拟器的 `CODE_SIGN_IDENTITY=-` 不适用于此流程。
7. 确认 Upload，直至 Xcode 显示上传成功。保存本地 Archive 与符号。

## 7. 等待 Apple 处理构建

App Store Connect → 新 App → TestFlight → iOS Builds。

- 上传后先经过 Processing，完成后才可加入测试。时长取决于 Apple，不能把 Xcode 上传成功当作已经可安装。
- 若显示 Missing Compliance / 缺少合规信息，打开对应构建按真实加密用途回答。现有 `ITSAppUsesNonExemptEncryption = NO` 是工程声明，不应解释为不使用 HTTPS 或 Keychain；如果最终依赖引入其他加密，需要重新核对。
- Invalid Binary / 处理失败时，查看 Apple 邮件和上传日志，按具体错误修复、提高 Build 后重新归档。
- 使用 Apple 允许上传的 Xcode / SDK。本轮本机及云端使用 Xcode 27.1（27A9275）；构建 7 的云端签名归档已获 Apple 接受并完成处理。历史 27.2 测试记录属于另一环境，后续仍按 Apple 当前要求选择可用版本。

## 8. 先给自己内部测试

1. 新 App → TestFlight → Internal Testing 旁边 `+`，创建例如 `本人真机测试`。
2. Add Builds，选择处理完成的构建。
3. Invite Testers，勾选自己有本 App 访问权限的 App Store Connect 账号。
4. What to Test 可填写：

```text
验证登录与重启恢复、行情列表与搜索、自选、K 线和指标、历史分页；
切换 Wi-Fi / 蜂窝网络后确认行情恢复；
检查持仓、开仓、信号、我的及 API 管理页面；
无交易所绑定时确认开仓禁用。
```

5. 按页面完成 Add / 邀请。内部测试支持最多 100 位具备相应 App Store Connect 权限的用户，通常不经过外部测试所需的 TestFlight App Review。
6. iPhone 从 App Store 安装 Apple 的 TestFlight，在手机上打开邀请邮件 → View in TestFlight → Accept → Install。
7. 安装后点击 Open；手机运行可独立于 Mac，首尔服务器需保持在线。

Apple Account 用于 TestFlight 安装；应用邮箱 / 密码用于登录 TradeTools 后端，两者是不同账户。服务器当前关闭自助注册，先使用已提供的应用登录资料；本机资料在忽略且受限的 `.integration-runtime/server-access.env`。多人测试应使用各自应用账户，不共享服务器初始管理员。

## 9. 邀请其他人外部测试

已建立内部组后，在 TestFlight → External Testing 创建外部组，Add Builds 选择普通 TestFlight & App Store 分发的构建。

1. 补测试说明、反馈邮箱、联系信息。
2. 如审核需要登录，准备专用、无真实交易资金权限的应用测试账号，并清楚说明未绑定状态的功能边界。审核资料不填写服务器 root、真实管理员或交易所 API 密钥。
3. 说明真实功能，包括 USD-M 永续行情及交易工具；提交 TestFlight App Review。
4. 首次提交的外测构建需要审核；同版本后续构建可能仍需审核，以后台状态为准。
5. 审核通过后，选择自动通知或手动 Start Testing，用邮箱或 public link 邀请。
6. 外部测试最多 10,000 人；普通测试者无需 App Store Connect 管理权限。

## 10. 手机上首次验收

| 场景 | 观察内容 |
| --- | --- |
| 登录 | 服务器选择为整合服务器；退出 / 重启后会话恢复符合预期 |
| 行情 | 列表、搜索、自选和红绿涨跌变化可见 |
| K 线 | BTC / ETH、多周期、拖动缩放、指标、向左历史分页 |
| 网络变化 | Wi-Fi / 蜂窝切换、短暂断网、切后台再回来后重新订阅与补齐 |
| 页面 | 五个 Tab、持仓空状态、API 管理表单、无绑定开仓禁用 |
| 现阶段边界 | TestFlight 测试不自动把币安切为测试网；真实绑定仍由首尔后端连接实际环境 |
| 推送 | 当前 Python 尚未接 Java APNs 链路，暂不能把系统通知送达列为已通过；前台 WSS 独立验证 |

当前唯一后端是 47.80.22.243（首尔服务器），旧 USDC Java 环境已退役；应用端继续使用同一整合 API，无需切换到旧接口。部署与独立数据库说明见 [运维](operations.md)。手机 Safari 可先打开 `https://47.80.22.243/integrated/v1/health` 检查 HTTPS。`/integrated/` 是 API 基址，不是 Web 首页。手机中的 `127.0.0.1` 指手机自身。

本轮普通验收继续使用无交易绑定账户；真实开平仓、划转和撤保护单不作为安装测试步骤。

## 11. 后续更新及常见问题

Cloud 工作流现已配置，每次客户端更新：修改本整合副本 → 推送至配置的分支 → Cloud 测试 / 自动增加 Build / Archive → 上传并处理 → 自动分配内部组 → 手机 TestFlight 更新。若手动使用 Organizer，仍按第 6 节归档上传并协调构建号。每个构建自上传起最多测试 90 天，继续测试要提供新构建。只有后端更新且接口兼容时，通常无需重发客户端。

| 问题 | 处理 |
| --- | --- |
| Bundle ID 注册失败 / 不可用 | 核对当前团队已有标识和权限；如确需新标识，统一修改三处身份，不复用旧项目 App |
| No profiles / 签名红字 | 核对付费团队、自动签名和 Push capability；由有权限账号刷新描述文件 |
| Archive 灰色 | 切换主 App Scheme 与 iOS 真机 / 通用设备目的地 |
| 找不到构建 | 核对 App、Version / Build、处理状态、Apple 邮件；查看是否上传到另一个团队 |
| 构建号重复 | 使用更大的未占用 Build，重新归档 |
| 缺少 API 隐私理由 | 补齐 manifest、Target Membership 和 Copy Bundle Resources，再重新归档 |
| 手机提示无法测试 | 核对邀请接受、构建已加入组、构建是否过期及设备系统版本 |
| 外测列表无法选择构建 | 核对是否上传为 Internal Only；这种包只能内测 |
| 行情无法加载 | 核对首尔 HTTPS 健康、App 服务器选择、手机网络与应用会话 |

## 官方依据

- [Apple Developer Program](https://developer.apple.com/programs/)
- [注册 App ID](https://developer.apple.com/help/account/identifiers/register-an-app-id)
- [创建 App Store Connect 应用](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/)
- [归档与分发](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)
- [上传构建与处理](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
- [内部测试](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/)
- [外部测试与审核](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/)
- [API 使用理由](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
- [添加 API 理由条目](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest)
- [加密出口声明](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)
- [配置首个 Xcode Cloud 工作流](https://developer.apple.com/documentation/xcode/configuring-your-first-xcode-cloud-workflow)
- [Cloud actions 与分发签名](https://developer.apple.com/documentation/xcode/configuring-your-xcode-cloud-workflow-s-actions)
- [Cloud 工作流与外测 Clean 要求](https://developer.apple.com/documentation/xcode/xcode-cloud-workflow-reference)
- [Cloud 自动构建号与起始号](https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds)
- [Cloud 自定义构建脚本](https://developer.apple.com/documentation/xcode/writing-custom-build-scripts)
- [Cloud 的 TestFlight 分发](https://developer.apple.com/documentation/xcode/distributing-your-xcode-cloud-builds-through-testflight)
