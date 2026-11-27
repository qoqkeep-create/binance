import { useEffect, useRef, useState } from "react";
import { ChevronDown, Trash2 } from "lucide-react";
import type { IChartApi, ISeriesApi, Logical } from "lightweight-charts";
import {
  calculatePositionMetrics,
  defaultPositionToolDefaults,
  isPositionTool,
  isPositionToolDefaults,
  type PositionDirection,
  type PositionTool,
  type PositionToolDefaults,
} from "./lib/positionTools";
import { priceScaleFormatter } from "./lib/priceFormat";
import "./position-tools.css";

interface PositionToolOverlayProps {
  currentPrice: number;
  readOnly?: boolean;
  activeTool: PositionDirection | null;
  onActiveToolChange: (tool: PositionDirection | null) => void;
  activeLineTool: ChartLineOrientation | null;
  onActiveLineToolChange: (tool: ChartLineOrientation | null) => void;
  api: IChartApi | null;
  clearSignal?: number;
}

export type ChartLineOrientation = "horizontal" | "vertical";
type ChartLineStyle = "solid" | "dashed";
type ChartLine = { id: string; orientation: ChartLineOrientation; time?: number; price?: number; color: string; lineWidth: number; lineStyle: ChartLineStyle; createdAt: number };
type Draft = Omit<PositionTool, "id" | "createdAt">;
type PositionToolState = { defaults: PositionToolDefaults; positions: PositionTool[] };
type ResizeHandle = "entryY" | "targetY" | "stopY" | "leftX" | "rightX" | "leftFree";
type MoveDrag = { id: string; startTime: number; startPrice: number; origin: PositionTool };
const toolsPreferenceFallback: PositionToolState = { defaults: defaultPositionToolDefaults, positions: [] };
const LOCAL_STORAGE_KEY = "trade-web-position-tools-v2";
const LINE_STORAGE_KEY = "trade-web-chart-lines-v1";
const LINE_COLORS = ["#2EBD85", "#F6465D", "#2D7FF9", "#F5B942", "#FFFFFF"];
const formatPrice = (value: number) => value >= 1000 ? value.toLocaleString("en-US", { maximumFractionDigits: 2 }) : value >= 1 ? value.toFixed(4) : value.toFixed(6);
const formatMoney = (value: number) => `${value >= 0 ? "+" : "−"}${Math.abs(value).toFixed(2)}`;
const clamp = (value: number, minimum: number, maximum: number) => Math.min(maximum, Math.max(minimum, value));

function validToolState(value: unknown): value is PositionToolState {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const state = value as { defaults?: unknown; positions?: unknown };
  return isPositionToolDefaults(state.defaults) && Array.isArray(state.positions) && state.positions.length <= 12 && state.positions.every(isPositionTool);
}
function readLocalToolState(): PositionToolState {
  try {
    const raw = window.localStorage.getItem(LOCAL_STORAGE_KEY);
    if (!raw) return toolsPreferenceFallback;
    const parsed: unknown = JSON.parse(raw);
    return validToolState(parsed) ? parsed : toolsPreferenceFallback;
  } catch {
    return toolsPreferenceFallback;
  }
}
function isChartLine(value: unknown): value is ChartLine {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const line = value as Partial<ChartLine>;
  return typeof line.id === "string" && line.id.length > 0 && line.id.length <= 80
    && (line.orientation === "horizontal" || line.orientation === "vertical")
    && (line.orientation === "horizontal" ? typeof line.price === "number" && Number.isFinite(line.price) && line.price > 0 : typeof line.time === "number" && Number.isFinite(line.time))
    && typeof line.color === "string" && LINE_COLORS.includes(line.color)
    && typeof line.lineWidth === "number" && [1, 2, 3, 4].includes(line.lineWidth)
    && (line.lineStyle === "solid" || line.lineStyle === "dashed")
    && typeof line.createdAt === "number" && Number.isFinite(line.createdAt);
}
function readLocalChartLines(): ChartLine[] {
  try {
    const raw = window.localStorage.getItem(LINE_STORAGE_KEY);
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) && parsed.length <= 48 && parsed.every(isChartLine) ? parsed : [];
  } catch {
    return [];
  }
}
const LINE_DEFAULTS_KEY = "trade-web-chart-line-defaults";
type LineDefaults = { color: string; lineWidth: number; lineStyle: ChartLineStyle };
function readLineDefaults(): LineDefaults {
  const fallback: LineDefaults = { color: LINE_COLORS[0], lineWidth: 1, lineStyle: "solid" };
  try {
    const raw = window.localStorage.getItem(LINE_DEFAULTS_KEY);
    if (!raw) return fallback;
    const parsed = JSON.parse(raw) as Partial<LineDefaults>;
    return {
      color: typeof parsed.color === "string" && LINE_COLORS.includes(parsed.color) ? parsed.color : fallback.color,
      lineWidth: [1, 2, 3, 4].includes(parsed.lineWidth as number) ? parsed.lineWidth as number : 1,
      lineStyle: parsed.lineStyle === "dashed" ? "dashed" : "solid",
    };
  } catch { return fallback; }
}
function saveLineDefaults(next: LineDefaults) { try { window.localStorage.setItem(LINE_DEFAULTS_KEY, JSON.stringify(next)); } catch { /* keep session value */ } }

