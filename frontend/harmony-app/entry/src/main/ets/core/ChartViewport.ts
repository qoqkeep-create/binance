import type { Candle } from './Market';
export class PriceDomain {
  low: number; high: number;
  constructor(low: number = 0, high: number = 1) { this.low = low; this.high = high; }
  price(y: number, top: number, height: number): number { return this.high - (y - top) / height * (this.high - this.low); }
  y(price: number, top: number, height: number): number { return top + (this.high - price) / (this.high - this.low) * height; }
  shifted(delta: number): PriceDomain { return new PriceDomain(this.low + delta, this.high + delta); }
  scaled(scale: number): PriceDomain { const middle = (this.low + this.high) / 2; const half = (this.high - this.low) / Math.max(0.1, scale) / 2; return new PriceDomain(middle - half, middle + half); }
}
export class ChartViewport {
  count: number = 60; offset: number = 0; start: number = 0; end: number = 0; domain: PriceDomain = new PriceDomain();
  auto: boolean = true; private fitted: boolean = false; private anchor: number = 0;
  reset(width: number = 0): void { this.count = width > 0 ? Math.max(10, Math.min(164, Math.round(width / 7.6))) : 60; this.offset = 0; this.anchor = 0; this.fitted = false; }
  update(candles: Candle[], overlays: number[][] = []): void {
    if (!candles.length) return;
    if (this.offset > 0 && this.anchor) { const index = candles.findIndex((c: Candle) => c.time === this.anchor); if (index >= 0) this.offset = candles.length - index - 1; }
    this.offset = Math.max(0, Math.min(this.offset, Math.max(0, candles.length - this.count)));
    this.end = Math.max(1, candles.length - Math.floor(this.offset)); this.start = Math.max(0, this.end - this.count); this.anchor = this.offset ? candles[this.end - 1].time : 0;
    if (this.auto || !this.fitted) {
      const visible = candles.slice(this.start, this.end); let low = Math.min(...visible.map((c: Candle) => c.low)); let high = Math.max(...visible.map((c: Candle) => c.high));
      for (const values of overlays) for (const v of values.slice(this.start, this.end)) if (Number.isFinite(v)) { low = Math.min(low, v); high = Math.max(high, v); }
      const pad = Math.max((high - low) * 0.06, Math.abs(high) * 0.0001); this.domain = new PriceDomain(low - pad, high + pad); this.fitted = true;
    }
  }
  pan(offset: number): void { this.offset = Math.max(0, offset); this.anchor = 0; }
  zoom(count: number): void { this.count = Math.max(10, Math.min(164, Math.round(count))); this.anchor = 0; }
  cursor(x: number, width: number): number { return Math.max(this.start, Math.min(this.end - 1, this.start + Math.floor(x / width * this.count))); }
}
export function drawingPrice(value: number, domain: PriceDomain, stop: boolean, auto: boolean): number {
  if (!Number.isFinite(value) || value <= 0) return NaN;
  return stop && !auto ? value : Math.min(domain.high, Math.max(Math.max(Number.MIN_VALUE, domain.low), value));
}

/** One physical touch owns tracking; a later drag always starts a viewport pan. */
export class ChartTouchState {
  cursor: number = -1;
  tracking: boolean = false;
  dragKind: string = '';
  pinching: boolean = false;
  private suppressSingleTouch: boolean = false;
  beginTouch(): void { if (!this.pinching) this.suppressSingleTouch = false; }
  allowsSingleTouch(): boolean { return !this.pinching && !this.suppressSingleTouch; }
  beginPinch(): void { this.dismiss(); this.dragKind = ''; this.pinching = true; this.suppressSingleTouch = true; }
  endPinch(): void { this.pinching = false; }
  beginCrosshair(index: number): boolean { if (this.dragKind || !this.allowsSingleTouch()) return false; this.cursor = index; this.tracking = true; return true; }
  endTouch(): void { this.tracking = false; this.dragKind = ''; }
  beginPan(): boolean { if (this.tracking || this.dragKind || !this.allowsSingleTouch()) return false; this.dismiss(); return true; }
  dismiss(): void { this.cursor = -1; this.tracking = false; }
}
