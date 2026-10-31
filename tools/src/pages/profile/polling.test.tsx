import { act, render } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ProfilePage } from './index'
import { api } from '@/shared/lib/api'
import { useAuthStore, useTradingStore } from '@/shared/store'

vi.mock('@/shared/lib/device', async original => ({
  ...await original<typeof import('@/shared/lib/device')>(), isStandaloneMode: () => false, requestAppLayoutSync: vi.fn(),
}))

beforeEach(() => {
  vi.useFakeTimers()
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
  vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(true)
  localStorage.clear()
  useAuthStore.getState().login({ id: '1', email: 'poll@example.com' }, 'placeholder-token')
  useTradingStore.getState().resetAccountState()
  vi.spyOn(api, 'get').mockImplementation(async url => {
    if (url.startsWith('/account/info')) return { balance: '100', spot_balance: '0', funding_balance: '0', stop_loss_amount: '120' }
    if (url === '/account/profile') return { bound: false }
    if (url === '/account/version') return { version: 'test' }
    return {}
  })
})
afterEach(() => vi.useRealTimers())

describe('profile polling visibility', () => {
  it.each(['hidden', 'offline'])('pauses private polling while %s and resumes once', async cause => {
    render(<QueryClientProvider client={new QueryClient()}><MemoryRouter><ProfilePage /></MemoryRouter></QueryClientProvider>)
    await act(async () => {})
    vi.mocked(api.get).mockClear()
    if (cause === 'hidden') vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('hidden')
    else vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(false)
    await act(async () => vi.advanceTimersByTimeAsync(60_000))
    expect(api.get).not.toHaveBeenCalled()
    vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
    vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(true)
    await act(async () => {
      document.dispatchEvent(new Event('visibilitychange'))
      window.dispatchEvent(new Event('app:resume'))
    })
    expect(vi.mocked(api.get).mock.calls.filter(call => call[0] === '/account/info')).toHaveLength(1)
    expect(vi.mocked(api.get).mock.calls.filter(call => call[0] === '/account/profile')).toHaveLength(1)
  })
})
