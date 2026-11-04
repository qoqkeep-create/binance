import test from 'node:test';
import assert from 'node:assert/strict';
import { Candle, INTERVALS, intervalMillis } from '../entry/src/main/ets/core/Market.ts';
import { favoriteIntervals, visibleIntervals, toggleFavorite, IndicatorParameters, DEFAULT_FAVORITES } from '../entry/src/main/ets/core/ChartSettings.ts';
import { ChartViewport, PriceDomain, drawingPrice, ChartTouchState } from '../entry/src/main/ets/core/ChartViewport.ts';
test('13 iOS intervals, favorites normalize, retain selected and respect six/one limits', () => {
  assert.equal(INTERVALS.length, 13); assert.equal(intervalMillis('16h'), 57600000); assert.equal(intervalMillis('3d'), 259200000);
  assert.deepEqual(favoriteIntervals('bad,3m,1m,1m'), ['1m','3m']); assert.deepEqual(favoriteIntervals(''), DEFAULT_FAVORITES.split(','));
  assert.equal(visibleIntervals(DEFAULT_FAVORITES, '16h').length, 6); assert.ok(visibleIntervals(DEFAULT_FAVORITES, '16h').includes('16h'));
  assert.equal(toggleFavorite('1m', '1m'), '1m'); assert.equal(toggleFavorite(DEFAULT_FAVORITES, '1m'), DEFAULT_FAVORITES);
});
test('parameter ranges, ordering and theme transparency match iOS', () => {
  const p = new IndicatorParameters(); assert.ok(p.valid()); assert.ok(Math.abs(p.fillAlpha(false) - .56) < 1e-12); assert.equal(p.fillAlpha(true), .16);
  for (const [key, value] of [['MA0', 25], ['EMA1', 200], ['macdFast', 26], ['sarStart', .3], ['kdjK', 51], ['stochWindow', 0], ['rsiPeriod', 2.5], ['superAlpha', -1]]) { const q = new IndicatorParameters(); q.values[key] = value; assert.equal(q.valid(), false, key); }
  assert.ok(IndicatorParameters.load('{"MA0":-1}').valid());
});
const candles = (n, start=0) => Array.from({length:n},(_,i)=>Object.assign(new Candle(),{time:(start+i+1)*60000,open:100+i,high:102+i,low:99+i,close:101+i}));
test('viewport follows live tail but anchors historical browsing through prepend/append', () => {
  const v = new ChartViewport(); const cs = candles(150); v.update(cs); assert.equal(v.end,150);
  v.pan(30); v.update(cs); const endTime=cs[v.end-1].time;
  const appended=cs.concat(candles(2,150)); v.update(appended); assert.equal(appended[v.end-1].time,endTime);
  const prepended=candles(20,-20).concat(appended); v.update(prepended); assert.equal(prepended[v.end-1].time,endTime);
  v.pan(0); v.update(prepended); assert.equal(v.end,prepended.length);
});
test('auto domain fits visible overlays while manual domain survives quotes, mapping and line bounds are reversible', () => {
  const v = new ChartViewport(); v.update(candles(80), [Array(80).fill(1000)]); assert.ok(v.domain.high>1000);
  v.auto=false; const before=v.domain; v.pan(30); v.update(candles(100)); assert.equal(v.domain,before);
  const d=new PriceDomain(90,110); assert.equal(d.price(d.y(103,30,300),30,300),103); assert.equal(d.shifted(5).low,95); assert.equal(d.scaled(2).high,105);
  assert.equal(drawingPrice(80,d,true,false),80); assert.equal(drawingPrice(80,d,true,true),90); assert.equal(drawingPrice(120,d,false,false),110);
});

test('the same long press tracks continuously; touch end freezes it and a new pan dismisses it', () => {
  const touch = new ChartTouchState(); assert.ok(touch.beginCrosshair(20)); assert.ok(touch.tracking);
  assert.equal(touch.beginPan(), false); touch.endTouch(); assert.equal(touch.tracking, false); assert.equal(touch.cursor,20);
  assert.ok(touch.beginPan()); assert.equal(touch.cursor,-1);
  touch.dragKind='stop'; assert.equal(touch.beginCrosshair(22),false); assert.equal(touch.beginPan(),false);
  touch.endTouch(); assert.ok(touch.beginCrosshair(25)); touch.dismiss(); assert.equal(touch.tracking,false);
});

test('a second finger takes over a crosshair; late single-touch callbacks cannot interrupt or resume after pinch', () => {
  const touch = new ChartTouchState(); touch.beginCrosshair(20);
  touch.beginPinch(); assert.equal(touch.cursor, -1); assert.equal(touch.tracking, false);
  touch.endTouch(); assert.equal(touch.pinching, true); assert.equal(touch.beginPan(), false); assert.equal(touch.beginCrosshair(21), false);
  touch.endPinch(); assert.equal(touch.pinching, false); assert.equal(touch.allowsSingleTouch(), false);
  assert.equal(touch.beginPan(), false); // The remaining finger must lift before a fresh single-touch gesture.
  touch.beginTouch(); assert.equal(touch.allowsSingleTouch(), true); assert.equal(touch.beginPan(), true);
});
