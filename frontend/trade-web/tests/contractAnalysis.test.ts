import type { Candle } from "../src/lib/binance";
import type { Pivot } from "../src/lib/analysisTypes";
import {
  aggregateCandles, buildPivotSeries, describeStructure, findBox,
  findSwingRange, fractalPivots, markTrendReversals, zigzagPivots,
} from "../src/lib/contractAnalysis.js";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function candle(time: number, low: number, high: number, close = (low + high) / 2): Candle {
  return { time, low, high, close, open: close, volume: 1 };
}

function pivot(index: number, price: number, kind: Pivot["kind"]): Pivot {
  return { time: index * 300, confirmedAt: (index + 1) * 300, price, kind };
}

const oneMinute = [candle(0, 10, 12, 11), candle(60, 9, 14, 13), candle(120, 11, 15, 12), candle(180, 10, 16, 15)];
const twoMinute = aggregateCandles(oneMinute, 60, 120, 240);
assert(twoMinute.length === 2, "2M requires two full 1M children");
assert(twoMinute[0].open === 11 && twoMinute[0].close === 13 && twoMinute[0].high === 14 && twoMinute[0].low === 9 && twoMinute[0].volume === 2, "aggregate preserves OHLCV");
assert(aggregateCandles(oneMinute.filter((c) => c.time !== 60), 60, 120, 240).length === 1, "missing 1M child cannot produce 2M");
assert(aggregateCandles(oneMinute, 60, 120, 239).length === 1, "forming 1M cannot complete a historical 2M");
assert(aggregateCandles([candle(0, 10, 12), candle(600, 9, 14)], 300, 600, 1200).length === 0, "missing 5M cannot produce 10M");
assert(aggregateCandles([...oneMinute, oneMinute[0]], 60, 120, 240).length === 2, "duplicate source timestamps are not counted twice");

const highs = [11, 12, 15, 15, 15, 13, 12, 10, 9, 8, 10, 11];
const lows = [9, 10, 11, 11, 11, 10, 9, 8, 7, 5, 8, 9];
const platform = highs.map((high, i) => candle(i * 120, lows[i], high));
const fractals = fractalPivots(platform);
assert(fractals.length === 2 && fractals[0].time === 240, "platform anchors first equal high");
assert(fractals[0].confirmedAt === 840, "platform requires two following closed candles");
assert(fractals[1].kind === "low" && fractals[1].price === 5, "fractal pivots alternate");
assert(fractalPivots(platform.slice(0, 6)).length === 0, "platform remains unconfirmed with one right bar");
const outside = [candle(0, 5, 10), candle(120, 5, 10), candle(240, 1, 20), candle(360, 5, 10), candle(480, 5, 10)];
assert(fractalPivots(outside).length === 0, "a simultaneous high/low pivot is skipped");

const options = { now: 1440, tickSize: .01, price: 12, quoteTime: 1440 };
const series = buildPivotSeries("2m", platform, options);
const movedQuote = buildPivotSeries("2m", platform, { ...options, price: 30 });
assert(series.points.length === movedQuote.points.length, "intrabar quote changes do not add confirmed points");
assert(movedQuote.candidate?.price === 30 && movedQuote.candidate.confirmedAt === 0, "live quote extends only the candidate");
const staleQuote = buildPivotSeries("2m", platform, { ...options, price: 30, quoteTime: 1400 });
assert(staleQuote.candidate?.price !== 30, "expired quote cannot extend the candidate");
const afterGap = platform.concat([candle(1800, 9, 12), candle(1920, 10, 13)]);
assert(buildPivotSeries("2m", afterGap, { ...options, now: 2040 }).contextPoints.length === 0, "candle gaps restart the continuous calculation context");
assert(buildPivotSeries("2m", platform, { ...options, now: 1439 }).points.length === 1, "a forming right confirmation candle is excluded");
const cachedForming = buildPivotSeries("2m", platform, { ...options, now: 1445, quoteTime: 1445, confirmedThrough: 1439 });
assert(cachedForming.points.length === 1 && cachedForming.lastCandleClose === 1320, "wall clock cannot promote cached forming OHLC into a confirmed candle");
assert(buildPivotSeries("2m", platform, { ...options, now: 1445, quoteTime: 1445, confirmedThrough: 1445 }).points.length === 2, "a fresh source observation after close permits confirmation");

