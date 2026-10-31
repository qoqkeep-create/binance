import { isValidKlineCandle, type CachedKlineCandle } from './klineCache'

const DIRECT_STREAM_BASE_URL = 'wss://fstream.binance.com/market/ws'
const PROXY_STREAM_BASE_URL = 'wss://stream.ba.wow211.com/market-stream'
const SUPPORTED_INTERVALS = new Set(['1m', '3m', '5m', '15m', '30m', '1h', '2h', '4h', '1d'])
// Cross-border TLS handshakes can exceed 2s; REST polling continues meanwhile.
const DEFAULT_CONNECT_TIMEOUT_MS = 6000
const DEFAULT_MESSAGE_TIMEOUT_MS = 8000
const RECONNECT_DELAYS_MS = [2000, 4000, 8000, 16000, 30000] as const

export type BinanceKlineStreamStatus = 'connecting' | 'connected' | 'disconnected'

interface BinanceKlineStreamOptions {
  symbol: string
  interval: string
  onCandle: (candle: CachedKlineCandle) => void
  onStatus: (status: BinanceKlineStreamStatus) => void
  connectTimeoutMs?: number
  messageTimeoutMs?: number
  streamUrls?: readonly string[]
}

type UnknownRecord = Record<string, unknown>

function asRecord(value: unknown): UnknownRecord | null {
  return value != null && typeof value === 'object' ? (value as UnknownRecord) : null
}

export function buildBinanceKlineStreamUrls(symbol: string, interval: string): string[] {
  const normalizedSymbol = symbol.trim().toLowerCase()
  const normalizedInterval = interval.trim().toLowerCase()
  if (!/^[a-z0-9]{2,30}$/.test(normalizedSymbol) || !SUPPORTED_INTERVALS.has(normalizedInterval))
    return []

  const streamName = `${normalizedSymbol}@kline_${normalizedInterval}`
  return [`${PROXY_STREAM_BASE_URL}/${streamName}`, `${DIRECT_STREAM_BASE_URL}/${streamName}`]
}

export function parseBinanceKlineMessage(data: unknown): CachedKlineCandle | null {
  if (typeof data !== 'string') return null
  try {
    const raw = asRecord(JSON.parse(data))
    const event = asRecord(raw?.data) || raw
    const kline = asRecord(event?.k)
    if (!kline) return null

    const openTime = Number(kline.t)
    const open = kline.o
    const high = kline.h
    const low = kline.l
    const close = kline.c
    const volume = kline.v
    const candle = {
      t: Math.floor(openTime / 1000),
      o: open,
      h: high,
      l: low,
      c: close,
      v: volume,
    }
    return isValidKlineCandle(candle) ? candle : null
  } catch {
    return null
  }
}

/**
 * Starts an isolated public market-data stream. The returned function permanently
 * stops this stream and removes its browser lifecycle listeners.
 */
