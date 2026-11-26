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

/** MACD 柱：能量柱增长实心、缩短空心（颜色按正负），并绘制零轴。 */
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
        for (let i = 0; i < bars.length; i += 1) {
          const bar = bars[i];
          // 左侧按可见范围裁剪防边缘堆积；右侧按像素 x 裁剪，避免误删最新 bar。
          if (range && bar.index < range.from - 1) continue;
          if (bar.x < -half || bar.x > mediaSize.width + half) continue;
          const y = priceConverter(bar.value);
          if (y === null) continue;
          const top = Math.min(zero, y);
          const height = Math.max(2, Math.abs(y - zero));
          // 能量柱增长（绝对值变大）实心、缩短空心；颜色仍按正负。
          const prev = i > 0 ? bars[i - 1].value : undefined;
          const growing = prev === undefined || Math.abs(bar.value) >= Math.abs(prev);
          const color = bar.value >= 0 ? config.upColor : config.downColor;
          if (growing) {
            context.fillStyle = color;
            context.fillRect(bar.x - half, top, half * 2, height);
          } else {
            context.strokeStyle = color;
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