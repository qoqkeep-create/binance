import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Settings2, X } from "lucide-react";
import { tradeApi, type AccountInfo } from "./lib/tradeApi";

const FEE_RATE = 0.001;
const MAKER_KEYS = {
  market: "integrated.chart.order-settings.market-entry-maker",
  limit: "integrated.chart.order-settings.limit-entry-maker",
  takeProfit: "integrated.chart.order-settings.take-profit-maker",
} as const;

interface StrategyRow { id: string; name: string; is_active: boolean; levels: unknown[] }
interface MakerPrefs { market: boolean; limit: boolean; takeProfit: boolean }

function readMakerPrefs(): MakerPrefs {
  const read = (key: string, fallback: boolean) => {
    try { const raw = localStorage.getItem(key); return raw === null ? fallback : raw === "true"; } catch { return fallback; }
  };
  return { market: read(MAKER_KEYS.market, false), limit: read(MAKER_KEYS.limit, true), takeProfit: read(MAKER_KEYS.takeProfit, false) };
}

function num(value: number | string | null | undefined) {
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}
function fmt(value: number, digits = 2) {
  return value.toLocaleString("zh-CN", { minimumFractionDigits: digits, maximumFractionDigits: digits });
}

export default function TradePanel({ symbol, price, canTrade }: { symbol: string; price: number | undefined; canTrade: boolean }) {
  const [account, setAccount] = useState<AccountInfo | null>(null);
  const [strategy, setStrategy] = useState<StrategyRow | null>(null);
  const [strategyState, setStrategyState] = useState<"loading" | "ready" | "error">("loading");
  const [risk, setRisk] = useState(120);
  const [stopInput, setStopInput] = useState("");
  const [orderType, setOrderType] = useState<"market" | "limit">("market");
  const [limitInput, setLimitInput] = useState("");
  const [maker, setMaker] = useState<MakerPrefs>(readMakerPrefs);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [adjusting, setAdjusting] = useState(false);
  const [draftRisk, setDraftRisk] = useState(120);
  const [savingRisk, setSavingRisk] = useState(false);
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [notice, setNotice] = useState("");
  const attemptKeyRef = useRef<string | null>(null);

  const load = useCallback(async (signal?: AbortSignal) => {
    setStrategyState("loading");
    try {
      const [info, strategies] = await Promise.all([
        tradeApi.accountInfo(false, signal),
        tradeApi.strategyList(signal),
      ]);
      setAccount(info);
      setRisk(num(info.stop_loss_amount) || 120);
      setStrategy(strategies.find((row) => row.is_active) ?? null);
      setStrategyState("ready");
    } catch {
      if (!signal?.aborted) setStrategyState("error");
    }
  }, []);

  useEffect(() => {
    const controller = new AbortController();
    void load(controller.signal);
    return () => controller.abort();
  }, [load, symbol]);

  function setMakerPref(key: keyof MakerPrefs, value: boolean) {
    setMaker((current) => ({ ...current, [key]: value }));
    try { localStorage.setItem(MAKER_KEYS[key], String(value)); } catch { /* keep session value */ }
  }

  const stop = Number(stopInput);
  const limit = Number(limitInput);
  const entry = price ?? 0;
  const baseValid = entry > 0 && Number.isFinite(stop) && stop > 0 && stop !== entry && risk > 0;
  const limitValid = orderType === "limit" ? Number.isFinite(limit) && limit > 0 && limit !== entry : true;
  const valid = baseValid && limitValid;
  const isLong = stop < entry;
  const ratio = valid ? Math.abs(entry - stop) / entry : 0;
  const notional = valid ? risk / (ratio + FEE_RATE) : 0;
  const fee = notional * FEE_RATE;

  const payload = useMemo(() => ({
    symbol: symbol.toUpperCase(),
    stop_loss_price: stopInput.trim(),
    stop_loss_amount: String(risk),
    ...(orderType === "market"
      ? { include_fee: true, ...(maker.market ? { execution_mode: "maker" } : {}) }
      : { limit_price: limitInput.trim() }),
    ...(strategy ? { strategy_id: strategy.id, strategy_name: strategy.name, strategy_config: strategy.levels } : {}),
  }), [symbol, stopInput, risk, strategy, orderType, limitInput, maker.market]);

  async function saveRisk() {
    setSavingRisk(true);
    setNotice("");
    try {
      await tradeApi.setStopLoss(draftRisk);
      setRisk(draftRisk);
      setAdjusting(false);
      setNotice("止损金额已保存");
    } catch (err) {
      setNotice(err instanceof Error ? err.message : "止损金额保存失败");
    } finally {
      setSavingRisk(false);
    }
  }

  async function submitOpen() {
    setSubmitting(true);
    setNotice("");
    if (!attemptKeyRef.current) {
      attemptKeyRef.current = `web-${orderType}-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
    }
    try {
      const id = await tradeApi.submitCommand(orderType === "market" ? "open" : "limit-create", payload, attemptKeyRef.current);
      const result = await tradeApi.pollCommand(id);
      if (result.status === "SUCCEEDED") {
        setNotice(orderType === "market" ? "开仓命令已确认，保护单由服务端跟进" : "限价挂单已确认，可在持仓页委托中查看");
        setConfirmOpen(false);
        attemptKeyRef.current = null;
      } else if (result.status === "FAILED") {
        setNotice(`${orderType === "market" ? "开仓" : "挂单"}失败：${result.result?.message ?? "请重试"}`);
      } else {
        setNotice("结果待确认，请勿重复提交，可在持仓页核对");
        setConfirmOpen(false);
      }
    } catch (err) {
      setNotice(err instanceof Error ? err.message : "请求失败");
    } finally {
      setSubmitting(false);
    }
  }

  const blocked = !canTrade ? "游客模式仅浏览，登录后可编辑交易" : strategyState === "ready" && !strategy ? "尚未启用止盈策略，请先在账户页启用" : "";

  return <div className="trade-panel">
    {notice && <div className="pg-notice">{notice}</div>}
    {blocked && <div className="trade-hint">{blocked}</div>}
    <div className="trade-type-row" role="group" aria-label="开仓方式">
      <button type="button" className={orderType === "market" ? "active" : ""} onClick={() => { setOrderType("market"); attemptKeyRef.current = null; }}>市价开仓</button>
      <button type="button" className={orderType === "limit" ? "active" : ""} onClick={() => { setOrderType("limit"); attemptKeyRef.current = null; }}>限价挂单</button>
    </div>
    <div className="trade-side-row">
      {valid && <span className={`trade-side ${isLong ? "long" : "short"}`}>{isLong ? "开多" : "开空"}</span>}
      <small>止损价低于现价为多，高于现价为空</small>
    </div>
    <div className="pg-grid trade-grid">
      <div><span>当前价格</span><strong>{price === undefined ? "—" : fmt(price, 4)}</strong></div>
      <div><span>预估仓位</span><strong>{valid ? `${fmt(notional)} U` : "—"}</strong></div>
      <div><span>预估手续费</span><strong>{valid ? `${fmt(fee)} U` : "—"}</strong></div>
      <div><span>止损回撤</span><strong>{valid ? `${fmt(ratio * 100)}%` : "—"}</strong></div>
    </div>
    {orderType === "limit" && <label className="trade-field">
      <span>限价</span>
      <input value={limitInput} inputMode="decimal" placeholder="输入挂单价格" onChange={(event) => { setLimitInput(event.target.value.replace(/[^\d.]/g, "")); attemptKeyRef.current = null; }} />
    </label>}
    <label className="trade-field">
      <span>止损价</span>
      <input value={stopInput} inputMode="decimal" placeholder="输入止损价" onChange={(event) => { setStopInput(event.target.value.replace(/[^\d.]/g, "")); attemptKeyRef.current = null; }} />
    </label>
    <div className="trade-field">
      <span>止损金额</span>
      <button type="button" className="trade-risk-btn" onClick={() => { setDraftRisk(risk); setAdjusting((open) => !open); }}>{risk} U</button>
    </div>
    {adjusting && <div className="trade-risk-adjust">
      <input type="range" min={50} max={300} step={1} value={draftRisk} onChange={(event) => setDraftRisk(Number(event.target.value))} />
      <div className="pg-row"><span>{draftRisk} U</span><span><button type="button" disabled={savingRisk} onClick={() => void saveRisk()}>{savingRisk ? "保存中…" : "保存"}</button><button type="button" onClick={() => setAdjusting(false)}>取消</button></span></div>
    </div>}
    <div className="trade-strategy">
      <span>止盈策略</span>
      <strong>{strategyState === "loading" ? "读取中…" : strategyState === "error" ? "读取失败" : strategy?.name ?? "未启用"}</strong>
      {strategyState === "error" && <button type="button" onClick={() => void load()}>重试</button>}
    </div>
    <button type="button" className="trade-settings-btn" onClick={() => setSettingsOpen((open) => !open)} aria-expanded={settingsOpen}><Settings2 size={13} /> 开仓设置</button>
    {settingsOpen && <div className="trade-settings">
      <label className="trade-maker-row"><span>市价开仓用 Maker</span><input type="checkbox" checked={maker.market} onChange={(event) => setMakerPref("market", event.target.checked)} /></label>
      <label className="trade-maker-row"><span>限价开仓用 Maker</span><input type="checkbox" checked={maker.limit} onChange={(event) => setMakerPref("limit", event.target.checked)} /></label>
      <label className="trade-maker-row"><span>预挂止盈用 Maker</span><input type="checkbox" checked={maker.takeProfit} onChange={(event) => setMakerPref("takeProfit", event.target.checked)} /></label>
      <div className="trade-maker-row is-fixed"><span>止损</span><strong>触发后市价</strong></div>
    </div>}
    <button type="button" className="trade-submit" disabled={!valid || !strategy || !canTrade || submitting} onClick={() => { setNotice(""); setConfirmOpen(true); }}>
      {submitting ? "提交中…" : orderType === "market" ? (valid ? (isLong ? "市价开多" : "市价开空") : "市价开仓") : (valid ? (isLong ? "限价挂多" : "限价挂空") : "限价挂单")}
    </button>
    {confirmOpen && <div className="pg-confirm-backdrop">
      <div className="pg-confirm" role="dialog" aria-modal="true">
        <header><strong>确认{orderType === "market" ? "开仓" : "挂单"}</strong><button type="button" aria-label="关闭" onClick={() => setConfirmOpen(false)}><X size={15} /></button></header>
        <p>{symbol.replace(/USDT$/, "")}/USDT {isLong ? "开多" : "开空"}{orderType === "limit" ? `，限价 ${limitInput}` : ""}，预估仓位 {fmt(notional)} U，手续费约 {fmt(fee)} U；止损价 {stopInput}，止损金额 {risk} U（回撤 {fmt(ratio * 100)}%），止盈策略「{strategy?.name}」。实际成交与数量以交易所为准，确认继续？</p>
        <footer>
          <button type="button" onClick={() => setConfirmOpen(false)}>取消</button>
          <button type="button" className={isLong ? "is-long" : "is-danger"} disabled={submitting} onClick={() => void submitOpen()}>{submitting ? "提交中…" : "确认"}</button>
        </footer>
      </div>
    </div>}
  </div>;
}