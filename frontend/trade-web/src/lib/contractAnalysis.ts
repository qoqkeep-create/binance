import type { Candle } from "./binance";
import type {
  AnalysisInterval, BollingerLevels, BoxRange, Pivot, PivotSeries,
  PriceStructure, SwingRange,
} from "./analysisTypes";

export const intervalSeconds: Record<AnalysisInterval, number> = {
  "2m": 120, "5m": 300, "10m": 600, "15m": 900, "1h": 3600,
};

interface SeriesOptions {
  now: number;
  /** Latest source observation allowed to establish a completed candle. */
  confirmedThrough?: number;
  tickSize: number;
  price: number | null;
  quoteTime: number | null;
  boll?: BollingerLevels | null;
  context15m?: Candle[];
  context30m?: Candle[];
  previousBox?: BoxRange;
}

const median = (values: number[]): number => {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const center = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[center] : (sorted[center - 1] + sorted[center]) / 2;
};

function normalizedCandles(candles: Candle[]): Candle[] {
  const byTime = new Map<number, Candle>();
  for (const candle of candles) {
    if ([candle.time, candle.open, candle.high, candle.low, candle.close].every(Number.isFinite)
      && candle.high >= candle.low && candle.low > 0
      && candle.open >= candle.low && candle.open <= candle.high
      && candle.close >= candle.low && candle.close <= candle.high) byTime.set(candle.time, candle);
  }
  return [...byTime.values()].sort((a, b) => a.time - b.time);
}

/** Only complete, aligned buckets are returned. A missing child never bridges a gap. */
export function aggregateCandles(
  candles: Candle[], sourceSeconds: number, targetSeconds: number,
  now = Date.now() / 1000,
): Candle[] {
  if (sourceSeconds <= 0 || targetSeconds < sourceSeconds || targetSeconds % sourceSeconds !== 0) return [];
  const count = targetSeconds / sourceSeconds;
  const buckets = new Map<number, Candle[]>();
  for (const candle of normalizedCandles(candles)) {
    if (candle.time % sourceSeconds !== 0 || candle.time + sourceSeconds > now) continue;
    const time = Math.floor(candle.time / targetSeconds) * targetSeconds;
    const group = buckets.get(time) ?? [];
    group.push(candle);
    buckets.set(time, group);
  }
  const result: Candle[] = [];
  for (const [time, group] of buckets) {
    if (group.length !== count || group.some((candle, i) => candle.time !== time + i * sourceSeconds)) continue;
    result.push({
      time, open: group[0].open, close: group[count - 1].close,
      high: Math.max(...group.map((c) => c.high)), low: Math.min(...group.map((c) => c.low)),
      volume: group.reduce((sum, c) => sum + c.volume, 0),
    });
  }
  return result;
}

/** A discontinuity starts a new calculation context rather than joining unrelated history. */
function continuousSuffix(candles: Candle[], seconds: number): Candle[] {
  let start = 0;
  for (let i = 1; i < candles.length; i++) if (candles[i].time - candles[i - 1].time !== seconds) start = i;
  return candles.slice(start);
}

function appendPivot(points: Pivot[], pivot: Pivot): void {
  const last = points[points.length - 1];
  if (!last) { points.push(pivot); return; }
  if (pivot.time <= last.time) return;
  if (last.kind !== pivot.kind) { points.push(pivot); return; }
  if ((pivot.kind === "high" && pivot.price > last.price) || (pivot.kind === "low" && pivot.price < last.price)) {
    points[points.length - 1] = pivot;
  }
}

function fractalEvents(candles: Candle[], seconds: number): Pivot[] {
  const points: Pivot[] = [];
  const highEnds: number[] = [], lowEnds: number[] = [];
  for (let i = candles.length - 1; i >= 0; i--) {
    highEnds[i] = i + 1 < candles.length && candles[i].high === candles[i + 1].high ? highEnds[i + 1] : i;
    lowEnds[i] = i + 1 < candles.length && candles[i].low === candles[i + 1].low ? lowEnds[i + 1] : i;
  }
  for (let i = 2; i < candles.length - 2; i++) {
    const candle = candles[i];
    const highEnd = highEnds[i], lowEnd = lowEnds[i];
    const high = candle.high !== candles[i - 1].high && highEnd + 2 < candles.length
      && [candles[i - 2].high, candles[i - 1].high, candles[highEnd + 1].high, candles[highEnd + 2].high].every((v) => candle.high > v);
    const low = candle.low !== candles[i - 1].low && lowEnd + 2 < candles.length
      && [candles[i - 2].low, candles[i - 1].low, candles[lowEnd + 1].low, candles[lowEnd + 2].low].every((v) => candle.low < v);
    if (high === low) continue;
    points.push({
      time: candle.time, price: high ? candle.high : candle.low, kind: high ? "high" : "low",
      confirmedAt: candles[(high ? highEnd : lowEnd) + 2].time + seconds,
    });
  }
  return points;
}

