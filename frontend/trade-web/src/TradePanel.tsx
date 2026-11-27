import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { ChevronRight, ClipboardPaste, Settings2, X } from "lucide-react";
import { tradeApi, type AccountInfo } from "./lib/tradeApi";
import { getCopiedPrice } from "./lib/priceClipboard";

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

export default function TradePanel({ symbol, price, visible, onNavigate, stopPriceRequest }: {
  symbol: string; price: number | undefined; visible: boolean;
  onNavigate: (target: "stop-loss" | "strategy") => void;
  stopPriceRequest?: { value: string; at: number } | null;
}) {
  const [account, setAccount] = useState<AccountInfo | null>(null);
  const [strategy, setStrategy] = useState<StrategyRow | null>(null);
  const [strategyState, setStrategyState] = useState<"loading" | "ready" | "error">("loading");
  const [risk, setRisk] = useState(120);
  const [stopInput, setStopInput] = useState("");
  const [orderType, setOrderType] = useState<"market" | "limit">("market");
  const [limitInput, setLimitInput] = useState("");
  const [maker, setMaker] = useState<MakerPrefs>(readMakerPrefs);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [submitting, setSubmitting] = useState(false);
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
    if (!visible) return;
    const controller = new AbortController();
    void load(controller.signal);
    return () => controller.abort();
  }, [load, symbol, visible]);
  useEffect(() => {
    if (!stopPriceRequest) return;
    setStopInput(stopPriceRequest.value);
    attemptKeyRef.current = null;
  }, [stopPriceRequest]);

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

  async function submitOpen() {
    setSubmitting(true);
    if (!attemptKeyRef.current) {
      attemptKeyRef.current = `web-${orderType}-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
    }
    try {
      const id = await tradeApi.submitCommand(orderType === "market" ? "open" : "limit-create", payload, attemptKeyRef.current);
      const result = await tradeApi.pollCommand(id);
      if (result.status === "SUCCEEDED") {
        setConfirmOpen(false);
        attemptKeyRef.current = null;
      } else if (result.status === "FAILED") {
      } else {
        setConfirmOpen(false);
      }
    } catch (err) {
    } finally {
      setSubmitting(false);
    }
  }

  const blocked = strategyState === "ready" && !strategy ? "尚未启用止盈策略，请先在账户页启用" : "";

  return <div className="trade-panel">
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
      <span className="trade-input-wrap">
        <input value={stopInput} inputMode="decimal" placeholder="输入止损价" onChange={(event) => { setStopInput(event.target.value.replace(/[^\d.]/g, "")); attemptKeyRef.current = null; }} />
        <button type="button" className="trade-paste-icon" title="粘贴" aria-label="粘贴止损价" onClick={() => { const v = getCopiedPrice(); if (v !== null) { setStopInput(v); attemptKeyRef.current = null; } }}><ClipboardPaste size={13} aria-hidden="true" /></button>
      </span>
    </label>
    <div className="trade-field">
      <span>止损金额</span>
      <button type="button" className="trade-risk-box" onClick={() => onNavigate("stop-loss")} aria-label="设置止损金额">
        <span>{risk} U</span><ChevronRight size={13} aria-hidden="true" />
      </button>
    </div>
    <div className="trade-strategy">
      <span>止盈策略</span>
      <button type="button" className="trade-strategy-link" onClick={() => onNavigate("strategy")}>
        <strong>{strategyState === "loading" ? "读取中…" : strategyState === "error" ? "读取失败" : strategy?.name ?? "未启用"}</strong>
        <ChevronRight size={13} aria-hidden="true" />
      </button>
      {strategyState === "error" && <button type="button" onClick={() => void load()}>重试</button>}
    </div>
    <button type="button" className="trade-submit" disabled={!valid || !strategy || submitting} onClick={() => setConfirmOpen(true)}>
      {submitting ? "提交中…" : stopInput.trim() === "" ? "输入止损价" : orderType === "market" ? (isLong ? "市价开多" : "市价开空") : (isLong ? "限价挂多" : "限价挂空")}
    </button>
    <button type="button" className="trade-settings-btn" onClick={() => setSettingsOpen((open) => !open)} aria-expanded={settingsOpen}><Settings2 size={13} /> 开仓设置</button>
    {settingsOpen && <div className="trade-settings">
      <label className="trade-maker-row"><span>市价开仓用 Maker</span><input type="checkbox" checked={maker.market} onChange={(event) => setMakerPref("market", event.target.checked)} /></label>
      <label className="trade-maker-row"><span>限价开仓用 Maker</span><input type="checkbox" checked={maker.limit} onChange={(event) => setMakerPref("limit", event.target.checked)} /></label>
      <label className="trade-maker-row"><span>预挂止盈用 Maker</span><input type="checkbox" checked={maker.takeProfit} onChange={(event) => setMakerPref("takeProfit", event.target.checked)} /></label>
      <div className="trade-maker-row is-fixed"><span>止损</span><strong>触发后市价</strong></div>
    </div>}
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