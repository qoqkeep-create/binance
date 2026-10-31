import { act, render } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { SignalsPage } from './index'
import { api } from '@/shared/lib/api'

vi.mock('@/shared/lib/device', async original => ({
  ...await original<typeof import('@/shared/lib/device')>(), isStandaloneMode: () => false,
}))
beforeEach(() => {
  vi.useFakeTimers()
  localStorage.clear()
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
  vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(true)
  vi.spyOn(api, 'get').mockResolvedValue([])
})
afterEach(() => vi.useRealTimers())

describe('signal polling visibility', () => {
  it.each(['hidden', 'offline'])('pauses while %s and merges simultaneous resume events', async cause => {
    render(<MemoryRouter><SignalsPage /></MemoryRouter>)
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
      window.dispatchEvent(new Event('online'))
      window.dispatchEvent(new Event('app:resume'))
    })
    expect(api.get).toHaveBeenCalledTimes(2)
  })
})