const wave = Array.from({ length: 360 }, (_, i) => {
  const phase = i % 24;
  const value = 100 + (phase <= 12 ? phase : 24 - phase);
  return candle(i * 300, value - 1, value + 1);
});
const zigzag = zigzagPivots(wave, 300, .01);
assert(zigzag.length >= 20, "ZigZag confirms repeated direction changes");
assert(zigzag.every((p, i) => !i || (p.time > zigzag[i - 1].time && p.kind !== zigzag[i - 1].kind)), "ZigZag points strictly increase in time and alternate");
assert(zigzag.every((p) => p.confirmedAt > p.time), "ZigZag records the direction switch confirmation time");

const descending = [130, 120, 120, 110, 110, 100, 100, 90, 90, 60].map((value, i) => pivot(i, value, i % 2 ? "low" : "high"));
const reversed = markTrendReversals(descending.concat(pivot(10, 120, "high")), null);
assert(reversed[9].trend === "up", "structural reaction above prior highs validates a lower-low reversal");
assert(markTrendReversals(descending.concat(pivot(10, 120, "high")), 50)[9].trend === "up", "later quotes do not erase an already confirmed reversal");
assert(markTrendReversals(descending, 120)[9].trend === "up", "fresh price can validate a structural reaction");
const invalidated = descending.concat(pivot(10, 75, "high"), pivot(11, 55, "low"), pivot(12, 130, "high"));
assert(markTrendReversals(invalidated, null)[9].trend === undefined, "a new lower low invalidates the older waiting reversal anchor");

const rising = [100, 90, 110, 100, 120, 110].map((value, i) => pivot(i, value, i % 2 ? "low" : "high"));
assert(describeStructure(rising, 115).bias === "up", "higher highs and higher lows form an ascending structure");
assert(describeStructure(rising, 105).description === "原结构抬高，现价下破前低", "live breach is reported against the prior rising structure");
const structure = describeStructure(rising, 115);
assert(structure.supports.join(",") === "110,100" && structure.resistances[0] === 120, "confirmed attention levels deduplicate and sort around current price");

const oscillation = [100, 110, 101, 111, 100, 109, 101, 110].map((value, i) => pivot(i, value, i % 2 ? "high" : "low"));
const range = findSwingRange(oscillation, 105);
assert(range?.rounds === 3 && !range.historical, "first qualified eight-point range reports three round trips");
assert(findSwingRange(oscillation, 113)?.breakout === "up", "five-percent range-width buffer marks an outside observation");
assert(describeStructure(oscillation, 105, range).supports[0] === 100, "range edges replace structure attention levels");

const boxCandles = Array.from({ length: 90 }, (_, i) => {
  const phase = i % 12;
  const value = 100 + (phase <= 6 ? phase : 12 - phase);
  return candle(i * 120, value - .2, value + .2, value);
});
const boxPivots = fractalPivots(boxCandles);
const box = findBox(boxCandles, boxPivots);
assert(box !== null && !box.historical && box.rounds >= 1, "complete sideways candles with repeated edge touches establish a box");
assert(box.upperBoundary > box.lowerBoundary && box.high > box.upperBoundary && box.low < box.lowerBoundary, "box exposes fixed 20/80 percent boundaries");
const breakoutCandles = boxCandles.concat(candle(90 * 120, 108, 110, 109));
assert(findBox(breakoutCandles, boxPivots)?.breakout === undefined, "one closed breakout candle does not register a box breakout");
breakoutCandles.push(candle(91 * 120, 109, 111, 110));
const brokenBox = findBox(breakoutCandles, boxPivots);
assert(brokenBox?.breakout === "up" && brokenBox.historical, "two consecutive closed candles register a box breakout");
assert(brokenBox.high === box.high && brokenBox.low === box.low, "confirmed box edges stay locked through breakout");
const longBoxCandles = Array.from({ length: 750 }, (_, i) => {
  const phase = i % 12;
  const value = 100 + (phase <= 6 ? phase : 12 - phase) + (i >= 150 ? .5 : 0);
  return candle(i * 120, value - .2, value + .2, value);
});
const longBox = findBox(longBoxCandles, fractalPivots(longBoxCandles));
assert(longBox?.high === box.high && longBox.low === box.low, "a long-lived box retains original edges beyond the previous 360-bar replay horizon");

