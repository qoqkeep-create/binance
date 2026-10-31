import { act, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import { HoldingsPage } from './index'
import { api, ApiError } from '@/shared/lib/api'
import { useAuthStore } from '@/shared/store/authStore'
import { useToastStore } from '@/shared/store/toastStore'

vi.mock('../trading/KlineChartCard', () => ({ KlineChartCard: () => null }))

vi.mock('@/shared/lib/device', async (importOriginal) => ({
  ...await importOriginal<typeof import('@/shared/lib/device')>(),
  isStandaloneMode: () => false,
  requestAppLayoutSync: vi.fn(),
}))

function position(id: number, origin = 'exchange_external') {
  return {
    id,
    position_origin: origin,
    symbol: id === 1 ? 'BTCUSDT' : 'ETHUSDT',
    side: 0,
    position_amount: '100',
    pnl: '-5',
    pnl_ratio: '-5',
    open_price: '100',
    current_price: '95',
    exchange_size: '1',
    stop_loss_price: '80',
    stop_loss_amount: '20',
    market_stop_set: true,
    market_stop_price: '80',
    leverage: '5',
    strategy_status: 0,
    latest_strategy_error: '',
    can_bind_strategy: false,
    strategy_snapshot_id: null,
    created_at: '2026-09-30T08:00:00Z',
  }
}

let activePositions: ReturnType<typeof position>[]
let historyPositions: Array<Record<string, unknown>>

function renderHoldings(tab = 'positions') {
  return render(
    <MemoryRouter initialEntries={[{ pathname: '/holdings', state: { activeTab: tab } }]}>
      <HoldingsPage />
    </MemoryRouter>,
  )
}

describe('holdings manual positions', () => {
  beforeEach(() => {
    localStorage.clear()
    useAuthStore.setState({ user: { id: '42', email: 'user@example.com' }, isAuthenticated: true })
    useToastStore.setState({ message: '', visible: false })
    activePositions = [position(1)]
    historyPositions = [{ ...position(1), close_price: '95', fee: '-1', funding_fee: '0', closed_at: '2026-09-30T09:00:00Z' }]
    vi.spyOn(api, 'get').mockImplementation(async (path) => {
      if (path === '/position/list') return activePositions
      if (path.startsWith('/trade/market/prices')) return { prices: {} }
      if (path.startsWith('/position/history')) {
        return {
          items: historyPositions,
          pagination: { page: 1, page_size: 20, total: 1, has_next: false, has_previous: false },
        }
      }
      throw new Error(`Unexpected request: ${path}`)
    })
  })

  it('labels only external positions and allows closing without a strategy or exchange entry ID', async () => {
    activePositions.push(position(2, 'web'))
    renderHoldings()

    expect(await screen.findByText('手动仓')).toBeInTheDocument()
    expect(screen.getAllByText('手动仓')).toHaveLength(1)
    expect(screen.getAllByRole('button', { name: '立即平仓' })).toHaveLength(2)
    expect(screen.getAllByRole('button', { name: '设置保本损' })).toHaveLength(1)
    expect(screen.getAllByRole('button', { name: '手动止盈' })).toHaveLength(1)
    expect(screen.getByText(/^接管时间：/)).toBeInTheDocument()
    expect(screen.getByText(/^开仓时间：/)).toBeInTheDocument()
    for (const button of screen.getAllByRole('button', { name: '立即平仓' })) {
      expect(button).toBeEnabled()
    }
  })

  it('uses the position error summary without polling full strategy logs', async () => {
    vi.useFakeTimers()
    try {
      activePositions = [{ ...position(1, 'web'), strategy_status: 1, latest_strategy_error: '策略保护未确认' }]
      renderHoldings()
      await act(async () => { await Promise.resolve() })
      expect(screen.getByText('策略保护未确认')).toBeInTheDocument()
      await act(async () => { await vi.advanceTimersByTimeAsync(16_000) })
      const requests = vi.mocked(api.get).mock.calls.map(call => call[0])
      expect(requests.some(path => path.startsWith('/strategy/log'))).toBe(false)
    } finally {
      vi.useRealTimers()
    }
  })

  it('closes the selected manual position by its local ID after confirmation', async () => {
    const user = userEvent.setup()
    const post = vi.spyOn(api, 'post').mockImplementation(async () => {
      activePositions = []
      return { pnl: '-5', pnl_ratio: '-5' }
    })
    renderHoldings()
    await user.click(await screen.findByRole('button', { name: '立即平仓' }))
    const dialog = screen.getByRole('dialog', { name: '立即平仓' })
    expect(within(dialog).getByText('BTCUSDT · 多单 · 手动仓')).toBeInTheDocument()
    expect(post).not.toHaveBeenCalled()
    await user.click(within(dialog).getByRole('button', { name: '确认' }))

    expect(post).toHaveBeenCalledExactlyOnceWith('/position/close', { position_id: 1 })
    await waitFor(() => expect(screen.queryByText('BTCUSDT')).not.toBeInTheDocument())
    expect(useToastStore.getState().message).toBe('已平仓\n亏损-5U')
  })

  it('does not present missing close PnL as a confirmed zero profit', async () => {
    const user = userEvent.setup()
    vi.spyOn(api, 'post').mockImplementation(async () => {
      activePositions = []
      return { pnl: null, pnl_ratio: null }
    })
    renderHoldings()
    await user.click(await screen.findByRole('button', { name: '立即平仓' }))
    await user.click(screen.getByRole('button', { name: '确认' }))

    await waitFor(() => expect(screen.queryByText('BTCUSDT')).not.toBeInTheDocument())
    expect(useToastStore.getState().message).toBe('已平仓，盈亏待核对')
  })

  it('includes manual positions in close-all without substituting floating PnL for unknown settlement', async () => {
    const user = userEvent.setup()
    activePositions.push(position(2, 'web'))
    vi.spyOn(api, 'post').mockImplementation(async (_path, payload) => {
      const id = (payload as { position_id: number }).position_id
      activePositions = activePositions.filter(row => row.id !== id)
      return { pnl: id === 1 ? null : '-5' }
    })
    renderHoldings()
    await user.click(await screen.findByRole('button', { name: /^全部平仓/ }))
    await user.click(screen.getByRole('button', { name: '确认' }))

    await waitFor(() => expect(screen.queryByText('BTCUSDT')).not.toBeInTheDocument())
    expect(api.post).toHaveBeenCalledWith('/position/close', { position_id: 1 })
    expect(api.post).toHaveBeenCalledWith('/position/close', { position_id: 2 })
    expect(useToastStore.getState().message).toBe('已全部平仓\n部分盈亏待核对')
  })

  it('keeps manual take-profit available without offering break-even or automatic strategies', async () => {
    renderHoldings()
    expect(await screen.findByRole('button', { name: '设置' })).toBeEnabled()
    expect(screen.queryByRole('button', { name: '设置保本损' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /添加.*策略|添加自动止盈/ })).not.toBeInTheDocument()
  })

  it('does not invent a default risk amount when the manual position has no valid setting', async () => {
    activePositions[0].stop_loss_amount = '0'
    renderHoldings()
    expect(await screen.findByText('止损额度未设置')).toBeInTheDocument()
    expect(screen.queryByText('止损30U')).not.toBeInTheDocument()
  })

  it('keeps an unconfirmed close visible and reports the server message without claiming success', async () => {
    const user = userEvent.setup()
    const message = '平仓请求已提交，但交易所尚未确认仓位归零，请刷新后重试'
    vi.spyOn(api, 'post').mockRejectedValue(new ApiError(message, 400))
    renderHoldings()
    await user.click(await screen.findByRole('button', { name: '立即平仓' }))
    await user.click(screen.getByRole('button', { name: '确认' }))

    await waitFor(() => expect(useToastStore.getState().message).toBe(message))
    expect(screen.getByText('手动仓')).toBeInTheDocument()
    expect(screen.getAllByText('BTCUSDT').length).toBeGreaterThan(0)
    expect(useToastStore.getState().message).not.toContain('已平仓')
  })

  it('blocks duplicate close submissions while the first request is pending', async () => {
    const user = userEvent.setup()
    let finishClose: (value: { pnl: string; pnl_ratio: string }) => void = () => undefined
    const post = vi.spyOn(api, 'post').mockReturnValue(new Promise(resolve => { finishClose = resolve }))
    renderHoldings()
    await user.click(await screen.findByRole('button', { name: '立即平仓' }))
    await user.click(screen.getByRole('button', { name: '确认' }))
    const pendingButton = screen.getByRole('button', { name: '平仓中...' })
    expect(pendingButton).toBeDisabled()
    expect(screen.getByRole('button', { name: '取消' })).toBeDisabled()
    await user.click(pendingButton)
    expect(post).toHaveBeenCalledTimes(1)

    activePositions = []
    await act(async () => finishClose({ pnl: '-5', pnl_ratio: '-5' }))
  })

  it('preserves the manual-position label in history', async () => {
    renderHoldings('history')
    expect(await screen.findByText('手动仓')).toBeInTheDocument()
    expect(screen.getByText('BTCUSDT')).toBeInTheDocument()
    expect(screen.getByText(/^接管时间/)).toBeInTheDocument()
    expect(screen.queryByText(/^开仓时间/)).not.toBeInTheDocument()
  })

  it('shows unknown manual history financials as unavailable instead of zero', async () => {
    Object.assign(historyPositions[0], {
      pnl: null, pnl_ratio: null, realized_pnl: null, close_price: null, fee: null, funding_fee: null,
    })
    renderHoldings('history')
    await screen.findByText('手动仓')

    for (const label of ['平仓盈亏', '盈亏比', '平仓价格', '手续费']) {
      const detail = screen.getByText(label).parentElement as HTMLElement
      expect(within(detail).getByText('--')).toBeInTheDocument()
    }
    expect(screen.queryByText('+0U')).not.toBeInTheDocument()
  })

  it.each(['web', 'exchange_external'])('preserves known zero values in %s history', async (origin) => {
    Object.assign(historyPositions[0], { position_origin: origin, pnl: '0', fee: '0', funding_fee: '0' })
    renderHoldings('history')
    await screen.findByText('BTCUSDT')

    expect(within(screen.getByText('平仓盈亏').parentElement as HTMLElement).getByText('+0U')).toBeInTheDocument()
    expect(within(screen.getByText('盈亏比').parentElement as HTMLElement).getByText('0.0:1')).toBeInTheDocument()
    expect(within(screen.getByText('平仓价格').parentElement as HTMLElement).getByText('95')).toBeInTheDocument()
    expect(within(screen.getByText('手续费').parentElement as HTMLElement).getByText('0U')).toBeInTheDocument()
  })

  it('does not show partial known fees as the complete manual-history fee', async () => {
    historyPositions[0].funding_fee = null
    renderHoldings('history')
    await screen.findByText('手动仓')

    expect(within(screen.getByText('手续费').parentElement as HTMLElement).getByText('--')).toBeInTheDocument()
    expect(within(screen.getByText('平仓盈亏').parentElement as HTMLElement).getByText('-5U')).toBeInTheDocument()
  })
})
