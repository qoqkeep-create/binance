import { useCallback, useEffect, useState } from "react";
import { ChevronRight, X } from "lucide-react";
import { tradeApi } from "./lib/tradeApi";

export interface StopLossState {
  current_amount: string;
  pending_amount: string | null;
  pending_from_amount: string | null;
  pending_effective_at: string | null;
  countdown_seconds: number;
  minimum_amount: string;
  maximum_amount: string;
}

const money = (value: string | number | null | undefined) => Number(value ?? 0).toLocaleString("zh-CN", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

export function StopLossDialog({ open, onClose, onSaved }: { open: boolean; onClose: () => void; onSaved?: () => void }) {
  const [state, setState] = useState<StopLossState | null>(null);
  const [amount, setAmount] = useState(120);
  const [saving, setSaving] = useState(false);
  const [notice, setNotice] = useState("");
  const [completed, setCompleted] = useState<{ from: string; to: string } | null>(null);
  const [countdown, setCountdown] = useState(0);

  const load = useCallback(async () => {
    try {
      const next = await tradeApi.getStopLoss();
      setState(next);
      setAmount(Number(next.current_amount));
      setCountdown(next.countdown_seconds);
    } catch (err) {
      setNotice(err instanceof Error ? err.message : "读取止损失败");
    }
  }, []);

  useEffect(() => {
    if (!open) return;
    setNotice("");
    setCompleted(null);
    void load();
  }, [open, load]);

  useEffect(() => {
    if (!open || countdown <= 0) return;
    const timer = window.setInterval(() => setCountdown((s) => Math.max(0, s - 1)), 1000);
    return () => window.clearInterval(timer);
  }, [open, countdown > 0]);

  if (!open) return null;
  const current = Number(state?.current_amount ?? 0);
  const minimum = Number(state?.minimum_amount ?? 50);
  const maximum = Number(state?.maximum_amount ?? 300);

  async function submit() {
    setSaving(true);
    setNotice("");
    try {
      await tradeApi.setStopLoss(amount);
      setCompleted({ from: state?.current_amount ?? String(amount), to: String(amount) });
      await load();
      onSaved?.();
    } catch (err) {
      setNotice(err instanceof Error ? err.message : "保存失败");
    } finally {
      setSaving(false);
    }
  }

  async function cancelPending() {
    setSaving(true);
    setNotice("");
    try {
      await tradeApi.cancelStopLoss();
      await load();
      onSaved?.();
    } catch (err) {
      setNotice(err instanceof Error ? err.message : "取消失败");
    } finally {
      setSaving(false);
    }
  }

  return <div className="pg-confirm-backdrop" onClick={onClose}>
    <div className="pg-confirm acct-dialog" role="dialog" aria-modal="true" aria-label="单笔止损金额设定" onClick={(event) => event.stopPropagation()}>
      <header><strong>单笔止损金额</strong><button type="button" aria-label="关闭" onClick={onClose}><X size={15} /></button></header>
      <div className="acct-dialog-range-head"><span>单笔止损金额</span><span>{minimum}～{maximum} USDT</span></div>
      <div className="acct-amount-box">
        <strong>{money(amount)} USDT</strong>
        {state && amount === current && <span className="acct-current-chip">当前</span>}
      </div>
      <input type="range" min={minimum} max={maximum} step={1} value={amount} disabled={saving || !state} onChange={(event) => setAmount(Number(event.target.value))} aria-label="单笔止损金额" />
      <div className="acct-dialog-range-head"><span>{minimum} USDT</span><span>{maximum} USDT</span></div>
      <p className="acct-muted">当前止损额：{money(state?.current_amount)} USDT</p>
      <div className="acct-notes">
        <span>1. 止损金额固定在 {minimum}～{maximum} USDT 之间设置</span>
        <span>2. 设置金额不根据账户余额计算，也不随余额变动</span>
        <span>3. 确认后止损额立即生效（测试阶段暂不启用调高冷却）</span>
      </div>
      {state?.pending_amount && <div className="acct-pending">
        <span>您已调整止损金额{money(state.pending_from_amount)} → {money(state.pending_amount)}，{countdown}s 后生效</span>
        <button type="button" disabled={saving} onClick={() => void cancelPending()}>取消</button>
      </div>}
      {completed && <div className="acct-completed">
        <span>您已调整止损金额{money(completed.from)} → {money(completed.to)}。</span>
        <button type="button" onClick={() => setCompleted(null)}>知道了</button>
      </div>}
      {notice && <p className="acct-notice">{notice}</p>}
      <footer><button type="button" className="trade-submit is-long" disabled={saving || !state || amount === current} onClick={() => void submit()}>{saving ? "提交中…" : "确定"}</button></footer>
    </div>
  </div>;
}

export interface StrategyRow { id: string; name: string; is_active: boolean; levels: unknown[] }

export function StrategyDialog({ open, onClose, onCreate, onEdit }: { open: boolean; onClose: () => void; onCreate: () => void; onEdit?: (row: StrategyRow) => void }) {
  const [rows, setRows] = useState<StrategyRow[]>([]);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState("");

  const load = useCallback(async () => {
    try {
      setRows(await tradeApi.strategyList());
    } catch (err) {
      setNotice(err instanceof Error ? err.message : "读取策略失败");
    }
  }, []);

  useEffect(() => {
    if (!open) return;
    setNotice("");
    void load();
  }, [open, load]);

  if (!open) return null;

  async function activate(row: StrategyRow) {
    setBusy(true);
    setNotice("");
    try {
      await tradeApi.strategySetActive(row.id);
      await load();
    } catch (err) {
      setNotice(err instanceof Error ? err.message : "启用失败");
    } finally {
      setBusy(false);
    }
  }

  async function remove(row: StrategyRow) {
    setBusy(true);
    setNotice("");
    try {
      await tradeApi.strategyDelete(row.id);
      await load();
    } catch (err) {
      setNotice(err instanceof Error ? err.message : "删除失败");
    } finally {
      setBusy(false);
    }
  }

  return <div className="pg-confirm-backdrop" onClick={onClose}>
    <div className="pg-confirm acct-dialog" role="dialog" aria-modal="true" aria-label="止盈策略" onClick={(event) => event.stopPropagation()}>
      <header><strong>止盈策略</strong><button type="button" aria-label="关闭" onClick={onClose}><X size={15} /></button></header>
      <div className="acct-strategy-list">
        {rows.length === 0 && <p className="acct-muted">暂无策略，点击下方新建。</p>}
        {rows.map((row) => <div key={row.id} className="acct-strategy-row">
          <span className="acct-strategy-name">{row.name}{row.is_active && <em className="acct-current-chip">启用中</em>}</span>
          <span className="acct-strategy-actions">
            {!row.is_active && <button type="button" disabled={busy} onClick={() => void activate(row)}>启用</button>}
            {onEdit && <button type="button" disabled={busy} onClick={() => onEdit(row)}>编辑</button>}
            <button type="button" className="is-danger" disabled={busy} onClick={() => void remove(row)}>删除</button>
          </span>
        </div>)}
      </div>
      {notice && <p className="acct-notice">{notice}</p>}
      <footer><button type="button" className="trade-submit is-long" onClick={onCreate}>新建策略</button></footer>
    </div>
  </div>;
}

export function AccountRow({ label, value, onClick, ariaLabel }: { label: string; value: string; onClick: () => void; ariaLabel: string }) {
  return <div className="pg-row acct-row">
    <span>{label}</span>
    <button type="button" onClick={onClick} aria-label={ariaLabel}>
      <strong>{value}</strong>
      <ChevronRight size={13} aria-hidden="true" />
    </button>
  </div>;
}