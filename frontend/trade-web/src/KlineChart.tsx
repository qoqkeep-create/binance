import { useCallback, useEffect, useRef, useState } from "react";
import type { ReactNode } from "react";
import { createPortal } from "react-dom";
import { RefreshCw } from "lucide-react";
import {
  createChart, ColorType, CrosshairMode, LineStyle,
  CandlestickSeries, LineSeries, HistogramSeries,
  type IChartApi, type ISeriesApi, type UTCTimestamp,
  type CandlestickData, type LineData, type HistogramData, type WhitespaceData,
} from "lightweight-charts";
import { useAccount, usePreference } from "./AccountProvider";
import { BinanceStream, getKlines, type Candle } from "./lib/binance";
import { buildChartIndicators } from "./lib/chartIndicators";
import "./kline-chart.css";

const INTERVALS = ["3m", "5m", "15m", "1h", "4h", "1d"];
const VALID_INTERVALS = new Set(["1m", "3m", "5m", "15m", "30m", "1h", "2h", "4h", "1d"]);
const HISTORY_LIMIT = 500;
// 首屏可见根数约为旧 TradingView 15m≈96 根的 1/3。
const INITIAL_VISIBLE_BARS = 32;
// 指标副图高度对齐 iOS 的 72pt，约为旧 108px 副图的 2/3。
const SUB_PANE_HEIGHT = 72;
const RIGHT_OFFSET = 5;

interface ChartPreference { interval: string }
const defaultChartPreference: ChartPreference = { interval: "15m" };
function validChartPreference(value: unknown): value is ChartPreference {
  return !!value && typeof value === "object" && typeof (value as ChartPreference).interval === "string"
    && VALID_INTERVALS.has((value as ChartPreference).interval);
}

const THEMES = {
  dark: { bg: "#212731", text: "#F0F0F4", grid: "#333B47", up: "#28A473", down: "#F63C55" },
  light: { bg: "#FFFFFF", text: "#181A20", grid: "#EAECEF", up: "#2EBD85", down: "#F6465D" },
};
const EMA_COLORS = { ema21: "#2DBD85", ema55: "#3860F6", ema144: "#71269C" };
const MACD_DIF = "#2DBD85";
const MACD_DEA = "#71269C";
const STOCH_K = "#2DBD85";
const STOCH_D = "#71269C";

type Time = UTCTimestamp;
type LinePoint = LineData<Time> | WhitespaceData<Time>;
type CandlePoint = CandlestickData<Time> | WhitespaceData<Time>;
type HistogramPoint = HistogramData<Time> | WhitespaceData<Time>;

function lineData(times: number[], values: Array<number | null>): LinePoint[] {
  return times.map((time, index) => values[index] === null
    ? { time: time as Time }
    : { time: time as Time, value: values[index]! });
}

function mergeCandle(candles: Candle[], candle: Candle): Candle[] {
  if (!candles.length) return [candle];
  const last = candles[candles.length - 1];
  if (candle.time === last.time) return [...candles.slice(0, -1), candle];
  if (candle.time > last.time) return [...candles, candle].slice(-1500);
  return candles;
}

