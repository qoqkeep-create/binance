import { act, fireEvent, render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { ProfilePage } from '@/pages/profile'
import { api } from '@/shared/lib/api'
import { setTradingMode } from '@/shared/lib/tradingMode'
import { useAuthStore, useTradingStore } from '@/shared/store'

vi.mock('@/shared/lib/device', async (importOriginal) => ({
  ...await importOriginal<typeof import('@/shared/lib/device')>(),
  requestAppLayoutSync: vi.fn(),
}))

beforeEach(() => {
  localStorage.clear()
  useAuthStore.setState({ user: { id: '7', email: 'test@example.com' }, isAuthenticated: true })
  useTradingStore.getState().resetAccountState()
  vi.spyOn(api, 'get').mockImplementation(async path => {
    if (path.startsWith('/account/info')) return { balance: '100', stop_loss_amount: '20', today_pnl: '0' }
    if (path === '/account/version') return { version: 'test', lead_trading_enabled: true }
    if (path === '/account/profile') return { bound: false, display_name: '测试账户' }
    if (path === '/account/capital-collect-account') return { account_type: 'unknown' }
    throw new Error(`Unexpected request: ${path}`)
  })
})

afterEach(() => setTradingMode('ordinary'))

describe('operation log entry', () => {
  it.each(['ordinary', 'lead'] as const)('opens from more features in %s mode', async mode => {
    setTradingMode(mode)
    render(<QueryClientProvider client={new QueryClient()}><MemoryRouter initialEntries={['/profile']}>
      <Routes>
        <Route path="/profile" element={<ProfilePage />} />
        <Route path="/operation-logs" element={<h1>日志页面</h1>} />
      </Routes>
    </MemoryRouter></QueryClientProvider>)
    await act(async () => {})
    fireEvent.click(screen.getByRole('button', { name: '更多功能' }))
    expect(screen.getByRole('button', { name: '日志' })).toBeInTheDocument()
    if (mode === 'lead') {
      expect(screen.queryByRole('button', { name: '看盘计划' })).not.toBeInTheDocument()
      expect(screen.queryByRole('button', { name: '信号研究' })).not.toBeInTheDocument()
    } else {
      expect(screen.getByRole('button', { name: '看盘计划' })).toBeInTheDocument()
      expect(screen.getByRole('button', { name: '信号研究' })).toBeInTheDocument()
    }
    fireEvent.click(screen.getByRole('button', { name: '日志' }))
    expect(screen.getByRole('heading', { name: '日志页面' })).toBeInTheDocument()
  })
})
