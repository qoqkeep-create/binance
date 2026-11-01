import { Candle, IndicatorLine, mainIndicators, panelIndicators, priceText } from '../core/Market';
import { Runtime } from '../platform/Runtime';
import { GREEN, RED } from './Ui';

@Component
export struct KlineCanvas {
  @Prop @Watch('resetChart') identity: string = '';
  @Prop @Watch('draw') revision: number = 0;
  @Prop @Watch('draw') main: string = 'EMA,SUPER';
  @Prop @Watch('draw') panels: string = 'MACD,VOL';
  @Prop @Watch('draw') drawMode: string = '';
  @Prop @Watch('draw') stopPrice: string = '';
  @Prop @Watch('draw') entryPrice: string = '';
  selectedPrice: (value: string) => void = () => {};
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private canvasWidth: number = 0;
  private canvasHeight: number = 560;
  private count: number = 80;
  private viewOffset: number = 0;
  private panOffset: number = 0;
  private pinchCount: number = 80;
  private cursor: number = -1;
  private low: number = 0;
  private high: number = 1;
  private start: number = 0;
  private end: number = 0;
  private plotHeight: number = 320;
  private lines: IndicatorLine[] = [];
  private ready: boolean = false;
  private line(x1: number, y1: number, x2: number, y2: number, color: string, width: number = 1): void {
    this.ctx.strokeStyle = color; this.ctx.lineWidth = width; this.ctx.beginPath(); this.ctx.moveTo(x1, y1); this.ctx.lineTo(x2, y2); this.ctx.stroke();
  }
  private label(text: string, x: number, y: number, color: string = '#848E9C', align: CanvasTextAlign = 'left'): void {
    this.ctx.font = '10px sans-serif'; this.ctx.fillStyle = color; this.ctx.textAlign = align; this.ctx.fillText(text, x, y);
  }
  private x(index: number): number { return (index - this.start + 0.5) * (this.canvasWidth - 64) / this.count; }
  private y(value: number): number { return 24 + (this.high - value) / (this.high - this.low) * (this.plotHeight - 42); }
  private series(line: IndicatorLine, top: number, height: number, low: number, high: number): void {
    if (!Number.isFinite(low) || !Number.isFinite(high)) return;
    const range = high - low || Math.max(Math.abs(high) * 0.01, 1);
    this.ctx.strokeStyle = line.color; this.ctx.lineWidth = 1; this.ctx.beginPath(); let connected = false;
    for (let i = this.start; i < this.end; i++) {
      const value = line.values[i]; if (!Number.isFinite(value)) { connected = false; continue; }
      const x = this.x(i); const y = top + (high - value) / range * height;
      if (connected) this.ctx.lineTo(x, y); else this.ctx.moveTo(x, y); connected = true;
    }
    this.ctx.stroke();
  }
  private resetChart(): void { this.viewOffset = 0; this.count = 80; this.cursor = -1; this.draw(); }
  private draw(): void {
    if (!this.ready || this.canvasWidth < 80) return;
    const candles = Runtime.store.chart.candles; const panels = this.panels.split(',').filter((v: string) => v !== '');
    this.plotHeight = Math.max(240, this.canvasHeight - panels.length * 105 - 20);
    this.ctx.clearRect(0, 0, this.canvasWidth, this.canvasHeight);
    if (!candles.length) { this.label(Runtime.store.chartLoading ? '加载 K 线…' : '暂无 K 线数据', this.canvasWidth / 2, 150, '#848E9C', 'center'); return; }
    this.viewOffset = Math.max(0, Math.min(this.viewOffset, Math.max(0, candles.length - this.count)));
    this.end = Math.max(1, candles.length - Math.floor(this.viewOffset)); this.start = Math.max(0, this.end - this.count);
    const visible = candles.slice(this.start, this.end);
    this.lines = []; for (const name of this.main.split(',')) this.lines = this.lines.concat(mainIndicators(candles, name));
    let low = Math.min(...visible.map((c: Candle) => c.low)); let high = Math.max(...visible.map((c: Candle) => c.high));
    for (const line of this.lines) {
      const values = line.values.slice(this.start, this.end).filter((v: number) => Number.isFinite(v));
      if (values.length) { low = Math.min(low, ...values); high = Math.max(high, ...values); }
    }
    const pad = (high - low) * 0.06 || high * 0.01; this.low = low - pad; this.high = high + pad;
    for (let i = 0; i < 5; i++) {
      const y = 24 + i * (this.plotHeight - 42) / 4;
      this.line(0, y, this.canvasWidth - 64, y, '#848E9C22');
      this.label(priceText(String(this.high - i * (this.high - this.low) / 4)), this.canvasWidth - 60, y + 3);
    }
    const step = (this.canvasWidth - 64) / this.count;
    for (let i = this.start; i < this.end; i++) {
      const candle = candles[i]; const x = this.x(i); const color = candle.close >= candle.open ? GREEN : RED;
      this.line(x, this.y(candle.high), x, this.y(candle.low), color);
      this.ctx.fillStyle = color;
      this.ctx.fillRect(x - step * 0.31, this.y(Math.max(candle.open, candle.close)), Math.max(1, step * 0.62), Math.max(1, Math.abs(this.y(candle.open) - this.y(candle.close))));
    }
    for (const line of this.lines) this.series(line, 24, this.plotHeight - 42, this.low, this.high);
    let legendX = 6;
    for (const line of this.lines.slice(0, 4)) { this.label(line.name + ' ' + priceText(String(line.values[this.end - 1])), legendX, 12, line.color); legendX += 102; }
    const latest = candles[candles.length - 1]; const latestColor = latest.close >= latest.open ? GREEN : RED;
    this.ctx.setLineDash([3, 3]); this.line(0, this.y(latest.close), this.canvasWidth - 64, this.y(latest.close), latestColor); this.ctx.setLineDash([]);
    this.label(priceText(String(latest.close)), this.canvasWidth - 60, this.y(latest.close) - 4, latestColor);
    for (const price of [this.stopPrice, this.entryPrice]) {
      const n = Number(price); if (!price || !Number.isFinite(n) || n < this.low || n > this.high) continue;
      const color = price === this.stopPrice ? RED : '#F0B90B';
      this.ctx.setLineDash([5, 3]); this.line(0, this.y(n), this.canvasWidth - 64, this.y(n), color); this.ctx.setLineDash([]);
      this.label((price === this.stopPrice ? '止损 ' : '开仓 ') + price, 8, this.y(n) - 5, color);
    }
    for (let p = 0; p < panels.length; p++) {
      const top = this.plotHeight + p * 105; const lines = panelIndicators(candles, panels[p]);
      const values: number[] = [];
      for (const line of lines) for (const value of line.values.slice(this.start, this.end)) if (Number.isFinite(value)) values.push(value);
      const min = values.length ? Math.min(...values, panels[p] === 'VOL' || panels[p] === 'MACD' ? 0 : Infinity) : 0;
      const max = values.length ? Math.max(...values) : 1;
      this.line(0, top, this.canvasWidth, top, '#848E9C33'); let labelX = 6;
      for (const line of lines) { this.label(line.name + ' ' + (Number.isFinite(line.values[this.end - 1]) ? line.values[this.end - 1].toFixed(2) : '--'), labelX, top + 13, line.color); labelX += 105; }
      if (panels[p] === 'VOL') {
        for (let i = this.start; i < this.end; i++) {
          const c = candles[i]; const barHeight = c.volume / (max || 1) * 70;
          this.ctx.fillStyle = c.close >= c.open ? GREEN : RED; this.ctx.fillRect(this.x(i) - step * 0.31, top + 92 - barHeight, Math.max(1, step * 0.62), barHeight);
        }
        if (lines.length > 1) this.series(lines[1], top + 22, 70, 0, max);
      } else for (const line of lines) this.series(line, top + 22, 70, min, max);
      this.label(max.toFixed(2), this.canvasWidth - 60, top + 30); this.label(min.toFixed(2), this.canvasWidth - 60, top + 90);
    }
    for (let i = 0; i < 3; i++) {
      const index = Math.min(this.end - 1, this.start + Math.floor((this.end - this.start - 1) * i / 2));
      const date = new Date(candles[index].time);
      this.label(date.toLocaleString('zh-CN', { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false, timeZone: 'Asia/Shanghai' }), this.x(index), this.canvasHeight - 4, '#848E9C', i === 0 ? 'left' : i === 2 ? 'right' : 'center');
    }
    if (this.cursor >= this.start && this.cursor < this.end) {
      const selected = candles[this.cursor]; const x = this.x(this.cursor);
      this.ctx.setLineDash([3, 3]); this.line(x, 20, x, this.canvasHeight - 20, '#848E9C'); this.line(0, this.y(selected.close), this.canvasWidth - 64, this.y(selected.close), '#848E9C'); this.ctx.setLineDash([]);
      this.ctx.fillStyle = '#212731'; this.ctx.fillRect(6, 24, 148, 96);
      this.label('开 ' + priceText(String(selected.open)), 14, 42, '#EAECEF'); this.label('高 ' + priceText(String(selected.high)), 14, 62, '#EAECEF');
      this.label('低 ' + priceText(String(selected.low)), 14, 82, '#EAECEF'); this.label('收 ' + priceText(String(selected.close)), 14, 102, '#EAECEF');
    }
  }
  build() {
    Canvas(this.ctx).width('100%').height(560)
      .onReady(() => { this.ready = true; this.draw(); })
      .onAreaChange((oldArea: Area, area: Area) => { this.canvasWidth = Number(area.width); this.canvasHeight = Number(area.height); this.draw(); })
      .onTouch((event: TouchEvent) => {
        if (!event.touches.length) return;
        const touch = event.touches[0];
        if (this.drawMode && event.type === TouchType.Down && touch.y < this.plotHeight) {
          const price = this.high - (touch.y - 24) / (this.plotHeight - 42) * (this.high - this.low);
          if (price > 0) this.selectedPrice(priceText(String(price))); return;
        }
        if (this.cursor >= 0 && event.type === TouchType.Move) { this.cursor = Math.max(this.start, Math.min(this.end - 1, this.start + Math.floor(touch.x / (this.canvasWidth - 64) * this.count))); this.draw(); }
        if (event.type === TouchType.Up || event.type === TouchType.Cancel) { this.cursor = -1; this.draw(); }
      })
      .gesture(GestureGroup(GestureMode.Exclusive,
        PinchGesture().onActionStart(() => { this.pinchCount = this.count; }).onActionUpdate((event: GestureEvent) => { this.count = Math.max(20, Math.min(200, Math.round(this.pinchCount / event.scale))); this.draw(); }),
        PanGesture({ direction: PanDirection.Horizontal }).onActionStart(() => { this.panOffset = this.viewOffset; }).onActionUpdate((event: GestureEvent) => {
          this.viewOffset = Math.max(0, this.panOffset + event.offsetX / ((this.canvasWidth - 64) / this.count)); this.draw();
          if (this.start < 20) Runtime.store.loadHistory(true);
        }),
        LongPressGesture({ repeat: false }).onAction((event: GestureEvent) => {
          if (!event.fingerList.length) return;
          this.cursor = Math.max(this.start, Math.min(this.end - 1, this.start + Math.floor(event.fingerList[0].localX / (this.canvasWidth - 64) * this.count))); this.draw();
        })
      ))
  }
}
