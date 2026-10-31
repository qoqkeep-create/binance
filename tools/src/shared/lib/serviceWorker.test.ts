import { describe, expect, it, vi } from 'vitest'
import script from '../../sw.js?raw'

function workerHarness() {
  const listeners = new Map<string, (event: object) => void>()
  const match = vi.fn().mockResolvedValue(undefined)
  const fetch = vi.fn().mockResolvedValue('network')
  const worker = {
    location: { origin: 'https://example.com' },
    skipWaiting: vi.fn().mockResolvedValue(undefined),
    clients: { claim: vi.fn().mockResolvedValue(undefined) },
    addEventListener: (type: string, listener: (event: object) => void) => listeners.set(type, listener),
  }
  new Function('self', 'caches', 'fetch', script)(worker, { match }, fetch)
  const dispatch = (url: string, method = 'GET', mode = 'cors') => {
    const respondWith = vi.fn()
    listeners.get('fetch')?.({ request: { url, method, mode }, respondWith })
    return respondWith
  }
  return { listeners, match, fetch, worker, dispatch }
}

describe('service worker navigation policy', () => {
  it.each([
    ['https://example.com/index.html', 'GET', 'cors'],
    ['https://example.com/api/account/info', 'GET', 'cors'],
    ['https://example.com/v1/trade/open', 'POST', 'cors'],
    ['https://example.com/assets/index-abc123.js', 'POST', 'cors'],
    ['https://another.example/assets/index-abc123.js', 'GET', 'cors'],
  ])('never serves cached HTML, private requests or writes: %s %s', (url, method, mode) => {
    const harness = workerHarness()
    expect(harness.dispatch(url, method, mode)).not.toHaveBeenCalled()
    expect(harness.match).not.toHaveBeenCalled()
    expect(harness.fetch).not.toHaveBeenCalled()
  })

  it.each(['/', '/profile', '/index.html'])('always fetches a fresh document on navigation: %s', async path => {
    const harness = workerHarness()
    harness.match.mockResolvedValue('stale HTML')
    const respond = harness.dispatch(`https://example.com${path}`, 'GET', 'navigate')
    await expect(respond.mock.calls[0][0]).resolves.toBe('network')
    expect(harness.fetch).toHaveBeenCalledWith(expect.any(Object), { cache: 'no-store' })
    expect(harness.match).not.toHaveBeenCalled()
  })

  it('preserves an old immutable chunk for an already open page', async () => {
    const harness = workerHarness()
    harness.match.mockResolvedValue('old immutable asset')
    const respond = harness.dispatch('https://example.com/assets/index-old123.js')
    await expect(respond.mock.calls[0][0]).resolves.toBe('old immutable asset')
    expect(harness.fetch).not.toHaveBeenCalled()
  })

  it('does not conceal a navigation outage with an obsolete app shell', async () => {
    const harness = workerHarness()
    harness.match.mockResolvedValue('stale HTML')
    harness.fetch.mockRejectedValue(new Error('offline'))
    const respond = harness.dispatch('https://example.com/profile', 'GET', 'navigate')
    await expect(respond.mock.calls[0][0]).rejects.toThrow('offline')
    expect(harness.match).not.toHaveBeenCalled()
  })

  it('uses the network if legacy browser storage fails', async () => {
    const harness = workerHarness()
    harness.match.mockRejectedValue(new Error('storage unavailable'))
    const respond = harness.dispatch('https://example.com/assets/index-new123.css')
    await expect(respond.mock.calls[0][0]).resolves.toBe('network')
    expect(harness.fetch).toHaveBeenCalledTimes(1)
  })

  it('installs and activates without downloading assets or deleting old caches', async () => {
    const harness = workerHarness()
    const waitUntil = vi.fn()
    harness.listeners.get('install')?.({ waitUntil })
    harness.listeners.get('activate')?.({ waitUntil })
    await Promise.all(waitUntil.mock.calls.map(([promise]) => promise))
    expect(harness.worker.skipWaiting).toHaveBeenCalledTimes(1)
    expect(harness.worker.clients.claim).toHaveBeenCalledTimes(1)
    expect(harness.match).not.toHaveBeenCalled()
    expect(harness.fetch).not.toHaveBeenCalled()
  })
})
