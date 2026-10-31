import { api } from '@/shared/lib/api'
import {
  getKlineCache,
  normalizeKlineCandles,
  reconcileKlineSnapshot,
  setKlineCache,
  type CachedKlineCandle,
} from '@/shared/lib/klineCache'

interface KlineSnapshotResponse {
  candles?: CachedKlineCandle[]
}

interface PublicKlineApiResponse {
  code: number
  message?: string
  data?: KlineSnapshotResponse
}

const inFlightSnapshots = new Map<string, Promise<CachedKlineCandle[]>>()

function snapshotKey(symbol: string, interval: string, limit: number): string {
  return `${symbol.trim().toUpperCase()}|${interval.trim().toLowerCase()}|${limit}`
}

function normalizeLimit(limit: number): number {
  return Number.isFinite(limit) ? Math.min(Math.max(Math.trunc(limit), 1), 300) : 300
}

function requestKlineSnapshot(
  symbol: string,
  interval: string,
  limit: number,
  source: 'edge' | 'origin'
): Promise<CachedKlineCandle[]> {
  const normalizedLimit = normalizeLimit(limit)
  const key = `${source}|${snapshotKey(symbol, interval, normalizedLimit)}`
  const existing = inFlightSnapshots.get(key)
  if (existing) return existing

  const normalizedSymbol = symbol.trim().toUpperCase()
  const normalizedInterval = interval.trim().toLowerCase()
  const encodedSymbol = encodeURIComponent(normalizedSymbol)
  const encodedInterval = encodeURIComponent(normalizedInterval)
  const controller = new AbortController()
  const timeout = window.setTimeout(() => controller.abort(), 12_000)
  const request = (
    source === 'origin'
      ? api.get<KlineSnapshotResponse>(
          `/trade/market/klines?symbol=${encodedSymbol}&interval=${encodedInterval}&limit=${normalizedLimit}&fresh=1`,
          { suppressConnectionError: true, disableRetry: true, timeout: 12_000 }
        )
      : fetch(
          import.meta.env.DEV
            ? `/v1/trade/market/klines-public/${encodedSymbol}/${encodedInterval}`
            : `/market-data/klines/${encodedSymbol}/${encodedInterval}.json`,
          {
            credentials: 'omit',
            headers: { Accept: 'application/json' },
            signal: controller.signal,
          }
        ).then(async response => {
          const payload = (await response.json()) as PublicKlineApiResponse
          if (!response.ok || (payload.code !== 0 && payload.code !== 200) || !payload.data) {
            throw new Error(payload.message || 'failed to load Kline snapshot')
          }
          return payload.data
        })
  )
    .then(data => {
      const candles = normalizeKlineCandles(data.candles).slice(-normalizedLimit)
      if (candles.length === 0) throw new Error('empty kline snapshot')
      const cached = getKlineCache(normalizedSymbol, normalizedInterval)
      const reconciled = reconcileKlineSnapshot(
        candles,
        cached?.candles || [],
        null,
        source === 'origin'
      )
      setKlineCache(normalizedSymbol, normalizedInterval, reconciled)
      return reconciled
    })
    .finally(() => {
      window.clearTimeout(timeout)
      inFlightSnapshots.delete(key)
    })

  inFlightSnapshots.set(key, request)
  return request
}

export function fetchKlineSnapshot(
  symbol: string,
  interval: string,
  limit: number
): Promise<CachedKlineCandle[]> {
  return requestKlineSnapshot(symbol, interval, limit, 'edge')
}

export function fetchOriginKlineSnapshot(
  symbol: string,
  interval: string,
  limit: number
): Promise<CachedKlineCandle[]> {
  return requestKlineSnapshot(symbol, interval, limit, 'origin')
}

export async function prefetchMissingKlineIntervals(
  symbol: string,
  intervals: readonly string[],
  activeInterval: string,
  limit: number
): Promise<void> {
  // Do not let background warming compete with the interval the user is viewing.
  try {
    await fetchKlineSnapshot(symbol, activeInterval, limit)
  } catch {
    return
  }

  const missing = intervals.filter(interval => {
    if (interval === activeInterval) return false
    const cached = getKlineCache(symbol, interval)
    return cached === null || cached.candles.length < limit
  })
  for (const interval of missing) {
    try {
      await fetchKlineSnapshot(symbol, interval, limit)
    } catch {
      // Prefetch is best effort; the selected interval will retry on demand.
    }
  }
}
