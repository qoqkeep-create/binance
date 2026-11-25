import { useEffect, useEffectEvent, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { ArrowUpRight, RefreshCw } from "lucide-react";
import { useAccount, usePreference } from "./AccountProvider";
import CompactIndicatorStrip from "./CompactIndicatorStrip";

const widgetTag = "tv-advanced-chart";
const widgetScript = "https://widgets.tradingview-widget.com/w/zh_CN/tv-advanced-chart.js";
const initialInterval = "15";
interface ChartPreference { interval: string; timeFrame?: string }
const defaultChartPreference: ChartPreference = { interval: initialInterval, timeFrame: "2d" };
function validChartPreference(value: unknown): value is ChartPreference {
  if (!value || typeof value !== "object") return false;
  const chart = value as ChartPreference;
  return typeof chart.interval === "string" && /^(?:[1-9][0-9]{0,4}[SMHDW]?|[DWM])$/.test(chart.interval)
    && (chart.timeFrame === undefined || /^(?:all|[1-9][0-9]{0,3}[smhdwMyY])$/.test(chart.timeFrame));
}
const studies = JSON.stringify([
  {
    id: "STD;MA%Ribbon",
    overlay: true,
    inputs: {
      in_1: "EMA", in_3: 21,
      in_5: "EMA", in_7: 55,
      in_9: "EMA", in_11: 144,
      in_12: false,
    },
  },
  {
    id: "STD;Supertrend",
    overlay: true,
    inputs: { in_0: 10, in_1: 6 }, // ATR length, factor
  },
]);

function perpetualSymbol(symbol: string) {
  return `BINANCE:${symbol}.P`;
}

interface ChartOptions {
  interval: string;
  timeFrame?: string;
  chartType?: string;
  attempt: number;
}

type ChartStatus = "loading" | "ready" | "slow" | "error";

function createChart(symbol: string, { interval, timeFrame, chartType, readOnly }: ChartOptions & { readOnly?: boolean }) {
  const chart = document.createElement(widgetTag);
  chart.setAttribute("symbol", perpetualSymbol(symbol));
  chart.setAttribute("interval", interval);
  chart.setAttribute("time-frame", timeFrame || (["D", "1D"].includes(interval) ? "1y" : "2d"));
  chart.setAttribute("timezone", "Asia/Shanghai");
  if (readOnly) chart.setAttribute("hide-top-toolbar", "");
  else chart.setAttribute("show-drawing-toolbar", "");
  chart.setAttribute("hide-snapshot-button", "");
  chart.setAttribute("hide-volume", "");
  // Keep hosted TradingView defaults deterministic across widget mounts. The
  // public widget cannot accept indicator color overrides or pane sizing.
  // MACD and StochRSI are rendered in the compact, app-owned strip below so
  // the price pane keeps most of the available height.
  chart.setAttribute("store-settings", "false");
  // Hosted storage is shared by the browser, so account preferences use our API.
  chart.setAttribute("studies", studies);
  if (chartType) chart.setAttribute("chart-type", chartType);
  return chart;
}

export default function TradingViewWidget({ symbol, actionsContainer, onSymbolChange, readOnly = false }: { symbol: string; actionsContainer: HTMLElement | null; onSymbolChange?: (symbol: string) => void; readOnly?: boolean }) {
  const { user, hydrating } = useAccount();
  const [preference, setPreference] = usePreference("chart", defaultChartPreference, validChartPreference);
  const containerRef = useRef<HTMLDivElement>(null);
  const chartRef = useRef<HTMLElement>(null);
  const [options, setOptions] = useState<ChartOptions>({ interval: initialInterval, attempt: 0 });
  const [status, setStatus] = useState<ChartStatus>("loading");
  const buildChart = useEffectEvent((chartOptions: ChartOptions) => createChart(symbol, { ...chartOptions, ...preference, readOnly }));
  const reflectPreference = useEffectEvent((chart: HTMLElement) => {
    const interval = chart.getAttribute("interval") ?? initialInterval;
    const timeFrame = chart.getAttribute("time-frame") ?? undefined;
    const next = { interval, timeFrame };
    if (validChartPreference(next)) setPreference(next);
    const reflected = chart.getAttribute("symbol")?.match(/^BINANCE:([A-Z0-9]{1,30}USDT)\.P$/);
    if (reflected && reflected[1] !== symbol) onSymbolChange?.(reflected[1]);
  });

  useEffect(() => {
    const container = containerRef.current;
    if (!container || hydrating) return;

    const chart = buildChart(options);
    setStatus("loading");
    chartRef.current = chart;

    const timeout = window.setTimeout(() => setStatus("slow"), 15_000);
    let ready = false;
    const observer = new MutationObserver(() => { if (ready) reflectPreference(chart); });
    observer.observe(chart, { attributes: true, attributeFilter: ["interval", "time-frame", "symbol"] });
    const onReady = () => {
      window.clearTimeout(timeout);
      ready = true;
      setStatus("ready");
    };
    const onError = (event: Event) => {
      window.clearTimeout(timeout);
      const type = (event as CustomEvent<{ type: string }>).detail?.type;
      // Leave TradingView's controls available for symbol and interval errors.
      setStatus(type === "no-data" || type === "unsupported-interval" ? "ready" : "error");
    };
    chart.addEventListener("tv-widget-ready", onReady);
    chart.addEventListener("tv-widget-error", onError);
    container.append(chart);

    // The module loading successfully only means the custom element is defined.
    let script: HTMLScriptElement | undefined;
    if (!customElements.get(widgetTag)) {
      script = document.createElement("script");
      script.type = "module";
      script.src = options.attempt ? `${widgetScript}?retry=${options.attempt}` : widgetScript;
      const onScriptError = () => {
        window.clearTimeout(timeout);
        setStatus("error");
      };
      script.onerror = onScriptError;
      script.onload = () => {
        if (!customElements.get(widgetTag)) onScriptError();
      };
      document.head.append(script);
    }

    return () => {
      window.clearTimeout(timeout);
      observer.disconnect();
      if (script) {
        script.onload = null;
        script.onerror = null;
        script.remove();
      }
      chart.removeEventListener("tv-widget-ready", onReady);
      chart.removeEventListener("tv-widget-error", onError);
      chart.remove();
      chartRef.current = null;
    };
  }, [options, hydrating, user?.id, readOnly]);

  useEffect(() => {
    const chart = chartRef.current;
    if (!chart || hydrating) return;
    if (chart.getAttribute("interval") !== preference.interval) chart.setAttribute("interval", preference.interval);
    if (preference.timeFrame && chart.getAttribute("time-frame") !== preference.timeFrame) chart.setAttribute("time-frame", preference.timeFrame);
  }, [preference.interval, preference.timeFrame, hydrating]);

  useEffect(() => {
    // The TradingView component applies symbol changes to the existing chart.
    // Sending the study presets again would replace the current indicator choices.
    chartRef.current?.setAttribute("symbol", perpetualSymbol(symbol));
  }, [symbol]);

  function reloadChart() {
    const current = chartRef.current;
    setOptions((previous) => ({
      interval: current?.getAttribute("interval") ?? previous.interval,
      timeFrame: current?.getAttribute("time-frame") ?? previous.timeFrame,
      chartType: current?.getAttribute("chart-type") ?? previous.chartType,
      attempt: previous.attempt + 1,
    }));
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
      <div className="tradingview-stage">
        {status === "loading" && <div className="chart-widget-loading" role="status"><RefreshCw size={14} className="spin" /> 正在连接 TradingView…</div>}
        {(status === "slow" || status === "error") && (
          <div className={`chart-widget-notice ${status === "error" ? "chart-widget-error" : ""}`}>
            <p role="status">{status === "slow" ? "TradingView 图表响应较慢" : "TradingView 图表连接失败"}</p>
            <button className="chart-restore" type="button" onClick={reloadChart}>重试图表</button>
            <a href={chartUrl} target="_blank" rel="noreferrer">在 TradingView 打开 <ArrowUpRight size={13} aria-hidden="true" /></a>
          </div>
        )}
        <div ref={containerRef} className="tradingview-widget" />
        <CompactIndicatorStrip symbol={symbol} interval={preference.interval} />
      </div>
    </>
  );
}
