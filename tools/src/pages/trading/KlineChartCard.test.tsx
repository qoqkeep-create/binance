import { act, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { KlineChartCard } from './KlineChartCard'
import { fetchKlineSnapshot, fetchOriginKlineSnapshot } from '@/shared/lib/klineSnapshotCache'
import { startBinanceKlineStream } from '@/shared/lib/binanceKlineStream'
import { type CachedKlineCandle, setKlineCache } from '@/shared/lib/klineCache'

const charts = vi.hoisted(
  () =>
    [] as Array<{
      series: Array<{ setData: ReturnType<typeof vi.fn>; update: ReturnType<typeof vi.fn>; options: { priceFormat?: { minMove: number } } }>
      options: { localization: { priceFormatter: (price: number) => string } }
    }>
)
vi.mock('lightweight-charts', async importOriginal => {
  const original = await importOriginal<typeof import('lightweight-charts')>()
  return {
    ...original,
    createChart: (_container: unknown, options: { localization: { priceFormatter: (price: number) => string } }) => {
      const series: Array<{ setData: ReturnType<typeof vi.fn>; update: ReturnType<typeof vi.fn>; options: { priceFormat?: { minMove: number } } }> =
        []
      const addSeries = (_type: unknown, options: { priceFormat?: { minMove: number } }) => {
        const item = {
          options,
          setData: vi.fn(),
          update: vi.fn(),
          applyOptions: vi.fn(),
          createPriceLine: vi.fn(),
          removePriceLine: vi.fn(),
        }
        series.push(item)
        return item
      }
      const chart = {
        series,
        options,
        addSeries,
        addCustomSeries: addSeries,
        remove: vi.fn(),
        removeSeries: vi.fn(),
        subscribeCrosshairMove: vi.fn(),
        applyOptions: vi.fn(),
        resize: vi.fn(),
        panes: () => [{ setHeight: vi.fn() }, { setHeight: vi.fn() }],
        priceScale: () => ({ applyOptions: vi.fn() }),
        timeScale: () => ({ getVisibleLogicalRange: () => null, scrollToRealTime: vi.fn() }),
      }
      charts.push(chart)
      return chart
    },
  }
})
vi.mock('@/shared/lib/klineSnapshotCache', () => ({
  fetchKlineSnapshot: vi.fn(),
  fetchOriginKlineSnapshot: vi.fn(),
  prefetchMissingKlineIntervals: vi.fn(),
}))
vi.mock('@/shared/lib/binanceKlineStream', () => ({
  startBinanceKlineStream: vi.fn(() => vi.fn()),
}))
vi.mock('@/app/contexts/ThemeContext', () => ({ useTheme: () => ({ theme: 'dark' }) }))

const candle: CachedKlineCandle = {
  t: 1_700_000_000,
  o: '100',
  h: '110',
  l: '90',
  c: '105',
  v: '12',
}
const history = [candle, { ...candle, t: candle.t + 900 }]
const latestSeries = () => charts[charts.length - 1].series[0]
const stream = () => {
  const calls = vi.mocked(startBinanceKlineStream).mock.calls
  return calls[calls.length - 1][0]
}

describe('Kline chart reconciliation lifecycle', () => {
  beforeEach(() => {
    charts.length = 0
    localStorage.clear()
    vi.clearAllMocks()
    vi.useFakeTimers()
    vi.spyOn(window, 'scrollTo').mockImplementation(() => undefined)
    vi.stubGlobal(
      'ResizeObserver',
      class {
        observe() {}
        disconnect() {}
      }
    )
    vi.mocked(fetchKlineSnapshot).mockResolvedValue(history)
    vi.mocked(fetchOriginKlineSnapshot).mockResolvedValue(history)
  })
  afterEach(() => {
    vi.useRealTimers()
    vi.unstubAllGlobals()
  })

  it('keeps small chart prices readable instead of rounding them to zero', async () => {
    const smallHistory = history.map(c => ({ ...c, o: '0.00001234', h: '0.00001250', l: '0.00001210', c: '0.00001240' }))
    vi.mocked(fetchKlineSnapshot).mockResolvedValue(smallHistory)
    vi.mocked(fetchOriginKlineSnapshot).mockResolvedValue(smallHistory)
    await act(async () => {
      render(<KlineChartCard symbol="TURBOUSDT" open entry="none" />)
    })
    const format = charts[charts.length - 1].options.localization.priceFormatter
    expect(format(0.00001234)).toBe('0.00001234')
    expect(format(0.00012346)).toBe('0.0001235')
    expect(format(-0.00001234)).toBe('-0.00001234')
    expect(format(0)).toBe('0')
    // Price scale steps must fit the price range; formatting alone leaves an empty axis.
    const series = charts[charts.length - 1].series
    expect(series[0].options.priceFormat?.minMove ?? 0.01).toBeLessThan(0.0000001)
    expect(series[5].options.priceFormat?.minMove ?? 0.01).toBeLessThan(0.0000001)
  })

  it('fully redraws corrected history even when timestamps and length are unchanged', async () => {
    await act(async () => {
      render(<KlineChartCard symbol="BTCUSDT" open entry="none" />)
    })
    const series = latestSeries()
    series.setData.mockClear()
    vi.mocked(fetchOriginKlineSnapshot).mockResolvedValue([
      { ...candle, c: '108', v: '20' },
      history[1],
    ])
    await act(async () => {
      fireEvent.click(screen.getByText('手动刷新'))
    })
    expect(series.setData).toHaveBeenCalledTimes(1)
    expect(series.setData.mock.calls[0][0][0].close).toBe(108)
  })

  it('discards a queued WS candle after disconnection and accepts fresh REST data', async () => {
    await act(async () => {
      render(<KlineChartCard symbol="BTCUSDT" open entry="none" />)
    })
    const options = stream()
    act(() => {
      options.onStatus('connected')
      options.onCandle({ ...history[1], c: '106', v: '13' })
      options.onStatus('disconnected')
    })
    vi.mocked(fetchOriginKlineSnapshot).mockResolvedValue([
      candle,
      { ...history[1], c: '109', v: '20' },
    ])
    await act(async () => {
      fireEvent.click(screen.getByText('手动刷新'))
    })
    await act(async () => {
      vi.advanceTimersByTime(800)
    })
    const updates = latestSeries().update.mock.calls
    expect(updates[updates.length - 1][0].close).toBe(109)
  })

  it('calibrates on reconnect within the same candle', async () => {
    await act(async () => {
      render(<KlineChartCard symbol="BTCUSDT" open entry="none" />)
    })
    const options = stream()
    act(() => {
      options.onStatus('connected')
      options.onCandle(history[1])
    })
    await act(async () => {
      vi.advanceTimersByTime(2600)
    })
    vi.mocked(fetchOriginKlineSnapshot).mockClear()
    act(() => {
      options.onStatus('disconnected')
      options.onStatus('connecting')
      options.onStatus('connected')
      options.onCandle(history[1])
    })
    await act(async () => {
      vi.advanceTimersByTime(2600)
    })
    expect(fetchOriginKlineSnapshot).toHaveBeenCalledTimes(1)
  })

  it('keeps fallback polling on schedule while reconnect statuses change', async () => {
    await act(async () => {
      render(<KlineChartCard symbol="BTCUSDT" open entry="none" />)
    })
    const options = stream()
    await act(async () => {
      vi.advanceTimersByTime(1000)
    })
    act(() => {
      options.onStatus('disconnected')
    })
    await act(async () => {
      vi.advanceTimersByTime(1000)
    })
    expect(fetchOriginKlineSnapshot).toHaveBeenCalledTimes(1)
    act(() => {
      options.onStatus('connecting')
    })
    await act(async () => {
      vi.advanceTimersByTime(1000)
    })
    act(() => {
      options.onStatus('disconnected')
    })
    await act(async () => {
      vi.advanceTimersByTime(1000)
    })
    expect(fetchOriginKlineSnapshot).toHaveBeenCalledTimes(2)
  })

  it('switches between live calibration and fallback polling when connectivity changes', async () => {
    await act(async () => {
      render(<KlineChartCard symbol="BTCUSDT" open entry="none" />)
    })
    const options = stream()
    act(() => {
      options.onStatus('connected')
    })
    await act(async () => {
      vi.advanceTimersByTime(29_999)
    })
    expect(fetchOriginKlineSnapshot).not.toHaveBeenCalled()
    await act(async () => {
      vi.advanceTimersByTime(1)
    })
    expect(fetchOriginKlineSnapshot).toHaveBeenCalledTimes(1)
    act(() => {
      options.onStatus('disconnected')
    })
    await act(async () => {
      vi.advanceTimersByTime(1999)
    })
    expect(fetchOriginKlineSnapshot).toHaveBeenCalledTimes(1)
    await act(async () => {
      vi.advanceTimersByTime(1)
    })
    expect(fetchOriginKlineSnapshot).toHaveBeenCalledTimes(2)
  })

  it('ignores a response from an earlier open of the same chart', async () => {
    let resolveOld!: (value: CachedKlineCandle[]) => void
    vi.mocked(fetchKlineSnapshot).mockImplementationOnce(
      () =>
        new Promise(resolve => {
          resolveOld = resolve
        })
    )
    const view = render(<KlineChartCard symbol="BTCUSDT" open entry="none" />)
    await act(async () => {
      view.rerender(<KlineChartCard symbol="BTCUSDT" open={false} entry="none" />)
    })
    await act(async () => {
      view.rerender(<KlineChartCard symbol="BTCUSDT" open entry="none" />)
    })
    const series = latestSeries()
    series.setData.mockClear()
    series.update.mockClear()
    await act(async () => {
      resolveOld([{ ...candle, c: '101' }])
    })
    expect(series.setData).not.toHaveBeenCalled()
    expect(series.update).not.toHaveBeenCalled()
  })

  it('uses the selected interval cache immediately and ignores delayed old intervals', async () => {
    let resolveOld!: (value: CachedKlineCandle[]) => void
    vi.mocked(fetchKlineSnapshot).mockImplementation(
      () =>
        new Promise(resolve => {
          resolveOld = resolve
        })
    )
    setKlineCache('BTCUSDT', '1h', [{ ...candle, c: '109' }])
    render(<KlineChartCard symbol="BTCUSDT" open entry="none" />)
    const oldRequest = resolveOld
    await act(async () => {
      fireEvent.click(screen.getByText('1时'))
    })
    const series = latestSeries()
    expect(series.setData.mock.calls[0][0][0].close).toBe(109)
    series.setData.mockClear()
    await act(async () => {
      oldRequest(history)
    })
    expect(series.setData).not.toHaveBeenCalled()
  })
})
