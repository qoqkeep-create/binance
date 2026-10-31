import { act, fireEvent, render, screen, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { MemoryRouter } from 'react-router-dom'

import { api, ApiError } from '@/shared/lib/api'
import { ACCOUNT_BINDING_CHANGED_EVENT, advanceAccountSessionRevision } from '@/shared/lib/accountBalanceState'
import { setTradingMode } from '@/shared/lib/tradingMode'
import { useAuthStore } from '@/shared/store/authStore'
import { OperationLogsPage } from './index'
import type { OperationLog, OperationLogPage } from './data'

vi.mock('@/shared/lib/device', async (importOriginal) => ({
  ...await importOriginal<typeof import('@/shared/lib/device')>(),
  isStandaloneMode: () => false,
}))

function log(id: string, fields: Partial<OperationLog> = {}): OperationLog {
  return {
    id, occurred_at: `2026-09-30T08:00:0${id}Z`, order_id: 42, symbol: 'BTCUSDT', side: 'long',
    position_origin: 'exchange_external', source: 'system', action: 'stop_created',
    status: 'success', message: `日志 ${id}`, ...fields,
  }
}

function page(records = [log('1')], next_cursor: string | null = null): OperationLogPage {
  return { records, next_cursor, has_more: next_cursor !== null }
}

function deferred() {
  let resolve: (value: OperationLogPage) => void = () => undefined
  const promise = new Promise<OperationLogPage>(done => { resolve = done })
  return { promise, resolve }
}

async function openPage() {
  const view = render(<MemoryRouter><OperationLogsPage /></MemoryRouter>)
  await act(async () => {})
  return view
}

beforeEach(() => {
  vi.useFakeTimers()
  setTradingMode('ordinary')
  Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'visible' })
  Object.defineProperty(navigator, 'onLine', { configurable: true, value: true })
  useAuthStore.setState({ user: { id: '7', email: 'test@example.com' }, isAuthenticated: true })
})

afterEach(() => {
  vi.useRealTimers()
  setTradingMode('ordinary')
})

