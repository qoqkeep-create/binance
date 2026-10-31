// K线 localStorage 缓存：弹窗打开/切换周期时首帧直接用缓存秒开；
// 持仓结束后由持仓页调用 clearKlineCacheSymbol 清理对应缓存。
const CACHE_PREFIX = 'tt_kline_cache_v1:'
const INDEX_KEY = `${CACHE_PREFIX}index`
const MAX_ENTRIES = 60
const MAX_CANDLES = 300

export interface CachedKlineCandle {
  t: number
  o: string
  h: string
  l: string
  c: string
  v: string
}

export interface KlineCacheEntry {
  candles: CachedKlineCandle[]
  savedAt: number
}

function cacheKey(symbol: string, interval: string): string {
  return `${CACHE_PREFIX}${symbol.trim().toUpperCase()}|${interval.trim().toLowerCase()}`
}

export function isValidKlineCandle(value: unknown): value is CachedKlineCandle {
  if (!value || typeof value !== 'object') return false
  const candle = value as Partial<CachedKlineCandle>
  const priceStrings = [candle.o, candle.h, candle.l, candle.c]
  if (
    typeof candle.t === 'number' &&
    Number.isInteger(candle.t) &&
    candle.t > 0 &&
    priceStrings.every(
      value => typeof value === 'string' && value.trim() !== '' && Number.isFinite(Number(value))
    ) &&
    typeof candle.v === 'string' &&
    candle.v.trim() !== '' &&
    Number.isFinite(Number(candle.v))
  ) {
    const [open, high, low, close] = priceStrings.map(Number)
    const volume = Number(candle.v)
    return (
      open > 0 &&
      high > 0 &&
      low > 0 &&
      close > 0 &&
      volume >= 0 &&
      high >= Math.max(open, close, low) &&
      low <= Math.min(open, close, high)
    )
  }
  return false
}

export function normalizeKlineCandles(value: unknown): CachedKlineCandle[] {
  if (!Array.isArray(value)) return []
  const byTime = new Map<number, CachedKlineCandle>()
  for (const candle of value) {
    if (isValidKlineCandle(candle)) byTime.set(candle.t, candle)
  }
  return [...byTime.values()].sort((left, right) => left.t - right.t).slice(-MAX_CANDLES)
}

function readIndex(): string[] {
  try {
    const raw = window.localStorage.getItem(INDEX_KEY)
    if (!raw) return []
    const list = JSON.parse(raw)
    if (!Array.isArray(list)) return []
    return [
      ...new Set(
        list.filter(
          (key): key is string =>
            typeof key === 'string' && key.startsWith(CACHE_PREFIX) && key !== INDEX_KEY
        )
      ),
    ]
  } catch {
    return []
  }
}

export function mergeKlineCandle(
  candles: CachedKlineCandle[],
  incoming: CachedKlineCandle
): CachedKlineCandle[] {
  const existing = candles.find(candle => candle.t === incoming.t)
  // Binance volume is cumulative within a candle. Late packets cannot undo trades.
  if (existing && Number(existing.v) > Number(incoming.v)) return candles
  return normalizeKlineCandles([...candles, incoming])
}

export function canUpdateLatestKline(
  previous: CachedKlineCandle[],
  next: CachedKlineCandle[]
): boolean {
  return (
    previous.length > 1 &&
    previous.length === next.length &&
    previous.every((candle, i) => {
      const incoming = next[i]
      return (
        candle.t === incoming.t &&
        (i === next.length - 1 ||
          (candle.o === incoming.o &&
            candle.h === incoming.h &&
            candle.l === incoming.l &&
            candle.c === incoming.c &&
            candle.v === incoming.v))
      )
    })
  )
}

export function reconcileKlineSnapshot(
  snapshot: CachedKlineCandle[],
  rendered: CachedKlineCandle[],
  liveCandle: CachedKlineCandle | null,
  authoritative: boolean
): CachedKlineCandle[] {
  const normalizedSnapshot = normalizeKlineCandles(snapshot)
  const normalizedRendered = normalizeKlineCandles(rendered)
  const snapshotLast = normalizedSnapshot[normalizedSnapshot.length - 1]
  const renderedLast = normalizedRendered[normalizedRendered.length - 1]
  let base = normalizedSnapshot

  if (!authoritative && renderedLast) {
    base = normalizedRendered.reduce(mergeKlineCandle, normalizedSnapshot)
  } else if (authoritative && !snapshotLast) {
    base = normalizedRendered
  }

  const baseLast = base[base.length - 1]
  return liveCandle &&
    (!baseLast ||
      liveCandle.t > baseLast.t ||
      (liveCandle.t === baseLast.t && Number(liveCandle.v) > Number(baseLast.v)))
    ? mergeKlineCandle(base, liveCandle)
    : base
}

function writeIndex(keys: string[]) {
  try {
    window.localStorage.setItem(INDEX_KEY, JSON.stringify(keys))
  } catch {
    // 忽略写入失败
  }
}

export function getKlineCache(symbol: string, interval: string): KlineCacheEntry | null {
  if (!symbol || !interval) return null
  try {
    const raw = window.localStorage.getItem(cacheKey(symbol, interval))
    if (!raw) return null
    const parsed: unknown = JSON.parse(raw)
    // 兼容旧版直接保存数组的缓存，读取后会在下次写入时升级为带时间元数据的格式。
    if (Array.isArray(parsed)) {
      const candles = normalizeKlineCandles(parsed)
      return candles.length > 0 ? { candles, savedAt: 0 } : null
    }
    if (!parsed || typeof parsed !== 'object') return null
    const entry = parsed as { candles?: unknown; savedAt?: unknown }
    const candles = normalizeKlineCandles(entry.candles)
    if (candles.length === 0) return null
    return {
      candles,
      savedAt:
        typeof entry.savedAt === 'number' && Number.isFinite(entry.savedAt) ? entry.savedAt : 0,
    }
  } catch {
    return null
  }
}

export function setKlineCache(symbol: string, interval: string, candles: CachedKlineCandle[]) {
  if (!symbol || !interval || !Array.isArray(candles) || candles.length === 0) return
  const key = cacheKey(symbol, interval)
  const normalized = normalizeKlineCandles(candles)
  if (normalized.length === 0) return
  try {
    window.localStorage.setItem(
      key,
      JSON.stringify({ version: 2, savedAt: Date.now(), candles: normalized })
    )
    const index = readIndex().filter(k => k !== key)
    index.push(key)
    // 超出上限时淘汰最旧条目
    while (index.length > MAX_ENTRIES) {
      const evict = index.shift()
      if (evict) window.localStorage.removeItem(evict)
    }
    writeIndex(index)
  } catch {
    // 空间不足时放弃该条缓存
    try {
      window.localStorage.removeItem(key)
      writeIndex(readIndex().filter(k => k !== key))
    } catch {
      // 忽略
    }
  }
}

export function clearKlineCacheSymbol(symbol: string) {
  if (!symbol) return
  const prefix = `${CACHE_PREFIX}${symbol.trim().toUpperCase()}|`
  const remain: string[] = []
  for (const key of readIndex()) {
    if (key.startsWith(prefix)) {
      try {
        window.localStorage.removeItem(key)
      } catch {
        // 忽略
      }
    } else {
      remain.push(key)
    }
  }
  writeIndex(remain)
}
