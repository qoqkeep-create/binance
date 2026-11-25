export type AnalysisInterval = "2m" | "5m" | "10m" | "15m" | "1h";
export type TopInterval = "2m" | "5m" | "10m";
export type AnalysisStatus = "ready" | "waiting" | "stale";
export type Direction = "up" | "down" | "neutral";

export interface Pivot {
  time: number;
  price: number;
  kind: "high" | "low";
  confirmedAt: number;
  trend?: "up" | "down" | "pending";
}

export interface SwingRange {
  startTime: number;
  endTime: number;
  high: number;
  low: number;
  rounds: number;
  historical: boolean;
  breakout?: "up" | "down";
}

export interface BoxRange extends SwingRange {
  lowerBoundary: number;
  upperBoundary: number;
  placement: "顶部箱体" | "底部箱体" | "箱体整理";
  confirmedAt: number;
  breakoutAt?: number;
  upperTouches: number;
  lowerTouches: number;
  candleCount: number;
  atr: number;
  efficiency: number;
  classificationPending?: boolean;
  pendingBreakout?: "up" | "down";
  pendingBreakoutCount?: number;
  /** Replay cursors preserve an active box when the rolling source drops its start. */
  lastProcessedCandleTime?: number;
  lastCountedPivotTime?: number;
  edgeTransitions?: number;
  lastEdge?: "up" | "down";
}

export interface BollingerLevels {
  upper: number;
  middle: number;
  lower: number;
  label: string;
}

export interface PriceStructure {
  label: string;
  description: string;
  bias: Direction;
  supports: number[];
  resistances: number[];
}

export interface PivotSeries {
  interval: AnalysisInterval;
  points: Pivot[];
  contextPoints: Pivot[];
  candidate: Pivot | null;
  structure: PriceStructure;
  range: SwingRange | null;
  box: BoxRange | null;
  boll: BollingerLevels | null;
  updatedAt: number;
  lastCandleClose: number | null;
  status: AnalysisStatus;
}

export interface IndicatorRow {
  interval: string;
  label: string;
  price: number | null;
  change: number | null;
  ema21: number | null;
  ema55: number | null;
  ema144: number | null;
  macd: number | null;
  stochK: number | null;
  stochD: number | null;
  boll: BollingerLevels | null;
  trend: Direction;
  status: AnalysisStatus;
}

export interface AnalysisSnapshot {
  symbol: string;
  quote: { price: number; time: number; source: string } | null;
  series: Record<AnalysisInterval, PivotSeries>;
  indicators: IndicatorRow[];
  fetchedAt: number;
}
