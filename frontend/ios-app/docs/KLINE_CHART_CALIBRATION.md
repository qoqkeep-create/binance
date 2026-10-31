# K 线图同机校准

本文固定第二十三批的采集、差分与证据边界。校准只使用同一台设备上的公开行情页，
不读取、导出或提交账户、余额、持仓和订单页面。

## 固定环境

- 设备：iPhone 17e（390pt，3x）；
- 当前系统：iOS 26.6；
- 参考 App：Binance `3.17.3`，bundle ID `com.czzhao.binance`；
- 候选 App：Trade Tool，bundle ID `com.oovso.trade`；
- Trade Tool 配置：`TradeTool Dev B` / `Debug-Dev-B`；
- Xcode：26.6；
- 设备设置：Developer Mode 与 `Enable UI Automation` 都必须开启。

Binance 或系统版本变化后，旧截图和旧手势数值只能作为历史记录，不能直接继续作为
当前验收真值。

## 采集入口

完整的 USB 真机直控、页面前置状态、单指标采集和故障恢复流程见
[`BINANCE_XCUITEST_REAL_DEVICE_CONTROL.md`](BINANCE_XCUITEST_REAL_DEVICE_CONTROL.md)。

独立 scheme `TradeTool Chart Calibration` 固定使用 Dev B 的 `Debug-Dev-B`。它不加入日常
`TradeTool Dev B` 测试 action，避免普通单元测试意外启动第三方 App。
候选 App 用 `launch()` 启动，确保 Xcode 刚安装的新二进制替换仍在运行的旧进程；
Binance 只用 `activate()`，避免破坏用户已经准备好的公开详情页。

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/usr/bin/xcodebuild \
  -allowProvisioningUpdates \
  -project frontend/ios-app/TradeTool.xcodeproj \
  -scheme 'TradeTool Chart Calibration' \
  -configuration Debug-Dev-B \
  -destination 'platform=iOS,id=<device-udid>' \
  -derivedDataPath /tmp/trade-tool-chart-calibration-dd \
  -resultBundlePath /tmp/trade-tool-chart-calibration.xcresult \
  test
```

截图只保留在本地 `.xcresult`。导出时使用新的临时目录：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun xcresulttool export attachments \
  --path /tmp/trade-tool-chart-calibration.xcresult \
  --output-path /tmp/trade-tool-chart-calibration-attachments
```

需要复核录像中的活动态时，可按测试日志时间提取单帧：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun swift frontend/ios-app/scripts/chart_video_frame.swift \
  --input /tmp/screen-recording.mp4 \
  --time 12.5 \
  --output /tmp/crosshair-frame.png
```

不要把 `.xcresult`、原始截图、录像、账户数据或 Instruments `.trace` 加入 Git。

## 固定状态矩阵

每一行必须同时取得 Binance 与 Trade Tool 的同尺寸原图：

| 状态 | 截图 | 固定输入/录像 | 当前状态 |
| --- | --- | --- | --- |
| 默认最新位置 | 必需 | 无 | 已采首轮；币对/副图未对齐，不作为整图验收 |
| 历史平移位置 | 必需 | 右向左固定距离拖动 | 两端已各采 5 轮结束帧与整段录像 |
| 默认/最小/最大缩放 | 必需 | 固定中心双指 pinch | 两端已各执行 5 次输入并采极值结束帧 |
| 十字光标点按/长按 | 必需 | 单击、二次单击、长按横移 | 两端原始无损图已齐；单击常驻、二次单击关闭、长按拖动且松手常驻已按同输入复验 |
| 惯性与 latest/oldest 边界 | 结束帧必需 | 60fps 原始录像 | latest 与惯性各 5 轮结束帧已采；Trade Tool oldest 已完成，Binance 已确认按需继续加载历史；60fps 原始 trace 待补 |
| EMA/SUPER + VOL/MACD/RSI | 必需 | 同一指标组合 | Trade Tool 已支持并真机确认三副图同时显示；精确面板高度/字体差分尚未冻结 |

正式对比前必须锁定 symbol、interval、设备方向、字体大小、locale、timezone、指标
组合和截图裁切。动态价格文字与 live candle 可建立 mask，但 candle slot、面板、网格、
轴、图例、十字光标和标签不能被大范围 mask 掩盖。

## 像素差分

仓库脚本使用 macOS Core Graphics/ImageIO，无第三方 Python 依赖。`--crop` 使用截图
左上角为原点的物理像素 `x,y,width,height`；`--threshold` 是单通道 0...255 容差。

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun swift frontend/ios-app/scripts/chart_calibration_diff.swift \
  --reference /tmp/binance.png \
  --candidate /tmp/trade-tool.png \
  --output-diff /tmp/chart-diff.png \
  --output-json /tmp/chart-diff.json \
  --crop 0,300,1170,900 \
  --threshold 8
```

