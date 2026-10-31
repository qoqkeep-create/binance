import { api } from '@/shared/lib/api'
import { ACCOUNT_BINDING_CHANGED_EVENT, getAccountSessionRevision } from '@/shared/lib/accountBalanceState'
import { getTradingModeRevision, TRADING_MODE_CHANGED } from '@/shared/lib/tradingMode'
import { useAuthStore } from '@/shared/store/authStore'

export interface OperationLog {
  id: string
  occurred_at: string
  order_id: number
  symbol: string
  side: 'long' | 'short'
  position_origin: 'web' | 'exchange_external'
  source: 'system' | 'user' | 'strategy' | 'trade'
  action: string
  status: 'success' | 'pending' | 'failed' | 'info'
  message: string
}

export interface OperationLogPage {
  records: OperationLog[]
  next_cursor: string | null
  has_more: boolean
}

// No account logs are persisted or shared between page instances.
export function getOperationLogScope(): string {
  const userId = useAuthStore.getState().user?.id
  return userId ? `${userId}:${getAccountSessionRevision()}:${getTradingModeRevision()}` : ''
}

export function subscribeOperationLogScope(listener: () => void) {
  const unsubscribe = useAuthStore.subscribe(listener)
  window.addEventListener(ACCOUNT_BINDING_CHANGED_EVENT, listener)
  window.addEventListener(TRADING_MODE_CHANGED, listener)
  return () => {
    unsubscribe()
    window.removeEventListener(ACCOUNT_BINDING_CHANGED_EVENT, listener)
    window.removeEventListener(TRADING_MODE_CHANGED, listener)
  }
}

export function loadOperationLogs(cursor: string | null, signal: AbortSignal): Promise<OperationLogPage> {
  const query = new URLSearchParams({ limit: '20' })
  if (cursor) query.set('cursor', cursor)
  return api.get<OperationLogPage>(`/account/operation-logs?${query}`, {
    signal,
    disableRetry: true,
    suppressConnectionError: true,
    timeout: 8000,
  })
}

export function mergeOperationLogs(previous: OperationLog[], next: OperationLog[]): OperationLog[] {
  const records = new Map(previous.map(record => [record.id, record]))
  for (const record of next) records.set(record.id, record)
  return [...records.values()].sort((left, right) =>
    Date.parse(right.occurred_at) - Date.parse(left.occurred_at),
  )
}