/** Two closed bars on either side confirm the first bar of an equal-price platform. */
export function fractalPivots(candles: Candle[], seconds = 120): Pivot[] {
  const points: Pivot[] = [];
  for (const event of fractalEvents(candles, seconds)) appendPivot(points, event);
  return points;
}

/** ZigZag++ state: Depth 12, Deviation 5 ticks, Backstep 2. */
export function zigzagPivots(candles: Candle[], seconds: number, tickSize: number): Pivot[] {
  if (candles.length < 12 || !(tickSize > 0)) return [];
  const points: Pivot[] = [];
  let highCount = 0, lowCount = 0, directionCount = 0;
  let previousHighTest = false, previousLowTest = false;
  let direction: "up" | "down" = "up";
  let extreme = candles[0], reverse = candles[0];
  for (let i = 0; i < candles.length; i++) {
    const candle = candles[i];
    if (i < 11) {
      if (candle.high > extreme.high) { extreme = candle; reverse = candle; }
      else if (candle.low < reverse.low) reverse = candle;
      continue;
    }
    const window = candles.slice(i - 11, i + 1);
    const highTest = Math.max(...window.map((c) => c.high)) - candle.high > 5 * tickSize;
    const lowTest = candle.low - Math.min(...window.map((c) => c.low)) > 5 * tickSize;
    highCount = previousHighTest ? highCount + 1 : 0;
    lowCount = previousLowTest ? lowCount + 1 : 0;
    directionCount = highCount <= lowCount ? 0 : directionCount + 1;
    const nextDirection = directionCount >= 2 ? "down" : "up";
    if (direction === "up") {
      if (candle.high > extreme.high) { extreme = candle; reverse = candle; }
      else if (candle.low < reverse.low) reverse = candle;
    } else {
      if (candle.low < extreme.low) { extreme = candle; reverse = candle; }
      else if (candle.high > reverse.high) reverse = candle;
    }
    if (nextDirection !== direction) {
      appendPivot(points, {
        time: extreme.time, price: direction === "up" ? extreme.high : extreme.low,
        kind: direction === "up" ? "high" : "low", confirmedAt: candle.time + seconds,
      });
      extreme = reverse;
      reverse = candle;
      direction = nextDirection;
    }
    previousHighTest = highTest;
    previousLowTest = lowTest;
  }
  return points;
}

function slope(points: { time: number; price: number }[]): number {
  if (points.length < 2) return 0;
  const origin = points[0].time;
  const meanX = points.reduce((sum, p) => sum + p.time - origin, 0) / points.length;
  const meanY = points.reduce((sum, p) => sum + p.price, 0) / points.length;
  let numerator = 0, denominator = 0;
  for (const point of points) {
    const x = point.time - origin - meanX;
    numerator += x * (point.price - meanY);
    denominator += x * x;
  }
  return denominator ? numerator / denominator : 0;
}