报告固定输出总像素、变化像素比例、RGB 平均绝对差、像素最大通道差的 p95/最大值和
变化包围盒。不同状态分别报告，不能把全屏平均值当作局部图元已经一致的证明。

## 手势与 token 冻结规则

同一输入至少重复 5 次，记录起点、终点、持续时间、帧率、总位移、惯性时间/距离、
边界最大位移和回弹时间。中位数用于候选 token，离群录像保留并解释。视觉测量至少
包括 panel/轴尺寸、slot/body/wick、字体基线、线宽/虚线、圆角、十字光标标签和触觉
触发时机。

只有原始截图、录像、固定输入和差分报告齐全后，测量值才能进入集中 token。缺少
真机证据时保持当前 provisional 值，不得把主观手感写成“与 Binance 完全一致”。

## 2026-07-31 首轮结果

首轮在上表固定设备上采集 Binance `BTCUSDT 1h` 与 Trade Tool Dev B
`BTCUSDC 1h`。两图都是 `1170 x 2532` 原始截图。由于币对和副图组合不同，主图加
副图的未遮罩裁切 `0,760,1170,1370` 仅作为差异基线：阈值 8 时变化像素率
`27.7709%`、平均 RGB 绝对差 `21.9541`、p95 最大通道差 `213`。该数字不能作为
视觉通过或失败结论。

可独立于价格形状判定的结果已经落地：

- sRGB Metal drawable 原先直接接收 sRGB token，真机实际输出被二次伽马编码；绿色
  从目标附近的 `#2AA575` 变为 `#71D2B4`，红色从 `#F6465D` 变为 `#FB8FA3`。
  renderer 现先把 token 线性化，再写入 `.bgra8Unorm_srgb`；
- Binance 主图分区的稳定实色聚类为上涨 `#28A473`、下跌 `#F63C55`、EMA21
  `#F0B90B`、EMA55 `#E840B5`、EMA144 `#8B68C4`。这些值已进入图表专用色板；
- Binance 图例第一行是 EMA21/55/144，第二行是 SuperTrend。Trade Tool 已改为相同
  行序；
- 首轮从屏幕归一化 `x=0.68` 拖到 `x=0.35` 后，Binance 保留了右侧未来空白，
  当时的 Trade Tool 则回弹到 latest；后续五轮和修正见下一节；
- Binance 当前可以同时显示 VOL、MACD、RSI；Trade Tool 仍只允许 MACD/VOL 二选一
  且尚无 RSI。这是指标/面板能力差异，不能用像素 mask 隐藏，应在指标阶段单独补齐。

最终真机复验中，Trade Tool 主图分区的五个稳定实色分别为 `#28A473`、`#F63C55`、
`#F0B90B`、`#E840B5`、`#8B68C4`，与本轮 Binance 参考聚类逐项相同。Dev B 的完整
iPhone 17e 模拟器测试为 `70/70`，后端 Java 25 测试为 `72/72`。

UI 测试会在安装导致导航栈复位时自动从 Dev B 行情页进入 `BTCUSDC` 详情，并断言
`1h` 控件存在后才截图。Binance 测试仍只激活用户已准备好的公开详情页，不尝试登录、
读取账户或自动修改第三方 App 的持久状态。

## 2026-07-31 五轮手势复验与 latest 边界修正

同一台设备上，两端都用完全相同的归一化坐标和 XCTest 速度档执行 5 轮。Binance
完整序列耗时 `174.260s`，Trade Tool Dev B 修正前/后完整序列分别耗时
`168.932s` / `175.344s` 且都通过；每轮 `.xcresult` 都保留系统自动录制的视频、
合成输入和结束帧。导出视频的 nominal frame
rate 约为 `23.966fps`，不是 60fps，因此它只能证明输入顺序和稳定结束状态，不能用来
冻结逐帧减速曲线、回弹时间、`0.998/ms`、72pt 或 14rad/s。

