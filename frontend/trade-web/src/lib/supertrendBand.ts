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
}

interface StoredBar { x: number; close: number; st: number; direction: 1 | -1 }

function withAlpha(hex: string, alpha: number) {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return `rgba(${r},${g},${b},${alpha})`;
}

/** Filled band between close and the Supertrend line, broken at direction reversals. */
export function createSupertrendBandView(config: BandFillConfig): ICustomSeriesPaneView<Time, BandPoint, CustomSeriesOptions> {
  let bars: StoredBar[] = [];
  const renderer: ICustomSeriesPaneRenderer = {
    draw(target, priceConverter) {
      target.useMediaCoordinateSpace(({ context }) => {
        if (bars.length < 2 || config.fillOpacity <= 0) return;
        for (let index = 0; index < bars.length - 1; index += 1) {
          const a = bars[index];
          const b = bars[index + 1];
          if (a.direction !== b.direction) continue;
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
      bars = [];
      for (const bar of data.bars) {
        const point = bar.originalData;
        if (point.st === undefined || point.close === undefined) continue;
        bars.push({ x: bar.x, close: point.close, st: point.st, direction: point.direction });
      }
    },
    priceValueBuilder: (row) => [row.close, row.st],
    isWhitespace: (data): data is CustomSeriesWhitespaceData<Time> => (data as BandPoint).st === undefined,
    defaultOptions: () => ({ ...customSeriesDefaultOptions }),
  };
}