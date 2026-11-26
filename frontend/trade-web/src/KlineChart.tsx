import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { ReactNode } from "react";
import { createPortal } from "react-dom";
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
import { DEFAULT_INDICATORS, mergeIndicatorSettings, type IndicatorSettings } from "./lib/indicatorSettings";
import { createSupertrendBandView, type BandPoint, type BandFillConfig } from "./lib/supertrendBand";
import { createMacdHistogramView, type MacdBarPoint, type MacdHistogramConfig } from "./lib/macdHistogram";
import IndicatorSettingsPanel from "./IndicatorSettingsPanel";
import "./kline-chart.css";

const INTERVALS = ["3m", "5m", "15m", "1h", "4h", "1d"];
const VALID_INTERVALS = new Set(["1m", "3m", "5m", "15m", "30m", "1h", "2h", "4h", "1d"]);
const HISTORY_LIMIT = 500;
// 首屏可见根数：旧 TradingView 15m≈96 根的 1/3 再翻倍。
const INITIAL_VISIBLE_BARS = 64;
// 自适应高度比例：主图 70%，两个副图各 15%。
const PANE_STRETCH = { main: 70, sub: 15 };
const RIGHT_OFFSET = 5;
// 客户端 SWR 缓存：回切已看过的币种瞬时出图，后台再拉新数据校正。
const klineCache = new Map<string, Candle[]>();

interface ChartPreference { interval: string; indicators?: unknown }
const defaultChartPreference: ChartPreference = { interval: "15m", indicators: DEFAULT_INDICATORS };
function validChartPreference(value: unknown): value is ChartPreference {
  return !!value && typeof value === "object" && typeof (value as ChartPreference).interval === "string"
    && VALID_INTERVALS.has((value as ChartPreference).interval);
}

const THEMES = {
  dark: { bg: "#212731", text: "#F0F0F4", grid: "#333B47", sep: "#5C6675", up: "#28A473", down: "#F63C55" },
  light: { bg: "#FFFFFF", text: "#181A20", grid: "#EAECEF", sep: "#B8BFC9", up: "#2EBD85", down: "#F6465D" },
};

// 十字线只在各序列上保留竖横参考线，不显示小圆点标记。
const NO_CROSSHAIR_MARKER = { crosshairMarkerVisible: false } as const;

type Time = ChartTime;
type LinePoint = LineData<Time> | WhitespaceData<Time>;
type CandlePoint = CandlestickData<Time> | WhitespaceData<Time>;
type BandDataPoint = BandPoint | WhitespaceData<Time>;
type MacdDataPoint = MacdBarPoint | WhitespaceData<Time>;

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

