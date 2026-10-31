import { beforeEach, describe, expect, it, vi } from 'vitest'

import { api } from '@/shared/lib/api'
import { useAuthStore } from '@/shared/store/authStore'
import {
  clearTransferHistorySnapshot,
  getTransferHistorySnapshot,
  loadTransferHistory,
  syncTransferHistory,
} from './data'
import type { TransferHistoryData } from './data'

function historyData(netAmount: string): TransferHistoryData {
  return {
    start_at: '2026-08-28T00:00:00Z',
    account_type: 'sub',
    outgoing_total: netAmount,
    incoming_total: '0',
    net_amount: netAmount,
    last_synced_at: null,
    sync_status: 'ready',
    pagination: {
      page: 1,
      page_size: 20,
      total: 0,
      total_pages: 0,
      has_next: false,
    },
    records: [],
  }
}

describe('transfer history request scope', () => {
  beforeEach(() => {
    useAuthStore.getState().logout()
    useAuthStore.getState().login({ id: '7', email: 'user@example.com' }, 'token-1')
    clearTransferHistorySnapshot()
  })

  it('does not cache an old response after the same account logs in again', async () => {
    let resolveOld: (value: TransferHistoryData) => void = () => undefined
    const oldRequest = new Promise<TransferHistoryData>((resolve) => {
      resolveOld = resolve
    })
    vi.spyOn(api, 'get').mockReturnValueOnce(oldRequest)

    const pending = loadTransferHistory()
    useAuthStore.getState().logout()
    useAuthStore.getState().login({ id: '7', email: 'user@example.com' }, 'token-2')
    resolveOld(historyData('10'))
    await pending

    expect(getTransferHistorySnapshot()).toBeNull()

    vi.spyOn(api, 'get').mockResolvedValueOnce(historyData('20'))
    await loadTransferHistory()
    expect(getTransferHistorySnapshot()?.net_amount).toBe('20')
  })

  it('does not restore a synchronized snapshot after the cache is invalidated', async () => {
    let resolveSync: (value: TransferHistoryData) => void = () => undefined
    const request = new Promise<TransferHistoryData>((resolve) => {
      resolveSync = resolve
    })
    vi.spyOn(api, 'post').mockReturnValueOnce(request)

    const pending = syncTransferHistory()
    clearTransferHistorySnapshot()
    resolveSync(historyData('30'))
    await pending

    expect(getTransferHistorySnapshot()).toBeNull()
  })
})
