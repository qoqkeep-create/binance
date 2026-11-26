import { useEffect, useId, useRef } from "react";
import type { ReactNode } from "react";
import { X } from "lucide-react";
import type { IndicatorSettings } from "./lib/indicatorSettings";

function NumberField({ label, value, min = 1, max = 500, step = 1, onChange }: { label: string; value: number; min?: number; max?: number; step?: number; onChange: (value: number) => void }) {
  return <label className="ind-field"><span>{label}</span><input type="number" min={min} max={max} step={step} value={value} onChange={(event) => {
    const next = Number(event.target.value);
    if (Number.isFinite(next) && next >= min && next <= max) onChange(next);
  }} /></label>;
}

function ColorField({ label, value, onChange }: { label: string; value: string; onChange: (value: string) => void }) {
  return <label className="ind-field ind-color"><span>{label}</span><span className="ind-color-control"><input type="color" value={value} onChange={(event) => onChange(event.target.value)} /><code>{value.toUpperCase()}</code></span></label>;
}

function Section({ title, enabled, onToggle, children }: { title: string; enabled: boolean; onToggle: (enabled: boolean) => void; children: ReactNode }) {
  return <section className={`ind-section ${enabled ? "" : "is-off"}`}>
    <header><label className="ind-enable"><input type="checkbox" checked={enabled} onChange={(event) => onToggle(event.target.checked)} /><strong>{title}</strong></label></header>
    <div className="ind-body">{children}</div>
  </section>;
}

export default function IndicatorSettingsPanel({ settings, onChange, onClose }: { settings: IndicatorSettings; onChange: (next: IndicatorSettings) => void; onClose: () => void }) {
  const titleId = useId();
  const dialogRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    dialogRef.current?.focus();
    const onKey = (event: KeyboardEvent) => { if (event.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const set = (patch: Partial<IndicatorSettings>) => onChange({ ...settings, ...patch });

  return <div className="ind-backdrop" onPointerDown={(event) => { if (event.target === event.currentTarget) onClose(); }}>
    <div className="ind-panel" ref={dialogRef} role="dialog" aria-modal="true" aria-labelledby={titleId} tabIndex={-1}>
      <header className="ind-panel-heading"><h2 id={titleId}>指标设置</h2><button type="button" className="ind-close" aria-label="关闭指标设置" onClick={onClose}><X size={16} /></button></header>
      <div className="ind-panel-body">
        <Section title="EMA 均线" enabled={settings.ema.enabled} onToggle={(enabled) => set({ ema: { ...settings.ema, enabled } })}>
          {(["短期", "中期", "长期"] as const).map((label, index) => <div className="ind-row" key={label}>
            <NumberField label={`${label}周期`} value={settings.ema.periods[index]} onChange={(value) => {
              const periods = [...settings.ema.periods] as [number, number, number];
              periods[index] = value;
              set({ ema: { ...settings.ema, periods } });
            }} />
            <ColorField label="颜色" value={settings.ema.colors[index]} onChange={(value) => {
              const colors = [...settings.ema.colors] as [string, string, string];
              colors[index] = value;
              set({ ema: { ...settings.ema, colors } });
            }} />
          </div>)}
        </Section>
        <Section title="Supertrend 撑压" enabled={settings.supertrend.enabled} onToggle={(enabled) => set({ supertrend: { ...settings.supertrend, enabled } })}>
          <div className="ind-row">
            <NumberField label="ATR 周期" value={settings.supertrend.period} onChange={(value) => set({ supertrend: { ...settings.supertrend, period: value } })} />
            <NumberField label="倍数" value={settings.supertrend.multiplier} min={0.5} max={50} step={0.5} onChange={(value) => set({ supertrend: { ...settings.supertrend, multiplier: value } })} />
          </div>
          <div className="ind-row">
            <ColorField label="多头线" value={settings.supertrend.upColor} onChange={(value) => set({ supertrend: { ...settings.supertrend, upColor: value } })} />
            <ColorField label="空头线" value={settings.supertrend.downColor} onChange={(value) => set({ supertrend: { ...settings.supertrend, downColor: value } })} />
          </div>
          <div className="ind-row">
            <ColorField label="多头填充" value={settings.supertrend.fillUpColor} onChange={(value) => set({ supertrend: { ...settings.supertrend, fillUpColor: value } })} />
            <ColorField label="空头填充" value={settings.supertrend.fillDownColor} onChange={(value) => set({ supertrend: { ...settings.supertrend, fillDownColor: value } })} />
          </div>
          <label className="ind-field ind-opacity"><span>填充透明度 {Math.round(settings.supertrend.fillOpacity * 100)}%</span><input type="range" min={0} max={100} value={Math.round(settings.supertrend.fillOpacity * 100)} onChange={(event) => set({ supertrend: { ...settings.supertrend, fillOpacity: Number(event.target.value) / 100 } })} /></label>
        </Section>
        <Section title="MACD" enabled={settings.macd.enabled} onToggle={(enabled) => set({ macd: { ...settings.macd, enabled } })}>
          <div className="ind-row">
            <NumberField label="快线" value={settings.macd.fast} onChange={(value) => set({ macd: { ...settings.macd, fast: value } })} />
            <NumberField label="慢线" value={settings.macd.slow} onChange={(value) => set({ macd: { ...settings.macd, slow: value } })} />
            <NumberField label="信号" value={settings.macd.signal} onChange={(value) => set({ macd: { ...settings.macd, signal: value } })} />
          </div>
          <div className="ind-row">
            <ColorField label="DIF" value={settings.macd.difColor} onChange={(value) => set({ macd: { ...settings.macd, difColor: value } })} />
            <ColorField label="DEA" value={settings.macd.deaColor} onChange={(value) => set({ macd: { ...settings.macd, deaColor: value } })} />
          </div>
          <div className="ind-row">
            <ColorField label="正柱" value={settings.macd.upColor} onChange={(value) => set({ macd: { ...settings.macd, upColor: value } })} />
            <ColorField label="负柱" value={settings.macd.downColor} onChange={(value) => set({ macd: { ...settings.macd, downColor: value } })} />
          </div>
        </Section>
        <Section title="StochRSI" enabled={settings.stoch.enabled} onToggle={(enabled) => set({ stoch: { ...settings.stoch, enabled } })}>
          <div className="ind-row">
            <NumberField label="RSI" value={settings.stoch.rsi} onChange={(value) => set({ stoch: { ...settings.stoch, rsi: value } })} />
            <NumberField label="随机窗口" value={settings.stoch.stoch} onChange={(value) => set({ stoch: { ...settings.stoch, stoch: value } })} />
            <NumberField label="K 平滑" value={settings.stoch.k} onChange={(value) => set({ stoch: { ...settings.stoch, k: value } })} />
            <NumberField label="D 平滑" value={settings.stoch.d} onChange={(value) => set({ stoch: { ...settings.stoch, d: value } })} />
          </div>
          <div className="ind-row">
            <ColorField label="K 线" value={settings.stoch.kColor} onChange={(value) => set({ stoch: { ...settings.stoch, kColor: value } })} />
            <ColorField label="D 线" value={settings.stoch.dColor} onChange={(value) => set({ stoch: { ...settings.stoch, dColor: value } })} />
          </div>
        </Section>
      </div>
    </div>
  </div>;
}