export default function KlineChart({ symbol, actionsContainer, insightToggle, theme = "dark", readOnly = false }: {
  symbol: string;
  actionsContainer: HTMLElement | null;
  insightToggle?: ReactNode;
  theme?: "dark" | "light";
  onSymbolChange?: (symbol: string) => void;
  readOnly?: boolean;
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
  const stUpRef = useRef<ISeriesApi<"Line"> | null>(null);
  const stDownRef = useRef<ISeriesApi<"Line"> | null>(null);
  const macdHistRef = useRef<ISeriesApi<"Custom", Time, MacdDataPoint> | null>(null);
  const macdConfigRef = useRef<MacdHistogramConfig>({ upColor: "#28A473", downColor: "#F63C55", zeroColor: "#333B47" });
  const macdDifRef = useRef<ISeriesApi<"Line"> | null>(null);
  const macdDeaRef = useRef<ISeriesApi<"Line"> | null>(null);
  const stochKRef = useRef<ISeriesApi<"Line"> | null>(null);
  const stochDRef = useRef<ISeriesApi<"Line"> | null>(null);
  const candlesRef = useRef<Candle[]>([]);
  // 当前 candlesRef 归属的币种；切币未加载完成前置 null，禁止新币 tick 合并进旧币尾根。
  const candlesSymbolRef = useRef<string | null>(null);
  const themeRef = useRef(theme);
  const settingsRef = useRef(settings);
  const [status, setStatus] = useState<"loading" | "ready" | "error">("loading");
  const [attempt, setAttempt] = useState(0);
  const [viewMode, setViewMode] = useState<"auto" | "manual">("auto");
  const viewModeRef = useRef<"auto" | "manual">("auto");

  const renderData = useCallback((candles: Candle[], resetView: boolean, tail = false) => {
    const chart = chartRef.current;
    if (!chart || !candleRef.current || !candles.length) return;
    const t = THEMES[themeRef.current];
    const config = settingsRef.current;
    const indicators = buildChartIndicators(candles, config);
    const times = indicators.times;
    const last = candles.length - 1;
    const emaValues = [indicators.ema21, indicators.ema55, indicators.ema144];
    // 反转处留一根空 bar，让多头／空头线段明确断开。
    const isFlip = (index: number) => index > 0 && indicators.supertrend[index - 1].direction !== indicators.supertrend[index].direction;
    const stPoint = (index: number, direction: 1 | -1): LinePoint => {
      const point = indicators.supertrend[index];
      return point.direction === direction && point.value !== null && !isFlip(index) ? { time: times[index] as Time, value: point.value } : { time: times[index] as Time };
    };
    const bandPoint = (index: number): BandDataPoint => {
      const point = indicators.supertrend[index];
      // 反转 bar 留空，避免填充带画出跨趋势的竖直连接段。
      return point.value === null || isFlip(index) ? { time: times[index] as Time } : { time: times[index] as Time, close: candles[index].close, st: point.value, direction: point.direction ?? 1 };
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
      stUpRef.current?.update(stPoint(last, 1));
      stDownRef.current?.update(stPoint(last, -1));
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
    stUpRef.current?.setData(times.map((_, index) => stPoint(index, 1)));
    stDownRef.current?.setData(times.map((_, index) => stPoint(index, -1)));
    stUpRef.current?.applyOptions({ color: config.supertrend.upColor, visible: config.supertrend.enabled });
    stDownRef.current?.applyOptions({ color: config.supertrend.downColor, visible: config.supertrend.enabled });
    bandConfigRef.current.fillUpColor = config.supertrend.fillUpColor;
    bandConfigRef.current.fillDownColor = config.supertrend.fillDownColor;
    bandConfigRef.current.fillOpacity = config.supertrend.fillOpacity;
    bandRef.current?.setData(times.map((_, index) => bandPoint(index)));
    bandRef.current?.applyOptions({ visible: config.supertrend.enabled });
    macdConfigRef.current.upColor = config.macd.upColor;
    macdConfigRef.current.downColor = config.macd.downColor;
    macdConfigRef.current.zeroColor = t.grid;
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
    if (resetView || viewModeRef.current === "auto") {
      chart.timeScale().setVisibleLogicalRange({ from: Math.max(0, candles.length - INITIAL_VISIBLE_BARS), to: candles.length - 1 });
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
      crosshair: { mode: CrosshairMode.Normal },
      localization: { locale: "zh-CN" },
    });
    chartRef.current = chart;
    bandRef.current = chart.addCustomSeries(createSupertrendBandView(bandConfigRef.current), { priceLineVisible: false, lastValueVisible: false, ...NO_CROSSHAIR_MARKER }, 0);
    candleRef.current = chart.addSeries(CandlestickSeries, {
      upColor: t.up, downColor: t.down, borderVisible: false, wickUpColor: t.up, wickDownColor: t.down, ...NO_CROSSHAIR_MARKER,
    });
    emaRefs.current = [0, 1, 2].map(() => chart.addSeries(LineSeries, { lineWidth: 1, priceLineVisible: false, lastValueVisible: false, ...NO_CROSSHAIR_MARKER }));
    stUpRef.current = chart.addSeries(LineSeries, { lineWidth: 1, priceLineVisible: false, lastValueVisible: false, ...NO_CROSSHAIR_MARKER });
    stDownRef.current = chart.addSeries(LineSeries, { lineWidth: 1, priceLineVisible: false, lastValueVisible: false, ...NO_CROSSHAIR_MARKER });
    macdHistRef.current = chart.addCustomSeries(createMacdHistogramView(macdConfigRef.current), { priceLineVisible: false, lastValueVisible: false, ...NO_CROSSHAIR_MARKER }, 1);
    macdDifRef.current = chart.addSeries(LineSeries, { lineWidth: 1, priceLineVisible: false, lastValueVisible: false, ...NO_CROSSHAIR_MARKER }, 1);
    macdDeaRef.current = chart.addSeries(LineSeries, { lineWidth: 1, priceLineVisible: false, lastValueVisible: false, ...NO_CROSSHAIR_MARKER }, 1);
    const fixedRange = { autoscaleInfoProvider: () => ({ priceRange: { minValue: 0, maxValue: 100 } }) };
    stochKRef.current = chart.addSeries(LineSeries, { lineWidth: 1, priceLineVisible: false, lastValueVisible: false, ...fixedRange, ...NO_CROSSHAIR_MARKER }, 2);
    stochDRef.current = chart.addSeries(LineSeries, { lineWidth: 1, priceLineVisible: false, lastValueVisible: false, ...fixedRange, ...NO_CROSSHAIR_MARKER }, 2);
    const resizeObserver = new ResizeObserver(() => { if (chartRef.current) applyPaneLayout(chartRef.current, settingsRef.current); });
    resizeObserver.observe(container);
    const markManual = () => { viewModeRef.current = "manual"; setViewMode("manual"); };
    const onWheel = () => markManual();
    const onPointerMove = (event: PointerEvent) => { if (event.buttons > 0) markManual(); };
    container.addEventListener("wheel", onWheel, { passive: true });
    container.addEventListener("pointermove", onPointerMove);
    return () => {
      container.removeEventListener("wheel", onWheel);
      container.removeEventListener("pointermove", onPointerMove);
      resizeObserver.disconnect();
      chart.remove();
      chartRef.current = null;
      bandRef.current = null;
      candleRef.current = null;
      emaRefs.current = [null, null, null];
      stUpRef.current = stDownRef.current = null;
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
    const cacheKey = `${symbol}|${selectedInterval}`;
    const cached = klineCache.get(cacheKey);
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
      if (klineCache.size > 12) klineCache.delete(klineCache.keys().next().value as string);
      klineCache.set(cacheKey, candles);
      candlesRef.current = candles;
      candlesSymbolRef.current = symbol;
      if (!cached) {
        viewModeRef.current = "auto";
        setViewMode("auto");
      }
      renderData(candles, !cached);
      setStatus("ready");
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
    chart.timeScale().setVisibleLogicalRange({ from: Math.max(0, length - INITIAL_VISIBLE_BARS), to: length - 1 });
  }

  return (
    <>
      {actionsContainer && !readOnly && createPortal(<button className="chart-restore" type="button" onClick={resetView}>重置</button>, actionsContainer)}
      {actionsContainer && insightToggle && createPortal(insightToggle, actionsContainer)}
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
            <button type="button" className={viewMode === "auto" ? "active" : ""} aria-pressed={viewMode === "auto"} onClick={resetView}>自动</button>
            <button type="button" className={viewMode === "manual" ? "active" : ""} aria-pressed={viewMode === "manual"} onClick={() => { viewModeRef.current = "manual"; setViewMode("manual"); }}>手动</button>
          </div>
          <button type="button" className="indicator-master" aria-label="指标设置" title="指标设置" aria-expanded={showSettings} onClick={() => setShowSettings(true)}>
            <SlidersHorizontal size={15} /> 指标
          </button>
        </div>
      </div>
      <div className="kline-stage" data-chart-theme={theme}>
        {status === "loading" && <div className="kline-loading" role="status"><span className="kline-spinner" aria-hidden="true" /><span>加载 K 线…</span></div>}
        {status === "error" && <div className="chart-widget-notice chart-widget-error"><p role="status">K 线加载失败</p><button className="chart-restore" type="button" onClick={() => setAttempt((previous) => previous + 1)}>重试</button></div>}
        <div ref={containerRef} className="kline-container" />
      </div>
      {showSettings && <IndicatorSettingsPanel settings={settings} onChange={(next) => setPreference({ ...preference, indicators: next })} onClose={() => setShowSettings(false)} />}
    </>
  );
}