latest 边界有两组可重复证据：

- 从重置后的 1h 状态重复 5 次 `x=0.68 -> 0.35` 慢拖，Binance 5/5 都保留相同
  位移，修正前 Trade Tool 5/5 都回到 latest；
- 上限专项先执行一次 `0.68 -> 0.35`，再从仍位于图形区域的 `0.35 -> 0.05`
  连续拖动。Binance 第 2 次到达上限，第 3～5 次位置不再变化；像素位置与 99px
  slot 间距对应“未来 offset 最多为半个可视窗口”。250pt/s 的慢拖没有可见松手惯性，
  750pt/s 的快甩仍进入惯性样本。

Trade Tool 当时允许负 `trailingOffsetSlots` 并按
`-visibleSlotCount * 0.5 ... maximumHistoryOffset` 夹取。未来空白成为可持久化、可
rebase 的真实视口状态，不再借用松手即消失的 overscroll translation；`followsLatest`
只在 offset 接近 0 时成立，“回到最新”明确归零。最小惯性起速从 provisional 45pt/s
提升到 300pt/s，用来区分本轮已确认的 250pt/s 慢拖和 750pt/s 快甩。新二进制在同机
专项中同样于第 2 次到达当时采用的半窗上限，第 3～5 次保持稳定。该半窗推断先在
2026-08-01 被误纠正为固定 5 个 future slots，最终语义在 2026-08-02 按用户真机观察
修正为“左滑极限只剩最后 5 根 K 线”，见下文最新复验。

本轮仍没有关闭第二十三批：十字光标激活帧、60fps 惯性/弹簧 trace 和
VOL + MACD + RSI 多副图能力尚未同时对齐。Trade Tool 有限数据集的 oldest 边界已在
下一节完成；Binance 会按需继续加载历史，不把任意固定拖动次数伪装成其绝对 oldest。
当前只冻结有结束帧和重复证据支持的状态语义，不把 24fps XCTest 录像描述成逐帧性能证明。

## 2026-08-01 oldest 边界专项入口

校准测试新增 Binance 与 Trade Tool 两个独立 oldest 专项。固定输入为先执行 5 次
`scale=0.5` 缩到最小 K 线宽，再从屏幕归一化 `x=0.12 -> 0.88`、`y=0.48`
执行 120 次 250pt/s 慢速右拖接近已加载历史上限，最后重复 5 次相同边界输入；接近
完成帧和五轮结束帧均保留为附件。两端使用完全相同的输入预算，不根据截图内容动态
增加拖动，避免把参考 App 的按需历史加载误判为固定 oldest 边界。物理机系统截图曾
间歇产生全屏合成缺块，后续入口会为每个检查点保留间隔 `0.8s` 的两份样本；坏帧必须
显式排除，不能计入视觉通过率。

首轮 20 次接近拖动后的真机结束帧证明预算不足：Trade Tool 的 5 个边界轮次从约
6 月 17 日继续移动到 6 月 8 日，Binance 也继续加载更早历史。两项 UI 测试虽然均为
0 失败，但只能证明输入执行完成，不能证明 oldest 状态已稳定。因此固定输入预算先
提高到 100 次后重跑；Trade Tool 已稳定在约 5 月 31 日的 1500 根数据上限，但
Binance TRUMPUSDT 的 5 个边界轮次仍继续进入更早的上市初期数据。100 次结果只计
Trade Tool oldest 通过，Binance 仍是有效失败证据；统一预算再提高到 120 次。

120 次同预算复验给出了边界语义的最终结论：

- Trade Tool Dev B `BTCUSDC 1h` 用例耗时 `372.022s`、`1/1`、0 failures。120 次接近
  输入后，5 次边界输入都在日志和录像中完整执行；可用的第 1、3、5 轮结束帧在
  `0,760,1170,1100` 核心图表裁切内两两逐像素相同，三组报告均为
  `1,287,000` 像素、变化像素 `0`、平均 RGB 绝对差 `0`。其余两帧有系统级合成缺块，
  已排除而未冒充通过。结合前一轮 100 次预算的三张完整稳定帧，确认有限 1500 根数据
  的 oldest clamp 稳定，无需修改生产图表代码；
