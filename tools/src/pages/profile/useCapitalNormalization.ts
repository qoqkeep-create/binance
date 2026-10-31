import { useCallback, useEffect, useRef, useState } from 'react'
import Decimal from 'decimal.js'
import type { CapitalState } from '@/components/modals/CapitalNormalizationModal'
import { api } from '@/shared/lib/api'
import { ACCOUNT_BINDING_CHANGED_EVENT, getAccountSessionRevision } from '@/shared/lib/accountBalanceState'
import { getTradingMode, getTradingModeRevision, TRADING_MODE_CHANGED } from '@/shared/lib/tradingMode'
import { showToast, useAuthStore } from '@/shared/store'

const FOLLOW_UP_DELAYS = [2000, 5000, 10000, 20000, 30000, 30000, 30000]

export function pendingCollection(state: CapitalState) {
  return state.status === 'collection_pending' ? state : state.pending_collection
}

function collectionPreview(state: CapitalState): CapitalState {
  // The account panel collects outward excess; refill-only plans belong to
  // the existing capital service and must not become a collection action.
  if (state.status === 'normalization_required' && !pendingCollection(state)
    && new Decimal(state.transfer_amount ?? state.collection_total ?? 0).lt('0.01')) {
    return { ...state, status: 'ready', reason: 'no_collectible_excess' }
  }
  return state
}

export function useCapitalNormalization(onChanged: () => void) {
  const [state, setState] = useState<CapitalState | null>(null)
  const [isOpen, setOpen] = useState(false)
  const [loading, setLoading] = useState(false)
  const [following, setFollowing] = useState(false)
  const revision = useRef(0)
  const busy = useRef(false)
  const timer = useRef<ReturnType<typeof setTimeout>>()
  const onChangedRef = useRef(onChanged)
  onChangedRef.current = onChanged

  const stop = useCallback(() => {
    revision.current += 1
    clearTimeout(timer.current)
    busy.current = false
    setLoading(false)
    setFollowing(false)
  }, [])
  const close = useCallback(() => {
    stop()
    setOpen(false)
    setState(null)
  }, [stop])

  useEffect(() => {
    const reset = close
    const pause = () => {
      if (document.visibilityState === 'hidden' || !navigator.onLine) stop()
    }
    window.addEventListener(ACCOUNT_BINDING_CHANGED_EVENT, reset)
    window.addEventListener(TRADING_MODE_CHANGED, reset)
    document.addEventListener('visibilitychange', pause)
    window.addEventListener('offline', pause)
    const unsubscribe = useAuthStore.subscribe((next, previous) => {
      if (next.user?.id !== previous.user?.id || !next.isAuthenticated) reset()
    })
    return () => {
      revision.current += 1
      clearTimeout(timer.current)
      unsubscribe()
      window.removeEventListener(ACCOUNT_BINDING_CHANGED_EVENT, reset)
      window.removeEventListener(TRADING_MODE_CHANGED, reset)
      document.removeEventListener('visibilitychange', pause)
      window.removeEventListener('offline', pause)
    }
  }, [close, stop])

  function currentScope() {
    const epoch = ++revision.current
    const session = getAccountSessionRevision()
    const mode = getTradingModeRevision()
    const user = useAuthStore.getState().user?.id
    return () => epoch === revision.current && session === getAccountSessionRevision()
      && mode === getTradingModeRevision() && getTradingMode() === 'ordinary'
      && Boolean(user) && user === useAuthStore.getState().user?.id
  }

  async function check() {
    if (busy.current || getTradingMode() !== 'ordinary') return
    stop()
    const isCurrent = currentScope()
    busy.current = true
    setLoading(true)
    try {
      const result = collectionPreview(await api.post<CapitalState>('/trade/capital/precheck', { purpose: 'manual_sweep' }))
      if (!isCurrent()) return
      setState(result)
      setOpen(true)
      return result
    } catch (error) {
      if (isCurrent()) showToast(error instanceof Error ? error.message : '归集检查失败，请稍后重试')
    } finally {
      if (isCurrent()) { busy.current = false; setLoading(false) }
    }
  }

  async function confirm() {
    if (!state || busy.current || following || !isOpen || getTradingMode() !== 'ordinary') return
    const pending = pendingCollection(state)
    if (!pending && state.status !== 'normalization_required') return
    // The server-returned id pins all follow-ups to this one confirmed plan.
    if (pending && !pending.collection_id) { await check(); return }
    stop()
    const isCurrent = currentScope()
    const startedAt = Date.now()
    setFollowing(true)

    const run = async (collectionId: number | undefined, attempt: number): Promise<void> => {
      if (!isCurrent() || document.visibilityState === 'hidden' || !navigator.onLine) return
      if (attempt > 0 && Date.now() - startedAt >= 180000) { setFollowing(false); return }
      busy.current = true
      setLoading(true)
      let nextId = collectionId
      let continueFollowing = false
      try {
        const result = collectionPreview(await api.post<CapitalState>('/trade/capital/normalize', {
          expected_status: collectionId ? 'collection_pending' : 'normalization_required',
          purpose: 'manual_sweep',
          ...(collectionId ? { collection_id: collectionId } : {}),
          ...(!collectionId && state.plan_token ? { expected_plan: state.plan_token } : {}),
        }))
        if (!isCurrent()) return
        const nextPending = pendingCollection(result)
        continueFollowing = result.status === 'collection_pending'
          && Boolean(nextPending?.collection_id)
          && (!collectionId || nextPending?.collection_id === collectionId)
        nextId = nextPending?.collection_id
        setState(previous => result.status === 'collection_pending'
          ? { ...previous, ...result, pending_collection: undefined }
          : result)
        if (!continueFollowing) {
          onChangedRef.current()
          if (result.reason === 'normalization_completed') {
            showToast('资金调整完成')
            if (pending) {
              // The resumed collection is finished. Read the present plan;
              // a new transfer still requires a separate confirmation.
              try {
                const latest = collectionPreview(await api.post<CapitalState>('/trade/capital/precheck', { purpose: 'manual_sweep' }))
                if (isCurrent() && latest.status === 'normalization_required') setState(latest)
              } catch {
                if (isCurrent()) showToast('上次归集已完成，当前余额检查失败，请重新打开归集面板')
              }
            }
          }
        }
      } catch (error) {
        if (!isCurrent()) return
        // Without a returned id we cannot safely replay the first confirmation.
        // Re-open via receipt-only precheck; an explicit click can then resume.
        if (!collectionId) {
          setState(null)
          setOpen(false)
          showToast('请求结果尚未确认，请重新打开归集面板核对，系统不会重复转账')
        } else {
          continueFollowing = true
          setState(previous => previous && ({ ...previous, collection_error: error instanceof Error ? error.message : '暂时无法查询，稍后继续确认' }))
        }
      } finally {
        if (isCurrent()) { busy.current = false; setLoading(false) }
      }
      if (!isCurrent()) return
      if (continueFollowing && nextId && attempt < FOLLOW_UP_DELAYS.length && Date.now() - startedAt < 180000) {
        timer.current = setTimeout(() => void run(nextId, attempt + 1), FOLLOW_UP_DELAYS[attempt])
      } else {
        setFollowing(false)
      }
    }
    await run(pending?.collection_id, 0)
  }

  return { state, isOpen, loading, following, check, confirm, close }
}
