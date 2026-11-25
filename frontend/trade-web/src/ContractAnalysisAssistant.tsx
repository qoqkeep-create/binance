import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { Activity, ArrowDownLeft, ArrowUpRight, ChevronDown, CircleHelp, RefreshCw, X } from "lucide-react";
import AnalysisChart from "./AnalysisChart";
import { useContractAnalysis } from "./lib/useContractAnalysis";
import { isQuoteFresh } from "./lib/analysisSnapshot";
import type { AnalysisSnapshot, BoxRange, Direction, IndicatorRow, PivotSeries, TopInterval } from "./lib/analysisTypes";
import "./contract-analysis.css";
import { usePreference } from "./AccountProvider";

interface AssistantProps {
  symbol: string;
  baseAsset: string;
  structuresContainer: HTMLElement | null;
  onClose: () => void;
  returnFocusTo: HTMLElement | null;
}

const intervalLabels = { "2m": "2M", "5m": "5M", "10m": "10M", "15m": "15M", "1h": "1H" };
const formatTime = (time: number) => new Date(time * 1000).toLocaleTimeString("zh-CN", { timeZone: "Asia/Shanghai", hour12: false });
const formatBoxTime = (time: number) => new Intl.DateTimeFormat("zh-CN", { timeZone: "Asia/Shanghai", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false }).format(time * 1000);

export function analysisPrice(price: number | null | undefined) {
  if (price == null || !Number.isFinite(price)) return "—";
  return price.toLocaleString("en-US", {
    minimumFractionDigits: price >= 1 ? 2 : 4,
    maximumFractionDigits: price >= 100 ? 2 : price >= 1 ? 4 : price >= .01 ? 6 : 8,
  });
}

function coverageOf(series: PivotSeries | undefined) {
  if (!series?.points.length) return undefined;
  return {
    startTime: series.points[0].time,
    endTime: series.candidate?.time ?? series.points[series.points.length - 1].time,
    label: intervalLabels[series.interval],
  };
}

function StructureCard({ series, label, quoteStale }: { series?: PivotSeries; label: string; quoteStale: boolean }) {
  const ready = series?.status === "ready";
  const levelsReady = ready && !quoteStale;
  return (
    <article className="assistant-structure-card">
      <div className="assistant-structure-title"><span>{label}</span><span className={`assistant-direction ${ready ? series.structure.bias : "neutral"}`}>{ready ? series.structure.label : "等待确认"}</span></div>
      <p>{ready ? series.structure.description : series?.status === "stale" ? "等待 K 线刷新" : "有效拐点不足，等待周期确认"}</p>
      <div className="assistant-level down"><ArrowDownLeft size={12} /><span>向下关注</span><strong>{levelsReady && series.structure.supports.length ? series.structure.supports.map(analysisPrice).join(" / ") : "—"}</strong></div>
      <div className="assistant-level up"><ArrowUpRight size={12} /><span>向上关注</span><strong>{levelsReady && series.structure.resistances.length ? series.structure.resistances.map(analysisPrice).join(" / ") : "—"}</strong></div>
      {series?.range && <div className="assistant-range-note">{series.range.historical ? "历史震荡区" : "往返震荡"} · {series.range.rounds} 轮{series.range.breakout ? " · 越界观察" : ""}</div>}
    </article>
  );
}

function boxState(box: BoxRange) {
  if (box.breakout) return `历史箱体 · ${box.breakout === "up" ? "向上" : "向下"}突破`;
  if (box.historical) return "历史箱体";
  if (box.pendingBreakout) return `${box.pendingBreakout === "up" ? "向上" : "向下"}越界待确认`;
  return box.classificationPending ? "已确认 · 归类待定" : box.placement;
}

