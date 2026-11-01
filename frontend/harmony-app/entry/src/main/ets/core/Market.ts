import { DataValue } from './Json';

export const INTERVALS: string[] = ['1m', '5m', '15m', '1h', '4h', '1d'];
export const INTERVAL_LABELS: string[] = ['1分', '5分', '15分', '1小时', '4小时', '1天'];
export function intervalMillis(interval: string): number {
  const widths: Record<string, number> = { '1m': 60000, '5m': 300000, '15m': 900000, '1h': 3600000, '4h': 14400000, '1d': 86400000 };
  return widths[interval] || 60000;
}
export class Ticker {
  symbol: string = '';
  price: string = '--';
  change: number = 0;
  volume: number = 0;
  eventTime: number = 0;
  static from(value: DataValue): Ticker {
    const ticker = new Ticker(); ticker.symbol = value.value('symbol', ''); ticker.price = value.value('lastPrice');
    ticker.change = value.get('priceChangePercent24h').number(); ticker.volume = value.get('quoteVolume24h').number();
    ticker.eventTime = value.get('eventTime').number(); return ticker;
  }
}
export class Candle {
  time: number = 0;
  eventTime: number = 0;
  open: number = 0;
  high: number = 0;
  low: number = 0;
  close: number = 0;
  volume: number = 0;
  closed: boolean = false;
  live: boolean = false;
  statistics: DataValue = new DataValue();
  static from(value: DataValue, live: boolean = false): Candle {
    const candle = new Candle(); candle.time = value.get('openTime').number(); candle.eventTime = value.get('eventTime').number();
    candle.open = value.get('openPrice').number(NaN); candle.high = value.get('highPrice').number(NaN);
    candle.low = value.get('lowPrice').number(NaN); candle.close = value.get('closePrice').number(NaN); candle.volume = value.get('volume').number();
    candle.closed = value.get('closed').flag(); candle.live = live; candle.statistics = value.get('tradingData'); return candle;
  }
  valid(): boolean { return this.time > 0 && [this.open, this.high, this.low, this.close].every((v: number) => Number.isFinite(v) && v > 0) && this.low <= Math.min(this.open, this.close) && this.high >= Math.max(this.open, this.close); }
}
export class CandleStore {
  candles: Candle[] = [];
  merge(incoming: Candle[]): void {
    const map = new Map<number, Candle>();
    for (const candle of this.candles) map.set(candle.time, candle);
    for (const candle of incoming) {
      if (!candle.valid()) continue;
      const previous = map.get(candle.time);
      if (previous) {
        const stats = DataValue.object(previous.statistics.fields());
        for (const key of Object.keys(candle.statistics.fields())) stats.fields()[key] = candle.statistics.get(key).raw;
        previous.statistics = stats; candle.statistics = stats;
        if (previous.closed && !candle.closed) continue;
        if (previous.live && !candle.live && previous.eventTime >= candle.eventTime) continue;
        if (previous.live && candle.live && previous.eventTime > candle.eventTime) continue;
      }
      map.set(candle.time, candle);
    }
    this.candles = Array.from(map.values()).sort((a: Candle, b: Candle) => a.time - b.time).slice(-5000);
  }
  clear(): void { this.candles = []; }
}

export function priceText(value: string): string {
  const n = Number(value); if (!Number.isFinite(n) || n <= 0) return '--';
  return n >= 100 ? n.toFixed(2) : n >= 1 ? n.toFixed(4).replace(/0+$/, '').replace(/\.$/, '') : n.toFixed(Math.min(12, Math.max(6, 3 - Math.floor(Math.log10(n))))).replace(/0+$/, '').replace(/\.$/, '');
}

