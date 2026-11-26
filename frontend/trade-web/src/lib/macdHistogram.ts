import {
  customSeriesDefaultOptions,
  type CustomData, type CustomSeriesOptions, type CustomSeriesWhitespaceData,
  type ICustomSeriesPaneRenderer, type ICustomSeriesPaneView, type PaneRendererCustomData, type Time,
} from "lightweight-charts";

export interface MacdBarPoint extends CustomData<Time> {
  value: number;
}
export interface MacdHistogramConfig {
  upColor: string;
  downColor: string;
  zeroColor: string;
}

interface StoredBar { x: number; index: number; value: number }

/** MACD 柱：正柱实心、负柱空心描边，并绘制零轴。 */
export function createMacdHistogramView(config: MacdHistogramConfig): ICustomSeriesPaneView<Time, MacdBarPoint, CustomSeriesOptions> {
  let bars: StoredBar[] = [];
  let barSpacing = 6;
  let range: { from: number; to: number } | null = null;
  const renderer: ICustomSeriesPaneRenderer = {
    draw(target, priceConverter) {
      target.useMediaCoordinateSpace(({ context, mediaSize }) => {
        const zero = priceConverter(0);
        if (zero === null) return;
        context.strokeStyle = config.zeroColor;
        context.lineWidth = 1;
        context.beginPath();
        context.moveTo(0, zero);
        context.lineTo(mediaSize.width, zero);
        context.stroke();
        const half = Math.max(1, barSpacing * 0.35);
        for (const bar of bars) {
          if (range && (bar.index < range.from - 1 || bar.index > range.to + 1)) continue;
          if (bar.x < -half || bar.x > mediaSize.width + half) continue;
          const y = priceConverter(bar.value);
          if (y === null) continue;
          const top = Math.min(zero, y);
          const height = Math.max(1, Math.abs(y - zero));
          if (bar.value >= 0) {
            context.fillStyle = config.upColor;
            context.fillRect(bar.x - half, top, half * 2, height);
          } else {
            context.strokeStyle = config.downColor;
            context.lineWidth = 1;
            context.strokeRect(bar.x - half + 0.5, top + 0.5, Math.max(1, half * 2 - 1), Math.max(1, height - 1));
          }
        }
      });
    },
  };
  return {
    renderer: () => renderer,
    update(data: PaneRendererCustomData<Time, MacdBarPoint>) {
      barSpacing = data.barSpacing;
      range = data.visibleRange ? { from: data.visibleRange.from, to: data.visibleRange.to } : null;
      bars = [];
      for (const bar of data.bars) {
        const point = bar.originalData;
        if (point.value === undefined) continue;
        bars.push({ x: bar.x, index: bar.time, value: point.value });
      }
    },
    priceValueBuilder: (row) => [row.value],
    isWhitespace: (data): data is CustomSeriesWhitespaceData<Time> => (data as MacdBarPoint).value === undefined,
    defaultOptions: () => ({ ...customSeriesDefaultOptions }),
  };
}