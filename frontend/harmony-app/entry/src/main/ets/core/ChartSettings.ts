import { DataValue } from './Json';
import { INTERVALS } from './Market';

export const OVERLAYS: string[] = ['MA', 'EMA', 'BOLL', 'SAR', 'AVL', 'SUPER'];
export const PANELS: string[] = ['VOL', 'MACD', 'RSI', 'KDJ', 'OBV', 'WR', 'StochRSI', 'ATR', 'O.I.', 'L.S Acco.', 'L.S Posit.', 'L.S Ratio', 'B.S Vol.', 'Basis'];
export const DEFAULT_FAVORITES: string = '3m,5m,15m,1h,4h,1d';
export function favoriteIntervals(value: string): string[] {
  const result = INTERVALS.filter((v: string) => value.split(',').includes(v)).slice(0, 6);
  return result.length ? result : DEFAULT_FAVORITES.split(',');
}
export function visibleIntervals(value: string, selected: string): string[] {
  const favorites = favoriteIntervals(value);
  if (!favorites.includes(selected) && INTERVALS.includes(selected)) { if (favorites.length === 6) favorites.pop(); favorites.push(selected); }
  return INTERVALS.filter((v: string) => favorites.includes(v));
}
export function toggleFavorite(value: string, interval: string): string {
  const values = favoriteIntervals(value);
  if (values.includes(interval)) { if (values.length === 1) return values.join(','); return values.filter((v: string) => v !== interval).join(','); }
  if (values.length >= 6 || !INTERVALS.includes(interval)) return values.join(',');
  return INTERVALS.filter((v: string) => values.includes(v) || v === interval).join(',');
}
export class ParameterField {
  key: string; title: string; value: number; min: number; max: number; integer: boolean;
  constructor(key: string, title: string, value: number, min: number, max: number, integer: boolean = true) {
    this.key = key; this.title = title; this.value = value; this.min = min; this.max = max; this.integer = integer;
  }
}
export function parameterFields(kind: string): ParameterField[] {
  if (kind === 'MA' || kind === 'EMA') return (kind === 'MA' ? [7, 25, 99] : [21, 55, 144]).map((v: number, i: number) => new ParameterField(kind + i, ['短周期', '中周期', '长周期'][i], v, 1, 500));
  const fields: Record<string, ParameterField[]> = {
    BOLL: [new ParameterField('bollPeriod', '周期', 20, 1, 500), new ParameterField('bollMultiplier', '标准差倍数', 2, 0.1, 20, false)],
    SAR: [new ParameterField('sarStart', '起始步长', 0.02, 0.001, 1, false), new ParameterField('sarMax', '最大步长', 0.2, 0.001, 5, false)],
    SUPER: [new ParameterField('superPeriod', 'ATR 周期', 10, 1, 200), new ParameterField('superMultiplier', '倍数', 6, 0.1, 20, false)],
    VOL: [new ParameterField('volFast', '短均量周期', 5, 1, 200), new ParameterField('volSlow', '长均量周期', 10, 1, 500)],
    MACD: [new ParameterField('macdFast', '快线周期', 12, 1, 200), new ParameterField('macdSlow', '慢线周期', 26, 2, 500), new ParameterField('macdSignal', '信号周期', 9, 1, 200)],
    RSI: [new ParameterField('rsiPeriod', '周期', 14, 1, 200)],
    KDJ: [new ParameterField('kdjPeriod', '周期', 9, 1, 200), new ParameterField('kdjK', 'K 平滑', 3, 1, 50), new ParameterField('kdjD', 'D 平滑', 3, 1, 50)],
    WR: [new ParameterField('wrPeriod', '周期', 14, 1, 200)],
    StochRSI: [new ParameterField('stochPeriod', 'RSI 周期', 14, 1, 200), new ParameterField('stochWindow', '随机周期', 14, 1, 200), new ParameterField('stochK', 'K 平滑', 3, 1, 50), new ParameterField('stochD', 'D 平滑', 3, 1, 50)],
    ATR: [new ParameterField('atrPeriod', '周期', 14, 1, 200)]
  };
  return fields[kind] || [];
}
export class IndicatorParameters {
  values: Record<string, number> = {};
  constructor() {
    for (const kind of OVERLAYS.concat(PANELS)) for (const field of parameterFields(kind)) this.values[field.key] = field.value;
    this.values['superAlpha'] = 0.16;
  }
  static load(text: string): IndicatorParameters {
    const result = new IndicatorParameters();
    try { const data = DataValue.parse(text); for (const key of Object.keys(result.values)) if (!data.get(key).empty()) result.values[key] = data.get(key).number(NaN); } catch (_) { return new IndicatorParameters(); }
    return result.valid() ? result : new IndicatorParameters();
  }
  valid(): boolean {
    for (const kind of OVERLAYS.concat(PANELS)) for (const field of parameterFields(kind)) {
      const value = this.values[field.key];
      if (!Number.isFinite(value) || value < field.min || value > field.max || (field.integer && !Number.isInteger(value))) return false;
    }
    for (const name of ['MA', 'EMA']) if (!(this.values[name + 0] < this.values[name + 1] && this.values[name + 1] < this.values[name + 2])) return false;
    return this.values['sarStart'] <= this.values['sarMax'] && this.values['volFast'] <= this.values['volSlow'] && this.values['macdFast'] < this.values['macdSlow']
      && Number.isFinite(this.values['superAlpha']) && this.values['superAlpha'] >= 0 && this.values['superAlpha'] <= 1;
  }
  json(): string { return JSON.stringify(this.values); }
  fillAlpha(dark: boolean): number { const fraction = 1 - Math.min(1, this.values['superAlpha'] / 0.2); return dark ? 0.2 * (1 - fraction) : 0.6 - 0.2 * fraction; }
}