/** Reaction must clear both the previous structure and its normal same-kind variation. */
export function markTrendReversals(points: Pivot[], price: number | null): Pivot[] {
  const result = points.map((point) => ({ ...point }));
  for (let i = 0; i < result.length; i++) {
    const anchor = result[i];
    const preceding = result.slice(0, i);
    const highs = preceding.filter((p) => p.kind === "high").slice(-6);
    const lows = preceding.filter((p) => p.kind === "low").slice(-6);
    if (highs.length < 3 || lows.length < 3) continue;
    const highVariation = median(highs.slice(1).map((p, j) => Math.abs(p.price - highs[j].price)));
    const lowVariation = median(lows.slice(1).map((p, j) => Math.abs(p.price - lows[j].price)));
    const highSlope = slope(highs), lowSlope = slope(lows);
    const lastHighs = highs.slice(-2), lastLows = lows.slice(-2);
    const descending = (highSlope < 0 && lowSlope < 0)
      || (lastHighs[1].price < lastHighs[0].price && lastLows[1].price < lastLows[0].price);
    const ascending = (highSlope > 0 && lowSlope > 0)
      || (lastHighs[1].price > lastHighs[0].price && lastLows[1].price > lastLows[0].price);
    const up = anchor.kind === "low" && descending
      && anchor.price < Math.min(...lastLows.map((p) => p.price)) - lowVariation;
    const down = anchor.kind === "high" && ascending
      && anchor.price > Math.max(...lastHighs.map((p) => p.price)) + highVariation;
    if (!up && !down) continue;
    const threshold = up ? Math.max(...lastHighs.map((p) => p.price)) + highVariation
      : Math.min(...lastLows.map((p) => p.price)) - lowVariation;
    let invalidated = false, confirmed = false;
    for (const reaction of result.slice(i + 1)) {
      if ((up && reaction.price < anchor.price) || (down && reaction.price > anchor.price)) { invalidated = true; break; }
      if ((up && reaction.price > threshold) || (down && reaction.price < threshold)) { confirmed = true; break; }
    }
    // A later quote cannot erase a reversal already validated by a confirmed reaction.
    if (!invalidated && !confirmed && price !== null) {
      if ((up && price < anchor.price) || (down && price > anchor.price)) invalidated = true;
      else if ((up && price > threshold) || (down && price < threshold)) confirmed = true;
    }
    if (confirmed && !invalidated) anchor.trend = up ? "up" : "down";
  }
  return result;
}

function isRange(points: Pivot[]): boolean {
  const swings = points.slice(1).map((point, i) => Math.abs(point.price - points[i].price));
  const normal = median(swings), total = swings.reduce((sum, value) => sum + value, 0);
  const width = Math.max(...points.map((p) => p.price)) - Math.min(...points.map((p) => p.price));
  if (!normal || !total || !width) return false;
  const efficiency = Math.abs(points[points.length - 1].price - points[0].price) / total;
  const dispersion = median(swings.map((value) => Math.abs(value - normal))) / normal;
  const drift = Math.abs(slope(points)) * (points[points.length - 1].time - points[0].time) / width;
  return efficiency <= .25 && dispersion <= .70 && drift <= .60
    && Math.max(...swings) <= normal * 2.8
    && swings.filter((value) => value >= normal * .35).length / swings.length >= .65;
}

export function findSwingRange(points: Pivot[], price: number | null): SwingRange | null {
  // Prefer the first qualifying trailing window, starting with eight pivots.
  for (let end = points.length; end >= Math.max(8, points.length - 72); end--) {
    for (let size = 8; size <= Math.min(12, end); size++) {
      const window = points.slice(end - size, end);
      if (!isRange(window)) continue;
      const high = Math.max(...window.map((p) => p.price)), low = Math.min(...window.map((p) => p.price));
      const padding = (high - low) * .05;
      const following = points.slice(end);
      let previousOutside: "up" | "down" | undefined;
      let breakout: "up" | "down" | undefined;
      let endTime = window[window.length - 1].confirmedAt;
      for (const point of following) {
        const outside = point.price > high + padding ? "up" : point.price < low - padding ? "down" : undefined;
        endTime = point.confirmedAt;
        if (outside && outside === previousOutside) { breakout = outside; break; }
        previousOutside = outside;
      }
      if (end === points.length && price !== null) breakout = price > high + padding ? "up" : price < low - padding ? "down" : undefined;
      return {
        startTime: window[0].time, endTime, high, low,
        rounds: Math.floor((size - 1) / 2), historical: end !== points.length, breakout,
      };
    }
  }
  return null;
}

