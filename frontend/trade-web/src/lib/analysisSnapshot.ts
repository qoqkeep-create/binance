import type { Candle } from "./binance";
import type { AnalysisInterval, AnalysisSnapshot, PivotSeries } from "./analysisTypes";
import { aggregateCandles, buildPivotSeries } from "./contractAnalysis.js";
import { bollingerLevels, buildIndicatorRow, continuousClosedCandles, intervalSeconds } from "./analysisIndicators.js";

export const analysisSources = ["1m", "5m", "15m", "30m", "1h", "2h", "4h", "12h", "1d"] as const;
export type SourceInterval = typeof analysisSources[number];
// 指标条周期须是 analysisSources 的子集：桶宽统一取自 intervalSeconds，缺配即编译失败。
const indicatorIntervals: SourceInterval[] = ["5m", "15m", "30m", "1h", "2h", "4h", "12h", "1d"];
export type AnalysisQuote = NonNullable<AnalysisSnapshot["quote"]>;

export interface RawAnalysisSnapshot {
  symbol: string;
  candles: Partial<Record<SourceInterval, Candle[]>>;
  receivedAt: Partial<Record<SourceInterval, number>>;
  confirmedThrough?: Partial<Record<SourceInterval, number>>;
  quote: AnalysisQuote | null;
  tickSize: number | null;
  fetchedAt: number;
}

export interface SnapshotHistory {
  raw: RawAnalysisSnapshot | null;
  snapshot: AnalysisSnapshot | null;
  now: number;
}

/** REST owns earlier final candles; newer stream data owns the request's forming minute onward. */
export function mergeRestCandles(fetched: Candle[], streamed: Candle[], requestStart: number): Candle[] {
  const currentMinute = Math.floor(requestStart / 60) * 60;
  return [...new Map(fetched.concat(streamed.filter((candle) => candle.time >= currentMinute))
    .map((candle) => [candle.time, candle])).values()].sort((a, b) => a.time - b.time).slice(-1500);
}

function unchangedContinuousHistory(previous: SnapshotHistory, raw: RawAnalysisSnapshot, source: SourceInterval, now: number) {
  if (!previous.raw || previous.raw.symbol !== raw.symbol) return false;
  const seconds = intervalSeconds[source];
  const closed = (data: RawAnalysisSnapshot, time: number) => continuousClosedCandles(data.candles[source] ?? [], seconds,
    Math.min(time, data.confirmedThrough?.[source] ?? data.receivedAt[source] ?? time));
  const before = closed(previous.raw, previous.now);
  const after = closed(raw, now);
  if (!before.length || !after.length) return false;
  const start = Math.max(before[0].time, after[0].time);
  const end = Math.min(before[before.length - 1].time, after[after.length - 1].time);
  if (start > end) return false;
  // A newly introduced gap changes the evidence; normal trimming of the left edge does not.
  const rawStart = Math.min(...(raw.candles[source] ?? []).map((candle) => candle.time));
  if (after[0].time > rawStart && after[0].time !== before[0].time) return false;
  const prior = new Map(before.filter((candle) => candle.time >= start && candle.time <= end).map((candle) => [candle.time, candle]));
  return after.filter((candle) => candle.time >= start && candle.time <= end).every((candle) => {
    const old = prior.get(candle.time);
    return !!old && old.open === candle.open && old.high === candle.high && old.low === candle.low && old.close === candle.close;
  });
}

function retainConfirmedTurns(series: Record<AnalysisInterval, PivotSeries>, raw: RawAnalysisSnapshot, now: number, previous?: SnapshotHistory | null) {
  if (!previous?.snapshot || previous.snapshot.symbol !== raw.symbol) return;
  for (const interval of Object.keys(series) as AnalysisInterval[]) {
    const source: SourceInterval = interval === "2m" ? "1m" : interval === "10m" ? "5m" : interval;
    if (!unchangedContinuousHistory(previous, raw, source, now)) continue;
    const key = (point: { time: number; price: number; kind: string }) => `${point.time}:${point.price}:${point.kind}`;
    const confirmed = new Map(previous.snapshot.series[interval].contextPoints
      .filter((point) => point.trend === "up" || point.trend === "down").map((point) => [key(point), point.trend]));
    for (const point of series[interval].contextPoints) {
      if (!point.trend && confirmed.has(key(point))) point.trend = confirmed.get(key(point));
    }
  }
}

function validQuote(quote: AnalysisQuote | null | undefined, now: number): quote is AnalysisQuote {
  return !!quote && Number.isFinite(quote.price) && quote.price > 0 && Number.isFinite(quote.time)
    && Number.isFinite(now) && now >= quote.time - 5;
}

