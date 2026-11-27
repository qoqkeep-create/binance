import { useEffect, useRef, useState } from "react";
import { Trash2, X } from "lucide-react";
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
}

type Draft = { direction: PositionDirection; startX: number; startY: number; endX: number; endY: number };
type PositionToolState = { defaults: PositionToolDefaults; positions: PositionTool[] };
type ResizeHandle = "entryY" | "targetY" | "stopY" | "leftX" | "rightX" | "leftFree";
type MoveDrag = { id: string; startX: number; startY: number; origin: PositionTool };
const toolsPreferenceFallback: PositionToolState = { defaults: defaultPositionToolDefaults, positions: [] };
const LOCAL_STORAGE_KEY = "trade-web-position-tools";
const MIN_POSITION_DISTANCE = 0.1;
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
function newId() { return `position-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`; }
function sanitizeDraft(draft: Draft, direction: PositionDirection): PositionTool {
  const left = clamp(Math.min(draft.startX, draft.endX), 0.02, 0.95);
  const right = clamp(Math.max(draft.startX, draft.endX), left + 0.05, 0.98);
  const entryY = clamp(draft.startY, 0.05, 0.95);
  const availableDistance = Math.max(0.01, Math.min(entryY - 0.01, 0.99 - entryY));
  const distance = Math.min(availableDistance, Math.max(MIN_POSITION_DISTANCE, Math.abs(draft.endY - entryY)));
  const targetY = direction === "long" ? entryY - distance : entryY + distance;
  const stopY = direction === "long" ? entryY + distance : entryY - distance;
  return { id: newId(), direction, left, right, entryY, targetY, stopY, createdAt: Date.now() };
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

export default function PositionToolOverlay({ currentPrice, readOnly = false, activeTool, onActiveToolChange }: PositionToolOverlayProps) {
  const [toolState, setToolState] = useState<PositionToolState>(() => readLocalToolState());
  const [draft, setDraft] = useState<Draft | null>(null);
  const [dragHandle, setDragHandle] = useState<{ id: string; handle: ResizeHandle } | null>(null);
  const [moveDrag, setMoveDrag] = useState<MoveDrag | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const surfaceRef = useRef<HTMLDivElement>(null);
  const liveRef = useRef<{ draft: Draft | null; dragHandle: { id: string; handle: ResizeHandle } | null; moveDrag: MoveDrag | null; activeTool: PositionDirection | null; readOnly: boolean; positions: PositionTool[] }>({ draft: null, dragHandle: null, moveDrag: null, activeTool: null, readOnly: false, positions: [] });
  liveRef.current = { draft, dragHandle, moveDrag, activeTool, readOnly, positions: toolState.positions };
  const defaults = toolState.defaults;
  const selectedPosition = toolState.positions.find((position) => position.id === selectedId) ?? null;
  const selectedMetrics = selectedPosition ? calculatePositionMetrics(selectedPosition, currentPrice, defaults) : null;

  useEffect(() => {
    try { window.localStorage.setItem(LOCAL_STORAGE_KEY, JSON.stringify(toolState)); } catch { /* storage can be unavailable in private contexts */ }
  }, [toolState]);

  useEffect(() => {
    if (!activeTool) return;
    const handleKey = (event: KeyboardEvent) => { if (event.key === "Escape") { onActiveToolChange(null); setDraft(null); } };
    document.addEventListener("keydown", handleKey);
    return () => document.removeEventListener("keydown", handleKey);
  }, [activeTool, onActiveToolChange]);
  function pointerPosition(event: { clientX: number; clientY: number }) {
    const rect = surfaceRef.current?.getBoundingClientRect();
    if (!rect) return null;
    return { x: clamp((event.clientX - rect.left) / rect.width, 0, 1), y: clamp((event.clientY - rect.top) / rect.height, 0, 1) };
  }
  // 覆盖层 pointer-events:none，真实鼠标事件直达图表保留十字线；工具交互走 window 级指针监听。
  useEffect(() => {
    const down = (event: PointerEvent) => {
      if ((event.target as HTMLElement).closest(".position-tool-resize-handle, .position-tool-edge, .position-tool-line, .position-tool-list, .position-tool-detail")) return;
      const live = liveRef.current;
      const point = pointerPosition(event);
      if (!point) return;
      if (live.activeTool) {
        // 阻断兼容鼠标事件，避免绘制时图表跟着平移。
        event.preventDefault();
        setDraft({ direction: live.activeTool, startX: point.x, startY: point.y, endX: point.x, endY: point.y });
        return;
      }
      if (live.readOnly) return;
      const hit = live.positions.find((p) => point.x >= p.left && point.x <= p.right && point.y >= Math.min(p.entryY, p.targetY, p.stopY) && point.y <= Math.max(p.entryY, p.targetY, p.stopY));
      if (hit) {
        event.preventDefault();
        setSelectedId(hit.id);
        setMoveDrag({ id: hit.id, startX: point.x, startY: point.y, origin: hit });
      } else {
        // 区外点击取消选中。
        setSelectedId(null);
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
    if (live.dragHandle) {
      const point = pointerPosition(event);
      if (!point) return;
      updatePosition(live.dragHandle.id, (position) => {
        if (live.dragHandle!.handle === "leftX") {
          return { ...position, left: clamp(point.x, 0.02, position.right - 0.05) };
        }
        if (live.dragHandle!.handle === "leftFree") {
          const nextY = clamp(point.y, 0.02, 0.98);
          return { ...position, left: clamp(point.x, 0.02, position.right - 0.05), entryY: nextY };
        }
        if (live.dragHandle!.handle === "rightX") {
          return { ...position, right: clamp(point.x, position.left + 0.05, 0.98) };
        }
        const nextY = clamp(point.y, 0.02, 0.98);
        if (live.dragHandle!.handle === "entryY") {
          const delta = nextY - position.entryY;
          return { ...position, entryY: nextY, targetY: clamp(position.targetY + delta, 0.02, 0.98), stopY: clamp(position.stopY + delta, 0.02, 0.98) };
        }
        if (live.dragHandle!.handle === "targetY") {
          const constrained = position.direction === "long" ? Math.min(nextY, position.entryY - .01) : Math.max(nextY, position.entryY + .01);
          return { ...position, targetY: clamp(constrained, 0.02, 0.98) };
        }
        const constrained = position.direction === "long" ? Math.max(nextY, position.entryY + .01) : Math.min(nextY, position.entryY - .01);
        return { ...position, stopY: clamp(constrained, 0.02, 0.98) };
      });
      return;
    }
    if (live.moveDrag) {
      const point = pointerPosition(event);
      if (!point) return;
      const origin = live.moveDrag.origin;
      const width = origin.right - origin.left;
      const verticalMinimum = Math.min(origin.entryY, origin.targetY, origin.stopY);
      const verticalMaximum = Math.max(origin.entryY, origin.targetY, origin.stopY);
      const shiftX = clamp(point.x - live.moveDrag.startX, -origin.left, 1 - origin.right);
      const shiftY = clamp(point.y - live.moveDrag.startY, -verticalMinimum, 1 - verticalMaximum);
      setToolState((state) => ({
        ...state,
        positions: state.positions.map((position) => position.id === live.moveDrag!.id
          ? { ...origin, left: origin.left + shiftX, right: origin.left + shiftX + width, entryY: origin.entryY + shiftY, targetY: origin.targetY + shiftY, stopY: origin.stopY + shiftY }
          : position),
      }));
      return;
    }
    if (!live.draft) return;
    const point = pointerPosition(event);
    if (point) setDraft((previous) => previous ? { ...previous, endX: point.x, endY: point.y } : previous);
  }
  function handlePointerUp(event: { clientX: number; clientY: number }) {
    const live = liveRef.current;
    if (live.dragHandle) {
      setDragHandle(null);
      return;
    }
    if (live.moveDrag) {
      setMoveDrag(null);
      return;
    }
    if (!live.draft) return;
    const point = pointerPosition(event);
    const completed = point ? sanitizeDraft({ ...live.draft, endX: point.x, endY: point.y }, live.draft.direction) : null;
    if (completed) {
      setToolState((state) => ({ ...state, positions: [...state.positions.slice(-11), completed] }));
      setSelectedId(completed.id);
    }
    setDraft(null);
    onActiveToolChange(null);
  }
  function updatePosition(id: string, update: (position: PositionTool) => PositionTool) { setToolState((state) => ({ ...state, positions: state.positions.map((position) => position.id === id ? update(position) : position) })); }
  function beginHandle(event: React.PointerEvent, id: string, handle: ResizeHandle) {
    if (previewPosition) return;
    event.stopPropagation();
    event.preventDefault();
    setSelectedId(id);
    setDragHandle({ id, handle });
  }
  const previewPosition = draft ? sanitizeDraft(draft, draft.direction) : null;
  const renderedPositions = previewPosition ? [...toolState.positions, previewPosition] : toolState.positions;

  return <div className="position-tool-layer">
    <div className={`position-tool-surface ${activeTool ? "is-drawing" : ""}`} ref={surfaceRef}>
      {renderedPositions.map((position) => {
        const metrics = calculatePositionMetrics(position, currentPrice, defaults);
        const selected = position.id === selectedId;
        const left = `${position.left * 100}%`;
        const width = `${(position.right - position.left) * 100}%`;
        const targetTop = `${Math.min(position.targetY, position.entryY) * 100}%`;
        const targetHeight = `${Math.abs(position.targetY - position.entryY) * 100}%`;
        const stopTop = `${Math.min(position.stopY, position.entryY) * 100}%`;
        const stopHeight = `${Math.abs(position.stopY - position.entryY) * 100}%`;
        const boxTop = `${Math.min(position.targetY, position.stopY, position.entryY) * 100}%`;
        const boxHeight = `${(Math.max(position.targetY, position.stopY, position.entryY) - Math.min(position.targetY, position.stopY, position.entryY)) * 100}%`;
        const topHandle: "targetY" | "stopY" = position.targetY < position.stopY ? "targetY" : "stopY";
        const bottomHandle: "targetY" | "stopY" = topHandle === "targetY" ? "stopY" : "targetY";
        const topHandleY = Math.min(position.targetY, position.stopY);
        const bottomHandleY = Math.max(position.targetY, position.stopY);
        const interactive = selected;
        return <div key={position.id} className={`position-tool-drawing ${position.direction} ${selected ? "is-selected" : ""}`} style={{ left, width }}>
          <div className="position-tool-zone target" style={{ top: targetTop, height: targetHeight }} /><div className="position-tool-zone stop" style={{ top: stopTop, height: stopHeight }} />
          <div className="position-tool-edge left-edge" style={{ top: boxTop, height: boxHeight }} onPointerDown={(event) => beginHandle(event, position.id, "leftX")} />
          <div className="position-tool-edge right-edge" style={{ top: boxTop, height: boxHeight }} onPointerDown={(event) => beginHandle(event, position.id, "rightX")} />
          <div className="position-tool-line entry" style={{ top: `${position.entryY * 100}%` }} onPointerDown={(event) => beginHandle(event, position.id, "entryY")} />
          <div className="position-tool-line target-line" style={{ top: `${position.targetY * 100}%` }} onPointerDown={(event) => beginHandle(event, position.id, "targetY")}>
            {interactive && <span>止盈 {formatPrice(metrics.targetPrice)}</span>}
          </div>
          <div className="position-tool-line stop-line" style={{ top: `${position.stopY * 100}%` }} onPointerDown={(event) => beginHandle(event, position.id, "stopY")}>
            {interactive && <span>止损 {formatPrice(metrics.stopPrice)}</span>}
          </div>
          <div className="position-tool-stats" style={{ top: `${position.entryY * 100}%` }}>入场 {formatPrice(metrics.entryPrice)} · RR {metrics.riskReward.toFixed(2)} · {formatMoney(metrics.openPnl)}</div>
          {selected && !previewPosition && <div className="position-tool-handles">
            <button type="button" className="position-tool-resize-handle top-left" style={{ top: `${topHandleY * 100}%` }} aria-label="调整上方高度" onPointerDown={(event) => beginHandle(event, position.id, topHandle)} />
            <button type="button" className="position-tool-resize-handle bottom-left" style={{ top: `${bottomHandleY * 100}%` }} aria-label="调整下方高度" onPointerDown={(event) => beginHandle(event, position.id, bottomHandle)} />
            <button type="button" className="position-tool-resize-handle middle-left" style={{ top: `${position.entryY * 100}%` }} aria-label="自由移动左点" onPointerDown={(event) => beginHandle(event, position.id, "leftFree")} />
            <button type="button" className="position-tool-resize-handle middle-right" style={{ top: `${position.entryY * 100}%` }} aria-label="左右调整宽度" onPointerDown={(event) => beginHandle(event, position.id, "rightX")} />
          </div>}
        </div>;
      })}
    </div>
    <div className="position-tool-list" aria-label="已保存的测量工具">{toolState.positions.map((position) => <ToolCard key={position.id} position={position} currentPrice={currentPrice} defaults={defaults} selected={position.id === selectedId} onSelect={() => setSelectedId(position.id)} onDelete={() => { setToolState((state) => ({ ...state, positions: state.positions.filter((item) => item.id !== position.id) })); if (selectedId === position.id) setSelectedId(null); }} />)}</div>
    {selectedPosition && selectedMetrics && <div className="position-tool-detail"><div><strong>{selectedPosition.direction === "long" ? "多头计划" : "空头计划"}</strong><span>入场 {formatPrice(selectedMetrics.entryPrice)}</span></div><div><span>止盈 {formatPrice(selectedMetrics.targetPrice)}</span><span>止损 {formatPrice(selectedMetrics.stopPrice)}</span><span>RR {selectedMetrics.riskReward.toFixed(2)}</span></div><button type="button" aria-label="关闭测量详情" onClick={() => setSelectedId(null)}><X size={13} /></button></div>}
  </div>;
}