describe('operation logs', () => {
  it('shows complete reasons, source, status and manual position identity in descending time order', async () => {
    const message = '市价止损确认失败。原止损保留；交易所返回结果未知，系统将继续按原请求核对。'
    vi.spyOn(api, 'get').mockResolvedValue(page([
      log('1', { message, status: 'pending' }),
      log('4', { source: 'trade', status: 'success', position_origin: 'web', side: 'short' }),
      log('3', { source: 'user', status: 'failed' }),
      log('2', { source: 'strategy', status: 'info' }),
    ]))
    const storage = vi.spyOn(Storage.prototype, 'setItem')
    await openPage()

    expect(screen.getByRole('heading', { name: '日志' })).toBeInTheDocument()
    expect(screen.getByText(message)).toBeInTheDocument()
    expect(screen.getAllByText('手动仓')).toHaveLength(3)
    expect(screen.getAllByText('仓位 #42')).toHaveLength(4)
    const items = within(screen.getByRole('list')).getAllByRole('listitem')
    expect(items.map(item => within(item).getByText(/日志|市价止损/).textContent)).toEqual(['日志 4', '日志 3', '日志 2', message])
    for (const label of ['系统', '手动', '策略', '成交', '已执行', '待确认', '失败', '记录']) {
      expect(screen.getByText(label)).toBeInTheDocument()
    }
    expect(storage).not.toHaveBeenCalled()
  })

  it('deduplicates cursor pages and stops automatic first-page refresh while reading older records', async () => {
    const get = vi.spyOn(api, 'get').mockResolvedValueOnce(page([log('3'), log('2')], 'stamp/id+1'))
      .mockResolvedValueOnce(page([log('2', { message: '日志 2 已更新' }), log('1')]))
    await openPage()
    await act(async () => fireEvent.click(screen.getByRole('button', { name: '加载更多' })))

    expect(get.mock.calls[1][0]).toBe('/account/operation-logs?limit=20&cursor=stamp%2Fid%2B1')
    expect(screen.getAllByRole('listitem')).toHaveLength(3)
    expect(screen.getByText('日志 2 已更新')).toBeInTheDocument()
    await act(() => vi.advanceTimersByTimeAsync(90_000))
    expect(get).toHaveBeenCalledTimes(2)
    expect(screen.getByText('日志 1')).toBeInTheDocument()
  })

  it('retains loaded records and pagination after refresh failure', async () => {
    const get = vi.spyOn(api, 'get').mockResolvedValueOnce(page([log('1')], 'older'))
      .mockRejectedValueOnce(new ApiError('日志服务暂时不可用', 503))
    await openPage()
    await act(async () => fireEvent.click(screen.getByRole('button', { name: '刷新日志' })))

    expect(get).toHaveBeenCalledTimes(2)
    expect(screen.getByText('日志 1')).toBeInTheDocument()
    expect(screen.getByRole('alert')).toHaveTextContent('日志服务暂时不可用')
    expect(screen.getByRole('alert')).toHaveTextContent('已保留之前加载的日志')
    expect(screen.getByRole('button', { name: '加载更多' })).toBeEnabled()
  })

  it('does not overlap pagination with another request or lose old pages when the tab resumes', async () => {
    const older = deferred()
    const get = vi.spyOn(api, 'get').mockResolvedValueOnce(page([log('3')], 'older'))
      .mockReturnValueOnce(older.promise).mockResolvedValueOnce(page([log('4')]))
    await openPage()
    fireEvent.click(screen.getByRole('button', { name: '加载更多' }))
    expect(screen.getByRole('button', { name: '刷新日志' })).toBeDisabled()
    expect(screen.getByRole('button', { name: '加载中...' })).toBeDisabled()
    await act(() => vi.advanceTimersByTimeAsync(30_000))
    expect(get).toHaveBeenCalledTimes(2)
    await act(async () => older.resolve(page([log('1')])) )
    act(() => {
      Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'hidden' })
      document.dispatchEvent(new Event('visibilitychange'))
    })
    await act(async () => {
      Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'visible' })
      document.dispatchEvent(new Event('visibilitychange'))
    })
    expect(get).toHaveBeenCalledTimes(2)
    expect(screen.getByText('日志 1')).toBeInTheDocument()
    await act(async () => fireEvent.click(screen.getByRole('button', { name: '刷新日志' })))
    expect(get).toHaveBeenCalledTimes(3)
    expect(screen.getByText('日志 4')).toBeInTheDocument()
    expect(screen.queryByText('日志 1')).not.toBeInTheDocument()
  })

  it('shows loading, initial error, retry and empty states', async () => {
    const initial = deferred()
    const get = vi.spyOn(api, 'get').mockReturnValueOnce(initial.promise)
      .mockRejectedValueOnce(new ApiError('读取失败', 500)).mockResolvedValueOnce(page([]))
    await openPage()
    expect(screen.getByRole('status')).toHaveTextContent('正在加载日志')
    await act(async () => initial.resolve(page([])))
    expect(screen.getByText('暂无日志')).toBeInTheDocument()
    await act(async () => fireEvent.click(screen.getByRole('button', { name: '刷新日志' })))
    expect(screen.getByRole('alert')).toHaveTextContent('读取失败')
    await act(async () => fireEvent.click(screen.getByRole('button', { name: '刷新日志' })))
    expect(get).toHaveBeenCalledTimes(3)
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })

  it('allows retry after an initial request fails', async () => {
    vi.spyOn(api, 'get').mockRejectedValueOnce(new ApiError('首次读取失败', 500)).mockResolvedValueOnce(page())
    await openPage()
    await act(async () => fireEvent.click(screen.getByRole('button', { name: '重新加载' })))
    expect(screen.getByText('日志 1')).toBeInTheDocument()
  })

  it.each(['user', 'binding', 'mode', 'mode_roundtrip', 'same_user_login'])('clears data and ignores responses from the previous %s scope', async cause => {
    const previous = deferred()
    const next = deferred()
    const get = vi.spyOn(api, 'get').mockResolvedValueOnce(page([log('1')]))
      .mockReturnValueOnce(previous.promise).mockReturnValueOnce(next.promise)
    await openPage()
    fireEvent.click(screen.getByRole('button', { name: '刷新日志' }))
    await act(async () => {
      if (cause === 'user') useAuthStore.setState({ user: { id: '8', email: 'next@example.com' } })
      if (cause === 'binding') {
        advanceAccountSessionRevision()
        window.dispatchEvent(new Event(ACCOUNT_BINDING_CHANGED_EVENT))
      }
      if (cause === 'mode' || cause === 'mode_roundtrip') setTradingMode('lead')
      if (cause === 'mode_roundtrip') setTradingMode('ordinary')
      if (cause === 'same_user_login') useAuthStore.getState().login({ id: '7', email: 'test@example.com' }, 'placeholder-access-token')
    })
    expect(get).toHaveBeenCalledTimes(3)
    expect(screen.queryByText('日志 1')).not.toBeInTheDocument()
    expect(get.mock.calls[1][1]?.signal?.aborted).toBe(true)
    await act(async () => previous.resolve(page([log('2')])) )
    expect(screen.queryByText('日志 2')).not.toBeInTheDocument()
    await act(async () => next.resolve(page([log('3')])) )
    expect(screen.getByText('日志 3')).toBeInTheDocument()
  })

  it('refreshes only while visible and online and stops after unmount', async () => {
    const get = vi.spyOn(api, 'get').mockResolvedValue(page())
    const { unmount } = await openPage()
    await act(() => vi.advanceTimersByTimeAsync(30_000))
    expect(get).toHaveBeenCalledTimes(2)
    act(() => {
      Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'hidden' })
      document.dispatchEvent(new Event('visibilitychange'))
    })
    await act(() => vi.advanceTimersByTimeAsync(90_000))
    expect(get).toHaveBeenCalledTimes(2)
    await act(async () => {
      Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'visible' })
      document.dispatchEvent(new Event('visibilitychange'))
    })
    expect(get).toHaveBeenCalledTimes(3)
    act(() => {
      Object.defineProperty(navigator, 'onLine', { configurable: true, value: false })
      window.dispatchEvent(new Event('offline'))
    })
    await act(() => vi.advanceTimersByTimeAsync(90_000))
    expect(get).toHaveBeenCalledTimes(3)
    await act(async () => {
      Object.defineProperty(navigator, 'onLine', { configurable: true, value: true })
      window.dispatchEvent(new Event('online'))
    })
    expect(get).toHaveBeenCalledTimes(4)
    unmount()
    await act(() => vi.advanceTimersByTimeAsync(90_000))
    expect(get).toHaveBeenCalledTimes(4)
  })

  it('waits for connectivity on an offline first visit and does not poll after logout', async () => {
    Object.defineProperty(navigator, 'onLine', { configurable: true, value: false })
    const get = vi.spyOn(api, 'get').mockResolvedValue(page())
    await openPage()
    expect(get).not.toHaveBeenCalled()
    expect(screen.getByRole('button', { name: '刷新日志' })).toBeDisabled()
    await act(async () => {
      Object.defineProperty(navigator, 'onLine', { configurable: true, value: true })
      window.dispatchEvent(new Event('online'))
    })
    expect(screen.getByText('日志 1')).toBeInTheDocument()
    act(() => useAuthStore.getState().logout())
    expect(screen.queryByText('日志 1')).not.toBeInTheDocument()
    await act(() => vi.advanceTimersByTimeAsync(90_000))
    expect(get).toHaveBeenCalledTimes(1)
  })
})