export function isQuoteFresh(quote: AnalysisQuote | null | undefined, now: number): boolean {
  return validQuote(quote, now) && now - quote.time <= 15;
}

/** Preserve exchange event time: receipt of an old packet must not refresh a quote. */
export function newestValidQuote(current: AnalysisQuote | null, next: AnalysisQuote, now: number): AnalysisQuote | null {
  if (!validQuote(next, now)) return validQuote(current, now) ? current : null;
  return validQuote(current, now) && current.time >= next.time ? current : next;
}

type AnalysisStreamEvent = { type: "ticker"; quote: AnalysisQuote } | { type: "kline"; candle: Candle; time: number; closed: boolean };

export function parseAnalysisStreamMessage(message: string, symbol: string, now: number): AnalysisStreamEvent | null {
  try {
    const envelope = JSON.parse(message);
    const data = envelope?.data ?? envelope;
    const integratedChannel = envelope?.type === "event" ? envelope.channel : undefined;
    const integratedTime = Number(data?.eventTime ?? envelope?.timestamp) / 1000;
    const time = Number.isFinite(integratedTime) ? integratedTime : Number(data?.E) / 1000;
    const dataSymbol = data?.symbol ?? data?.s;
    if (!data || dataSymbol !== symbol) return null;
    if (!Number.isFinite(time) || now - time > 15 || now < time - 5) return null;
    if (integratedChannel === "market.ticker" || data.e === "24hrTicker") {
      const quote = { price: Number(data.lastPrice ?? data.c), time, source: "整合行情 WSS" };
      return isQuoteFresh(quote, now) ? { type: "ticker", quote } : null;
    }
    if (integratedChannel === "market.kline" || (data.e === "kline" && data.k?.i === "1m" && data.k.s === symbol)) {
      const k = data.k ?? data;
      const candle = { time: Number(k.openTime ?? k.t) / 1000, open: Number(k.openPrice ?? k.o), high: Number(k.highPrice ?? k.h), low: Number(k.lowPrice ?? k.l), close: Number(k.closePrice ?? k.c), volume: Number(k.volume ?? k.v) };
      if (Object.values(candle).every(Number.isFinite) && candle.time % 60 === 0 && candle.time <= now + 5
        && candle.low > 0 && candle.high >= candle.low && candle.open >= candle.low && candle.open <= candle.high
        && candle.close >= candle.low && candle.close <= candle.high) return { type: "kline", candle, time, closed: k.closed === true || k.x === true };
    }
  } catch { /* Ignore malformed packets without refreshing source timestamps. */ }
  return null;
}

/** Include a continuous forming bucket only for candidates; its target close is still in the future. */
export function candlesWithFormingBucket(candles: Candle[], sourceSeconds: number, targetSeconds: number, now: number, confirmedThrough = now) {
  const complete = aggregateCandles(candles, sourceSeconds, targetSeconds, Math.min(now, confirmedThrough));
  const start = Math.floor(now / targetSeconds) * targetSeconds;
  const currentChild = Math.floor((now - start) / sourceSeconds);
  const byTime = new Map(candles.map((candle) => [candle.time, candle]));
  const children: Candle[] = [];
  for (let index = 0; index <= currentChild; index++) {
    const child = byTime.get(start + index * sourceSeconds);
    if (!child || !Object.values(child).every(Number.isFinite) || child.low <= 0 || child.high < child.low || child.open < child.low || child.open > child.high || child.close < child.low || child.close > child.high) return complete;
    children.push(child);
  }
  // A new forming bucket cannot replace the last valid confirmed history while
  // the intervening bucket is still waiting for source close certification.
  const latestComplete = complete[complete.length - 1];
  if (latestComplete && latestComplete.time + targetSeconds !== start) return complete;
  complete.push({
    time: start, open: children[0].open, close: children[children.length - 1].close,
    high: Math.max(...children.map((candle) => candle.high)), low: Math.min(...children.map((candle) => candle.low)),
    volume: children.reduce((sum, candle) => sum + candle.volume, 0),
  });
  return complete;
}


/** Provisional inheritance is only a hint; the larger period must confirm independently. */
function inheritPendingTurns(series: Record<AnalysisInterval, PivotSeries>, tickSize: number) {
  const ordered: AnalysisInterval[] = ["2m", "5m", "10m", "15m", "1h"];
  for (let largerIndex = 1; largerIndex < ordered.length; largerIndex++) {
    const larger = series[ordered[largerIndex]];
    if (larger.status !== "ready") continue;
    for (const anchor of larger.points.slice(-6)) {
      if (anchor.trend) continue;
      const matches = ordered.slice(0, largerIndex).some((interval) =>
        series[interval].status === "ready" && series[interval].contextPoints.some((point) =>
          (point.trend === "up" || point.trend === "down") && point.kind === anchor.kind &&
          point.time >= anchor.time && point.time < anchor.time + intervalSeconds[larger.interval] &&
          Math.abs(point.price - anchor.price) <= Math.max(tickSize * 5, anchor.price * 0.0005),
        ),
      );
      if (matches) anchor.trend = "pending";
    }
  }
}