// setHeight 会按当前高度反推 stretch，连续设置会互相干扰；改用绝对 stretch 因子。
function applyPaneHeights(chart: IChartApi) {
  const panes = chart.panes();
  if (panes.length < 3) return;
  const available = panes.reduce((sum, pane) => sum + pane.getHeight(), 0);
  panes[0].setStretchFactor(Math.max(120, available - SUB_PANE_HEIGHT * 2));
  panes[1].setStretchFactor(SUB_PANE_HEIGHT);
  panes[2].setStretchFactor(SUB_PANE_HEIGHT);
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
  const containerRef = useRef<HTMLDivElement>(null);
  const chartRef = useRef<IChartApi | null>(null);
  const candleRef = useRef<ISeriesApi<"Candlestick"> | null>(null);
  const ema21Ref = useRef<ISeriesApi<"Line"> | null>(null);
  const ema55Ref = useRef<ISeriesApi<"Line"> | null>(null);
  const ema144Ref = useRef<ISeriesApi<"Line"> | null>(null);
  const stUpRef = useRef<ISeriesApi<"Line"> | null>(null);
  const stDownRef = useRef<ISeriesApi<"Line"> | null>(null);
  const macdHistRef = useRef<ISeriesApi<"Histogram"> | null>(null);
  const macdDifRef = useRef<ISeriesApi<"Line"> | null>(null);
  const macdDeaRef = useRef<ISeriesApi<"Line"> | null>(null);
  const stochKRef = useRef<ISeriesApi<"Line"> | null>(null);
  const stochDRef = useRef<ISeriesApi<"Line"> | null>(null);
  const candlesRef = useRef<Candle[]>([]);
  const themeRef = useRef(theme);
  const [status, setStatus] = useState<"loading" | "ready" | "error">("loading");
  const [attempt, setAttempt] = useState(0);

  const renderData = useCallback((candles: Candle[], resetView: boolean) => {
    const chart = chartRef.current;
    if (!chart || !candleRef.current) return;
    const t = THEMES[themeRef.current];
    const indicators = buildChartIndicators(candles);
    const times = indicators.times;
    candleRef.current.setData(candles.map((candle): CandlePoint => ({
      time: candle.time as Time, open: candle.open, high: candle.high, low: candle.low, close: candle.close,
    })));
    ema21Ref.current?.setData(lineData(times, indicators.ema21));
    ema55Ref.current?.setData(lineData(times, indicators.ema55));
    ema144Ref.current?.setData(lineData(times, indicators.ema144));
    stUpRef.current?.setData(times.map((time, index): LinePoint => {
      const point = indicators.supertrend[index];
      return point.direction === 1 && point.value !== null ? { time: time as Time, value: point.value } : { time: time as Time };
    }));
    stDownRef.current?.setData(times.map((time, index): LinePoint => {
      const point = indicators.supertrend[index];
      return point.direction === -1 && point.value !== null ? { time: time as Time, value: point.value } : { time: time as Time };
    }));
    macdHistRef.current?.setData(times.map((time, index): HistogramPoint => {
      const histogram = indicators.macd[index].histogram;
      return histogram === null ? { time: time as Time } : { time: time as Time, value: histogram, color: histogram >= 0 ? t.up : t.down };
    }));
    macdDifRef.current?.setData(lineData(times, indicators.macd.map((point) => point.dif)));
    macdDeaRef.current?.setData(lineData(times, indicators.macd.map((point) => point.dea)));
    stochKRef.current?.setData(lineData(times, indicators.stoch.map((point) => point.k)));
    stochDRef.current?.setData(lineData(times, indicators.stoch.map((point) => point.d)));
    if (resetView && candles.length) {
      applyPaneHeights(chart);
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
        panes: { separatorColor: t.grid, separatorHoverColor: "rgba(155,155,170,0.2)", enableResize: true },
      },
      grid: { vertLines: { color: t.grid }, horzLines: { color: t.grid } },
      rightPriceScale: { borderVisible: false },
      timeScale: { borderVisible: false, timeVisible: true, secondsVisible: false, rightOffset: RIGHT_OFFSET, minBarSpacing: 0.5 },
      crosshair: { mode: CrosshairMode.Normal },
      localization: { locale: "zh-CN" },
    });
    chartRef.current = chart;
    candleRef.current = chart.addSeries(CandlestickSeries, {
      upColor: t.up, downColor: t.down, borderVisible: false, wickUpColor: t.up, wickDownColor: t.down,
    });
    ema21Ref.current = chart.addSeries(LineSeries, { color: EMA_COLORS.ema21, lineWidth: 1, priceLineVisible: false, lastValueVisible: false });
    ema55Ref.current = chart.addSeries(LineSeries, { color: EMA_COLORS.ema55, lineWidth: 1, priceLineVisible: false, lastValueVisible: false });
    ema144Ref.current = chart.addSeries(LineSeries, { color: EMA_COLORS.ema144, lineWidth: 1, priceLineVisible: false, lastValueVisible: false });
    stUpRef.current = chart.addSeries(LineSeries, { color: t.up, lineWidth: 1, priceLineVisible: false, lastValueVisible: false });
    stDownRef.current = chart.addSeries(LineSeries, { color: t.down, lineWidth: 1, priceLineVisible: false, lastValueVisible: false });
    macdHistRef.current = chart.addSeries(HistogramSeries, { priceLineVisible: false, lastValueVisible: false }, 1);
    macdDifRef.current = chart.addSeries(LineSeries, { color: MACD_DIF, lineWidth: 1, priceLineVisible: false, lastValueVisible: false }, 1);
    macdDeaRef.current = chart.addSeries(LineSeries, { color: MACD_DEA, lineWidth: 1, priceLineVisible: false, lastValueVisible: false }, 1);
    const fixedRange = { autoscaleInfoProvider: () => ({ priceRange: { minValue: 0, maxValue: 100 } }) };
    stochKRef.current = chart.addSeries(LineSeries, { color: STOCH_K, lineWidth: 1, priceLineVisible: false, lastValueVisible: false, ...fixedRange }, 2);
    stochDRef.current = chart.addSeries(LineSeries, { color: STOCH_D, lineWidth: 1, priceLineVisible: false, lastValueVisible: false, ...fixedRange }, 2);
    macdHistRef.current.createPriceLine({ price: 0, color: t.grid, lineWidth: 1, lineStyle: LineStyle.Solid, axisLabelVisible: false, title: "" });
    const resizeObserver = new ResizeObserver(() => { if (chartRef.current) applyPaneHeights(chartRef.current); });
    resizeObserver.observe(container);
    return () => {
      resizeObserver.disconnect();
      chart.remove();
      chartRef.current = null;
      candleRef.current = null;
      ema21Ref.current = ema55Ref.current = ema144Ref.current = null;
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
      layout: { background: { type: ColorType.Solid, color: t.bg }, textColor: t.text, panes: { separatorColor: t.grid } },
      grid: { vertLines: { color: t.grid }, horzLines: { color: t.grid } },
    });
    candleRef.current?.applyOptions({ upColor: t.up, downColor: t.down, wickUpColor: t.up, wickDownColor: t.down });
    stUpRef.current?.applyOptions({ color: t.up });
    stDownRef.current?.applyOptions({ color: t.down });
    if (candlesRef.current.length) renderData(candlesRef.current, false);
  }, [theme, renderData]);

  useEffect(() => {
    if (hydrating || !chartRef.current) return;
    let active = true;
    const controller = new AbortController();
    setStatus("loading");
    getKlines(symbol, selectedInterval, HISTORY_LIMIT, controller.signal).then((candles) => {
      if (!active) return;
      candlesRef.current = candles;
      renderData(candles, true);
      setStatus("ready");
    }).catch((error: unknown) => {
      if (active && !(error instanceof DOMException && error.name === "AbortError")) setStatus("error");
    });
    const stream = new BinanceStream(symbol, selectedInterval, (event) => {
      if (!active || event.type !== "kline") return;
      const next = mergeCandle(candlesRef.current, event.candle);
      candlesRef.current = next;
      renderData(next, false);
    });
    stream.connect();
    return () => { active = false; controller.abort(); stream.close(); };
  }, [hydrating, symbol, selectedInterval, attempt, renderData]);

  function resetView() {
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
            <button key={interval} type="button" className={`timeframe ${selectedInterval === interval ? "active" : ""}`} onClick={() => setPreference({ interval })}>
              {interval === "1d" ? "1D" : interval.toUpperCase()}
            </button>
          ))}
        </div>
      </div>
      <div className="kline-stage" data-chart-theme={theme}>
        {status === "loading" && <div className="chart-widget-loading" role="status"><RefreshCw size={14} className="spin" /> 正在加载 K 线…</div>}
        {status === "error" && <div className="chart-widget-notice chart-widget-error"><p role="status">K 线加载失败</p><button className="chart-restore" type="button" onClick={() => setAttempt((previous) => previous + 1)}>重试</button></div>}
        <div ref={containerRef} className="kline-container" />
      </div>
    </>
  );
}