export function describeStructure(points: Pivot[], price: number | null, range: SwingRange | null = null): PriceStructure {
  const recent = points.slice(-12);
  const highs = recent.filter((p) => p.kind === "high"), lows = recent.filter((p) => p.kind === "low");
  const prices = [...new Set(recent.map((point) => point.price))].sort((a, b) => a - b);
  const supports = price === null ? [] : prices.filter((value) => value <= price).reverse().slice(0, 2);
  const resistances = price === null ? [] : prices.filter((value) => value > price).slice(0, 2);
  if (highs.length < 2 || lows.length < 2) return { label: "等待结构确认", description: "至少需要两个已确认高点和低点", bias: "neutral", supports, resistances };
  const normalSwing = median(recent.slice(1).map((p, i) => Math.abs(p.price - recent[i].price)));
  const protection = (price ?? recent[recent.length - 1].price) >= 100 ? .02 : (price ?? recent[recent.length - 1].price) * .000005;
  const tolerance = Math.max(protection, normalSwing * .05);
  const compare = (value: number) => value > tolerance ? 1 : value < -tolerance ? -1 : 0;
  const highDirection = compare(highs[highs.length - 1].price - highs[highs.length - 2].price);
  const lowDirection = compare(lows[lows.length - 1].price - lows[lows.length - 2].price);
  let label = "混合结构", description = "高低点方向不一，震荡观察", bias: PriceStructure["bias"] = "neutral";
  if (highDirection > 0 && lowDirection > 0) { label = "上升结构"; description = "高低点抬高，偏强"; bias = "up"; }
  else if (highDirection < 0 && lowDirection < 0) { label = "下降结构"; description = "高低点下移，偏弱"; bias = "down"; }
  else if (!highDirection && !lowDirection) { label = "区间结构"; description = "高低点重叠，区间观察"; }
  else if (highDirection < 0 && lowDirection > 0) { label = "收敛结构"; description = "高点回落、低点抬高，收敛观察"; }
  else if (highDirection > 0 && lowDirection < 0) { label = "扩张结构"; description = "高低点向外扩展，振幅扩大"; }
  if (price !== null) {
    const buffer = price >= 100 ? .005 : price * .00000125;
    if (bias === "up" && price < lows[lows.length - 1].price - buffer) { description = "原结构抬高，现价下破前低"; bias = "neutral"; }
    if (bias === "down" && price > highs[highs.length - 1].price + buffer) { description = "原结构下移，现价突破前高"; bias = "neutral"; }
  }
  if (range && !range.historical) {
    label = range.breakout ? "震荡区越界观察" : "往返震荡";
    description = range.breakout ? "现价越过震荡边界，等待后续确认" : `区间内往返 ${range.rounds} 轮`;
    bias = "neutral";
    return { label, description, bias, supports: [range.low], resistances: [range.high] };
  }
  return { label, description, bias, supports, resistances };
}

/** Wilder ATR14, seeded by the first fourteen true ranges of the continuous history. */
function boxAtrValues(candles: Candle[]): Array<number | null> {
  let sum = 0, average: number | null = null;
  return candles.map((candle, index) => {
    const range = index ? Math.max(candle.high - candle.low,
      Math.abs(candle.high - candles[index - 1].close), Math.abs(candle.low - candles[index - 1].close)) : candle.high - candle.low;
    if (index < 14) sum += range;
    if (index === 13) average = sum / 14;
    else if (index > 13 && average !== null) average = (average * 13 + range) / 14;
    return average;
  });
}

function boxContext(candles: Candle[], seconds: number, startTime: number): Candle[] {
  return continuousSuffix(normalizedCandles(candles).filter((candle) => candle.time % seconds === 0 && candle.time + seconds <= startTime), seconds).slice(-60);
}

function boxPlacement(startTime: number, midpoint: number, context15m: Candle[], context30m: Candle[]): Pick<BoxRange, "placement" | "classificationPending"> {
  const fifteen = boxContext(context15m, 900, startTime);
  const thirty = boxContext(context30m, 1800, startTime);
  const currentFifteen = fifteen.length && fifteen[fifteen.length - 1].time + 900 === Math.floor(startTime / 900) * 900;
  const currentThirty = thirty.length && thirty[thirty.length - 1].time + 1800 === Math.floor(startTime / 1800) * 1800;
  if (fifteen.length < 20 || thirty.length < 4 || !currentFifteen || !currentThirty) return { placement: "箱体整理", classificationPending: true };
  const high = Math.max(...fifteen.map((c) => c.high)), low = Math.min(...fifteen.map((c) => c.low));
  if (high <= low) return { placement: "箱体整理", classificationPending: true };
  const position = (midpoint - low) / (high - low);
  const fifteenChange = fifteen[fifteen.length - 1].close - fifteen[fifteen.length - 6].close;
  const thirtyChange = thirty[thirty.length - 1].close - thirty[thirty.length - 4].close;
  if (fifteenChange > 0 && thirtyChange > 0 && position >= .7) return { placement: "顶部箱体", classificationPending: false };
  if (fifteenChange < 0 && thirtyChange < 0 && position <= .3) return { placement: "底部箱体", classificationPending: false };
  return { placement: "箱体整理", classificationPending: false };
}