assert(box.candleCount >= 12 && box.candleCount <= 60 && box.confirmedAt <= box.endTime, "box records its valid confirmation window and timestamp");
assert(box.upperTouches >= 2 && box.lowerTouches >= 2 && box.high - box.low >= box.atr * 1.25 && box.efficiency <= .4, "confirmation metadata proves touches, ATR width and efficiency constraints");
assert(box.classificationPending === true, "missing prior context is explicitly pending rather than a neutral classification");
assert(findBox(boxCandles.slice(0, 11), boxPivots) === null, "fewer than twelve candles cannot establish a box");
assert(findBox(boxCandles.slice(0, 20), fractalPivots(boxCandles.slice(0, 20))) === null, "unconfirmed second edge touches cannot establish a box");
const onlyOneUpper = boxPivots.filter((point) => point.kind === "low" || point === boxPivots.find((p) => p.kind === "high"));
assert(findBox(boxCandles, onlyOneUpper) === null, "at least two confirmed touches are required on each edge");
assert(findBox(boxCandles, [boxPivots[0], boxPivots[0], boxPivots[1], boxPivots[1]]) === null, "duplicate pivots cannot masquerade as repeated touches");
const overlyWideCandles = Array.from({ length: 60 }, (_, i) => {
  const value = 100 + Math.sin(i * .6) * .1;
  return candle(i * 120, value - 10, value + 10, value);
});
assert(findBox(overlyWideCandles, fractalPivots(overlyWideCandles)) === null, "a narrow swing relative to ATR does not qualify even with repeated extrema");
const wideningUpper = boxCandles.slice(0, 60).map((c, i) => i % 12 === 6 ? { ...c, high: c.high + Math.floor(i / 12) * 20 } : c);
assert(findBox(wideningUpper, fractalPivots(wideningUpper)) === null, "two highs must actually touch the calculated upper-edge tolerance");
const nearTouchCandles = boxCandles.slice(0, 27).map((c, i) => i === 18 ? candle(c.time, 105.5, 105.9, 105.7) : c);
const nearTouchBox = findBox(nearTouchCandles, fractalPivots(nearTouchCandles));
assert(nearTouchBox !== null && nearTouchBox.upperTouches === 2, "a nearby high inside the ATR-based edge tolerance counts as a touch");
const edgeTolerance = Math.min((nearTouchBox.high - nearTouchBox.low) * .2, Math.max(nearTouchBox.atr * .35, (nearTouchBox.high - nearTouchBox.low) * .05));
assert(.3 <= edgeTolerance, "touch metadata uses min(width20%, max(ATR35%, width5%))");
const distantTouchCandles = boxCandles.slice(0, 27).map((c, i) => i === 18 ? candle(c.time, 105.3, 105.7, 105.5) : c);
assert(findBox(distantTouchCandles, fractalPivots(distantTouchCandles)) === null, "a second high outside the edge tolerance is rejected");
const withGap = boxCandles.filter((_, i) => i < 80 || i > 82);
assert(findBox(withGap, fractalPivots(boxCandles)) === null, "a recent two-minute gap discards the earlier box context");
const trendingCloses = Array.from({ length: 60 }, (_, i) => {
  const close = 100 + i * .1;
  return candle(i * 120, i % 12 === 9 ? 80 : close - .1, i % 12 === 3 ? 120 : close + .1, close);
});
assert(fractalPivots(trendingCloses).length >= 4 && findBox(trendingCloses, fractalPivots(trendingCloses)) === null, "efficient directional closes fail the 0.40 box efficiency limit despite repeated edge wicks");
const outsideWindowClose = boxCandles.slice(0, 27).map((c, i) => i === 26 ? { ...c, open: 130, close: 130, high: 130 } : c);
assert(findBox(outsideWindowClose, fractalPivots(outsideWindowClose)) === null, "a candidate window with a close outside confirmed edges is rejected");
const distantEdges = Array.from({ length: 100 }, (_, i) => candle(i * 120, i === 35 || i === 85 ? 90 : 99.9, i === 10 || i === 60 ? 110 : 100.1, 100));
assert(fractalPivots(distantEdges).length === 4 && findBox(distantEdges, fractalPivots(distantEdges)) === null, "four edge touches spanning more than sixty candles cannot form one candidate window");
const flatCloses = Array.from({ length: 27 }, (_, i) => candle(i * 120, i === 12 || i === 24 ? 90 : 99.9, i === 6 || i === 18 ? 110 : 100.1, 100));
assert(findBox(flatCloses, fractalPivots(flatCloses))?.efficiency === 0, "zero net/path close movement has zero efficiency when edge pivots independently qualify");
const wickOnly = boxCandles.concat(candle(90 * 120, 90, 130, 103));
const wickBox = findBox(wickOnly, fractalPivots(wickOnly));
assert(wickBox?.high === box.high && wickBox.low === box.low && !wickBox.breakout && !wickBox.pendingBreakout, "wicks beyond the edges cannot move or break a confirmed box");
const replacedPivotHistory = boxCandles.slice(0, 26).concat(
  ...[102, 103, 102, 100, 99, 100, 101].map((close, i) => candle((26 + i) * 120, close - .2, 110, close)),
);
const replacedPivots = fractalPivots(replacedPivotHistory);
assert(!replacedPivots.some((p) => p.time === 24 * 120 && p.kind === "low"), "fixture replaces the earlier confirmed low while the opposing high platform is still unconfirmed");
const stableHistoricalBox = findBox(replacedPivotHistory, replacedPivots);
assert(stableHistoricalBox?.low === box.low && stableHistoricalBox.confirmedAt === box.confirmedAt, "later same-kind pivot replacement cannot rewrite an already-established historical box");
const oneAbove = boxCandles.concat(candle(90 * 120, 108, 110, 109));
const pendingAbove = findBox(oneAbove, fractalPivots(oneAbove));
assert(pendingAbove?.pendingBreakout === "up" && pendingAbove.pendingBreakoutCount === 1 && !pendingAbove.breakoutAt, "one outside close is exposed as pending rather than confirmed");
const resetInside = oneAbove.concat(candle(91 * 120, 102, 104, 103), candle(92 * 120, 108, 110, 109));
assert(findBox(resetInside, fractalPivots(resetInside))?.pendingBreakoutCount === 1, "an inside close resets the consecutive-breakout streak");
const changedSide = oneAbove.concat(candle(91 * 120, 94, 96, 95));
const changedSideBox = findBox(changedSide, fractalPivots(changedSide));
assert(changedSideBox?.pendingBreakout === "down" && changedSideBox.pendingBreakoutCount === 1 && !changedSideBox.breakout, "an opposite outside close starts a new one-close streak");
const exactBuffer = box.high + (box.high - box.low) * .02;
const onBuffer = oneAbove.concat(candle(91 * 120, 103, exactBuffer + 1, exactBuffer));
assert(!findBox(onBuffer, fractalPivots(onBuffer))?.breakout && !findBox(onBuffer, fractalPivots(onBuffer))?.pendingBreakout, "a close exactly on the two-percent buffer is not beyond it");
const belowTwice = boxCandles.concat(candle(90 * 120, 94, 96, 95), candle(91 * 120, 93, 95, 94));
const downwardBox = findBox(belowTwice, fractalPivots(belowTwice));
assert(downwardBox?.historical && downwardBox.breakout === "down" && downwardBox.breakoutAt === 92 * 120, "two consecutive lower closes confirm a timestamped downward breakout");
const seededBreakout = oneAbove.concat(candle(91 * 120, 109, 111, 110)).slice(-16);
const carriedBreakout = findBox(seededBreakout, fractalPivots(seededBreakout), [], [], pendingAbove ?? undefined);
assert(carriedBreakout?.breakout === "up" && carriedBreakout.confirmedAt === box.confirmedAt && carriedBreakout.high === box.high, "a one-close breakout streak survives a rolling-history trim");
const stationaryLong = longBoxCandles.map((c, i) => i < 150 ? c : { ...c, open: c.open - .5, high: c.high - .5, low: c.low - .5, close: c.close - .5 });
const beforeTrim = stationaryLong.slice(0, 400);
const seededBeforeTrim = findBox(beforeTrim, fractalPivots(beforeTrim));
const afterTrim = stationaryLong.slice(350, 500);
const rolledBox = findBox(afterTrim, fractalPivots(afterTrim), [], [], seededBeforeTrim ?? undefined);
const fullBoxAt500 = findBox(stationaryLong.slice(0, 500), fractalPivots(stationaryLong.slice(0, 500)));
assert(rolledBox?.high === box.high && rolledBox.low === box.low && rolledBox.confirmedAt === box.confirmedAt, "rolling history retains original established edges and confirmation time");
assert(rolledBox?.rounds === fullBoxAt500?.rounds && (rolledBox?.rounds ?? 0) > (seededBeforeTrim?.rounds ?? 0), "round trips increment once across trims without resetting or double counting");
assert(findBox(afterTrim, fractalPivots(afterTrim), [], [], rolledBox ?? undefined)?.rounds === rolledBox?.rounds, "replaying an unchanged seeded snapshot does not double count round trips");
const outsidePivotCandles = boxCandles.concat(
  candle(90 * 120, 102, 130, 103), candle(91 * 120, 102, 104, 103),
  candle(92 * 120, 99.8, 100.2, 100), candle(93 * 120, 100.8, 101.2, 101), candle(94 * 120, 101.8, 102.2, 102),
);
assert(findBox(outsidePivotCandles, fractalPivots(outsidePivotCandles))?.rounds === box.rounds, "a confirmed extreme outside the fixed box is excluded from inside-box round trips");
const newBoxCandles = boxCandles.map((c) => ({ ...c, time: c.time + 100 * 120, open: c.open - 50, high: c.high - 50, low: c.low - 50, close: c.close - 50 }));
const newBoxAfterHistoricalSeed = findBox(newBoxCandles, fractalPivots(newBoxCandles), [], [], brokenBox);
assert(newBoxAfterHistoricalSeed?.high === box.high - 50 && !newBoxAfterHistoricalSeed.historical, "a historical seed cannot prevent a new independent box from being detected");

