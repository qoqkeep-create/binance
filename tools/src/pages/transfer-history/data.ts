import { api } from '@/shared/lib/api'
import { getAccountSessionRevision } from '@/shared/lib/accountBalanceState'
import { useAuthStore } from '@/shared/store/authStore'

export type TransferDirection = 'outgoing' | 'incoming'

export interface TransferRecord {
  id: string
  direction: TransferDirection
  amount: string
  asset: 'USDT'
  occurred_at: string
  route: string
  channel: string
}

export interface TransferHistoryData {
  start_at: string
  account_type: 'master' | 'sub' | 'unknown'
  outgoing_total: string
  incoming_total: string
  net_amount: string
  last_synced_at: string | null
  sync_status: 'ready' | 'pending' | 'error'
  pagination: {
    page: number
    page_size: number
    total: number
    total_pages: number
    has_next: boolean
  }
  records: TransferRecord[]
}

interface ScopedValue<T> {
  scope: string
  value: T
}

let snapshot: ScopedValue<TransferHistoryData> | null = null
let pendingRead: ScopedValue<Promise<TransferHistoryData>> | null = null
let cacheGeneration = 0

function currentScope(): string {
  const user = useAuthStore.getState().user
  const userId = user?.id || user?.email || ''
  return userId ? `${userId}:${getAccountSessionRevision()}` : ''
}

export function getTransferHistorySnapshot(): TransferHistoryData | null {
  const scope = currentScope()
  return scope && snapshot?.scope === scope ? snapshot.value : null
}

export function clearTransferHistorySnapshot() {
  cacheGeneration += 1
  snapshot = null
  pendingRead = null
}

export async function loadTransferHistory(): Promise<TransferHistoryData> {
  const scope = currentScope()
  const generation = cacheGeneration
  if (pendingRead?.scope === scope) return pendingRead.value

  const request = api.get<TransferHistoryData>('/account/transfer-history?page=1&page_size=20', {
    disableRetry: true,
    suppressConnectionError: true,
    timeout: 8000,
  })
  pendingRead = { scope, value: request }
  try {
    const data = await request
    if (currentScope() === scope && cacheGeneration === generation) {
      snapshot = { scope, value: data }
    }
    return data
  } finally {
    if (pendingRead?.value === request) pendingRead = null
  }
}

export async function loadMoreTransferHistory(
  current: TransferHistoryData,
): Promise<TransferHistoryData> {
  if (!current.pagination.has_next) return current
  const scope = currentScope()
  const generation = cacheGeneration
  const nextPage = current.pagination.page + 1
  const next = await api.get<TransferHistoryData>(
    `/account/transfer-history?page=${nextPage}&page_size=${current.pagination.page_size}`,
    {
      disableRetry: true,
      suppressConnectionError: true,
      timeout: 8000,
    },
  )
  const seen = new Set(current.records.map(record => record.id))
  const merged = {
    ...next,
    records: [...current.records, ...next.records.filter(record => !seen.has(record.id))],
  }
  if (currentScope() === scope && cacheGeneration === generation) {
    snapshot = { scope, value: merged }
  }
  return merged
}

export async function syncTransferHistory(): Promise<TransferHistoryData> {
  const scope = currentScope()
  const generation = cacheGeneration
  const data = await api.post<TransferHistoryData>(
    '/account/transfer-history/sync',
    {},
    { timeout: 60000 },
  )
  if (currentScope() === scope && cacheGeneration === generation) {
    snapshot = { scope, value: data }
  }
  return data
}
