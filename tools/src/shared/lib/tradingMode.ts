export type TradingMode = 'ordinary' | 'lead'
export const TRADING_MODE_CHANGED = 'tradetools:trading-mode-changed'

const storageKey = 'tradetools:trading-mode'
let mode: TradingMode = 'ordinary'
try {
  if (window.sessionStorage.getItem(storageKey) === 'lead') mode = 'lead'
} catch { /* A mode preference is optional browser storage. */ }
let revision = 0
let activeMutations = 0

export const getTradingMode = () => mode
export const getTradingModeRevision = () => revision
export const hasActiveTradingMutation = () => activeMutations > 0

export async function trackTradingMutation<T>(operation: () => Promise<T>): Promise<T> {
  activeMutations += 1
  try {
    return await operation()
  } finally {
    activeMutations -= 1
  }
}

export function setTradingMode(next: TradingMode) {
  if (next !== 'ordinary' && next !== 'lead') throw new Error('交易模式无效')
  if (next === mode) return
  if (activeMutations > 0) throw new Error('当前操作尚未结束，请稍后切换模式')
  mode = next
  revision += 1
  try { window.sessionStorage.setItem(storageKey, next) } catch { /* optional */ }
  window.dispatchEvent(new Event(TRADING_MODE_CHANGED))
}
