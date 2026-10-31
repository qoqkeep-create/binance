import { useEffect, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { api } from '@/shared/lib/api'
import { advanceAccountSessionRevision } from '@/shared/lib/accountBalanceState'
import { hasActiveTradingMutation, setTradingMode } from '@/shared/lib/tradingMode'
import { useTradingMode } from '@/shared/hooks/useTradingMode'
import { showToast, useAuthStore, useTradingStore } from '@/shared/store'
import { ConfirmModal } from '@/components/modals/ConfirmModal'

export function TradingModeSwitch() {
  const mode = useTradingMode()
  const [enabled, setEnabled] = useState(mode === 'lead')
  const [confirming, setConfirming] = useState(false)
  const next = mode === 'ordinary' ? 'lead' : 'ordinary'
  const buttonText = mode === 'ordinary' ? '切换带单模式' : '切换合约模式'
  const queryClient = useQueryClient()
  useEffect(() => {
    let active = true
    api.get<{ lead_trading_enabled?: boolean; lead_trading_bound?: boolean }>('/account/version', { disableRetry: true })
      .then(data => { if (active) setEnabled(Boolean(data.lead_trading_enabled || data.lead_trading_bound)) })
      .catch(() => { /* Keep the return-to-ordinary option available. */ })
    return () => { active = false }
  }, [])

  const switchTo = () => {
    if (hasActiveTradingMutation()) {
      showToast('当前操作尚未结束，请稍后切换模式')
      return
    }
    advanceAccountSessionRevision()
    queryClient.clear()
    setTradingMode(next)
    useTradingStore.getState().activateAccount(useAuthStore.getState().user?.id ?? '')
    setConfirming(false)
  }

  if (!enabled && mode === 'ordinary') return null
  return (
    <>
      <button type="button" onClick={() => setConfirming(true)}
        className="shrink-0 rounded-lg border border-[var(--t-brand)]/30 bg-[var(--t-brand)]/10 px-2.5 py-2.5 text-xs font-medium whitespace-nowrap text-t-text transition-colors hover:bg-[var(--t-brand)]/20 active:scale-[0.98]">
        {buttonText}
      </button>
      <ConfirmModal isOpen={confirming} onClose={() => setConfirming(false)} onConfirm={switchTo}
        title={buttonText} confirmText="确认切换">
        确定切换到{next === 'lead' ? '带单' : '普通合约'}账户吗？切换后显示该账户的余额和订单，当前持仓及保护继续运行。
      </ConfirmModal>
    </>
  )
}
