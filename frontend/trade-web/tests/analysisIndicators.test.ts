import type { Candle } from "../src/lib/binance";
import {
  bollingerLevels, buildIndicatorRow, continuousClosedCandles, intervalSeconds,
} from "../src/lib/analysisIndicators.js";
import {
  analysisSources, buildAnalysisSnapshot, candlesWithFormingBucket, isQuoteFresh,
  mergeRestCandles, newestValidQuote, parseAnalysisStreamMessage, type RawAnalysisSnapshot,
} from "../src/lib/analysisSnapshot.js";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function closeTo(actual: number | null | undefined, expected: number, message: string) {
  assert(actual != null && Math.abs(actual - expected) < 1e-9, `${message}: expected ${expected}, got ${actual}`);
}

function candle(time: number, close = 100): Candle {
  return { time, open: close, high: close + .5, low: close - .5, close, volume: 1 };
}

const constant = Array.from({ length: 200 }, (_, index) => candle(index * 300));
const constantRow = buildIndicatorRow("5m", constant, 60001);
assert(constantRow.status === "ready", "200 complete candles provide sufficient indicator history");
for (const key of ["ema21", "ema55", "ema144"] as const) closeTo(constantRow[key], 100, `constant ${key}`);
closeTo(constantRow.macd, 0, "flat prices have a zero MACD histogram");
closeTo(constantRow.stochK, 50, "flat RSI has a neutral finite StochRSI K");
closeTo(constantRow.stochD, 50, "flat RSI has a neutral finite StochRSI D");
closeTo(constantRow.boll?.upper, 100, "flat Bollinger upper band");
closeTo(constantRow.boll?.lower, 100, "flat Bollinger lower band");

const linear = constant.map((value, index) => candle(value.time, 100 + index));
const linearRow = buildIndicatorRow("5m", linear, 60001);
assert(linearRow.trend === "up", "linear rising prices produce ascending EMA structure");
// For a unit linear ramp, an SMA-seeded N-period EMA lags the latest price by (N-1)/2.
closeTo(linearRow.ema21, 299 - 10, "linear EMA21 has the expected ten-bar lag");
closeTo(linearRow.ema55, 299 - 27, "linear EMA55 has the expected 27-bar lag");
closeTo(linearRow.ema144, 299 - 71.5, "linear EMA144 has the expected 71.5-bar lag");
closeTo(linearRow.macd, 0, "a constant rate of price change has a zero settled MACD histogram");
assert(buildIndicatorRow("5m", constant.map((value, index) => candle(value.time, 300 - index)), 60001).trend === "down", "falling prices produce descending EMA structure");
const wave = constant.map((value, index) => candle(value.time, 100 + Math.sin(index * .21) * 10));
const waveRow = buildIndicatorRow("5m", wave, 60001);
assert(Number.isFinite(waveRow.macd), "oscillating prices have a finite MACD histogram");
assert(waveRow.stochK != null && waveRow.stochK >= 0 && waveRow.stochK <= 100, "StochRSI K stays within its percentage bounds");
assert(waveRow.stochD != null && waveRow.stochD >= 0 && waveRow.stochD <= 100, "StochRSI D stays within its percentage bounds");

const twenty = Array.from({ length: 20 }, (_, index) => candle(index * 300, index + 1));
const boll = bollingerLevels(twenty, "5M");
closeTo(boll?.middle, 10.5, "Bollinger uses the actual trailing twenty-price mean");
closeTo(boll?.upper, 10.5 + 2 * Math.sqrt(33.25), "Bollinger uses population variance rather than sample variance");
closeTo(boll?.lower, 10.5 - 2 * Math.sqrt(33.25), "Bollinger lower band is symmetric");
assert(bollingerLevels(twenty.slice(1), "5M") === null, "Bollinger waits for twenty complete candles");

assert(buildIndicatorRow("5m", constant.slice(0, 143), 42901).ema144 === null, "EMA144 is unavailable before its full warmup");
assert(buildIndicatorRow("5m", constant.slice(0, 143), 42901).status === "waiting", "insufficient history is explicitly waiting");
const forming = constant.concat(candle(60000, 999));
assert(continuousClosedCandles(forming, 300, 60001).length === 200, "an unfinished candle is excluded");
closeTo(buildIndicatorRow("5m", forming, 60001).price, 100, "unfinished extremes cannot move confirmed indicators");
const gap = constant.filter((_, index) => index !== 100);
assert(continuousClosedCandles(gap, 300, 60001).length === 99, "a missing candle restarts indicator history");
assert(buildIndicatorRow("5m", gap, 60001).status === "waiting", "a gap can invalidate EMA warmup");
const malformed = constant.map((value, index) => index === 100 ? { ...value, close: 500 } : value);
assert(continuousClosedCandles(malformed, 300, 60001).length === 99, "an OHLC value outside the candle range cannot bridge history");
const nonFinite = constant.map((value, index) => index === 100 ? { ...value, high: NaN } : value);
assert(continuousClosedCandles(nonFinite, 300, 60001).length === 99, "nonfinite prices cannot bridge history");
assert(continuousClosedCandles(constant.concat(candle(59700, 100.1)), 300, 60001).length === 200, "duplicate candle timestamps do not increase history length");
assert(buildIndicatorRow("5m", constant, 60301).status === "stale", "a missing expected period close is stale even before source timeout");

