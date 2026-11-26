import { useCallback, useEffect, useState } from "react";
import { RefreshCw, ShieldAlert, X } from "lucide-react";
import { useAccount } from "./AccountProvider";
import { tradeApi, type PositionRow, type MarginInfo, type HistoryRow, type OrderRow, type AccountInfo, type Profile, type ApiInfo } from "./lib/tradeApi";

const num = (value: number | string | null | undefined) => {
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
};
const fmt = (value: number | string | null | undefined, digits = 2) => num(value).toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits });
const isLong = (side: string) => side === "0" || side === "long" || side === "BUY";

function SideBadge({ side }: { side: string }) {
  return <span className={`pg-side ${isLong(side) ? "is-long" : "is-short"}`}>{isLong(side) ? "多" : "空"}</span>;
}

function ErrorNote({ message, onRetry }: { message: string; onRetry: () => void }) {
  return <div className="pg-empty"><span>{message}</span><button type="button" onClick={onRetry}>重试</button></div>;
}

export function PositionsPage({ onOpenSymbol, prices }: { onOpenSymbol: (symbol: string) => void; prices: Record<string, number> }) {
  const [rows, setRows] = useState<PositionRow[]>([]);
  const [margin, setMargin] = useState<MarginInfo | null>(null);
  const [state, setState] = useState<"loading" | "ready" | "error">("loading");
  const [error, setError] = useState("");
  const [confirmId, setConfirmId] = useState<number | null>(null);
  const [closing, setClosing] = useState(false);
  const [notice, setNotice] = useState("");

  const load = useCallback(async (signal?: AbortSignal) => {
    try {
      const [list, marginInfo] = await Promise.all([tradeApi.positions(signal), tradeApi.margin(signal).catch(() => null)]);
      setRows(list);
      setMargin(marginInfo);
      setState("ready");
    } catch (err) {
      if (signal?.aborted) return;
      setError(err instanceof Error ? err.message : "持仓加载失败");
      setState("error");
    }
  }, []);

  useEffect(() => {
    const controller = new AbortController();
    void load(controller.signal);
    const timer = window.setInterval(() => void load(controller.signal), 5000);
    return () => { controller.abort(); window.clearInterval(timer); };
  }, [load]);

  async function closePosition(id: number) {
    setClosing(true);
    setNotice("");
    try {
      const commandId = await tradeApi.submitCommand("position-close", { position_id: id });
      const result = await tradeApi.pollCommand(commandId);
      setNotice(result.status === "SUCCEEDED" ? "平仓命令已确认" : result.status === "FAILED" ? `平仓失败：${result.result?.message ?? "请重试"}` : "平仓结果待确认，已刷新持仓");
      setConfirmId(null);
      await load();
    } catch (err) {
      setNotice(err instanceof Error ? err.message : "平仓请求失败");
    } finally {
      setClosing(false);
    }
  }

  const ratio = num(margin?.margin_ratio_percent);
  return <div className="pg-wrap">
    <header className="pg-head">
      <h2>持仓</h2>
      {margin && <span className={`pg-margin ${ratio >= 80 ? "is-danger" : ratio >= 50 ? "is-warn" : ""}`}><ShieldAlert size={13} /> 保证金率 {fmt(ratio)}%</span>}
      <button type="button" className="pg-refresh" onClick={() => void load()} aria-label="刷新持仓"><RefreshCw size={14} /></button>
    </header>
    {notice && <div className="pg-notice">{notice}</div>}
    {state === "loading" && <div className="pg-empty"><RefreshCw size={14} className="spin" /> 正在加载持仓…</div>}
    {state === "error" && <ErrorNote message={error} onRetry={() => void load()} />}
    {state === "ready" && rows.length === 0 && <div className="pg-empty"><span>暂无持仓</span></div>}
    {state === "ready" && rows.map((row) => {
      const live = prices[row.symbol];
      const current = live ?? num(row.current_price);
      const pnl = num(row.pnl);
      return <article key={row.id} className="pg-card">
        <header>
          <SideBadge side={row.side} />
          <button type="button" className="pg-symbol" onClick={() => onOpenSymbol(row.symbol)}>{row.symbol.replace(/USDT$/, "")}/USDT</button>
          <span className="pg-lev">x{row.leverage}</span>
          {row.position_origin === "exchange_external" && <span className="pg-tag">手动仓</span>}
        </header>
        <div className="pg-grid">
          <div><span>持仓盈亏</span><strong className={pnl >= 0 ? "up" : "down"}>{fmt(pnl)} U</strong></div>
          <div><span>盈亏比</span><strong className={pnl >= 0 ? "up" : "down"}>{fmt(num(row.pnl_ratio) * 100)}%</strong></div>
          <div><span>开仓价格</span><strong>{fmt(row.open_price, 4)}</strong></div>
          <div><span>当前价格</span><strong>{fmt(current, 4)}</strong></div>
          <div><span>保证金</span><strong>{fmt(row.margin)} U</strong></div>
          <div><span>持仓额</span><strong>{fmt(row.position_amount)} U</strong></div>
          <div><span>市价止损</span><strong>{row.market_stop_price ? fmt(row.market_stop_price, 4) : "未设置"}</strong></div>
          <div><span>市价止盈</span><strong>{row.manual_take_profit_price ? fmt(row.manual_take_profit_price, 4) : "未设置"}</strong></div>
        </div>
        <footer>
          <button type="button" className="pg-close-btn" onClick={() => setConfirmId(row.id)}>立即平仓</button>
        </footer>
      </article>;
    })}
    {confirmId !== null && <div className="pg-confirm-backdrop">
      <div className="pg-confirm" role="dialog" aria-modal="true">
        <header><strong>确认平仓</strong><button type="button" aria-label="关闭" onClick={() => setConfirmId(null)}><X size={15} /></button></header>
        <p>将以市价平掉该持仓，实际成交以交易所为准。确认继续？</p>
        <footer>
          <button type="button" onClick={() => setConfirmId(null)}>取消</button>
          <button type="button" className="is-danger" disabled={closing} onClick={() => void closePosition(confirmId)}>{closing ? "平仓中…" : "确认平仓"}</button>
        </footer>
      </div>
    </div>}
  </div>;
}