- Binance 用例耗时 `355.559s`、`1/1`、0 failures，但本轮用户准备页已是
  `BNBUSDT 1h`。120 次后 5 轮仍持续进入更早价格区间，符合长历史交易对按需加载行为，
  不计为 absolute oldest 通过。该结果也证明固定次数只适合作为可复现输入预算，不能
  跨不同上市时长的 symbol 断言 Binance 已到绝对最老端。

因此本专项关闭的是 Trade Tool 自身 oldest 边界稳定性；Binance 参考结果冻结为“到达
已加载左端时继续补历史”，而不是不存在的统一拖动次数。若后续要比较绝对上市边界，
必须预先锁定同一 symbol 及其上市时间，不能沿用当前 BNB/TRUMP 的混合证据。

本轮 `TradeTool Chart Calibration / Debug-Dev-B` 已在 iPhone 17e iOS 26.5 模拟器
完成 `build-for-testing`。模拟器没有 Dev B 登录会话，因此没有注入凭证或把未进入详情
页的失败冒充手势结果。物理 iPhone 17e 已确认有线配对、Developer Mode 开启且未锁屏，
但 XCTest 连续 3 次在进入测试方法前报告 `Timed out while enabling automation mode`；
清理残留 `automationmode-writer` 后结果不变。故当时只标记“专项入口已实现并编译”，
未标记 Binance/Trade Tool oldest 真机证据完成。设备端 `Enable UI Automation` 与
开发者证书信任恢复后，20、100、120 次预算的真机专项均已执行并得到上述结论；
该批当时未重跑 future blank 五轮；其半窗结论已在后续人工对照中被“左滑极限只留
最后 5 根 K 线”的规则取代。

## 2026-08-01 币安七项细节复验

物理 iPhone 17e 上重新抓取币安 `BTCUSDT 1h` 与 Dev B `BTCUSDC 1h` 同页双样本。
币种报价不同，因此不比较绝对价格形状；可独立判定的渲染和手势语义按本轮用户观察
重新冻结：

- 原生 `1m` 未收盘 K 线通过 `market.kline/upsert` 实时替换；高周期页面同时订阅
  所选周期和 `1m`，将 `1m` 最新价合并进当前 provisional K 线，所有周期最多每
  `250ms` 发布一次 `ChartDataFrame`。`market.ticker` 保留 24h 数据和价格兜底；
  最新价、K 线实体、EMA 与 SuperTrend provisional 值由同一帧输出；
- SuperTrend 通用 figure style 同时绘制分段线与 K 线收盘价之间的红绿透明带。Metal
  线性色域下 `fillAlpha=0.01`，取样亮度与币安背景带一致；
- 竖网格仅保留 25%、50%、75% 三条内部线，左右 plot 边界不画竖线；
- K 线间隔固定为 `2.2pt`，缩放只改变 slot 和实体宽度，不再使用 `3pt` 半宽上限；
- latest 端左滑极限按可视根数动态计算，使画面最终只保留最后 5 根 K 线，不是固定
  5 个 future candle slots；
- 最新价使用白色虚线；标签改为黑色半透明底、白色圆角描边和白色文字。

Dev B 单测新增固定间隔/缩放、左滑极限 5 根可见 K 线、色带、圆角价格标和 ticker
驱动实时指标同帧更新断言。
模拟器完整测试与真机校准用例均通过；原始截图和 `.xcresult` 仍只保留在本机 `/tmp`。

## 2026-08-01 十字光标活动态专项

为绕开 XCTest 在长按与截图之间的串行化，校准入口新增两条只负责维持活动态的独立
用例。两端均从屏幕归一化 `x=0.48,y=0.46` 长按 `0.55s`，慢速拖到
`x=0.70,y=0.50` 后继续保持 `3s`，完整重复 5 次。Binance 用例为 `39.389s`、
Trade Tool 最终 Dev B 用例为 `52.119s`，两项均为 `1/1`、0 failures。

`chart_video_frame.swift` 使用 AVFoundation 按时间从 XCTest 自动录像导出
`1170 x 2532` PNG，供逐帧复核。这里的 PNG 是约 24fps 有损 MP4 的解码帧，不是系统
原始截图；它能证明十字光标确实处于活动态并暴露稳定的合成问题，但不能冒充无损像素
golden、60fps 动力学 trace 或逐像素一致性证据。原始录像、解码帧和 `.xcresult` 仍只
保留在 `/tmp`，不进入 Git。

