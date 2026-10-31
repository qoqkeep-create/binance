# iOS 主题、列表和设置布局实施计划

**Goal:** 逐项落实用户最新界面反馈，提供改动清单，并按用户最新要求完成交付。

**Architecture:** SwiftUI 页面复用 `BinanceTheme` 的颜色、字号与尺寸；Metal 场景、宿主和清屏使用相同背景语义。行情、信号和编辑自选共用交易对字号；图表按可见绘图区计算横向长方格，保留时间轴分段。

**Tech Stack:** SwiftUI、UIKit、Metal、XCTest、Xcode 27.2。

**本轮最新要求：** 顶部“API 未绑定”改为默认 10pt，设置选项主文字恢复至 17pt。完成本地修改与预览检查，先不提交、不推送。

## 任务及验收清单

| 项目 | 文件 / 实施方式 | 验收标准 |
| --- | --- | --- |
| 行情字号与间距 | `BinanceTheme.swift`、`DashboardView.swift`、`MarketListSettingsView.swift` | 首页、信号、编辑自选均使用默认 15pt 的 `listSymbol`；主价格 13pt，最小行高 60pt |
| 搜索框 | `BinanceTheme.Layout` | 可视高度 46pt，点击高度 48pt；首页和搜索页同步 |
| 暗色背景 | `BinanceTheme`、`ChartFigure`、`KlineChartHostView`、`MetalRenderer` | 页面、底栏、宿主、加载区、GPU 清屏均为 sRGB `#212731` |
| K 线网格 | `ChartSceneBuilder.swift` | 保留横竖网格，单格宽高比至少 1.8；竖线按主副图绘图区分段，不穿过时间轴 |
| 底栏 | `BottomNavigationBar.swift` | 禁用选择事务动画与 SF Symbol 过渡；文字默认 10pt，保留动态字号缩放 |
| 信号卡片 | `SignalsView.swift` | 时间独占顶部靠右的一行，使用文字自然高度；主体另起一行，方向图标、信息与价格区域垂直居中；价格数字在上、标签在下；二次提醒仍完整展示 |
| 设置分组 | `SettingsView.swift` | 第一组依次为绑定 API、止损额、止盈止损策略、下单设置；第二组为暗色模式和策略通知 |
| 设置字号 | `BinanceTheme.Typography.settingsRowTitle` | 选项主文字默认 17pt，辅助说明 11pt；顶部“API 未绑定”为 10pt |
| 未绑定与未设置 | `SettingsView.swift` | 资产区显示一行“API 未绑定”，移除旁边重复的圆角状态块；止损额和下单设置为空显示“未设置” |

## 验证步骤

1. 使用 `TradeTool` scheme 和 generic iOS Simulator SDK 执行 `build-for-testing CODE_SIGNING_ALLOWED=NO`，验证应用及 XCTest 目标。
2. 使用本地 Mac Catalyst 预览与临时离线数据检查实际生产视图，覆盖亮暗主题、信号状态、设置空态、首页与编辑自选。
3. `ChartEngineCoreTests.testGridCellsStayHorizontalAcrossViewportSizes` 覆盖窄屏、较高竖屏及横屏绘图区；核对单格比例与分段边界。
4. 同步 `frontend/ios-app/docs/DESIGN_AND_AUTH.md` 和 `docs/DEVELOPMENT_LOG.md`，记录实际验证结果与限制。
5. 检查 Git 差异、敏感内容和未跟踪文件。本轮按用户最新要求仅保留本地修改，不提交、不推送。

本轮要求覆盖前一版的 `#202630` 背景、52pt 首页行高、左侧时间和价格标签在上的布局。

## 实际验证结果

- iOS Simulator SDK：应用及测试目标构建通过；本机没有 iOS 模拟器运行时，未在模拟器或真机执行。
- Mac Catalyst：实际执行 `AppearanceTests` 的 6 项回归与三视口网格比例回归，共 7 项通过，0 失败。
- 生产视图离线渲染：已检查亮色行情、三种信号状态、亮暗设置分组与空态、编辑自选字号、暗色 K 线横向网格。

- 时间行布局修正：时间采用独立顶行的自然文字高度，下方主体三列垂直居中；iOS 与本地预览构建通过，三种信号状态离线渲染核对通过。

- 最新设置字号：顶部“API 未绑定”默认 10pt、设置选项主文字默认 17pt；iOS 和本地预览构建通过，设置页渲染检查通过。修改仅保留本地，未提交或推送。
