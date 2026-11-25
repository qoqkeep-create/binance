# Web 图表控件与附图联动设计

## 目标

保留 TradingView 作为主 K 线数据与绘图引擎，把重复的顶部周期栏移到页面自身，并让页面自建的 MACD、StochRSI 附图具备可调高度、颜色约定和统一十字线索引。主图与附图继续共用交易对和周期偏好，账号同步仍沿用现有 Web settings 接口。

## 交互决定

- 页面顶部周期按钮固定为 `3m / 5m / 15m / 1h / 4h / 1D`，分别映射到 TradingView `3 / 5 / 15 / 60 / 240 / D`。
- TradingView 主图隐藏自身顶部工具栏，但保留主图和允许用户使用的左侧画线工具。
- EMA 21、55、144 继续由 TradingView study preset 绘制并固定长度。当前官方 Web Component 不接受 study plot color override；本轮不注入自建主图线，颜色要求需改用支持 `studies_overrides` 的授权 Charting Library 或后续官方能力。
- MACD 快线为绿色、慢线为紫色；正柱实心绿色，负柱空心紫色。StochRSI 的 K 线为绿色、D 线为紫色。
- 两个附图共享一个拖拽分隔条，总高度限制在 72–260px，并保存到当前账户浏览器的 localStorage；键盘上下箭头每次调整 8px。
- 主图和附图在同一 chart stage 内按横向比例选择最近一根自建指标线，附图显示与主图光标相同位置的垂直虚线；在任一附图移动也会更新另一附图。

## 实现边界

`TradingViewWidget` 负责主图生命周期、周期栏、stage 横向指针比例和指标高度；`CompactIndicatorStrip` 负责 K 线请求、指标计算、附图绘制、分隔条和附图 hover 索引。由于 TradingView Web Component 的图表内容在跨域封装文档内，页面不读取内部 crosshair 事件，而是在同一个外层 stage 上按指针横向比例绘制附图联动线，避免引入 TradingView 私有 API。

## 验收

- 六个周期按钮切换后主图和附图请求周期一致，刷新后账号偏好仍可恢复。
- 主图显示 TradingView 蜡烛、EMA 三色和原有 Supertrend；页面不渲染自建主 K 线。
- MACD／StochRSI 附图高度可拖拽、可用键盘调整，刷新后保留。
- 主图或附图移动指针时，两个附图均显示同一横向虚线；离开 chart stage 后清除。
- `npm test`、`npm run build`、`git diff --check` 通过；线上浏览器验收周期栏、附图高度和附图联动。TradingView 主图是否能连接取决于当前浏览器到 TradingView CDN 的网络状态。