/** Count completed edge-to-opposite-edge-to-edge trips; middle/outside points add none. */
function countBoxRounds(box: BoxRange, points: Pivot[]): void {
  let lastEdge = box.lastEdge;
  let transitions = box.edgeTransitions ?? box.rounds * 2;
  let cursor = box.lastCountedPivotTime ?? box.startTime - 1;
  for (const point of points) {
    if (point.time < box.startTime || point.time <= cursor || point.confirmedAt > box.endTime) continue;
    cursor = point.time;
    if (point.price < box.low || point.price > box.high) continue;
    const edge = point.price >= box.upperBoundary ? "up" : point.price <= box.lowerBoundary ? "down" : undefined;
    if (!edge) continue;
    if (lastEdge && edge !== lastEdge) transitions++;
    lastEdge = edge;
  }
  box.lastEdge = lastEdge;
  box.edgeTransitions = transitions;
  box.lastCountedPivotTime = cursor;
  box.rounds = Math.floor(transitions / 2);
}

/** Once discovered, a box keeps its bounds until two consecutive closed bars break it. */
export function findBox(candles: Candle[], points: Pivot[], context15m: Candle[] = [], context30m: Candle[] = [], previousBox?: BoxRange): BoxRange | null {
  const source = continuousSuffix(normalizedCandles(candles).filter((candle) => candle.time % 120 === 0 && Number.isFinite(candle.volume) && candle.volume >= 0), 120);
  if (!source.length) return null;
  const sourceByTime = new Map(source.map((candle) => [candle.time, candle]));
  const lastClose = source[source.length - 1].time + 120;
  const unique = new Map<number, Pivot>();
  const ambiguous = new Set<number>();
  for (const point of points) {
    const candle = sourceByTime.get(point.time);
    if (!candle || !Number.isFinite(point.price) || !Number.isFinite(point.confirmedAt)
      || point.confirmedAt < point.time + 360 || point.confirmedAt > lastClose
      || !sourceByTime.has(point.confirmedAt - 120)) continue;
    const actual = point.kind === "high" ? candle.high : candle.low;
    if (Math.abs(actual - point.price) > Math.max(1e-10, Math.abs(actual) * 1e-10)) continue;
    const existing = unique.get(point.time);
    if (existing && existing.kind !== point.kind) ambiguous.add(point.time);
    else unique.set(point.time, point);
  }
  const confirmedPoints = [...unique.values()].filter((point) => !ambiguous.has(point.time)).sort((a, b) => a.time - b.time);
  // Same-kind extrema can replace an earlier point in the present-day pivot
  // list. Replay its verified confirmation event as well, so that replacement
  // cannot rewrite a box that had already been established in the past.
  const events = fractalEvents(source, 120);
  const canonical: Pivot[] = [];
  for (const event of events) appendPivot(canonical, event);
  const suppliedKeys = new Set(confirmedPoints.map((point) => `${point.time}:${point.kind}:${point.price}`));
  const hasCompleteContext = confirmedPoints.length >= 4 && canonical.every((point) => suppliedKeys.has(`${point.time}:${point.kind}:${point.price}`));
  const byConfirmation = [...events].sort((a, b) => a.confirmedAt - b.confirmedAt);
  const observed = new Set<Pivot>();
  let observedIndex = 0, replayTime = -Infinity, replayPoints: Pivot[] = [];
  const pointsAt = (closeTime: number) => {
    if (!hasCompleteContext) return confirmedPoints.filter((point) => point.confirmedAt <= closeTime);
    if (closeTime >= replayTime) {
      let changed = false;
      while (observedIndex < byConfirmation.length && byConfirmation[observedIndex].confirmedAt <= closeTime) {
        observed.add(byConfirmation[observedIndex++]); changed = true;
      }
      if (changed) {
        replayPoints = [];
        for (const event of events) if (observed.has(event)) appendPivot(replayPoints, event);
      }
      replayTime = closeTime;
      return replayPoints;
    }
    const visible: Pivot[] = [];
    for (const event of events) if (event.confirmedAt <= closeTime) appendPivot(visible, event);
    return visible;
  };
  // Candidate windows are bounded to 60 bars, but a confirmed box can remain
  // active much longer. Replaying all available continuous history preserves its
  // original fixed boundaries instead of moving them as a display window slides.
  const canSeed = previousBox && !previousBox.historical && !previousBox.breakout
    && previousBox.high > previousBox.low && previousBox.endTime <= lastClose
    && sourceByTime.has(previousBox.endTime - 120);
  let box: BoxRange | null = canSeed ? { ...previousBox } : null, lastBox: BoxRange | null = null;
  if (box?.classificationPending) Object.assign(box, boxPlacement(box.startTime, (box.high + box.low) / 2, context15m, context30m));
  let earliestStart = 0;
  const atrValues = boxAtrValues(source);
  const closePath = [0];
  for (let index = 1; index < source.length; index++) closePath[index] = closePath[index - 1] + Math.abs(source[index].close - source[index - 1].close);
  for (let end = 0; end < source.length; end++) {
    const candle = source[end];
    if (box) {
      if (candle.time + 120 <= box.endTime) continue;
      const padding = (box.high - box.low) * .02;
      const outside = candle.close > box.high + padding ? "up" : candle.close < box.low - padding ? "down" : undefined;
      const consecutive = box.lastProcessedCandleTime !== undefined && candle.time - box.lastProcessedCandleTime === 120;
      const count = outside ? consecutive && outside === box.pendingBreakout ? (box.pendingBreakoutCount ?? 1) + 1 : 1 : 0;
      box.endTime = candle.time + 120;
      box.lastProcessedCandleTime = candle.time;
      if (outside && count >= 2) {
        box.breakout = outside; box.breakoutAt = box.endTime; box.historical = true;
        delete box.pendingBreakout; delete box.pendingBreakoutCount;
        countBoxRounds(box, pointsAt(box.endTime));
        lastBox = box; box = null; earliestStart = end + 1;
      } else {
        box.pendingBreakout = outside;
        box.pendingBreakoutCount = outside ? count : undefined;
        countBoxRounds(box, pointsAt(box.endTime));
      }
      continue;
    }
    if (end + 1 - earliestStart < 12 || atrValues[end] === null) continue;
    // Index the small active horizon once per bar, rather than rescanning the
    // complete pivot history for each of the 49 possible candidate windows.
    const firstTime = source[Math.max(earliestStart, end - 59)].time;
    const eligible = pointsAt(candle.time + 120).filter((p) => p.time >= firstTime && p.time <= candle.time);
    if (eligible.length < 4) continue;
    const currentAtr = atrValues[end]!;
    let pivotCursor = eligible.length - 1;
    const highs: number[] = [], lows: number[] = [];
    let high = -Infinity, low = Infinity;
    let minClose = Infinity, maxClose = -Infinity;
    for (let index = end - 11; index <= end; index++) {
      minClose = Math.min(minClose, source[index].close); maxClose = Math.max(maxClose, source[index].close);
    }
    for (let size = 12; size <= Math.min(60, end + 1 - earliestStart); size++) {
      const startIndex = end + 1 - size, startTime = source[startIndex].time;
      if (size > 12) { minClose = Math.min(minClose, source[startIndex].close); maxClose = Math.max(maxClose, source[startIndex].close); }
      // Growing the window backwards visits each eligible pivot only once.
      while (pivotCursor >= 0 && eligible[pivotCursor].time >= startTime) {
        const point = eligible[pivotCursor--];
        if (point.kind === "high") { highs.push(point.price); high = Math.max(high, point.price); }
        else { lows.push(point.price); low = Math.min(low, point.price); }
      }
      if (highs.length < 2 || lows.length < 2) continue;
      const width = high - low;
      if (!(width >= currentAtr * 1.25) || width <= 0) continue;
      const touch = Math.min(width * .2, Math.max(currentAtr * .35, width * .05));
      let upperTouches = 0, lowerTouches = 0;
      for (const value of highs) if (value >= high - touch) upperTouches++;
      for (const value of lows) if (value <= low + touch) lowerTouches++;
      if (upperTouches < 2 || lowerTouches < 2) continue;
      if (maxClose > high || minClose < low) continue;
      const path = closePath[end] - closePath[startIndex];
      const efficiency = path ? Math.abs(candle.close - source[startIndex].close) / path : 0;
      if (efficiency > .40) continue;
      box = {
        startTime, endTime: candle.time + 120, high, low,
        lowerBoundary: low + width * .2, upperBoundary: low + width * .8,
        ...boxPlacement(startTime, (high + low) / 2, context15m, context30m),
        confirmedAt: candle.time + 120, upperTouches, lowerTouches, candleCount: size,
        atr: currentAtr, efficiency, rounds: 0, historical: false,
        lastProcessedCandleTime: candle.time,
      };
      countBoxRounds(box, pointsAt(box.endTime));
      break;
    }
  }
  const result = box ?? lastBox;
  if (!result) return null;
  countBoxRounds(result, pointsAt(result.endTime));
  return result;
}