function BoxObservation({ series, price, quoteStale, loading, onView }: { series?: PivotSeries; price: number | null; quoteStale: boolean; loading: boolean; onView: () => void }) {
  const box = series?.box;
  const stale = series?.status === "stale";
  const validPosition = !!box && !box.historical && series?.status === "ready" && !quoteStale && price !== null;
  const position = validPosition && price !== null && box
    ? price > box.high ? "现价在上沿外" : price < box.low ? "现价在下沿外"
      : price >= box.upperBoundary ? "现价在上沿 20% 区" : price <= box.lowerBoundary ? "现价在下沿 20% 区" : "现价在箱体中部"
    : box?.historical ? "历史范围" : stale ? "等待 K 线刷新" : "等待有效报价";
  return (
    <article className="assistant-structure-card assistant-box-card" aria-label="2M箱体观察">
      <div className="assistant-box-heading"><h4>2M 箱体观察</h4><span className={`assistant-box-badge ${!box || stale || box.classificationPending ? "is-waiting" : ""}`}>{box ? stale && !box.historical ? "记录待刷新" : boxState(box) : loading ? "同步中" : "尚未确认"}</span></div>
      {box ? <>
        <p className="assistant-box-status-note">{stale ? "以下为最近确认记录，当前箱体状态等待 K 线刷新。" : box.breakout ? `连续两根收盘价越过${box.breakout === "up" ? "上沿" : "下沿"}及箱宽 2% 缓冲，已确认${box.breakout === "up" ? "向上" : "向下"}突破。` : box.pendingBreakout ? `已有 ${box.pendingBreakoutCount ?? 1} 根收盘价${box.pendingBreakout === "up" ? "向上" : "向下"}越界，等待下一根同向收盘确认。` : box.historical ? "保留已结束的箱体记录，不作为当前价格区间。" : box.classificationPending ? "箱体已确认，前序 15M / 30M 数据不足，暂不判定顶部或底部。" : "上下沿确认后保持固定；连续两根收盘价同向越界才登记突破。"}</p>
        <dl className="assistant-box-levels">
          <div><dt>箱体上沿</dt><dd>{analysisPrice(box.high)}</dd></div><div><dt>箱体下沿</dt><dd>{analysisPrice(box.low)}</dd></div>
          <div><dt>80% 边界</dt><dd>{analysisPrice(box.upperBoundary)}</dd></div><div><dt>20% 边界</dt><dd>{analysisPrice(box.lowerBoundary)}</dd></div>
        </dl>
        <div className="assistant-box-progress"><span>箱内往返 <strong>{box.rounds} 次</strong></span><strong>{position}</strong></div>
        {validPosition && price !== null && (price > box.high || price < box.low) && !box.pendingBreakout && <p className="assistant-box-status-note">报价越界仅作观察，尚未满足收盘突破条件。</p>}
        <div className="assistant-box-evidence" title="以下数值为箱体建立时的确认依据"><span>上沿触碰 {box.upperTouches} 次</span><span>下沿触碰 {box.lowerTouches} 次</span><span>{box.candleCount} 根确认</span><span>ATR {analysisPrice(box.atr)}</span><span>效率 {(box.efficiency * 100).toFixed(1)}%</span></div>
        <div className="assistant-box-times"><span>箱体确认<time dateTime={new Date(box.confirmedAt * 1000).toISOString()}>{formatBoxTime(box.confirmedAt)}</time></span>{box.breakoutAt && <span>突破确认<time dateTime={new Date(box.breakoutAt * 1000).toISOString()}>{formatBoxTime(box.breakoutAt)}</time></span>}</div>
      </> : <p className="assistant-box-empty">{loading ? "正在同步连续 2M K 线与确认拐点。" : stale ? "K 线已过期，刷新后重新检查箱体。" : series?.status === "waiting" ? "有效 K 线或确认拐点不足，箱体尚未确认。" : "当前没有符合条件的箱体。"}<br />需上下沿各至少两次触碰，并通过箱宽、效率与完整收盘检查。</p>}
      <button className="assistant-box-open" type="button" onClick={onView}>查看 2M 箱体 <ArrowUpRight size={12} /></button>
    </article>
  );
}

function emaLabel(row: IndicatorRow) {
  if (row.ema21 == null || row.ema55 == null || row.ema144 == null) return "等待计算";
  if (row.ema21 > row.ema55 && row.ema55 > row.ema144) return "多头排列";
  if (row.ema21 < row.ema55 && row.ema55 < row.ema144) return "空头排列";
  return "均线交错";
}

function bollLabel(row: IndicatorRow) {
  if (!row.boll || row.price == null) return "—";
  if (row.price > row.boll.upper) return "上轨之外";
  if (row.price < row.boll.lower) return "下轨之外";
  return row.price >= row.boll.middle ? "中上轨间" : "中下轨间";
}

