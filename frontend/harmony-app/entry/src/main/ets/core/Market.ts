import { DataValue } from './Json';

export const INTERVALS: string[] = ['1m', '3m', '5m', '15m', '30m', '1h', '2h', '4h', '8h', '16h', '1d', '3d', '1w'];
export const INTERVAL_LABELS: string[] = ['1分', '3分', '5分', '15分', '30分', '1小时', '2小时', '4小时', '8小时', '16小时', '1天', '3天', '1周'];
export function intervalMillis(interval: string): number {
  const widths: Record<string, number> = { 'm': 60000, 'h': 3600000, 'd': 86400000, 'w': 604800000 };
  return INTERVALS.includes(interval) ? Number(interval.slice(0, -1)) * widths[interval.slice(-1)] : 60000;
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
  quoteVolume: number = 0;
  closed: boolean = false;
  live: boolean = false;
  statistics: DataValue = new DataValue();
  static from(value: DataValue, live: boolean = false): Candle {
    const candle = new Candle(); candle.time = value.get('openTime').number(); candle.eventTime = value.get('eventTime').number();
    candle.open = value.get('openPrice').number(NaN); candle.high = value.get('highPrice').number(NaN);
    candle.low = value.get('lowPrice').number(NaN); candle.close = value.get('closePrice').number(NaN); candle.volume = value.get('volume').number();
    candle.quoteVolume = value.get('quoteVolume').number(); candle.closed = value.get('closed').flag(); candle.live = live; candle.statistics = value.get('tradingData'); return candle;
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

export { IndicatorLine, ema, sma, rsi, atr, mainIndicators, panelIndicators } from './Indicators';
