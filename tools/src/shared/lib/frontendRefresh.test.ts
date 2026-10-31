import { beforeEach, describe, expect, it, vi } from 'vitest'
import script from '../../../public/frontend-refresh.js?raw'

const origin = 'https://example.com'

beforeEach(() => {
  document.body.innerHTML = '<p id="status"></p><button id="retry" hidden>重新加载</button>'
})

function runRefresh(registrations?: object[]) {
  const replace = vi.fn()
  const execute = new Function('navigator', 'location', 'document', script)
  execute(
    registrations ? { serviceWorker: { getRegistrations: async () => registrations } } : {},
    { origin, replace }, document,
  )
  return replace
}

describe('frontend cache recovery', () => {
  it('retires only this app worker, leaving other workers and browser data intact', async () => {
    const app = { scope: `${origin}/`, active: { scriptURL: `${origin}/sw.js` }, unregister: vi.fn().mockResolvedValue(true) }
    const unrelated = { scope: `${origin}/other/`, active: { scriptURL: `${origin}/other/sw.js` }, unregister: vi.fn() }
    localStorage.setItem('recovery-test', 'preserved')
    sessionStorage.setItem('recovery-test', 'lead')
    const replace = runRefresh([app, unrelated])
    await vi.waitFor(() => expect(replace).toHaveBeenCalledWith('/profile'))
    expect(app.unregister).toHaveBeenCalledTimes(1)
    expect(unrelated.unregister).not.toHaveBeenCalled()
    expect(localStorage.getItem('recovery-test')).toBe('preserved')
    expect(sessionStorage.getItem('recovery-test')).toBe('lead')
    localStorage.removeItem('recovery-test')
    sessionStorage.removeItem('recovery-test')
  })

  it('shows a retry on failure and navigates only after recovery succeeds', async () => {
    const unregister = vi.fn().mockRejectedValueOnce(new Error('busy')).mockResolvedValue(true)
    const replace = runRefresh([{ scope: `${origin}/`, installing: { scriptURL: `${origin}/sw.js` }, unregister }])
    const retry = document.getElementById('retry') as HTMLButtonElement
    await vi.waitFor(() => expect(retry).toBeVisible())
    expect(replace).not.toHaveBeenCalled()
    retry.click()
    await vi.waitFor(() => expect(replace).toHaveBeenCalledWith('/profile'))
    expect(unregister).toHaveBeenCalledTimes(2)
  })

  it('opens the current page when the browser has no service worker support', async () => {
    const replace = runRefresh()
    await vi.waitFor(() => expect(replace).toHaveBeenCalledWith('/profile'))
  })
})