function IndicatorTable({ rows, onDetails }: { rows: IndicatorRow[]; onDetails: (opener: HTMLButtonElement) => void }) {
  return (
    <section className="assistant-indicators">
      <div className="assistant-section-heading"><h3><Activity size={14} /> 合约指标趋势</h3><button type="button" onClick={(event) => onDetails(event.currentTarget)} aria-label="查看合约指标表说明">详 <CircleHelp size={12} /></button></div>
      <div className="assistant-table-scroll">
        <table>
          <caption className="assistant-sr-only">同一合约已收盘 K 线的多周期指标</caption>
          <thead><tr><th scope="col">周期</th><th scope="col">EMA 结构</th><th scope="col">MACD 柱</th><th scope="col">StochRSI K / D</th><th scope="col">BOLL 位置</th></tr></thead>
          <tbody>{(rows.length ? rows : ["5M", "15M", "30M", "1H", "2H", "4H", "12H", "24H"].map((label) => ({ label, interval: label, status: "waiting" } as IndicatorRow))).map((row) => (
            <tr key={row.interval}>
              <th scope="row">{row.label}</th>
              {row.status === "ready" ? <>
                <td className={`assistant-direction ${row.trend}`} title={`EMA21 ${analysisPrice(row.ema21)} · EMA55 ${analysisPrice(row.ema55)} · EMA144 ${analysisPrice(row.ema144)}`}>{emaLabel(row)}</td>
                <td className={row.macd == null ? "" : row.macd >= 0 ? "assistant-value-up" : "assistant-value-down"}>{row.macd == null ? "—" : `${row.macd >= 0 ? "+" : ""}${Math.abs(row.macd) < .01 ? row.macd.toPrecision(3) : row.macd.toFixed(2)}`}</td>
                <td>{row.stochK == null || row.stochD == null ? "—" : `${row.stochK.toFixed(1)} / ${row.stochD.toFixed(1)}`}</td>
                <td>{bollLabel(row)}</td>
              </> : <td colSpan={4} className="assistant-table-waiting">{row.status === "stale" ? "等待 K 线刷新" : "等待完整 K 线"}</td>}
            </tr>
          ))}</tbody>
        </table>
      </div>
      <div className="assistant-table-foot">EMA 21 / 55 / 144 · MACD 12 / 26 / 9 · BOLL 20 / 2</div>
    </section>
  );
}

function PlanPreview({ snapshot, topInterval, quoteStale }: { snapshot: AnalysisSnapshot | null; topInterval: TopInterval; quoteStale: boolean }) {
  const main = snapshot?.series["1h"];
  const valid = main?.status === "ready" && !quoteStale;
  const bias: Direction = valid ? main.structure.bias : "neutral";
  const peers = snapshot ? [snapshot.series[topInterval], snapshot.series["15m"]] : [];
  const agreement = valid && bias !== "neutral" ? peers.filter((series) => series.status === "ready" && series.structure.bias === bias).length : 0;
  return (
    <section className="assistant-plan">
      <div className="assistant-section-heading"><h3>交易挂单计划预览</h3><span>1H 主波段</span></div>
      <div className="assistant-plan-direction"><span className={`assistant-direction ${bias}`}>{!valid ? "等待有效市场快照" : bias === "up" ? "上升结构 · 偏多观察" : bias === "down" ? "下降结构 · 偏空观察" : "结构未共振 · 区间观察"}</span><small>{valid && bias !== "neutral" ? `${agreement + 1} / 3 周期同向` : "等待方向确认"}</small></div>
      <div className="assistant-plan-zone"><span>下方关注区</span><strong className="assistant-value-up">{valid && main.structure.supports.length ? [...main.structure.supports].reverse().map(analysisPrice).join(" — ") : "—"}</strong></div>
      <div className="assistant-plan-zone"><span>上方关注区</span><strong className="assistant-value-down">{valid && main.structure.resistances.length ? main.structure.resistances.map(analysisPrice).join(" — ") : "—"}</strong></div>
      <p className="assistant-plan-reading">{valid ? `结合 ${intervalLabels[topInterval]} 与 15M 结构，观察价格触及区间后的确认情况。` : "报价与 K 线有效后，按主波段结构生成关注区间。"}</p>
      <div className="assistant-plan-foot"><span className="assistant-small-dot" /> 结构预览 · 不执行挂单</div>
    </section>
  );
}

