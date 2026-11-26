export interface EmaSettings {
  enabled: boolean;
  periods: [number, number, number];
  colors: [string, string, string];
}
export interface SupertrendSettings {
  enabled: boolean;
  period: number;
  multiplier: number;
  upColor: string;
  downColor: string;
  fillUpColor: string;
  fillDownColor: string;
  fillOpacity: number;
}
export interface MacdSettings {
  enabled: boolean;
  fast: number;
  slow: number;
  signal: number;
  difColor: string;
  deaColor: string;
  upColor: string;
  downColor: string;
}
export interface StochSettings {
  enabled: boolean;
  rsi: number;
  stoch: number;
  k: number;
  d: number;
  kColor: string;
  dColor: string;
}
export interface IndicatorSettings {
  ema: EmaSettings;
  supertrend: SupertrendSettings;
  macd: MacdSettings;
  stoch: StochSettings;
}

export const DEFAULT_INDICATORS: IndicatorSettings = {
  ema: { enabled: true, periods: [21, 55, 144], colors: ["#2DBD85", "#3860F6", "#71269C"] },
  supertrend: {
    enabled: true, period: 10, multiplier: 6,
    upColor: "#28A473", downColor: "#F63C55",
    fillUpColor: "#28A473", fillDownColor: "#F63C55", fillOpacity: 0.16,
  },
  macd: { enabled: true, fast: 12, slow: 26, signal: 9, difColor: "#2DBD85", deaColor: "#71269C", upColor: "#28A473", downColor: "#F63C55" },
  stoch: { enabled: true, rsi: 14, stoch: 14, k: 3, d: 3, kColor: "#2DBD85", dColor: "#71269C" },
};

const isHex = (value: unknown): value is string => typeof value === "string" && /^#[0-9a-fA-F]{6}$/.test(value);
const isPosInt = (value: unknown, min = 1, max = 500): value is number => typeof value === "number" && Number.isInteger(value) && value >= min && value <= max;
const isOpacity = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1;
const isBool = (value: unknown): value is boolean => typeof value === "boolean";

function mergeEma(raw: unknown): EmaSettings {
  const base = DEFAULT_INDICATORS.ema;
  const value = (raw ?? {}) as Partial<EmaSettings>;
  const periods = Array.isArray(value.periods) && value.periods.length === 3 && value.periods.every((p) => isPosInt(p))
    ? value.periods as [number, number, number] : base.periods;
  const colors = Array.isArray(value.colors) && value.colors.length === 3 && value.colors.every(isHex)
    ? value.colors as [string, string, string] : base.colors;
  return { enabled: isBool(value.enabled) ? value.enabled : base.enabled, periods, colors };
}

function mergeSupertrend(raw: unknown): SupertrendSettings {
  const base = DEFAULT_INDICATORS.supertrend;
  const value = (raw ?? {}) as Partial<SupertrendSettings>;
  return {
    enabled: isBool(value.enabled) ? value.enabled : base.enabled,
    period: isPosInt(value.period) ? value.period : base.period,
    multiplier: typeof value.multiplier === "number" && value.multiplier > 0 && value.multiplier <= 50 ? value.multiplier : base.multiplier,
    upColor: isHex(value.upColor) ? value.upColor : base.upColor,
    downColor: isHex(value.downColor) ? value.downColor : base.downColor,
    fillUpColor: isHex(value.fillUpColor) ? value.fillUpColor : base.fillUpColor,
    fillDownColor: isHex(value.fillDownColor) ? value.fillDownColor : base.fillDownColor,
    fillOpacity: isOpacity(value.fillOpacity) ? value.fillOpacity : base.fillOpacity,
  };
}

function mergeMacd(raw: unknown): MacdSettings {
  const base = DEFAULT_INDICATORS.macd;
  const value = (raw ?? {}) as Partial<MacdSettings>;
  return {
    enabled: isBool(value.enabled) ? value.enabled : base.enabled,
    fast: isPosInt(value.fast) ? value.fast : base.fast,
    slow: isPosInt(value.slow) ? value.slow : base.slow,
    signal: isPosInt(value.signal) ? value.signal : base.signal,
    difColor: isHex(value.difColor) ? value.difColor : base.difColor,
    deaColor: isHex(value.deaColor) ? value.deaColor : base.deaColor,
    upColor: isHex(value.upColor) ? value.upColor : base.upColor,
    downColor: isHex(value.downColor) ? value.downColor : base.downColor,
  };
}

function mergeStoch(raw: unknown): StochSettings {
  const base = DEFAULT_INDICATORS.stoch;
  const value = (raw ?? {}) as Partial<StochSettings>;
  return {
    enabled: isBool(value.enabled) ? value.enabled : base.enabled,
    rsi: isPosInt(value.rsi) ? value.rsi : base.rsi,
    stoch: isPosInt(value.stoch) ? value.stoch : base.stoch,
    k: isPosInt(value.k) ? value.k : base.k,
    d: isPosInt(value.d) ? value.d : base.d,
    kColor: isHex(value.kColor) ? value.kColor : base.kColor,
    dColor: isHex(value.dColor) ? value.dColor : base.dColor,
  };
}

/** Lenient merge so partial or legacy stored values fall back to iOS defaults per field. */
export function mergeIndicatorSettings(raw: unknown): IndicatorSettings {
  const value = (raw ?? {}) as Partial<IndicatorSettings>;
  return {
    ema: mergeEma(value.ema),
    supertrend: mergeSupertrend(value.supertrend),
    macd: mergeMacd(value.macd),
    stoch: mergeStoch(value.stoch),
  };
}