const now = 1_800_300;
const quote = { price: 105, time: now, source: "test exchange" };
assert(isQuoteFresh(quote, now + 15), "fifteen-second quote boundary is still accepted");
assert(!isQuoteFresh(quote, now + 15.001), "quotes older than fifteen seconds are stale");
assert(!isQuoteFresh({ ...quote, time: now + 6 }, now), "quotes beyond clock-skew tolerance are rejected");
assert(!isQuoteFresh({ ...quote, price: Infinity }, now), "nonfinite quotes are rejected");
assert(!isQuoteFresh({ ...quote, price: 0 }, now), "nonpositive quotes are rejected");
assert(newestValidQuote(quote, { ...quote, price: 99, time: now - 1 }, now)?.price === 105, "delayed packets cannot replace a newer quote");
assert(newestValidQuote(quote, { ...quote, price: 999, time: now + 60 }, now)?.price === 105, "future packets cannot poison the latest quote");

const ticker = (time: number, symbol = "BTCUSDT") => JSON.stringify({ data: { e: "24hrTicker", E: time * 1000, s: symbol, c: "105" } });
const parsed = parseAnalysisStreamMessage(ticker(now - 2), "BTCUSDT", now);
assert(parsed?.type === "ticker" && parsed.quote.time === now - 2, "stream quotes retain exchange event time rather than packet receipt time");
assert(parseAnalysisStreamMessage(ticker(now - 16), "BTCUSDT", now) === null, "recent receipt of an old ticker cannot refresh freshness");
assert(parseAnalysisStreamMessage(ticker(now + 6), "BTCUSDT", now) === null, "future ticker packets are ignored");
assert(parseAnalysisStreamMessage(ticker(now, "ETHUSDT"), "BTCUSDT", now) === null, "ticker packets cannot cross symbols");
assert(parseAnalysisStreamMessage("not json", "BTCUSDT", now) === null, "malformed stream packets are ignored");

function marketSnapshot(time: number): RawAnalysisSnapshot {
  const data: RawAnalysisSnapshot = { symbol: "BTCUSDT", candles: {}, receivedAt: {}, confirmedThrough: {}, quote: { ...quote, time }, tickSize: .01, fetchedAt: time };
  for (const interval of analysisSources) {
    const seconds = intervalSeconds[interval];
    const end = Math.floor(time / seconds) * seconds;
    data.candles[interval] = Array.from({ length: 300 }, (_, index) => {
      const phase = index % 24;
      return candle(end - (300 - index) * seconds, 100 + (phase <= 12 ? phase : 24 - phase));
    }).concat(candle(end, 110));
    data.receivedAt[interval] = time;
    data.confirmedThrough![interval] = time;
  }
  return data;
}
const raw = marketSnapshot(now);
const snapshot = buildAnalysisSnapshot(raw, "BTCUSDT", now);
assert(snapshot !== null && snapshot.series["10m"].status === "ready", "complete 10M stays ready halfway into the next candle, beyond the generic 150-second age");
assert(snapshot.series["5m"].status === "ready" && snapshot.indicators.every((row) => row.status === "ready"), "one fresh symbol-scoped snapshot drives all indicator periods");
assert(buildAnalysisSnapshot(raw, "ETHUSDT", now) === null, "symbol changes cannot display the previous snapshot");
const staleSource = buildAnalysisSnapshot({ ...raw, receivedAt: { ...raw.receivedAt, "5m": now - 151 } }, "BTCUSDT", now);
assert(staleSource?.series["5m"].status === "stale" && staleSource.series["10m"].status === "stale", "source timeout expires both native and derived periods");
assert(staleSource.series["5m"].candidate === null && staleSource.series["10m"].candidate === null, "stale candle sources cannot display active candidates");
assert(staleSource.indicators.find((row) => row.interval === "5m")?.status === "stale", "source timeout also expires indicators");
const staleBoll = buildAnalysisSnapshot({ ...raw, receivedAt: { ...raw.receivedAt, "4h": now - 151 } }, "BTCUSDT", now);
assert(staleBoll?.series["15m"].boll === null && staleBoll.series["1h"].boll === null, "stale higher-period sources cannot display old Bollinger levels");
const missingClose = (raw.candles["5m"] ?? []).filter((value) => value.time < Math.floor(now / 300) * 300 - 300);
const expiredClose = buildAnalysisSnapshot({ ...raw, candles: { ...raw.candles, "5m": missingClose } }, "BTCUSDT", now);
assert(expiredClose?.series["5m"].status === "stale", "a source receipt cannot make an overdue period close current");
const futureQuote = buildAnalysisSnapshot({ ...raw, quote: { ...quote, time: now + 60, price: 999 } }, "BTCUSDT", now);
assert(futureQuote?.quote === null, "future quotes are omitted from the rendered snapshot");
const oldQuote = buildAnalysisSnapshot({ ...raw, quote: { ...quote, time: now - 16, price: 999 } }, "BTCUSDT", now);
assert(oldQuote?.series["5m"].candidate?.price !== 999, "expired quote prices cannot extend snapshot candidates");
const noTick = buildAnalysisSnapshot({ ...raw, tickSize: null }, "BTCUSDT", now);
assert(noTick?.series["5m"].status === "waiting" && noTick.series["5m"].points.length === 0, "deviation waits for the real contract minimum tick");

