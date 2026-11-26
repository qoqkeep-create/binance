import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { ReactNode } from "react";
import { SlidersHorizontal } from "lucide-react";
import {
  createChart, ColorType, CrosshairMode,
  CandlestickSeries, LineSeries,
  type IChartApi, type ISeriesApi, type Time as ChartTime,
  type CandlestickData, type LineData, type WhitespaceData,
} from "lightweight-charts";
import { useAccount, usePreference } from "./AccountProvider";
import { BinanceStream, getKlines, type Candle } from "./lib/binance";
import { buildChartIndicators } from "./lib/chartIndicators";
import { mergeCandle, mergeTicker } from "./lib/candleMerge";
import { getCachedKlines, putCachedKlines } from "./lib/klineCache";
import { DEFAULT_INDICATORS, mergeIndicatorSettings, type IndicatorSettings } from "./lib/indicatorSettings";
import { createSupertrendBandView, type BandPoint, type BandFillConfig } from "./lib/supertrendBand";
import { createSupertrendLineView, type SupertrendLinePoint, type SupertrendLineConfig } from "./lib/supertrendLine";
import { createMacdHistogramView, type MacdBarPoint, type MacdHistogramConfig } from "./lib/macdHistogram";
import IndicatorSettingsPanel from "./IndicatorSettingsPanel";
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
function priceScaleFormatter(price: number) {
  const abs = Math.abs(price);
  const digits = abs < 1 ? 4 : abs < 100 ? 3 : abs < 10000 ? 2 : 1;
  return price.toFixed(digits);
}
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
  const { hydrating } = useAccount();
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
  // 当前 candlesRef 归属的币种；切币未加载完成前置 null，禁止新币 tick 合并进旧币尾根。
  const candlesSymbolRef = useRef<string | null>(null);
  const themeRef = useRef(theme);
  const settingsRef = useRef(settings);
  const [status, setStatus] = useState<"loading" | "ready" | "error">("loading");
  const [crosshair, setCrosshair] = useState<{ y: number; price: number } | null>(null);
  const [attempt, setAttempt] = useState(0);
  const [viewMode, setViewMode] = useState<"auto" | "manual">("auto");
  const viewModeRef = useRef<"auto" | "manual">("auto");
  const viewModeApplyRef = useRef<(mode: "auto" | "manual") => void>(() => {});

  const autoVisibleBars = () => {
    const width = containerRef.current?.clientWidth ?? 800;
    const plot = Math.max(120, width - 60);
    return Math.min(AUTO_MAX_BARS, Math.max(AUTO_MIN_BARS, Math.round(plot / AUTO_BAR_SPACING)));
  };

  const renderData = useCallback((candles: Candle[], resetView: boolean, tail = false) => {
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
    applyPaneLayout(chart, config);
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
    if (resetView || viewModeRef.current === "auto") {
      chart.timeScale().setVisibleLogicalRange({ from: Math.max(0, candles.length - autoVisibleBars()), to: candles.length - 1 });
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
      crosshair: { mode: CrosshairMode.Normal, horzLine: { labelVisible: false } },
      localization: { locale: "zh-CN" },
    });
    chartRef.current = chart;
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
    macdDifRef.current = chart.addSeries(LineSeries, { lineWidth: 1, priceLineVisible: false, lastValueVisible: false, ...NO_CROSSHAIR_MARKER }, 1);
    macdDeaRef.current = chart.addSeries(LineSeries, { lineWidth: 1, priceLineVisible: false, lastValueVisible: false, ...NO_CROSSHAIR_MARKER }, 1);
    const fixedRange = { autoscaleInfoProvider: () => ({ priceRange: { minValue: 0, maxValue: 100 } }) };
    stochKRef.current = chart.addSeries(LineSeries, { lineWidth: 1, priceLineVisible: false, lastValueVisible: false, ...fixedRange, ...NO_CROSSHAIR_MARKER }, 2);
    stochDRef.current = chart.addSeries(LineSeries, { lineWidth: 1, priceLineVisible: false, lastValueVisible: false, ...fixedRange, ...NO_CROSSHAIR_MARKER }, 2);
    const resizeObserver = new ResizeObserver(() => {
      if (!chartRef.current) return;
      applyPaneLayout(chartRef.current, settingsRef.current);
      if (viewModeRef.current === "auto" && candlesRef.current.length) {
        chartRef.current.timeScale().setVisibleLogicalRange({ from: Math.max(0, candlesRef.current.length - autoVisibleBars()), to: candlesRef.current.length - 1 });
      }
    });
    resizeObserver.observe(container);
    // 自动：左右拖动＋滚轮缩放可用，上下（价格轴／触摸竖向）锁定；手动：全向。
    const applyViewMode = (mode: "auto" | "manual") => {
      chart.applyOptions({
        handleScroll: { mouseWheel: true, pressedMouseMove: true, horzTouchDrag: true, vertTouchDrag: mode === "manual" },
        handleScale: { mouseWheel: true, pinch: true, axisPressedMouseMove: mode === "manual" ? true : { time: true, price: false }, axisDoubleClickReset: true },
      });
    };
    applyViewMode("auto");
    viewModeApplyRef.current = applyViewMode;
    const onCrosshair = (param: { point?: { x: number; y: number } }) => {
      const candle = candleRef.current;
      const api = chartRef.current;
      if (!param.point || !candle || !api) { setCrosshair(null); return; }
      const mainHeight = api.panes()[0]?.getHeight() ?? 0;
      if (param.point.y > mainHeight) { setCrosshair(null); return; }
      const price = candle.coordinateToPrice(param.point.y);
      if (price === null) { setCrosshair(null); return; }
      setCrosshair({ y: param.point.y, price });
    };
    chart.subscribeCrosshairMove(onCrosshair);
    return () => {
      chart.unsubscribeCrosshairMove(onCrosshair);
      resizeObserver.disconnect();
      chart.remove();
      chartRef.current = null;
      bandRef.current = null;
      candleRef.current = null;
      emaRefs.current = [null, null, null];
      stLineRef.current = null;
      paneLegendRefs.current = [null, null];
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
    getKlines(symbol, selectedInterval, HISTORY_LIMIT, controller.signal).then((candles) => {
      if (!active) return;
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
      if (active && !(error instanceof DOMException && error.name === "AbortError")) setStatus("error");
    });
    let tickPending = false;
    const scheduleTail = () => {
      if (tickPending) return;
      tickPending = true;
      window.setTimeout(() => {
        tickPending = false;
        if (active && candlesSymbolRef.current === symbol && candlesRef.current.length) renderData(candlesRef.current, false, true);
      }, 120);
    };
    const stream = new BinanceStream(symbol, selectedInterval, (event) => {
      if (!active || candlesSymbolRef.current !== symbol) return;
      if (event.type === "kline") {
        candlesRef.current = mergeCandle(candlesRef.current, event.candle);
        scheduleTail();
      } else if (event.type === "ticker") {
        const next = mergeTicker(candlesRef.current, event.price);
        if (next !== candlesRef.current) {
          candlesRef.current = next;
          scheduleTail();
        }
      }
    });
    stream.connect();
    return () => { active = false; controller.abort(); stream.close(); };
  }, [hydrating, symbol, selectedInterval, attempt, renderData]);

  function resetView() {
    viewModeRef.current = "auto";
    setViewMode("auto");
    const chart = chartRef.current;
    const length = candlesRef.current.length;
    if (!chart || !length) return;
    // 手动期的价格轴缩放一并复位：恢复各 pane 自动价格域。
    chart.panes().forEach((_, index) => chart.priceScale("right", index).applyOptions({ autoScale: true }));
    chart.timeScale().setVisibleLogicalRange({ from: Math.max(0, length - autoVisibleBars()), to: length - 1 });
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
        </div>
        <div className="toolbar-right">
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
      <div className="kline-stage" data-chart-theme={theme}>
        {status === "loading" && <div className="kline-loading" role="status" aria-label="K 线加载中"><span className="kline-bars" aria-hidden="true"><i /><i /><i /><i /></span></div>}
        {status === "error" && <div className="chart-widget-notice chart-widget-error"><p role="status">K 线加载失败</p><button className="chart-restore" type="button" onClick={() => setAttempt((previous) => previous + 1)}>重试</button></div>}
        <div ref={containerRef} className="kline-container" />
        {crosshair && (() => {
          const base = candlesRef.current[candlesRef.current.length - 1]?.close ?? crosshair.price;
          const pct = base > 0 ? (crosshair.price - base) / base * 100 : 0;
          const up = pct >= 0;
          return <div className="kline-crosshair-tag" style={{ top: crosshair.y }}>
            <span>{priceScaleFormatter(crosshair.price)}</span>
            <span className={up ? "up" : "down"}>{up ? "+" : "-"}{Math.abs(pct).toFixed(2)}%</span>
          </div>;
        })()}
      </div>
      {showSettings && <IndicatorSettingsPanel settings={settings} onChange={(next) => setPreference({ ...preference, indicators: next })} onClose={() => setShowSettings(false)} />}
    </>
  );
}