const HISTORY_FILTERS = [["all", "全部"], ["1d", "一天内"], ["3d", "三天"], ["1w", "一周"]] as const;

export function HistoryPage() {
  const [tab, setTab] = useState<"history" | "orders">("history");
  const [filter, setFilter] = useState<string>("all");
  const [history, setHistory] = useState<HistoryRow[]>([]);
  const [orders, setOrders] = useState<OrderRow[]>([]);
  const [page, setPage] = useState(1);
  const [hasMore, setHasMore] = useState(false);
  const [state, setState] = useState<"loading" | "ready" | "error">("loading");
  const [error, setError] = useState("");

  const load = useCallback(async (target: "history" | "orders", f: string, p: number, append: boolean, signal?: AbortSignal) => {
    setState("loading");
    try {
      if (target === "history") {
        const data = await tradeApi.history(f, p, signal);
        setHistory((prev) => append ? [...prev, ...data.items] : data.items);
        setHasMore(data.pagination.has_more);
      } else {
        const data = await tradeApi.orders(p, signal);
        setOrders((prev) => append ? [...prev, ...data.items] : data.items);
        setHasMore(data.pagination.has_more);
      }
      setPage(p);
      setState("ready");
    } catch (err) {
      if (signal?.aborted) return;
      setError(err instanceof Error ? err.message : "历史加载失败");
      setState("error");
    }
  }, []);

  useEffect(() => {
    const controller = new AbortController();
    void load(tab, filter, 1, false, controller.signal);
    return () => controller.abort();
  }, [tab, filter, load]);

  return <div className="pg-wrap">
    <header className="pg-head">
      <h2>历史</h2>
      <div className="pg-tabs">
        <button type="button" className={tab === "history" ? "active" : ""} onClick={() => setTab("history")}>历史仓位</button>
        <button type="button" className={tab === "orders" ? "active" : ""} onClick={() => setTab("orders")}>委托</button>
      </div>
    </header>
    {tab === "history" && <div className="pg-filters">
      {HISTORY_FILTERS.map(([value, label]) => <button key={value} type="button" className={filter === value ? "active" : ""} onClick={() => setFilter(value)}>{label}</button>)}
    </div>}
    {state === "error" && <ErrorNote message={error} onRetry={() => void load(tab, filter, 1, false)} />}
    {state === "loading" && page === 1 && <div className="pg-empty"><RefreshCw size={14} className="spin" /> 正在加载…</div>}
    {tab === "history" && state === "ready" && history.length === 0 && <div className="pg-empty"><span>暂无历史仓位</span></div>}
    {tab === "history" && history.map((row) => {
      const pnl = num(row.pnl);
      return <article key={row.id} className="pg-card">
        <header><SideBadge side={row.side} /><span className="pg-symbol">{row.symbol.replace(/USDT$/, "")}/USDT</span></header>
        <div className="pg-grid">
          <div><span>平仓盈亏</span><strong className={pnl >= 0 ? "up" : "down"}>{fmt(pnl)} U</strong></div>
          <div><span>盈亏比</span><strong className={pnl >= 0 ? "up" : "down"}>{fmt(num(row.pnl_ratio) * 100)}%</strong></div>
          <div><span>开仓价</span><strong>{fmt(row.open_price, 4)}</strong></div>
          <div><span>平仓价</span><strong>{fmt(row.close_price, 4)}</strong></div>
          <div><span>持仓额</span><strong>{fmt(row.position_amount)} U</strong></div>
          <div><span>手续费</span><strong>{fmt(num(row.fee) + num(row.funding_fee))} U</strong></div>
        </div>
        <footer className="pg-times"><span>开 {row.opened_at}</span><span>平 {row.closed_at}</span></footer>
      </article>;
    })}
    {tab === "orders" && state === "ready" && orders.length === 0 && <div className="pg-empty"><span>暂无委托</span></div>}
    {tab === "orders" && orders.map((row) => <article key={row.id} className="pg-card">
      <header><SideBadge side={row.side} /><span className="pg-symbol">{row.symbol.replace(/USDT$/, "")}/USDT</span><span className="pg-tag">{row.status_text}</span></header>
      <div className="pg-grid">
        <div><span>类型</span><strong>{row.kind}</strong></div>
        <div><span>杠杆</span><strong>x{row.leverage}</strong></div>
        <div><span>委托价</span><strong>{fmt(row.price, 4)}</strong></div>
        <div><span>止损价</span><strong>{row.stop_price ? fmt(row.stop_price, 4) : "—"}</strong></div>
        <div><span>委托金额</span><strong>{fmt(row.amount)} U</strong></div>
        <div><span>成交均价</span><strong>{row.avg_price ? fmt(row.avg_price, 4) : "—"}</strong></div>
      </div>
    </article>)}
    {state === "ready" && hasMore && <button type="button" className="pg-more" onClick={() => void load(tab, filter, page + 1, true)}>加载更多</button>}
  </div>;
}

