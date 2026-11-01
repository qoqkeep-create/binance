# 鸿蒙客户端

核对日期：2026-11-01。本次新增 `frontend/harmony-app/`，与 iOS 在同一源码仓库内独立维护。用户测试机为 Mate 80；官方规格列为 HarmonyOS 6.0，实际系统构建号、USB 连接和调试签名尚未读取。不进行任何应用市场发布。

**当前已有通过真实 ArkTS 编译的未签名 debug HAP，尚未完成调试签名、Mate 80 安装和全功能／界面复刻验收。** 本机已安装独立 Command Line Tools、HarmonyOS SDK、JDK 与官方 CLI；DevEco Studio 桌面安装包由用户手动下载，IDE 尚未安装。

## 工程与边界

- `AppScope/`、`entry/`、Hvigor 配置构成 Stage 原生应用；本机使用 API 26 SDK 编译，包内 target 为 HarmonyOS 6.0 / API 20、compatible 为 5.0 / API 12。较低版本运行兼容性仍需真机确认。
- `entry/src/main/ets/pages/` 负责认证、行情、持仓、开仓、信号、我的及二级页面；`components/` 包含共用组件、Canvas 与应用内浮窗。
- `core/` 为平台无关 TypeScript；`platform/` 将 HTTP、WebSocket、安全存储、偏好和时钟接到鸿蒙系统 API；`EntryAbility` 管理前后台。
- 复用 Django 既有 `/api/auth/*`、`/api/market/*`、`/api/commands`、`/v1/*` 和 `/ws/v1`；不复制交易引擎，不新增后端写接口。本轮没有修改后端、iOS 或部署配置。
- 默认连接 `https://47.80.22.243/integrated/`，即 47.80.22.243（首尔服务器）；未登录可切换 HTTPS 服务地址。普通本地验证全部使用 transport / vault / socket 替身，没有请求实际交易或转账。
- 手机显示名称沿用 Binance Tools、现有图标和黄／绿／红配色，提供浅／深／跟随系统主题。ArkUI 页面结构与现有业务对应，尺寸、弹窗形态和 Canvas 效果仍需与 iOS 截图逐页对照，不能称为像素一致。

## 当前源码覆盖

下列源码已纳入本轮 ArkTS／HAP 构建；“已有”不代表联网联调、页面行为或设备验收通过。

| 范围 | 已有代码 | 差异与待验 |
| --- | --- | --- |
| 登录／注册／恢复 | 协议勾选、密码登录、注册、刷新 cookie、恢复身份、退出、HTTPS 服务设置 | 鸿蒙安全存储与原生 HTTP cookie 需真机验证 |
| 找回密码／法律页 | 请求重置邮件；手填邮件 uid/token 完成重置；协议和隐私文本沿用当前 iOS | 邮件链接直接唤起原生 App 未配置；文本合规性不在本轮重新审定范围 |
| 行情／自选 | 全合约、自选、搜索、成交额／涨跌排序、收藏、鉴权 WSS、延迟测量 | 真机长列表与更新性能、网络异常和视觉待验 |
| 图表 | 6 周期、最多5000根、500根分页、实时合并、缩放、拖动、十字光标、划止损／限价并带入开仓 | Canvas 替代 Metal；未接入 iOS 的完整绘制与性能体系；相同参数和输出仍需数值校准 |
| 技术指标 | MA、EMA、BOLL、SAR、AVL、SUPER；VOL、MACD、RSI、KDJ、OBV、WR、StochRSI、ATR | 已有固定参数与显隐选择；完整参数编辑、指标样式和逐值对照尚未实现／验收 |
| 统计副图 | O.I.、L.S Acco.、L.S Posit.、L.S Ratio、B.S Vol.、Basis | 按服务端 `tradingData` 字段绘制；缺数据保留空值；1m 无统计、不同量纲显示与历史补全待验 |
| 开仓 | 市价／限价、止损价／金额、策略选择、手续费估算、资金预检查、限时 EMA 方向初筛、冻结参数后确认、持久化命令 | 含手续费估算沿用0.001；服务器为最终口径；未作真实交易验收 |
| 持仓／委托／历史 | 列表、历史筛选和分页、仓位详情、保护和结算字段、追单／撤单 | 当前实现的页面与 iOS 逐项交互对照待完成 |
| 持仓操作 | 平仓、同批次批量平仓、手动止盈／取消、含／不含费保本、策略重绑／取消、执行日志 | 批量遇 UNKNOWN 停止后续；明确失败记录后继续其他目标；未调用交易所写操作验证 |
| 账户 | 普通／带单模式、API绑定／验证／解绑、账户资料、止损百分比／待生效取消 | 仅展示服务器已有能力；带单开放限制继续由服务端裁决 |
| 策略 | 新建／编辑／删除／设当前，1至5层、递增 R、减仓比例、止损移动参数校验 | 页面、输入键盘及既有策略快照联调待验 |
| 资金 | 整理预览、目标金额／地址／网络确认、同一归集流水核对、归集地址配置、补资提醒邮件预览与确认 | 无 ID 的未知结果不会重发原计划；需预览恢复，无法确认时保持阻断；没有执行真实划转或邮件发送 |
| 记录／信号 | 转账历史和手动同步、游标操作日志、内部信号与跳图、云端命令与本机待确认恢复 | 刷新与错误提示已接入；推送通知、内部信号规则弹窗和细节样式尚待补齐 |
| 浮窗 | 可拖动的应用内持仓卡片，前台每3秒读取当前账户，显示更新时间与异常 | **跨 App 系统浮窗／画中画未实现**；需核实鸿蒙平台能力与权限，再做 Mate 80 实机方案 |
| 系统设置 | 主题、管理员开放注册、应用版本显示 | 自动更新／原生通知分发未接入；不接应用市场 |

