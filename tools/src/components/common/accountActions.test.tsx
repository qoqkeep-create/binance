import { act, fireEvent, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import AxiosMockAdapter from 'axios-mock-adapter'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '@/shared/lib/api/client'
import { getTradingMode, hasActiveTradingMutation, setTradingMode, trackTradingMutation } from '@/shared/lib/tradingMode'
import { useAuthStore, useTradingStore } from '@/shared/store'
import { TradingModeSwitch } from './TradingModeSwitch'
import { ApiUnbindButton } from './ApiUnbindButton'

const binding = { id: 'demo-api', alias: 'demo', apiKey: '', secretKey: '', passphrase: '', isActive: true, createdAt: 1 }
let mock: AxiosMockAdapter

beforeEach(() => {
  mock = new AxiosMockAdapter(apiClient)
  mock.onGet('/account/version').reply(200, { code: 0, data: { lead_trading_enabled: true } })
  useAuthStore.getState().login({ id: '7', email: 'demo@example.com' }, 'test-token')
  useTradingStore.getState().replaceApiConfigs([binding])
})

afterEach(() => {
  mock.restore()
  act(() => {
    setTradingMode('ordinary')
    useAuthStore.getState().logout()
  })
})

describe('account card actions', () => {
  it('switches and clears account data only after confirmation', async () => {
    const user = userEvent.setup()
    const client = new QueryClient()
    client.setQueryData(['private-account'], 'ordinary')
    render(<QueryClientProvider client={client}><TradingModeSwitch /></QueryClientProvider>)
    await user.click(await screen.findByRole('button', { name: '切换带单模式' }))
    expect(getTradingMode()).toBe('ordinary')
    await user.click(screen.getByRole('button', { name: '取消' }))
    expect(getTradingMode()).toBe('ordinary')
    expect(useTradingStore.getState().apiConfigs).toEqual([binding])
    await user.click(screen.getByRole('button', { name: '切换带单模式' }))
    await user.click(screen.getByRole('button', { name: '确认切换' }))
    expect(getTradingMode()).toBe('lead')
    expect(useTradingStore.getState().apiConfigs).toEqual([])
    expect(client.getQueryData(['private-account'])).toBeUndefined()
    await user.click(screen.getByRole('button', { name: '切换合约模式' }))
    await user.click(screen.getByRole('button', { name: '确认切换' }))
    expect(getTradingMode()).toBe('ordinary')
  })

  it('rechecks pending operations at confirmation time', async () => {
    const user = userEvent.setup()
    render(<QueryClientProvider client={new QueryClient()}><TradingModeSwitch /></QueryClientProvider>)
    await user.click(await screen.findByRole('button', { name: '切换带单模式' }))
    let finish!: () => void
    const pending = trackTradingMutation(() => new Promise<void>(resolve => { finish = resolve }))
    try {
      await user.click(screen.getByRole('button', { name: '确认切换' }))
      expect(getTradingMode()).toBe('ordinary')
      expect(screen.getByRole('dialog')).toBeInTheDocument()
      expect(useTradingStore.getState().apiConfigs).toEqual([binding])
    } finally {
      finish()
      await pending
    }
    await user.click(screen.getByRole('button', { name: '确认切换' }))
    expect(getTradingMode()).toBe('lead')
  })

  it('cancels unbinding without sending a request', async () => {
    const user = userEvent.setup()
    render(<ApiUnbindButton />)
    await user.click(screen.getByRole('button', { name: '解除 API 绑定' }))
    expect(mock.history.post).toHaveLength(0)
    await user.click(screen.getByRole('button', { name: '取消' }))
    expect(mock.history.post).toHaveLength(0)
    expect(useTradingStore.getState().apiConfigs).toEqual([binding])
  })

  it('submits once, prevents dismissal while pending and clears the confirmed binding', async () => {
    const user = userEvent.setup()
    const onUnbound = vi.fn()
    let finish!: (result: [number, object]) => void
    mock.onPost('/api/unbind').reply(() => new Promise(resolve => { finish = resolve }))
    render(<ApiUnbindButton onUnbound={onUnbound} />)
    await user.click(screen.getByRole('button', { name: '解除 API 绑定' }))
    const confirm = screen.getByRole('button', { name: '确认解除' })
    act(() => { fireEvent.click(confirm); fireEvent.click(confirm) })
    await waitFor(() => expect(mock.history.post).toHaveLength(1))
    expect(mock.history.post[0].headers?.['X-Trading-Mode']).toBe('ordinary')
    expect(hasActiveTradingMutation()).toBe(true)
    expect(screen.getByRole('button', { name: '取消' })).toBeDisabled()
    expect(screen.getByRole('button', { name: '解除中…' })).toBeDisabled()
    await user.keyboard('{Escape}')
    fireEvent.click(screen.getByRole('dialog').previousElementSibling!)
    expect(screen.getByRole('dialog')).toBeInTheDocument()
    await act(async () => finish([200, { code: 0, data: null }]))
    expect(onUnbound).toHaveBeenCalledTimes(1)
    expect(useTradingStore.getState().apiConfigs).toEqual([])
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(hasActiveTradingMutation()).toBe(false)
  })

  it('retains the binding and shows the server reason when unbinding is rejected', async () => {
    const user = userEvent.setup()
    mock.onPost('/api/unbind').reply(400, { code: 400, message: '仍有持仓，无法解除绑定' })
    const onUnbound = vi.fn()
    render(<ApiUnbindButton onUnbound={onUnbound} />)
    await user.click(screen.getByRole('button', { name: '解除 API 绑定' }))
    await user.click(screen.getByRole('button', { name: '确认解除' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('仍有持仓，无法解除绑定')
    expect(useTradingStore.getState().apiConfigs).toEqual([binding])
    expect(onUnbound).not.toHaveBeenCalled()
    expect(mock.history.post).toHaveLength(1)
    expect(screen.getByRole('button', { name: '取消' })).toBeEnabled()
  })

  it('ignores a successful unbind response from an earlier login of the same user', async () => {
    const user = userEvent.setup()
    let finish!: (result: [number, object]) => void
    mock.onPost('/api/unbind').reply(() => new Promise(resolve => { finish = resolve }))
    const onUnbound = vi.fn()
    render(<ApiUnbindButton onUnbound={onUnbound} />)
    await user.click(screen.getByRole('button', { name: '解除 API 绑定' }))
    await user.click(screen.getByRole('button', { name: '确认解除' }))
    await waitFor(() => expect(mock.history.post).toHaveLength(1))
    act(() => {
      useAuthStore.getState().logout()
      useAuthStore.getState().login({ id: '7', email: 'demo@example.com' }, 'new-test-token')
      useTradingStore.getState().replaceApiConfigs([{ ...binding, id: 'new-api' }])
    })
    await act(async () => finish([200, { code: 0, data: null }]))
    expect(onUnbound).not.toHaveBeenCalled()
    expect(useTradingStore.getState().apiConfigs[0]?.id).toBe('new-api')
  })
})
