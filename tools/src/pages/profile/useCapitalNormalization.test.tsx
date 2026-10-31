import { act, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { api } from '@/shared/lib/api'
import { useAuthStore } from '@/shared/store'
import { advanceAccountSessionRevision, ACCOUNT_BINDING_CHANGED_EVENT } from '@/shared/lib/accountBalanceState'
import { setTradingMode } from '@/shared/lib/tradingMode'
import type { CapitalState } from '@/components/modals/CapitalNormalizationModal'
import { useCapitalNormalization } from './useCapitalNormalization'

const plan: CapitalState = {
  status: 'normalization_required', futures_collect: '405.28', transfer_amount: '405.28',
  minimum_open_balance: '300', maximum_futures_balance: '1000', futures_balance: '1405.28',
}
const pending: CapitalState = {
  status: 'collection_pending', collection_id: 22, futures_collect: '405.28', transfer_amount: '405.28',
  completed_steps: ['futures_collect'],
}
const completed: CapitalState = { ...pending, status: 'ready', reason: 'normalization_completed' }

beforeEach(() => {
  vi.useFakeTimers()
  setTradingMode('ordinary')
  Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'visible' })
  Object.defineProperty(navigator, 'onLine', { configurable: true, value: true })
  useAuthStore.setState({ user: { id: '7', email: 'test@example.com' }, isAuthenticated: true })
})
afterEach(() => {
  vi.restoreAllMocks()
  vi.useRealTimers()
  setTradingMode('ordinary')
})

