import type { Candle } from './Market';
import { IndicatorParameters } from './ChartSettings';

export class IndicatorLine {
  name: string; color: string; values: number[]; directions: number[] = [];
  constructor(name: string, color: string, values: number[]) { this.name = name; this.color = color; this.values = values; }
}
const COLORS: string[] = ['#F0B90B', '#E840B5', '#8B68C4'];
export function ema(values: number[], period: number): number[] {
  let previous = NaN; let sum = 0; let count = 0;
  return values.map((v: number) => {
    if (!Number.isFinite(v) || period < 1) { previous = NaN; sum = 0; count = 0; return NaN; }
    if (Number.isFinite(previous)) { previous += 2 / (period + 1) * (v - previous); return previous; }
    sum += v; count++; if (count < period) return NaN; previous = sum / period; return previous;
  });
}
export function sma(values: number[], period: number): number[] {
  let sum = 0; const window: number[] = [];
  return values.map((v: number) => {
    if (!Number.isFinite(v) || period < 1) { sum = 0; window.length = 0; return NaN; }
    sum += v; window.push(v); if (window.length > period) sum -= window.shift() || 0;
    return window.length === period ? sum / period : NaN;
  });
}
export function rsi(values: number[], period: number = 14): number[] {
  let gain = 0; let loss = 0;
  return values.map((v: number, i: number) => {
    if (i === 0) return NaN;
    const delta = v - values[i - 1];
    if (i <= period) { gain += Math.max(0, delta) / period; loss += Math.max(0, -delta) / period; }
    else { gain = (gain * (period - 1) + Math.max(0, delta)) / period; loss = (loss * (period - 1) + Math.max(0, -delta)) / period; }
    return i < period ? NaN : loss === 0 ? gain === 0 ? 50 : 100 : 100 - 100 / (1 + gain / loss);
  });
}
function trueRange(candles: Candle[], i: number): number {
  const c = candles[i]; return i === 0 ? c.high - c.low : Math.max(c.high - c.low, Math.abs(c.high - candles[i - 1].close), Math.abs(c.low - candles[i - 1].close));
}
export function atr(candles: Candle[], period: number = 14): number[] {
  let average = 0;
  return candles.map((c: Candle, i: number) => {
    const tr = trueRange(candles, i); if (i < period) average += tr / period; else average = (average * (period - 1) + tr) / period;
    return i + 1 < period ? NaN : average;
  });
}
// Rebuild from immutable candles: a live replacement is never committed twice. Restart after a missing interval.
function segmented(candles: Candle[], kind: string, p: IndicatorParameters, interval: number, panel: boolean): IndicatorLine[] {
  if (!interval || candles.length < 2) return calculate(candles, kind, p, panel);
  let result: IndicatorLine[] = []; let start = 0;
  for (let i = 1; i <= candles.length; i++) {
    if (i !== candles.length && candles[i].time - candles[i - 1].time === interval) continue;
    const lines = calculate(candles.slice(start, i), kind, p, panel);
    if (!result.length) result = lines.map((l: IndicatorLine) => new IndicatorLine(l.name, l.color, []));
    for (let j = 0; j < lines.length; j++) {
      if (start > 0) { lines[j].values[0] = NaN; if (lines[j].directions.length) lines[j].directions[0] = 0; }
      result[j].values = result[j].values.concat(lines[j].values); result[j].directions = result[j].directions.concat(lines[j].directions);
    }
    start = i;
  }
  return result;
}
export function mainIndicators(candles: Candle[], kind: string, p: IndicatorParameters = new IndicatorParameters(), interval: number = 0): IndicatorLine[] { return segmented(candles, kind, p, interval, false); }
export function panelIndicators(candles: Candle[], kind: string, p: IndicatorParameters = new IndicatorParameters(), interval: number = 0): IndicatorLine[] { return segmented(candles, kind, p, interval, true); }
function calculate(candles: Candle[], kind: string, params: IndicatorParameters, panel: boolean): IndicatorLine[] {
  const p = params.values; const close = candles.map((c: Candle) => c.close); const volume = candles.map((c: Candle) => c.volume);
  if (kind === 'MA' || kind === 'EMA') return [0, 1, 2].map((i: number) => new IndicatorLine(kind + '(' + p[kind + i] + '):', kind === 'EMA' ? ['#2DBD85', '#3860F6', '#71269C'][i] : COLORS[i], kind === 'EMA' ? ema(close, p[kind + i]) : sma(close, p[kind + i])));
  if (kind === 'BOLL') {
    const n = p['bollPeriod']; const middle = sma(close, n); const deviation = close.map((v: number, i: number) => i < n - 1 ? NaN : Math.sqrt(close.slice(i - n + 1, i + 1).reduce((sum: number, item: number) => sum + Math.pow(item - middle[i], 2), 0) / n) * p['bollMultiplier']);
    return [new IndicatorLine('BOLL', COLORS[0], middle), new IndicatorLine('UP', COLORS[1], middle.map((v: number, i: number) => v + deviation[i])), new IndicatorLine('DN', COLORS[2], middle.map((v: number, i: number) => v - deviation[i]))];
  }
  if (kind === 'AVL') return [new IndicatorLine('AVL', COLORS[0], candles.map((c: Candle) => c.volume > 0 ? c.quoteVolume / c.volume : NaN))];
  if (kind === 'SAR') {
    let up = true; let acceleration = p['sarStart']; let extreme = NaN; let sar = NaN;
    return [new IndicatorLine('SAR', COLORS[0], candles.map((c: Candle, i: number) => {
      if (i === 0) return NaN;
      if (i === 1) { up = c.high - candles[0].high >= candles[0].low - c.low; extreme = up ? Math.max(c.high, candles[0].high) : Math.min(c.low, candles[0].low); sar = up ? Math.min(c.low, candles[0].low) : Math.max(c.high, candles[0].high); return sar; }
      sar += acceleration * (extreme - sar);
      sar = up ? Math.min(sar, candles[i - 1].low, candles[i - 2].low) : Math.max(sar, candles[i - 1].high, candles[i - 2].high);
      if ((up && c.low < sar) || (!up && c.high > sar)) { sar = extreme; up = !up; extreme = up ? c.high : c.low; acceleration = p['sarStart']; }
      else if ((up && c.high > extreme) || (!up && c.low < extreme)) { extreme = up ? c.high : c.low; acceleration = Math.min(p['sarMax'], acceleration + p['sarStart']); }
      return sar;
    }))];
  }
  if (kind === 'SUPER' || kind === 'SuperTrend') {
    const n = p['superPeriod']; let atrValue = NaN; let upper = NaN; let lower = NaN; let up = true; const directions: number[] = [];
    const values = candles.map((c: Candle, i: number) => {
      if (i < n) { directions.push(0); return NaN; }
      const tr = trueRange(candles, i); atrValue = i === n ? tr : atrValue + (tr - atrValue) / n;
      const mid = (c.high + c.low) / 2; const bu = mid + p['superMultiplier'] * atrValue; const bl = mid - p['superMultiplier'] * atrValue;
      upper = !Number.isFinite(upper) || bu < upper || candles[i - 1].close > upper ? bu : upper;
      lower = !Number.isFinite(lower) || bl > lower || candles[i - 1].close < lower ? bl : lower;
      up = up ? c.close >= lower : c.close > upper; directions.push(up ? 1 : -1); return up ? lower : upper;
    });
    const line = new IndicatorLine('Super(' + n + ',' + p['superMultiplier'] + ')', COLORS[0], values); line.directions = directions; return [line];
  }
  if (!panel) return [];
  if (kind === 'VOL') return [new IndicatorLine('VOL', '#848E9C', volume), new IndicatorLine('MA' + p['volFast'], COLORS[0], sma(volume, p['volFast'])), new IndicatorLine('MA' + p['volSlow'], COLORS[1], sma(volume, p['volSlow']))];
  if (kind === 'MACD') {
    const fast = ema(close, p['macdFast']); const slow = ema(close, p['macdSlow']); const dif = fast.map((v: number, i: number) => v - slow[i]); const dea = ema(dif, p['macdSignal']);
    return [new IndicatorLine('DIF', COLORS[0], dif), new IndicatorLine('DEA', COLORS[1], dea), new IndicatorLine('MACD', COLORS[2], dif.map((v: number, i: number) => 2 * (v - dea[i])))];
  }
  if (kind === 'RSI') return [new IndicatorLine('RSI' + p['rsiPeriod'], COLORS[0], rsi(close, p['rsiPeriod']))];
  if (kind === 'ATR') return [new IndicatorLine('ATR' + p['atrPeriod'], COLORS[0], atr(candles, p['atrPeriod']))];
  if (kind === 'OBV') {
    let value = candles.length ? candles[0].volume : 0;
    return [new IndicatorLine('OBV', COLORS[0], candles.map((c: Candle, i: number) => { if (i > 0) value += c.close > candles[i - 1].close ? c.volume : c.close < candles[i - 1].close ? -c.volume : 0; return value; }))];
  }
  if (kind === 'KDJ' || kind === 'WR') {
    const n = p[kind === 'KDJ' ? 'kdjPeriod' : 'wrPeriod']; let k = 50; let d = 50; const ds: number[] = []; const js: number[] = [];
    const values = candles.map((c: Candle, i: number) => {
      if (i < n - 1) { ds.push(NaN); js.push(NaN); return NaN; }
      const window = candles.slice(i - n + 1, i + 1); const high = Math.max(...window.map((v: Candle) => v.high)); const low = Math.min(...window.map((v: Candle) => v.low));
      if (kind === 'WR') return high === low ? 0 : (c.close - high) / (high - low) * 100;
      const rsv = high === low ? 0 : (c.close - low) / (high - low) * 100;
      k = (k * (p['kdjK'] - 1) + rsv) / p['kdjK']; d = (d * (p['kdjD'] - 1) + k) / p['kdjD']; ds.push(d); js.push(3 * k - 2 * d); return k;
    });
    return kind === 'WR' ? [new IndicatorLine('WR' + n, COLORS[0], values)] : [new IndicatorLine('K', COLORS[0], values), new IndicatorLine('D', COLORS[1], ds), new IndicatorLine('J', COLORS[2], js)];
  }
  if (kind === 'StochRSI') {
    const values = rsi(close, p['stochPeriod']); const raw = values.map((v: number, i: number) => {
      const window = values.slice(Math.max(0, i - p['stochWindow'] + 1), i + 1);
      if (window.length < p['stochWindow'] || window.some((n: number) => !Number.isFinite(n))) return NaN;
      const low = Math.min(...window); const high = Math.max(...window); return high === low ? 0 : (v - low) / (high - low) * 100;
    });
    const k = sma(raw, p['stochK']); const d = sma(k, p['stochD']);
    return [new IndicatorLine('K%', COLORS[0], k), new IndicatorLine('D%', COLORS[2], d)];
  }
  const statistics: Record<string, string[]> = { 'O.I.': ['openInterest', 'notional'], 'L.S Acco.': ['total', 'long', 'ratio'], 'L.S Posit.': ['total', 'long', 'ratio'], 'L.S Ratio': ['total', 'long', 'ratio'], 'B.S Vol.': ['buy', 'sell'], 'Basis': ['basis', 'basisRate', 'futuresPremium', 'indexPremium'] };
  const names: Record<string, string[]> = { 'O.I.': ['O.I.', 'O.I. NV'], 'L.S Acco.': ['S', 'L', 'L.S Acco.'], 'L.S Posit.': ['S', 'L', 'L.S Posit.'], 'L.S Ratio': ['S', 'L', 'L.S Ratio'], 'B.S Vol.': ['B', 'S'], 'Basis': ['Basis', 'BR', 'FP', 'PI'] };
  const statsColors: Record<string, string[]> = { 'O.I.': ['#2EBD85', COLORS[0]], 'L.S Acco.': ['#F6465D', '#2EBD85', COLORS[0]], 'L.S Posit.': ['#F6465D', '#2EBD85', COLORS[0]], 'L.S Ratio': ['#F6465D', '#2EBD85', COLORS[0]], 'B.S Vol.': ['#2EBD85', '#F6465D'], 'Basis': [COLORS[0], '#F6A34D', COLORS[1], '#2EBD85'] };
  return (statistics[kind] || []).map((key: string, index: number) => new IndicatorLine(names[kind][index], statsColors[kind][index], candles.map((c: Candle) => {
    const data = c.statistics;
    const n = (field: string): number => data.get(field).number(NaN);
    if (kind === 'O.I.') return key === 'notional' ? n('openInterestNotional') / c.close : n('openInterest');
    if (kind === 'B.S Vol.') return n(key === 'buy' ? 'takerBuyVolume' : 'takerSellVolume');
    if (kind === 'Basis') {
      if (key === 'basis') return n('basis');
      if (key === 'futuresPremium') return n('futuresPrice') - c.close;
      if (key === 'indexPremium') return n('indexPrice') - c.close;
      const reference = Number.isFinite(n('indexPrice')) ? n('indexPrice') : Number.isFinite(n('futuresPrice')) ? n('futuresPrice') : c.close;
      return n('basisRate') * reference;
    }
    const prefix = kind === 'L.S Acco.' ? 'top' : kind === 'L.S Posit.' ? 'top' : 'global';
    const suffix = kind === 'L.S Posit.' ? 'Position' : 'Account';
    return key === 'total' ? n(prefix + 'Long' + suffix) + n(prefix + 'Short' + suffix) : key === 'long' ? n(prefix + 'Long' + suffix) : n(prefix + 'LongShort' + suffix + 'Ratio');
  })));
}
