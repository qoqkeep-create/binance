import { useEffect, useMemo, useRef, useState } from "react";
import type { CSSProperties, PointerEvent as ReactPointerEvent, ReactNode } from "react";
import { getKlines, type Candle } from "./lib/binance";
import { buildCompactIndicatorSeries, type CompactIndicatorPoint } from "./lib/compactIndicators";
import "./compact-indicators.css";

const DEFAULT_INDICATOR_HEIGHT = 108;
const MIN_INDICATOR_HEIGHT = 72;
const MAX_INDICATOR_HEIGHT = 260;
const INDICATOR_HEIGHT_STORAGE_KEY = "trade-web.compact-indicator-height";

function readIndicatorHeight() {
  try {
    const stored = Number(window.localStorage.getItem(INDICATOR_HEIGHT_STORAGE_KEY));
    if (Number.isFinite(stored)) return Math.min(MAX_INDICATOR_HEIGHT, Math.max(MIN_INDICATOR_HEIGHT, Math.round(stored)));
  } catch { /* storage can be unavailable in private contexts */ }
  return DEFAULT_INDICATOR_HEIGHT;
}

function saveIndicatorHeight(height: number) {
  try { window.localStorage.setItem(INDICATOR_HEIGHT_STORAGE_KEY, String(height)); } catch { /* keep the current-session setting */ }
}

const intervalMap: Record<string, string> = {
  "2": "2m", "3": "3m", "5": "5m", "15": "15m", "30": "30m", "60": "1h", "120": "2h", "240": "4h", D: "1d", "1D": "1d",
};

function formatValue(value: number | null, digits = 2) {
  if (value === null || !Number.isFinite(value)) return "—";
  return `${value >= 0 ? "+" : ""}${value.toFixed(digits)}`;
}

function pathFor(values: Array<number | null>, x: (index: number) => number, y: (value: number) => number) {
  let path = "";
  values.forEach((value, index) => {
    if (value === null || !Number.isFinite(value)) return;
    path += `${path ? " L" : "M"}${x(index).toFixed(2)},${y(value).toFixed(2)}`;
  });
  return path;
}

function PaneFrame({ label, value, children, className = "" }: { label: string; value: string; children: ReactNode; className?: string }) {
  return <section className={`compact-indicator-pane ${className}`} aria-label={label}>
    <div className="compact-indicator-caption"><strong>{label}</strong><span>{value}</span></div>
    {children}
  </section>;
}

function MiniIndicators({ series, crosshairTime, crosshairRatio, onCrosshairTimeChange }: { series: CompactIndicatorPoint[]; crosshairTime?: number | null; crosshairRatio?: number | null; onCrosshairTimeChange?: (time: number | null) => void }) {
  const containerRef = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(760);
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    const observer = new ResizeObserver(([entry]) => setWidth(Math.max(420, Math.round(entry.contentRect.width))));
    observer.observe(container);
    return () => observer.disconnect();
  }, []);

  const visible = useMemo(() => series.slice(-90), [series]);
  const [hoverIndex, setHoverIndex] = useState<number | null>(null);
  const left = 32;
  const right = width - 49;
  const height = 46;
  const top = 13;
  const bottom = 38;
  const x = (index: number) => left + (right - left) * index / Math.max(1, visible.length - 1);
  const macdValues = visible.map((point) => point.macd);
  const signalValues = visible.map((point) => point.signal);
  const histogramValues = visible.map((point) => point.histogram);
  const macdMax = Math.max(0.00000001, ...histogramValues.filter((value): value is number => value !== null).map(Math.abs), ...macdValues.filter((value): value is number => value !== null).map(Math.abs), ...signalValues.filter((value): value is number => value !== null).map(Math.abs));
  const macdY = (value: number) => top + (macdMax - value) / (macdMax * 2) * (bottom - top);
  const oscillatorY = (value: number) => top + (100 - value) / 100 * (bottom - top);
  const last = visible[visible.length - 1];
  const histogramWidth = Math.max(1, (right - left) / Math.max(visible.length, 1) * .75);

  useEffect(() => {
    if (crosshairRatio !== undefined && crosshairRatio !== null && visible.length) {
      setHoverIndex(Math.round(Math.max(0, Math.min(1, crosshairRatio)) * Math.max(0, visible.length - 1)));
      return;
    }
    if (crosshairTime === undefined || crosshairTime === null || !visible.length) {
      if (crosshairTime !== undefined) setHoverIndex(null);
      return;
    }
    let closest = 0;
    let distance = Infinity;
    visible.forEach((point, index) => {
      const nextDistance = Math.abs(point.time - crosshairTime);
      if (nextDistance < distance) { closest = index; distance = nextDistance; }
    });
    setHoverIndex(closest);
  }, [crosshairRatio, crosshairTime, visible]);

  function updateCrosshair(event: ReactPointerEvent<SVGSVGElement>) {
    if (!visible.length) return;
    const rect = event.currentTarget.getBoundingClientRect();
    const ratio = Math.max(0, Math.min(1, (event.clientX - rect.left) / Math.max(1, rect.width)));
    const index = Math.round(ratio * Math.max(0, visible.length - 1));
    setHoverIndex(index);
    onCrosshairTimeChange?.(visible[index]?.time ?? null);
  }

  function clearCrosshair() {
    setHoverIndex(null);
    onCrosshairTimeChange?.(null);
  }

  return <div className="compact-indicator-graphics" ref={containerRef}>
    <PaneFrame label="MACD 12 / 26 / 9" value={formatValue(last?.histogram ?? null)} className="compact-macd">
      <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`} role="img" aria-label="MACD 紧凑图" onPointerMove={updateCrosshair} onPointerLeave={clearCrosshair}>
        <line className="compact-zero-line" x1={left} x2={right} y1={macdY(0)} y2={macdY(0)} />
        {visible.map((point, index) => point.histogram === null ? null : <rect key={point.time} className={point.histogram >= 0 ? "compact-bar-up" : "compact-bar-down"} x={x(index) - histogramWidth / 2} y={Math.min(macdY(0), macdY(point.histogram))} width={histogramWidth} height={Math.max(.8, Math.abs(macdY(point.histogram) - macdY(0)))} rx=".5" />)}
        <path className="compact-macd-line" d={pathFor(macdValues, x, macdY)} />
        <path className="compact-signal-line" d={pathFor(signalValues, x, macdY)} />
        {hoverIndex !== null && <line className="compact-crosshair-line" x1={x(hoverIndex)} x2={x(hoverIndex)} y1={top} y2={bottom} />}
      </svg>
    </PaneFrame>
    <PaneFrame label="StochRSI 14 / 3 / 3" value={last?.stochK === null || last?.stochK === undefined ? "—" : `${last.stochK.toFixed(1)} / ${(last.stochD ?? 0).toFixed(1)}`} className="compact-stoch">
      <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`} role="img" aria-label="StochRSI 紧凑图" onPointerMove={updateCrosshair} onPointerLeave={clearCrosshair}>
        <line className="compact-threshold-line" x1={left} x2={right} y1={oscillatorY(80)} y2={oscillatorY(80)} />
        <line className="compact-threshold-line" x1={left} x2={right} y1={oscillatorY(20)} y2={oscillatorY(20)} />
        <path className="compact-k-line" d={pathFor(visible.map((point) => point.stochK), x, oscillatorY)} />
        <path className="compact-d-line" d={pathFor(visible.map((point) => point.stochD), x, oscillatorY)} />
        {hoverIndex !== null && <line className="compact-crosshair-line" x1={x(hoverIndex)} x2={x(hoverIndex)} y1={top} y2={bottom} />}
        <text className="compact-axis-label" x={right + 4} y={oscillatorY(80) + 3}>80</text>
        <text className="compact-axis-label" x={right + 4} y={oscillatorY(20) + 3}>20</text>
      </svg>
    </PaneFrame>
  </div>;
}

