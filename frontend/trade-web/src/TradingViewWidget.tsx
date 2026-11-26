import { useEffect, useEffectEvent, useRef, useState } from "react";
import type { CSSProperties, ReactNode } from "react";
import { createPortal } from "react-dom";
import { ArrowUpRight, RefreshCw } from "lucide-react";
import { useAccount, usePreference } from "./AccountProvider";

const widgetTag = "tv-advanced-chart";
const widgetScript = "https://widgets.tradingview-widget.com/w/zh_CN/tv-advanced-chart.js";
const initialInterval = "15";
interface ChartPreference { interval: string; timeFrame?: string }
const defaultChartPreference: ChartPreference = { interval: initialInterval, timeFrame: "2d" };
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

const studies = JSON.stringify([
  { id: "STD;MA%Ribbon", overlay: true, inputs: { in_1: "EMA", in_3: 21, in_5: "EMA", in_7: 55, in_9: "EMA", in_11: 144, in_12: false } },
  { id: "STD;Supertrend", overlay: true, inputs: { in_0: 10, in_1: 6 } },
  { id: "STD;MACD", overlay: false, inputs: {} },
  { id: "StochasticRSI@tv-basicstudies", overlay: false, inputs: {} },
]);

function perpetualSymbol(symbol: string) {
  return `BINANCE:${symbol}.P`;
}

interface ChartOptions { interval: string; timeFrame?: string; attempt: number }
type ChartStatus = "loading" | "ready" | "slow" | "error";
type ChartTheme = "dark" | "light";

function createChart(symbol: string, { interval, timeFrame }: ChartOptions, readOnly: boolean, theme: ChartTheme) {
  const chart = document.createElement(widgetTag);
  chart.setAttribute("symbol", perpetualSymbol(symbol));
  chart.setAttribute("interval", interval);
  chart.setAttribute("time-frame", timeFrame || (interval === "D" ? "1y" : "2d"));
  chart.setAttribute("timezone", "Asia/Shanghai");
  chart.setAttribute("theme", theme);
  chart.setAttribute("locale", "zh_CN");
  chart.setAttribute("hide-snapshot-button", "");
  chart.setAttribute("hide-volume", "");
  chart.setAttribute("store-settings", "false");
  chart.setAttribute("studies", studies);
  if (readOnly) chart.setAttribute("hide-top-toolbar", "");
  else chart.setAttribute("show-drawing-toolbar", "");
  return chart;
}

