# Binance Tools · HarmonyOS

独立原生鸿蒙客户端，使用 ArkTS / ArkUI、Stage 模型与 Canvas，共用现有 Django HTTP / WSS。测试设备为 Mate 80；目标 HarmonyOS 6.0 / API 20，兼容配置为 5.0 / API 12，兼容设备尚未验收。不接入任何应用市场。

本目录是首轮客户端代码，**已通过真实鸿蒙编译并生成未签名 debug HAP，尚未完成真机安装或签名**。功能矩阵、已知差异和验证范围以 [鸿蒙主文档](../../docs/harmony-client.md) 为准。iOS、后端与部署使用各自原目录。

## 结构

- `entry/src/main/ets/pages/`：认证、五个主入口、图表、账户、策略、资金与记录。
- `core/`：纯 TypeScript 协议、十进制、会话、命令恢复、资金与批量任务、行情和指标。
- `platform/`：Network Kit HTTP / WebSocket、Asset Store 安全存储、偏好和时钟适配。
- `components/`：复用组件、原生 Canvas 和应用内持仓浮窗。
- `AppScope/`、`entry/src/main/resources/`：既有品牌图标、主题和页面配置。
- `tests/`：无网络、无真实账户的协议与交易安全替身回归。

## 本地检查

在本目录执行，Node 24 及以上；无需 npm install，无第三方运行依赖：

```sh
npm test
npm run check
./scripts/doctor.sh
```

核心类型检查（使用固定版本 TypeScript，不修改依赖或锁文件）：

```sh
npm exec --yes --package=typescript@5.9.3 -- tsc --noEmit --strict --target es2020 --module es2020 --moduleResolution bundler entry/src/main/ets/core/*.ts
```

这些检查不包含 ArkTS / ArkUI 编译、鸿蒙系统 API 类型或界面运行。

## DevEco 与调试安装

1. 从 [华为官方](https://developer.huawei.com/consumer/cn/download/)安装匹配电脑架构的 DevEco Studio 或 Command Line Tools。本机已安装 ARM64 Command Line Tools 26.0.0.865／API 26 SDK 与 JDK 21，真实构建通过；应用 target 保持 API 20，compatible API 12，真机兼容性待验。官方下载和调试签名需华为账号；认证与签名有效期以开发者中心当时要求为准。
2. 在本目录运行 `node scripts/prepare-local.mjs`。**用 DevEco 打开输出的 `.local-build/project/`**；它是忽略的本地构建目录。后续同步源代码再次运行该命令，保留此目录中 IDE 生成的签名配置。
3. Mate 80 开启开发者选项、USB 调试，连接电脑并在手机授权。在 DevEco 的 Project Structure / Signing Configs 为这台测试机生成调试签名。包名 `com.waibao2025.trade.harmony`，签名与设备列表必须匹配。首次调试以 IDE 提示为准。
4. 源码目录运行 `./scripts/build-debug.sh`，构建输出在 `.local-build/project/`；修正应写入公开源码后再次同步。使用 IDE 时选择 Mate 80 点击 Run。脚本支持 DevEco Studio 与独立 Command Line Tools，路径说明见下节。
5. 已签名调试包默认在 `.local-build/project/entry/build/default/outputs/default/entry-default-signed.hap`；以实际 DevEco 输出为准。只对显式指定设备安装：

```sh
hdc list targets
./scripts/install-debug.sh '<设备标识>' '.local-build/project/entry/build/default/outputs/default/entry-default-signed.hap'
```

调试设备登记和签名即可用于本机测试，应用市场上架属于另一套流程。安装脚本只更新指定设备上的本应用，不卸载、清数据或调用交易接口。未签名 HAP 不能作为可直接安装包分发。

2026-11-01 首次成功编译的未签名包已本地备份至 `.local-build/artifacts/2026-11-01/entry-default-unsigned.hap`，附 `SHA256SUMS` 和 `build-info.json`。用户选择稍后连接 Mate 80，再完成调试签名与安装；此备份不进入 Git。

签名口令、私钥、证书、设备身份和 `local.properties` 仅保留在忽略目录。DevEco 会将签名信息写入工程配置，务必在 `.local-build/project/` 配置；不要将带签名的配置复制回公开工程或提交 Git。

## 独立命令行工具链

`./scripts/doctor.sh` 检查 Hvigor、ohpm、SDK 元数据、hdc、JDK 和 Node 的实际运行结果。脚本通过 `scripts/toolchain-env.sh` 临时配置当前进程，不修改全局 Node 或 shell 启动文件。

本机 JDK 位置为 `$HOME/Library/Developer/HarmonyOS/jdk-21/Contents/Home`，脚本也会识别 IDE 自带 JBR 或显式 `JAVA_HOME`。

工具链优先使用显式 `HARMONY_TOOLCHAIN_HOME`，然后是 `/Applications/DevEco-Studio.app/Contents`，最后是 `DEVECO_CLI_CLT_PATH` 或 `$HOME/Library/Developer/HarmonyOS/command-line-tools`。其他位置安装的 IDE 可设置 `DEVECO_STUDIO_HOME`。可单独覆盖 `HARMONY_SDK_HOME`、`HVIGOR_HOME`、`HARMONY_NODE`、`HARMONY_OHPM`、`HARMONY_HDC` 与 `JAVA_HOME`。

华为官方 `@deveco/deveco-cli` 只是统一命令入口，仍需安装 IDE 或 Command Line Tools；显示 CLI 版本不等同于 SDK 已就绪。构建只在忽略的 `.local-build/project/` 中进行。重复同步会保留该目录完整的 `build-profile.json5`，因此公开配置变更后，应核对本地产品／SDK字段；签名字段仍只保留在本地副本。

## 接口与测试边界

默认 API 为 `https://47.80.22.243/integrated/`，即 47.80.22.243（首尔服务器）；可在未登录的服务器设置页改为隔离测试环境。HTTP 与 WSS 使用系统 TLS 校验，不绕过证书错误。

所有实际开平仓、划转、撤单、撤保护或调整已有策略都由用户操作触发。普通验证使用替身，**不要以实盘交易测试按钮是否正常**。命令已超时或 UNKNOWN 时到交易命令继续核对原请求，不生成另一笔替代订单。资金未知请求没有流水 ID 时先重新预览恢复状态，不能反复发起原计划。
