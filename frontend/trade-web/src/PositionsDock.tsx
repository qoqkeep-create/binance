import { useState } from "react";
import { ChevronDown, ChevronUp, X } from "lucide-react";
import { tradeApi, isLongSide, type PositionRow } from "./lib/tradeApi";
import { TpLevels } from "./Pages";

const num = (value: number | string | null | undefined) => {
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
};
const fmt = (value: number | string | null | undefined, digits = 2) => num(value).toLocaleString("zh-CN", { minimumFractionDigits: digits, maximumFractionDigits: digits });

export function PositionsDock({ rows, prices, open, onToggle, onOpenSymbol, onChanged }: {
  rows: PositionRow[];
  prices: Record<string, number>;
  open: boolean;
  onToggle: () => void;
  onOpenSymbol: (symbol: string) => void;
  onChanged: () => void;
}) {
  const [confirmRow, setConfirmRow] = useState<PositionRow | null>(null);
  const [tpRow, setTpRow] = useState<PositionRow | null>(null);
  const [closing, setClosing] = useState(false);
  const [notice, setNotice] = useState("");

  async function closePosition(row: PositionRow) {
    setClosing(true);
    setNotice("");
    try {
      const commandId = await tradeApi.submitCommand("position-close", { position_id: row.id });
      const result = await tradeApi.pollCommand(commandId);
      setNotice(result.status === "SUCCEEDED" ? "平仓命令已确认" : result.status === "FAILED" ? `平仓失败：${result.result?.message ?? "请重试"}` : "平仓结果待确认，已刷新持仓");
      setConfirmRow(null);
      onChanged();
    } catch (err) {
      setNotice(err instanceof Error ? err.message : "平仓请求失败");
    } finally {
      setClosing(false);
    }
  }

  return <div className="positions-dock">
    {!open && <button type="button" className="positions-dock-toggle positions-dock-closed" aria-expanded={false} aria-label="展开持仓列表" onClick={onToggle}><ChevronUp size={13} /> 持仓</button>}
    {open && <div className="positions-dock-body">
      <div className="positions-dock-head" role="row">
        <span>币种/方向</span><span>仓位</span><span>保证金</span><span>开仓价</span><span>现价</span><span>浮盈浮亏</span><span>市价止损</span><span>市价止盈</span><span className="pd-op-head"><em>操作</em><button type="button" className="positions-dock-toggle" aria-expanded={open} aria-label={open ? "收起持仓列表" : "展开持仓列表"} onClick={onToggle}><ChevronDown size={13} /> 持仓</button></span>
      </div>
      <div className="positions-dock-list">
        {rows.length === 0 && <p className="positions-dock-empty">暂无持仓</p>}
        {rows.map((row) => {
          const long = isLongSide(row.side);
          const mark = prices[row.symbol] ?? num(row.current_price);
          const entry = num(row.open_price);
          const notional = num(row.position_amount);
          const pnl = entry > 0 && Number.isFinite(mark) ? (mark - entry) / entry * notional * (long ? 1 : -1) : num(row.pnl);
          const ratio = entry > 0 ? (mark - entry) / entry * 100 * (long ? 1 : -1) : num(row.pnl_ratio) * 100;
          return <div key={row.id} className="positions-dock-row" role="row">
            <span className="pd-symbol">
              <button type="button" onClick={() => onOpenSymbol(row.symbol)} aria-label={`查看 ${row.symbol} K线`}>{row.symbol.replace(/USDT$/, "")}</button>
              <em className={`pd-side ${long ? "long" : "short"}`}>{long ? "多" : "空"}</em>
              <small>x{row.leverage}</small>
            </span>
            <span>{fmt(notional)} U</span>
            <span>{fmt(row.margin)} U</span>
            <span>{fmt(entry, 4)}</span>
            <span>{fmt(mark, 4)}</span>
            <span className={pnl >= 0 ? "pd-up" : "pd-down"}>{pnl >= 0 ? "+" : "-"}{fmt(Math.abs(pnl))} U（{ratio >= 0 ? "+" : "-"}{fmt(Math.abs(ratio))}%）</span>
            <span>{row.market_stop_price ? fmt(row.market_stop_price, 4) : "未设置"}</span>
            <span>{row.manual_take_profit_price ? fmt(row.manual_take_profit_price, 4) : "未设置"}</span>
            <span className="pd-actions">
              <button type="button" className={`pg-tp-btn ${row.strategy_status === 1 ? "is-running" : ""}`} onClick={() => setTpRow(row)}>{row.strategy_status === 1 ? "自动止盈中" : "自动止盈"}</button>
              <button type="button" className="pg-close-btn" onClick={() => setConfirmRow(row)}>立即平仓</button>
            </span>
          </div>;
        })}
      </div>
      {notice && <p className="positions-dock-notice">{notice}</p>}
    </div>}
    {confirmRow && <div className="pg-confirm-backdrop">
      <div className="pg-confirm" role="dialog" aria-modal="true">
        <header><strong>确认平仓</strong><button type="button" aria-label="关闭" onClick={() => setConfirmRow(null)}><X size={15} /></button></header>
        <p>将以市价平掉 {confirmRow.symbol.replace(/USDT$/, "")}/USDT 持仓，实际成交以交易所为准。确认继续？</p>
        <footer>
          <button type="button" onClick={() => setConfirmRow(null)}>取消</button>
          <button type="button" className="is-danger" disabled={closing} onClick={() => void closePosition(confirmRow)}>{closing ? "平仓中…" : "确认平仓"}</button>
        </footer>
      </div>
    </div>}
    {tpRow && <div className="pg-confirm-backdrop">
      <div className="pg-confirm" role="dialog" aria-modal="true">
        <header><strong>自动止盈策略</strong><button type="button" aria-label="关闭" onClick={() => setTpRow(null)}><X size={15} /></button></header>
        {tpRow.strategy_config?.length ? <>
          <p className="pg-tp-name">{tpRow.strategy_name || "自动止盈"}{tpRow.strategy_status === 1 ? "（运行中）" : tpRow.strategy_status === 2 ? "（已取消）" : ""}</p>
          <TpLevels levels={tpRow.strategy_config} />
        </> : <p>该持仓未绑定自动止盈策略。</p>}
        <footer><button type="button" onClick={() => setTpRow(null)}>关闭</button></footer>
      </div>
    </div>}
  </div>;
}