function buildCandidate(points: Pivot[], candles: Candle[], price: number | null, now: number): Pivot | null {
  const last = points[points.length - 1];
  if (!last) return null;
  const remaining = candles.filter((c) => c.time > last.time);
  const kind = last.kind === "high" ? "low" : "high";
  let candidate: Pivot | null = null;
  for (const candle of remaining) {
    const value = kind === "high" ? candle.high : candle.low;
    if (!candidate || (kind === "high" ? value > candidate.price : value < candidate.price)) {
      candidate = { time: candle.time, price: value, kind, confirmedAt: 0 };
    }
  }
  if (price !== null && (!candidate || (kind === "high" ? price > candidate.price : price < candidate.price))) {
    candidate = { time: now, price, kind, confirmedAt: 0 };
  }
  return candidate;
}

export function buildPivotSeries(interval: AnalysisInterval, candles: Candle[], options: SeriesOptions): PivotSeries {
  const seconds = intervalSeconds[interval];
  const continuous = continuousSuffix(normalizedCandles(candles).filter((c) => c.time <= options.now), seconds);
  // Cached forming OHLC is never promoted to final merely because the clock
  // crossed a boundary. The data source must first observe that closed period.
  const confirmedThrough = Math.min(options.now, options.confirmedThrough ?? options.now);
  const closed = continuous.filter((c) => c.time + seconds <= confirmedThrough);
  const freshPrice = options.price !== null && options.quoteTime !== null && options.now - options.quoteTime <= 15
    && options.now >= options.quoteTime - 5 && Number.isFinite(options.price) && options.price > 0 ? options.price : null;
  const confirmed = interval === "2m" ? fractalPivots(closed, seconds) : zigzagPivots(closed, seconds, options.tickSize);
  const contextPoints = markTrendReversals(confirmed, freshPrice);
  const range = interval === "10m" || interval === "15m" ? findSwingRange(contextPoints, freshPrice) : null;
  const lastCandleClose = closed.length ? closed[closed.length - 1].time + seconds : null;
  const latest = continuous[continuous.length - 1];
  // Complete synthesized periods have no forming candle; the expected last close
  // remains the current period boundary until the next boundary is reached.
  const expectedClose = Math.floor(options.now / seconds) * seconds;
  const expired = lastCandleClose !== null && lastCandleClose < expectedClose && options.now - lastCandleClose > 150;
  return {
    interval, points: contextPoints.slice(interval === "15m" || interval === "1h" ? -24 : -35), contextPoints,
    candidate: buildCandidate(contextPoints, continuous, freshPrice, options.now),
    structure: describeStructure(contextPoints, freshPrice, range), range,
    box: interval === "2m" ? findBox(closed, contextPoints, options.context15m, options.context30m, options.previousBox) : null,
    boll: options.boll ?? null, updatedAt: options.now, lastCandleClose,
    status: !latest || contextPoints.length < 4 ? "waiting" : expired ? "stale" : "ready",
  };
}
