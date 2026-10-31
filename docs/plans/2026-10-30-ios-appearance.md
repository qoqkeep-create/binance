# iOS 亮色与暗色外观实施计划

**Goal:** 根据用户提供的币安亮色截图，为全部 iOS 页面与 Metal 图表提供一致的亮色/暗色外观，在设置中即时切换并保存选择。

**Architecture:** SwiftUI 通过类型化 `AppStorage` 保存设备级外观，根视图设置统一 `preferredColorScheme`。通用组件采用动态语义颜色；Metal 在不可变 RenderState 中携带外观，在打包 GPU 颜色时解析，并将外观纳入静态缓冲缓存条件。

**Tech Stack:** SwiftUI、UIKit 动态 UIColor、UserDefaults、现有 Metal 图表与 XCTest。

## 设计决定

- 用户提供的截图和仓库现有视觉规范作为参考，不引入 Binance 私有字体或商标素材。
- 新安装默认亮色；设置提供亮色/暗色两项，选择即时生效并跨重启、登录保留。
- 亮色采用白底、浅灰容器、深色文字、灰色分隔与币安黄主操作，涨跌保持绿/红。
- 标准边距 16pt；4/8/12/16/24pt 间距；行高至少 56pt；按钮/输入框 48pt；触控目标至少 44pt。
- 系统字体：页面标题 22pt、行标题 17pt、正文 15–17pt、辅助 12pt、账户余额 34pt、数值使用等宽数字；支持 Dynamic Type。图表保留既有坐标和交互尺寸。

## 实施步骤

1. 在 `Core/Design/AppAppearance.swift` 定义可持久化的外观枚举；更新 `TradeToolApp.swift` 和 `SettingsView.swift`，提供带选中状态及辅助功能标签的外观选择。
2. 更新 `BinanceTheme.swift` 的动态颜色、字号、间距与基础组件；整理行情、设置、登录、持仓、信号页面的主次层级。
3. 修正 `MarketChartView.swift`、指标设置、划线下单与 UIKit 滚轴的硬编码黑/白颜色，适配亮色背景。
4. 更新 `ChartFigure.swift`、`RenderState.swift`、`KlineChartHostView.swift` 和 `MetalRenderer.swift`，覆盖背景、网格、标尺、最新价、十字光标与填充；切换主题时保留历史数据和视口，刷新缓冲颜色。
5. 增加外观与图表调色回归，更新 Xcode source/test 注册和 `DESIGN_AND_AUTH.md`，在本文记录实际验证。
6. 执行可用的 Swift 解析、纯 Swift 颜色验证、项目文件检查和已有脚本回归；检查 Git diff 后直接提交本次 UI 改动。此前已暂存的项目审阅文档保留其状态。

## 验收

- 设置可切换，重启后恢复选择，登录页/导航/弹层/设置/图表使用相同主题。
- 白底图表无黑色空洞、白色不可读标尺或旧主题静态缓冲；暗色保持既有行为。
- 主操作、输入、列表与空状态使用统一层级；辅助按钮具有足够触控区域。
- 主题切换不重建登录会话、行情订阅或交易命令，不改变数据与交易逻辑。

## 实施与验证记录

2026-10-31 已完成：

- 外观默认亮色；设置提供亮/暗选项，带选中标记和 VoiceOver 标签，使用设备级 `AppStorage` 保存。
- 登录、行情、信号、参考通知、持仓、设置及业务弹层使用语义颜色；统一系统字体、等宽数字、卡片与控件尺寸。黄色主按钮使用深色文字；白底强调文字与涨跌文字使用加深色。
- Metal 场景显式携带主题；静态缓冲同时按 revision/主题判断复用。手势交互帧与离屏渲染传递相同外观，历史与视口保持共享。
- `AppearanceTests.swift` 新增 6 项 XCTest，覆盖偏好保存、双主题文字对比度、透明度和指标颜色、坐标标记、快照共享及 Metal 离屏颜色；已注册到 Xcode 测试 target。

已运行验证：

1. `swiftc -frontend -parse`：应用和测试共 89 个 Swift 文件通过。
2. Swift 6 编译执行真实 `AppAppearance.swift`、`ChartFigure.swift`、`RenderState.swift` 的 Foundation 验证程序，其他图表依赖使用临时最小桩：枚举 UserDefaults 往返、102 项颜色/透明度检查、主题切换的快照共享、最新帧邮箱均通过；临时产物未加入仓库。
3. 根据实际主题 token 计算 sRGB 对比度：两种主题的主次文字、强调文字和红绿文字均达到 4.5:1，亮色最低 4.74:1；黄色主按钮及红绿按钮文字同样通过。
4. `plutil -lint frontend/ios-app/TradeTool.xcodeproj/project.pbxproj frontend/ios-app/TradeTool/Resources/Info.plist`：通过。解析项目文件确认新增源码和测试分别加入正确 target。
5. `bash frontend/ios-app/ci_scripts/tests/ci_pre_xcodebuild_test.sh "$PWD/frontend/ios-app/ci_scripts/ci_pre_xcodebuild.sh"`：4 个现有模拟场景通过。
6. `git diff --check` 通过；检查未追踪文件后，将本次 3 个新增交付文件加入追踪。

环境限制：`xcode-select -p` 为 `/Library/Developer/CommandLineTools`，没有完整 Xcode 或 iOS SDK。尚未执行 iOS 编译、XCTest、模拟器截图及真机视觉验收，不能将上述源码/模型验证视为完整 iOS 测试。后续在 Xcode 的 `TradeToolTests` target 执行新增回归，并检查亮暗模式下的设置、K 线、输入与业务弹层。
