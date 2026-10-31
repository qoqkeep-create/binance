import { useSyncExternalStore } from 'react'
import { getTradingMode, TRADING_MODE_CHANGED } from '@/shared/lib/tradingMode'

function subscribe(listener: () => void) {
  window.addEventListener(TRADING_MODE_CHANGED, listener)
  return () => window.removeEventListener(TRADING_MODE_CHANGED, listener)
}

export function useTradingMode() {
  return useSyncExternalStore(subscribe, getTradingMode, () => 'ordinary' as const)
}
