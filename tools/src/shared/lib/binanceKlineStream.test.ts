import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import {
  buildBinanceKlineStreamUrls,
  parseBinanceKlineMessage,
  startBinanceKlineStream,
} from './binanceKlineStream'

class MockWebSocket {
  static readonly CONNECTING = 0
  static readonly OPEN = 1
  static readonly CLOSING = 2
  static readonly CLOSED = 3
  static instances: MockWebSocket[] = []
  static rejectedUrls = new Set<string>()

  readonly url: string
  readyState = MockWebSocket.CONNECTING
  onopen: (() => void) | null = null
  onmessage: ((event: MessageEvent<string>) => void) | null = null
  onerror: (() => void) | null = null
  onclose: (() => void) | null = null

  constructor(url: string | URL) {
    this.url = String(url)
    if (MockWebSocket.rejectedUrls.has(this.url)) throw new DOMException('invalid URL')
    MockWebSocket.instances.push(this)
  }

  open() {
    this.readyState = MockWebSocket.OPEN
    this.onopen?.()
  }

  close() {
    if (this.readyState === MockWebSocket.CLOSED) return
    this.readyState = MockWebSocket.CLOSED
    this.onclose?.()
  }

  message(data: string) {
    this.onmessage?.({ data } as MessageEvent<string>)
  }
}

describe('Binance kline stream', () => {
  beforeEach(() => {
    MockWebSocket.instances = []
    MockWebSocket.rejectedUrls.clear()
    vi.stubGlobal('WebSocket', MockWebSocket)
    vi.spyOn(window.navigator, 'onLine', 'get').mockReturnValue(true)
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('prefers the isolated origin proxy and keeps direct Binance as fallback', () => {
    expect(buildBinanceKlineStreamUrls('BTCUSDT', '15m')).toEqual([
      'wss://stream.ba.wow211.com/market-stream/btcusdt@kline_15m',
      'wss://fstream.binance.com/market/ws/btcusdt@kline_15m',
    ])
  })

  it('rejects unsupported intervals and invalid symbol paths', () => {
    expect(buildBinanceKlineStreamUrls('ETHUSDT', '1h')).toEqual([
      'wss://stream.ba.wow211.com/market-stream/ethusdt@kline_1h',
      'wss://fstream.binance.com/market/ws/ethusdt@kline_1h',
    ])
    expect(buildBinanceKlineStreamUrls('ETHUSDT', '../private')).toEqual([])
    expect(buildBinanceKlineStreamUrls('../api/account', '15m')).toEqual([])
  })

  it('normalizes supported intervals before building a stream URL', () => {
    expect(buildBinanceKlineStreamUrls(' BTCUSDT ', ' 15M ')).toEqual([
      'wss://stream.ba.wow211.com/market-stream/btcusdt@kline_15m',
      'wss://fstream.binance.com/market/ws/btcusdt@kline_15m',
    ])
  })

  it('falls back immediately when the origin proxy connection fails', () => {
    const statuses: string[] = []
    const stop = startBinanceKlineStream({
      symbol: 'BTCUSDT',
      interval: '15m',
      onCandle: vi.fn(),
      onStatus: status => statuses.push(status),
      streamUrls: [
        'wss://stream.ba.wow211.com/market-stream/btcusdt@kline_15m',
        'wss://fstream.binance.com/market/ws/btcusdt@kline_15m',
      ],
    })

    expect(MockWebSocket.instances.map(socket => socket.url)).toEqual([
      'wss://stream.ba.wow211.com/market-stream/btcusdt@kline_15m',
    ])
    MockWebSocket.instances[0].close()
    expect(MockWebSocket.instances.map(socket => socket.url)).toEqual([
      'wss://stream.ba.wow211.com/market-stream/btcusdt@kline_15m',
      'wss://fstream.binance.com/market/ws/btcusdt@kline_15m',
    ])

    MockWebSocket.instances[1].open()
    expect(statuses).toEqual(['connecting'])
    MockWebSocket.instances[1].message(
      JSON.stringify({
        k: { t: 1_788_600_000_000, o: '100', h: '110', l: '90', c: '105', v: '12' },
      })
    )
    expect(statuses).toEqual(['connecting', 'connected'])
    stop()
  })

  it('uses the fallback when constructing the preferred endpoint fails', () => {
    MockWebSocket.rejectedUrls.add('wss://same-origin.example/stream')

    const stop = startBinanceKlineStream({
      symbol: 'BTCUSDT',
      interval: '15m',
      onCandle: vi.fn(),
      onStatus: vi.fn(),
      streamUrls: ['wss://same-origin.example/stream', 'wss://direct.example/stream'],
    })

    expect(MockWebSocket.instances.map(socket => socket.url)).toEqual([
      'wss://direct.example/stream',
    ])
    stop()
  })

  it('falls back when a connected endpoint never delivers a valid candle', () => {
    vi.useFakeTimers()
    const statuses: string[] = []
    const stop = startBinanceKlineStream({
      symbol: 'BTCUSDT',
      interval: '15m',
      onCandle: vi.fn(),
      onStatus: status => statuses.push(status),
      messageTimeoutMs: 100,
      streamUrls: ['wss://same-origin.example/stream', 'wss://direct.example/stream'],
    })

    MockWebSocket.instances[0].open()
    vi.advanceTimersByTime(100)

    expect(MockWebSocket.instances.map(socket => socket.url)).toEqual([
      'wss://same-origin.example/stream',
      'wss://direct.example/stream',
    ])
    expect(statuses).toEqual(['connecting'])
    stop()
  })

  it('parses a routed or raw Binance kline event', () => {
    const payload = JSON.stringify({
      stream: 'btcusdt@kline_15m',
      data: { k: { t: 1_788_600_000_000, o: '100', h: '110', l: '90', c: '105', v: '12' } },
    })

    expect(parseBinanceKlineMessage(payload)).toEqual({
      t: 1_788_600_000,
      o: '100',
      h: '110',
      l: '90',
      c: '105',
      v: '12',
    })
    expect(
      parseBinanceKlineMessage(
        JSON.stringify({ k: { t: 0, o: '100', h: '90', l: '110', c: '', v: '-1' } })
      )
    ).toBeNull()
  })

  it('allows a slow origin TLS handshake and falls back after a bounded timeout', () => {
    vi.useFakeTimers()
    const stop = startBinanceKlineStream({
      symbol: 'BTCUSDT',
      interval: '15m',
      onCandle: vi.fn(),
      onStatus: vi.fn(),
    })
    vi.advanceTimersByTime(4000)
    expect(MockWebSocket.instances).toHaveLength(1)
    vi.advanceTimersByTime(2000)
    expect(MockWebSocket.instances).toHaveLength(2)
    expect(MockWebSocket.instances[1].url).toContain('fstream.binance.com')
    stop()
  })

  it('does not reconnect after the chart has been closed', () => {
    vi.useFakeTimers()
    const onCandle = vi.fn()
    const stop = startBinanceKlineStream({
      symbol: 'BTCUSDT',
      interval: '15m',
      onCandle,
      onStatus: vi.fn(),
    })
    MockWebSocket.instances[0].close()
    stop()
    const count = MockWebSocket.instances.length
    vi.advanceTimersByTime(60_000)
    expect(MockWebSocket.instances).toHaveLength(count)
    expect(onCandle).not.toHaveBeenCalled()
  })
})