function newId() { return `position-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`; }
// 中线不得越过止盈/止损两条边线：距两边各 5% 区间边缘即锁死。
function clampEntryToEdges(position: PositionTool, price: number): number {
  const span = Math.abs(position.targetPrice - position.stopPrice);
  const lo = Math.min(position.targetPrice, position.stopPrice) + span * 0.05;
  const hi = Math.max(position.targetPrice, position.stopPrice) - span * 0.05;
  return Math.min(hi, Math.max(lo, price));
}
function sanitizeDraft(draft: Draft, minSpan = 60): PositionTool {
  const minDistance = Math.max(0.00000001, draft.entryPrice * 0.002);
  const distance = Math.max(minDistance, Math.abs(draft.targetPrice - draft.entryPrice));
  const targetPrice = draft.direction === "long" ? draft.entryPrice + distance : draft.entryPrice - distance;
  const stopPrice = draft.direction === "long" ? draft.entryPrice - distance : draft.entryPrice + distance;
  const startTime = Math.min(draft.startTime, draft.endTime);
  const endTime = Math.max(draft.startTime, draft.endTime);
  return { id: newId(), direction: draft.direction, startTime, endTime: endTime >= startTime + minSpan ? endTime : startTime + minSpan, entryPrice: draft.entryPrice, targetPrice, stopPrice, createdAt: Date.now() };
}