function DetailContent({ kind }: { kind: "full" | "indicators" }) {
  if (kind === "indicators") return <>
    <p>指标表与上方图表读取同一合约的市场快照，使用各周期连续、已收盘的 K 线计算。历史不足或数据过期时，显示等待状态。</p>
    <h4>EMA 结构</h4><p>使用 21、55、144 周期指数移动平均线。短期高于中期、中期高于长期时为多头排列，反向排列时为空头排列，其余为均线交错。悬停可查看三个均线数值。</p>
    <h4>MACD 与 StochRSI</h4><p>MACD 使用 12 / 26 / 9 参数，表内显示柱值。StochRSI 使用 RSI 14、随机窗口 14、K / D 平滑各 3；K 低于 20 和高于 80 分别作为向上、向下拐点的辅助观察。</p>
    <h4>BOLL 位置</h4><p>使用 20 周期均值和 2 倍标准差，展示该周期收盘价相对上下轨、中轨的位置。指标提供辅助证据，价格结构决定主要观察方向。</p>
  </>;
  return <>
    <p>合约分析助手将多周期价格拐点、价格结构与指标放在同一份市场快照中。顶部可切换 2M、5M、10M；下方固定为 15M 和 1H，1H 作为主波段。</p>
    <h4>确认点与动态候选</h4><p>青色实线连接已确认拐点。2M 由两根连续 1M K 线合成，并等待左右各两根收盘 K 线确认；平台极值以首根为锚点。5M、10M、15M、1H 使用 Depth 12、Deviation 5 个最小价位、Backstep 2 的 ZigZag++ 状态机。10M 仅由两根连续、完整的官方 5M K 线合成。</p>
    <p>黄色虚线与星号表示尚未确认的末端候选，不计入确认点数。形成中的 K 线和有效实时报价只延伸候选；历史缺口之后重新开始计算。绿色与红色标记分别代表向上与向下趋势拐点，灰色标记表示待定。</p>
    <h4>趋势拐点</h4><p>系统根据锚点前最多六个高点和六个低点，计算同类价差中位数作为常态波动。原结构下降后，更低低点与后续突破前高的反应共同确认向上拐点；向下拐点对称判断。后续出现更极端同向价位时，原锚点停止等待。大周期相近且时间重叠的极值可承接小周期提示为待定，随后等待大周期确认。</p>
    <h4>合约价格结构</h4><p>使用最近最多 12 个确认点，至少需要两个高点和两个低点。高低点同升为偏强，同降为偏弱；其余按区间、收敛、扩张或混合结构观察。容差为价格保护值与相邻波段幅度中位数 5% 中的较大值。向下与向上关注位分别取现价下方最近两个、上方最近两个去重确认价位；震荡结构优先使用区间上下沿。</p>
    <h4>往返震荡与箱体</h4><p>10M、15M 使用最近 8 至 12 个确认点寻找往返震荡：效率不高于 0.25，离散度不高于 0.70，漂移不高于 0.60，单段波动不超过中位摆动的 2.8 倍，达到中位摆动 35% 的波段占比至少 65%。现价越过边沿超过区间宽度的 5% 后，进入越界观察；过往合格区间以历史范围保留。</p>
    <p>2M 箱体使用 12 至 60 根完整 K 线，上下沿各至少两次确认触碰、箱宽至少为 ATR 的 1.25 倍、效率不高于 0.40。确认后固定边沿，连续两根收盘价越过边沿并超过箱宽的 2% 才登记突破；仅有一根越界时显示待确认，实时价格越界不等于收盘突破。20% / 80% 边界用于计算完整往返，完成上→下→上或下→上→下记一次。右侧独立显示 2M 箱体，即使顶部选中 5M 或 10M 仍可查看；前序 15M、30M 数据充分时，结合方向与位置归类为顶部、底部或箱体整理，否则显示归类待定。已突破箱体保留为历史记录。</p>
    <h4>图表与数据时效</h4><p>拐点按发生顺序等距排列，纵轴按真实价格线性绘制。淡色覆盖带表示较短周期覆盖的时段，日期分隔采用北京时间。箱体图形只绘制与当前拐点时段重合的部分，历史范围在当前时段以外时保留文字记录。5M、10M 最多显示 35 点，15M、1H 最多显示 24 点；趋势分类仍读取更长历史。</p>
    <p>报价超过 15 秒未更新时显示等待最新报价；K 线来源超过 150 秒未刷新、周期应收盘却未获得新 K 线时，显示等待刷新。过期报价不用于候选延伸或关注区间预览。底部计划读取 1H、当前顶部周期与 15M 的同一观察结果。</p>
  </>;
}

