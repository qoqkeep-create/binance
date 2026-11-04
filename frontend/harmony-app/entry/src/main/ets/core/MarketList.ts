import { Decimal } from './Decimal';
import { Ticker } from './Market';

export class MarketSort {
  field: string;
  direction: string;
  constructor(field: string = '', direction: string = '') { this.field = field; this.direction = direction; }
  next(field: string): MarketSort {
    const initial = field === 'symbol' ? 'ascending' : 'descending';
    if (field !== this.field) return new MarketSort(field, initial);
    return this.direction === initial ? new MarketSort(field, initial === 'ascending' ? 'descending' : 'ascending') : new MarketSort();
  }
}

export function normalizedSymbols(values: string[]): string[] {
  return Array.from(new Set(values.map((s: string) => s.trim().toUpperCase()).filter((s: string) => /^[A-Z0-9]+USDT$/.test(s))));
}

export function pairPickerSymbols(catalog: string[], watchlist: string[], query: string): string[] {
  const available = new Set(catalog);
  const favorites = watchlist.filter((s: string) => available.has(s));
  const selected = new Set(favorites);
  const normalized = query.trim().replace(/\//g, '').toUpperCase();
  return favorites.concat(catalog.filter((s: string) => !selected.has(s))).filter((s: string) => s.includes(normalized));
}

export function sortedMarketSymbols(watchlist: string[], tickers: Ticker[], sort: MarketSort): string[] {
  const rows = watchlist.slice();
  if (!sort.field) return rows;
  const bySymbol = new Map<string, Ticker>();
  for (const ticker of tickers) bySymbol.set(ticker.symbol, ticker);
  return rows.sort((a: string, b: string) => {
    let comparison = a < b ? -1 : a > b ? 1 : 0;
    if (sort.field !== 'symbol') {
      const left = bySymbol.get(a); const right = bySymbol.get(b);
      const x = left ? sort.field === 'price' ? Number(left.price) : sort.field === 'volume' ? left.volume : left.change : NaN;
      const y = right ? sort.field === 'price' ? Number(right.price) : sort.field === 'volume' ? right.volume : right.change : NaN;
      // Keep missing quotes after available quotes in either direction.
      if (!Number.isFinite(x) || !Number.isFinite(y)) return Number.isFinite(x) ? -1 : Number.isFinite(y) ? 1 : comparison;
      comparison = x < y ? -1 : x > y ? 1 : 0;
    }
    if (comparison === 0) return a < b ? -1 : a > b ? 1 : 0;
    return sort.direction === 'ascending' ? comparison : -comparison;
  });
}

export function reorderedWatchlist(symbols: string[], from: number, to: number): string[] {
  const result = symbols.slice();
  if (!Number.isInteger(from) || !Number.isInteger(to) || from < 0 || from >= result.length || to < 0 || to >= result.length) return result;
  const item = result.splice(from, 1)[0]; result.splice(to, 0, item); return result;
}

function digits(value: Decimal): number {
  const magnitude = value.abs();
  if (magnitude.compare(new Decimal('100')) >= 0) return 2;
  if (magnitude.compare(new Decimal('1')) >= 0) return 3;
  if (!magnitude.positive()) return 4;
  let scaled = magnitude; let places = 3;
  while (scaled.compare(new Decimal('1')) < 0 && places < 32) { scaled = scaled.multiply(new Decimal('10')); places++; }
  return places;
}

/** Mirrors iOS DisplayNumber for presentation; never used for order payloads. */
export function marketNumber(value: string, signed: boolean = false): string {
  try {
    const source = value.trim();
    if (!/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?$/i.test(source)) return '--';
    const parts = source.toLowerCase().split('e');
    let expanded = parts[0];
    if (parts.length === 2) {
      const exponent = Number(parts[1]);
      if (!Number.isInteger(exponent) || Math.abs(exponent) > 100) return '--';
      const sign = expanded.startsWith('-') ? '-' : '';
      const mantissa = expanded.replace(/^[+-]/, '').split('.');
      const raw = mantissa.join(''); const point = mantissa[0].length + exponent;
      expanded = sign + (point <= 0 ? '0.' + '0'.repeat(-point) + raw : point >= raw.length ? raw + '0'.repeat(point - raw.length) : raw.slice(0, point) + '.' + raw.slice(point));
    } else if (parts.length > 2) return '--';
    if (expanded.startsWith('.')) expanded = '0' + expanded;
    if (expanded.startsWith('-.') || expanded.startsWith('+.')) expanded = expanded[0] + '0' + expanded.slice(1);
    if (expanded.endsWith('.')) expanded = expanded.slice(0, -1);
    let number = new Decimal(expanded); number = new Decimal(number.fixed(digits(number)));
    const result = number.fixed(digits(number));
    const text = number.abs().compare(new Decimal('1')) < 0 ? result.replace(/\.?0+$/, '') : result;
    return (signed && number.positive() ? '+' : '') + text;
  } catch (_) { return '--'; }
}

export function marketTurnover(value: number): string {
  if (!Number.isFinite(value)) return '--';
  return Math.abs(value) >= 1e8 ? marketNumber(String(value / 1e8)) + '亿' : Math.abs(value) >= 1e4 ? marketNumber(String(value / 1e4)) + '万' : marketNumber(String(value));
}