活动帧确认两端都具备吸附竖线、手指横线、选中点、右侧值标签、底部时间标签，并跨
主图与当前副图联动。Binance 参考还显示左侧 OHLC/涨跌/成交量卡片，且十字线继续贯穿
VOL、MACD、RSI。首轮 Trade Tool 活动帧则暴露了两个真实缺陷：

- live-tail 的固定图例和 crosshair 覆盖层被按 primitive 类型合批，覆盖背景之后仍会
  绘制旧图例 glyph，造成 EMA、SuperTrend、MACD 新旧值叠字；
- 十字光标把所有主图指标挤在单行，横向空间不足时会丢掉 SuperTrend；SuperTrend 的
  up/down 两条渲染 series 也不应被当成两个逻辑图例。

修正后，动态指标图例批次显式标记为“十字光标活动时隐藏”，屏幕与离屏 renderer 使用
同一筛选路径；历史选择按逻辑 legend 解析，每个已启用指标只保留一个选中值；主图按
原有两行恢复 EMA21/55/144 与 SuperTrend，OHLC、涨跌/涨跌幅和成交量移入与参考结构
一致的避让数据卡。最终 5 个活动帧均无叠字，EMA、SuperTrend 与 MACD 选中值稳定，
松手后普通 live 图例恢复。新增回归同时断言活动态不再提交 live 图例批次，并且所有
逻辑图例 key 都实际进入有界覆盖层。修正后的 Dev B 模拟器完整 Core + onscreen
套件为 `70/70`、0 failures、0 skipped。

本专项补齐的是可审计的活动态功能证据，并修复由证据发现的合成错误；它仍不把当前
字体、卡片尺寸、虚线 token 或时间格式描述为与 Binance 像素一致。第二十三批继续因
60fps 惯性/弹簧原始 trace、原始无损活动截图以及 VOL + MACD + RSI 多副图能力保持
开放。

## 2026-08-01 多副图与无损活动态复验

Trade Tool 已移除 VOL/MACD 单副图互斥并新增 Wilder RSI(14)。Dev B 通过
`--chart-indicators-all` 在同一页面同时启用 VOL、MACD、RSI；UI 测试逐一断言三个
按钮的 accessibility value 为“已开启”。物理 iPhone 17e 用例耗时 `20.956s`、
`1/1`、0 failures，导出的 `1170 x 2532` 原始 PNG 人工确认三个副图同时存在，RSI
使用独立 `0/50/100` 固定域。该图关闭“多副图能力不存在”的差距，但币对与价格形状
并未与 Binance 锁成相同，因此不把整图宣称为像素一致。

为取得 Trade Tool 原始无损 crosshair 活动态，Debug-Dev-B 新增只在校准参数
`--chart-calibration-persist-crosshair` 下生效的测试行为：真实长按/横移结束后保留
同一 `CrosshairSnapshot`，让 XCTest 可以在手势命令返回后采原始 screenshot；正常
Debug 启动和 Release 均不改变。真机用例耗时 `24.524s`、`1/1`、0 failures，保存
两张 `1170 x 2532` 原始 PNG。人工复核确认吸附竖线、手指横线、右侧价格标签、底部
时间标签、OHLC/涨跌/成交量卡片，以及 EMA/SuperTrend/MACD 选中值均处于活动态且
无叠字。

因此当前剩余校准证据缩小为 Binance 原始无损活动截图，以及用于冻结惯性/弹簧参数
的原始逐帧手势 trace；本轮 Game Performance 的 60Hz surface-swap 轨迹只证明渲染
帧率，不冒充相同输入下的 Binance 动力学曲线。

## 2026-08-02 最新价与屏幕极值专项

物理 iPhone 17e 上把手势固定在主 K 线区域 `y=0.36`，分别采集 Binance 与 Dev B
的默认态、连续三次向右拖动和连续三次向左拖动。参考截图确认：价格标尺是透明覆盖层，
其下方 K 线、EMA、SuperTrend 和横向网格继续绘制到屏幕右边；默认态的白色虚线只从
当前 K 线连接到屏幕右侧圆角价格框；向右拖动使当前 K 线移出屏幕右侧后，虚线改为
整行，价格框移到价格标尺左侧并显示右箭头；向左拖到 latest 极限时，当前 K 线仍在
画面左侧，虚线继续从该 K 线起画，不使用整行状态。