function sourceInterval(interval: string) {
  return intervalMap[interval] ?? "15m";
}

export default function CompactIndicatorStrip({ symbol, interval, onHeightChange, crosshairTime, crosshairRatio, onCrosshairTimeChange }: { symbol: string; interval: string; onHeightChange?: (height: number) => void; crosshairTime?: number | null; crosshairRatio?: number | null; onCrosshairTimeChange?: (time: number | null) => void }) {
  const [candles, setCandles] = useState<Candle[]>([]);
  const [loading, setLoading] = useState(true);
  const [failed, setFailed] = useState(false);
  const [height, setHeight] = useState(readIndicatorHeight);
  const source = sourceInterval(interval);

  useEffect(() => { onHeightChange?.(height); }, [height, onHeightChange]);

  function resizeStart(event: ReactPointerEvent<HTMLDivElement>) {
    event.preventDefault();
    event.currentTarget.setPointerCapture(event.pointerId);
    const startY = event.clientY;
    const startHeight = height;
    let currentHeight = startHeight;
    const move = (moveEvent: PointerEvent) => {
      const next = Math.min(MAX_INDICATOR_HEIGHT, Math.max(MIN_INDICATOR_HEIGHT, Math.round(startHeight + startY - moveEvent.clientY)));
      currentHeight = next;
      setHeight(next);
    };
    const end = () => {
      saveIndicatorHeight(currentHeight);
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", end);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", end, { once: true });
  }

  useEffect(() => {
    let active = true;
    const refresh = () => {
      setLoading(true);
      getKlines(symbol, source, 220).then((next) => {
        if (!active) return;
        setCandles(next);
        setFailed(false);
      }).catch(() => { if (active) setFailed(true); }).finally(() => { if (active) setLoading(false); });
    };
    refresh();
    const timer = window.setInterval(refresh, 60_000);
    return () => { active = false; window.clearInterval(timer); };
  }, [source, symbol]);

  const series = useMemo(() => buildCompactIndicatorSeries(candles), [candles]);
  return <div className="compact-indicator-strip" data-state={loading ? "loading" : failed ? "error" : "ready"} style={{ "--compact-indicators-height": `${height}px` } as CSSProperties}>
    <div className="compact-indicator-resize" role="slider" aria-label="调整附图高度" aria-valuemin={MIN_INDICATOR_HEIGHT} aria-valuemax={MAX_INDICATOR_HEIGHT} aria-valuenow={height} tabIndex={0} onPointerDown={resizeStart} onKeyDown={(event) => {
      if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return;
      event.preventDefault();
      const next = Math.min(MAX_INDICATOR_HEIGHT, Math.max(MIN_INDICATOR_HEIGHT, height + (event.key === "ArrowUp" ? 8 : -8)));
      setHeight(next);
      saveIndicatorHeight(next);
    }} />
    {series.length > 40 ? <MiniIndicators series={series} crosshairTime={crosshairTime} crosshairRatio={crosshairRatio} onCrosshairTimeChange={onCrosshairTimeChange} /> : <div className="compact-indicator-placeholder"><span>{loading ? "正在同步指标" : failed ? "指标暂时不可用" : "等待连续 K 线"}</span></div>}
  </div>;
}
