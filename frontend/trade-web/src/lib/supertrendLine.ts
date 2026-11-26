import {
  customSeriesDefaultOptions,
  type CustomData, type CustomSeriesOptions, type CustomSeriesWhitespaceData,
  type ICustomSeriesPaneRenderer, type ICustomSeriesPaneView, type PaneRendererCustomData, type Time,
} from "lightweight-charts";

export interface SupertrendLinePoint extends CustomData<Time> {
  value: number;
  direction: 1 | -1;
}
export interface SupertrendLineConfig {
  upColor: string;
  downColor: string;
  lineWidth: number;
}

interface StoredBar { x: number; index: number; value: number; direction: 1 | -1 }

// LineSeries 的 whitespace 不会真正断开（相邻有效点仍被连线），故用自定义系列
// 只描「原始序号相邻且同向」的线段，多→空→多时中间空头区域必然断开。
export function createSupertrendLineView(config: SupertrendLineConfig): ICustomSeriesPaneView<Time, SupertrendLinePoint, CustomSeriesOptions> {
  let bars: StoredBar[] = [];
  let range: { from: number; to: number } | null = null;
  const renderer: ICustomSeriesPaneRenderer = {
    draw(target, priceConverter) {
      target.useMediaCoordinateSpace(({ context, mediaSize }) => {
        context.lineWidth = config.lineWidth;
        context.lineJoin = "round";
        context.lineCap = "round";
        for (let index = 0; index < bars.length - 1; index += 1) {
          const a = bars[index];
          const b = bars[index + 1];
          if (a.direction !== b.direction || b.index !== a.index + 1) continue;
          if (range && (b.index < range.from - 1 || a.index > range.to + 1)) continue;
          if (b.x < 0 || a.x > mediaSize.width) continue;
          const ya = priceConverter(a.value);
          const yb = priceConverter(b.value);
          if (ya === null || yb === null) continue;
          context.strokeStyle = a.direction === 1 ? config.upColor : config.downColor;
          context.beginPath();
          context.moveTo(a.x, ya);
          context.lineTo(b.x, yb);
          context.stroke();
        }
      });
    },
  };
  return {
    renderer: () => renderer,
    update(data: PaneRendererCustomData<Time, SupertrendLinePoint>) {
      range = data.visibleRange ? { from: data.visibleRange.from, to: data.visibleRange.to } : null;
      bars = [];
      for (const bar of data.bars) {
        const point = bar.originalData;
        if (point.value === undefined) continue;
        bars.push({ x: bar.x, index: bar.time, value: point.value, direction: point.direction });
      }
    },
    priceValueBuilder: (row) => [row.value],
    isWhitespace: (data): data is CustomSeriesWhitespaceData<Time> => (data as SupertrendLinePoint).value === undefined,
    defaultOptions: () => ({ ...customSeriesDefaultOptions }),
  };
}