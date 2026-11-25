import { useEffect, useRef, useState } from "react";
import type { CSSProperties } from "react";
import { createPortal } from "react-dom";
import { ArrowUpRight, RefreshCw } from "lucide-react";
import { useAccount, usePreference } from "./AccountProvider";

// Serve TradingView's official legacy loader from the integrated static
// package. The loader still creates an iframe on TradingView's official host,
// while the browser no longer needs to fetch the bootstrap script from s3.
const widgetScript = "vendor/tradingview-advanced-chart.js";
const initialInterval = "15";
interface ChartPreference { interval: string; timeFrame?: string }
const defaultChartPreference: ChartPreference = { interval: initialInterval, timeFrame: "2d" };
const localIntervals = [
  { value: "3", label: "3 分钟", shortLabel: "3m", timeFrame: "2d" },
  { value: "5", label: "5 分钟", shortLabel: "5m", timeFrame: "2d" },
  { value: "15", label: "15 分钟", shortLabel: "15m", timeFrame: "2d" },
  { value: "60", label: "1 小时", shortLabel: "1h", timeFrame: "7d" },
  { value: "240", label: "4 小时", shortLabel: "4h", timeFrame: "1M" },
  { value: "D", label: "1 天", shortLabel: "1D", timeFrame: "1y" },
] as const;
const intervalAliases: Record<string, string> = { "3m": "3", "5m": "5", "15m": "15", "1h": "60", "4h": "240", "1d": "D", "1D": "D" };
function canonicalInterval(interval: string) {
  return intervalAliases[interval] ?? interval;
}
function validChartPreference(value: unknown): value is ChartPreference {
  if (!value || typeof value !== "object") return false;
  const chart = value as ChartPreference;
  return typeof chart.interval === "string" && /^(?:[1-9][0-9]{0,4}[SMHDW]?|[DWM])$/.test(chart.interval)
    && (chart.timeFrame === undefined || /^(?:all|[1-9][0-9]{0,3}[smhdwMyY])$/.test(chart.timeFrame));
}
// Keep all default studies in TradingView. MA Ribbon is a single study with
// the three requested EMA lengths, so the chart does not create three separate
// indicator entries. The legacy embed accepts the standard-study IDs below,
// including the native MACD and Stoch RSI panes.
const studies = [
  {
    id: "STD;MA%Ribbon",
    overlay: true,
    inputs: {
      in_1: "EMA",
      in_3: 21,
      in_5: "EMA",
      in_7: 55,
      in_9: "EMA",
      in_11: 144,
      in_12: false,
    },
  },
  {
    id: "STD;Supertrend",
    overlay: true,
    inputs: { in_0: 10, in_1: 6 },
  },
  // Keep pane studies as full descriptors. The legacy embed accepts string
  // aliases for simple layouts, but drops those panes when they follow the
  // object-based overlay studies above.
  { id: "STD;MACD", overlay: false, inputs: {} },
  { id: "StochasticRSI@tv-basicstudies", overlay: false, inputs: {} },
];

function perpetualSymbol(symbol: string) {
  return `BINANCE:${symbol}.P`;
}

interface ChartOptions {
  interval: string;
  timeFrame?: string;
  attempt: number;
}

type ChartStatus = "loading" | "ready" | "slow" | "error";

function createWidgetScript(symbol: string, { interval, timeFrame, attempt }: ChartOptions, readOnly: boolean) {
  const script = document.createElement("script");
  script.type = "text/javascript";
  script.async = true;
  script.src = attempt ? `${widgetScript}?retry=${attempt}` : widgetScript;
  script.text = JSON.stringify({
    autosize: true,
    symbol: perpetualSymbol(symbol),
    interval,
    range: timeFrame || (interval === "D" ? "1y" : "2d"),
    timezone: "Asia/Shanghai",
    theme: "dark",
    style: "1",
    locale: "zh_CN",
    enable_publishing: false,
    hide_top_toolbar: true,
    hide_side_toolbar: readOnly,
    hide_legend: false,
    hide_volume: true,
    save_image: false,
    allow_symbol_change: false,
    withdateranges: false,
    details: false,
    hotlist: false,
    calendar: false,
    studies,
    support_host: "https://www.tradingview.com",
    backgroundColor: "#0c0d0f",
    gridColor: "rgba(161, 165, 174, 0.08)",
  });
  return script;
}

