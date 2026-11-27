import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { CSSProperties, ReactNode } from "react";
import { RefreshCw, SlidersHorizontal, TrendingDown, TrendingUp } from "lucide-react";
import {
  createChart, ColorType, CrosshairMode, LineStyle,
  CandlestickSeries, LineSeries,
  type IChartApi, type ISeriesApi, type IPriceLine, type Logical, type Time as ChartTime,
  type CandlestickData, type LineData, type WhitespaceData,
} from "lightweight-charts";
import { useAccount, usePreference } from "./AccountProvider";
import { getKlines, type Candle } from "./lib/binance";
import { tradeApi, type PositionRow } from "./lib/tradeApi";
import { setCopiedPrice } from "./lib/priceClipboard";
import { priceScaleFormatter, minMoveFor } from "./lib/priceFormat";
import { intervalSeconds } from "./lib/analysisIndicators";
import { marketRealtime } from "./lib/realtime";
import { buildChartIndicators } from "./lib/chartIndicators";
import { mergeCandle, mergeTicker } from "./lib/candleMerge";
import { getCachedKlines, putCachedKlines } from "./lib/klineCache";
import { DEFAULT_INDICATORS, mergeIndicatorSettings, type IndicatorSettings } from "./lib/indicatorSettings";
import { createSupertrendBandView, type BandPoint, type BandFillConfig } from "./lib/supertrendBand";
import { createSupertrendLineView, type SupertrendLinePoint, type SupertrendLineConfig } from "./lib/supertrendLine";
import { createMacdHistogramView, type MacdBarPoint, type MacdHistogramConfig } from "./lib/macdHistogram";
import IndicatorSettingsPanel from "./IndicatorSettingsPanel";
import PositionToolOverlay from "./PositionToolOverlay";
import type { PositionDirection } from "./lib/positionTools";
import "./kline-chart.css";

const INTERVALS = ["3m", "5m", "15m", "1h", "4h", "1d"];
const VALID_INTERVALS = new Set(["1m", "3m", "5m", "15m", "30m", "1h", "2h", "4h", "1d"]);
const HISTORY_LIMIT = 300;
// 自适应高度比例：主图 70%，两个副图各 15%。
const PANE_STRETCH = { main: 70, sub: 15 };
const RIGHT_OFFSET = 5;

interface ChartPreference { interval: string; indicators?: unknown }
const defaultChartPreference: ChartPreference = { interval: "15m", indicators: DEFAULT_INDICATORS };
function validChartPreference(value: unknown): value is ChartPreference {
  return !!value && typeof value === "object" && typeof (value as ChartPreference).interval === "string"
    && VALID_INTERVALS.has((value as ChartPreference).interval);
}

const THEMES = {
  dark: { bg: "#212731", text: "#F0F0F4", grid: "rgba(240, 244, 250, 0.045)", zero: "#333B47", sep: "#5C6675", up: "#28A473", down: "#F63C55" },
  light: { bg: "#FFFFFF", text: "#181A20", grid: "rgba(24, 26, 32, 0.045)", zero: "#EAECEF", sep: "#B8BFC9", up: "#2EBD85", down: "#F6465D" },
};

// 十字线只在各序列上保留竖横参考线，不显示小圆点标记。
const NO_CROSSHAIR_MARKER = { crosshairMarkerVisible: false } as const;

type Time = ChartTime;
type LinePoint = LineData<Time> | WhitespaceData<Time>;
type CandlePoint = CandlestickData<Time> | WhitespaceData<Time>;
type BandDataPoint = BandPoint | WhitespaceData<Time>;
type MacdDataPoint = MacdBarPoint | WhitespaceData<Time>;
type StLineDataPoint = SupertrendLinePoint | WhitespaceData<Time>;

// 右轴价格标尺分档：<1 四位、1–99 三位、100–9999 两位、≥10000 一位。
// 右轴价格分档与 minMove 见 lib/priceFormat（tiny 价格需足小数位，否则刻度抹平）。
// 主图右轴为共享 scale，须所有主图系列统一 priceFormat，否则被默认 precision 覆盖。
const MAIN_PRICE_FORMAT = { type: "custom", formatter: priceScaleFormatter, minMove: 0.0001 } as const;
// 自定义系列默认按全量数据 autoscale 会把屏外极值算进价格域（跨周期出现大片空白）；
// 仅按可见范围参与主图价格域。
function visiblePriceScale(range: { min: number; max: number } | null) {
  return range ? { priceRange: { minValue: range.min, maxValue: range.max } } : null;
}
// iOS 式自动视图：按 bar 间距定可见根数（而非固定根数），跨周期蜡烛疏密一致。
const AUTO_BAR_SPACING = 7.6;
const AUTO_MIN_BARS = 10;
const AUTO_MAX_BARS = 164;

function linePoint(time: number, value: number | null): LinePoint {
  return value === null ? { time: time as Time } : { time: time as Time, value };
}

function lineData(times: number[], values: Array<number | null>): LinePoint[] {
  return times.map((time, index) => values[index] === null
    ? { time: time as Time }
    : { time: time as Time, value: values[index]! });
}

function applyPaneLayout(chart: IChartApi, settings: IndicatorSettings) {
  const panes = chart.panes();
  if (panes.length < 3) return;
  const enabledSubs = (settings.macd.enabled ? 1 : 0) + (settings.stoch.enabled ? 1 : 0);
  panes[0].setStretchFactor(100 - PANE_STRETCH.sub * enabledSubs);
  panes[1].setStretchFactor(settings.macd.enabled ? PANE_STRETCH.sub : 0);
  panes[2].setStretchFactor(settings.stoch.enabled ? PANE_STRETCH.sub : 0);
}

