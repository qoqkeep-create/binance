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
  visibleRange?: () => { from: number; to: number } | null;
}

interface StoredBar { x: number; index: number; value: number; direction: 1 | -1 }

// LineSeries 的 whitespace 不会真正断开（相邻有效点仍被连线），故用自定义系列
// 只描「原始序号相邻且同向」的线段，多→空→多时中间空头区域必然断开。
export function createSupertrendLineView(config: SupertrendLineConfig) {
  let bars: StoredBar[] = [];
  let barSpacing = 6;
  let range: { from: number; to: number } | null = null;
  const visiblePriceRange = () => {
    const vr = (config.visibleRange ? config.visibleRange() : null) || range;
    let min = Infinity;
    let max = -Infinity;
    for (const bar of bars) {
      if (vr && (bar.index < vr.from || bar.index > vr.to)) continue;
      min = Math.min(min, bar.value);
      max = Math.max(max, bar.value);
    }
    return Number.isFinite(min) && Number.isFinite(max) ? { min, max } : null;
  };
  const renderer: ICustomSeriesPaneRenderer = {
    draw(target, priceConverter) {
      target.useMediaCoordinateSpace(({ context, mediaSize }) => {
        context.lineWidth = config.lineWidth;
        context.lineJoin = "round";
        context.lineCap = "round";
        const half = Math.max(1, barSpacing / 2);
        // 绘制时直读实时逻辑可见范围：update 的 visibleRange 是 bars 数组下标，
        // 与逻辑序号（含头部空白根偏移）不一致，会误删尾部最新根。
        const vr = (config.visibleRange ? config.visibleRange() : null) || range;
        for (let index = 0; index < bars.length; index += 1) {
          const a = bars[index];
          if (vr && (a.index < vr.from - 1 || a.index > vr.to + 1)) continue;
          if (a.x < -half || a.x > mediaSize.width + half) continue;
          const ya = priceConverter(a.value);
          if (ya === null) continue;
          context.strokeStyle = a.direction === 1 ? config.upColor : config.downColor;
          const b = bars[index + 1];
          const connected = !!b && b.direction === a.direction && b.index === a.index + 1;
          if (connected) {
            // 官方 plot.style_linebr：相邻同向点用直线连接（平滑折线，非水平台阶）。
            const yb = priceConverter(b.value);
            if (yb !== null) {
              context.beginPath();
              context.moveTo(a.x, ya);
              context.lineTo(b.x, yb);
              context.stroke();
            }
          } else {
            // 段末（含最新根／孤立反转根）向右延伸半根，保证末尾始终有撑压线。
            context.beginPath();
            context.moveTo(a.x, ya);
            context.lineTo(a.x + half, ya);
            context.stroke();
          }
        }
      });
    },
  };
  const view: ICustomSeriesPaneView<Time, SupertrendLinePoint, CustomSeriesOptions> = {
    renderer: () => renderer,
    update(data: PaneRendererCustomData<Time, SupertrendLinePoint>) {
      barSpacing = data.barSpacing;
      // visibleRange 为 bars 下标区间，换算成逻辑序号供兜底裁剪／autoscale 使用。
      if (data.visibleRange && data.bars.length) {
        const fromItem = data.bars[Math.max(0, Math.min(data.bars.length - 1, data.visibleRange.from))];
        const toItem = data.bars[Math.max(0, Math.min(data.bars.length - 1, data.visibleRange.to - 1))];
        range = { from: fromItem.time as number, to: toItem.time as number };
      } else {
        range = null;
      }
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
  return { view, visiblePriceRange };
}