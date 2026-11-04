import { Candle, IndicatorLine, mainIndicators, panelIndicators, intervalMillis, priceText } from '../core/Market';
import { IndicatorParameters } from '../core/ChartSettings';
import { ChartViewport, PriceDomain, drawingPrice, ChartTouchState } from '../core/ChartViewport';
import { DataValue } from '../core/Json';
import { Runtime } from '../platform/Runtime';

@Component
export struct KlineCanvas {
  @Prop @Watch('resetChart') identity: string = '';
  @Prop @Watch('draw') revision: number = 0;
  @Prop @Watch('draw') main: string = 'EMA,SUPER';
  @Prop @Watch('draw') panels: string = 'MACD,VOL';
  @Prop @Watch('draw') parameters: string = '{}';
  @Prop @Watch('draw') autoFit: boolean = true;
  @Prop @Watch('resetCursor') orderType: string = 'market';
  @Prop @Watch('draw') stopPrice: string = '';
  @Prop @Watch('draw') entryPrice: string = '';
  @Prop @Watch('draw') positions: string = '[]';
  @Prop interactive: boolean = true;
  selectedPrice: (value: string) => void = () => {};
  moveLine: (kind: string, value: string) => void = () => {};
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  @State canvasHeight: number = 560;
  private canvasWidth: number = 0;
  private plotWidth: number = 0;
  private plotHeight: number = 320;
  private viewport: ChartViewport = new ChartViewport();
  private touchState: ChartTouchState = new ChartTouchState();
  private cursorY: number = 0;
  private startOffset: number = 0;
  private startCount: number = 60;
  private pinchAnchor: number = 0.5;
  private startDomain: PriceDomain = new PriceDomain();
  private touchX: number = 0;
  private touchY: number = 0;
  private ready: boolean = false;
  private cacheKey: string = '';
  private initializedViewport: boolean = false;
  private overlays: IndicatorLine[] = [];
  private panelLines: IndicatorLine[][] = [];
  private dark: boolean = true;
  private positive: string = '#2EBD85';
  private negative: string = '#F6465D';
  private text: string = '#848E9C';
  private grid: string = '#333B47';
  private canvasBackground: string = '#212731';
  private line(x1: number, y1: number, x2: number, y2: number, color: string, width: number = 0.5): void {
    this.ctx.strokeStyle = color; this.ctx.lineWidth = width; this.ctx.beginPath(); this.ctx.moveTo(x1, y1); this.ctx.lineTo(x2, y2); this.ctx.stroke();
  }
  private label(text: string, x: number, y: number, color: string = '', align: CanvasTextAlign = 'left', size: number = 10): void {
    this.ctx.font = String(size) + 'vp sans-serif'; this.ctx.fillStyle = color || this.text; this.ctx.textAlign = align; this.ctx.fillText(text, x, y);
  }
  private x(index: number): number { return 4 + (index - this.viewport.start + 0.5) * this.plotWidth / this.viewport.count; }
  private y(value: number): number { return this.viewport.domain.y(value, 30, this.plotHeight); }
  private panelNames(): string[] { return this.panels.split(',').filter((v: string) => v !== ''); }
  private resetCursor(): void { this.touchState.dismiss(); this.selectedPrice(''); this.draw(); }
  private resetChart(): void { this.viewport.reset(this.plotWidth); this.initializedViewport = false; this.cacheKey = ''; this.resetCursor(); }
  private palette(): void {
    const manager = getContext(this).resourceManager;
    const value = manager.getColorByNameSync('background') >>> 0;
    this.canvasBackground = '#' + value.toString(16).padStart(8, '0').slice(2); this.dark = this.canvasBackground.toUpperCase() !== '#FFFFFF';
    this.positive = this.dark ? '#28A473' : '#2EBD85'; this.negative = this.dark ? '#F63C55' : '#F6465D';
    this.text = this.dark ? '#848E9C' : '#707A8A'; this.grid = this.dark ? '#333B47' : '#EAECEF';
  }
  private series(line: IndicatorLine, top: number, height: number, low: number, high: number, marker: boolean = false): void {
    const range = high - low || Math.max(Math.abs(high) * 0.01, 1);
    this.ctx.strokeStyle = !this.dark && line.color === '#F0B90B' ? '#9C7400' : line.color; this.ctx.lineWidth = 0.8; this.ctx.beginPath(); let connected = false;
    for (let i = this.viewport.start; i < this.viewport.end; i++) {
      const value = line.values[i]; if (!Number.isFinite(value)) { connected = false; continue; }
      const x = this.x(i); const y = top + (high - value) / range * height;
      if (marker) { this.ctx.strokeRect(x - 1.35, y - 1.35, 2.7, 2.7); continue; }
      if (line.directions.length) {
        const direction = line.directions[i]; this.ctx.strokeStyle = direction > 0 ? this.positive : this.negative;
        if (i > this.viewport.start && direction === line.directions[i - 1] && Number.isFinite(line.values[i - 1])) this.line(this.x(i - 1), top + (high - line.values[i - 1]) / range * height, x, y, direction > 0 ? this.positive : this.negative, 0.8);
      } else { if (connected) this.ctx.lineTo(x, y); else this.ctx.moveTo(x, y); connected = true; }
    }
    if (!line.directions.length) this.ctx.stroke();
  }
  private legend(lines: IndicatorLine[], y: number, index: number): void {
    this.ctx.font = '10vp sans-serif'; let x = 6; for (const l of lines) {
      const value = l.values[index]; const title = l.name + ' ' + (Number.isFinite(value) ? (value < 0 ? '-' : '') + priceText(String(Math.abs(value))) : '--');
      const width = this.ctx.measureText(title).width + 12; if (x + width > this.canvasWidth - 4) break;
      this.label(title, x, y, !this.dark && l.color === '#F0B90B' ? '#9C7400' : l.color); x += width;
    }
  }
  private priceLine(price: number, title: string, color: string, held: boolean = false): void {
    const y = this.y(price); if (!Number.isFinite(y) || y < 30 || y > 30 + this.plotHeight) return;
    this.ctx.setLineDash(held ? [4, 3] : [6, 3]); this.line(4, y, this.plotWidth + 4, y, color, 0.8); this.ctx.setLineDash([]);
    this.ctx.fillStyle = this.canvasBackground; const label = title + ' ' + priceText(String(price));
    this.ctx.font = '11vp sans-serif'; const labelWidth = this.ctx.measureText(label).width;
    this.ctx.fillRect(7, y - 17, labelWidth + (held ? 14 : 28), 18);
    this.label(label, 12, y - 4, color, 'left', 11);
    if (!held) {
      const handle = 12 + labelWidth + 8;
      this.line(handle - 3, y - 10, handle, y - 13, color, 1); this.line(handle, y - 13, handle + 3, y - 10, color, 1);
      this.line(handle - 3, y - 6, handle, y - 3, color, 1); this.line(handle, y - 3, handle + 3, y - 6, color, 1);
    }
    this.label(priceText(String(price)), this.plotWidth + 7, y + 3, color);
  }
  private draw(): void {
    if (!this.ready || this.canvasWidth < 100) return;
    this.palette(); const candles = Runtime.store.chart.candles; const names = this.panelNames();
    this.plotWidth = Math.max(120, this.canvasWidth - 4 - 58); this.plotHeight = this.plotWidth;
    if (!this.initializedViewport) { this.viewport.reset(this.plotWidth); this.initializedViewport = true; }
    this.canvasHeight = 30 + this.plotHeight + 24 + names.length * 74;
    this.ctx.clearRect(0, 0, this.canvasWidth, this.canvasHeight);
    if (!candles.length) { this.label(Runtime.store.chartLoading ? '加载 K 线…' : '暂无 K 线数据', this.canvasWidth / 2, 150, this.text, 'center', 13); return; }
    const parameters = IndicatorParameters.load(this.parameters); const cacheKey = String(Runtime.store.chartRevision) + this.identity + this.main + this.panels + this.parameters;
    if (cacheKey !== this.cacheKey) {
      this.overlays = []; for (const name of this.main.split(',')) this.overlays = this.overlays.concat(mainIndicators(candles, name, parameters, intervalMillis(Runtime.store.interval)));
      this.panelLines = names.map((name: string) => panelIndicators(candles, name, parameters, intervalMillis(Runtime.store.interval))); this.cacheKey = cacheKey;
    }
    this.viewport.auto = this.autoFit; this.viewport.update(candles, this.overlays.map((l: IndicatorLine) => l.values));
    const domain = this.viewport.domain; const step = this.plotWidth / this.viewport.count; const index = this.touchState.cursor >= this.viewport.start && this.touchState.cursor < this.viewport.end ? this.touchState.cursor : this.viewport.end - 1;
    for (let i = 0; i < 5; i++) {
      const y = 30 + i * this.plotHeight / 4; this.line(4, y, this.plotWidth + 4, y, this.grid);
      this.label(priceText(String(domain.high - i * (domain.high - domain.low) / 4)), this.plotWidth + 7, y + 3);
    }
    this.ctx.save(); this.ctx.beginPath(); this.ctx.rect(4, 30, this.plotWidth, this.plotHeight); this.ctx.clip();
    for (const l of this.overlays) if (l.directions.length) {
      const alpha = parameters.fillAlpha(this.dark);
      for (let i = this.viewport.start; i < this.viewport.end; i++) if (Number.isFinite(l.values[i])) {
        this.ctx.fillStyle = l.directions[i] > 0 ? 'rgba(46,189,133,' + alpha + ')' : 'rgba(246,70,93,' + alpha + ')';
        this.ctx.fillRect(this.x(i) - step / 2, Math.min(this.y(candles[i].close), this.y(l.values[i])), step, Math.abs(this.y(candles[i].close) - this.y(l.values[i])));
      }
    }
    for (let i = this.viewport.start; i < this.viewport.end; i++) {
      const c = candles[i]; const color = c.close >= c.open ? this.positive : this.negative; const x = this.x(i);
      this.line(x, this.y(c.high), x, this.y(c.low), color, 0.8); this.ctx.fillStyle = color;
      this.ctx.fillRect(x - (step - 1) / 2, this.y(Math.max(c.open, c.close)), Math.max(1, step - 1), Math.max(0.8, Math.abs(this.y(c.open) - this.y(c.close))));
    }
    for (const l of this.overlays) this.series(l, 30, this.plotHeight, domain.low, domain.high, l.name === 'SAR');
    this.ctx.restore(); this.legend(this.overlays.filter((l: IndicatorLine) => !l.directions.length), 12, index); this.legend(this.overlays.filter((l: IndicatorLine) => l.directions.length > 0), 26, index);
    const latest = candles[candles.length - 1]; this.priceLine(latest.close, '', latest.close >= latest.open ? this.positive : this.negative, true);
    const held = DataValue.parse(this.positions).rows();
    if (held.length) {
      for (const row of held) {
        this.priceLine(row.get('open_price').number(NaN), '持仓价', '#E8B622', true);
        this.priceLine((row.get('market_stop_set').flag() ? row.get('market_stop_price') : row.get('stop_loss_price')).number(NaN), '止损', this.negative, true);
        if (row.get('manual_take_profit_set').flag()) this.priceLine(row.get('manual_take_profit_price').number(NaN), '止盈', this.positive, true);
      }
    } else if (this.orderType === 'limit') {
      this.priceLine(Number(this.entryPrice), '限价建仓', '#E8B622'); this.priceLine(Number(this.stopPrice), '止损', this.negative);
    }
    for (const row of held) {
      const timestamp = Date.parse(row.value('opened_at', row.value('created_at'))); const interval = intervalMillis(Runtime.store.interval);
      const i = candles.findIndex((c: Candle) => c.time <= timestamp && timestamp < c.time + interval);
      if (i >= this.viewport.start && i < this.viewport.end) {
        const c = candles[i]; const long = row.value('side') === '0'; const y = this.y(long ? c.low : c.high) + (long ? 13 : -6);
        if (y >= 30 && y <= 30 + this.plotHeight) this.label(long ? 'B' : 'S', this.x(i), y, long ? this.positive : this.negative, 'center', 10);
      }
    }
    const timeTop = 30 + this.plotHeight;
    for (let i = 0; i < 3; i++) {
      const j = Math.min(this.viewport.end - 1, this.viewport.start + Math.floor((this.viewport.end - this.viewport.start - 1) * i / 2)); const d = new Date(candles[j].time);
      this.label(String(d.getMonth() + 1).padStart(2, '0') + '/' + String(d.getDate()).padStart(2, '0') + ' ' + String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0'), this.x(j), timeTop + 16, this.text, i === 0 ? 'left' : i === 2 ? 'right' : 'center');
    }
    for (let p = 0; p < names.length; p++) {
      const top = timeTop + 24 + p * 74; const lines = this.panelLines[p]; const values: number[] = [];
      for (const l of lines) for (const value of l.values.slice(this.viewport.start, this.viewport.end)) if (Number.isFinite(value)) values.push(value);
      let low = values.length ? Math.min(...values) : 0; let high = values.length ? Math.max(...values) : 1;
      if (['VOL', 'MACD', 'B.S Vol.'].includes(names[p])) { low = Math.min(0, low); high = Math.max(0, high); }
      if (['RSI', 'KDJ', 'StochRSI'].includes(names[p])) { low = 0; high = 100; } if (names[p] === 'WR') { low = -100; high = 0; }
      if (low === high) high = low + Math.max(1, Math.abs(low) * 0.01);
      this.line(0, top, this.canvasWidth, top, this.grid); this.legend(lines, top + 13, index);
      this.ctx.save(); this.ctx.beginPath(); this.ctx.rect(4, top + 18, this.plotWidth, 54); this.ctx.clip();
      const paired = names[p] === 'B.S Vol.'; const ratio = names[p].startsWith('L.S');
      for (let j = 0; j < lines.length; j++) {
        const histogram = (names[p] === 'VOL' && j === 0) || (names[p] === 'MACD' && j === 2) || (names[p] === 'O.I.' && j === 0) || (ratio && j < 2) || paired;
        const area = names[p] === 'Basis' && j === 0;
        if (!histogram && !area) { this.series(lines[j], top + 18, 54, low, high); continue; }
        for (let i = this.viewport.start; i < this.viewport.end; i++) {
          const value = lines[j].values[i]; if (!Number.isFinite(value)) continue;
          const zero = top + 18 + high / (high - low) * 54; const y = top + 18 + (high - value) / (high - low) * 54;
          const color = names[p] === 'VOL' ? candles[i].close >= candles[i].open ? this.positive : this.negative : names[p] === 'MACD' ? value >= 0 ? this.positive : this.negative : ratio ? j === 0 ? this.negative : this.positive : paired ? j === 0 ? this.positive : this.negative : lines[j].color;
          this.ctx.fillStyle = color; this.ctx.strokeStyle = color; this.ctx.lineWidth = 1 / vp2px(1);
          const hollow = names[p] === 'MACD' && i > 0 && (value >= 0 ? value < lines[j].values[i - 1] : value > lines[j].values[i - 1]);
          const barWidth = Math.max(1, step - 1) / (paired ? 2 : 1); const left = this.x(i) - (step - 1) / 2 + (paired && j === 1 ? barWidth : 0);
          if (area) { this.ctx.globalAlpha = 0.72; this.ctx.fillRect(this.x(i) - step / 2, Math.min(y, zero), step, Math.abs(zero - y)); this.ctx.globalAlpha = 1; }
          else if (hollow) this.ctx.strokeRect(left, Math.min(y, zero), barWidth, Math.max(0.8, Math.abs(zero - y)));
          else this.ctx.fillRect(left, Math.min(y, zero), barWidth, Math.max(0.8, Math.abs(zero - y)));
        }
      }
      this.ctx.restore(); this.label(high.toFixed(2), this.plotWidth + 7, top + 28); this.label(low.toFixed(2), this.plotWidth + 7, top + 70);
    }
    if (this.touchState.cursor >= this.viewport.start && this.touchState.cursor < this.viewport.end) {
      const x = this.x(this.touchState.cursor); this.ctx.setLineDash([3, 3]); this.line(x, 30, x, this.canvasHeight, this.text); this.line(4, this.cursorY, this.plotWidth + 4, this.cursorY, this.text); this.ctx.setLineDash([]);
      const selected = candles[this.touchState.cursor]; const left = x < this.plotWidth / 2 ? this.plotWidth - 154 : 6;
      this.ctx.fillStyle = this.dark ? '#272F3A' : '#F5F5F5'; this.ctx.fillRect(left, 34, 148, 108);
      const labels = ['开 ' + priceText(String(selected.open)), '高 ' + priceText(String(selected.high)), '低 ' + priceText(String(selected.low)), '收 ' + priceText(String(selected.close)), '量 ' + selected.volume.toFixed(2)];
      for (let i = 0; i < labels.length; i++) this.label(labels[i], left + 8, 51 + i * 19, this.dark ? '#EAECEF' : '#181A20');
      if (this.cursorY >= 30 && this.cursorY <= timeTop) this.label(priceText(String(domain.price(this.cursorY, 30, this.plotHeight))), this.plotWidth + 7, this.cursorY + 3, this.dark ? '#EAECEF' : '#181A20');
    }
  }
  private updateCursor(x: number, y: number): void {
    if (!Runtime.store.chart.candles.length) return;
    this.touchState.cursor = this.viewport.cursor(x - 4, this.plotWidth); this.cursorY = Math.max(30, Math.min(this.canvasHeight - 1, y));
    if (this.orderType === 'market') this.selectedPrice(y >= 30 && y <= 30 + this.plotHeight && x <= this.plotWidth + 4 ? this.priceString(this.viewport.domain.price(y, 30, this.plotHeight)) : '');
    this.draw();
  }
  private priceString(value: number): string { return Number.isFinite(value) && value > 0 ? value.toFixed(12).replace(/\.?0+$/, '') : ''; }
  build() {
    Canvas(this.ctx).width('100%').height(this.canvasHeight).id('chart.canvas')
      .onReady(() => { this.ready = true; this.draw(); })
      .onAreaChange((_old: Area, area: Area) => { this.canvasWidth = Number(area.width); this.draw(); })
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Up || event.type === TouchType.Cancel) { this.touchState.endTouch(); return; }
        if (event.touches.length > 1) { this.touchState.endTouch(); return; }
        if (!event.touches.length) return; const t = event.touches[0]; this.touchX = t.x; this.touchY = t.y;
        if (event.type === TouchType.Down) this.touchState.beginTouch();
        if (!this.touchState.allowsSingleTouch()) return;
        if (event.type === TouchType.Down && this.orderType === 'limit' && this.interactive && DataValue.parse(this.positions).rows().length === 0) {
          const entryDistance = Math.abs(t.y - this.y(Number(this.entryPrice))); const stopDistance = Math.abs(t.y - this.y(Number(this.stopPrice)));
          this.touchState.dragKind = Math.min(entryDistance, stopDistance) < 18 && t.x < this.plotWidth + 4 ? entryDistance <= stopDistance ? 'entry' : 'stop' : '';
        }
        if (event.type === TouchType.Move && this.touchState.dragKind) {
          const value = drawingPrice(this.viewport.domain.price(t.y, 30, this.plotHeight), this.viewport.domain, this.touchState.dragKind === 'stop', this.autoFit);
          if (Number.isFinite(value)) this.moveLine(this.touchState.dragKind, this.priceString(value));
        } else if (event.type === TouchType.Move && this.touchState.tracking) this.updateCursor(t.x, t.y);
      })
      .gesture(GestureGroup(GestureMode.Parallel,
        PinchGesture().onActionStart((e: GestureEvent) => { this.touchState.beginPinch(); this.startCount = this.viewport.count; this.startOffset = this.viewport.offset; this.startDomain = this.viewport.domain; this.pinchAnchor = e.fingerList.length ? Math.max(0, Math.min(1, (e.fingerList.reduce((sum: number, f: FingerInfo) => sum + f.localX, 0) / e.fingerList.length - 4) / this.plotWidth)) : 0.5; this.resetCursor(); }).onActionUpdate((e: GestureEvent) => {
          if (!this.touchState.pinching) return;
          this.viewport.zoom(this.startCount / e.scale); this.viewport.pan(this.startOffset + (this.startCount - this.viewport.count) * (1 - this.pinchAnchor)); if (!this.autoFit) this.viewport.domain = this.startDomain.scaled(e.scale); this.draw();
        }).onActionEnd(() => this.touchState.endPinch()).onActionCancel(() => this.touchState.endPinch()),
        GestureGroup(GestureMode.Exclusive,
        LongPressGesture({ repeat: false, duration: 350 }).onAction((e: GestureEvent) => {
          if (!e.fingerList.length || !this.touchState.beginCrosshair(this.viewport.cursor(e.fingerList[0].localX - 4, this.plotWidth))) return; this.updateCursor(e.fingerList[0].localX, e.fingerList[0].localY);
        }).onActionEnd(() => { this.touchState.tracking = false; }),
        PanGesture({ direction: this.autoFit ? PanDirection.Horizontal : PanDirection.All }).onActionStart(() => { if (!this.touchState.beginPan()) return; this.selectedPrice(''); this.startOffset = this.viewport.offset; this.startDomain = this.viewport.domain; })
          .onActionUpdate((e: GestureEvent) => {
            if (this.touchState.dragKind || this.touchState.tracking || !this.touchState.allowsSingleTouch()) return;
            if (this.touchState.cursor >= 0) { this.updateCursor(this.touchX, this.touchY); return; }
            this.viewport.pan(this.startOffset + e.offsetX / (this.plotWidth / this.viewport.count));
            if (!this.autoFit) this.viewport.domain = this.startDomain.shifted(e.offsetY / this.plotHeight * (this.startDomain.high - this.startDomain.low));
            this.draw(); if (this.viewport.start < 20) Runtime.store.loadHistory(true);
          }),
        TapGesture().onAction((e: GestureEvent) => {
          if (this.touchState.dragKind || !this.touchState.allowsSingleTouch()) return; if (this.touchState.cursor >= 0) this.resetCursor(); else if (e.fingerList.length) this.updateCursor(e.fingerList[0].localX, e.fingerList[0].localY);
        })
      )))
  }
}
