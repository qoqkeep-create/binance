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
  const [dragHandle, setDragHandle] = useState<{ id: string; handle: "entryY" | "targetY" | "stopY" } | null>(null);
  const [moveDrag, setMoveDrag] = useState<MoveDrag | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const surfaceRef = useRef<HTMLDivElement>(null);
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
  function pointerPosition(event: React.PointerEvent) {
    const rect = surfaceRef.current?.getBoundingClientRect();
    if (!rect) return null;
    return { x: clamp((event.clientX - rect.left) / rect.width, 0, 1), y: clamp((event.clientY - rect.top) / rect.height, 0, 1) };
  }
  function handlePointerDown(event: React.PointerEvent) {
    if (!activeTool) return;
    const point = pointerPosition(event);
    if (!point) return;
    event.currentTarget.setPointerCapture(event.pointerId);
    setDraft({ direction: activeTool, startX: point.x, startY: point.y, endX: point.x, endY: point.y });
  }
  function handlePointerMove(event: React.PointerEvent) {
    if (dragHandle) {
      const point = pointerPosition(event);
      if (!point) return;
      updatePosition(dragHandle.id, (position) => {
        const nextY = clamp(point.y, 0.02, 0.98);
        if (dragHandle.handle === "entryY") {
          const delta = nextY - position.entryY;
          return { ...position, entryY: nextY, targetY: clamp(position.targetY + delta, 0.02, 0.98), stopY: clamp(position.stopY + delta, 0.02, 0.98) };
        }
        if (dragHandle.handle === "targetY") {
          const constrained = position.direction === "long" ? Math.min(nextY, position.entryY - .01) : Math.max(nextY, position.entryY + .01);
          return { ...position, targetY: clamp(constrained, 0.02, 0.98) };
        }
        const constrained = position.direction === "long" ? Math.max(nextY, position.entryY + .01) : Math.min(nextY, position.entryY - .01);
        return { ...position, stopY: clamp(constrained, 0.02, 0.98) };
      });
      return;
    }
    if (moveDrag) {
      const point = pointerPosition(event);
      if (!point) return;
      const width = moveDrag.origin.right - moveDrag.origin.left;
      const verticalMinimum = Math.min(moveDrag.origin.entryY, moveDrag.origin.targetY, moveDrag.origin.stopY);
      const verticalMaximum = Math.max(moveDrag.origin.entryY, moveDrag.origin.targetY, moveDrag.origin.stopY);
      const shiftX = clamp(point.x - moveDrag.startX, -moveDrag.origin.left, 1 - moveDrag.origin.right);
      const shiftY = clamp(point.y - moveDrag.startY, -verticalMinimum, 1 - verticalMaximum);
      setToolState((state) => ({
        ...state,
        positions: state.positions.map((position) => position.id === moveDrag.id
          ? { ...moveDrag.origin, left: moveDrag.origin.left + shiftX, right: moveDrag.origin.left + shiftX + width, entryY: moveDrag.origin.entryY + shiftY, targetY: moveDrag.origin.targetY + shiftY, stopY: moveDrag.origin.stopY + shiftY }
          : position),
      }));
      return;
    }
    if (!draft) return;
    const point = pointerPosition(event);
    if (point) setDraft((previous) => previous ? { ...previous, endX: point.x, endY: point.y } : previous);
  }
  function handlePointerUp(event: React.PointerEvent) {
    if (dragHandle) {
      setDragHandle(null);
      return;
    }
    if (moveDrag) {
      setMoveDrag(null);
      return;
    }
    if (!draft) return;
    const point = pointerPosition(event);
    const completed = point ? sanitizeDraft({ ...draft, endX: point.x, endY: point.y }, draft.direction) : null;
    if (completed) {
      setToolState((state) => ({ ...state, positions: [...state.positions.slice(-11), completed] }));
      setSelectedId(completed.id);
    }
    setDraft(null);
    onActiveToolChange(null);
  }
  function updatePosition(id: string, update: (position: PositionTool) => PositionTool) { setToolState((state) => ({ ...state, positions: state.positions.map((position) => position.id === id ? update(position) : position) })); }
  function beginHandle(event: React.PointerEvent, id: string, handle: "entryY" | "targetY" | "stopY") {
    if (previewPosition) return;
    event.stopPropagation();
    event.currentTarget.setPointerCapture(event.pointerId);
    setSelectedId(id);
    setDragHandle({ id, handle });
  }
  function beginMove(event: React.PointerEvent, position: PositionTool) {
    if (readOnly || previewPosition) return;
    const point = pointerPosition(event);
    if (!point) return;
    event.stopPropagation();
    event.currentTarget.setPointerCapture(event.pointerId);
    setSelectedId(position.id);
    setMoveDrag({ id: position.id, startX: point.x, startY: point.y, origin: position });
  }
  const previewPosition = draft ? sanitizeDraft(draft, draft.direction) : null;
  const renderedPositions = previewPosition ? [...toolState.positions, previewPosition] : toolState.positions;

  return <div className="position-tool-layer">
    <div className={`position-tool-surface ${activeTool ? "is-drawing" : ""}`} ref={surfaceRef} onPointerDown={handlePointerDown} onPointerMove={handlePointerMove} onPointerUp={handlePointerUp}>
      {renderedPositions.map((position) => {
        const metrics = calculatePositionMetrics(position, currentPrice, defaults);
        const selected = position.id === selectedId;
        const left = `${position.left * 100}%`;
        const width = `${(position.right - position.left) * 100}%`;
        const targetTop = `${Math.min(position.targetY, position.entryY) * 100}%`;
        const targetHeight = `${Math.abs(position.targetY - position.entryY) * 100}%`;
        const stopTop = `${Math.min(position.stopY, position.entryY) * 100}%`;
        const stopHeight = `${Math.abs(position.stopY - position.entryY) * 100}%`;
        return <div key={position.id} className={`position-tool-drawing ${position.direction} ${selected ? "is-selected" : ""}`} style={{ left, width }} onPointerDown={(event) => beginMove(event, position)}>
          <div className="position-tool-zone target" style={{ top: targetTop, height: targetHeight }} /><div className="position-tool-zone stop" style={{ top: stopTop, height: stopHeight }} />
          <div className="position-tool-line entry" style={{ top: `${position.entryY * 100}%` }} onPointerDown={(event) => beginHandle(event, position.id, "entryY")}><span>入场 {formatPrice(metrics.entryPrice)}</span></div>
          <div className="position-tool-line target-line" style={{ top: `${position.targetY * 100}%` }} onPointerDown={(event) => beginHandle(event, position.id, "targetY")}><span>止盈 {formatPrice(metrics.targetPrice)} · +{metrics.profitPercent.toFixed(2)}%</span></div>
          <div className="position-tool-line stop-line" style={{ top: `${position.stopY * 100}%` }} onPointerDown={(event) => beginHandle(event, position.id, "stopY")}><span>止损 {formatPrice(metrics.stopPrice)} · −{metrics.lossPercent.toFixed(2)}%</span></div>
          <div className="position-tool-stats"><strong>{position.direction === "long" ? "多头" : "空头"} · RR {metrics.riskReward.toFixed(2)}</strong><span>浮动盈亏 {formatMoney(metrics.openPnl)}</span><span>数量 {metrics.quantity.toFixed(defaults.qtyPrecision)} · 风险 {formatMoney(metrics.riskAmount)}</span></div>
          {selected && !previewPosition && <div className="position-tool-handles"><button type="button" aria-label="上移止盈" onPointerDown={(event) => event.stopPropagation()} onClick={() => updatePosition(position.id, (current) => ({ ...current, targetY: clamp(current.targetY - .02, .02, .98) }))}>↑</button><button type="button" aria-label="下移止损" onPointerDown={(event) => event.stopPropagation()} onClick={() => updatePosition(position.id, (current) => ({ ...current, stopY: clamp(current.stopY + .02, .02, .98) }))}>↓</button></div>}
        </div>;
      })}
      {!renderedPositions.length && !activeTool && <div className="position-tool-empty">选择多头或空头，然后在 K 线区域拖出测量区间</div>}
    </div>
    <div className="position-tool-list" aria-label="已保存的测量工具">{toolState.positions.map((position) => <ToolCard key={position.id} position={position} currentPrice={currentPrice} defaults={defaults} selected={position.id === selectedId} onSelect={() => setSelectedId(position.id)} onDelete={() => { setToolState((state) => ({ ...state, positions: state.positions.filter((item) => item.id !== position.id) })); if (selectedId === position.id) setSelectedId(null); }} />)}</div>
    {selectedPosition && selectedMetrics && <div className="position-tool-detail"><div><strong>{selectedPosition.direction === "long" ? "多头计划" : "空头计划"}</strong><span>入场 {formatPrice(selectedMetrics.entryPrice)}</span></div><div><span>止盈 {formatPrice(selectedMetrics.targetPrice)}</span><span>止损 {formatPrice(selectedMetrics.stopPrice)}</span><span>RR {selectedMetrics.riskReward.toFixed(2)}</span></div><button type="button" aria-label="关闭测量详情" onClick={() => setSelectedId(null)}><X size={13} /></button></div>}
  </div>;
}
