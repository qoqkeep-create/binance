import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'

import { LoginPage } from './index'
import { api } from '@/shared/lib/api'
import { useAuthStore } from '@/shared/store/authStore'

vi.mock('@/shared/lib/api', () => ({
  api: {
    get: vi.fn(),
    post: vi.fn(),
  },
  ApiError: class ApiError extends Error {},
  tokenManager: {
    get: vi.fn(),
    set: vi.fn(),
    remove: vi.fn(),
  },
}))

vi.mock('@/shared/lib/device', () => ({
  primeAppViewport: vi.fn().mockResolvedValue(undefined),
}))

describe('LoginPage', () => {
  beforeEach(() => {
    localStorage.clear()
    useAuthStore.setState({ user: null, isAuthenticated: false })
    vi.mocked(api.get).mockResolvedValue({ open_registration: false })
    vi.mocked(api.post).mockImplementation(async (path: string) => {
      if (path !== '/auth/login') return undefined
      return {
        token: 'access-token',
        user_id: '42',
        email: 'user@example.com',
        preflight_completed_at: '2026-09-11T08:00:00Z',
      }
    })
  })

  it('stores the canonical server identity instead of the raw login input', async () => {
    const user = userEvent.setup()
    render(
      <MemoryRouter>
        <LoginPage />
      </MemoryRouter>,
    )

    await user.type(screen.getByLabelText('账号'), ' User@Example.COM ')
    await user.type(screen.getByLabelText('密码'), 'password123')
    await user.click(screen.getByRole('button', { name: '登录' }))

    await waitFor(() => {
      expect(useAuthStore.getState().user).toEqual({
        id: '42',
        email: 'user@example.com',
        preflightCompletedAt: '2026-09-11T08:00:00Z',
      })
    })
  })
})
