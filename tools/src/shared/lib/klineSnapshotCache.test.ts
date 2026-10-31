import { beforeEach, describe, expect, it, vi } from 'vitest'

import { api } from '@/shared/lib/api'
import {
  canUpdateLatestKline,
  getKlineCache,
  mergeKlineCandle,
  reconcileKlineSnapshot,
  setKlineCache,
} from './klineCache'
import {
  fetchKlineSnapshot,
  fetchOriginKlineSnapshot,
  prefetchMissingKlineIntervals,
} from './klineSnapshotCache'

vi.mock('@/shared/lib/api', () => ({ api: { get: vi.fn() } }))

function snapshotFor(interval: string) {
  return {
    candles: [
      {
        t: interval === '15m' ? 1 : interval === '1h' ? 2 : 3,
        o: '100',
        h: '110',
        l: '90',
        c: '105',
        v: '12',
      },
    ],
  }
}

function responseFor(interval: string): Response {
  return responseWith(snapshotFor(interval).candles)
}

function responseWith(candles: unknown[]): Response {
  return {
    ok: true,
    json: async () => ({
      code: 200,
      data: { candles },
    }),
  } as Response
}

describe('Kline snapshot cache', () => {
  beforeEach(() => {
    localStorage.clear()
    vi.restoreAllMocks()
    vi.clearAllMocks()
  })

  it('loads public market data without cookies or authorization', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(responseFor('15m'))

    await fetchKlineSnapshot('btcusdt', '15m', 300)

    expect(fetchMock).toHaveBeenCalledWith('/v1/trade/market/klines-public/BTCUSDT/15m', {
      credentials: 'omit',
      headers: { Accept: 'application/json' },
      signal: expect.any(AbortSignal),
    })
  })

  it('bypasses the edge cache through the authenticated origin route when requested', async () => {
    vi.mocked(api.get).mockResolvedValue(snapshotFor('1h'))

    await fetchOriginKlineSnapshot('btcusdt', '1h', 300)

    expect(api.get).toHaveBeenCalledWith(
      '/trade/market/klines?symbol=BTCUSDT&interval=1h&limit=300&fresh=1',
      { suppressConnectionError: true, disableRetry: true, timeout: 12_000 }
    )
  })

  it('waits for the active interval and prefetches missing intervals sequentially', async () => {
    let concurrent = 0
    let maxConcurrent = 0
    const requested: string[] = []
    vi.spyOn(globalThis, 'fetch').mockImplementation(async input => {
      const url = String(input)
      const interval = url.split('/').pop() || ''
      requested.push(interval)
      concurrent += 1
      maxConcurrent = Math.max(maxConcurrent, concurrent)
      await new Promise(resolve => setTimeout(resolve, 1))
      concurrent -= 1
      return responseFor(interval)
    })

    await prefetchMissingKlineIntervals('BTCUSDT', ['15m', '1h', '4h'], '15m', 300)

    expect(requested).toEqual(['15m', '1h', '4h'])
    expect(maxConcurrent).toBe(1)
  })

  it('keeps sixty recent symbol and interval snapshots in local storage', () => {
    const candle = snapshotFor('15m').candles
    for (let index = 0; index <= 60; index += 1) {
      setKlineCache(`SYMBOL${index}USDT`, '15m', candle)
    }

    expect(getKlineCache('SYMBOL0USDT', '15m')).toBeNull()
    expect(getKlineCache('SYMBOL1USDT', '15m')).not.toBeNull()
    expect(getKlineCache('SYMBOL60USDT', '15m')).not.toBeNull()
  })

  it('does not let an older edge snapshot replace a newer browser snapshot', async () => {
    const newer = { ...snapshotFor('15m').candles[0], t: 200 }
    const older = { ...newer, t: 100 }
    setKlineCache('BTCUSDT', '15m', [newer])
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(responseWith([older]))

    const candles = await fetchKlineSnapshot('BTCUSDT', '15m', 300)

    expect(candles).toEqual([older, newer])
    expect(getKlineCache('BTCUSDT', '15m')?.candles).toEqual([older, newer])
  })

  it('uses an authoritative snapshot to repair the candle before a live rollover', () => {
    const staleClosed = { ...snapshotFor('15m').candles[0], t: 100, c: '101' }
    const finalClosed = { ...staleClosed, c: '109' }
    const live = { ...staleClosed, t: 200, o: '109', h: '112', c: '111' }

    const candles = reconcileKlineSnapshot([finalClosed], [staleClosed, live], live, true)

    expect(candles).toEqual([finalClosed, live])
  })

  it('does not let an older live event overwrite a newer authoritative snapshot', () => {
    const current = { ...snapshotFor('15m').candles[0], t: 200 }
    const oldLive = { ...current, t: 100, c: '101' }

    expect(reconcileKlineSnapshot([current], [oldLive], oldLive, true)).toEqual([current])
  })

  it('rejects a snapshot whose rows are all malformed', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(responseWith([{ t: 1, o: '100' }]))

    await expect(fetchKlineSnapshot('BTCUSDT', '15m', 300)).rejects.toThrow('empty kline snapshot')
    expect(getKlineCache('BTCUSDT', '15m')).toBeNull()
  })

  it('normalizes interval keys and repairs unordered duplicate cache rows', () => {
    const first = { ...snapshotFor('15m').candles[0], t: 100, c: '101' }
    const duplicate = { ...first, c: '102' }
    const second = { ...first, t: 200, c: '103' }

    setKlineCache('btcusdt', ' 15M ', [second, first, duplicate])

    expect(getKlineCache('BTCUSDT', '15m')?.candles).toEqual([duplicate, second])
  })

  it('does not freeze a fresh REST candle behind an old same-time WS candle', () => {
    const oldLive = snapshotFor('15m').candles[0]
    const fresh = { ...oldLive, c: '108', v: '20' }
    expect(reconcileKlineSnapshot([fresh], [oldLive], oldLive, true)).toEqual([fresh])
    expect(reconcileKlineSnapshot([oldLive], [fresh], fresh, true)).toEqual([fresh])
    expect(mergeKlineCandle([fresh], oldLive)).toEqual([fresh])
  })

  it('prefers REST corrections when cumulative volume is equal', () => {
    const oldLive = snapshotFor('15m').candles[0]
    const corrected = { ...oldLive, c: '108' }
    expect(reconcileKlineSnapshot([corrected], [oldLive], oldLive, true)).toEqual([corrected])
  })

  it('does not let a late edge response undo corrected historical candles', () => {
    const old = snapshotFor('15m').candles[0]
    const corrected = { ...old, v: '20', c: '108' }
    const next = { ...old, t: 200 }
    expect(reconcileKlineSnapshot([old, next], [corrected, next], null, false)).toEqual([
      corrected,
      next,
    ])
  })

  it('only uses incremental drawing when all historical candles are unchanged', () => {
    const first = snapshotFor('15m').candles[0]
    const last = { ...first, t: 200 }
    expect(canUpdateLatestKline([first, last], [first, { ...last, c: '108' }])).toBe(true)
    expect(canUpdateLatestKline([first, last], [{ ...first, c: '108' }, last])).toBe(false)
    expect(canUpdateLatestKline([first, last], [first, { ...last, t: 300 }])).toBe(false)
    expect(canUpdateLatestKline([], [])).toBe(false)
  })

  it('keeps concurrent requests for different intervals isolated', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(async input =>
      responseFor(String(input).split('/').pop()!)
    )
    await Promise.all([
      fetchKlineSnapshot('BTCUSDT', '15m', 300),
      fetchKlineSnapshot('BTCUSDT', '1h', 300),
    ])
    expect(getKlineCache('BTCUSDT', '15m')?.candles).toEqual(snapshotFor('15m').candles)
    expect(getKlineCache('BTCUSDT', '1h')?.candles).toEqual(snapshotFor('1h').candles)
  })

  it('coalesces concurrent refreshes for the same interval', async () => {
    vi.mocked(api.get).mockResolvedValue(snapshotFor('1h'))
    await Promise.all([
      fetchOriginKlineSnapshot('BTCUSDT', '1h', 300),
      fetchOriginKlineSnapshot('BTCUSDT', '1h', 300),
    ])
    expect(api.get).toHaveBeenCalledTimes(1)
  })
})
