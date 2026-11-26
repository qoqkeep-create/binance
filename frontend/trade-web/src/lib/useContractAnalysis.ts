import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { get24hTickers, getKlines, type Candle } from "./binance";
import { marketRealtime } from "./realtime";
import { buildPivotSeries } from "./contractAnalysis";
import {
  analysisSources as sources, buildAnalysisSnapshot, mergeRestCandles, newestValidQuote,
  type AnalysisQuote as Quote, type RawAnalysisSnapshot, type SnapshotHistory, type SourceInterval,
} from "./analysisSnapshot";

import { allSettledLimited } from "./marketReliability";

const tickCache = new Map<string, { value: number; time: number }>();
interface CandleBatch { candles: Candle[]; receivedAt: number; confirmedThrough: number }

async function fetchCandles(symbol: string, interval: SourceInterval, signal: AbortSignal, endTime?: number): Promise<CandleBatch> {
  const limit = ["1m", "5m", "15m", "1h"].includes(interval) ? 720 : 300;
  // A request straddling a boundary must not certify the candle that was forming when it began.
  const confirmedThrough = Date.now() / 1000;
  const candles = await getKlines(symbol, interval, limit, signal, endTime === undefined ? undefined : Math.floor(endTime));
  if (!candles.length) throw new Error("暂无有效K线");
  return { candles, receivedAt: Date.now() / 1000, confirmedThrough };
}

async function fetchTickSize(symbol: string, signal: AbortSignal): Promise<number> {
  const cached = tickCache.get(symbol);
  if (cached && Date.now() / 1000 - cached.time < 900) return cached.value;
  const quote = await get24hTickers(signal);
  const current = quote.find((item) => item.symbol === symbol)?.lastPrice ?? 0;
  const estimated = current >= 1000 ? 0.01 : current >= 1 ? 0.0001 : current >= 0.01 ? 0.000001 : 0.00000001;
  const now = Date.now() / 1000;
  if (estimated > 0) tickCache.set(symbol, { value: estimated, time: now });
  const tick = tickCache.get(symbol)?.value;
  if (!tick) throw new Error("合约最小价位尚未同步");
  return tick;
}

async function fetchQuote(symbol: string, signal: AbortSignal): Promise<Quote> {
  const data = (await get24hTickers(signal)).find((item) => item.symbol === symbol);
  const price = data?.lastPrice ?? 0;
  const time = (data?.eventTime ?? Date.now()) / 1000;
  if (!data || !(price > 0) || !Number.isFinite(time)) throw new Error("报价返回异常");
  return { price, time, source: "整合行情服务" };
}