export default function ContractAnalysisAssistant({ symbol, baseAsset, structuresContainer, onClose, returnFocusTo }: AssistantProps) {
  const [topInterval, setTopInterval] = usePreference<TopInterval>("assistantTopInterval", "5m", (value): value is TopInterval => value === "2m" || value === "5m" || value === "10m");
  const [details, setDetails] = useState<"full" | "indicators" | null>(null);
  const { snapshot, loading, refreshing, error, refresh } = useContractAnalysis(symbol);
  const closeRef = useRef<HTMLButtonElement>(null);
  const detailRef = useRef<HTMLDivElement>(null);
  const detailCloseRef = useRef<HTMLButtonElement>(null);
  const detailOpenerRef = useRef<HTMLElement | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const twoMinuteRef = useRef<HTMLButtonElement>(null);
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;

  useEffect(() => {
    const opener = returnFocusTo;
    closeRef.current?.focus();
    return () => { if (opener?.isConnected) opener.focus(); };
  }, []);

  useEffect(() => {
    structuresContainer?.scrollTo({ top: 0 });
  }, [structuresContainer]);

  useEffect(() => {
    if (!details) return;
    const opener = detailOpenerRef.current;
    detailCloseRef.current?.focus();
    return () => { if (opener?.isConnected) opener.focus(); };
  }, [details]);

  function openDetails(kind: "full" | "indicators", opener: HTMLElement) {
    detailOpenerRef.current = opener;
    setDetails(kind);
  }

  function viewBox() {
    setTopInterval("2m");
    scrollRef.current?.scrollTo({ top: 0, behavior: "smooth" });
    twoMinuteRef.current?.focus();
  }

  useEffect(() => {
    const handleKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        if (details) setDetails(null);
        else onCloseRef.current();
      }
      if (event.key === "Tab" && details) {
        const focusable = detailRef.current?.querySelectorAll<HTMLElement>('button, a[href], [tabindex="0"]');
        if (!focusable?.length) return;
        const first = focusable[0];
        const last = focusable[focusable.length - 1];
        if (event.shiftKey && (document.activeElement === first || !detailRef.current?.contains(document.activeElement))) { event.preventDefault(); last.focus(); }
        else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
      }
    };
    document.addEventListener("keydown", handleKey, true);
    return () => document.removeEventListener("keydown", handleKey, true);
  }, [details]);

  const quote = snapshot?.quote;
  const quoteStale = !isQuoteFresh(quote ?? null, Date.now() / 1000);
  const top = snapshot?.series[topInterval];
  const medium = snapshot?.series["15m"];
  const main = snapshot?.series["1h"];

  return (
    <section className="contract-assistant" id="contract-analysis-assistant" role="region" aria-label={`${baseAsset} 合约分析助手`}>
      <div className="assistant-surface" inert={details ? true : undefined}>
        <header className="assistant-header">
          <div className="assistant-heading"><span className="assistant-heading-mark"><Activity size={17} /></span><h2>合约分析助手</h2><span className="assistant-contract">{baseAsset}<span> / USDT</span></span></div>
          <div className="assistant-header-actions">
            <button className="assistant-refresh" onClick={refresh} type="button" disabled={loading || refreshing} aria-label="刷新合约分析" title="刷新合约分析"><RefreshCw size={13} className={loading || refreshing ? "spin" : ""} /><span>刷新</span></button>
            <button className="assistant-close" type="button" onClick={onClose} ref={closeRef} aria-label="关闭合约分析助手"><span>关闭</span><X size={14} /></button>
          </div>
        </header>
        <div className="assistant-scroll" ref={scrollRef}>
          <div className="assistant-controls">
            <div className="assistant-period-control"><span>顶部周期</span><div role="group" aria-label="顶部分析周期">{(["2m", "5m", "10m"] as TopInterval[]).map((interval) => <button type="button" key={interval} ref={interval === "2m" ? twoMinuteRef : undefined} aria-pressed={topInterval === interval} className={topInterval === interval ? "active" : ""} onClick={() => setTopInterval(interval)}>{intervalLabels[interval]}</button>)}</div></div>
            <div className={`assistant-snapshot-status ${quoteStale ? "waiting" : ""}`}><span className="assistant-small-dot" />{loading ? "正在同步市场快照" : quoteStale ? "等待最新报价" : `现价 ${analysisPrice(quote?.price)}`}<span className="assistant-snapshot-time">{snapshot ? `${formatTime(snapshot.fetchedAt)} 北京时间` : "BINANCE 永续"}</span></div>
          </div>
          {error && <div className="assistant-error" role="status"><span>{error}</span><button type="button" onClick={refresh} disabled={loading || refreshing}>重试 <RefreshCw size={12} /></button></div>}
          <div className="assistant-chart-layout">
            <div className="assistant-chart-top">{top ? <AnalysisChart series={top} price={quote?.price ?? null} quoteStale={quoteStale} label={intervalLabels[topInterval]} /> : <ChartWaiting label={intervalLabels[topInterval]} loading={loading} />}</div>
            <div className="assistant-chart-stack">
              {medium ? <AnalysisChart series={medium} coverage={coverageOf(top)} price={quote?.price ?? null} quoteStale={quoteStale} label="15M" /> : <ChartWaiting label="15M" loading={loading} />}
              {main ? <AnalysisChart series={main} coverage={coverageOf(medium)} price={quote?.price ?? null} quoteStale={quoteStale} label="1H" /> : <ChartWaiting label="1H" loading={loading} />}
            </div>
          </div>
          <div className="assistant-chart-legend"><span><i /> 价格轴说明</span><span>青色实线为确认拐点，黄色虚线为末端候选；淡色覆盖带为短周期覆盖时段。</span></div>
          <div className="assistant-bottom-grid"><IndicatorTable rows={snapshot?.indicators ?? []} onDetails={(opener) => openDetails("indicators", opener)} /><PlanPreview snapshot={snapshot} topInterval={topInterval} quoteStale={quoteStale} /></div>
          <footer className="assistant-footer"><span>价格结构观察 · {baseAsset}/USDT 永续</span><button type="button" onClick={(event) => openDetails("full", event.currentTarget)}><CircleHelp size={13} /> 详细说明 <ChevronDown size={12} /></button></footer>
        </div>
      </div>
      {structuresContainer && createPortal(
        <div className="assistant-structures" inert={details ? true : undefined}>
          <header className="assistant-structures-heading"><h2 id="assistant-structures-title">结构与箱体观察</h2><span>观察结论</span></header>
          <BoxObservation series={snapshot?.series["2m"]} price={quote?.price ?? null} quoteStale={quoteStale} loading={loading} onView={viewBox} />
          <StructureCard series={top} quoteStale={quoteStale} label={`${intervalLabels[topInterval]} 拐点结构`} />
          <StructureCard series={medium} quoteStale={quoteStale} label="15M 拐点结构" />
          <StructureCard series={main} quoteStale={quoteStale} label="1H 主波段结构" />
          <div className="assistant-structure-key"><span><i className="cyan" /> 已确认</span><span><i className="yellow" /> 候选点 *</span><span><i className="green" /> 向上拐点</span><span><i className="red" /> 向下拐点</span></div>
        </div>,
        structuresContainer,
      )}
      {details && <div className="assistant-detail-backdrop"><div className="assistant-detail-dialog" ref={detailRef} role="dialog" aria-modal="true" aria-labelledby="assistant-detail-title"><header><div><span className="assistant-detail-eyebrow">ANALYSIS GUIDE</span><h3 id="assistant-detail-title">{details === "full" ? "合约分析助手 · 详细说明" : "合约指标表说明"}</h3></div><button ref={detailCloseRef} type="button" onClick={() => setDetails(null)} aria-label="关闭说明"><X size={17} /></button></header><div className="assistant-detail-body" tabIndex={0}><DetailContent kind={details} /></div><footer><span>按 Esc 收起说明</span><button type="button" onClick={() => setDetails(null)}>知道了</button></footer></div></div>}
    </section>
  );
}

function ChartWaiting({ label, loading }: { label: string; loading: boolean }) {
  return <div className="assistant-chart-waiting"><span className="assistant-chart-waiting-label">{label} · 价格拐点</span><div role="status">{loading ? <><RefreshCw size={15} className="spin" /> 正在同步 K 线与价格结构…</> : <>等待完整 K 线后绘制拐点</>}</div></div>;
}