export default function PositionToolOverlay({ currentPrice, readOnly = false, activeTool, onActiveToolChange, activeLineTool, onActiveLineToolChange, api, clearSignal = 0 }: PositionToolOverlayProps) {
  const [toolState, setToolState] = useState<PositionToolState>(() => readLocalToolState());
  const [chartLines, setChartLines] = useState<ChartLine[]>(() => readLocalChartLines());
  const [draft, setDraft] = useState<Draft | null>(null);
  const [dragHandle, setDragHandle] = useState<{ id: string; handle: ResizeHandle } | null>(null);
  const [moveDrag, setMoveDrag] = useState<MoveDrag | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [selectedLineId, setSelectedLineId] = useState<string | null>(null);
  const [lineMenu, setLineMenu] = useState<{ id: string; kind: "width" | "lineStyle" | "color" } | null>(null);
  const [lineDefaults, setLineDefaults] = useState<LineDefaults>(readLineDefaults);
  const [lineDrag, setLineDrag] = useState<{ id: string; orientation: ChartLineOrientation } | null>(null);
  const lineDefaultsRef = useRef(lineDefaults);
  lineDefaultsRef.current = lineDefaults;
  const surfaceRef = useRef<HTMLDivElement>(null);
  const liveRef = useRef<{ draft: Draft | null; dragHandle: { id: string; handle: ResizeHandle } | null; moveDrag: MoveDrag | null; lineDrag: { id: string; orientation: ChartLineOrientation } | null; activeTool: PositionDirection | null; activeLineTool: ChartLineOrientation | null; readOnly: boolean; positions: PositionTool[] }>({ draft: null, dragHandle: null, moveDrag: null, lineDrag: null, activeTool: null, activeLineTool: null, readOnly: false, positions: [] });
  liveRef.current = { draft, dragHandle, moveDrag, lineDrag, activeTool, activeLineTool, readOnly, positions: toolState.positions };
  const defaults = toolState.defaults;
  const selectedPosition = toolState.positions.find((position) => position.id === selectedId) ?? null;
  const selectedMetrics = selectedPosition ? calculatePositionMetrics(selectedPosition, currentPrice, defaults) : null;

  const candleSeries: ISeriesApi<"Candlestick"> | undefined = api?.panes()[0]?.getSeries().find((s): s is ISeriesApi<"Candlestick"> => s.seriesType() === "Candlestick");
  const timeScale = api?.timeScale();
  // 换算必须每次调用实时读 data()：指针监听只注册一次，捕获旧快照会在切周期后
  // 用错末根时间/周期差（中间区命中失效、拖不动、工具飞出屏幕）。
  const timeGrid = () => {
    const data = candleSeries?.data() ?? [];
    if (!data.length) return null;
    const lastIdx = data.length - 1;
    const lastTime = Number(data[lastIdx].time);
    const interval = data.length > 1 ? Number(data[1].time) - Number(data[0].time) : 60;
    return { lastIdx, lastTime, interval };
  };
  // 右侧空白区同属 K 线显示区：库 coordinateToTime/timeToIndex 只认有数据的根，
  // 按周期等差外推逻辑坐标，空白区可绘制可移动。
  const xToTime = (x: number): number | null => {
    const grid = timeGrid();
    if (!grid || !timeScale) return null;
    const logical = timeScale.coordinateToLogical(x);
    if (logical === null || logical === undefined) return null;
    return grid.lastTime + (Math.round(logical) - grid.lastIdx) * grid.interval;
  };
  const yToPrice = (y: number): number | null => candleSeries?.coordinateToPrice(y) ?? null;
  const timeToX = (t: number): number | null => {
    const grid = timeGrid();
    if (!grid || !timeScale) return null;
    // logicalToCoordinate 对非整数逻辑坐标返回 0：低周期工具切到高周期时时间不落网格，
    // 必须取整到最近根（与 xToTime 的 round 对称），否则 x 被打成 0＝贴左缘细条。
    const logical = Math.round(grid.lastIdx + (t - grid.lastTime) / grid.interval);
    return timeScale.logicalToCoordinate(logical as unknown as Logical);
  };
  const priceToY = (p: number): number | null => candleSeries?.priceToCoordinate(p) ?? null;

  const [, setViewTick] = useState(0);
  useEffect(() => {
    if (!api || !candleSeries) return;
    let raf = 0;
    let lastKey = "";
    const sync = () => {
      const vr = api.timeScale().getVisibleLogicalRange();
      const pr = candleSeries.priceScale().getVisibleRange();
      const data = candleSeries.data();
      const last = data.length ? Number(data[data.length - 1].time) : 0;
      const first = data.length ? Number(data[0].time) : 0;
      const key = `${vr?.from},${vr?.to},${pr?.from},${pr?.to},${data.length},${first},${last}`;
      if (key !== lastKey) { lastKey = key; setViewTick((tick) => tick + 1); }
      raf = requestAnimationFrame(sync);
    };
    raf = requestAnimationFrame(sync);
    return () => cancelAnimationFrame(raf);
  }, [api, candleSeries]);

  useEffect(() => {
    if (!clearSignal) return;
    setToolState((state) => ({ ...state, positions: [] }));
    setChartLines([]);
    setSelectedId(null);
    setSelectedLineId(null);
    setLineMenu(null);
    setDraft(null);
  }, [clearSignal]);

  useEffect(() => {
    try { window.localStorage.setItem(LOCAL_STORAGE_KEY, JSON.stringify(toolState)); } catch { /* storage can be unavailable in private contexts */ }
  }, [toolState]);
  useEffect(() => {
    try { window.localStorage.setItem(LINE_STORAGE_KEY, JSON.stringify(chartLines)); } catch { /* storage can be unavailable in private contexts */ }
  }, [chartLines]);

  useEffect(() => {
    if (!activeTool && !activeLineTool) return;
    const handleKey = (event: KeyboardEvent) => { if (event.key === "Escape") { onActiveToolChange(null); onActiveLineToolChange(null); setDraft(null); setLineMenu(null); } };
    document.addEventListener("keydown", handleKey);
    return () => document.removeEventListener("keydown", handleKey);
  }, [activeTool, activeLineTool, onActiveToolChange, onActiveLineToolChange]);

  function pixelPoint(event: { clientX: number; clientY: number }) {
    const rect = surfaceRef.current?.getBoundingClientRect();
    if (!rect) return null;
    return { x: event.clientX - rect.left, y: event.clientY - rect.top };
  }
  function dataPoint(event: { clientX: number; clientY: number }) {
    const point = pixelPoint(event);
    if (!point) return null;
    const t = xToTime(point.x);
    const p = yToPrice(point.y);
    if (t === null || p === null) return null;
    return { t, p };
  }
  useEffect(() => {
    const down = (event: PointerEvent) => {
      if ((event.target as HTMLElement).closest(".position-tool-resize-handle, .position-tool-edge, .position-tool-line, .position-tool-detail, .chart-line-tool, .chart-line-editor")) return;
      const live = liveRef.current;
      const point = dataPoint(event);
      if (!point) return;
      if (live.activeLineTool) {
        event.preventDefault();
        const preset = lineDefaultsRef.current;
        const line: ChartLine = live.activeLineTool === "horizontal"
          ? { id: newId(), orientation: "horizontal", price: point.p, color: preset.color, lineWidth: preset.lineWidth, lineStyle: preset.lineStyle, createdAt: Date.now() }
          : { id: newId(), orientation: "vertical", time: point.t, color: preset.color, lineWidth: preset.lineWidth, lineStyle: preset.lineStyle, createdAt: Date.now() };
        setChartLines((current) => [...current.slice(-47), line]);
        setSelectedLineId(line.id);
        onActiveLineToolChange(null);
        return;
      }
      if (live.activeTool) {
        event.preventDefault();
        setDraft({ direction: live.activeTool, startTime: point.t, endTime: point.t, entryPrice: point.p, targetPrice: point.p, stopPrice: point.p });
        return;
      }
      if (live.readOnly) return;
      const hit = live.positions.find((pos) => {
        const x1 = timeToX(pos.startTime); const x2 = timeToX(pos.endTime);
        const yTop = priceToY(Math.max(pos.entryPrice, pos.targetPrice, pos.stopPrice));
        const yBottom = priceToY(Math.min(pos.entryPrice, pos.targetPrice, pos.stopPrice));
        const px = pixelPoint(event);
        if (x1 === null || x2 === null || yTop === null || yBottom === null || !px) return false;
        return px.x >= x1 && px.x <= Math.max(x2, x1 + 8) && px.y >= yTop && px.y <= yBottom;
      });
      if (hit) {
        event.preventDefault();
        setSelectedId(hit.id);
        clearLineSelection();
        setMoveDrag({ id: hit.id, startTime: point.t, startPrice: point.p, origin: hit });
      } else {
        setSelectedId(null);
        setSelectedLineId(null);
        setLineMenu(null);
      }
    };
    const move = (event: PointerEvent) => handlePointerMove(event);
    const up = (event: PointerEvent) => handlePointerUp(event);
    window.addEventListener("pointerdown", down);
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    return () => {
      window.removeEventListener("pointerdown", down);
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
    };
  }, []);
  useEffect(() => {
    const container = surfaceRef.current?.closest(".kline-container") as HTMLElement | null;
    if (container) container.style.cursor = activeTool ? "crosshair" : "";
  }, [activeTool]);

  function handlePointerMove(event: { clientX: number; clientY: number }) {
    const live = liveRef.current;
    const point = dataPoint(event);
    if (live.dragHandle) {
      if (!point) return;
      const minSpan = timeGrid()?.interval ?? 60;
      updatePosition(live.dragHandle.id, (position) => {
        switch (live.dragHandle!.handle) {
          case "leftX": return { ...position, startTime: Math.min(point.t, position.endTime - minSpan) };
          case "rightX": return { ...position, endTime: Math.max(point.t, position.startTime + minSpan) };
          case "leftFree": return { ...position, startTime: Math.min(point.t, position.endTime - minSpan), entryPrice: clampEntryToEdges(position, point.p) };
          case "entryY": return { ...position, entryPrice: clampEntryToEdges(position, point.p) };
          case "targetY": return { ...position, targetPrice: point.p };
          default: return { ...position, stopPrice: point.p };
        }
      });
      return;
    }
    if (live.lineDrag) {
      if (!point) return;
      const drag = live.lineDrag;
      setChartLines((lines) => lines.map((line) => line.id === drag.id ? (drag.orientation === "horizontal" ? { ...line, price: point.p } : { ...line, time: point.t }) : line));
      return;
    }
    if (live.moveDrag) {
      if (!point) return;
      const origin = live.moveDrag.origin;
      const dt = point.t - live.moveDrag.startTime;
      const dp = point.p - live.moveDrag.startPrice;
      setToolState((state) => ({
        ...state,
        positions: state.positions.map((position) => position.id === live.moveDrag!.id
          ? { ...origin, startTime: origin.startTime + dt, endTime: origin.endTime + dt, entryPrice: Math.max(0.00000001, origin.entryPrice + dp), targetPrice: Math.max(0.00000001, origin.targetPrice + dp), stopPrice: Math.max(0.00000001, origin.stopPrice + dp) }
          : position),
      }));
      return;
    }
    if (!live.draft) return;
    if (point) setDraft((previous) => previous ? { ...previous, endTime: point.t, targetPrice: point.p, stopPrice: point.p } : previous);
  }
  function handlePointerUp(event: { clientX: number; clientY: number }) {
    const live = liveRef.current;
    if (live.dragHandle) { setDragHandle(null); return; }
    if (live.lineDrag) { setLineDrag(null); document.body.style.cursor = ""; return; }
    if (live.moveDrag) { setMoveDrag(null); return; }
    if (!live.draft) return;
    const point = dataPoint(event);
    let finished: Draft | null = point ? { ...live.draft, endTime: point.t, targetPrice: point.p, stopPrice: point.p } : null;
    // 单击（未拖动）落一个初始尺寸框：宽＝可见根数 18%（按周期换算成整根）、高＝主图高上下各 15%，保持同层。
    if (finished && point && point.t === live.draft.startTime && point.p === live.draft.entryPrice) {
      const px = pixelPoint(event);
      const surface = surfaceRef.current;
      const data = candleSeries?.data() ?? [];
      const interval = data.length > 1 ? Number(data[1].time) - Number(data[0].time) : 60;
      const vr = timeScale?.getVisibleLogicalRange();
      const bars = Math.max(2, Math.round((vr ? vr.to - vr.from : 80) * 0.18));
      const pUp = px && surface ? yToPrice(px.y - surface.clientHeight * 0.15) : null;
      if (pUp !== null) {
        const distance = Math.abs(pUp - finished.entryPrice);
        finished = { ...finished, endTime: finished.startTime + bars * interval, targetPrice: finished.entryPrice + distance, stopPrice: finished.entryPrice - distance };
      }
    }
    const completed = finished ? sanitizeDraft(finished, timeGrid()?.interval ?? 60) : null;
    if (completed) {
      setToolState((state) => ({ ...state, positions: [...state.positions.slice(-11), completed] }));
      setSelectedId(completed.id);
      clearLineSelection();
    }
    setDraft(null);
    onActiveToolChange(null);
  }
  function updatePosition(id: string, update: (position: PositionTool) => PositionTool) { setToolState((state) => ({ ...state, positions: state.positions.map((position) => position.id === id ? update(position) : position) })); }
  function updateChartLine(id: string, update: (line: ChartLine) => ChartLine) { setChartLines((lines) => lines.map((line) => line.id === id ? update(line) : line)); }
  function changeLineStyle(id: string, patch: Partial<LineDefaults>) {
    setChartLines((lines) => lines.map((line) => line.id === id ? { ...line, ...patch } : line));
    setLineDefaults((current) => { const next = { ...current, ...patch }; saveLineDefaults(next); return next; });
  }
  function deleteChartLine(id: string) {
    setChartLines((lines) => lines.filter((line) => line.id !== id));
    if (selectedLineId === id) setSelectedLineId(null);
    setLineMenu(null);
  }
  function beginHandle(event: React.PointerEvent, id: string, handle: ResizeHandle) {
    if (draft) return;
    event.stopPropagation();
    event.preventDefault();
    setSelectedId(id);
    clearLineSelection();
    setDragHandle({ id, handle });
  }
  function clearLineSelection() { setSelectedLineId(null); setLineMenu(null); }
  const previewPosition = draft ? sanitizeDraft(draft, timeGrid()?.interval ?? 60) : null;
  const renderedPositions = previewPosition ? [...toolState.positions, previewPosition] : toolState.positions;
  const selectedLine = chartLines.find((line) => line.id === selectedLineId) ?? null;

  return <div className="position-tool-layer">
    <div className={`position-tool-surface ${activeTool ? "is-drawing" : ""}`} ref={surfaceRef}>
      {chartLines.map((line) => {
        const coordinate = line.orientation === "horizontal" && line.price !== undefined ? priceToY(line.price) : line.time !== undefined ? timeToX(line.time) : null;
        if (coordinate === null) return null;
        const selected = selectedLineId === line.id;
        const lineStyle = line.orientation === "horizontal"
          ? { top: coordinate, borderTop: `${line.lineWidth}px ${line.lineStyle} ${line.color}` }
          : { left: coordinate, borderLeft: `${line.lineWidth}px ${line.lineStyle} ${line.color}` };
        return <div key={line.id} className={`chart-line-tool ${line.orientation} ${selected ? "is-selected" : ""}`} style={lineStyle} onPointerDown={(event) => {
          event.preventDefault();
          event.stopPropagation();
          setSelectedLineId(line.id);
          setSelectedId(null);
          if (readOnly) return;
          const point = dataPoint(event);
          if (!point) return;
          setLineDrag({ id: line.id, orientation: line.orientation });
          document.body.style.cursor = "grabbing";
        }} />;
      })}
      {renderedPositions.map((position) => {
        const metrics = calculatePositionMetrics(position, currentPrice, defaults);
        const selected = position.id === selectedId;
        const x1 = timeToX(position.startTime);
        const x2 = timeToX(position.endTime);
        const yEntry = priceToY(position.entryPrice);
        const yTarget = priceToY(position.targetPrice);
        const yStop = priceToY(position.stopPrice);
        if (x1 === null || x2 === null || yEntry === null || yTarget === null || yStop === null) return null;
        const left = `${x1}px`;
        const width = `${Math.max(8, x2 - x1)}px`;
        const targetTop = `${Math.min(yTarget, yEntry)}px`;
        const targetHeight = `${Math.abs(yTarget - yEntry)}px`;
        const stopTop = `${Math.min(yStop, yEntry)}px`;
        const stopHeight = `${Math.abs(yStop - yEntry)}px`;
        const boxTop = `${Math.min(yTarget, yStop, yEntry)}px`;
        const boxHeight = `${Math.max(yTarget, yStop, yEntry) - Math.min(yTarget, yStop, yEntry)}px`;
        const topHandle: "targetY" | "stopY" = yTarget < yStop ? "targetY" : "stopY";
        const bottomHandle: "targetY" | "stopY" = topHandle === "targetY" ? "stopY" : "targetY";
        const topHandleY = Math.min(yTarget, yStop);
        const bottomHandleY = Math.max(yTarget, yStop);
        const interactive = selected;
        return <div key={position.id} className={`position-tool-drawing ${position.direction} ${selected ? "is-selected" : ""}`} style={{ left, width }}>
          <div className="position-tool-zone target" style={{ top: targetTop, height: targetHeight }} /><div className="position-tool-zone stop" style={{ top: stopTop, height: stopHeight }} />
          <div className="position-tool-edge left-edge" style={{ top: boxTop, height: boxHeight }} onPointerDown={(event) => beginHandle(event, position.id, "leftX")} />
          <div className="position-tool-edge right-edge" style={{ top: boxTop, height: boxHeight }} onPointerDown={(event) => beginHandle(event, position.id, "rightX")} />
          <div className="position-tool-line entry" style={{ top: `${yEntry}px` }} onPointerDown={(event) => beginHandle(event, position.id, "entryY")} />
          <div className="position-tool-line target-line" style={{ top: `${yTarget}px` }} onPointerDown={(event) => beginHandle(event, position.id, "targetY")}>
            {interactive && <span>止盈 {formatPrice(metrics.targetPrice)}</span>}
          </div>
          <div className="position-tool-line stop-line" style={{ top: `${yStop}px` }} onPointerDown={(event) => beginHandle(event, position.id, "stopY")}>
            {interactive && <span>止损 {formatPrice(metrics.stopPrice)}</span>}
          </div>
          {selected && <div className="position-tool-stats" style={{ top: `${yEntry}px` }}>入场 {formatPrice(metrics.entryPrice)} · RR {metrics.riskReward.toFixed(2)} · {formatMoney(metrics.openPnl)}</div>}
          {selected && !previewPosition && <div className="position-tool-handles">
            <button type="button" className="position-tool-resize-handle top-left" style={{ top: `${topHandleY}px` }} aria-label="调整上方高度" onPointerDown={(event) => beginHandle(event, position.id, topHandle)} />
            <button type="button" className="position-tool-resize-handle bottom-left" style={{ top: `${bottomHandleY}px` }} aria-label="调整下方高度" onPointerDown={(event) => beginHandle(event, position.id, bottomHandle)} />
            <button type="button" className="position-tool-resize-handle middle-left" style={{ top: `${yEntry}px` }} aria-label="自由移动左点" onPointerDown={(event) => beginHandle(event, position.id, "leftFree")} />
            <button type="button" className="position-tool-resize-handle middle-right" style={{ top: `${yEntry}px` }} aria-label="左右调整宽度" onPointerDown={(event) => beginHandle(event, position.id, "rightX")} />
          </div>}
        </div>;
      })}
      {selectedLine && <div className="chart-line-editor chart-line-editor-center" onPointerDown={(event) => event.stopPropagation()}>
        <button type="button" aria-label="线条粗细" onClick={() => setLineMenu((current) => current?.id === selectedLine.id && current.kind === "width" ? null : { id: selectedLine.id, kind: "width" })}><span className="pd-line-sample" style={{ borderTopWidth: `${selectedLine.lineWidth}px`, borderTopStyle: selectedLine.lineStyle === "dashed" ? "dashed" : "solid", borderTopColor: selectedLine.color }} />{selectedLine.lineWidth}px <ChevronDown size={12} /></button>
        <button type="button" aria-label="线型实虚" onClick={() => setLineMenu((current) => current?.id === selectedLine.id && current.kind === "lineStyle" ? null : { id: selectedLine.id, kind: "lineStyle" })}><span className="pd-line-sample" style={{ borderTopStyle: selectedLine.lineStyle === "dashed" ? "dashed" : "solid" }} /> <ChevronDown size={12} /></button>
        <button type="button" aria-label="线条颜色" onClick={() => setLineMenu((current) => current?.id === selectedLine.id && current.kind === "color" ? null : { id: selectedLine.id, kind: "color" })}><span className="pd-color-swatch" style={{ background: selectedLine.color }} /> <ChevronDown size={12} /></button>
        <button type="button" className="chart-line-delete" aria-label="删除线条" onClick={() => deleteChartLine(selectedLine.id)}><Trash2 size={13} /></button>
        {lineMenu?.id === selectedLine.id && lineMenu.kind === "width" && <div className="chart-line-menu">
          <span>粗细</span><div className="chart-line-options">{[1, 2, 3, 4].map((width) => <button key={width} type="button" className={selectedLine.lineWidth === width ? "is-active" : ""} onClick={() => changeLineStyle(selectedLine.id, { lineWidth: width })}><span className="pd-line-sample" style={{ borderTopWidth: `${width}px`, borderTopColor: selectedLine.color }} />{width}px</button>)}</div>
        </div>}
        {lineMenu?.id === selectedLine.id && lineMenu.kind === "lineStyle" && <div className="chart-line-menu">
          <span>线型</span><div className="chart-line-options"><button type="button" className={selectedLine.lineStyle === "solid" ? "is-active" : ""} onClick={() => changeLineStyle(selectedLine.id, { lineStyle: "solid" })}><span className="pd-line-sample" />实线</button><button type="button" className={selectedLine.lineStyle === "dashed" ? "is-active" : ""} onClick={() => changeLineStyle(selectedLine.id, { lineStyle: "dashed" })}><span className="pd-line-sample is-dashed" />虚线</button></div>
        </div>}
        {lineMenu?.id === selectedLine.id && lineMenu.kind === "color" && <div className="chart-line-menu chart-line-color-menu"><span>颜色</span><div className="chart-line-options">{LINE_COLORS.map((color) => <button key={color} type="button" className={selectedLine.color === color ? "is-active" : ""} style={{ background: color }} aria-label={`选择颜色 ${color}`} onClick={() => changeLineStyle(selectedLine.id, { color })} />)}</div></div>}
      </div>}
      {selectedPosition && selectedMetrics && <div className="chart-line-editor position-tool-detail"><span className="chart-line-editor-item is-title">{selectedPosition.direction === "long" ? "多头计划" : "空头计划"}</span><span className="chart-line-editor-item">入场 {formatPrice(selectedMetrics.entryPrice)}</span><span className="chart-line-editor-item">止盈 {formatPrice(selectedMetrics.targetPrice)}</span><span className="chart-line-editor-item">止损 {formatPrice(selectedMetrics.stopPrice)}</span><span className="chart-line-editor-item">RR {selectedMetrics.riskReward.toFixed(2)}</span><button type="button" aria-label="删除测量工具" onClick={() => { setToolState((state) => ({ ...state, positions: state.positions.filter((item) => item.id !== selectedPosition.id) })); setSelectedId(null); }}><Trash2 size={13} /></button></div>}
    </div>
    {chartLines.map((line) => {
      if (line.orientation !== "horizontal" || line.price === undefined) return null;
      const y = priceToY(line.price);
      const mainHeight = surfaceRef.current?.clientHeight ?? 0;
      if (y === null || y < 0 || y > mainHeight) return null;
      return <div key={`axis-${line.id}`} className="chart-line-axis-tag" style={{ top: y, background: line.color, color: line.color === "#FFFFFF" ? "#181a1d" : "#ffffff" }}>{priceScaleFormatter(line.price)}</div>;
    })}
  </div>;
}