export class IndicatorLine {
  name: string;
  color: string;
  values: number[];
  constructor(name: string, color: string, values: number[]) { this.name = name; this.color = color; this.values = values; }
}
export function ema(values: number[], period: number): number[] {
  if (period < 1) return values.map(() => NaN);
  let previous = NaN;
  return values.map((v: number) => { previous = Number.isFinite(previous) ? v * 2 / (period + 1) + previous * (1 - 2 / (period + 1)) : v; return previous; });
}
export function sma(values: number[], period: number): number[] {
  let sum = 0;
  return values.map((v: number, i: number) => { sum += v; if (i >= period) sum -= values[i - period]; return i + 1 >= period ? sum / period : NaN; });
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
export function atr(candles: Candle[], period: number = 14): number[] {
  let average = 0;
  return candles.map((c: Candle, i: number) => {
    const tr = i === 0 ? c.high - c.low : Math.max(c.high - c.low, Math.abs(c.high - candles[i - 1].close), Math.abs(c.low - candles[i - 1].close));
    if (i < period) average += tr / period; else average = (average * (period - 1) + tr) / period;
    return i + 1 < period ? NaN : average;
  });
}
export function mainIndicators(candles: Candle[], kind: string): IndicatorLine[] {
  const close = candles.map((c: Candle) => c.close);
  const colors = ['#F0B90B', '#A78BFA', '#38BDF8'];
  if (kind === 'MA' || kind === 'EMA') return [21, 55, 144].map((n: number, i: number) => new IndicatorLine(kind + n, colors[i], kind === 'EMA' ? ema(close, n) : sma(close, n)));
  if (kind === 'BOLL') {
    const middle = sma(close, 20); const deviation = close.map((v: number, i: number) => {
      if (i < 19) return NaN;
      return Math.sqrt(close.slice(i - 19, i + 1).reduce((sum: number, item: number) => sum + Math.pow(item - middle[i], 2), 0) / 20) * 2;
    });
    return [new IndicatorLine('BOLL', colors[0], middle), new IndicatorLine('UP', colors[1], middle.map((v: number, i: number) => v + deviation[i])), new IndicatorLine('DN', colors[2], middle.map((v: number, i: number) => v - deviation[i]))];
  }
  if (kind === 'AVL') {
    let total = 0; let volume = 0;
    return [new IndicatorLine('AVL', colors[0], candles.map((c: Candle) => { total += (c.high + c.low + c.close) / 3 * c.volume; volume += c.volume; return volume > 0 ? total / volume : NaN; }))];
  }
  if (kind === 'SAR') {
    let up = true; let acceleration = 0.02; let extreme = candles.length ? candles[0].high : 0; let sar = candles.length ? candles[0].low : 0;
    return [new IndicatorLine('SAR', colors[1], candles.map((c: Candle, i: number) => {
      if (i === 0) return sar;
      sar += acceleration * (extreme - sar);
      sar = up ? Math.min(sar, candles[i - 1].low, candles[Math.max(0, i - 2)].low) : Math.max(sar, candles[i - 1].high, candles[Math.max(0, i - 2)].high);
      if ((up && c.low < sar) || (!up && c.high > sar)) { sar = extreme; up = !up; extreme = up ? c.high : c.low; acceleration = 0.02; }
      else if ((up && c.high > extreme) || (!up && c.low < extreme)) { extreme = up ? c.high : c.low; acceleration = Math.min(0.2, acceleration + 0.02); }
      return sar;
    }))];
  }
  if (kind === 'SuperTrend'  || kind === 'SUPER') {
    const ranges = atr(candles, 10); let upper = NaN; let lower = NaN; let up = true;
    const values = candles.map((c: Candle, i: number) => {
      if (!Number.isFinite(ranges[i])) return NaN;
      const mid = (c.high + c.low) / 2; const bu = mid + 3 * ranges[i]; const bl = mid - 3 * ranges[i];
      upper = !Number.isFinite(upper) || bu < upper || candles[i - 1].close > upper ? bu : upper;
      lower = !Number.isFinite(lower) || bl > lower || candles[i - 1].close < lower ? bl : lower;
      if (c.close > upper) up = true; else if (c.close < lower) up = false;
      return up ? lower : upper;
    });
    return [new IndicatorLine('ST(10,3)', colors[0], values)];
  }
  return [];
}
export function panelIndicators(candles: Candle[], kind: string): IndicatorLine[] {
  const close = candles.map((c: Candle) => c.close);
  if (kind === 'RSI') return [new IndicatorLine('RSI14', '#A78BFA', rsi(close))];
  if (kind === 'StochRSI') {
    const values = rsi(close); const raw = values.map((v: number, i: number) => {
      const window = values.slice(Math.max(0, i - 13), i + 1);
      if (window.length < 14 || window.some((n: number) => !Number.isFinite(n))) return NaN;
      const low = Math.min(...window); const high = Math.max(...window); return high === low ? 50 : (v - low) / (high - low) * 100;
    });
    const smooth = (values: number[]): number[] => values.map((v: number, i: number) => i < 2 ? NaN : (values[i - 2] + values[i - 1] + v) / 3);
    const k = smooth(raw); return [new IndicatorLine('K', '#F0B90B', k), new IndicatorLine('D', '#A78BFA', smooth(k))];
  }
  const statistics: Record<string, string[]> = { 'O.I.': ['openInterest'], 'L.S Acco.': ['topLongAccount', 'topShortAccount'], 'L.S Posit.': ['topLongPosition', 'topShortPosition'], 'L.S Ratio': ['globalLongAccount', 'globalShortAccount'], 'B.S Vol.': ['takerBuyVolume', 'takerSellVolume'], 'Basis': ['basis', 'basisRate'] };
  if (statistics[kind]) return statistics[kind].map((key: string, i: number) => new IndicatorLine(key, i === 0 ? '#F0B90B' : '#A78BFA', candles.map((c: Candle) => c.statistics.get(key).number(NaN))));
  if (kind === 'MACD') {
    const fast = ema(close, 12); const slow = ema(close, 26); const dif = fast.map((v: number, i: number) => v - slow[i]); const dea = ema(dif, 9);
    return [new IndicatorLine('DIF', '#F0B90B', dif), new IndicatorLine('DEA', '#A78BFA', dea), new IndicatorLine('MACD', '#38BDF8', dif.map((v: number, i: number) => 2 * (v - dea[i])))];
  }
  if (kind === 'KDJ') {
    let k = 50; let d = 50; const ks: number[] = []; const ds: number[] = []; const js: number[] = [];
    candles.forEach((c: Candle, i: number) => {
      const window = candles.slice(Math.max(0, i - 8), i + 1); const high = Math.max(...window.map((v: Candle) => v.high)); const low = Math.min(...window.map((v: Candle) => v.low));
      const rsv = high === low ? 50 : (c.close - low) / (high - low) * 100; k = k * 2 / 3 + rsv / 3; d = d * 2 / 3 + k / 3;
      ks.push(k); ds.push(d); js.push(3 * k - 2 * d);
    });
    return [new IndicatorLine('K', '#F0B90B', ks), new IndicatorLine('D', '#A78BFA', ds), new IndicatorLine('J', '#38BDF8', js)];
  }
  if (kind === 'ATR') return [new IndicatorLine('ATR14', '#F0B90B', atr(candles))];
  if (kind === 'OBV') {
    let value = 0;
    return [new IndicatorLine('OBV', '#F0B90B', candles.map((c: Candle, i: number) => { if (i > 0) value += c.close > candles[i - 1].close ? c.volume : c.close < candles[i - 1].close ? -c.volume : 0; return value; }))];
  }
  if (kind === 'WR') return [new IndicatorLine('WR14', '#A78BFA', candles.map((c: Candle, i: number) => {
    const window = candles.slice(Math.max(0, i - 13), i + 1); const high = Math.max(...window.map((v: Candle) => v.high)); const low = Math.min(...window.map((v: Candle) => v.low));
    return i < 13 ? NaN : high === low ? -50 : (c.close - high) / (high - low) * 100;
  }))];
  if (kind.startsWith('data:')) return [new IndicatorLine(kind.slice(5), '#38BDF8', candles.map((c: Candle) => c.statistics.get(kind.slice(5)).number(NaN)))];
  if (kind !== 'VOL') return [];
  return [new IndicatorLine('VOL', '#848E9C', candles.map((c: Candle) => c.volume)), new IndicatorLine('MA5', '#F0B90B', sma(candles.map((c: Candle) => c.volume), 5))];
}