const childCandles = [candle(0, 100), candle(60, 110)];
const partial = candlesWithFormingBucket(childCandles, 60, 120, 90);
assert(partial.length === 1 && partial[0].high === 110.5 && partial[0].time + 120 > 90, "forming child extrema extend only a future-closing candidate bucket");
assert(candlesWithFormingBucket(childCandles.slice(1), 60, 120, 90).length === 0, "a forming aggregate cannot hide a missing earlier child");

const hourlyBoundary = 1_803_600;
const beforeBoundary = marketSnapshot(hourlyBoundary - 1);
const beforeSnapshot = buildAnalysisSnapshot(beforeBoundary, "BTCUSDT", hourlyBoundary - 1);
const afterClockOnly = buildAnalysisSnapshot(beforeBoundary, "BTCUSDT", hourlyBoundary + 1);
assert(beforeSnapshot !== null && afterClockOnly !== null, "rollover snapshots exist");
assert(afterClockOnly.series["1h"].lastCandleClose === beforeSnapshot.series["1h"].lastCandleClose, "clock rollover cannot certify the cached forming 1H candle");
assert(afterClockOnly.series["1h"].points.length === beforeSnapshot.series["1h"].points.length, "clock rollover cannot add confirmed hourly pivots");
assert(afterClockOnly.series["1h"].status === "stale", "hourly rollover waits for an actually observed final candle");
assert(afterClockOnly.indicators.find((row) => row.interval === "1h")?.price === beforeSnapshot.indicators.find((row) => row.interval === "1h")?.price, "cached forming close cannot enter hourly indicators");
assert(afterClockOnly.indicators.find((row) => row.interval === "1h")?.status === "stale", "hourly indicators expose the overdue period close");
assert(afterClockOnly.series["2m"].lastCandleClose === beforeSnapshot.series["2m"].lastCandleClose, "clock rollover cannot promote an uncertified 1M child into 2M");
assert(afterClockOnly.series["10m"].lastCandleClose === beforeSnapshot.series["10m"].lastCandleClose, "clock rollover cannot promote an uncertified 5M child into 10M");
const lateResponse = buildAnalysisSnapshot({ ...beforeBoundary, receivedAt: { ...beforeBoundary.receivedAt, "1h": hourlyBoundary + 1 } }, "BTCUSDT", hourlyBoundary + 1);
assert(lateResponse?.series["1h"].lastCandleClose === beforeSnapshot.series["1h"].lastCandleClose, "a response arriving after a boundary still uses conservative request-start certification");
const observedFinal: RawAnalysisSnapshot = {
  ...beforeBoundary,
  candles: {
    ...beforeBoundary.candles,
    "1h": (beforeBoundary.candles["1h"] ?? []).map((value) => value.time === hourlyBoundary - 3600 ? candle(value.time, 150) : value).concat(candle(hourlyBoundary, 151)),
  },
  receivedAt: { ...beforeBoundary.receivedAt, "1h": hourlyBoundary + 1 },
  confirmedThrough: { ...beforeBoundary.confirmedThrough, "1h": hourlyBoundary + 1 },
};
const finalSnapshot = buildAnalysisSnapshot(observedFinal, "BTCUSDT", hourlyBoundary + 1);
assert(finalSnapshot?.series["1h"].lastCandleClose === hourlyBoundary && finalSnapshot.series["1h"].status === "ready", "a fresh post-boundary source observation certifies the final candle");
closeTo(finalSnapshot.indicators.find((row) => row.interval === "1h")?.price, 150, "only the newly observed final OHLC enters indicators");