export default function TradingViewWidget({ symbol, actionsContainer, onSymbolChange: _onSymbolChange, readOnly = false }: { symbol: string; actionsContainer: HTMLElement | null; onSymbolChange?: (symbol: string) => void; readOnly?: boolean }) {
  const { hydrating } = useAccount();
  const [preference, setPreference] = usePreference("chart", defaultChartPreference, validChartPreference);
  const containerRef = useRef<HTMLDivElement>(null);
  const [options, setOptions] = useState<ChartOptions>({ interval: initialInterval, attempt: 0 });
  const [status, setStatus] = useState<ChartStatus>("loading");
  const selectedInterval = canonicalInterval(preference.interval);

  useEffect(() => {
    if (options.interval === selectedInterval && options.timeFrame === preference.timeFrame) return;
    setOptions((previous) => ({
      ...previous,
      interval: selectedInterval,
      timeFrame: preference.timeFrame,
      attempt: previous.attempt + 1,
    }));
  }, [options.interval, options.timeFrame, preference.timeFrame, selectedInterval]);

  useEffect(() => {
    const container = containerRef.current;
    if (!container || hydrating || options.interval !== selectedInterval || options.timeFrame !== preference.timeFrame) return;

    container.replaceChildren();
    const widgetHost = document.createElement("div");
    widgetHost.className = "tradingview-widget-container__widget";
    container.append(widgetHost);
    const script = createWidgetScript(symbol, options, readOnly);
    setStatus("loading");
    let settled = false;
    const slowTimer = window.setTimeout(() => {
      if (!settled) setStatus("slow");
    }, 10_000);
    const failureTimer = window.setTimeout(() => {
      if (!settled) {
        settled = true;
        setStatus("error");
      }
    }, 30_000);
    const markReady = () => {
      if (settled || !container.querySelector("iframe")) return;
      settled = true;
      window.clearTimeout(slowTimer);
      window.clearTimeout(failureTimer);
      setStatus("ready");
    };
    const observer = new MutationObserver(markReady);
    observer.observe(container, { childList: true, subtree: true });
    script.onload = markReady;
    script.onerror = () => {
      settled = true;
      window.clearTimeout(slowTimer);
      window.clearTimeout(failureTimer);
      setStatus("error");
    };
    container.append(script);
    markReady();

    return () => {
      window.clearTimeout(slowTimer);
      window.clearTimeout(failureTimer);
      observer.disconnect();
      script.onload = null;
      script.onerror = null;
      container.replaceChildren();
    };
  }, [hydrating, options, readOnly, symbol]);

  function reloadChart() {
    setOptions((previous) => ({ ...previous, attempt: previous.attempt + 1 }));
  }

  function resetChart() {
    if (!window.confirm("重置会恢复默认指标，并清除当前图表未保存的画线和临时设置。继续？")) return;
    reloadChart();
  }

  const chartUrl = `https://www.tradingview.com/chart/?symbol=${encodeURIComponent(perpetualSymbol(symbol))}`;

  return (
    <>
      {actionsContainer && !readOnly && createPortal(
        <button className="chart-restore" type="button" onClick={resetChart}>
          重置
        </button>,
        actionsContainer,
      )}
      <div className="tradingview-stage" style={{ "--compact-indicators-height": "0px" } as CSSProperties}>
        <div className="chart-local-toolbar">
          <span className="chart-local-toolbar-label">周期</span>
          <div className="chart-local-intervals" role="group" aria-label="K线周期">
            {localIntervals.map((item) => <button key={item.value} type="button" title={item.label} aria-pressed={selectedInterval === item.value} className={selectedInterval === item.value ? "active" : ""} onClick={() => setPreference({ interval: item.value, timeFrame: item.timeFrame })}>{item.shortLabel}</button>)}
          </div>
        </div>
        {status === "loading" && <div className="chart-widget-loading" role="status"><RefreshCw size={14} className="spin" /> 正在连接 TradingView…</div>}
        {(status === "slow" || status === "error") && (
          <div className={`chart-widget-notice ${status === "error" ? "chart-widget-error" : ""}`}>
            <p role="status">{status === "slow" ? "TradingView 图表响应较慢" : "TradingView 图表连接失败"}</p>
            <button className="chart-restore" type="button" onClick={reloadChart}>重试图表</button>
            <a href={chartUrl} target="_blank" rel="noreferrer">在 TradingView 打开 <ArrowUpRight size={13} aria-hidden="true" /></a>
          </div>
        )}
        <div ref={containerRef} className="tradingview-widget tradingview-widget-container" />
      </div>
    </>
  );
}