看盘计划、评分复盘、专用校准问答、手动“开仓理由／指标校验”和信号研究已随当前 iOS／后端退役，不恢复这些页面或接口，见 [退役说明](research.md)。

## 资金与身份安全

金额、比例和请求字段使用十进制字符串。`Decimal.ts` 实现定点加减乘除与舍入；价格绘图和指标才使用浮点数。止损预估遵循服务端1／5／10 USDT阶梯向上取整，实际结果以服务器为准。普通测试不真实开平仓、划转、撤保护或更改已有订单策略，规则见 [交易安全](trading-safety.md) 和 [资金](capital-and-transfers.md)。

会话使用 Bearer header；refresh cookie 与访问 token 只写 Asset Store，不写 Preferences。安全存储按1000字节分块，先写分块再提交清单，串行读写；锁屏或写入失败时阻止新增交易。Preferences 仅存 HTTPS 地址、主题、自选和图表偏好。HTTP／WSS 保留系统 TLS 校验，不添加忽略证书错误的逻辑。

会话代际覆盖退出、服务地址、用户、模式和本机绑定变化。旧 HTTP 响应及旧 WSS 回调不能覆盖新身份；401 刷新合并为单在途，原请求最多重试一次。`/v1/api/info` 目前只给出 alias/status，没有服务端绑定代际：客户端持久化本机 epoch，在本机绑定／解绑时轮换，连接状态变化不当作新账户。**其他设备用相同别名替换 API 的场景无法仅凭此协议在客户端提前识别**，最终绑定指纹及代际隔离继续由服务端检查；后续可考虑提供不含凭证的绑定身份接口。

所有交易命令先把 action、冻结参数和稳定幂等键写入安全存储，再发送。未知结果重启后沿用原键；已有 command ID 只查询该 ID；当前身份存在未决请求时阻止更换参数另发命令。批量平仓先保存整批目标和逐笔键，成功／明确失败才推进游标；UNKNOWN 或账户切换时停止后续目标，即使本机游标写失败也不会重新生成键。

资金整理使用独立本机安全记录：首次请求前记录未知状态，收到 `collection_id` 后先保存，再允许核对同一流水；没有 ID 的异常不重发原计划。重新预览若返回待确认流水则恢复 ID，返回 ready/not_required 才清理未知记录。无法确定结果时保持阻断。操作目的、计划 token、金额、网络与目标地址按现有资金状态机交给服务器确认。

## 构建、签名与安装

具体命令与操作入口见 [鸿蒙工程 README](../frontend/harmony-app/README.md)，这里维护流程边界。

