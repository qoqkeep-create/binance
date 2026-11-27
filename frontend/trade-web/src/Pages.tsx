import { useCallback, useEffect, useState } from "react";
import { RefreshCw, ShieldAlert, X } from "lucide-react";
import { useAccount } from "./AccountProvider";
import { tradeApi, isLongSide, type PositionRow, type PositionStrategyLevel, type MarginInfo, type HistoryRow, type OrderRow, type AccountInfo, type Profile, type ApiInfo } from "./lib/tradeApi";

const num = (value: number | string | null | undefined) => {
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
};
const fmt = (value: number | string | null | undefined, digits = 2) => num(value).toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits });
interface StrategyLevel { profitRR: number; reducePosition: number; stopLossType: "none" | "fixedRR" | "absoluteRR"; stopLossRR: number; stopLossAbsoluteRR: number }
const emptyLevel = (): StrategyLevel => ({ profitRR: 1, reducePosition: 50, stopLossType: "none", stopLossRR: 1, stopLossAbsoluteRR: 1 });
function SideBadge({ side }: { side: number | string }) {
  return <span className={`pg-side ${isLongSide(side) ? "is-long" : "is-short"}`}>{isLongSide(side) ? "多" : "空"}</span>;
}

function ErrorNote({ message, onRetry }: { message: string; onRetry: () => void }) {
  return <div className="pg-empty"><span>{message}</span><button type="button" onClick={onRetry}>重试</button></div>;
}

function TpLevels({ levels }: { levels: PositionStrategyLevel[] }) {
  return <div className="pg-tp-levels">{levels.map((level, index) => <div key={index} className="pg-tp-level">
    <span>L{index + 1}</span>
    <strong>止盈 RR {level.profitRR}</strong>
    <span>减仓 {level.reducePosition}%</span>
    <span>{level.stopLossType === "none" ? "止损不动" : level.stopLossType === "fixedRR" ? `止损固定RR ${level.stopLossRR}` : `止损绝对RR ${level.stopLossAbsoluteRR}`}</span>
  </div>)}</div>;
}