export default function TradingViewWidget({ symbol, actionsContainer, insightToggle, theme = "dark", onSymbolChange: _onSymbolChange, readOnly = false }: { symbol: string; actionsContainer: HTMLElement | null; insightToggle?: ReactNode; theme?: ChartTheme; onSymbolChange?: (symbol: string) => void; readOnly?: boolean }) {
  const { user, hydrating } = useAccount();
  const [preference, setPreference] = usePreference("chart", defaultChartPreference, validChartPreference);
  const containerRef = useRef<HTMLDivElement>(null);
  const chartRef = useRef<HTMLElement>(null);
  const [options, setOptions] = useState<ChartOptions>({ interval: initialInterval, attempt: 0 });
  const [status, setStatus] = useState<ChartStatus>("loading");
  const selectedInterval = canonicalInterval(preference.interval);
  const chartSurface = theme === "light" ? "#eef0f3" : "#0c0d0f";

  useEffect(() => {
    if (options.interval === selectedInterval && options.timeFrame === preference.timeFrame) return;
    setOptions((previous) => ({ ...previous, interval: selectedInterval, timeFrame: preference.timeFrame, attempt: previous.attempt + 1 }));
  }, [options.interval, options.timeFrame, preference.timeFrame, selectedInterval]);

  const reflectChartPreference = useEffectEvent((chart: HTMLElement) => {
    const interval = canonicalInterval(chart.getAttribute("interval") ?? initialInterval);
    const timeFrame = chart.getAttribute("time-frame") ?? undefined;
    if (validChartPreference({ interval, timeFrame })) setPreference({ interval, timeFrame });
    const reflected = chart.getAttribute("symbol")?.match(/^BINANCE:([A-Z0-9]{1,30}USDT)\.P$/);
    if (reflected && reflected[1] !== symbol) _onSymbolChange?.(reflected[1]);
  });

  useEffect(() => {
    const container = containerRef.current;
    if (!container || hydrating || options.interval !== selectedInterval || options.timeFrame !== preference.timeFrame) return;

    const chart = createChart(symbol, options, readOnly, theme);
    chartRef.current = chart;
    container.replaceChildren(chart);
    setStatus("loading");
    let settled = false;
    let moduleScript: HTMLScriptElement | undefined;
    const slowTimer = window.setTimeout(() => { if (!settled) setStatus("slow"); }, 10_000);
    const failureTimer = window.setTimeout(() => { if (!settled) { settled = true; setStatus("error"); } }, 30_000);
    const observer = new MutationObserver(() => { if (settled) reflectChartPreference(chart); });
    observer.observe(chart, { attributes: true, attributeFilter: ["interval", "time-frame", "symbol"] });
    const onReady = () => {
      settled = true;
      window.clearTimeout(slowTimer);
      window.clearTimeout(failureTimer);
      setStatus("ready");
      reflectChartPreference(chart);
    };
    const onError = (event: Event) => {
      settled = true;
      window.clearTimeout(slowTimer);
      window.clearTimeout(failureTimer);
      const type = (event as CustomEvent<{ type?: string }>).detail?.type;
      setStatus(type === "no-data" || type === "unsupported-interval" ? "ready" : "error");
    };
    chart.addEventListener("tv-widget-ready", onReady);
    chart.addEventListener("tv-widget-error", onError);
    if (!customElements.get(widgetTag)) {
      moduleScript = document.createElement("script");
      moduleScript.type = "module";
      moduleScript.src = options.attempt ? `${widgetScript}?retry=${options.attempt}` : widgetScript;
      moduleScript.onerror = () => { settled = true; window.clearTimeout(slowTimer); window.clearTimeout(failureTimer); setStatus("error"); };
      document.head.append(moduleScript);
    }

    return () => {
      window.clearTimeout(slowTimer);
      window.clearTimeout(failureTimer);
      observer.disconnect();
      chart.removeEventListener("tv-widget-ready", onReady);
      chart.removeEventListener("tv-widget-error", onError);
      moduleScript?.remove();
      chart.remove();
      chartRef.current = null;
    };
  }, [hydrating, options, preference.timeFrame, readOnly, selectedInterval, symbol, theme]);

  useEffect(() => {
    const chart = chartRef.current;
    if (!chart || hydrating) return;
    if (chart.getAttribute("symbol") !== perpetualSymbol(symbol)) chart.setAttribute("symbol", perpetualSymbol(symbol));
  }, [hydrating, symbol]);

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
      {actionsContainer && !readOnly && createPortal(<button className="chart-restore" type="button" onClick={resetChart}>重置</button>, actionsContainer)}
      {actionsContainer && insightToggle && createPortal(insightToggle, actionsContainer)}
      <div className="tradingview-stage" data-chart-theme={theme} style={{ "--compact-indicators-height": "0px", "--chart-surface": chartSurface } as CSSProperties}>
        {status === "loading" && <div className="chart-widget-loading" role="status"><RefreshCw size={14} className="spin" /> 正在连接 TradingView…</div>}
        {(status === "slow" || status === "error") && <div className={`chart-widget-notice ${status === "error" ? "chart-widget-error" : ""}`}><p role="status">{status === "slow" ? "TradingView 图表响应较慢" : "TradingView 图表连接失败"}</p><button className="chart-restore" type="button" onClick={reloadChart}>重试图表</button><a href={chartUrl} target="_blank" rel="noreferrer">在 TradingView 打开 <ArrowUpRight size={13} aria-hidden="true" /></a></div>}
        <div ref={containerRef} className="tradingview-widget" />
      </div>
    </>
  );
}