const streamCandle = (closed: boolean) => JSON.stringify({ data: { e: "kline", E: now * 1000, s: "BTCUSDT", k: { s: "BTCUSDT", i: "1m", t: Math.floor(now / 60) * 60000, o: "105", h: "106", l: "104", c: "105", v: "1", x: closed } } });
const formingEvent = parseAnalysisStreamMessage(streamCandle(false), "BTCUSDT", now);
const finalEvent = parseAnalysisStreamMessage(streamCandle(true), "BTCUSDT", now);
assert(formingEvent?.type === "kline" && !formingEvent.closed && finalEvent?.type === "kline" && finalEvent.closed, "stream finality distinguishes forming updates from exchange-certified closes");
const restHistory = [candle(0, 101), candle(60, 102), candle(120, 103)];
const cachedStream = [candle(0, 90), candle(60, 91), candle(120, 110), candle(180, 111)];
const merged = mergeRestCandles(restHistory, cachedStream, 150);
assert(merged[0].close === 101 && merged[1].close === 102, "old cached partial values cannot overwrite earlier REST final candles");
assert(merged[2].close === 110 && merged[3].close === 111, "stream updates from the request's forming minute onward survive REST completion");

const lockBase = buildAnalysisSnapshot(raw, "BTCUSDT", now);
assert(lockBase !== null, "lock baseline exists");
const anchor = lockBase.series["5m"].contextPoints.filter((point) => point.kind === "low").slice(-1)[0];
assert(anchor !== undefined, "lock baseline has a confirmed low anchor");
anchor.trend = "up"; // Represents a reaction previously confirmed by a valid quote.
const lockHistory = { raw, snapshot: lockBase, now };
const locked = buildAnalysisSnapshot({ ...raw, quote: { ...quote, price: 104 } }, "BTCUSDT", now + 1, lockHistory);
const anchorIn = (data: ReturnType<typeof buildAnalysisSnapshot>) => data?.series["5m"].contextPoints.find((point) => point.time === anchor.time && point.kind === anchor.kind && point.price === anchor.price);
assert(anchorIn(locked)?.trend === "up", "a valid quote reaction stays confirmed after a later retrace");
const rolling = { ...raw, candles: { ...raw.candles, "5m": raw.candles["5m"]!.slice(1) } };
assert(anchorIn(buildAnalysisSnapshot(rolling, "BTCUSDT", now + 1, lockHistory))?.trend === "up", "normal left-edge history trimming preserves an existing anchor's confirmation");
const revised = { ...raw, candles: { ...raw.candles, "5m": raw.candles["5m"]!.map((value, index) => index === 2 ? { ...value, open: value.open + .1 } : value) } };
assert(anchorIn(buildAnalysisSnapshot(revised, "BTCUSDT", now + 1, lockHistory))?.trend !== "up", "revised closed history invalidates retained quote evidence");
const newGap = { ...raw, candles: { ...raw.candles, "5m": raw.candles["5m"]!.filter((_, index) => index !== 10) } };
assert(anchorIn(buildAnalysisSnapshot(newGap, "BTCUSDT", now + 1, lockHistory))?.trend !== "up", "a new history gap cannot carry prior reaction evidence");
const otherSymbol = { ...raw, symbol: "ETHUSDT" };
assert(anchorIn(buildAnalysisSnapshot(otherSymbol, "ETHUSDT", now + 1, lockHistory))?.trend !== "up", "quote reaction locks never cross symbols");
anchor.trend = "pending";
assert(anchorIn(buildAnalysisSnapshot(raw, "BTCUSDT", now + 1, lockHistory))?.trend !== "pending", "provisional cross-period hints are recalculated and never retained as reaction evidence");

