import { useEffect, useId, useMemo, useRef, useState } from "react";
import type { Pivot, PivotSeries } from "./lib/analysisTypes";
import "./analysis-chart.css";

export interface AnalysisChartProps {
  series: PivotSeries;
  coverage?: { startTime: number; endTime: number; label: string };
  price: number | null;
  quoteStale: boolean;
  label: string;
}

const HEIGHT = 284;
const TOP = 41;
const BOTTOM = 228;
const BEIJING_OFFSET = 8 * 3600;

function priceText(value: number) {
  const absolute = Math.abs(value);
  const digits = absolute >= 100 ? 2 : absolute >= 1 ? 4 : absolute >= 0.001 ? 5 : 8;
  return value.toLocaleString("en-US", { minimumFractionDigits: Math.min(2, digits), maximumFractionDigits: digits });
}

function clockText(seconds: number) {
  return new Intl.DateTimeFormat("zh-CN", { timeZone: "Asia/Shanghai", hour: "2-digit", minute: "2-digit", hour12: false }).format(seconds * 1000);
}

function fullTimeText(seconds: number) {
  return new Intl.DateTimeFormat("zh-CN", { timeZone: "Asia/Shanghai", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false }).format(seconds * 1000);
}

function niceStep(range: number, count: number) {
  const raw = range / count;
  const power = 10 ** Math.floor(Math.log10(raw || 1));
  const ratio = raw / power;
  return (ratio <= 1 ? 1 : ratio <= 2 ? 2 : ratio <= 2.5 ? 2.5 : ratio <= 5 ? 5 : 10) * power;
}

function dateMarkers(series: PivotSeries, start: number, end: number) {
  if (!Number.isFinite(start) || end <= start) return [];
  const markers: { time: number; label: string | null }[] = [];
  const day = 86400;
  const firstMidnight = Math.floor((start + BEIJING_OFFSET) / day) * day - BEIJING_OFFSET + day;
  for (let time = firstMidnight; time <= end && markers.length < 180; time += day) {
    const previous = new Date((time + BEIJING_OFFSET - day) * 1000);
    const date = `${String(previous.getUTCMonth() + 1).padStart(2, "0")}/${String(previous.getUTCDate()).padStart(2, "0")} 24:00`;
    const dayIndex = Math.floor((time + BEIJING_OFFSET) / day);
    if (series.interval === "15m" && dayIndex % 2 !== 0) continue;
    const showLabel = series.interval === "1h"
      ? previous.getUTCDay() === 0 || previous.getUTCDay() === 4
      : series.interval === "15m" ? dayIndex % 2 === 0 : true;
    // Reading UTC fields on a shifted date avoids the computer's local zone.
    markers.push({ time, label: showLabel ? date : null });
  }
  return markers;
}