export function startBinanceKlineStream(options: BinanceKlineStreamOptions): () => void {
  const streamUrls = options.streamUrls?.length
    ? Array.from(options.streamUrls)
    : buildBinanceKlineStreamUrls(options.symbol, options.interval)
  if (streamUrls.length === 0) {
    options.onStatus('disconnected')
    return () => undefined
  }
  const connectTimeoutMs = options.connectTimeoutMs ?? DEFAULT_CONNECT_TIMEOUT_MS
  const messageTimeoutMs = options.messageTimeoutMs ?? DEFAULT_MESSAGE_TIMEOUT_MS
  let socket: WebSocket | null = null
  let stopped = false
  let reconnectAttempt = 0
  let reconnectTimer: number | null = null
  let connectTimer: number | null = null
  let messageTimer: number | null = null
  let lastStatus: BinanceKlineStreamStatus | null = null
  let streamUrlIndex = 0
  let failedEndpoints = 0
  let connectionBecameStable = false

  const emitStatus = (status: BinanceKlineStreamStatus) => {
    if (lastStatus === status) return
    lastStatus = status
    options.onStatus(status)
  }

  const clearTimer = (timer: number | null) => {
    if (timer !== null) window.clearTimeout(timer)
  }

  const clearConnectionTimers = () => {
    clearTimer(connectTimer)
    clearTimer(messageTimer)
    connectTimer = null
    messageTimer = null
  }

  const resetMessageTimeout = (target: WebSocket) => {
    clearTimer(messageTimer)
    messageTimer = window.setTimeout(() => {
      if (socket === target) target.close()
    }, messageTimeoutMs)
  }

  const scheduleReconnect = () => {
    if (stopped || reconnectTimer !== null || navigator.onLine === false) return
    const delay = RECONNECT_DELAYS_MS[Math.min(reconnectAttempt, RECONNECT_DELAYS_MS.length - 1)]
    reconnectAttempt += 1
    reconnectTimer = window.setTimeout(() => {
      reconnectTimer = null
      connect()
    }, delay)
  }

  const handleDisconnect = (target: WebSocket) => {
    if (socket !== target) return
    clearConnectionTimers()
    socket = null
    if (stopped) return

    if (!connectionBecameStable && streamUrls.length > 1) {
      failedEndpoints += 1
      streamUrlIndex = (streamUrlIndex + 1) % streamUrls.length
      if (failedEndpoints < streamUrls.length) {
        connect()
        return
      }
    }
    failedEndpoints = 0
    emitStatus('disconnected')
    scheduleReconnect()
  }

  const handleConnectFailure = () => {
    if (stopped) return
    if (streamUrls.length > 1) {
      failedEndpoints += 1
      streamUrlIndex = (streamUrlIndex + 1) % streamUrls.length
      if (failedEndpoints < streamUrls.length) {
        connect()
        return
      }
    }
    failedEndpoints = 0
    emitStatus('disconnected')
    scheduleReconnect()
  }

  function connect() {
    if (stopped || socket || navigator.onLine === false) return
    emitStatus('connecting')
    connectionBecameStable = false

    let target: WebSocket
    try {
      target = new WebSocket(streamUrls[streamUrlIndex])
    } catch {
      handleConnectFailure()
      return
    }
    socket = target
    connectTimer = window.setTimeout(() => {
      if (socket === target && target.readyState !== WebSocket.OPEN) target.close()
    }, connectTimeoutMs)

    target.onopen = () => {
      if (socket !== target || stopped) return
      clearTimer(connectTimer)
      connectTimer = null
      resetMessageTimeout(target)
    }
    target.onmessage = event => {
      if (socket !== target || stopped) return
      const candle = parseBinanceKlineMessage(event.data)
      if (!candle) return
      const firstValidCandle = !connectionBecameStable
      connectionBecameStable = true
      reconnectAttempt = 0
      failedEndpoints = 0
      resetMessageTimeout(target)
      if (firstValidCandle) emitStatus('connected')
      options.onCandle(candle)
    }
    target.onerror = () => {
      if (socket === target) target.close()
    }
    target.onclose = () => handleDisconnect(target)
  }

  const reconnectNow = () => {
    if (stopped || navigator.onLine === false || document.visibilityState === 'hidden') return
    if (socket?.readyState === WebSocket.OPEN || socket?.readyState === WebSocket.CONNECTING) return
    clearTimer(reconnectTimer)
    reconnectTimer = null
    connect()
  }
  const handleVisibility = () => {
    if (document.visibilityState === 'visible') reconnectNow()
  }
  const handleOnline = () => reconnectNow()
  const handleOffline = () => {
    clearTimer(reconnectTimer)
    reconnectTimer = null
    emitStatus('disconnected')
    socket?.close()
  }

  document.addEventListener('visibilitychange', handleVisibility)
  window.addEventListener('online', handleOnline)
  window.addEventListener('offline', handleOffline)
  connect()

  return () => {
    stopped = true
    clearTimer(reconnectTimer)
    reconnectTimer = null
    clearConnectionTimers()
    document.removeEventListener('visibilitychange', handleVisibility)
    window.removeEventListener('online', handleOnline)
    window.removeEventListener('offline', handleOffline)
    const target = socket
    socket = null
    if (target) {
      target.onopen = null
      target.onmessage = null
      target.onerror = null
      target.onclose = null
      target.close()
    }
  }
}