function priorContext(seconds: number, count: number, low: number, high: number, startClose: number, step: number) {
  const boundary = Math.floor(box!.startTime / seconds) * seconds;
  return Array.from({ length: count }, (_, i) => candle(boundary - (count - i) * seconds, low, high, startClose + i * step));
}
const topFifteen = priorContext(900, 20, 70, 110, 80, 1);
const topThirty = priorContext(1800, 4, 70, 110, 80, 5);
const topBox = findBox(boxCandles, boxPivots, topFifteen, topThirty);
assert(topBox?.placement === "顶部箱体" && !topBox.classificationPending, "rising 15M and 30M context plus a midpoint above seventy percent classifies a top box");
const bottomFifteen = priorContext(900, 20, 100, 140, 130, -1);
const bottomThirty = priorContext(1800, 4, 100, 140, 130, -5);
const bottomBox = findBox(boxCandles, boxPivots, bottomFifteen, bottomThirty);
assert(bottomBox?.placement === "底部箱体" && !bottomBox.classificationPending, "falling 15M and 30M context plus a midpoint below thirty percent classifies a bottom box");
assert(findBox(boxCandles, boxPivots, priorContext(900, 20, 96, 106, 97, .4), priorContext(1800, 4, 96, 106, 97, 1))?.placement === "顶部箱体", "the seventy-percent position threshold is inclusive");
assert(findBox(boxCandles, boxPivots, priorContext(900, 20, 100, 110, 109, -.4), priorContext(1800, 4, 100, 110, 108, -2))?.placement === "底部箱体", "the thirty-percent position threshold is inclusive");
const neutralBox = findBox(boxCandles, boxPivots, topFifteen, bottomThirty);
assert(neutralBox?.placement === "箱体整理" && !neutralBox.classificationPending, "opposing prior directions yield a valid neutral classification");
assert(findBox(boxCandles, boxPivots, topFifteen.slice(1), topThirty)?.classificationPending, "nineteen prior 15M candles are insufficient for classification");
assert(findBox(boxCandles, boxPivots, topFifteen, topThirty.slice(1))?.classificationPending, "three prior 30M candles are insufficient for classification");
assert(findBox(boxCandles, boxPivots, topFifteen.filter((_, i) => i !== 10), topThirty)?.classificationPending, "gapped 15M history cannot satisfy the twenty-candle context minimum");
assert(findBox(boxCandles, boxPivots, topFifteen, topThirty.filter((_, i) => i !== 1))?.classificationPending, "gapped 30M history cannot satisfy the four-candle context minimum");
const oldFifteen = topFifteen.map((c) => ({ ...c, time: c.time - 900 }));
assert(findBox(boxCandles, boxPivots, oldFifteen, topThirty)?.classificationPending, "a missing final prior period leaves classification pending even if enough old bars remain");
const maxSixty = priorContext(900, 60, 70, 110, 80, .3);
const olderOutlier = candle(maxSixty[0].time - 900, 1, 1000, 500);
assert(findBox(boxCandles, boxPivots, [olderOutlier, ...maxSixty], topThirty)?.placement === "顶部箱体", "position classification uses at most the most recent sixty prior 15M candles");
const futureFifteen = topFifteen.concat(candle(0, 1, 10000, 9999));
assert(findBox(boxCandles, boxPivots, futureFifteen, topThirty)?.placement === "顶部箱体", "a 15M candle not closed before box start cannot affect prior classification");
const upgradedBox = findBox(boxCandles, boxPivots, topFifteen, topThirty, box);
assert(upgradedBox?.placement === "顶部箱体" && !upgradedBox.classificationPending && upgradedBox.high === box.high && upgradedBox.confirmedAt === box.confirmedAt, "backfilled prior context can classify a pending seeded box without moving its edges");

console.log("contractAnalysis: all deterministic checks passed");
