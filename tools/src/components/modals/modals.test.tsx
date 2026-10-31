import { act, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useState } from 'react'
import { describe, expect, it, vi } from 'vitest'

import { CapitalNormalizationModal } from './CapitalNormalizationModal'
import { ApiBindModal } from './ApiBindModal'
import { ConfirmModal } from './ConfirmModal'
import { OpenPositionConfirmModal } from './OpenPositionConfirmModal'
import { roundUpStopLoss } from './StopLossSettingsModal'
import { api } from '@/shared/lib/api'
import { useAuthStore, useTradingStore } from '@/shared/store'
import { useToastStore } from '@/shared/store/toastStore'
import {
  ACCOUNT_BINDING_CHANGED_EVENT,
  getAccountSessionRevision,
} from '@/shared/lib/accountBalanceState'

function ConfirmHarness() {
  const [open, setOpen] = useState(false)
  return (
    <>
      <button onClick={() => setOpen(true)}>打开</button>
      <ConfirmModal
        isOpen={open}
        onClose={() => setOpen(false)}
        onConfirm={() => setOpen(false)}
        title="删除策略"
      >
        此操作不可撤销
      </ConfirmModal>
    </>
  )
}

describe('critical confirmation modals', () => {
  it('shows both futures-to-spot and spot-to-master amounts with individual receipts', () => {
    render(<CapitalNormalizationModal
      isOpen mode="manual_sweep" loading={false} following
      state={{ status: 'collection_pending', collection_id: 22, futures_collect: '405.28', transfer_amount: '405.28', completed_steps: ['futures_collect'] }}
      onClose={vi.fn()} onNormalize={vi.fn()} onContinue={vi.fn()}
    />)
    expect(screen.getByText('合约 -> 现货')).toBeInTheDocument()
    expect(screen.getByText('现货 -> 主账户')).toBeInTheDocument()
    expect(screen.getAllByText('405.28 U')).toHaveLength(2)
    expect(screen.getAllByLabelText('已完成')).toHaveLength(1)
    expect(screen.getByRole('button', { name: '自动确认中...' })).toBeDisabled()
  })

  it('always rounds the stop-loss amount upward to the configured step', () => {
    expect(roundUpStopLoss(0)).toBe(1)
    expect(roundUpStopLoss(19.01)).toBe(20)
    expect(roundUpStopLoss(20.01)).toBe(25)
    expect(roundUpStopLoss(99.99)).toBe(100)
    expect(roundUpStopLoss(100.01)).toBe(110)
  })

  it('traps focus, closes on Escape, and restores the trigger focus', async () => {
    const user = userEvent.setup()
    render(<ConfirmHarness />)
    const trigger = screen.getByRole('button', { name: '打开' })
    await user.click(trigger)

    const dialog = screen.getByRole('dialog', { name: '删除策略' })
    expect(dialog).toHaveAttribute('aria-modal', 'true')
    const cancel = screen.getByRole('button', { name: '取消' })
    const confirm = screen.getByRole('button', { name: '确认' })
    await waitFor(() => expect(cancel).toHaveFocus())
    await user.tab()
    expect(confirm).toHaveFocus()
    await user.tab()
    expect(cancel).toHaveFocus()
    await user.keyboard('{Escape}')
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(trigger).toHaveFocus()
  })

  it('exposes the order confirmation title and blocks Escape while submitting', async () => {
    const onClose = vi.fn()
    const user = userEvent.setup()
    render(
      <OpenPositionConfirmModal
        isOpen
        loading
        onClose={onClose}
        onConfirm={vi.fn()}
        direction="long"
        tradingPair="BTCUSDT"
        position={100}
        fee={0.05}
        stopLossAmount={20}
        includeFeesInStopLoss
      />,
    )

    expect(screen.getByRole('dialog', { name: '开仓确认' })).toHaveAttribute('aria-modal', 'true')
    expect(screen.getByRole('button', { name: '关闭' })).toBeDisabled()
    await user.keyboard('{Escape}')
    expect(onClose).not.toHaveBeenCalled()
  })

  it('shows the planned capital directions in an accessible dialog', () => {
    render(
      <CapitalNormalizationModal
        isOpen
        loading={false}
        state={{
          status: 'normalization_required',
          minimum_open_balance: '150',
          maximum_futures_balance: '500',
          futures_balance: '100',
          funding_to_futures: '30',
          spot_to_futures: '20',
        }}
        onClose={vi.fn()}
        onNormalize={vi.fn()}
        onContinue={vi.fn()}
      />,
    )

    expect(screen.getByRole('dialog', { name: '调整账户资金' })).toHaveAttribute('aria-modal', 'true')
    expect(screen.getByText('资金 -> 合约')).toBeInTheDocument()
    expect(screen.getByText('现货 -> 合约')).toBeInTheDocument()
    expect(screen.getByText('500.00 U')).toBeInTheDocument()
  })

  it('explains why a sweep from an old API binding cannot continue', () => {
    render(
      <CapitalNormalizationModal
        isOpen
        loading={false}
        mode="manual_sweep"
        state={{
          status: 'blocked',
          reason: 'capital_sweep_binding_mismatch',
        }}
        onClose={vi.fn()}
        onNormalize={vi.fn()}
        onContinue={vi.fn()}
      />,
    )

    expect(screen.getByRole('dialog', { name: '暂时无法归集' })).toBeInTheDocument()
    expect(screen.getByText(/旧 API 绑定留下的未确认资金流水/)).toBeInTheDocument()
  })

  it('does not apply API status from an earlier login of the same account', async () => {
    useAuthStore.getState().logout()
    useAuthStore.getState().login({ id: '7', email: 'user@example.com' }, 'token-1')
    let resolveRequest: (value: { alias: string; status: number }) => void = () => undefined
    const request = new Promise<{ alias: string; status: number }>((resolve) => {
      resolveRequest = resolve
    })
    vi.spyOn(api, 'get').mockReturnValueOnce(request)
    const onBoundChange = vi.fn()

    render(<ApiBindModal isOpen onClose={vi.fn()} onBoundChange={onBoundChange} />)
    await waitFor(() => expect(api.get).toHaveBeenCalledWith('/api/info?validate=1', expect.any(Object)))

    useAuthStore.getState().logout()
    useAuthStore.getState().login({ id: '7', email: 'user@example.com' }, 'token-2')
    await act(async () => resolveRequest({ alias: 'stale-api', status: 1 }))

    expect(useTradingStore.getState().apiConfigs).toEqual([])
    expect(onBoundChange).not.toHaveBeenCalled()
    expect(screen.queryByText('stale-api')).not.toBeInTheDocument()
  })

  it('does not continue binding after the precheck login session expires', async () => {
    useAuthStore.getState().logout()
    useAuthStore.getState().login({ id: '7', email: 'user@example.com' }, 'token-1')
    let resolvePrecheck: (value: null) => void = () => undefined
    const precheck = new Promise<null>((resolve) => {
      resolvePrecheck = resolve
    })
    vi.spyOn(api, 'get').mockReturnValueOnce(precheck)
    const post = vi.spyOn(api, 'post')
    const user = userEvent.setup()

    render(<ApiBindModal isOpen onClose={vi.fn()} />)
    await waitFor(() => expect(api.get).toHaveBeenCalledTimes(1))
    await act(async () => resolvePrecheck(null))
    await user.type(await screen.findByPlaceholderText('请输入API Key'), 'api-key')
    await user.type(screen.getByPlaceholderText('请输入Secret Key'), 'secret-key')
    await user.type(screen.getByPlaceholderText('请输入API别名，便于区分和记忆'), 'primary')

    let resolveBindPrecheck: (value: null) => void = () => undefined
    const bindPrecheck = new Promise<null>((resolve) => {
      resolveBindPrecheck = resolve
    })
    vi.spyOn(api, 'get').mockReturnValueOnce(bindPrecheck)
    await user.click(screen.getByRole('button', { name: '确认绑定' }))
    await waitFor(() => expect(api.get).toHaveBeenCalledTimes(2))

    useAuthStore.getState().logout()
    useAuthStore.getState().login({ id: '7', email: 'user@example.com' }, 'token-2')
    await act(async () => resolveBindPrecheck(null))

    expect(post).not.toHaveBeenCalled()
  })

  it('invalidates cached account data after a successful API binding change', async () => {
    useAuthStore.getState().logout()
    useAuthStore.getState().login({ id: '7', email: 'user@example.com' }, 'token-1')
    window.localStorage.setItem('tradetools:profile:account:v2:7', '{"balance":999}')
    const previousRevision = getAccountSessionRevision()
    vi.spyOn(api, 'get')
      .mockResolvedValueOnce(null)
      .mockResolvedValueOnce(null)
      .mockResolvedValueOnce({ alias: 'primary', status: 1 })
    vi.spyOn(api, 'post').mockResolvedValue({})
    const onClose = vi.fn()
    const bindingChanged = vi.fn()
    window.addEventListener(ACCOUNT_BINDING_CHANGED_EVENT, bindingChanged)
    const user = userEvent.setup()

    render(<ApiBindModal isOpen onClose={onClose} />)
    await waitFor(() => expect(api.get).toHaveBeenCalledTimes(1))
    await user.type(await screen.findByPlaceholderText('请输入API Key'), 'api-key')
    await user.type(screen.getByPlaceholderText('请输入Secret Key'), 'secret-key')
    await user.type(screen.getByPlaceholderText('请输入API别名，便于区分和记忆'), 'primary')
    await user.click(screen.getByRole('button', { name: '确认绑定' }))

    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1))
    expect(window.localStorage.getItem('tradetools:profile:account:v2:7')).toBeNull()
    expect(getAccountSessionRevision()).toBe(previousRevision + 1)
    expect(bindingChanged).toHaveBeenCalledTimes(1)
    expect(useTradingStore.getState().apiConfigs[0]?.alias).toBe('primary')
    window.removeEventListener(ACCOUNT_BINDING_CHANGED_EVENT, bindingChanged)
  })

  it('keeps a successful API binding when the follow-up status refresh fails', async () => {
    useAuthStore.getState().logout()
    useAuthStore.getState().login({ id: '7', email: 'user@example.com' }, 'token-1')
    vi.spyOn(api, 'get')
      .mockResolvedValueOnce(null)
      .mockResolvedValueOnce(null)
      .mockRejectedValueOnce(new Error('temporary refresh failure'))
    vi.spyOn(api, 'post').mockResolvedValue({})
    const onClose = vi.fn()
    const onBoundChange = vi.fn()
    const bindingChanged = vi.fn()
    window.addEventListener(ACCOUNT_BINDING_CHANGED_EVENT, bindingChanged)
    const user = userEvent.setup()

    render(<ApiBindModal isOpen onClose={onClose} onBoundChange={onBoundChange} />)
    await waitFor(() => expect(api.get).toHaveBeenCalledTimes(1))
    onBoundChange.mockClear()
    await user.type(await screen.findByPlaceholderText('请输入API Key'), 'api-key')
    await user.type(screen.getByPlaceholderText('请输入Secret Key'), 'secret-key')
    await user.type(screen.getByPlaceholderText('请输入API别名，便于区分和记忆'), 'primary')
    await user.click(screen.getByRole('button', { name: '确认绑定' }))

    await waitFor(() => expect(api.get).toHaveBeenCalledTimes(3))
    expect(onClose).toHaveBeenCalledTimes(1)
    expect(onBoundChange).toHaveBeenCalledTimes(1)
    expect(bindingChanged).toHaveBeenCalledTimes(1)
    expect(useTradingStore.getState().apiConfigs[0]?.alias).toBe('primary')
    expect(useToastStore.getState().message).toBe('API绑定成功')
    window.removeEventListener(ACCOUNT_BINDING_CHANGED_EVENT, bindingChanged)
  })
})