1. 本机已安装 ARM64 Command Line Tools 26.0.0.865（API 26 SDK），可直接命令行构建；IDE 可另装匹配架构的 DevEco Studio。官网下载账号登录由用户本人完成；IDE 安装包仍在用户手动下载过程中。工具链位置与环境覆盖参数见工程 README。
2. 执行 `node scripts/prepare-local.mjs`，用 DevEco 打开生成的 `.local-build/project/`。签名仅写这个忽略目录；自动签名会把密码／证书路径写入工程配置，不允许回填或提交公开 `build-profile.json5`。
3. Mate 80 开启开发者选项和 USB 调试，授权这台电脑；在 DevEco Signing Configs 为此设备生成调试签名。包名为 `com.waibao2025.trade.harmony`，版本1.0.0。无需上架应用市场；调试 Profile 的设备范围和有效期以开发者中心为准。
4. 首次真实 ArkTS 编译和未签名 HAP 打包已通过；修复了组件成员与 ArkUI 属性重名、对象与 SelectOption 类型、catch 重抛类型。已签名 HAP 和设备运行仍待验证。命令行安装脚本要求显式设备标识与包路径，只安装／更新指定设备，不卸载或清数据。
5. 初次手机验收先使用无交易绑定测试账户，核对登录、主题、行情、K线、前后台、退出／重登、网络中断和身份隔离。涉及交易和资金写入的联调继续使用隔离后端与交易所替身；真实资金操作不能成为普通 UI 测试。

官方依据：[Mate 80 规格](https://consumer.huawei.com/cn/phones/mate80/specs/)、[DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)、[真机运行](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-run-device)、[自动签名](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing-auto)。官方文档在线更新，首次安装按当前 IDE／开发者中心提示核对。

## 本机工具链（2026-11-01）

独立工具链安装于 `$HOME/Library/Developer/HarmonyOS/command-line-tools`，JDK 安装于同一父目录的 `jdk-21/Contents/Home`。JDK 来自 Azul 官方 ARM64 发行包，SHA-256 与官方元数据一致；hdc 的 macOS 代码签名验证通过。华为工具通过已登录的官方下载页取得，未使用第三方重打包 SDK。SDK 不进入源码仓库；工具路径只在构建进程中生效。

终端已安装华为官方 `@deveco/deveco-cli@1.3.10`；本工程构建脚本可直接调用随包 Hvigor，无需额外 Agent 插件或 MCP。此次 Homebrew JDK 下载过慢，已中止，最终使用上述独立 JDK。桌面 IDE 和手机调试签名仍是独立待办。

## 本轮验证记录

2026-11-01，仅在此 Mac 本地验证：

- Node 24 的核心／WSS替身测试40项通过，涵盖精度、刷新并发、身份、命令未知恢复、资金同流水、批量稳定键、行情历史合并、统计缺值、指标和策略／止损规则。
- TypeScript 5.9.3 strict 核心类型检查通过；只覆盖 `core/*.ts`，不包含 `.ets` 或鸿蒙系统 API。
- 工程静态检查覆盖配置 JSON、页面入口、相对导入、资源、主题键及签名材料；脚本语法检查和本地构建副本生成通过。它们不是 ArkTS 编译器或功能联调。
- 后续环境安装完成后，`doctor.sh` 退出0：Command Line Tools 26.0.0.865、SDK 26.0.0.105 / API 26、Hvigor 6.26.9、ohpm 26.0.0.630、hdc 3.2.0f、工具链 Node 24.14.1、Zulu OpenJDK 21.0.13.0.3。官方 CLI 1.3.10 已安装并验证可运行。
- 在忽略的 `.local-build/project/` 中执行 `./scripts/build-debug.sh`，真实 ArkTS 编译和 assembleHap 成功（44.909秒）。产物为 `entry/build/default/outputs/default/entry-default-unsigned.hap`，2,745,307字节；包内包含 Ark 字节码，包名、版本、权限及 target20／compatible12 已核对，ZIP CRC 通过。
- 用户选择稍后连接 Mate 80；当前未签名包另存于 `.local-build/artifacts/2026-11-01/entry-default-unsigned.hap`，同目录保存 SHA-256 与构建元数据，不随源码提交。后续签名后重新生成可安装包，不能直接安装此未签名备份。
- 构建仍有 SDK 异常处理／设备能力提示、弃用 API 和重复 `app_name` 资源警告；本轮不据此声称运行安全或界面验收完成。构建日志保留于忽略的 `.local-build/build.log`。
- `hdc list targets` 返回 `[Empty]`，尚无设备授权、调试签名或手机运行结果。此前工具缺失阶段的退出2已由本轮真实构建结果替代。
- 没有部署、提交、推送、上传应用市场或 TestFlight。安全的新源码加入整合版独立 Git 追踪，已有工作区改动保留。

后续完成 Mate 80 调试签名与安装，再逐页对照 iOS、校准指标参数、补齐系统浮窗和通知能力；不要将编译通过标记为“全量复刻完成”。