export default function KlineChart({ symbol, insightToggle, theme = "dark" }: {
  symbol: string;
  insightToggle?: ReactNode;
  theme?: "dark" | "light";
  onSymbolChange?: (symbol: string) => void;
}) {
  const { hydrating, user } = useAccount();
  const [preference, setPreference] = usePreference("chart", defaultChartPreference, validChartPreference);
  const selectedInterval = preference.interval;
  const settings = useMemo(() => mergeIndicatorSettings(preference.indicators), [preference.indicators]);
  const [showSettings, setShowSettings] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);
  const chartRef = useRef<IChartApi | null>(null);
  const bandRef = useRef<ISeriesApi<"Custom", Time, BandPoint | WhitespaceData<Time>> | null>(null);
  const bandConfigRef = useRef<BandFillConfig>({ fillUpColor: "#28A473", fillDownColor: "#F63C55", fillOpacity: 0.16 });
  const candleRef = useRef<ISeriesApi<"Candlestick"> | null>(null);
  const emaRefs = useRef<Array<ISeriesApi<"Line"> | null>>([null, null, null]);
  const stLineRef = useRef<ISeriesApi<"Custom", Time, StLineDataPoint> | null>(null);
  const stLineConfigRef = useRef<SupertrendLineConfig>({ upColor: "#28A473", downColor: "#F63C55", lineWidth: 1.3 });
  const macdHistRef = useRef<ISeriesApi<"Custom", Time, MacdDataPoint> | null>(null);
  const macdConfigRef = useRef<MacdHistogramConfig>({ upColor: "#28A473", downColor: "#F63C55", zeroColor: "#333B47" });
  const macdDifRef = useRef<ISeriesApi<"Line"> | null>(null);
  const macdDeaRef = useRef<ISeriesApi<"Line"> | null>(null);
  const stochKRef = useRef<ISeriesApi<"Line"> | null>(null);
  const stochDRef = useRef<ISeriesApi<"Line"> | null>(null);
  const candlesRef = useRef<Candle[]>([]);
  const paneLegendRefs = useRef<Array<HTMLDivElement | null>>([null, null]);
  const symbolRef = useRef<string | null>(null);
  const intervalRef = useRef<string>("15m");
  const loadingOlderRef = useRef(false);
  const hasMoreRef = useRef(true);
  const loadGenRef = useRef(0);
  const positionRef = useRef<PositionRow | null>(null);
  const posLineRefs = useRef<Map<string, IPriceLine>>(new Map());
  const posLabelRefs = useRef<Map<string, HTMLDivElement>>(new Map());
  const labelPriceRefs = useRef<Map<string, number>>(new Map());
  const labelLayerRef = useRef<HTMLDivElement | null>(null);
  const tpOrdersRef = useRef<Array<{ key: string; price: number }>>([]);
  const prevCloseRef = useRef<number | null>(null);
  const tickDirRef = useRef<1 | -1>(1);
  const loadOlderRef = useRef<() => Promise<void>>(async () => {});
  // 当前 candlesRef 归属的币种；切币未加载完成前置 null，禁止新币 tick 合并进旧币尾根。
  const candlesSymbolRef = useRef<string | null>(null);
  const themeRef = useRef(theme);
  const settingsRef = useRef(settings);
  const [status, setStatus] = useState<"loading" | "ready" | "error">("loading");
  const [crosshair, setCrosshair] = useState<{ x: number; y: number; price: number } | null>(null);
  const [attempt, setAttempt] = useState(0);
  const [refreshing, setRefreshing] = useState(false);
  const [viewMode, setViewMode] = useState<"auto" | "manual">("auto");
  const [clickMenu, setClickMenu] = useState<{ x: number; y: number; price: number | null } | null>(null);
  const [copied, setCopied] = useState(false);
  const [, setChartTick] = useState(0);
  const [mainPaneHeight, setMainPaneHeight] = useState(0);
  const [activePositionTool, setActivePositionTool] = useState<PositionDirection | null>(null);
  const viewModeRef = useRef<"auto" | "manual">("auto");
  const viewModeApplyRef = useRef<(mode: "auto" | "manual") => void>(() => {});

  useEffect(() => {
    setActivePositionTool(null);
  }, [symbol, selectedInterval]);

  const autoVisibleBars = () => {
    const width = containerRef.current?.clientWidth ?? 800;
    const plot = Math.max(120, width - 60);
    return Math.min(AUTO_MAX_BARS, Math.max(AUTO_MIN_BARS, Math.round(plot / AUTO_BAR_SPACING)));
  };

  // 自动视图：最新根落在视口 80% 处，右侧留 1/5 空白；跨度不变保持蜡烛密度。
  const autoRange = (length: number) => {
    const bars = autoVisibleBars();
    const last = length - 1;
    return { from: Math.max(0, last - bars * 0.8 + 0.5), to: last + bars * 0.2 - 0.5 };
  };

  // 持仓线：开仓／止损／现价浮盈亏／已挂止盈单；横线＋方框，方框定位左 1/6 处。
  const layoutPosLabels = useCallback(() => {
    const series = candleRef.current;
    const layer = labelLayerRef.current;
    const container = containerRef.current;
    if (!series || !layer || !container) return;
    const leftEdge = 8;
    const leftSixth = Math.round(container.clientWidth / 6);
    const strip = posLabelRefs.current.get("entry")?.offsetWidth || posLabelRefs.current.get("stop")?.offsetWidth || 64;
    // 三框整体再右移两个条宽；浮盈亏仍在开仓/止损右侧一个条宽。
    const base = leftEdge + strip * 2;
    const height = container.clientHeight;
    posLabelRefs.current.forEach((el, key) => {
      const price = labelPriceRefs.current.get(key);
      const y = price !== undefined ? series.priceToCoordinate(price) : null;
      if (y === null || y < 0 || y > height) { el.style.display = "none"; return; }
      el.style.display = "";
      el.style.left = key === "entry" || key === "stop" ? `${base}px` : key === "pnl" ? `${base + strip + 8}px` : `${leftSixth}px`;
      el.style.top = `${y}px`;
    });
  }, []);

  const syncPositionLines = useCallback((row: PositionRow | null, liveClose?: number) => {
    const series = candleRef.current;
    if (!series) return;
    const lines = posLineRefs.current;
    const labels = posLabelRefs.current;
    const layer = labelLayerRef.current;
    const desired = new Map<string, { price: number; text: string; color: string; style: LineStyle }>();
    if (row) {
      const entry = Number(row.open_price);
      const stop = Number(row.market_stop_price);
      const notional = Number(row.position_amount);
      if (Number.isFinite(entry) && entry > 0 && Number.isFinite(notional)) {
        const long = row.side === "0" || row.side === "long" || row.side === "BUY";
        const loss = Number.isFinite(stop) && stop > 0 ? notional * Math.abs(entry - stop) / entry : 0;
        const close = liveClose !== undefined && Number.isFinite(liveClose) ? liveClose : entry;
        const pnl = (close - entry) / entry * notional * (long ? 1 : -1);
        if (prevCloseRef.current !== null && close !== prevCloseRef.current) tickDirRef.current = close > prevCloseRef.current ? 1 : -1;
        prevCloseRef.current = close;
        const dirColor = tickDirRef.current === 1 ? "#28A473" : "#F63C55";
        desired.set("entry", { price: entry, text: `开仓 ${priceScaleFormatter(entry)}`, color: "#3179F5", style: LineStyle.Dashed });
        if (Number.isFinite(stop) && stop > 0) desired.set("stop", { price: stop, text: `止损 -${loss.toFixed(2)}U`, color: "#F63C55", style: LineStyle.Dashed });
        desired.set("pnl", { price: close, text: `${pnl >= 0 ? "浮盈" : "浮亏"} ${pnl >= 0 ? "+" : "-"}${Math.abs(pnl).toFixed(2)}U`, color: dirColor, style: LineStyle.Dotted });
        tpOrdersRef.current.forEach((tp, index) => {
          if (Number.isFinite(tp.price) && tp.price > 0) desired.set(tp.key, { price: tp.price, text: `止盈${tpOrdersRef.current.length > 1 ? ` L${index + 1}` : ""} ${priceScaleFormatter(tp.price)}`, color: "#28A473", style: LineStyle.Dashed });
        });
      }
    }
    for (const [key, line] of [...lines.entries()]) {
      if (!desired.has(key)) { series.removePriceLine(line); lines.delete(key); }
    }
    for (const [key, el] of [...labels.entries()]) {
      if (!desired.has(key)) { el.remove(); labels.delete(key); labelPriceRefs.current.delete(key); }
    }
    desired.forEach((spec, key) => {
      labelPriceRefs.current.set(key, spec.price);
      const existing = lines.get(key);
      if (existing) existing.applyOptions({ price: spec.price, color: spec.color, lineStyle: spec.style, axisLabelVisible: false });
      else lines.set(key, series.createPriceLine({ price: spec.price, color: spec.color, lineWidth: 1, lineStyle: spec.style, axisLabelVisible: false, lineVisible: true }));
      let el = labels.get(key);
      if (!el && layer) {
        el = document.createElement("div");
        el.className = "pos-label";
        layer.appendChild(el);
        labels.set(key, el);
      }
      if (el) {
        el.textContent = spec.text;
        el.style.background = spec.color;
      }
    });
    layoutPosLabels();
  }, [layoutPosLabels]);

  useEffect(() => {
    let active = true;
    const loadPos = () => Promise.all([
      tradeApi.positions(),
      tradeApi.orders(1).catch(() => ({ items: [] as Array<{ id: number; symbol: string; kind: string; price: number | string; can_cancel: boolean }> })),
    ]).then(([rows, orders]) => {
      if (!active) return;
      const row = rows.find((item) => item.symbol === symbol) ?? null;
      positionRef.current = row;
      tpOrdersRef.current = (orders.items ?? [])
        .filter((order) => order.symbol === symbol && order.kind.endsWith("take_profit") && order.can_cancel)
        .map((order) => ({ key: `tp-${order.id}`, price: Number(order.price) }));
      syncPositionLines(row, candlesRef.current[candlesRef.current.length - 1]?.close);
    }).catch(() => undefined);
    void loadPos();
    const timer = window.setInterval(loadPos, 5000);
    return () => {
      active = false;
      window.clearInterval(timer);
      positionRef.current = null;
      syncPositionLines(null);
    };
  }, [symbol, syncPositionLines]);

  const renderData = useCallback((candles: Candle[], resetView: boolean, tail = false, preserveView = false) => {
    const chart = chartRef.current;
    if (!chart || !candleRef.current || !candles.length) return;
    const t = THEMES[themeRef.current];
    const config = settingsRef.current;
    const indicators = buildChartIndicators(candles, config);
    const times = indicators.times;
    const last = candles.length - 1;
    const emaValues = [indicators.ema21, indicators.ema55, indicators.ema144];
    const stLinePoint = (index: number): StLineDataPoint => {
      const point = indicators.supertrend[index];
      return point.value === null ? { time: times[index] as Time } : { time: times[index] as Time, value: point.value, direction: point.direction ?? 1 };
    };
    const bandPoint = (index: number): BandDataPoint => {
      const point = indicators.supertrend[index];
      // 对齐用户 Pine：fill(趋势线, src=hl2)，填充锚为 hl2 中价而非 close。
      const mid = (candles[index].high + candles[index].low) / 2;
      return point.value === null ? { time: times[index] as Time } : { time: times[index] as Time, close: mid, st: point.value, direction: point.direction ?? 1 };
    };
    const macdPoint = (index: number): MacdDataPoint => {
      const histogram = indicators.macd[index].histogram;
      return histogram === null ? { time: times[index] as Time } : { time: times[index] as Time, value: histogram };
    };
    if (!tail) {
      // tiny 价格（如 0.0000123）须按量级放宽 minMove，否则右轴刻度全舍入为 0＝无价格。
      const mainFormat = { ...MAIN_PRICE_FORMAT, minMove: minMoveFor(candles[last].close) };
      candleRef.current.applyOptions({ priceFormat: mainFormat });
      emaRefs.current.forEach((series) => series?.applyOptions({ priceFormat: mainFormat }));
      stLineRef.current?.applyOptions({ priceFormat: mainFormat });
      bandRef.current?.applyOptions({ priceFormat: mainFormat });
    }
    if (tail) {
      // 实时 tick 只更新尾根，避免每 tick 全量 setData 重建全部系列。
      const candle = candles[last];
      candleRef.current.update({ time: candle.time as Time, open: candle.open, high: candle.high, low: candle.low, close: candle.close });
      emaRefs.current.forEach((series, index) => series?.update(linePoint(times[last], emaValues[index][last])));
      stLineRef.current?.update(stLinePoint(last));
      bandRef.current?.update(bandPoint(last));
      macdHistRef.current?.update(macdPoint(last));
      macdDifRef.current?.update(linePoint(times[last], indicators.macd[last].dif));
      macdDeaRef.current?.update(linePoint(times[last], indicators.macd[last].dea));
      stochKRef.current?.update(linePoint(times[last], indicators.stoch[last].k));
      stochDRef.current?.update(linePoint(times[last], indicators.stoch[last].d));
      if (prevCloseRef.current === null) prevCloseRef.current = candles[last - 1]?.close ?? null;
      syncPositionLines(positionRef.current, candle.close);
      setChartTick((t) => t + 1);
      return;
    }
    candleRef.current.setData(candles.map((candle): CandlePoint => ({
      time: candle.time as Time, open: candle.open, high: candle.high, low: candle.low, close: candle.close,
    })));
    emaRefs.current.forEach((series, index) => {
      series?.setData(lineData(times, emaValues[index]));
      series?.applyOptions({ color: config.ema.colors[index], visible: config.ema.enabled });
    });
    stLineConfigRef.current.upColor = config.supertrend.upColor;
    stLineConfigRef.current.downColor = config.supertrend.downColor;
    stLineRef.current?.setData(times.map((_, index) => stLinePoint(index)));
    stLineRef.current?.applyOptions({ visible: config.supertrend.enabled });
    bandConfigRef.current.fillUpColor = config.supertrend.fillUpColor;
    bandConfigRef.current.fillDownColor = config.supertrend.fillDownColor;
    bandConfigRef.current.fillOpacity = config.supertrend.fillOpacity;
    bandRef.current?.setData(times.map((_, index) => bandPoint(index)));
    bandRef.current?.applyOptions({ visible: config.supertrend.enabled });
    macdConfigRef.current.upColor = config.macd.upColor;
    macdConfigRef.current.downColor = config.macd.downColor;
    macdConfigRef.current.zeroColor = t.zero;
    macdHistRef.current?.setData(times.map((_, index) => macdPoint(index)));
    macdDifRef.current?.setData(lineData(times, indicators.macd.map((point) => point.dif)));
    macdDeaRef.current?.setData(lineData(times, indicators.macd.map((point) => point.dea)));
    macdDifRef.current?.applyOptions({ color: config.macd.difColor, visible: config.macd.enabled });
    macdDeaRef.current?.applyOptions({ color: config.macd.deaColor, visible: config.macd.enabled });
    macdHistRef.current?.applyOptions({ visible: config.macd.enabled });
    stochKRef.current?.setData(lineData(times, indicators.stoch.map((point) => point.k)));
    stochDRef.current?.setData(lineData(times, indicators.stoch.map((point) => point.d)));
    stochKRef.current?.applyOptions({ color: config.stoch.kColor, visible: config.stoch.enabled });
    stochDRef.current?.applyOptions({ color: config.stoch.dColor, visible: config.stoch.enabled });
    if (prevCloseRef.current === null) prevCloseRef.current = candles[last - 1]?.close ?? null;
    syncPositionLines(positionRef.current, candles[last].close);
    applyPaneLayout(chart, config);
    setMainPaneHeight(chart.panes()[0]?.getHeight() ?? 0);
    requestAnimationFrame(() => { if (chartRef.current === chart) setMainPaneHeight(chart.panes()[0]?.getHeight() ?? 0); });
    // TradingView 式附图图例：名称＋参数固定 pane 左上角，禁用时隐藏。
    const panes = chart.panes();
    const legendSpecs = [
      { pane: panes[1], enabled: config.macd.enabled, text: `MACD(${config.macd.fast},${config.macd.slow},${config.macd.signal})` },
      { pane: panes[2], enabled: config.stoch.enabled, text: `StochRSI(${config.stoch.rsi},${config.stoch.stoch},${config.stoch.k},${config.stoch.d})` },
    ];
    legendSpecs.forEach((spec, index) => {
      // getHTMLElement 返回 tr，不能挂绝对定位子节点；取 pane 画布的 relative 容器。
      const host = spec.pane?.getHTMLElement()?.querySelector("canvas")?.parentElement ?? null;
      if (!host) return;
      let legend = paneLegendRefs.current[index];
      if (!legend || legend.parentElement !== host) {
        legend = document.createElement("div");
        legend.className = "pane-legend";
        host.appendChild(legend);
        paneLegendRefs.current[index] = legend;
      }
      legend.textContent = spec.text;
      legend.style.display = spec.enabled ? "" : "none";
    });
    if (resetView || (viewModeRef.current === "auto" && !preserveView)) {
      chart.timeScale().setVisibleLogicalRange(autoRange(candles.length));
    }
  }, []);

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    const t = THEMES[theme];
    const chart = createChart(container, {
      autoSize: true,
      layout: {
        background: { type: ColorType.Solid, color: t.bg },
        textColor: t.text,
        panes: { separatorColor: t.sep, separatorHoverColor: "rgba(155,155,170,0.35)", enableResize: true },
      },
      grid: { vertLines: { color: t.grid }, horzLines: { color: t.grid } },
      rightPriceScale: { borderVisible: false },
      timeScale: { borderVisible: false, timeVisible: true, secondsVisible: false, rightOffset: RIGHT_OFFSET, minBarSpacing: 0.5 },
      crosshair: { mode: CrosshairMode.Normal, vertLine: { visible: false, labelVisible: false }, horzLine: { visible: false, labelVisible: false } },
      localization: { locale: "zh-CN" },
    });
    chartRef.current = chart;
    if (import.meta.env.DEV) (window as unknown as { __chart?: IChartApi }).__chart = chart;
    const labelLayer = document.createElement("div");
    labelLayer.className = "pos-label-layer";
    container.appendChild(labelLayer);
    labelLayerRef.current = labelLayer;
    // 自定义系列绘制时读实时可见范围，避免陈旧 visibleRange 造成左拖堆积／右侧缺柱。
    const liveRange = () => chartRef.current?.timeScale().getVisibleLogicalRange() ?? null;
    bandConfigRef.current.visibleRange = liveRange;
    macdConfigRef.current.visibleRange = liveRange;
    stLineConfigRef.current.visibleRange = liveRange;
    const bandView = createSupertrendBandView(bandConfigRef.current);
    bandRef.current = chart.addCustomSeries(bandView.view, { priceLineVisible: false, lastValueVisible: false, ...NO_CROSSHAIR_MARKER, priceFormat: MAIN_PRICE_FORMAT, autoscaleInfoProvider: () => visiblePriceScale(bandView.visiblePriceRange()) }, 0);
    candleRef.current = chart.addSeries(CandlestickSeries, {
      upColor: t.up, downColor: t.down, borderVisible: false, wickUpColor: t.up, wickDownColor: t.down, ...NO_CROSSHAIR_MARKER,
      priceFormat: MAIN_PRICE_FORMAT,
    });
    emaRefs.current = [0, 1, 2].map(() => chart.addSeries(LineSeries, { lineWidth: 1, priceLineVisible: false, lastValueVisible: false, ...NO_CROSSHAIR_MARKER, priceFormat: MAIN_PRICE_FORMAT }));
    const stLineView = createSupertrendLineView(stLineConfigRef.current);
    stLineRef.current = chart.addCustomSeries(stLineView.view, { priceLineVisible: false, lastValueVisible: false, ...NO_CROSSHAIR_MARKER, priceFormat: MAIN_PRICE_FORMAT, autoscaleInfoProvider: () => visiblePriceScale(stLineView.visiblePriceRange()) }, 0);
    macdHistRef.current = chart.addCustomSeries(createMacdHistogramView(macdConfigRef.current), { priceLineVisible: false, lastValueVisible: false, ...NO_CROSSHAIR_MARKER }, 1);
    // 慢线先加、快线后加：DIF 压在 DEA 之上（后加者绘制在上）。
    macdDeaRef.current = chart.addSeries(LineSeries, { lineWidth: 1, priceLineVisible: false, lastValueVisible: false, ...NO_CROSSHAIR_MARKER }, 1);
    macdDifRef.current = chart.addSeries(LineSeries, { lineWidth: 1, priceLineVisible: false, lastValueVisible: false, ...NO_CROSSHAIR_MARKER }, 1);
    const fixedRange = { autoscaleInfoProvider: () => ({ priceRange: { minValue: 0, maxValue: 100 } }) };
    // D 先加、K 后加：绿 K 压在紫 D 之上。
    stochDRef.current = chart.addSeries(LineSeries, { lineWidth: 1, priceLineVisible: false, lastValueVisible: false, ...fixedRange, ...NO_CROSSHAIR_MARKER }, 2);
    stochKRef.current = chart.addSeries(LineSeries, { lineWidth: 1, priceLineVisible: false, lastValueVisible: false, ...fixedRange, ...NO_CROSSHAIR_MARKER }, 2);
    const resizeObserver = new ResizeObserver(() => {
      if (!chartRef.current) return;
      applyPaneLayout(chartRef.current, settingsRef.current);
      setMainPaneHeight(chartRef.current.panes()[0]?.getHeight() ?? 0);
      if (viewModeRef.current === "auto" && candlesRef.current.length) {
        chartRef.current.timeScale().setVisibleLogicalRange(autoRange(candlesRef.current.length));
      }
      layoutPosLabels();
      setChartTick((t) => t + 1);
    });
    resizeObserver.observe(container);
    // 自动：左右拖动＋滚轮缩放可用，上下（价格轴／触摸竖向）锁定；手动：全向。
    const applyViewMode = (mode: "auto" | "manual") => {
      chart.applyOptions({
        handleScroll: { mouseWheel: true, pressedMouseMove: true, horzTouchDrag: true, vertTouchDrag: mode === "manual" },
        handleScale: { mouseWheel: true, pinch: true, axisPressedMouseMove: true, axisDoubleClickReset: true },
      });
    };
    applyViewMode("auto");
    viewModeApplyRef.current = applyViewMode;
    // 手动模式左键拖图面＝全向平移不缩放；右侧价格标尺区域留给轴拖拽缩放。
    let vdrag: { startY: number; from: number; to: number } | null = null;
    const onPointerDown = (event: PointerEvent) => {
      if ((event.target as HTMLElement).closest(".kline-click-menu")) return;
      setClickMenu(null);
      if (viewModeRef.current !== "manual" || event.button !== 0) return;
      const rect = container.getBoundingClientRect();
      const axisWidth = chart.priceScale("right", 0).width();
      if (event.clientX - rect.left > rect.width - axisWidth) return;
      const scale = chart.priceScale("right", 0);
      const range = scale.getVisibleRange();
      if (!range) return;
      scale.setAutoScale(false);
      vdrag = { startY: event.clientY, from: range.from, to: range.to };
    };
    const onPointerMove = (event: PointerEvent) => {
      if (!vdrag) return;
      const height = chart.panes()[0]?.getHeight() ?? 1;
      const perPixel = (vdrag.to - vdrag.from) / Math.max(1, height);
      const shift = (event.clientY - vdrag.startY) * perPixel;
      chart.priceScale("right", 0).setVisibleRange({ from: vdrag.from + shift, to: vdrag.to + shift });
    };
    const onPointerUp = () => {
      vdrag = null;
    };
    // 右键自定义菜单（屏蔽浏览器原生"图片另存为/检查"）；左键不触发。
    const onContextMenu = (event: MouseEvent) => {
      event.preventDefault();
      const rect = container.getBoundingClientRect();
      // 复制语义＝鼠标所处横线价格，非最新市价。
      const pRaw = candleRef.current?.coordinateToPrice(event.clientY - rect.top) ?? null;
      setCopied(false);
      setClickMenu({
        x: Math.min(Math.max(8, event.clientX - rect.left), Math.max(8, rect.width - 130)),
        y: Math.min(Math.max(8, event.clientY - rect.top), Math.max(8, rect.height - 76)),
        price: pRaw === null ? null : Number(pRaw),
      });
    };
    container.addEventListener("pointerdown", onPointerDown);
    container.addEventListener("pointermove", onPointerMove);
    container.addEventListener("contextmenu", onContextMenu);
    window.addEventListener("pointerup", onPointerUp);
    const onRange = (range: { from: number; to: number } | null) => {
      if (range && range.from < 24) void loadOlderRef.current();
      layoutPosLabels();
      setChartTick((t) => t + 1);
    };
    chart.timeScale().subscribeVisibleLogicalRangeChange(onRange);
    // 自绘十字线：round 取整＝越过两根中轴线中点即跳下一根（库 ceil 需到中心才跳）。
    const onCrosshairMove = (event: MouseEvent) => {
      const api = chartRef.current;
      const candle = candleRef.current;
      if (!api || !candle) return;
      const rect = container.getBoundingClientRect();
      const x = event.clientX - rect.left;
      const y = event.clientY - rect.top;
      const mainHeight = api.panes()[0]?.getHeight() ?? 0;
      if (y > mainHeight || x < 0 || x > rect.width) { setCrosshair(null); return; }
      const ts = api.timeScale();
      const logical = ts.coordinateToLogical(x);
      if (logical === null) { setCrosshair(null); return; }
      const barX = ts.logicalToCoordinate(Math.round(logical) as Logical);
      const price = candle.coordinateToPrice(y);
      if (barX === null || price === null) { setCrosshair(null); return; }
      setCrosshair({ x: barX, y, price });
    };
    const onCrosshairLeave = () => setCrosshair(null);
    container.addEventListener("mousemove", onCrosshairMove);
    container.addEventListener("mouseleave", onCrosshairLeave);
    return () => {
      container.removeEventListener("mousemove", onCrosshairMove);
      container.removeEventListener("mouseleave", onCrosshairLeave);
      container.removeEventListener("pointerdown", onPointerDown);
      container.removeEventListener("pointermove", onPointerMove);
      container.removeEventListener("contextmenu", onContextMenu);
      window.removeEventListener("pointerup", onPointerUp);
      chart.timeScale().unsubscribeVisibleLogicalRangeChange(onRange);
      resizeObserver.disconnect();
      chart.remove();
      chartRef.current = null;
      bandRef.current = null;
      candleRef.current = null;
      emaRefs.current = [null, null, null];
      stLineRef.current = null;
      paneLegendRefs.current = [null, null];
      posLineRefs.current = new Map();
      posLabelRefs.current.forEach((el) => el.remove());
      posLabelRefs.current = new Map();
      labelPriceRefs.current = new Map();
      labelLayerRef.current?.remove();
      labelLayerRef.current = null;
      macdHistRef.current = macdDifRef.current = macdDeaRef.current = null;
      stochKRef.current = stochDRef.current = null;
    };
  }, []);

  useEffect(() => {
    themeRef.current = theme;
    const chart = chartRef.current;
    if (!chart) return;
    const t = THEMES[theme];
    chart.applyOptions({
      layout: { background: { type: ColorType.Solid, color: t.bg }, textColor: t.text, panes: { separatorColor: t.sep } },
      grid: { vertLines: { color: t.grid }, horzLines: { color: t.grid } },
    });
    candleRef.current?.applyOptions({ upColor: t.up, downColor: t.down, wickUpColor: t.up, wickDownColor: t.down });
    if (candlesRef.current.length) renderData(candlesRef.current, false);
  }, [theme, renderData]);

  useEffect(() => {
    settingsRef.current = settings;
    if (candlesRef.current.length) renderData(candlesRef.current, false);
  }, [settings, renderData]);

  useEffect(() => {
    if (hydrating || !chartRef.current) return;
    let active = true;
    symbolRef.current = symbol;
    intervalRef.current = selectedInterval;
    hasMoreRef.current = true;
    loadingOlderRef.current = false;
    loadGenRef.current += 1;
    prevCloseRef.current = null;
    tickDirRef.current = 1;
    // 切币必须恢复价格轴 autoScale：手动竖向拖动/轴缩放会冻结旧币价格窗，
    // 不恢复则新币蜡烛落在窗外＝"切换后空白"，点自动才出来。
    chartRef.current.panes().forEach((_, index) => chartRef.current?.priceScale("right", index).applyOptions({ autoScale: true }));
    const controller = new AbortController();
    const cached = getCachedKlines(symbol, selectedInterval);
    candlesSymbolRef.current = null;
    if (cached && cached.length) {
      candlesRef.current = cached;
      candlesSymbolRef.current = symbol;
      viewModeRef.current = "auto";
      setViewMode("auto");
      renderData(cached, true);
      setStatus("ready");
    } else {
      setStatus("loading");
    }
    let retryTimer: ReturnType<typeof setTimeout> | undefined;
    const fetchHistory = (attemptNo: number) => {
      // 后端同步线程队列可能挂起请求：每 attempt 12s 超时，超时/瞬断均退避重试保留蒙层。
      let guardTimer: ReturnType<typeof setTimeout> | undefined;
      const guard = new Promise<never>((_, reject) => { guardTimer = setTimeout(() => reject(new Error("kline-attempt-timeout")), 12000); });
      Promise.race([getKlines(symbol, selectedInterval, HISTORY_LIMIT, controller.signal), guard]).then((candles) => {
        if (guardTimer) clearTimeout(guardTimer);
        if (!active) return;
        if (!candles.length) {
          // 冷币首请求后端可能先回空表＋historyPending（异步修复）：保留蒙层退避重试，不渲染空、不缓存空。
          if (attemptNo < 6) retryTimer = setTimeout(() => fetchHistory(attemptNo + 1), 1200 * (attemptNo + 1));
          else setStatus("error");
          return;
        }
        putCachedKlines(symbol, selectedInterval, candles);
        candlesRef.current = candles;
        candlesSymbolRef.current = symbol;
        if (!cached) {
          viewModeRef.current = "auto";
          setViewMode("auto");
        }
        renderData(candles, !cached);
        setStatus("ready");
        // 首屏 autoSize／面板比例稳定后强制重绘一次，消除自定义系列首屏残影。
        requestAnimationFrame(() => { if (active) renderData(candlesRef.current, false); });
      }).catch((error: unknown) => {
        if (guardTimer) clearTimeout(guardTimer);
        if (!active) return;
        if (error instanceof DOMException && error.name === "AbortError") return;
        if (attemptNo < 6) retryTimer = setTimeout(() => fetchHistory(attemptNo + 1), 1200 * (attemptNo + 1));
        else setStatus("error");
      });
    };
    fetchHistory(0);
    let tickPending = false;
    const scheduleTail = () => {
      if (tickPending) return;
      tickPending = true;
      window.setTimeout(() => {
        tickPending = false;
        if (active && candlesSymbolRef.current === symbol && candlesRef.current.length) renderData(candlesRef.current, false, true);
      }, 120);
    };
    const unsubscribe = marketRealtime.subscribe({ symbol, interval: selectedInterval, handler: (event) => {
      if (!active || candlesSymbolRef.current !== symbol) return;
      if (event.type === "kline") {
        const width = intervalSeconds[selectedInterval] ?? 60;
        const incoming = event.candle;
        if (selectedInterval === "1m") {
          candlesRef.current = mergeCandle(candlesRef.current, incoming);
        } else {
          // 后端仅推 1m 实时 K 线；大周期客户端聚合到对应桶，保证尾根实时且带影线。
          const bucket = Math.floor(incoming.time / width) * width;
          const list = candlesRef.current;
          const last = list[list.length - 1];
          if (last && last.time === bucket) {
            // forming 1m 不重复累加成交量：仅收盘 1m 计入桶成交量。
            candlesRef.current = [...list.slice(0, -1), { ...last, high: Math.max(last.high, incoming.high), low: Math.min(last.low, incoming.low), close: incoming.close, volume: event.closed ? last.volume + incoming.volume : last.volume }];
          } else if (!last || bucket > last.time) {
            candlesRef.current = [...list, { time: bucket, open: incoming.open, high: incoming.high, low: incoming.low, close: incoming.close, volume: incoming.volume }].slice(-1500);
          }
        }
        scheduleTail();
      } else if (event.type === "ticker") {
        const width = intervalSeconds[selectedInterval] ?? 60;
        const ts = event.eventTime && event.eventTime > 0 ? event.eventTime : Date.now();
        const bucket = Math.floor(ts / 1000 / width) * width;
        const next = mergeTicker(candlesRef.current, event.price, bucket);
        if (next !== candlesRef.current) {
          candlesRef.current = next;
          scheduleTail();
        }
      }
    } });
    return () => { active = false; controller.abort(); unsubscribe(); if (retryTimer) clearTimeout(retryTimer); };
  }, [hydrating, symbol, selectedInterval, attempt, renderData]);

  // 向左滚到历史边缘时补载更早 K 线（beforeOpenTime 分页），视口保持不跳。
  const loadOlder = useCallback(async () => {
    const chart = chartRef.current;
    const symbol = symbolRef.current;
    if (!chart || !symbol || loadingOlderRef.current || !hasMoreRef.current) return;
    const current = candlesRef.current;
    if (!current.length || current.length >= 3000) { hasMoreRef.current = false; return; }
    const gen = loadGenRef.current;
    loadingOlderRef.current = true;
    try {
      const older = await getKlines(symbol, intervalRef.current, 300, undefined, current[0].time * 1000);
      // 切币/切周期/刷新会推进世代：跨世代补载必须丢弃，否则旧币历史混入新币并污染缓存。
      if (gen !== loadGenRef.current || symbolRef.current !== symbol) return;
      const fresh = older.filter((candle) => candle.time < current[0].time);
      if (older.length < 300) hasMoreRef.current = false;
      if (!fresh.length) return;
      const prev = chart.timeScale().getVisibleLogicalRange();
      const merged = [...fresh, ...candlesRef.current];
      candlesRef.current = merged;
      putCachedKlines(symbol, intervalRef.current, merged);
      renderData(merged, false, false, true);
      if (prev) chart.timeScale().setVisibleLogicalRange({ from: prev.from + fresh.length, to: prev.to + fresh.length });
    } catch { /* 保留现有历史，下次滚动再试 */ }
    finally { loadingOlderRef.current = false; }
  }, [renderData]);
  loadOlderRef.current = loadOlder;

  function resetView() {
    viewModeRef.current = "auto";
    setViewMode("auto");
    const chart = chartRef.current;
    const length = candlesRef.current.length;
    if (!chart || !length) return;
    // 手动期的价格轴缩放一并复位：恢复各 pane 自动价格域。
    chart.panes().forEach((_, index) => chart.priceScale("right", index).applyOptions({ autoScale: true }));
    chart.timeScale().setVisibleLogicalRange(autoRange(length));
  }

  async function copyCurrentPrice() {
    const price = clickMenu?.price ?? candlesRef.current[candlesRef.current.length - 1]?.close;
    if (price === undefined || price === null) return;
    const text = priceScaleFormatter(price);
    setCopiedPrice(text);
    let ok = false;
    if (navigator.clipboard) {
      try { await navigator.clipboard.writeText(text); ok = true; } catch { /* fall through to legacy copy */ }
    }
    if (!ok) {
      const ta = document.createElement("textarea");
      ta.value = text;
      document.body.appendChild(ta);
      ta.select();
      ok = document.execCommand("copy");
      ta.remove();
    }
    setCopied(ok);
  }

  async function refreshChart() {
    if (refreshing) return;
    setRefreshing(true);
    loadGenRef.current += 1;
    try {
      const candles = await getKlines(symbol, selectedInterval, HISTORY_LIMIT);
      if (!candles.length) { setStatus("error"); return; }
      putCachedKlines(symbol, selectedInterval, candles);
      candlesRef.current = candles;
      candlesSymbolRef.current = symbol;
      renderData(candles, true);
      // 刷新＝完整重置：模式回自动、价格轴 autoScale、视口回自动留白。
      resetView();
      setStatus("ready");
    } catch {
      setStatus("error");
    } finally {
      setRefreshing(false);
    }
  }

  return (
    <>
      <div className="chart-toolbar">
        <div className="toolbar-left">
          {INTERVALS.map((interval) => (
            <button key={interval} type="button" className={`timeframe ${selectedInterval === interval ? "active" : ""}`} onClick={() => setPreference({ ...preference, interval })}>
              {interval === "1d" ? "1D" : interval.toUpperCase()}
            </button>
          ))}
          <span className="divider" aria-hidden="true" />
          <button type="button" className={`position-tool-trigger long ${activePositionTool === "long" ? "is-active" : ""}`} aria-label="多头测量" title="多头测量" aria-pressed={activePositionTool === "long"} disabled={status !== "ready"} onClick={() => setActivePositionTool((current) => current === "long" ? null : "long")}><TrendingUp size={15} /></button>
          <button type="button" className={`position-tool-trigger short ${activePositionTool === "short" ? "is-active" : ""}`} aria-label="空头测量" title="空头测量" aria-pressed={activePositionTool === "short"} disabled={status !== "ready"} onClick={() => setActivePositionTool((current) => current === "short" ? null : "short")}><TrendingDown size={15} /></button>
        </div>
        <div className="toolbar-right">
          <button type="button" className="chart-refresh" aria-label="刷新 K 线" title="刷新 K 线" disabled={refreshing} onClick={() => void refreshChart()}><RefreshCw size={14} className={refreshing ? "spin" : ""} /></button>
          <div className="view-mode" role="group" aria-label="缩放模式">
            <button type="button" className={viewMode === "auto" ? "active" : ""} aria-pressed={viewMode === "auto"} onClick={() => { viewModeApplyRef.current("auto"); resetView(); }}>自动</button>
            <button type="button" className={viewMode === "manual" ? "active" : ""} aria-pressed={viewMode === "manual"} onClick={() => { viewModeRef.current = "manual"; setViewMode("manual"); viewModeApplyRef.current("manual"); }}>手动</button>
          </div>
          <button type="button" className="indicator-master" aria-label="指标设置" title="指标设置" aria-expanded={showSettings} onClick={() => setShowSettings(true)}>
            <SlidersHorizontal size={15} /> 指标
          </button>
          {insightToggle}
        </div>
      </div>
      <div className="kline-stage" data-chart-theme={theme} style={{ "--position-tool-main-height": mainPaneHeight > 0 ? `${mainPaneHeight}px` : "100%" } as CSSProperties}>
        {status === "loading" && <div className="kline-loading" role="status" aria-label="K 线加载中"><span className="kline-bars" aria-hidden="true"><i /><i /><i /><i /></span></div>}
        {status === "error" && <div className="chart-widget-notice chart-widget-error"><p role="status">K 线加载失败</p><button className="chart-restore" type="button" onClick={() => setAttempt((previous) => previous + 1)}>重试</button></div>}
        <div ref={containerRef} className="kline-container">
          {clickMenu && <div className="kline-click-menu" style={{ left: clickMenu.x, top: clickMenu.y }}>
            <button type="button" onClick={() => { setClickMenu(null); void refreshChart(); }}>刷新</button>
            <button type="button" onClick={() => void copyCurrentPrice()}>{copied ? "已复制" : "复制当前价格"}</button>
          </div>}
        </div>
        {status === "ready" && <PositionToolOverlay currentPrice={candlesRef.current[candlesRef.current.length - 1]?.close ?? 0} readOnly={false} activeTool={activePositionTool} onActiveToolChange={setActivePositionTool} />}
        {crosshair && (() => {
          const base = candlesRef.current[candlesRef.current.length - 1]?.close ?? crosshair.price;
          const pct = base > 0 ? (crosshair.price - base) / base * 100 : 0;
          const up = pct >= 0;
          return <>
            <div className="kline-crosshair-v" style={{ left: crosshair.x }} />
            <div className="kline-crosshair-h" style={{ top: crosshair.y }} />
            <div className="kline-crosshair-tag" style={{ top: crosshair.y }}>
              <span>{priceScaleFormatter(crosshair.price)}</span>
              <span className={up ? "up" : "down"}>{up ? "+" : "-"}{Math.abs(pct).toFixed(2)}%</span>
            </div>
          </>;
        })()}
      </div>
      {showSettings && <IndicatorSettingsPanel settings={settings} onChange={(next) => setPreference({ ...preference, indicators: next })} onClose={() => setShowSettings(false)} />}
    </>
  );
}
