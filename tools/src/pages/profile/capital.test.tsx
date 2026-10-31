import { act, fireEvent, render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ProfilePage } from './index'
import { api } from '@/shared/lib/api'
import { useAuthStore, useTradingStore } from '@/shared/store'

vi.mock('@/shared/lib/device', async original => ({
  ...await original<typeof import('@/shared/lib/device')>(), isStandaloneMode: () => false, requestAppLayoutSync: vi.fn(),
}))

let balance: string
let pending: boolean

beforeEach(() => {
  vi.useFakeTimers()
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
  vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(true)
  localStorage.clear()
  useAuthStore.getState().login({ id: '1', email: 'capital@example.com' }, 'placeholder-token')
  useTradingStore.getState().resetAccountState()
  balance = '900'
  pending = true
  vi.spyOn(api, 'get').mockImplementation(async url => {
    if (url.startsWith('/account/info')) return {
      balance, spot_balance: '0', funding_balance: '0', stop_loss_amount: '200', pending_capital_collection: pending,
    }
    if (url === '/account/profile') return { bound: true, display_name: 'Test' }
    if (url === '/account/version') return { version: 'test' }
    if (url === '/account/capital-collect-account') return { account_type: 'sub' }
    return {}
  })
})
afterEach(() => { vi.restoreAllMocks(); vi.useRealTimers() })

async function openProfile() {
  render(<QueryClientProvider client={new QueryClient()}><MemoryRouter><ProfilePage /></MemoryRouter></QueryClientProvider>)
  await act(async () => {})
}

describe('current balance collection', () => {
  it('keeps collection disabled below the cap while offering receipt verification separately', async () => {
    await openProfile()
    expect(screen.getByRole('button', { name: '归集余额' })).toBeDisabled()
    expect(screen.getByRole('button', { name: '核对上次归集' })).toBeEnabled()
  })

  it('does not keep the previous pending panel as the button state after balances refresh', async () => {
    balance = '1100'
    const request = vi.spyOn(api, 'post').mockResolvedValue({
      status: 'ready', pending_collection: { status: 'collection_pending', collection_id: 22 },
    })
    await openProfile()
    await act(async () => { fireEvent.click(screen.getByRole('button', { name: '归集余额' })) })
    fireEvent.click(screen.getByRole('button', { name: '关闭' }))
    balance = '900'
    pending = false
    await act(async () => { await vi.advanceTimersByTimeAsync(30_000) })
    expect(request).toHaveBeenCalledOnce()
    expect(screen.getByRole('button', { name: '归集余额' })).toBeDisabled()
    expect(screen.queryByRole('button', { name: '核对上次归集' })).not.toBeInTheDocument()
  })
})
