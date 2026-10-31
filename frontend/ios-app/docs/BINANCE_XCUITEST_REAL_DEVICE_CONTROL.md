# Binance iOS 真机直控与样板采集

本文固化本项目已经验证可用的 Binance 参考 App 控制方式。目标是让后续开发者在同一台
iPhone 上重复采集公开 K 线详情页，而不依赖 iPhone 镜像、模拟器、网页截图或 Appium。

## 固定方案

- 连接方式：iPhone 通过 USB 连接 Mac，由 Xcode/XCUITest 的真机服务直接控制；
- Binance bundle ID：`com.czzhao.binance`；
- Trade Tool bundle ID：`com.oovso.trade`；
- Xcode scheme：`TradeTool Chart Calibration`；
- Trade Tool 构建配置：`Debug-Dev-B`；
- Binance 使用 `XCUIApplication(...).activate()`，保留人工准备好的公开详情页；
- Trade Tool 使用 `launch()`，确保采到当前安装的新二进制；
- 原始截图、录像、层级文本和 `.xcresult` 只写入 `/tmp`，不得加入 Git。

这套方案只允许操作公开行情与指标设置。不要自动进入或采集登录、账户、资产、持仓、
订单、交易和 API 密钥页面。

## 设备前置条件

1. 用数据线连接并解锁 iPhone，确认 Mac 和手机已经互相信任；
2. iPhone 已开启 Developer Mode 和 `Enable UI Automation`；
3. Binance 已停在需要对比的合约公开详情页，并把周期切到 `1小时`；
4. Trade Tool 使用 `TradeTool Dev B`；
5. 用下面命令取得当前设备 UDID：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun devicectl list devices
```

运行器不会自动登录 Binance，也不会替开发者猜测当前页面。页面跑偏时先停止采集、人工
恢复详情页，再重跑；跑偏后的图不能继续作为样板。

## 运行与导出

查看常用采集入口：

```bash
frontend/ios-app/scripts/run_chart_calibration.sh --list
```

采一张当前 Binance 准备状态：

```bash
IOS_DEVICE_UDID=<device-udid> \
frontend/ios-app/scripts/run_chart_calibration.sh \
testCaptureBinancePreparedChartState
```

逐个采集 MA、BOLL、SAR、AVL：

```bash
IOS_DEVICE_UDID=<device-udid> \
frontend/ios-app/scripts/run_chart_calibration.sh \
testCaptureBinancePrimaryIndicatorReferences
```

脚本默认使用 `Debug-Dev-B`，执行一个 UI 测试，并把 `.xcresult` 与附件导出到带时间戳的
`/tmp/trade-tool-chart-calibration-*` 路径。成功结束时会打印两个绝对路径。需要固定输出
前缀时可设置 `CALIBRATION_OUTPUT_ROOT`；脚本只接受系统临时目录，并在运行前检查手机
是否已经解锁，避免附件误进仓库或 Xcode 长时间等待锁屏设备。测试失败时也会尝试导出
系统截图、录像和 UI 层级，便于判断是页面前置状态还是控件变化，但仍返回失败退出码。

## 指标样板的稳定前置状态

采 MA、BOLL、SAR、AVL 前，Binance 必须处于以下状态：

- `BTCUSDC` 永续合约详情页，周期为 `1小时`；
- EMA 和 SUPER 已开启；
- MA、BOLL、SAR、AVL 已关闭；
- VOL 和 MACD 可保持开启，用来维持当前参照页面的副图组合。

XCUITest 无法稳定读取 Binance 指标按钮的选中状态，所以这里使用明确的开始/结束约定。
测试先关闭 EMA、SUPER 得到无主图指标基线，再按 `MA -> BOLL -> SAR -> AVL` 逐个执行
“打开、截图、关闭”，最后恢复 EMA、SUPER。正常完成后仍是同一个稳定状态，可以直接
重复执行。

必须一次只打开一个待复刻主图指标。一次全开得到的图例、线条、颜色和遮挡关系相互
污染，不能用来判断单个指标的 UI、参数或几何位置。

参数页采集使用以下三个入口。它们对应“图表上的设置入口、指标设置列表、逐个参数详情”
三个页面层级；执行前必须人工回到各入口所要求的页面，不能把前一项的结束页误当成下一
项的稳定起点：

- `testCaptureBinanceIndicatorSettings`
- `testCaptureBinanceIndicatorParameterSettings`
- `testCaptureBinancePrimaryIndicatorParameterDetails`

主图样板入口会在任何指标点击前检查 `1小时` 控件，并拒绝在“指标设置”页面继续执行。
因此若参数采集后忘记返回图表，它只会给出清晰失败信息，不会误点设置页中的同名指标。

## K 线手势约束

- 横向拖动、长按和双指缩放的起点必须落在实际 K 线绘图区；当前统一纵向坐标是屏幕
  高度的 `0.36`，不要从顶部行情摘要、指标按钮或价格标尺开始；
- 采粗细序列时，先把 Binance K 线缩到最细状态，再在 K 线绘图区逐级拉宽，每一级都
  单独截图；
- 同一对比轮次必须锁定设备、方向、币对、周期、locale、timezone、字体大小、指标组合
  和手势坐标；
- Binance 会随手势或异步加载改变页面。若手势把页面带离详情页，立即判定该轮样本失效；
- XCUITest 在 390pt、3x 设备上得到的原始截图为 `1170 x 2532` PNG。视频帧只能证明
  状态变化，不能替代原始 PNG 做像素金标。

相关手势、差分与证据规则见
[`KLINE_CHART_CALIBRATION.md`](KLINE_CHART_CALIBRATION.md)。

## 故障恢复

- `Developer Mode`、信任或 UI Automation 报错：解锁手机，重新确认信任与系统开关，
  再运行同一个测试；
- 找不到 Binance 控件：确认语言、详情页、周期与指标栏都符合前置状态；不要临时改坐标
  绕过错误页面；
- Trade Tool 没有后端数据：使用测试已有的 `--chart-calibration-fixture` 启动参数取得
  确定性图表，不要把网络失败样本当作 UI 差异；
- 输出路径已存在：不复用旧目录，改用默认时间戳或新的 `CALIBRATION_OUTPUT_ROOT`；
- 设备断连：先用 `xcrun devicectl list devices` 确认状态，再重跑当前单项。

测试代码位于
[`TradeToolChartCalibrationUITests/ChartCalibrationUITests.swift`](../TradeToolChartCalibrationUITests/ChartCalibrationUITests.swift)。