export function PositionsPage({ onOpenSymbol, prices }: { onOpenSymbol: (symbol: string) => void; prices: Record<string, number> }) {
  const [rows, setRows] = useState<PositionRow[]>([]);
  const [margin, setMargin] = useState<MarginInfo | null>(null);
  const [state, setState] = useState<"loading" | "ready" | "error">("loading");
  const [error, setError] = useState("");
  const [confirmId, setConfirmId] = useState<number | null>(null);
  const [closing, setClosing] = useState(false);
  const [notice, setNotice] = useState("");
  const [tpRow, setTpRow] = useState<PositionRow | null>(null);
  const [marginOpen, setMarginOpen] = useState(false);
  const [activeStrategy, setActiveStrategy] = useState<{ name: string; levels: PositionStrategyLevel[] } | null>(null);

  const load = useCallback(async (signal?: AbortSignal) => {
    try {
      const [list, marginInfo, strategies] = await Promise.all([
        tradeApi.positions(signal),
        tradeApi.margin(signal).catch(() => null),
        tradeApi.strategyList(signal).catch(() => []),
      ]);
      setRows(list);
      setMargin(marginInfo);
      const active = strategies.find((row) => row.is_active);
      setActiveStrategy(active ? { name: active.name, levels: active.levels as PositionStrategyLevel[] } : null);
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
      {margin && <button type="button" className={`pg-margin ${ratio >= 80 ? "is-danger" : ratio >= 50 ? "is-warn" : ""}`} onClick={() => setMarginOpen(true)} aria-label="查看保证金详情"><ShieldAlert size={13} /> 保证金率 {fmt(ratio)}%</button>}
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
          <button type="button" className={`pg-tp-btn ${row.strategy_status === 1 ? "is-running" : ""}`} onClick={() => setTpRow(row)}>
            {row.strategy_status === 1 ? "自动止盈中" : "自动止盈"}
          </button>
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
    {tpRow && <div className="pg-confirm-backdrop">
      <div className="pg-confirm" role="dialog" aria-modal="true">
        <header><strong>自动止盈策略</strong><button type="button" aria-label="关闭" onClick={() => setTpRow(null)}><X size={15} /></button></header>
        {tpRow.strategy_config?.length ? <>
          <p className="pg-tp-name">{tpRow.strategy_name || "自动止盈"}{tpRow.strategy_status === 1 ? "（运行中）" : tpRow.strategy_status === 2 ? "（已取消）" : ""}</p>
          <TpLevels levels={tpRow.strategy_config} />
        </> : <>
          <p>该持仓未绑定自动止盈策略。</p>
          {activeStrategy ? <>
            <p className="pg-tp-name">当前启用：{activeStrategy.name}</p>
            <TpLevels levels={activeStrategy.levels} />
          </> : <p>账户尚未启用止盈策略，可在账户页新建并启用。</p>}
        </>}
        <footer><button type="button" onClick={() => setTpRow(null)}>关闭</button></footer>
      </div>
    </div>}
    {marginOpen && margin && <div className="pg-confirm-backdrop">
      <div className="pg-confirm" role="dialog" aria-modal="true">
        <header><strong>保证金详情</strong><button type="button" aria-label="关闭" onClick={() => setMarginOpen(false)}><X size={15} /></button></header>
        <div className="pg-grid">
          <div><span>保证金率</span><strong className={num(margin.margin_ratio_percent) >= 80 ? "down" : num(margin.margin_ratio_percent) >= 50 ? "" : "up"}>{fmt(num(margin.margin_ratio_percent))}%</strong></div>
          <div><span>钱包余额</span><strong>{fmt(num(margin.wallet_balance))} U</strong></div>
          <div><span>保证金余额</span><strong>{fmt(num(margin.margin_balance))} U</strong></div>
          <div><span>可用余额</span><strong>{fmt(num(margin.available_balance))} U</strong></div>
        </div>
        {margin.liquidation_reached && <p className="pg-tp-name">已触及强平警示线，请尽快减仓或追加保证金。</p>}
        <footer><button type="button" onClick={() => setMarginOpen(false)}>关闭</button></footer>
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

export function AccountPage({ focus }: { focus?: { kind: "stop-loss" | "strategy"; at: number } | null }) {
  const { logout } = useAccount();
  const [info, setInfo] = useState<AccountInfo | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [api, setApi] = useState<ApiInfo | null>(null);
  const [stopLoss, setStopLoss] = useState(120);
  const [state, setState] = useState<"loading" | "ready" | "error">("loading");
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [saving, setSaving] = useState(false);
  const [strategies, setStrategies] = useState<Array<{ id: string; name: string; is_active: boolean; levels: StrategyLevel[] }>>([]);
  const [editing, setEditing] = useState<{ id?: string; name: string; levels: StrategyLevel[] } | null>(null);
  const [bindOpen, setBindOpen] = useState(false);
  const [bindForm, setBindForm] = useState({ alias: "", api_key: "", secret_key: "" });
  const [confirmUnbind, setConfirmUnbind] = useState(false);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async (fresh: boolean, signal?: AbortSignal) => {
    try {
      const [account, prof, apiInfo, strat] = await Promise.all([
        tradeApi.accountInfo(fresh, signal),
        tradeApi.profile(signal).catch(() => null),
        tradeApi.apiInfo(signal).catch(() => null),
        tradeApi.strategyList(signal).catch(() => []),
      ]);
      setInfo(account);
      setProfile(prof);
      setApi(apiInfo);
      setStrategies(strat as Array<{ id: string; name: string; is_active: boolean; levels: StrategyLevel[] }>);
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

  useEffect(() => {
    if (!focus || state !== "ready") return;
    const frame = requestAnimationFrame(() => {
      document.getElementById(focus.kind === "stop-loss" ? "account-stop-loss" : "account-strategy")?.scrollIntoView({ behavior: "smooth", block: "center" });
    });
    return () => cancelAnimationFrame(frame);
  }, [focus, state]);

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

  async function runBusy(fn: () => Promise<unknown>, ok: string) {
    setBusy(true);
    setNotice("");
    try {
      await fn();
      setNotice(ok);
      await load(false);
    } catch (err) {
      setNotice(err instanceof Error ? err.message : "操作失败");
    } finally {
      setBusy(false);
    }
  }

  async function saveStrategy() {
    if (!editing) return;
    const levels = editing.levels;
    const sum = levels.reduce((acc, l) => acc + l.reducePosition, 0);
    if (!editing.name.trim()) { setNotice("策略名称不能为空"); return; }
    if (!levels.length || sum > 100) { setNotice("至少一档且减仓比例合计不超过 100%"); return; }
    for (let i = 1; i < levels.length; i++) if (levels[i].profitRR <= levels[i - 1].profitRR) { setNotice("止盈 RR 需严格递增"); return; }
    await runBusy(() => tradeApi.strategySave({ strategy_id: editing.id, name: editing.name.trim(), levels }), "策略已保存");
    setEditing(null);
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
        {api?.status === 1 ? (
          <div className="pg-row"><span>解除绑定将停止实盘交易能力</span><button type="button" className="is-danger" disabled={busy} onClick={() => setConfirmUnbind(true)}>解除绑定</button></div>
        ) : (
          <div className="pg-row"><span>绑定 Binance Futures 实盘 API 后可交易</span><button type="button" disabled={busy} onClick={() => setBindOpen((open) => !open)}>{bindOpen ? "收起" : "绑定 API"}</button></div>
        )}
        {bindOpen && api?.status !== 1 && <div className="pg-bind-form">
          <label className="trade-field"><span>API 别名</span><input value={bindForm.alias} onChange={(e) => setBindForm((f) => ({ ...f, alias: e.target.value }))} placeholder="如 主账户" /></label>
          <label className="trade-field"><span>API Key</span><input value={bindForm.api_key} onChange={(e) => setBindForm((f) => ({ ...f, api_key: e.target.value.trim() }))} placeholder="Binance API Key" /></label>
          <label className="trade-field"><span>Secret Key</span><input type="password" value={bindForm.secret_key} onChange={(e) => setBindForm((f) => ({ ...f, secret_key: e.target.value.trim() }))} placeholder="Binance Secret Key" /></label>
          <div className="pg-row"><span>服务端将校验权限与 IP 白名单</span><button type="button" disabled={busy || !bindForm.api_key || !bindForm.secret_key} onClick={() => void runBusy(() => tradeApi.apiBind(bindForm), "绑定成功").then(() => setBindOpen(false))}>{busy ? "绑定中…" : "确认绑定"}</button></div>
        </div>}
      </section>
      <section className="pg-card" id="account-strategy">
        <header><strong>止盈止损策略</strong><button type="button" disabled={busy} onClick={() => setEditing({ name: "", levels: [emptyLevel()] })}>新建</button></header>
        {strategies.length === 0 && <div className="pg-empty"><span>暂无策略</span></div>}
        {strategies.map((s) => <div key={s.id} className="pg-strategy-row">
          <span className="pg-strategy-name">{s.name}{s.is_active && <em className="pg-tag is-active">启用中</em>}</span>
          <span className="pg-strategy-actions">
            {!s.is_active && <button type="button" disabled={busy} onClick={() => void runBusy(() => tradeApi.strategySetActive(s.id), "已启用")}>启用</button>}
            <button type="button" disabled={busy} onClick={() => setEditing({ id: s.id, name: s.name, levels: s.levels?.length ? s.levels : [emptyLevel()] })}>编辑</button>
            <button type="button" className="is-danger" disabled={busy} onClick={() => void runBusy(() => tradeApi.strategyDelete(s.id), "已删除")}>删除</button>
          </span>
        </div>)}
        {editing && <div className="pg-strategy-editor">
          <label className="trade-field"><span>策略名称</span><input value={editing.name} onChange={(e) => setEditing((cur) => cur && { ...cur, name: e.target.value })} /></label>
          {editing.levels.map((level, index) => <div key={index} className="pg-level-row">
            <label><span>止盈RR</span><input type="number" step="0.1" value={level.profitRR} onChange={(e) => setEditing((cur) => cur && { ...cur, levels: cur.levels.map((l, i) => i === index ? { ...l, profitRR: Number(e.target.value) } : l) })} /></label>
            <label><span>减仓%</span><input type="number" step="5" value={level.reducePosition} onChange={(e) => setEditing((cur) => cur && { ...cur, levels: cur.levels.map((l, i) => i === index ? { ...l, reducePosition: Number(e.target.value) } : l) })} /></label>
            <label><span>止损类型</span><select value={level.stopLossType} onChange={(e) => setEditing((cur) => cur && { ...cur, levels: cur.levels.map((l, i) => i === index ? { ...l, stopLossType: e.target.value as StrategyLevel["stopLossType"] } : l) })}><option value="none">不动</option><option value="fixedRR">固定RR</option><option value="absoluteRR">绝对RR</option></select></label>
            {level.stopLossType !== "none" && <label><span>止损RR</span><input type="number" step="0.1" value={level.stopLossType === "fixedRR" ? level.stopLossRR : level.stopLossAbsoluteRR} onChange={(e) => setEditing((cur) => cur && { ...cur, levels: cur.levels.map((l, i) => i === index ? (l.stopLossType === "fixedRR" ? { ...l, stopLossRR: Number(e.target.value) } : { ...l, stopLossAbsoluteRR: Number(e.target.value) }) : l) })} /></label>}
            <button type="button" className="is-danger" onClick={() => setEditing((cur) => cur && { ...cur, levels: cur.levels.filter((_, i) => i !== index) })}>删</button>
          </div>)}
          <div className="pg-row">
            <button type="button" disabled={editing.levels.length >= 5} onClick={() => setEditing((cur) => cur && { ...cur, levels: [...cur.levels, emptyLevel()] })}>加档</button>
            <span><button type="button" disabled={busy} onClick={() => void saveStrategy()}>{busy ? "保存中…" : "保存策略"}</button><button type="button" onClick={() => setEditing(null)}>取消</button></span>
          </div>
        </div>}
      </section>
      <section className="pg-card" id="account-stop-loss">
        <header><strong>单笔止损额 (U)</strong></header>
        <input type="range" min={50} max={300} step={1} value={stopLoss} onChange={(event) => setStopLoss(Number(event.target.value))} />
        <div className="pg-row"><span>{stopLoss} U</span><button type="button" disabled={saving} onClick={() => void saveStopLoss()}>{saving ? "保存中…" : "保存"}</button></div>
      </section>
      <section className="pg-card">
        <div className="pg-row"><span>退出登录</span><button type="button" className="is-danger" onClick={() => { void logout().catch(() => undefined).finally(() => window.location.reload()); }}>退出</button></div>
      </section>
      {confirmUnbind && <div className="pg-confirm-backdrop">
        <div className="pg-confirm" role="dialog" aria-modal="true">
          <header><strong>解除绑定</strong><button type="button" aria-label="关闭" onClick={() => setConfirmUnbind(false)}><X size={15} /></button></header>
          <p>解除后实盘开平仓/保护单能力停止；如有持仓或待成交委托将被服务端拒绝。确认解除？</p>
          <footer>
            <button type="button" onClick={() => setConfirmUnbind(false)}>取消</button>
            <button type="button" className="is-danger" disabled={busy} onClick={() => void runBusy(() => tradeApi.apiUnbind(), "已解除绑定").then(() => setConfirmUnbind(false))}>{busy ? "解除中…" : "确认解除"}</button>
          </footer>
        </div>
      </div>}
      {notice && <div className="pg-notice">{notice}</div>}
    </>}
  </div>;
}