Dev B 据此取消主图在价格标尺左边界的横向裁切，移除 `>>` 快速复位按钮，并把最新价
状态拆分为可见、移出左侧和移出右侧三种。主图同时根据当前全宽画布内的 K 线计算最高
价和最低价，以白字和短横引线标注；极端 latest 视口只剩少量 K 线时，时间轴标签会做
边界夹取与碰撞消除，避免文字叠在一起。Metal 字形批次新增可选时间轴锚点，使屏幕极值
标签跟随 K 线平移但不随横向缩放拉伸。原始截图和 `.xcresult` 只保留在本机 `/tmp`。

## 2026-08-03 十字光标点按、数据卡与轴标签专项

本轮在物理 iPhone 17e、iOS 26.6 上重新采集 Binance 和 Trade Tool 的原始
`1170 x 2532` PNG。Binance 只激活用户已经打开的 `BTCUSDC 1h` 公开详情页；Trade
Tool 安装并启动 `TradeTool Dev A / Debug`。先前误以 Dev B 启动得到的候选图显示
`0.00000`，该组证据已明确作废，不参与行情数据、文字或几何决策。

固定输入序列为：主图 `x=0.46,y=0.36` 单击两次，历史位置
`x=0.28,y=0.39` 单击两次，再从 `x=0.40,y=0.36` 长按 `0.55s`、慢拖到
`x=0.68,y=0.43` 并松手，最后单击关闭。两端证据确认相同状态机：

- 第一次单击显示十字光标，手指抬起后不消失；第二次单击关闭；
- 长按后可连续拖动吸附 K 线，横线随手指价格移动，松手后十字光标仍不消失；
- 吸附竖线、横线和交点在同一 Metal 帧呈现，竖线按 `openTime` 锁定 K 线；
- 常驻状态下 250ms 行情只刷新最新价相关数据，不改变已选历史 K 线身份；
- 每个可见主/副图底部都显示同一个 `yyyy-MM-dd HH:mm` 时间标签，关闭时一并恢复。

右轴复合标签冻结为约 `70.5pt x 34pt` 的白色圆角块，左段为黑色圆形和白色加号，
中间使用黑色分隔线；右段第一行是十字横线价格，第二行是相对当前最新价的变化率：

```text
(crosshairPrice / latestPrice) - 1
```

该百分比不是选中 K 线的开收涨跌幅。Binance 样本 `65,290.0 / 62,832.6` 显示
`+3.91%`；Dev A 样本 `64,831.9 / 62,904.8` 显示 `+3.06%`，两组都与公式舍入一致。
当前最新价标签继续独立保留，不会被十字标签替换。

历史信息卡按竖线左右避让，约 `90pt` 宽、`5pt` 圆角、每行约 `14.3pt`，固定十行：

```text
时间  MM-dd HH:mm
开    open
高    high
低    low
收    close
涨跌  close - open
涨跌幅 (close - open) / open
振幅  (high - low) / abs(open)
量    base volume
额    quote volume（万/亿）
```

涨为绿色、跌为红色，其余数据为白色。活动时主图和副图图例改为所选 K 线对应的
EMA/SuperTrend/MACD 值；关闭后恢复 live 值。卡片允许跨副图上方叠加，避免多副图
压缩主图时截掉末行。所有卡片、标签、圆角和文字仍由 Metal + Core Text glyph atlas
绘制，没有新增 UIKit 动态图表文字。

自动化结果：Binance 参考专项 `1/1`、0 failures、`26.656s`；Dev A 候选专项
`1/1`、0 failures、`40.806s`。Dev A 模拟器 Core + onscreen 完整套件为
`79/79`、0 failures，其中十字光标 10,000 次移动资源边界测试耗时约 `11.924s`；
构建与测试均使用 `Debug-Dev-A.xcconfig`。原始 `.xcresult`、PNG、录像仍只保留在
`/private/tmp`，不加入 Git。由于两端实时价格和 K 线内容持续变化，本轮逐项冻结可观察
状态、字段公式和 UI token，不把动态整屏差分伪装成同一行情帧的逐像素 golden。

## 2026-08-03 价格轴、历史图例、当前价回位与 VOL 专项

物理 iPhone 17e、iOS 26.6 上继续使用用户已打开的 Binance `BTCUSDC 1h` 详情页，
按同一组动作采集右侧价格轴上拖/下拖、EMA/SUPER 开关、历史平移、当前价标签与
VOL。原始结果保存在本机 `/private/tmp/binance-unified-20260803-1.xcresult` 和
`/private/tmp/binance-vol-return-20260803-1.xcresult`，不进入 Git。

