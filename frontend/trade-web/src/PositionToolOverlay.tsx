import { useEffect, useRef, useState } from "react";
import { ChevronDown, Trash2, X } from "lucide-react";
import type { IChartApi, ISeriesApi, Logical, Time } from "lightweight-charts";
import {
  calculatePositionMetrics,
  defaultPositionToolDefaults,
  isPositionTool,
  isPositionToolDefaults,
  type PositionDirection,
  type PositionTool,
  type PositionToolDefaults,
} from "./lib/positionTools";
import "./position-tools.css";

interface PositionToolOverlayProps {
  currentPrice: number;
  readOnly?: boolean;
  activeTool: PositionDirection | null;
  onActiveToolChange: (tool: PositionDirection | null) => void;
  activeLineTool: ChartLineOrientation | null;
  onActiveLineToolChange: (tool: ChartLineOrientation | null) => void;
  api: IChartApi | null;
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
function newId() { return `position-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`; }
function sanitizeDraft(draft: Draft): PositionTool {
  const minDistance = Math.max(0.00000001, draft.entryPrice * 0.002);
  const distance = Math.max(minDistance, Math.abs(draft.targetPrice - draft.entryPrice));
  const targetPrice = draft.direction === "long" ? draft.entryPrice + distance : draft.entryPrice - distance;
  const stopPrice = draft.direction === "long" ? draft.entryPrice - distance : draft.entryPrice + distance;
  const startTime = Math.min(draft.startTime, draft.endTime);
  const endTime = Math.max(draft.startTime, draft.endTime);
  return { id: newId(), direction: draft.direction, startTime, endTime: endTime > startTime ? endTime : startTime + 60, entryPrice: draft.entryPrice, targetPrice, stopPrice, createdAt: Date.now() };
}

function ToolCard({ position, currentPrice, defaults, selected, onSelect, onDelete }: { position: PositionTool; currentPrice: number; defaults: PositionToolDefaults; selected: boolean; onSelect: () => void; onDelete: () => void }) {
  const metrics = calculatePositionMetrics(position, currentPrice, defaults);
  return <button type="button" className={`position-tool-card ${selected ? "is-selected" : ""}`} onClick={onSelect}>
    <span className={`position-tool-card-dot ${position.direction}`} />
    <span><strong>{position.direction === "long" ? "多头" : "空头"}</strong><small>RR {metrics.riskReward.toFixed(2)} · 数量 {metrics.quantity.toFixed(defaults.qtyPrecision)}</small></span>
    <span className={metrics.openPnl >= 0 ? "position-positive" : "position-negative"}>{formatMoney(metrics.openPnl)}</span>
    <span className="position-tool-card-delete" role="button" tabIndex={0} aria-label="删除测量工具" onClick={(event) => { event.stopPropagation(); onDelete(); }} onKeyDown={(event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); event.stopPropagation(); onDelete(); } }}><Trash2 size={12} /></span>
  </button>;
}