export function useContractAnalysis(symbol: string) {
  const [raw, setRaw] = useState<RawAnalysisSnapshot | null>(null);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [now, setNow] = useState(() => Date.now() / 1000);
  const refreshRef = useRef<(() => void) | null>(null);
  const historyRef = useRef<SnapshotHistory | null>(null);
  const refresh = useCallback(() => refreshRef.current?.(), []);

  useEffect(() => {
    let active = true;
    let pending = false;
    let initialRetryCount = 0;
    let initialRetryTimer: ReturnType<typeof globalThis.setTimeout> | undefined;
    const controller = new AbortController();
    setRaw(null);
    setError(null);
    setLoading(true);
    setRefreshing(false);

    async function load(initial = false) {
      if (pending || !active) return;
      pending = true;
      if (!initial) setRefreshing(true);
      const candleResultsPromise = allSettledLimited(
        sources.map((interval) => () => fetchCandles(symbol, interval, controller.signal)),
        3,
      );
      const metadataResultsPromise = Promise.allSettled([
        fetchTickSize(symbol, controller.signal),
        fetchQuote(symbol, controller.signal),
      ]);
      const [candleResults, metadataResults] = await Promise.all([candleResultsPromise, metadataResultsPromise]);
      const results = [...candleResults, ...metadataResults];
      const tickResult = results[sources.length];
      const tickSize = tickResult.status === "fulfilled" ? tickResult.value as number : null;
      let backfillFailures = 0;
      if (tickSize && active) {
        const backfills = await Promise.allSettled((["15m", "1h"] as const).map(async (interval) => {
          const index = sources.indexOf(interval);
          const result = results[index];
          if (result.status !== "fulfilled") return;
          const batch = result.value as CandleBatch;
          if (batch.candles.length < 1500 || buildPivotSeries(interval, batch.candles, {
            now: batch.receivedAt, confirmedThrough: batch.confirmedThrough, tickSize, price: null, quoteTime: null,
          }).points.length >= 24) return;
          // At most one older page per period; young contracts and missing history remain explicit.
          const older = await fetchCandles(symbol, interval, controller.signal, batch.candles[0].time * 1000 - 1);
          results[index] = { status: "fulfilled", value: { ...batch, candles: older.candles.concat(batch.candles) } };
        }));
        backfillFailures = backfills.filter((result) => result.status === "rejected").length;
      }
      pending = false;
      if (!active) return;
      const fetchedAt = Date.now() / 1000;
      setNow(fetchedAt);
      setRaw((previous) => {
        const current: RawAnalysisSnapshot = previous?.symbol === symbol ? {
          ...previous, candles: { ...previous.candles }, receivedAt: { ...previous.receivedAt }, fetchedAt,
          confirmedThrough: { ...previous.confirmedThrough },
        } : { symbol, candles: {}, receivedAt: {}, confirmedThrough: {}, quote: null, tickSize: null, fetchedAt };
        sources.forEach((interval, index) => {
          const result = results[index];
          if (result.status === "fulfilled") {
            const batch = result.value as CandleBatch;
            if (interval === "1m" && (current.receivedAt[interval] ?? 0) > batch.confirmedThrough) {
              // Preserve updates received while the other REST intervals were loading.
              current.candles[interval] = mergeRestCandles(batch.candles, current.candles[interval] ?? [], batch.confirmedThrough);
            } else {
              current.candles[interval] = batch.candles;
            }
            current.receivedAt[interval] = Math.max(current.receivedAt[interval] ?? 0, batch.receivedAt);
            current.confirmedThrough![interval] = Math.max(current.confirmedThrough?.[interval] ?? 0, batch.confirmedThrough);
          }
        });
        const tick = results[sources.length];
        if (tick.status === "fulfilled") current.tickSize = tick.value as number;
        const quote = results[sources.length + 1];
        if (quote.status === "fulfilled") {
          const value = quote.value as Quote;
          current.quote = newestValidQuote(current.quote, value, fetchedAt);
        }
        return current;
      });
      const failed = results.filter((result) => result.status === "rejected").length + backfillFailures;
      const allInitialRequestsFailed = failed === results.length;
      if (allInitialRequestsFailed) {
        // Keep the first transient outage quiet while the automatic recovery
        // attempts run. A warning is shown only after those attempts are used.
        setError(initial && initialRetryCount < 2 ? null : "行情暂时无法加载，请检查网络后重试。");
        // After the final automatic attempt, enable the visible manual retry.
        setLoading(initial && initialRetryCount < 2);
        setRefreshing(false);
        if (initial && active && initialRetryCount < 2) {
          const delay = initialRetryCount === 0 ? 2_000 : 5_000;
          initialRetryCount += 1;
          initialRetryTimer = globalThis.setTimeout(() => {
            initialRetryTimer = undefined;
            void load(true);
          }, delay);
        }
        return;
      }
      initialRetryCount = 0;
      setError(failed ? "部分周期暂未同步，已保留最近有效数据。" : null);
      setLoading(false);
      setRefreshing(false);
    }

    refreshRef.current = () => {
      if (initialRetryTimer) globalThis.clearTimeout(initialRetryTimer);
      initialRetryTimer = undefined;
      initialRetryCount = 0;
      void load();
    };
    void load(true);
    const refreshTimer = window.setInterval(() => { void load(); }, 45000);
    const clockTimer = window.setInterval(() => setNow(Date.now() / 1000), 1000);
    const unsubscribe = marketRealtime.subscribe({ symbol, interval: "1m", handler: (event) => {
        if (!active) return;
        const sampledAt = Date.now() / 1000;
        if (event.type === "ticker") {
          setRaw((previous) => {
            const current: RawAnalysisSnapshot = previous?.symbol === symbol ? previous : { symbol, candles: {}, receivedAt: {}, confirmedThrough: {}, tickSize: null, fetchedAt: sampledAt, quote: null };
            return { ...current, quote: newestValidQuote(current.quote, { price: event.price, time: (event.eventTime ?? Date.now()) / 1000, source: "整合行情 WSS" }, sampledAt) };
          });
        } else if (event.type === "kline") {
          setRaw((previous) => {
            if (!previous || previous.symbol !== symbol || !previous.candles["1m"]?.length) return previous;
            const eventTime = (event.eventTime ?? Date.now()) / 1000;
            if (eventTime < (previous.receivedAt["1m"] ?? 0)) return previous;
            if (event.candle.time + 60 <= (previous.confirmedThrough?.["1m"] ?? 0)) return previous;
            const candles = [...previous.candles["1m"]];
            const index = candles.findIndex((candle) => candle.time === event.candle.time);
            if (index >= 0) candles[index] = event.candle;
            else if (event.candle.time > candles[candles.length - 1].time) candles.push(event.candle);
            else return previous;
            return {
              ...previous, candles: { ...previous.candles, "1m": candles.slice(-1500) }, receivedAt: { ...previous.receivedAt, "1m": eventTime },
              confirmedThrough: {
                ...previous.confirmedThrough,
                "1m": event.closed ? event.candle.time + 60 : previous.confirmedThrough?.["1m"] ?? 0,
              },
            };
          });
        }
      } });
    return () => {
      active = false;
      controller.abort();
      window.clearInterval(refreshTimer);
      window.clearInterval(clockTimer);
      if (initialRetryTimer) globalThis.clearTimeout(initialRetryTimer);
      unsubscribe();
      refreshRef.current = null;
    };
  }, [symbol]);

  const snapshot = useMemo(() => buildAnalysisSnapshot(raw, symbol, now, historyRef.current), [raw, symbol, now]);
  useEffect(() => { historyRef.current = { raw, snapshot, now }; }, [raw, snapshot, now]);

  return { snapshot, loading, refreshing, error, refresh };
}
