import { useCallback, useEffect, useState } from "react";
import { ChevronDown, LoaderCircle, X } from "lucide-react";
import { tradeApi, isLongSide, type HistoryRow, type OrderRow, type PositionRow } from "./lib/tradeApi";
import { TpLevels } from "./Pages";

type DockTab = "positions" | "orders" | "history";

const num = (value: number | string | null | undefined) => {
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
};
const fmt = (value: number | string | null | undefined, digits = 2) => num(value).toLocaleString("zh-CN", { minimumFractionDigits: digits, maximumFractionDigits: digits });
const orderKind = (value: string) => ({ limit: "限价", maker: "Maker", stop_loss: "止损", take_profit: "止盈" }[value] ?? value);

export function PositionsDock({ rows, prices, open, onToggle, onOpenSymbol, onChanged }: {
  rows: PositionRow[];
  prices: Record<string, number>;
  open: boolean;
  onToggle: () => void;
  onOpenSymbol: (symbol: string) => void;
  onChanged: () => void;
}) {
  const [tab, setTab] = useState<DockTab>("positions");
  const [orders, setOrders] = useState<OrderRow[]>([]);
  const [history, setHistory] = useState<HistoryRow[]>([]);
  const [listState, setListState] = useState<"idle" | "loading" | "ready" | "error">("idle");
  const [actionId, setActionId] = useState<number | null>(null);
  const [confirmRow, setConfirmRow] = useState<PositionRow | null>(null);
  const [tpRow, setTpRow] = useState<PositionRow | null>(null);
  const [closing, setClosing] = useState(false);
  const [notice, setNotice] = useState("");
  const [reloadVersion, setReloadVersion] = useState(0);

  const loadList = useCallback(async (target: DockTab, signal?: AbortSignal) => {
    if (target === "positions") return;
    setListState("loading");
    try {
      if (target === "orders") {
        const data = await tradeApi.orders(1, signal);
        setOrders(data.items);
      } else {
        const data = await tradeApi.history("all", 1, signal);
        setHistory(data.items);
      }
      setListState("ready");
    } catch (error) {
      if (signal?.aborted) return;
      setNotice(error instanceof Error ? error.message : "列表加载失败");
      setListState("error");
    }
  }, []);

  useEffect(() => {
    if (!open || tab === "positions") return;
    const controller = new AbortController();
    void loadList(tab, controller.signal);
    return () => controller.abort();
  }, [loadList, open, reloadVersion, tab]);

  async function closePosition(row: PositionRow) {
    setClosing(true);
    setNotice("");
    try {
      const commandId = await tradeApi.submitCommand("position-close", { position_id: row.id });
      const result = await tradeApi.pollCommand(commandId);
      setNotice(result.status === "SUCCEEDED" ? "平仓命令已确认" : result.status === "FAILED" ? `平仓失败：${result.result?.message ?? "请重试"}` : "平仓结果待确认，已刷新持仓");
      setConfirmRow(null);
      onChanged();
    } catch (error) {
      setNotice(error instanceof Error ? error.message : "平仓请求失败");
    } finally {
      setClosing(false);
    }
  }

  async function runOrderAction(row: OrderRow, action: "limit-cancel" | "limit-chase") {
    setActionId(row.id);
    setNotice("");
    try {
      const commandId = await tradeApi.submitCommand(action, { limit_order_id: row.id });
      const result = await tradeApi.pollCommand(commandId);
      setNotice(result.status === "SUCCEEDED" ? (action === "limit-cancel" ? "委托已撤销" : "追单命令已确认") : result.status === "FAILED" ? (result.result?.message ?? "委托操作失败") : "委托结果待确认");
      setReloadVersion((value) => value + 1);
    } catch (error) {
      setNotice(error instanceof Error ? error.message : "委托操作失败");
    } finally {
      setActionId(null);
    }
  }

  if (!open) return null;
  return <div className="positions-dock" role="dialog" aria-label="交易抽屉">
    <div className="positions-dock-topbar">
      <div className="positions-dock-tabs" role="tablist" aria-label="交易信息分类">
        {(["positions", "orders", "history"] as const).map((value) => <button key={value} type="button" role="tab" aria-selected={tab === value} className={`positions-dock-tab ${tab === value ? "active" : ""}`} onClick={() => { setTab(value); setNotice(""); }}>
          {value === "positions" ? `持仓${rows.length ? ` ${rows.length}` : ""}` : value === "orders" ? "委托" : "历史"}
        </button>)}
      </div>
      <button type="button" className="positions-dock-close" aria-expanded={true} aria-label="收起交易抽屉" onClick={onToggle}><ChevronDown size={14} /></button>
    </div>
    <div className="positions-dock-body">
      {tab === "positions" && <><div className="positions-dock-head" role="row">
        <span>币种/方向</span><span>仓位</span><span>保证金</span><span>开仓价</span><span>现价</span><span>浮盈浮亏</span><span>市价止损</span><span>市价止盈</span><span>操作</span>
      </div><div className="positions-dock-list">
        {rows.length === 0 && <p className="positions-dock-empty">暂无持仓</p>}
        {rows.map((row) => {
          const long = isLongSide(row.side);
          const mark = prices[row.symbol] ?? num(row.current_price);
          const entry = num(row.open_price);
          const notional = num(row.position_amount);
          const pnl = entry > 0 && Number.isFinite(mark) ? (mark - entry) / entry * notional * (long ? 1 : -1) : num(row.pnl);
          const ratio = entry > 0 ? (mark - entry) / entry * 100 * (long ? 1 : -1) : num(row.pnl_ratio) * 100;
          return <div key={row.id} className="positions-dock-row" role="row">
            <span className="pd-symbol"><button type="button" onClick={() => onOpenSymbol(row.symbol)} aria-label={`查看 ${row.symbol} K线`}>{row.symbol.replace(/USDT$/, "")}</button><em className={`pd-side ${long ? "long" : "short"}`}>{long ? "多" : "空"}</em><small>x{row.leverage}</small></span>
            <span>{fmt(notional)} U</span><span>{fmt(row.margin)} U</span><span>{fmt(entry, 4)}</span><span>{fmt(mark, 4)}</span>
            <span className={pnl >= 0 ? "pd-up" : "pd-down"}>{pnl >= 0 ? "+" : "-"}{fmt(Math.abs(pnl))} U（{ratio >= 0 ? "+" : "-"}{fmt(Math.abs(ratio))}%）</span>
            <span>{row.market_stop_price ? fmt(row.market_stop_price, 4) : "未设置"}</span><span>{row.manual_take_profit_price ? fmt(row.manual_take_profit_price, 4) : "未设置"}</span>
            <span className="pd-actions"><button type="button" className={`pg-tp-btn ${row.strategy_status === 1 ? "is-running" : ""}`} onClick={() => setTpRow(row)}>{row.strategy_status === 1 ? "自动止盈中" : "自动止盈"}</button><button type="button" className="pg-close-btn" onClick={() => setConfirmRow(row)}>立即平仓</button></span>
          </div>;
        })}
      </div></>}
      {tab === "orders" && <div className="positions-dock-list positions-dock-cards">
        {listState === "loading" && <p className="positions-dock-empty"><LoaderCircle size={14} className="spin" /> 正在加载委托…</p>}
        {listState === "error" && <p className="positions-dock-empty">委托加载失败，请切换页签重试</p>}
        {listState === "ready" && orders.length === 0 && <p className="positions-dock-empty">暂无委托</p>}
        {listState === "ready" && orders.map((row) => <article key={row.id} className="positions-dock-card">
          <header><span className="pd-card-symbol"><button type="button" onClick={() => onOpenSymbol(row.symbol)}>{row.symbol.replace(/USDT$/, "")}/USDT</button><span className={`pd-side ${isLongSide(row.side) ? "long" : "short"}`}>{isLongSide(row.side) ? "多" : "空"}</span></span><span className="pg-tag">{row.status_text}</span></header>
          <div className="positions-dock-card-grid"><span>类型 <strong>{orderKind(row.kind)}</strong></span><span>杠杆 <strong>x{row.leverage}</strong></span><span>委托价 <strong>{fmt(row.price, 4)}</strong></span><span>成交均价 <strong>{row.avg_price ? fmt(row.avg_price, 4) : "—"}</strong></span><span>委托金额 <strong>{fmt(row.amount)} U</strong></span><span>时间 <strong>{row.created_at}</strong></span></div>
          <footer>{row.can_cancel && <button type="button" className="order-action is-danger" disabled={actionId === row.id} onClick={() => void runOrderAction(row, "limit-cancel")}>{actionId === row.id ? "处理中…" : "撤单"}</button>}{row.can_chase && <button type="button" className="order-action" disabled={actionId === row.id} onClick={() => void runOrderAction(row, "limit-chase")}>追单</button>}</footer>
        </article>)}
      </div>}
      {tab === "history" && <div className="positions-dock-list positions-dock-cards">
        {listState === "loading" && <p className="positions-dock-empty"><LoaderCircle size={14} className="spin" /> 正在加载历史…</p>}
        {listState === "error" && <p className="positions-dock-empty">历史加载失败，请切换页签重试</p>}
        {listState === "ready" && history.length === 0 && <p className="positions-dock-empty">暂无历史记录</p>}
        {listState === "ready" && history.map((row) => { const pnl = num(row.pnl); return <article key={row.id} className="positions-dock-card">
          <header><span className="pd-card-symbol"><button type="button" onClick={() => onOpenSymbol(row.symbol)}>{row.symbol.replace(/USDT$/, "")}/USDT</button><span className={`pd-side ${isLongSide(row.side) ? "long" : "short"}`}>{isLongSide(row.side) ? "多" : "空"}</span></span><span className={pnl >= 0 ? "pd-up" : "pd-down"}>{pnl >= 0 ? "+" : "-"}{fmt(Math.abs(pnl))} U</span></header>
          <div className="positions-dock-card-grid"><span>盈亏比 <strong>{fmt(num(row.pnl_ratio) * 100)}%</strong></span><span>开仓价 <strong>{fmt(row.open_price, 4)}</strong></span><span>平仓价 <strong>{fmt(row.close_price, 4)}</strong></span><span>持仓额 <strong>{fmt(row.position_amount)} U</strong></span><span>手续费 <strong>{fmt(num(row.fee) + num(row.funding_fee))} U</strong></span><span>时间 <strong>{row.closed_at}</strong></span></div>
        </article>; })}
      </div>}
      {notice && <p className="positions-dock-notice">{notice}</p>}
    </div>
    {confirmRow && <div className="pg-confirm-backdrop"><div className="pg-confirm" role="dialog" aria-modal="true"><header><strong>确认平仓</strong><button type="button" aria-label="关闭" onClick={() => setConfirmRow(null)}><X size={15} /></button></header><p>将以市价平掉 {confirmRow.symbol.replace(/USDT$/, "")}/USDT 持仓，实际成交以交易所为准。确认继续？</p><footer><button type="button" onClick={() => setConfirmRow(null)}>取消</button><button type="button" className="is-danger" disabled={closing} onClick={() => void closePosition(confirmRow)}>{closing ? "平仓中…" : "确认平仓"}</button></footer></div></div>}
    {tpRow && <div className="pg-confirm-backdrop"><div className="pg-confirm" role="dialog" aria-modal="true"><header><strong>自动止盈策略</strong><button type="button" aria-label="关闭" onClick={() => setTpRow(null)}><X size={15} /></button></header>{tpRow.strategy_config?.length ? <><p className="pg-tp-name">{tpRow.strategy_name || "自动止盈"}{tpRow.strategy_status === 1 ? "（运行中）" : tpRow.strategy_status === 2 ? "（已取消）" : ""}</p><TpLevels levels={tpRow.strategy_config} /></> : <p>该持仓未绑定自动止盈策略。</p>}<footer><button type="button" onClick={() => setTpRow(null)}>关闭</button></footer></div></div>}
  </div>;
}