export function AccountPage({ theme, onToggleTheme }: { theme: "dark" | "light"; onToggleTheme: () => void }) {
  const { logout } = useAccount();
  const [info, setInfo] = useState<AccountInfo | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [api, setApi] = useState<ApiInfo | null>(null);
  const [stopLoss, setStopLoss] = useState(120);
  const [state, setState] = useState<"loading" | "ready" | "error">("loading");
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [saving, setSaving] = useState(false);

  const load = useCallback(async (fresh: boolean, signal?: AbortSignal) => {
    try {
      const [account, prof, apiInfo] = await Promise.all([
        tradeApi.accountInfo(fresh, signal),
        tradeApi.profile(signal).catch(() => null),
        tradeApi.apiInfo(signal).catch(() => null),
      ]);
      setInfo(account);
      setProfile(prof);
      setApi(apiInfo);
      setStopLoss(num(account.stop_loss_amount) || 120);
      setState("ready");
    } catch (err) {
      if (signal?.aborted) return;
      setError(err instanceof Error ? err.message : "账户加载失败");
      setState("error");
    }
  }, []);

  useEffect(() => {
    const controller = new AbortController();
    void load(false, controller.signal);
    return () => controller.abort();
  }, [load]);

  async function saveStopLoss() {
    setSaving(true);
    setNotice("");
    try {
      await tradeApi.setStopLoss(stopLoss);
      setNotice("止损额已保存");
      await load(false);
    } catch (err) {
      setNotice(err instanceof Error ? err.message : "保存失败");
    } finally {
      setSaving(false);
    }
  }

  return <div className="pg-wrap">
    <header className="pg-head"><h2>账户</h2><button type="button" className="pg-refresh" onClick={() => void load(true)} aria-label="刷新余额"><RefreshCw size={14} /></button></header>
    {state === "loading" && <div className="pg-empty"><RefreshCw size={14} className="spin" /> 正在加载账户…</div>}
    {state === "error" && <ErrorNote message={error} onRetry={() => void load(false)} />}
    {state === "ready" && <>
      <section className="pg-card pg-balance">
        <span>合约余额 (U)</span>
        <strong>{fmt(info?.balance)}</strong>
        <div className="pg-grid">
          <div><span>今日盈亏</span><strong className={num(info?.today_pnl) >= 0 ? "up" : "down"}>{fmt(info?.today_pnl)} U</strong></div>
          <div><span>现货钱包</span><strong>{fmt(info?.spot_balance)} U</strong></div>
          <div><span>资金钱包</span><strong>{fmt(info?.funding_balance)} U</strong></div>
        </div>
      </section>
      <section className="pg-card">
        <header><strong>{profile?.display_name || profile?.username || "账户"}</strong><span className="pg-tag">{profile?.position_mode === "lead" ? "带单" : "合约"}</span></header>
        <div className="pg-grid">
          <div><span>API 绑定</span><strong>{api?.status === 1 ? `已绑定 ${api.api_key_masked}` : "未绑定"}</strong></div>
          <div><span>别名</span><strong>{api?.alias || "—"}</strong></div>
        </div>
      </section>
      <section className="pg-card">
        <header><strong>单笔止损额 (U)</strong></header>
        <input type="range" min={50} max={300} step={10} value={stopLoss} onChange={(event) => setStopLoss(Number(event.target.value))} />
        <div className="pg-row"><span>{stopLoss} U</span><button type="button" disabled={saving} onClick={() => void saveStopLoss()}>{saving ? "保存中…" : "保存"}</button></div>
      </section>
      <section className="pg-card">
        <div className="pg-row"><span>颜色模式</span><button type="button" onClick={onToggleTheme}>{theme === "dark" ? "切换浅色" : "切换深色"}</button></div>
        <div className="pg-row"><span>退出登录</span><button type="button" className="is-danger" onClick={() => { void logout().catch(() => undefined).finally(() => window.location.reload()); }}>退出</button></div>
      </section>
      {notice && <div className="pg-notice">{notice}</div>}
    </>}
  </div>;
}