describe('confirmed capital progression', () => {
  it('does not offer a refill-only plan as a new collection', async () => {
    const request = vi.spyOn(api, 'post').mockResolvedValueOnce({
      status: 'normalization_required', spot_to_futures: '100', transfer_amount: '0',
    })
    const { result } = renderHook(() => useCapitalNormalization(vi.fn()))
    await act(() => result.current.check())
    await act(() => result.current.confirm())
    expect(result.current.state?.reason).toBe('no_collectible_excess')
    expect(result.current.state?.status).toBe('ready')
    expect(request).toHaveBeenCalledOnce()
  })

  it('shows the current excess after the previous collection completes, without confirming a new transfer', async () => {
    const request = vi.spyOn(api, 'post').mockResolvedValueOnce({ ...plan, pending_collection: pending })
      .mockResolvedValueOnce(completed).mockResolvedValueOnce(plan)
    const changed = vi.fn()
    const { result } = renderHook(() => useCapitalNormalization(changed))
    await act(() => result.current.check())
    await act(() => result.current.confirm())
    expect(result.current.state).toEqual(plan)
    expect(request.mock.calls.map(([url]) => url)).toEqual([
      '/trade/capital/precheck', '/trade/capital/normalize', '/trade/capital/precheck',
    ])
    expect(result.current.following).toBe(false)
    expect(changed).toHaveBeenCalled()
  })

  it('discards the panel state when it closes', async () => {
    vi.spyOn(api, 'post').mockResolvedValueOnce(pending)
    const { result } = renderHook(() => useCapitalNormalization(vi.fn()))
    await act(() => result.current.check())
    act(() => result.current.close())
    expect(result.current.state).toBeNull()
  })

  it('keeps completion when the current preview fails and never replays the transfer', async () => {
    const request = vi.spyOn(api, 'post').mockResolvedValueOnce(pending)
      .mockResolvedValueOnce(completed).mockRejectedValueOnce(new Error('network'))
    const { result } = renderHook(() => useCapitalNormalization(vi.fn()))
    await act(() => result.current.check())
    await act(() => result.current.confirm())
    await act(() => vi.advanceTimersByTimeAsync(180_000))
    expect(result.current.state?.reason).toBe('normalization_completed')
    expect(result.current.following).toBe(false)
    expect(request.mock.calls.filter(([url]) => url === '/trade/capital/normalize')).toHaveLength(1)
  })

  it.each([pending, { ...plan, pending_collection: pending }])('resumes either pending shape and completes without another click', async initial => {
    const request = vi.spyOn(api, 'post').mockResolvedValueOnce(initial).mockResolvedValueOnce(pending)
      .mockResolvedValueOnce(completed).mockResolvedValueOnce({ status: 'ready' })
    const changed = vi.fn()
    const { result } = renderHook(() => useCapitalNormalization(changed))
    await act(() => result.current.check())
    expect(request).toHaveBeenCalledTimes(1) // Opening never sends normalize.
    await act(() => result.current.confirm())
    expect(result.current.following).toBe(true)
    await act(() => vi.advanceTimersByTimeAsync(2000))
    expect(request.mock.calls.slice(1)).toEqual([
      ['/trade/capital/normalize', { expected_status: 'collection_pending', purpose: 'manual_sweep', collection_id: 22 }],
      ['/trade/capital/normalize', { expected_status: 'collection_pending', purpose: 'manual_sweep', collection_id: 22 }],
      ['/trade/capital/precheck', { purpose: 'manual_sweep' }],
    ])
    expect(result.current.state?.reason).toBe('normalization_completed')
    expect(result.current.following).toBe(false)
    expect(changed).toHaveBeenCalledOnce()
  })

  it('retains thresholds and both directions while polling, then stops at a changed plan', async () => {
    const request = vi.spyOn(api, 'post').mockResolvedValueOnce(plan).mockResolvedValueOnce(pending)
      .mockResolvedValueOnce({ ...plan, plan_changed: true, futures_collect: '500' })
    const { result } = renderHook(() => useCapitalNormalization(vi.fn()))
    await act(() => result.current.check())
    await act(() => result.current.confirm())
    expect(result.current.state).toMatchObject({ minimum_open_balance: '300', futures_collect: '405.28', transfer_amount: '405.28' })
    await act(() => vi.advanceTimersByTimeAsync(2000))
    await act(() => vi.advanceTimersByTimeAsync(180000))
    expect(result.current.state?.plan_changed).toBe(true)
    expect(request).toHaveBeenCalledTimes(3)
    expect(result.current.following).toBe(false)
  })

  it.each(['close', 'unmount', 'hidden', 'offline', 'binding', 'logout', 'mode'])('stops follow-ups after %s', async cause => {
    const request = vi.spyOn(api, 'post').mockResolvedValueOnce(plan).mockResolvedValue(pending)
    const { result, unmount } = renderHook(() => useCapitalNormalization(vi.fn()))
    await act(() => result.current.check())
    await act(() => result.current.confirm())
    act(() => {
      if (cause === 'close') result.current.close()
      if (cause === 'unmount') unmount()
      if (cause === 'hidden') {
        Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'hidden' })
        document.dispatchEvent(new Event('visibilitychange'))
      }
      if (cause === 'offline') {
        Object.defineProperty(navigator, 'onLine', { configurable: true, value: false })
        window.dispatchEvent(new Event('offline'))
      }
      if (cause === 'binding') {
        advanceAccountSessionRevision()
        window.dispatchEvent(new Event(ACCOUNT_BINDING_CHANGED_EVENT))
      }
      if (cause === 'logout') useAuthStore.setState({ user: null, isAuthenticated: false })
      if (cause === 'mode') setTradingMode('lead')
    })
    await act(() => vi.advanceTimersByTimeAsync(180000))
    expect(request).toHaveBeenCalledTimes(2)
  })

  it('discards late responses after the binding changes', async () => {
    let resolve!: (state: CapitalState) => void
    vi.spyOn(api, 'post').mockImplementation(() => new Promise(done => { resolve = done }) as never)
    const { result } = renderHook(() => useCapitalNormalization(vi.fn()))
    let checking!: Promise<CapitalState | undefined>
    act(() => { checking = result.current.check() })
    act(() => { advanceAccountSessionRevision(); window.dispatchEvent(new Event(ACCOUNT_BINDING_CHANGED_EVENT)) })
    await act(async () => { resolve(plan); await checking })
    expect(result.current.isOpen).toBe(false)
    expect(result.current.state).toBeNull()
  })

  it('bounds retries and keeps the original id after transient query errors', async () => {
    const request = vi.spyOn(api, 'post').mockResolvedValueOnce(plan).mockResolvedValueOnce(pending).mockRejectedValue(new Error('network'))
    const { result } = renderHook(() => useCapitalNormalization(vi.fn()))
    await act(() => result.current.check())
    await act(() => result.current.confirm())
    await act(() => vi.advanceTimersByTimeAsync(180000))
    expect(request).toHaveBeenCalledTimes(9)
    expect(result.current.following).toBe(false)
    expect(result.current.state?.collection_id).toBe(22)
    expect(request.mock.calls.slice(2).every(([, body]) => (body as { collection_id: number }).collection_id === 22)).toBe(true)
  })

  it('does not replay a timed-out initial confirmation without a collection id', async () => {
    const request = vi.spyOn(api, 'post').mockResolvedValueOnce(plan).mockRejectedValue(new Error('timeout'))
    const { result } = renderHook(() => useCapitalNormalization(vi.fn()))
    await act(() => result.current.check())
    await act(() => result.current.confirm())
    await act(() => vi.advanceTimersByTimeAsync(180000))
    expect(request).toHaveBeenCalledTimes(2)
    expect(result.current.following).toBe(false)
  })
})