export default function AnalysisChart({ series, coverage, price, quoteStale, label }: AnalysisChartProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(760);
  const [hovered, setHovered] = useState<number | null>(null);
  const titleId = useId();
  const clipId = useId();

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    const observer = new ResizeObserver(([entry]) => setWidth(Math.max(530, Math.round(entry.contentRect.width))));
    observer.observe(container);
    return () => observer.disconnect();
  }, []);

  const chart = useMemo(() => {
    const points = series.points;
    const validPrice = !quoteStale && series.status === "ready" && price !== null && Number.isFinite(price) && price > 0 ? price : null;
    const endTime = Math.max(series.candidate?.time ?? 0, series.lastCandleClose ?? 0, points[points.length - 1]?.time ?? 0);
    const startTime = points[0]?.time ?? endTime;
    const box = series.interval === "2m" ? series.box : null;
    const visibleBox = box && box.endTime > startTime && box.startTime < endTime
      ? { start: Math.max(startTime, box.startTime), end: Math.min(endTime, box.endTime) } : null;
    const values = points.map((point) => point.price);
    if (series.candidate) values.push(series.candidate.price);
    if (validPrice !== null) values.push(validPrice);
    if (series.boll) values.push(series.boll.upper, series.boll.middle, series.boll.lower);
    if (series.range) values.push(series.range.high, series.range.low);
    if (box && visibleBox) values.push(box.high, box.low);
    const low = Math.min(...values);
    const high = Math.max(...values);
    const span = Math.max(high - low, Math.abs(high) * 0.002, 0.00000001);
    const min = low - span * 0.13;
    const max = high + span * 0.17;
    const left = 42;
    const right = width - 75;
    const hasCandidate = !!series.candidate;
    const slots = Math.max(3, points.length - 1 + (hasCandidate ? 2.2 : 1.2));
    const step = (right - left) / slots;
    const x = (index: number) => left + step * index;
    const y = (value: number) => TOP + (max - value) / (max - min) * (BOTTOM - TOP);
    const timeX = (time: number) => {
      if (!points.length) return left;
      if (time <= points[0].time) return left;
      for (let index = 1; index < points.length; index++) {
        if (time <= points[index].time) {
          const previous = points[index - 1];
          const current = points[index];
          return x(index - 1 + (time - previous.time) / Math.max(1, current.time - previous.time));
        }
      }
      const last = points[points.length - 1];
      return Math.min(right, x(points.length - 1) + (time - last.time) / Math.max(1, endTime - last.time) * step * (hasCandidate ? 2.2 : 1.2));
    };
    const stepValue = niceStep(max - min, 4);
    const ticks: number[] = [];
    if (Number.isFinite(min) && Number.isFinite(max)) {
      for (let value = Math.ceil(min / stepValue) * stepValue; value <= max + stepValue * 0.001 && ticks.length < 8; value += stepValue) ticks.push(value);
    }
    const candidateIndex = points.length;
    const liveIndex = points.length + (hasCandidate ? 1.15 : 0.15);
    const lastPoint = points[points.length - 1];
    const forecast: { x: number; y: number }[] = lastPoint ? [{ x: x(points.length - 1), y: y(lastPoint.price) }] : [];
    if (series.candidate) forecast.push({ x: x(candidateIndex), y: y(series.candidate.price) });
    if (validPrice !== null) forecast.push({ x: x(liveIndex), y: y(validPrice) });
    const boxWindow = visibleBox ? { ...visibleBox, left: Math.max(left, timeX(visibleBox.start)), right: Math.min(right, timeX(visibleBox.end)) } : null;
    return { left, right, step, x, y, min, max, ticks, startTime, endTime, timeX, validPrice, candidateIndex, liveIndex, forecast, boxWindow };
  }, [price, quoteStale, series, width]);

  const points = series.points;
  const hasPoints = points.length > 0;
  const activePoint = hovered !== null ? points[hovered] : null;
  // High/low labels occupy separate rows. Keep both kinds in each visible pair
  // and thin by the actual formatted price width rather than an arbitrary step.
  const labelWidth = Math.max(42, ...points.map((point) => priceText(point.price).length * 5.8 + 5));
  const labelStride = Math.max(1, Math.ceil(labelWidth / Math.max(1, chart.step * 2)));
  const timeStride = Math.max(1, Math.ceil(points.length / Math.max(5, Math.floor(width / 70))));
  const range = series.range;
  const box = series.interval === "2m" ? series.box : null;
  const boxWindow = chart.boxWindow;
  const coverageStart = coverage ? chart.timeX(coverage.startTime) : 0;
  const coverageEnd = coverage ? chart.timeX(coverage.endTime) : 0;
  const stale = quoteStale || series.status !== "ready";

  function pointClass(point: Pivot) {
    return `analysis-pivot ${point.trend ? `is-${point.trend}` : ""}`;
  }

  return (
    <div ref={containerRef} className="analysis-price-chart" data-interval={series.interval}>
      <div className="analysis-price-chart-caption">
        <strong>{label} · {points.length} 拐点</strong>
        <span className={stale ? "is-waiting" : "is-current"}>{series.status === "waiting" ? "等待确认" : series.status === "stale" ? "等待 K 线刷新" : quoteStale ? "等待最新报价" : "实时"}</span>
      </div>
      <div className="analysis-price-chart-scroll">
        <svg width={width} height={HEIGHT} viewBox={`0 0 ${width} ${HEIGHT}`} role="img" aria-labelledby={titleId}>
          <title id={titleId}>{label}价格拐点图，{points.length}个已确认拐点，黄色虚线表示未确认的末端候选</title>
          <defs><clipPath id={clipId}><rect x={chart.left - 4} y={TOP - 6} width={chart.right - chart.left + 8} height={BOTTOM - TOP + 12} /></clipPath></defs>
          {hasPoints && <>
            {chart.ticks.map((value, index) => <g key={index} className="analysis-chart-grid"><line x1={chart.left - 12} x2={chart.right + 12} y1={chart.y(value)} y2={chart.y(value)} /><text x={width - 8} y={chart.y(value) - 4} textAnchor="end">{priceText(value)}</text></g>)}
            {coverage && coverageEnd > chart.left && coverageStart < chart.right && <g className="analysis-coverage" clipPath={`url(#${clipId})`}><rect x={Math.max(chart.left, coverageStart)} y={TOP} width={Math.max(2, Math.min(chart.right, coverageEnd) - Math.max(chart.left, coverageStart))} height={BOTTOM - TOP} /><text x={Math.max(chart.left, coverageStart) + 8} y={TOP + 13}>{coverage.label} 覆盖时段</text></g>}
            {dateMarkers(series, chart.startTime, chart.endTime).map((marker) => <g key={marker.time} className="analysis-chart-date"><line x1={chart.timeX(marker.time)} x2={chart.timeX(marker.time)} y1={TOP} y2={BOTTOM + 31} />{marker.label && <text x={Math.max(82, chart.timeX(marker.time) - 4)} y={BOTTOM + 46} textAnchor="end">{marker.label}</text>}</g>)}
            {range && chart.timeX(range.endTime) > chart.left && <g className={`analysis-chart-range ${range.historical ? "is-history" : ""}`} clipPath={`url(#${clipId})`}><rect x={chart.timeX(range.startTime)} y={chart.y(range.high)} width={Math.max(1, chart.timeX(range.endTime) - chart.timeX(range.startTime))} height={Math.max(1, chart.y(range.low) - chart.y(range.high))} /><text x={chart.timeX(range.startTime) + 7} y={chart.y(range.high) + 14}>{label} {range.historical ? "历史震荡区" : range.breakout ? "震荡区越界观察" : "往返震荡"} · {range.rounds} 轮</text></g>}
            {box && boxWindow && boxWindow.right > boxWindow.left && <g className={`analysis-chart-box ${box.historical ? "is-history" : ""} ${box.breakout ? "is-breakout" : ""}`} clipPath={`url(#${clipId})`}>
              <title>{box.historical ? "历史箱体" : box.classificationPending ? "箱体归类待定" : box.placement}，上沿 {priceText(box.high)}，下沿 {priceText(box.low)}，{box.rounds} 次往返</title>
              <rect x={boxWindow.left} y={chart.y(box.high)} width={boxWindow.right - boxWindow.left} height={Math.max(1, chart.y(box.low) - chart.y(box.high))} />
              {([['upperBoundary', '80%'], ['lowerBoundary', '20%']] as const).map(([key, text]) => <g key={key}>
                <line className={`analysis-box-boundary ${key === "upperBoundary" ? "is-upper" : "is-lower"}`} x1={boxWindow.left} x2={boxWindow.right} y1={chart.y(box[key])} y2={chart.y(box[key])} />
                {boxWindow.right - boxWindow.left > 34 && <><rect className="analysis-box-label-bg" x={boxWindow.left + 3} y={chart.y(box[key]) - 12} width={27} height={12} /><text className="analysis-box-boundary-label" x={boxWindow.left + 6} y={chart.y(box[key]) - 3}>{text}</text></>}
              </g>)}
              {([{ time: box.confirmedAt, breakout: false }, ...(box.breakoutAt ? [{ time: box.breakoutAt, breakout: true }] : [])]).filter((event) => event.time >= boxWindow.start && event.time <= boxWindow.end).map((event) => <g key={`${event.time}-${event.breakout}`} className={`analysis-box-event ${event.breakout ? "is-breakout" : "is-confirmed"}`}>
                <title>{event.breakout ? `${box.breakout === "up" ? "向上" : "向下"}突破确认` : "箱体确认"} · {fullTimeText(event.time)} 北京时间</title>
                <line x1={chart.timeX(event.time)} x2={chart.timeX(event.time)} y1={chart.y(box.high)} y2={chart.y(box.low)} />
                <circle cx={chart.timeX(event.time)} cy={chart.y(event.breakout && box.breakout === "down" ? box.low : box.high)} r={3.5} />
              </g>)}
            </g>}
            {series.boll && ([['upper', '上'], ['middle', '中'], ['lower', '下']] as const).map(([key, text]) => <g key={key} className={`analysis-chart-boll is-${key}`}><line x1={chart.left + (chart.right - chart.left) * 0.4} x2={chart.right} y1={chart.y(series.boll![key])} y2={chart.y(series.boll![key])} /><text x={chart.left + (chart.right - chart.left) * 0.4 - 5} y={chart.y(series.boll![key]) - 4} textAnchor="end">{series.boll!.label} BOLL{text} {priceText(series.boll![key])}</text></g>)}
            <polyline className="analysis-chart-line" points={points.map((point, index) => `${chart.x(index)},${chart.y(point.price)}`).join(" ")} />
            {chart.forecast.length > 1 && <polyline className={`analysis-chart-candidate-line ${quoteStale ? "is-stale" : ""}`} points={chart.forecast.map((point) => `${point.x},${point.y}`).join(" ")} />}
            {points.map((point, index) => {
              const forced = point.trend || hovered === index || index === 0 || index === points.length - 1;
              const nearFirst = index > 0 && point.kind === points[0].kind && chart.step * index < labelWidth;
              const nearLast = index < points.length - 1 && point.kind === points[points.length - 1].kind && chart.step * (points.length - 1 - index) < labelWidth;
              const showLabel = forced || (!nearFirst && !nearLast && Math.floor(index / 2) % labelStride === 0);
              const isLow = point.kind === "low";
              return <g key={`${point.time}-${point.kind}`} className={pointClass(point)} onMouseEnter={() => setHovered(index)} onMouseLeave={() => setHovered(null)}>
                <circle className="analysis-pivot-hit" cx={chart.x(index)} cy={chart.y(point.price)} r={10} />
                <circle cx={chart.x(index)} cy={chart.y(point.price)} r={point.trend ? 3.7 : 2.5} />
                {showLabel && <text x={chart.x(index)} y={Math.min(BOTTOM + 12, Math.max(TOP - 12, chart.y(point.price) + (isLow ? 17 : -9)))} textAnchor="middle">{priceText(point.price)}{point.trend && <tspan className="analysis-trend-caption" x={chart.x(index)} dy={isLow ? 12 : -12}>{point.trend === "pending" ? "趋势待定" : "趋势拐点"}</tspan>}</text>}
              </g>;
            })}
            {series.candidate && <g className="analysis-chart-candidate"><circle cx={chart.x(chart.candidateIndex)} cy={chart.y(series.candidate.price)} r={3.2} /><text x={chart.x(chart.candidateIndex)} y={chart.y(series.candidate.price) + (series.candidate.kind === "low" ? 18 : -9)} textAnchor="middle">{priceText(series.candidate.price)} *</text></g>}
            {chart.validPrice !== null && <g className={`analysis-chart-live ${quoteStale ? "is-stale" : ""}`}><circle cx={chart.x(chart.liveIndex)} cy={chart.y(chart.validPrice)} r={3.4} /><text x={chart.x(chart.liveIndex)} y={Math.max(29, chart.y(chart.validPrice) - 32)} textAnchor="middle"><tspan x={chart.x(chart.liveIndex)}>现价</tspan><tspan x={chart.x(chart.liveIndex)} dy="14">{priceText(chart.validPrice)}</tspan></text></g>}
            {points.map((point, index) => (index % timeStride === 0 || index === points.length - 1) && <text key={`time-${point.time}`} className="analysis-chart-time" x={chart.x(index)} y={BOTTOM + 21} textAnchor="middle">{clockText(point.time)}</text>)}
            {activePoint && hovered !== null && <g className="analysis-chart-tooltip" pointerEvents="none"><rect x={Math.max(8, Math.min(width - 190, chart.x(hovered) - 87))} y={8} width={182} height={24} rx={3} /><text x={Math.max(8, Math.min(width - 190, chart.x(hovered) - 87)) + 9} y={24}>{fullTimeText(activePoint.time)} · {activePoint.kind === "high" ? "高点" : "低点"} {priceText(activePoint.price)}</text></g>}
          </>}
          {!hasPoints && <g className="analysis-chart-empty"><line x1={32} x2={width - 32} y1={145} y2={145} /><text x={width / 2} y={130} textAnchor="middle">等待连续 K 线与已确认拐点</text><text x={width / 2} y={166} textAnchor="middle">确认点需由收盘及后续 K 线验证</text></g>}
        </svg>
      </div>
      {box && <>
        <div className="analysis-box-chart-summary" aria-label="2M箱体价格与确认时间"><strong>{box.historical ? "历史箱体" : box.classificationPending ? "箱体归类待定" : box.placement}</strong><span>上沿 {priceText(box.high)}</span><span>80% {priceText(box.upperBoundary)}</span><span>20% {priceText(box.lowerBoundary)}</span><span>下沿 {priceText(box.low)}</span><span>往返 {box.rounds} 次</span><span>确认 {fullTimeText(box.confirmedAt)}</span>{box.breakoutAt && <span>{box.breakout === "up" ? "向上" : "向下"}突破 {fullTimeText(box.breakoutAt)}</span>}{box.pendingBreakout && !box.breakout && <span>{box.pendingBreakout === "up" ? "向上" : "向下"}越界 {box.pendingBreakoutCount ?? 1} 根 · 待确认</span>}</div>
        {!boxWindow && <div className="analysis-box-chart-note">箱体时段在当前拐点范围之外，保留价格与确认记录；图形不延伸到当前时段。</div>}
      </>}
    </div>
  );
}
