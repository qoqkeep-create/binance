import { useRef, useState } from 'react'
import { ConfirmModal } from '@/components/modals/ConfirmModal'
import { api } from '@/shared/lib/api'
import {
  ACCOUNT_BINDING_CHANGED_EVENT, advanceAccountSessionRevision, clearAccountScopedCaches,
  getAccountSessionRevision, isCurrentAccountSession,
} from '@/shared/lib/accountBalanceState'
import { useTradingMode } from '@/shared/hooks/useTradingMode'
import { showToast, useAuthStore, useTradingStore } from '@/shared/store'

interface ApiUnbindButtonProps {
  onUnbound?: () => void
  className?: string
}

export function ApiUnbindButton({ onUnbound, className }: ApiUnbindButtonProps) {
  const mode = useTradingMode()
  const [confirming, setConfirming] = useState(false)
  const [pending, setPending] = useState(false)
  const [error, setError] = useState('')
  const pendingRef = useRef(false)

  const unbind = async () => {
    if (pendingRef.current) return
    pendingRef.current = true
    const userId = useAuthStore.getState().user?.id ?? ''
    let revision = getAccountSessionRevision()
    const isCurrent = () => isCurrentAccountSession(
      userId, useAuthStore.getState().user?.id ?? '', revision, getAccountSessionRevision(),
    )
    setPending(true)
    setError('')
    try {
      await api.post('/api/unbind', {})
      if (!isCurrent()) return
      revision = advanceAccountSessionRevision()
      clearAccountScopedCaches(userId)
      useTradingStore.getState().clearApiConfigs()
      setConfirming(false)
      showToast('API 绑定已解除')
      onUnbound?.()
      window.dispatchEvent(new CustomEvent(ACCOUNT_BINDING_CHANGED_EVENT, { detail: { bound: false } }))
    } catch (failure) {
      if (isCurrent()) setError(failure instanceof Error ? failure.message : '解除失败，请稍后重试')
    } finally {
      pendingRef.current = false
      if (isCurrent()) setPending(false)
    }
  }

  return <>
    <button type="button" onClick={() => { setError(''); setConfirming(true) }}
      className={className ?? 'min-h-8 whitespace-nowrap text-xs text-[#F6465D] underline underline-offset-4 hover:opacity-80'}>
      解除 API 绑定
    </button>
    <ConfirmModal isOpen={confirming} onClose={() => setConfirming(false)} onConfirm={() => void unbind()}
      title="解除 API 绑定" confirmText={pending ? '解除中…' : '确认解除'} confirmVariant="danger" busy={pending}>
      <p>确定解除当前{mode === 'lead' ? '带单' : '合约'}账户的 API 绑定吗？解除后需重新绑定才能在本系统交易。</p>
      {error && <p role="alert" className="mt-3 text-[#F6465D]">{error}</p>}
    </ConfirmModal>
  </>
}
