# 原生图表校准

当前入口是 `TradeTool Chart Calibration` Scheme 和 `TradeToolChartCalibrationUITests`。校准覆盖蜡烛、价格线、十字光标、周期 / 交易对、指标面板及布局；数据和测试范围见 [开发文档](../../../docs/development.md)。

## 工具

- `scripts/run_chart_calibration.sh --list` 列出可选测试。真实设备需 `IOS_DEVICE_UDID`，默认配置为 `Debug-Seoul`；脚本将 xcresult 和附件输出到临时目录。
- `scripts/chart_calibration_diff.swift` 比较校准图片，`scripts/check_chart_lines.py` 检查图表线条，`scripts/chart_video_frame.swift` 提取录屏帧。
- `ci_scripts/ci_pre_xcodebuild.sh` 为构建确认 Metal Toolchain；其安装重试测试保留。

外部 Binance App 的参考捕获需要设备上已有应用、相应页面和测试前置状态，不能当作无需准备即可运行的整合 UI 验收。旧截图与历次校准记录从 [USDC 来源目录](../../../docs/sources.md) 查询。

## 整合流程

`IntegratedNativeUITests` 显式使用无交易绑定的本地 QA 环境；密码经环境变量传入，不写入源码。缺少配置时跳过。检查登录、行情 / Metal 图表和五个业务 Tab，不真实开平仓或划转。

保留实际截图和 xcresult，分别记录设备、配置、网络、测试账户边界与结果。禁止把模拟器运行写成真机帧率或长稳通过。