export default function PositionToolOverlay({ currentPrice, readOnly = false, activeTool, onActiveToolChange, activeLineTool, onActiveLineToolChange, api }: PositionToolOverlayProps) {
  const [toolState, setToolState] = useState<PositionToolState>(() => readLocalToolState());
  const [chartLines, setChartLines] = useState<ChartLine[]>(() => readLocalChartLines());
  const [draft, setDraft] = useState<Draft | null>(null);
  const [dragHandle, setDragHandle] = useState<{ id: string; handle: ResizeHandle } | null>(null);
  const [moveDrag, setMoveDrag] = useState<MoveDrag | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [selectedLineId, setSelectedLineId] = useState<string | null>(null);
  const [lineMenu, setLineMenu] = useState<{ id: string; kind: "style" | "color" } | null>(null);
  const surfaceRef = useRef<HTMLDivElement>(null);
  const liveRef = useRef<{ draft: Draft | null; dragHandle: { id: string; handle: ResizeHandle } | null; moveDrag: MoveDrag | null; activeTool: PositionDirection | null; activeLineTool: ChartLineOrientation | null; readOnly: boolean; positions: PositionTool[] }>({ draft: null, dragHandle: null, moveDrag: null, activeTool: null, activeLineTool: null, readOnly: false, positions: [] });
  liveRef.current = { draft, dragHandle, moveDrag, activeTool, activeLineTool, readOnly, positions: toolState.positions };
  const defaults = toolState.defaults;
  const selectedPosition = toolState.positions.find((position) => position.id === selectedId) ?? null;
  const selectedMetrics = selectedPosition ? calculatePositionMetrics(selectedPosition, currentPrice, defaults) : null;

  const candleSeries: ISeriesApi<"Candlestick"> | undefined = api?.panes()[0]?.getSeries().find((s): s is ISeriesApi<"Candlestick"> => s.seriesType() === "Candlestick");
  const timeScale = api?.timeScale();
  const xToTime = (x: number): number | null => {
    const t = timeScale?.coordinateToTime(x);
    return t === null || t === undefined ? null : Number(t);
  };
  const yToPrice = (y: number): number | null => candleSeries?.coordinateToPrice(y) ?? null;
  const timeToX = (t: number): number | null => {
    const index = timeScale?.timeToIndex(t as Time, true);
    return index === null || index === undefined ? null : timeScale?.logicalToCoordinate(index as unknown as Logical) ?? null;
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
      const key = `${vr?.from},${vr?.to},${pr?.from},${pr?.to}`;
      if (key !== lastKey) { lastKey = key; setViewTick((tick) => tick + 1); }
      raf = requestAnimationFrame(sync);
    };
    raf = requestAnimationFrame(sync);
    return () => cancelAnimationFrame(raf);
  }, [api, candleSeries]);

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
      if ((event.target as HTMLElement).closest(".position-tool-resize-handle, .position-tool-edge, .position-tool-line, .position-tool-list, .position-tool-detail, .chart-line-tool, .chart-line-editor")) return;
      const live = liveRef.current;
      const point = dataPoint(event);
      if (!point) return;
      if (live.activeLineTool) {
        event.preventDefault();
        const line: ChartLine = live.activeLineTool === "horizontal"
          ? { id: newId(), orientation: "horizontal", price: point.p, color: LINE_COLORS[0], lineWidth: 1, lineStyle: "solid", createdAt: Date.now() }
          : { id: newId(), orientation: "vertical", time: point.t, color: LINE_COLORS[0], lineWidth: 1, lineStyle: "solid", createdAt: Date.now() };
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
        return px.x >= x1 && px.x <= x2 && px.y >= yTop && px.y <= yBottom;
      });
      if (hit) {
        event.preventDefault();
        setSelectedId(hit.id);
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
      updatePosition(live.dragHandle.id, (position) => {
        switch (live.dragHandle!.handle) {
          case "leftX": return { ...position, startTime: Math.min(point.t, position.endTime - 60) };
          case "rightX": return { ...position, endTime: Math.max(point.t, position.startTime + 60) };
          case "leftFree": return { ...position, startTime: Math.min(point.t, position.endTime - 60), entryPrice: point.p };
          case "entryY": return { ...position, entryPrice: point.p };
          case "targetY": return { ...position, targetPrice: point.p };
          default: return { ...position, stopPrice: point.p };
        }
      });
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
    const completed = finished ? sanitizeDraft(finished) : null;
    if (completed) {
      setToolState((state) => ({ ...state, positions: [...state.positions.slice(-11), completed] }));
      setSelectedId(completed.id);
    }
    setDraft(null);
    onActiveToolChange(null);
  }
  function updatePosition(id: string, update: (position: PositionTool) => PositionTool) { setToolState((state) => ({ ...state, positions: state.positions.map((position) => position.id === id ? update(position) : position) })); }
  function updateChartLine(id: string, update: (line: ChartLine) => ChartLine) { setChartLines((lines) => lines.map((line) => line.id === id ? update(line) : line)); }
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
    setDragHandle({ id, handle });
  }
  const previewPosition = draft ? sanitizeDraft(draft) : null;
  const renderedPositions = previewPosition ? [...toolState.positions, previewPosition] : toolState.positions;

  return <div className="position-tool-layer">
    <div className={`position-tool-surface ${activeTool ? "is-drawing" : ""}`} ref={surfaceRef}>
      {chartLines.map((line) => {
        const coordinate = line.orientation === "horizontal" && line.price !== undefined ? priceToY(line.price) : line.time !== undefined ? timeToX(line.time) : null;
        if (coordinate === null) return null;
        const selected = selectedLineId === line.id;
        const lineStyle = line.orientation === "horizontal"
          ? { top: coordinate, borderTop: `${line.lineWidth}px ${line.lineStyle} ${line.color}` }
          : { left: coordinate, borderLeft: `${line.lineWidth}px ${line.lineStyle} ${line.color}` };
        const editorStyle = line.orientation === "horizontal"
          ? { left: 8, top: -42 }
          : { left: 8, top: 8 };
        return <div key={line.id} className={`chart-line-tool ${line.orientation} ${selected ? "is-selected" : ""}`} style={lineStyle} onPointerDown={(event) => { event.preventDefault(); event.stopPropagation(); setSelectedLineId(line.id); setSelectedId(null); }}>
          {selected && <div className="chart-line-editor" style={editorStyle} onPointerDown={(event) => event.stopPropagation()}>
            <button type="button" onClick={() => setLineMenu((current) => current?.id === line.id && current.kind === "style" ? null : { id: line.id, kind: "style" })}>粗细/线型 <ChevronDown size={12} /></button>
            <button type="button" onClick={() => setLineMenu((current) => current?.id === line.id && current.kind === "color" ? null : { id: line.id, kind: "color" })}>颜色 <ChevronDown size={12} /></button>
            <button type="button" className="chart-line-delete" aria-label="删除线条" onClick={() => deleteChartLine(line.id)}><Trash2 size={13} /></button>
            {lineMenu?.id === line.id && lineMenu.kind === "style" && <div className="chart-line-menu">
              <span>粗细</span><div className="chart-line-options">{[1, 2, 3, 4].map((width) => <button key={width} type="button" className={line.lineWidth === width ? "is-active" : ""} onClick={() => updateChartLine(line.id, (current) => ({ ...current, lineWidth: width }))}>{width}px</button>)}</div>
              <span>线型</span><div className="chart-line-options"><button type="button" className={line.lineStyle === "solid" ? "is-active" : ""} onClick={() => updateChartLine(line.id, (current) => ({ ...current, lineStyle: "solid" }))}>实线</button><button type="button" className={line.lineStyle === "dashed" ? "is-active" : ""} onClick={() => updateChartLine(line.id, (current) => ({ ...current, lineStyle: "dashed" }))}>虚线</button></div>
            </div>}
            {lineMenu?.id === line.id && lineMenu.kind === "color" && <div className="chart-line-menu chart-line-color-menu"><span>颜色</span><div className="chart-line-options">{LINE_COLORS.map((color) => <button key={color} type="button" className={line.color === color ? "is-active" : ""} style={{ background: color }} aria-label={`选择颜色 ${color}`} onClick={() => updateChartLine(line.id, (current) => ({ ...current, color }))} />)}</div></div>}
          </div>}
        </div>;
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
          <div className="position-tool-stats" style={{ top: `${yEntry}px` }}>入场 {formatPrice(metrics.entryPrice)} · RR {metrics.riskReward.toFixed(2)} · {formatMoney(metrics.openPnl)}</div>
          {selected && !previewPosition && <div className="position-tool-handles">
            <button type="button" className="position-tool-resize-handle top-left" style={{ top: `${topHandleY}px` }} aria-label="调整上方高度" onPointerDown={(event) => beginHandle(event, position.id, topHandle)} />
            <button type="button" className="position-tool-resize-handle bottom-left" style={{ top: `${bottomHandleY}px` }} aria-label="调整下方高度" onPointerDown={(event) => beginHandle(event, position.id, bottomHandle)} />
            <button type="button" className="position-tool-resize-handle middle-left" style={{ top: `${yEntry}px` }} aria-label="自由移动左点" onPointerDown={(event) => beginHandle(event, position.id, "leftFree")} />
            <button type="button" className="position-tool-resize-handle middle-right" style={{ top: `${yEntry}px` }} aria-label="左右调整宽度" onPointerDown={(event) => beginHandle(event, position.id, "rightX")} />
          </div>}
        </div>;
      })}
    </div>
    <div className="position-tool-list" aria-label="已保存的测量工具">{toolState.positions.map((position) => <ToolCard key={position.id} position={position} currentPrice={currentPrice} defaults={defaults} selected={position.id === selectedId} onSelect={() => setSelectedId(position.id)} onDelete={() => { setToolState((state) => ({ ...state, positions: state.positions.filter((item) => item.id !== position.id) })); if (selectedId === position.id) setSelectedId(null); }} />)}</div>
    {selectedPosition && selectedMetrics && <div className="position-tool-detail"><div><strong>{selectedPosition.direction === "long" ? "多头计划" : "空头计划"}</strong><span>入场 {formatPrice(selectedMetrics.entryPrice)}</span></div><div><span>止盈 {formatPrice(selectedMetrics.targetPrice)}</span><span>止损 {formatPrice(selectedMetrics.stopPrice)}</span><span>RR {selectedMetrics.riskReward.toFixed(2)}</span></div><button type="button" aria-label="关闭测量详情" onClick={() => setSelectedId(null)}><X size={13} /></button></div>}
  </div>;
}
