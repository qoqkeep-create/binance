# 原生 iOS 的 TestFlight 发布与手机测试

## 换根修复与完整源码交付（2026-11-06）

用户授权全部提交推送部署。换根连续性修复 `79f812b` 已推送 GitHub `codex/integrated-ios`，后续 `7e29236` 只修正后端 MySQL 测试事务，Swift 源码与前者相同；配套完整后端已在 **47.80.22.243（首尔服务器）** 发布，见[运维](operations.md#完整同源发布2026-11-06)。先前的账号／通知导航／持仓界面改动均已包含在这套完整源码，未摘除其他会话修改。

本轮通过 GitHub 公开 check 确认 `79f812b` 自动触发既有 Apple 工作流，[Archive](https://appstoreconnect.apple.com/teams/a1d39eb0-e706-4568-ae9b-edba97561247/apps/6829222305/ci/builds/d743f35b-7c9c-49ca-acc1-ea954e70b33a/action/230698b7-b7ba-4c72-a2d5-1f8341106946) 已成功，[Test](https://appstoreconnect.apple.com/teams/a1d39eb0-e706-4568-ae9b-edba97561247/apps/6829222305/ci/builds/d743f35b-7c9c-49ca-acc1-ea954e70b33a/action/b0cf2d3f-011d-448b-ac4f-96171576b989) 截至 2026-11-06 17:50（北京时间）为 **in_progress／尚无结论**，见交付时 check 记录。本轮未手动改 Jenkins／Apple 工作流、上传或加内部组，准确 Build Number／TestFlight 处理与分发／手机安装尚未核实。源码推送、Archive、Test 和手机可安装分别判断；后端上线不会修复旧安装包中的换根逻辑。

本地 64 项 host 及 generic iOS App／Widget Release 通过；多周期真实换根、迟到收盘、后台恢复及通知点击仍需安装包含 `79f812b` 的新客户端验收。证据在忽略的 `.integration-runtime/FullReleaseNov6/cloud-checks-ios.json`，没有保存 Apple 凭证。

核对日期：2026-11-01。工程配置以当前源码为准，Apple 操作依据文末官方文档。已补主 App 隐私清单，并核对 Xcode Cloud 所需的共享 Scheme、Metal 准备脚本和自动构建号机制。Apple 团队已核实为 GUANGDONG ZHANG / `756Y5JKBUD`；新 App ID 已注册并启用 Push Notifications，App Store Connect 已创建 `TradeTools USDT`（App ID `6829222305`）。已保存新应用的 `iOS TestFlight` 工作流，仓库授权、分支 / 路径触发、必过单测、App Store Connect 归档和内部测试自动分发均已配置；编号从 `4` 开始自动递增；构建 `7` 已完成云端测试、归档、上传和内部自动分发。后续用户先确认手机为 13／14，现已从实际 iPhone 诊断确认正在运行 `1.0.1 (15)`；K 线真机结果见下节，准确的 Cloud commit／配置映射仍待后台核对。

2026-11-02 用户确认构建 **26 已成功**，本轮停止追查此前 Cloud 构建失败。该反馈不等于下面新增图表／通知代码已上传或已在手机验收；准确 commit 映射仍以 Apple 记录为准。

2026-11-03 构建 34／35 的测试、归档和上传处理已成功；构建 35 由用户**手动加入内部测试组**后立即收到更新通知。本次不能作为 Cloud 自动分发成功的证据，历史构建 7 的自动分发记录也不能替代当前结果；后续操作仍显示等待的原因待查，详见 [本次核验](#构建-3435-状态核验与日志入口2026-11-03)。

## 持仓界面源码交付核验（2026-11-06）

用户反馈未选中页签仍小，且看不到此前刷新／保证金徽标改动。本次 fetch 后核对 GitHub `codex/integrated-ios`：`c96fcbcde43165c889e0f79540e3a412806c3c7f` 已在分支历史中，`USDTTradingViews.swift`、`USDTComponents.swift`、`PositionMargin.swift` 与该提交及本地逐字一致，没有漏推或后续回退。该提交包含约 15 pt 未选中／20 pt 选中页签、紧凑条不二次缩字、20 pt 刷新覆盖层与松手位移修复、顶部整数百分比和移除比较符号，以及整页横滑。

GitHub 公开 check 与 combined status 确认该提交对应 [Xcode Cloud 运行](https://appstoreconnect.apple.com/teams/a1d39eb0-e706-4568-ae9b-edba97561247/apps/6829222305/ci/builds/d75e7bc4-1279-4f04-8db8-caecb2b86db4)的 Required Test／Archive 均成功，均为 0 errors／0 test failures，整体状态 success。App Store Connect 详情跳转登录，未能核实准确 Build Number、Apple 处理与内部测试组分发；本次用户也未提供手机构建号。因此只确认源码交付和云端构建成功，不能据此声称手机已安装或断言真机字号回归。新客户端显示改动需要安装包含 `c96fcbc` 的构建，后端限定部署不会改变已安装 App 的字体或刷新图标。

来源哈希与公开 check 证据保存在忽略目录 `.integration-runtime/ClientDeliveryNov6/verified.json`。本次不修改界面源码、不重复运行已通过的 UI／Release 验证、不手动上传或分发 TestFlight，也不创建空提交重建相同源码；补记核验文档并按用户授权推送，真实手机构建映射仍待核实。此前各构建记录描述其各自时点。

## 本项目固定信息与待办

| 项目 | 当前值 / 操作 |
| --- | --- |
| Xcode 工程 | `frontend/ios-app/TradeTool.xcodeproj` |
| 主 Target | `TradeTool` |
| live 扩展 Target／Bundle ID | `PositionLiveWidget`／`com.waibao2025.trade.integrated.PositionLiveWidget`；同一团队独立登记，不另建 App Store Connect App |
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

## live 扩展的 Cloud 导出签名修复（2026-11-04）

Xcode Cloud 构建 37（`15b4784`）成功；38（`8593267`）首次嵌入 `PositionLiveWidget.appex` 后失败，39（`482c0fb`）沿用该工程配置。39 的 Test 通过，但 Archive action 在 ad-hoc、App Store、development 三种导出阶段退出 70；不能把这一状态称为 Swift 编译失败，也不能以本地无签名构建通过说明分发签名已通过。38 的具体导出日志本轮未下载，不把与 39 相同的根因推断写为已核验。

已下载 39 的 Archive Logs，三种 `xcodebuild-export-archive.log` 均明确报告 `Automatic signing cannot register bundle identifier` 和 `No profiles`，对象都是 `com.waibao2025.trade.integrated.PositionLiveWidget`。Apple Developer 团队 `756Y5JKBUD` 的 App IDs 列表中已有主 App、未找到该扩展。2026-11-04 已在同团队以 Explicit 登记该 Bundle ID，并在列表核验存在。主 App／扩展继续使用现有 Automatic 签名，由 Cloud 获取匹配的描述文件；本轮不更改 Bundle ID、签名团队、业务源码或测试门槛。

扩展只通过 ActivityKit 渲染内容，无独立网络推送注册、App Groups、共享 Keychain 或共享存储，不给扩展启用额外 Push／App Groups capability，也不扩大现有 APNs key 的 topic 授权。live token 仍在主 App 申请，后台 topic 仍为主 App 的 `.push-type.liveactivity`。登记依据见 [Apple App ID 流程](https://developer.apple.com/help/account/identifiers/register-an-app-id)，推送归属见 [ActivityKit 官方说明](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications)。

排查入口：Xcode → Reports → Cloud → 对应构建 → Archive - iOS → Artifacts → Logs，解压后先看各 `*-export-archive-logs/xcodebuild-export-archive.log`；仅截图中的 exit 70 不足以定位问题。新增任何被嵌入的 extension 时，在推送前核对实际 Release Bundle ID、团队及 Apple App IDs 登记，再以 Cloud App Store export／处理／分发分阶段验收。无需把私钥、描述文件或完整日志提交到 Git。此次重建与最终结果见 [变更记录](changes.md)。

同提交 `482c0fb` 重建的 [Cloud 构建 40](https://appstoreconnect.apple.com/teams/a1d39eb0-e706-4568-ae9b-edba97561247/xcode-cloud/products/f01be7a9-f719-4ecc-932e-17c7bac455a6/builds/b486171d-111c-4f6a-9363-e07d597e4d13/summary) 已核验 328 项测试全部通过，App Store／ad-hoc／development 导出均成功，App Store Connect 准备步骤也通过；原签名导出错误已消失。测试和导出阶段由云端实际执行，本轮未重复本地编译。Apple 处理、内部组后续分发与手机更新仍需分别确认，不能用导出成功代替已安装。

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
| `NSPrivacyAccessedAPICategorySystemBootTime` | `35F9.1`、`8FFB.1` | 测量 App 内事件间隔，并转换 UIKit／Metal 事件的绝对时间 |

本轮新增图表诊断上报，清单增加与用户关联、仅用于 App 功能的性能与其他诊断数据声明。仅上报事件绝对时间和间隔，不上报原始 uptime；理由核对见 Apple [required reason 说明](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons)及[数据声明](https://developer.apple.com/documentation/technotes/tn3184-adding-data-collection-details-to-your-privacy-manifest)。App Store Connect 的 App Privacy 后续需同步实际收集用途，本轮未修改 Apple 后台。

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

2026-11-02 用户反馈连续三次失败，提供的构建 22 截图显示 Archive 成功、Test 失败，TestFlight 后续步骤没有执行。图例尾项被宽度裁掉及离屏当前价标记越界已在本地复现并修复，完整 255 项 iOS 单测通过；截图中的旧五项底栏在最新源码已为四项。测试门槛保持不变，需由修复提交触发的新 Cloud 运行分别确认 Test、Archive、Apple 处理与内部分发，不能直接重建旧失败提交就视为已包含修复；各构建对应提交及新云端结果待核实，见 [开发验证](development.md#云端构建图表断言修复2026-11-02)。

2026-11-02 后续用户反馈构建 25。对新提交 `cafc053`，GitHub 公开 check 可确认 Archive 成功（0 errors），读取时 Test 尚未回传结束结果；前一提交 `d533b19` 的 Test／Archive 均成功。不能从公开 check 反推准确 Build Number。本地同方案完整测试复现另外两处旧图表测试数组越界，修复后 263 项全过；本次只修改测试与文档，Cloud 必过单测保持启用，用户随后授权将修复与文档提交／推送至 `codex/integrated-ios`，新 Cloud／TestFlight 结果待核验，详见 [复现与验证](development.md#构建-25-反馈后的测试越界修复2026-11-02)。不要以 Archive 成功代替 Test 或 TestFlight 分发结果。

Cloud 首次启用测试时，构建 6 的图表压力测试出现 426ms P95，超过本地模拟器 150ms 阈值，归档成功但测试未通过；新推送随后自动取消该构建。现将共享云端运行器的耗时保留为报告，继续执行所有确定性的帧数 / 并发 / 错误检查，本地保留原耗时断言；不把 Cloud 模拟器计时当作实机性能结论。修正提交 `509f2da` 自动触发构建 7，测试、Archive 与 TestFlight Internal Testing 后续操作全部成功，耗时约 4 分钟。

`frontend/ios-app/ci_scripts/ci_pre_xcodebuild.sh` 已位于工程旁且以 Git 可执行文件追踪，Xcode Cloud 自动识别。它检查并按需安装 Metal Toolchain，对下载失败最多尝试三次；无需在后台重复粘贴脚本。当前无 CocoaPods 或第三方 Swift Package 依赖安装步骤。自动签名和上传由 Xcode Cloud 完成，无需额外上传脚本或在仓库保存 `.p8`、`.p12` 和描述文件。

### 本轮分发结果

- [Cloud 构建 7](https://appstoreconnect.apple.com/teams/a1d39eb0-e706-4568-ae9b-edba97561247/xcode-cloud/products/f01be7a9-f719-4ecc-932e-17c7bac455a6/builds/3684c2fc-6c88-4ba5-b126-a539694097f5/summary)：代码推送触发，提交 `509f2da`，Test / Archive / TestFlight Internal Testing 均成功。
- [内部测试组](https://appstoreconnect.apple.com/apps/6829222305/testflight/groups/df7e47dd-6266-41c0-9e5c-344dac1ad6f1/builds)：`1.0.1 (7)` 已自动加入，状态“正在测试”，1 名测试员已邀请，Apple 处理已完成。未手工绕过测试门槛分发构建 6。
- 当前测试者在 iPhone 使用被邀请的 Apple 账号接受 TestFlight 邀请并安装。后台分发完成不代表手机已接受邀请、安装或运行；此三项仍由测试者实机验收。

### 构建 34／35 状态核验与日志入口（2026-11-03）

2026-11-03 晚间通过本机 Xcode 和已登录的 App Store Connect 页面只读核验：构建 34、35 均使用提交 `38e696c`，Xcode 中 `Test - iOS`、`Archive - iOS` 均成功，归档日志中的 App Store 导出与上传准备也成功；构建 34 的 `Errors Only` 没有错误项。核验时 Xcode 总览仍显示 Running、TestFlight 后续操作等待，但 App Store Connect → TestFlight → iOS →「构建版本上传」已显示两者均为「完成」。版本列表中构建 35 已关联「内部测试」组；构建 34 的群组栏为空。现有证据不能将这两次记录判定为编译或上传失败，也未确认 Xcode 等待状态未同步的具体原因。

用户随后明确说明，构建 35 的测试组关联是其在本轮查看期间手动添加，添加后立即收到更新通知。该结果证明本次经手动加组触发了通知，不能据此认定 Cloud 自动分发成功；自动后续操作等待的原因仍待核实。助手没有重新构建、取消任务、调整工作流、添加测试员或手动分发；手机安装与运行 `1.0.1 (35)` 仍待实机确认。核验范围见 [变更记录](changes.md#2026-11-03云端构建-3435-只读状态核验)。

以后排查先按失败阶段查看，避免以 Cloud 总览等待代替上传结果：

1. Xcode → Report navigator → Cloud → 对应构建号，展开失败的 `Test - iOS`／`Archive - iOS` → `Logs`；使用 `Errors Only` 定位错误。测试失败也可查看 `Tests`；完整日志和结果包从同一步骤的 `Artifacts` 下载。
2. 两个 action 成功时，查看 `TestFlight Internal Testing` 后续操作，再到 App Store Connect → 本 App → TestFlight → iOS →「构建版本上传」核对准确构建号。点击失败状态查看上传／处理错误；点击构建号查看详情。Cloud 总览、上传处理和测试组分发分别核对。
3. 若上传已经「完成」，继续确认版本列表／内部组是否包含该构建，以及手机 TestFlight 是否可见。没有具体失败记录时，不通过反复重建同一提交推断错误原因。

日志入口依据 Apple [构建问题排查](https://developer.apple.com/documentation/xcode/resolving-common-configuration-and-build-issues)与[查看上传状态](https://developer.apple.com/help/app-store-connect/manage-builds/view-builds-and-metadata)。

### 日常更新：云端与本地归档

- **云端路径**：本地修改后 commit 并 push 到实际构建分支；按用户说明，由现有关联 Jenkins 调用 Apple 打包服务。Cloud 读取已推送的提交，测试／归档／上传并处理完成后，在 App Store Connect → TestFlight →「内部测试」组 →「构建版本」添加该构建，手机 TestFlight 才获得该组的新包。只 commit 而未 push，或从 Xcode 的 Cloud 页面手动重建旧提交，都不会带入未推送的本地修改。本轮没有检查 Jenkins 任务本身。
- **本地归档路径**：Xcode 选择 `TradeTool Release` → Product → Archive → Organizer → Distribute App → TestFlight & App Store，完成上传；等待 Apple 处理完成，再按同样方式加入内部测试组。本地普通 Build／Run 不会自动上传 TestFlight；本地 Archive 使用当前工作区内容，不要求先 push，但应记录源码版本以便追溯。
- 两条路径任选一条完成一次客户端交付即可；混用时核对 Version／Build，避免重复上传同一构建号。Cloud 编号由平台递增，本地源码的 Build 基线仍为 `3`，本地上传时应使用 Xcode 的版本／构建号管理功能或协调新的可用编号，不能直接假定源码 `3` 可用。若只是从本机 Xcode 的 **Cloud** 页面启动任务，执行的仍是前一条云端路径。

添加测试组的操作依据 Apple [添加构建的测试员](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-testers-to-builds)，本地归档上传依据 [分发 App](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)。本次未修改工作流以解决自动分发等待。

### 本次 K 线诊断的打包授权

2026-11-01 本次推送已由 GitHub 确认接收；客户端对应提交 `7628111` 的 Apple `Test - iOS` 和 `Archive - iOS` 两项 check 后续均为 completed／success。本轮后续 MySQL 资源修正和验收文档没有改变 iOS 源码。用户配合实际手机操作后，已收到 `1.0.1 (15)`／`iosDevice`／`presented` 的三轮九次 BTC1h 报告，确认该手机已安装运行具备新诊断的包。不能据此补写 Apple 后台未核实的 commit／配置映射或整个测试组分发状态。

2026-11-01 用户说明 GitHub 推送后由其既有 Jenkins 调用 Apple 打包服务，并明确授权本次需要手机测试的新客户端完成后直接推送。一般任务仍需用户批准；这不构成长期自动推送授权。本轮复用现有配置，不新建或改动 Jenkins／Apple 工作流。后端 `7daa362` 接收接口已部署到 47.80.22.243（首尔服务器），固定样本及上述真机报告均已落库。前六次首帧为 2.00～6.94 秒；传输算法对照后的三次为 0.504／0.433／0.453 秒，用户体感一致。此次改善通过宿主网络配置实现，手机继续使用构建 15，没有再分发客户端。传输瓶颈与待验范围见 [行情](market-data.md#构建-15-真机传输排查2026-11-01)、[运维](operations.md#https-传输拥塞控制2026-11-01)和[变更](changes.md)；九次加载不代表其他功能、设备或真实交易已验收。

## 构建号自动递增

2026-11-01 用户先确认手机从 `1.0.1 (13)` 升至 `(14)`，BTC K 线等待约 1 秒变为约 3 秒；随后实际手机上报确认为 `(15)`。上方构建 7 是历史后台分发记录，不代表手机仍在该版本。本轮 App Store Connect 登录失效，尚未取得 13／14／15 各自的准确源码 commit 和构建配置；不得仅按发布时间将其等同某两个相邻提交。源码候选对照见 [13／14 排查](market-data.md#构建-1314-速度回退排查2026-11-01)，实际新包结果见 [15 真机排查](market-data.md#构建-15-真机传输排查2026-11-01)。新增加载诊断已在 15 的手机运行并落库，旧 14 不会自动获得；协议见 [客户端诊断](market-data.md#客户端加载诊断)。

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
| 品牌与认证 | 桌面名称 Binance Tools、橙红渐变图标；冷启动为白底、64 pt 新图标，深色模式也核对；USDC 布局的登录、注册 / 找回密码 / 协议底部 sheet，注册遵守后台开关；见 [品牌与认证](ios-authentication.md) |
| 持仓浮窗 | 从“我的”开启后切到其他 App，核对系统画中画、多仓轮播、更新时间、暂停 / 关闭 / 返回及重开；本机模拟器不支持该能力，真机步骤与当前待验范围见 [持仓浮窗](ios-floating-positions.md) |
| 现阶段边界 | TestFlight 测试不自动把币安切为测试网；真实绑定仍由首尔后端连接实际环境 |
| 推送 | 2026-11-03 Python App APNs 链路已在 47.80.22.243（首尔服务器）限定上线，实际 production 设备已注册；首轮 TopicDisallowed 已通过用户明确允许后新增整合 topic 授权修复，15:44 三条测试均获苹果 200，用户确认全部收到，见 [通知实测](signals-and-notifications.md#普通通知真机测试2026-11-03)。本次系统通知送达通过，自然信号长稳及浮盈通知另验；前台 WSS 独立验证 |

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
