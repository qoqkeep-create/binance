# iOS 持仓浮窗

## 使用与范围

在“我的 → 持仓浮窗”点击开启，再次点击或使用浮窗右上角关闭按钮即可关闭。浮窗为 App 内原生 SwiftUI 组件，跨底部页面和导航详情显示；系统弹窗、sheet 和全屏呈现在其上方。当前没有跨 App、画中画或后台展示能力。

卡片大小为 184 × 82 pt，单次显示交易对、方向、市价和浮盈；多笔持仓点击顶部切换，右侧显示序号。拖动可调整位置，边界保留 12 pt、底部预留 76 pt，避免覆盖底部导航。沿用现有浅色、深色主题和盈亏颜色，不提供交易操作。实现位于 `frontend/ios-app/TradeTool/Features/USDT/FloatingPositionsView.swift`，由 `MainAppView` 的 NavigationStack 外层挂载。

## 数据和生命周期

- 已绑定 API 且 App 在前台开启浮窗时，读取当前账户模式的 `GET /v1/position/list`，完成一次请求后等待 3 秒再刷新；账户事件经 `USDTStore.liveRevision` 触发提前刷新，同一时刻最多一个请求在途。
- 币种、方向、市价和浮盈分别来自 `symbol`、`side`、`current_price`、`pnl`，与持仓页使用相同接口。市价与浮盈取同一次服务端响应，不用独立 ticker 重新计算盈亏。金额采用 Decimal；浮盈显示两位和 `U`，小币价保留有效小数；缺失值显示 `--`。
- 未绑定、无持仓、首次同步和更新失败分别显示状态。失败清空旧快照，避免把旧价格显示为当前价格；下一轮重试。
- 关闭、退后台或离开已登录主界面时停止轮询并废弃旧请求。账户、模式或绑定代际变化清空快照；响应还必须匹配请求 ID 与当前 `USDTStore.scope`，旧身份响应不能覆盖新账户。
- UserDefaults 只保存开关与归一化拖动位置，不保存持仓、价格、盈亏或凭证。菜单和 overlay 共享同一 UserDefaults 实例；DEBUG 视觉测试使用独立 suite，不改用户实际偏好。

## 验证方式

`FloatingPositionsTests` 使用无网络 API 替身，覆盖 Decimal / 小币价、缺失值与负零、平仓后空列表、失败清理、旧账户响应、关闭后在途响应、并发请求去重和拖动边界。

`WebParityUITests` 的 `testFloatingPositionsAcrossPagesAndDragging` 与 `testFloatingPositionsEmptyUnboundAndDarkStates` 使用 [Web 原生复刻](ios-web-parity.md#本地校对) 的 DEBUG 隔离数据，验证开启、多个持仓切换、跨 Tab / 详情页、拖动、关闭、空仓、未绑定和深色带单状态，并导出截图实际检查。fixture 不连接真实交易，Release 不包含该入口；真实有仓账户、iPhone 和本次 TestFlight 构建仍需分别验收。实际日期与结果见 [变更记录](changes.md)。