export function buildAnalysisSnapshot(raw: RawAnalysisSnapshot | null, symbol: string, now: number, previous?: SnapshotHistory | null): AnalysisSnapshot | null {
    if (!raw || raw.symbol !== symbol) return null;
    const quote = validQuote(raw.quote, now) ? raw.quote : null;
    const freshQuote = isQuoteFresh(quote, now) ? quote : null;
    const previousBox = previous?.snapshot?.symbol === symbol
      && previous.snapshot.series["2m"].box
      && !previous.snapshot.series["2m"].box.historical
      && unchangedContinuousHistory(previous, raw, "1m", now)
      ? previous.snapshot.series["2m"].box : undefined;
    const cutoff = (interval: SourceInterval) => Math.min(now, raw.confirmedThrough?.[interval] ?? raw.receivedAt[interval] ?? now);
    const candleMap: Record<AnalysisInterval, Candle[]> = {
      "2m": candlesWithFormingBucket(raw.candles["1m"] ?? [], 60, 120, now, cutoff("1m")),
      "5m": raw.candles["5m"] ?? [],
      "10m": candlesWithFormingBucket(raw.candles["5m"] ?? [], 300, 600, now, cutoff("5m")),
      "15m": raw.candles["15m"] ?? [],
      "1h": raw.candles["1h"] ?? [],
    };
    const currentBoll = (interval: "30m" | "4h") => {
      const received = raw.receivedAt[interval];
      const seconds = intervalSeconds[interval];
      const closed = continuousClosedCandles(raw.candles[interval] ?? [], seconds, cutoff(interval));
      const latest = closed[closed.length - 1];
      if (!received || now - received > 150 || !latest || latest.time + seconds < Math.floor(now / seconds) * seconds) return null;
      return bollingerLevels(closed, interval.toUpperCase());
    };
    const boll30 = currentBoll("30m");
    const boll4h = currentBoll("4h");
    const series = Object.fromEntries((Object.keys(candleMap) as AnalysisInterval[]).map((interval) => {
      const source: SourceInterval = interval === "2m" ? "1m" : interval === "10m" ? "5m" : interval;
      const updatedAt = raw.receivedAt[source] ?? 0;
      const result = buildPivotSeries(interval, raw.tickSize ? candleMap[interval] : [], {
        now, confirmedThrough: cutoff(source), tickSize: raw.tickSize ?? 0, price: freshQuote?.price ?? null, quoteTime: freshQuote?.time ?? null,
        boll: interval === "15m" || interval === "1h" ? boll4h : boll30,
        context15m: continuousClosedCandles(raw.candles["15m"] ?? [], 900, cutoff("15m")),
        context30m: continuousClosedCandles(raw.candles["30m"] ?? [], 1800, cutoff("30m")),
        previousBox: interval === "2m" ? previousBox : undefined,
      });
      result.updatedAt = updatedAt;
      const lastClosed = result.lastCandleClose;
      if (!updatedAt || !raw.tickSize || !lastClosed) result.status = "waiting";
      else if (now - updatedAt > 150 || lastClosed < Math.floor(now / intervalSeconds[interval]) * intervalSeconds[interval]) result.status = "stale";
      else result.status = result.contextPoints.length >= 4 || (interval === "2m" && result.box) ? "ready" : "waiting";
      if (result.status === "stale") result.candidate = null;
      return [interval, result];
    })) as Record<AnalysisInterval, PivotSeries>;
    retainConfirmedTurns(series, raw, now, previous);
    if (raw.tickSize) inheritPendingTurns(series, raw.tickSize);
    const indicators = indicatorIntervals.map((interval) => {
      const seconds = intervalSeconds[interval];
      const result = buildIndicatorRow(interval, raw.candles[interval] ?? [], cutoff(interval));
      const received = raw.receivedAt[interval];
      const closed = continuousClosedCandles(raw.candles[interval] ?? [], seconds, cutoff(interval));
      const lastClose = closed.length ? closed[closed.length - 1].time + seconds : null;
      if (result.status === "ready" && (!received || now - received > 150 || lastClose === null || lastClose < Math.floor(now / seconds) * seconds)) result.status = "stale";
      return result;
    });
    return { symbol, quote, series, indicators, fetchedAt: raw.fetchedAt };
}