本轮冻结以下参考行为：

- 右侧价格标尺内单指竖拖只改变价格域，不改变时间轴；向上拖放大纵向价格变化，
  向下拖压缩。参考样本默认域约 `66,451–62,054`，上拖后跨度缩小，下拖后约
  `68,941–59,564`；因此方向不是凭经验指定，而是以真机结果为准；
- 关闭 EMA 或 SUPER 时，对应曲线/带状图形与主图顶部完整图例必须在同一帧消失；
  再次开启时一起恢复，不能保留旧数值等待下一次 250ms 行情；
- 平移到历史区后，主图和全部副图图例继续显示，数值取当前可视范围最右一根真实
  K 线。它们不继续显示最新根，也不能因为最新根移出画面而隐藏；十字光标激活时则
  暂时切换为十字选中根；
- 当前 K 线移出屏幕右侧后，标签为 `价格 >` 的黑底白边圆角框。白色虚线在框左边
  截止、从框右边恢复，不能穿进框内；文字、箭头、虚线和框的水平中线垂直居中。
  点按该标签回到最新视口；
- VOL 副图使用从零开始的独立右轴、涨跌方向色柱、黄色 MA(5) 与紫色 MA(10)。顶部
  依次显示 `VOL(BTC)`、`VOL(USDC)`、`MA(5)`、`MA(10)`；首项为 base volume，
  第二项为 quote volume，值用 `K/M/B` 紧凑格式。参考样本为
  `850 / 53.3M / 3.18K / 3.59K`。历史平移和十字光标都切换到所选历史根，不能隐藏。

实现采用独立 `ChartPriceViewport`，以指数曲线把累计竖向位移映射为倍率，范围固定
`0.35...4.5`；只有价格面板右轴区域取得该手势，父级长页面纵向滚动仍按既有仲裁。
场景请求身份加入 indicator-history 对象身份，解决同 candle revision 下开关指标后
旧图例/旧曲线滞留。历史图例、当前价命中框和 VOL base/quote 值都随不可变
`RenderState` 发布，不增加 UIKit 动态 overlay。

验证结果：Dev A 模拟器完整 Core + onscreen 套件为 `80/80`、0 failures，包含 4Hz、
20Hz、10,000 次 live-tail 更新和 10,000 次十字移动；Dev A 物理真机统一用例为
`1/1`、0 failures、`68.964s`。用例用 accessibility value 断言平移后为“历史”，
点按实测当前价框中心 `x=0.78,y=0.69` 后为“最新”；原始通过结果位于
`/private/tmp/tradetool-unified-dev-a-20260803-2.xcresult`。第一轮曾用猜测的
`y=0.45` 点击而未命中，状态正确保持“历史”；该结果用于校正自动化坐标，不算产品
功能失败，也没有复跑两小时长稳。

## 2026-08-03 图表加载动画专项

同一台 iPhone 17e、iOS 26.6 上分别对 Binance `BTCUSDT` 和 Trade Tool Dev A
执行 4 轮 `1小时 ↔ 4小时` 切换，每轮在点击返回后连续保留 6 张快速截图，并保留
系统自动录像。两端用例均为 `1/1`、0 failures。

Binance 首个加载帧显示纯黑图表槽位和正中央 4 柱黄色动画，真实图完成后直接替换。
原始 `3x` PNG 中四柱 X 范围分别约为 `553...562`、`571...580`、`589...598`、
`607...616px`，即每柱约 `10px`、间距约 `8px`、整体约 `64px`；活动高度约
`10...30px`。颜色使用既有 Binance yellow token `#FCD535`，录像中可见四柱按相位
连续改变高度，不是系统圆形 `ProgressView`。

Trade Tool 按相同几何和颜色实现后，快速截图确认切换瞬间只出现 4 柱加载动画，随后
直接进入目标周期 Metal 场景；没有静态蜡烛、模拟指标或旧周期画面闪回。模拟器 Core +
onscreen 完整回归为 `82/82`。原始 `.xcresult`、PNG 和 MP4 只位于
`/private/tmp/tradetool-binance-loading.xcresult` 与
`/private/tmp/tradetool-loading-dev-a.xcresult`，不加入 Git。
