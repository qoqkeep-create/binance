import {
  customSeriesDefaultOptions,
  type CustomData, type CustomSeriesOptions, type CustomSeriesWhitespaceData,
  type ICustomSeriesPaneRenderer, type ICustomSeriesPaneView, type PaneRendererCustomData, type Time,
} from "lightweight-charts";

export interface BandPoint extends CustomData<Time> {
  close: number;
  st: number;
  direction: 1 | -1;
}
export interface BandFillConfig {
  fillUpColor: string;
  fillDownColor: string;
  fillOpacity: number;
  visibleRange?: () => { from: number; to: number } | null;
}

interface StoredBar { x: number; index: number; close: number; st: number; direction: 1 | -1 }

function withAlpha(hex: string, alpha: number) {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return `rgba(${r},${g},${b},${alpha})`;
}

/** Filled band between close and the Supertrend line, broken at direction reversals. */
export function createSupertrendBandView(config: BandFillConfig): ICustomSeriesPaneView<Time, BandPoint, CustomSeriesOptions> {
  let bars: StoredBar[] = [];
  let range: { from: number; to: number } | null = null;
  const renderer: ICustomSeriesPaneRenderer = {
    draw(target, priceConverter) {
      target.useMediaCoordinateSpace(({ context, mediaSize }) => {
        if (bars.length < 2 || config.fillOpacity <= 0) return;
        // 绘制时读图表实时可见范围：update 传入的 visibleRange 可能陈旧，
        // 左拖时屏外 bar 的 x 被夹到左缘会堆叠，必须按最新范围双侧裁剪
        // （兜底沿用 range.from - 1／range.to + 1 的序号边界语义）。
        const vr = (config.visibleRange ? config.visibleRange() : null) || range;
        for (let index = 0; index < bars.length - 1; index += 1) {
          const a = bars[index];
          const b = bars[index + 1];
          // 仅连接原始序号相邻且同向的 bar：反转留空或单根反向趋势造成的缺口都断开，
          // 避免两段同向趋势被填充带边缘连成一条线。
          if (a.direction !== b.direction || b.index !== a.index + 1) continue;
          if (vr && (b.index < vr.from - 1 || a.index > vr.to + 1)) continue;
          if (b.x < 0 || a.x > mediaSize.width) continue;
          const closeA = priceConverter(a.close);
          const stA = priceConverter(a.st);
          const closeB = priceConverter(b.close);
          const stB = priceConverter(b.st);
          if (closeA === null || stA === null || closeB === null || stB === null) continue;
          context.beginPath();
          context.moveTo(a.x, closeA);
          context.lineTo(b.x, closeB);
          context.lineTo(b.x, stB);
          context.lineTo(a.x, stA);
          context.closePath();
          context.fillStyle = withAlpha(a.direction === 1 ? config.fillUpColor : config.fillDownColor, config.fillOpacity);
          context.fill();
        }
      });
    },
  };
  return {
    renderer: () => renderer,
    update(data: PaneRendererCustomData<Time, BandPoint>) {
      range = data.visibleRange ? { from: data.visibleRange.from, to: data.visibleRange.to } : null;
      bars = [];
      for (const bar of data.bars) {
        const point = bar.originalData;
        if (point.st === undefined || point.close === undefined) continue;
        bars.push({ x: bar.x, index: bar.time, close: point.close, st: point.st, direction: point.direction });
      }
    },
    priceValueBuilder: (row) => [row.close, row.st],
    isWhitespace: (data): data is CustomSeriesWhitespaceData<Time> => (data as BandPoint).st === undefined,
    defaultOptions: () => ({ ...customSeriesDefaultOptions }),
  };
}