// A valid established box must survive normal rolling-source truncation, while
// gaps, revised closed OHLC and symbol changes invalidate its locked evidence.
const boxOrigin = 1_814_400;
const boxWave = Array.from({ length: 90 }, (_, index) => {
  const phase = index % 12;
  const close = 100 + (phase <= 6 ? phase : 12 - phase);
  return { time: boxOrigin + index * 120, open: close, close, high: close + .2, low: close - .2, volume: 2 };
});
const minuteChildren = (values: Candle[]) => values.flatMap((value) => [
  { ...value, volume: value.volume / 2 },
  { ...value, time: value.time + 60, volume: value.volume / 2 },
]);
function boxRaw(candles: Candle[], time: number): RawAnalysisSnapshot {
  return {
    symbol: "BTCUSDT", candles: { "1m": minuteChildren(candles) },
    receivedAt: { "1m": time }, confirmedThrough: { "1m": time },
    quote: { price: 103, time, source: "test exchange" }, tickSize: .01, fetchedAt: time,
  };
}
const initialBoxTime = boxOrigin + boxWave.length * 120 + 1;
const initialBoxRaw = boxRaw(boxWave, initialBoxTime);
const initialBoxSnapshot = buildAnalysisSnapshot(initialBoxRaw, "BTCUSDT", initialBoxTime);
const originalBox = initialBoxSnapshot?.series["2m"].box;
assert(originalBox && !originalBox.historical, "snapshot establishes a qualified active 2M box");
const boxHistory = { raw: initialBoxRaw, snapshot: initialBoxSnapshot, now: initialBoxTime };
const pendingBoundary = boxOrigin + 92 * 120 + 1;
const pendingBoxRaw: RawAnalysisSnapshot = {
  ...initialBoxRaw,
  candles: { "1m": initialBoxRaw.candles["1m"]!.concat(
    candle(boxOrigin + 90 * 120, 103), candle(boxOrigin + 90 * 120 + 60, 103),
    candle(boxOrigin + 91 * 120, 103), candle(boxOrigin + 91 * 120 + 60, 103),
    candle(boxOrigin + 92 * 120, 103),
  ) },
  receivedAt: { "1m": pendingBoundary },
};
const pendingBoxSnapshot = buildAnalysisSnapshot(pendingBoxRaw, "BTCUSDT", pendingBoundary, boxHistory);
assert(pendingBoxSnapshot?.series["2m"].box?.startTime === originalBox.startTime, "an uncertified close followed by a forming bucket does not erase the last confirmed box");
assert(pendingBoxSnapshot.series["2m"].lastCandleClose === initialBoxSnapshot.series["2m"].lastCandleClose && pendingBoxSnapshot.series["2m"].status === "stale", "uncertified intervening buckets keep the old close and explicitly wait for refresh");
const moreBoxCandles = Array.from({ length: 30 }, (_, index) => {
  const phase = index % 12;
  const close = 101 + (phase <= 6 ? phase : 12 - phase) * .7;
  return { time: boxOrigin + (90 + index) * 120, open: close, close, high: close + .15, low: close - .15, volume: 2 };
});
const rolledTime = boxOrigin + 120 * 120 + 1;
const rolledBoxRaw = boxRaw(boxWave.slice(-24).concat(moreBoxCandles), rolledTime);
const rolledBoxSnapshot = buildAnalysisSnapshot(rolledBoxRaw, "BTCUSDT", rolledTime, boxHistory);
const rolledBox = rolledBoxSnapshot?.series["2m"].box;
assert(rolledBox?.startTime === originalBox.startTime && rolledBox.high === originalBox.high && rolledBox.low === originalBox.low, "normal rolling history preserves original box identity and fixed edges");
assert(rolledBox.endTime > originalBox.endTime && rolledBox.rounds >= originalBox.rounds, "retained box advances on newly confirmed data without losing its prior round trips");
const gapBoxRaw = { ...rolledBoxRaw, candles: { "1m": rolledBoxRaw.candles["1m"]!.filter((_, index) => index !== 8) } };
assert(buildAnalysisSnapshot(gapBoxRaw, "BTCUSDT", rolledTime, boxHistory)?.series["2m"].box?.startTime !== originalBox.startTime, "a new missing 1M child prevents resuming an old locked box across the gap");
const revisedBoxRaw = { ...rolledBoxRaw, candles: { "1m": rolledBoxRaw.candles["1m"]!.map((value, index) => index === 2 ? { ...value, high: value.high + .05 } : value) } };
assert(buildAnalysisSnapshot(revisedBoxRaw, "BTCUSDT", rolledTime, boxHistory)?.series["2m"].box?.startTime !== originalBox.startTime, "revised historical OHLC restarts box evidence");
assert(buildAnalysisSnapshot({ ...rolledBoxRaw, symbol: "ETHUSDT" }, "ETHUSDT", rolledTime, boxHistory)?.series["2m"].box?.startTime !== originalBox.startTime, "fixed box edges cannot cross contract symbols");

console.log("analysisIndicators: indicator, quote, snapshot and rolling-box regressions passed");
