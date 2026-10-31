import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import {
  CandlestickChart,
  Check,
  ChevronDown,
  Minus,
  Plus,
  Settings as SettingsIcon,
} from 'lucide-react'
import {
  createChart,
  CandlestickSeries,
  HistogramSeries,
  LineSeries,
  ColorType,
  CrosshairMode,
  LineStyle,
  TrackingModeExitMode,
  customSeriesDefaultOptions,
  type IChartApi,
  type IPriceLine,
  type ISeriesApi,
  type UTCTimestamp,
  type Time,
  type CustomData,
  type CustomBarItemData,
  type CustomSeriesOptions,
  type CustomSeriesWhitespaceData,
  type CustomSeriesPricePlotValues,
  type ICustomSeriesPaneRenderer,
  type ICustomSeriesPaneView,
  type PaneRendererCustomData,
  type PriceToCoordinateConverter,
} from 'lightweight-charts'
import type { CanvasRenderingTarget2D } from 'fancy-canvas'
import { useTheme } from '@/app/contexts/ThemeContext'
import { formatChartPrice } from '@/shared/lib/chartPrice'
import {
  startBinanceKlineStream,
  type BinanceKlineStreamStatus,
} from '@/shared/lib/binanceKlineStream'
import {
  canUpdateLatestKline,
  getKlineCache,
  mergeKlineCandle,
  reconcileKlineSnapshot,
  setKlineCache,
  type CachedKlineCandle,
} from '@/shared/lib/klineCache'
import {
  fetchKlineSnapshot,
  fetchOriginKlineSnapshot,
  prefetchMissingKlineIntervals,
} from '@/shared/lib/klineSnapshotCache'

// ===== 图表配色：品牌色深浅共用，背景/网格/边框跟随主题 =====
const CHART_BRAND = {
  up: '#0ECB81',
  down: '#F6465D',
  ema21: '#00D1B2',
  ema55: '#547CFF',
  ema144: '#7C3AED',
}

function getChartPalette(theme: 'dark' | 'light') {
  return theme === 'light'
    ? {
        ...CHART_BRAND,
        bg: '#FFFFFF',
        text: '#111827',
        textMuted: '#6B7280',
        grid: '#F0F2F5',
        border: '#E5E7EB',
      }
    : {
        ...CHART_BRAND,
        bg: '#181A20',
        text: '#EAECEF',
        textMuted: '#848E9C',
        grid: '#252A33',
        border: '#2B3139',
      }
}

const INTERVALS = [
  { value: '3m', label: '3分' },
  { value: '15m', label: '15分' },
  { value: '1h', label: '1时' },
  { value: '4h', label: '4时' },
  { value: '1d', label: '1天' },
] as const
const KLINE_INTERVAL_VALUES = INTERVALS.map(item => item.value)

const KLINE_LIMIT = 300
const FALLBACK_POLL_INTERVAL_MS = 2000
const SERVER_CALIBRATION_INTERVAL_MS = 30_000
const STREAM_APPLY_THROTTLE_MS = 750
const STREAM_CALIBRATION_DELAYS_MS = [2500, 5000, 10_000, 30_000] as const

type KlineCandle = CachedKlineCandle

// ===== 指标计算 =====

function calcEma(values: number[], period: number): (number | null)[] {
  const out: (number | null)[] = new Array(values.length).fill(null)
  if (values.length < period) return out
  let sum = 0
  for (let i = 0; i < period; i += 1) sum += values[i]
  let ema = sum / period
  out[period - 1] = ema
  const k = 2 / (period + 1)
  for (let i = period; i < values.length; i += 1) {
    ema = values[i] * k + ema * (1 - k)
    out[i] = ema
  }
  return out
}

/** Supertrend（ATR 周期 10，乘数 6） */
function calcSupertrend(
  highs: number[],
  lows: number[],
  closes: number[],
  atrPeriod = 10,
  multiplier = 6
): { line: (number | null)[]; trendUp: boolean[] } {
  const n = closes.length
  const line: (number | null)[] = new Array(n).fill(null)
  const trendUp: boolean[] = new Array(n).fill(true)
  if (n < atrPeriod + 1) return { line, trendUp }

  const tr: number[] = new Array(n).fill(0)
  tr[0] = highs[0] - lows[0]
  for (let i = 1; i < n; i += 1) {
    tr[i] = Math.max(
      highs[i] - lows[i],
      Math.abs(highs[i] - closes[i - 1]),
      Math.abs(lows[i] - closes[i - 1])
    )
  }

  const atr: number[] = new Array(n).fill(0)
  let sum = 0
  for (let i = 0; i < atrPeriod; i += 1) sum += tr[i]
  atr[atrPeriod - 1] = sum / atrPeriod
  for (let i = atrPeriod; i < n; i += 1) {
    atr[i] = (atr[i - 1] * (atrPeriod - 1) + tr[i]) / atrPeriod
  }

  const finalUpper: number[] = new Array(n).fill(0)
  const finalLower: number[] = new Array(n).fill(0)
  for (let i = atrPeriod; i < n; i += 1) {
    const mid = (highs[i] + lows[i]) / 2
    const basicUpper = mid + multiplier * atr[i]
    const basicLower = mid - multiplier * atr[i]
    const prevFU = i > atrPeriod ? finalUpper[i - 1] : basicUpper
    const prevFL = i > atrPeriod ? finalLower[i - 1] : basicLower
    finalUpper[i] = basicUpper < prevFU || closes[i - 1] > prevFU ? basicUpper : prevFU
    finalLower[i] = basicLower > prevFL || closes[i - 1] < prevFL ? basicLower : prevFL

    let st: number
    if (i === atrPeriod) {
      st = closes[i] > finalUpper[i] ? finalLower[i] : finalUpper[i]
    } else {
      const prevSt = line[i - 1] as number
      if (prevSt === finalUpper[i - 1]) {
        st = closes[i] > finalUpper[i] ? finalLower[i] : finalUpper[i]
      } else {
        st = closes[i] < finalLower[i] ? finalUpper[i] : finalLower[i]
      }
    }
    line[i] = st
    trendUp[i] = st === finalLower[i]
  }
  return { line, trendUp }
}

// ===== MACD 计算（12/26/9，柱体 = 2*(DIF-DEA)，与通达信/币安习惯一致）=====

function calcEmaSeedFirst(values: number[], period: number): number[] {
  const k = 2 / (period + 1)
  const out: number[] = new Array(values.length)
  if (values.length === 0) return out
  out[0] = values[0]
  for (let i = 1; i < values.length; i += 1) {
    out[i] = values[i] * k + out[i - 1] * (1 - k)
  }
  return out
}

function calcMacd(
  closes: number[],
  fastPeriod = 12,
  slowPeriod = 26,
  signalPeriod = 9
): { dif: number[]; dea: number[]; hist: number[]; increasing: boolean[] } {
  const n = closes.length
  const dif = new Array<number>(n).fill(0)
  let dea = new Array<number>(n).fill(0)
  const hist = new Array<number>(n).fill(0)
  const increasing = new Array<boolean>(n).fill(false)
  if (n === 0) return { dif, dea, hist, increasing }
  const emaFast = calcEmaSeedFirst(closes, fastPeriod)
  const emaSlow = calcEmaSeedFirst(closes, slowPeriod)
  for (let i = 0; i < n; i += 1) dif[i] = emaFast[i] - emaSlow[i]
  dea = calcEmaSeedFirst(dif, signalPeriod).slice()
  for (let i = 0; i < n; i += 1) {
    hist[i] = 2 * (dif[i] - dea[i])
    increasing[i] = i > 0 && Math.abs(hist[i]) > Math.abs(hist[i - 1])
  }
  return { dif, dea, hist, increasing }
}

// ===== MACD 能量柱自定义 Series（增加=实心，减少=空心）=====

interface MacdBarData extends CustomData<Time> {
  value: number
  hollow: boolean
  /** 柱体颜色（注意：不能用 color 字段名，lightweight-charts 会将其作为保留字段剥离） */
  histColor: string
}

class MacdHistogramRenderer implements ICustomSeriesPaneRenderer {
  private _data: PaneRendererCustomData<Time, MacdBarData> | null = null

  update(data: PaneRendererCustomData<Time, MacdBarData>): void {
    this._data = data
  }

  draw(target: CanvasRenderingTarget2D, priceConverter: PriceToCoordinateConverter): void {
    target.useBitmapCoordinateSpace(scope => {
      const ctx = scope.context
      const data = this._data
      if (!data || !data.visibleRange) return
      const zeroY = priceConverter(0)
      if (zeroY == null) return
      const xr = scope.horizontalPixelRatio
      const yr = scope.verticalPixelRatio
      // 宽柱（类似成交量）：占满整根 bar 宽度，留 1px 间隙
      const barWidth = Math.max(1, Math.floor(data.barSpacing * data.conflationFactor) - 1)
      for (let i = data.visibleRange.from; i < data.visibleRange.to; i += 1) {
        const bar: CustomBarItemData<Time, MacdBarData> = data.bars[i]
        const item = bar.originalData
        const color = item.histColor || '#848E9C'
        const valueY = priceConverter(item.value)
        if (valueY == null) continue
        const top = Math.min(zeroY, valueY)
        const height = Math.max(1, Math.abs(zeroY - valueY))
        const left = Math.round(bar.x * xr) - Math.round(barWidth / 2)
        const topPx = Math.round(top * yr)
        const heightPx = Math.max(1, Math.round(height * yr))
        if (item.hollow && barWidth > 3) {
          // 空心柱：仅描边（柱宽过窄时退化为实心，保证可见）
          ctx.strokeStyle = color
          ctx.lineWidth = Math.max(1, Math.round(yr))
          ctx.strokeRect(
            left + ctx.lineWidth / 2,
            topPx + ctx.lineWidth / 2,
            barWidth - ctx.lineWidth,
            Math.max(0, heightPx - ctx.lineWidth)
          )
        } else {
          // 实心柱：直接填充
          ctx.fillStyle = color
          ctx.fillRect(left, topPx, barWidth, heightPx)
        }
      }
    })
  }

  destroy(): void {
    this._data = null
  }
}

class MacdHistogramSeries implements ICustomSeriesPaneView<Time, MacdBarData, CustomSeriesOptions> {
  private _renderer: MacdHistogramRenderer = new MacdHistogramRenderer()

  priceValueBuilder(plotRow: MacdBarData): CustomSeriesPricePlotValues {
    return [plotRow.value]
  }

  isWhitespace(
    data: MacdBarData | CustomSeriesWhitespaceData<Time>
  ): data is CustomSeriesWhitespaceData<Time> {
    return (data as Partial<MacdBarData>).value === undefined
  }

  update(
    data: PaneRendererCustomData<Time, MacdBarData>,
    _seriesOptions: CustomSeriesOptions
  ): void {
    this._renderer.update(data)
  }

  renderer(): ICustomSeriesPaneRenderer {
    return this._renderer
  }

  defaultOptions(): CustomSeriesOptions {
    return customSeriesDefaultOptions
  }

  destroy(): void {
    this._renderer.destroy()
  }
}

// ===== 指标设置（localStorage 持久化）=====

type IndicatorKey = 'ema21' | 'ema55' | 'ema144' | 'supertrend' | 'macd' | 'volume'

interface IndicatorState {
  enabled: boolean
  params: Record<string, number>
}

type KlineIndicatorSettings = Record<IndicatorKey, IndicatorState>

const INDICATOR_SETTINGS_KEY = 'tradetools:kline:indicators:v1'

const DEFAULT_INDICATOR_SETTINGS: KlineIndicatorSettings = {
  ema21: { enabled: true, params: { period: 21 } },
  ema55: { enabled: true, params: { period: 55 } },
  ema144: { enabled: true, params: { period: 144 } },
  supertrend: { enabled: true, params: { atrPeriod: 10, multiplier: 6 } },
  macd: { enabled: true, params: { fast: 12, slow: 26, signal: 9 } },
  volume: { enabled: true, params: {} },
}

interface IndicatorDef {
  key: IndicatorKey
  label: (s: IndicatorState) => string
  color?: string
  params: { key: string; label: string; min: number; max: number }[]
}

const INDICATOR_DEFS: IndicatorDef[] = [
  {
    key: 'ema21',
    color: CHART_BRAND.ema21,
    label: s => `EMA${s.params.period}`,
    params: [{ key: 'period', label: '周期', min: 2, max: 300 }],
  },
  {
    key: 'ema55',
    color: CHART_BRAND.ema55,
    label: s => `EMA${s.params.period}`,
    params: [{ key: 'period', label: '周期', min: 2, max: 300 }],
  },
  {
    key: 'ema144',
    color: CHART_BRAND.ema144,
    label: s => `EMA${s.params.period}`,
    params: [{ key: 'period', label: '周期', min: 2, max: 300 }],
  },
  {
    key: 'supertrend',
    label: () => 'Supertrend',
    params: [
      { key: 'atrPeriod', label: 'ATR 长度', min: 2, max: 100 },
      { key: 'multiplier', label: 'ATR 系数', min: 1, max: 20 },
    ],
  },
  {
    key: 'macd',
    label: () => 'MACD',
    params: [
      { key: 'fast', label: '快线', min: 2, max: 100 },
      { key: 'slow', label: '慢线', min: 2, max: 200 },
      { key: 'signal', label: '信号线', min: 2, max: 100 },
    ],
  },
  { key: 'volume', label: () => '成交量', params: [] },
]

function loadIndicatorSettings(): KlineIndicatorSettings {
  try {
    const raw = localStorage.getItem(INDICATOR_SETTINGS_KEY)
    if (!raw) return DEFAULT_INDICATOR_SETTINGS
    const parsed = JSON.parse(raw) as Partial<Record<IndicatorKey, Partial<IndicatorState>>>
    const merged: KlineIndicatorSettings = {
      ...DEFAULT_INDICATOR_SETTINGS,
      ema21: { ...DEFAULT_INDICATOR_SETTINGS.ema21 },
      ema55: { ...DEFAULT_INDICATOR_SETTINGS.ema55 },
      ema144: { ...DEFAULT_INDICATOR_SETTINGS.ema144 },
      supertrend: { ...DEFAULT_INDICATOR_SETTINGS.supertrend },
      macd: { ...DEFAULT_INDICATOR_SETTINGS.macd },
      volume: { ...DEFAULT_INDICATOR_SETTINGS.volume },
    }
    for (const def of INDICATOR_DEFS) {
      const item = parsed[def.key]
      if (item && typeof item.enabled === 'boolean') {
        merged[def.key] = {
          enabled: item.enabled,
          params: { ...DEFAULT_INDICATOR_SETTINGS[def.key].params, ...(item.params || {}) },
        }
      }
    }
    return merged
  } catch {
    return DEFAULT_INDICATOR_SETTINGS
  }
}

// ===== 组件 =====

interface KlineChartCardProps {
  symbol: string
  /** 十字光标滑动时回传当前价格（用于自动填充止损价等场景） */
  onCrosshairPrice?: (price: number) => void
  /** 持仓价格线（开仓/止损/止盈等），以虚线横线展示在 K 线图上 */
  priceLines?: Array<{ price: number; title: string; color: string }>
  /** 弹窗开关（受控）：传入后由外部控制弹窗开合 */
  open?: boolean
  /** 弹窗开关变化回调（配合受控 open 使用） */
  onOpenChange?: (open: boolean) => void
  /** 入口形态：header=标题行入口(默认)，icon=仅K线图标入口，none=不渲染入口(完全受控) */
  entry?: 'header' | 'icon' | 'button' | 'none'
  /** 是否展示止损价取价（开仓页弹窗展示，持仓页弹窗不展示） */
  stopLossEnabled?: boolean
  /** 弹窗底部长按钮（如信号页的“去开仓”），不传则不渲染 */
  bottomAction?: { label: string; onClick: () => void }
  /** 附加到根容器的样式（如嵌入卡片内部时去外边距、加边框） */
  className?: string
}

export function KlineChartCard({
  symbol,
  onCrosshairPrice,
  priceLines,
  open,
  onOpenChange,
  entry = 'header',
  stopLossEnabled = false,
  bottomAction,
  className = '',
}: KlineChartCardProps) {
  const [interval, setInterval] = useState<string>('15m')
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')
  const [streamStatus, setStreamStatus] = useState<BinanceKlineStreamStatus>('disconnected')
  const streamConnected = streamStatus === 'connected'
  const [lastTrend, setLastTrend] = useState<'up' | 'down' | null>(null)
  const [settings, setSettings] = useState<KlineIndicatorSettings>(() => loadIndicatorSettings())
  const [showSettings, setShowSettings] = useState(false)
  const [expandedIndicator, setExpandedIndicator] = useState<IndicatorKey | null>(null)
  // 弹窗内十字光标滑动获取的价格（用于底部止损价展示）
  const [crosshairPrice, setCrosshairPrice] = useState<number | null>(null)
  const { theme } = useTheme()
  const palette = useMemo(() => getChartPalette(theme), [theme])
  // 大图弹窗：竖版左右通栏 + 模糊蒙层，通过 Portal 渲染到 body 避免祖先层叠上下文遮挡
  const [fullscreen, setFullscreen] = useState(false)
  // 受控模式：外部 open 变化时同步内部状态
  useEffect(() => {
    if (open !== undefined) setFullscreen(open)
  }, [open])
  // 统一的开关入口：内部更新 + 通知外部（受控时由外部回写 open 保持一致）
  const requestFullscreen = useCallback(
    (next: boolean) => {
      setFullscreen(next)
      onOpenChange?.(next)
    },
    [onOpenChange]
  )

  const containerRef = useRef<HTMLDivElement | null>(null)
  // 十字光标自定义价格标签容器（价格 + 百分比）
  const crosshairLabelRef = useRef<HTMLDivElement | null>(null)
  const lastCandlesRef = useRef<KlineCandle[]>([])
  const macdZeroLineRef = useRef<IPriceLine | null>(null)
  const chartRef = useRef<IChartApi | null>(null)
  const candleSeriesRef = useRef<ISeriesApi<'Candlestick'> | null>(null)
  const volumeSeriesRef = useRef<ISeriesApi<'Histogram'> | null>(null)
  const ema21SeriesRef = useRef<ISeriesApi<'Line'> | null>(null)
  const ema55SeriesRef = useRef<ISeriesApi<'Line'> | null>(null)
  const ema144SeriesRef = useRef<ISeriesApi<'Line'> | null>(null)
  const macdDifSeriesRef = useRef<ISeriesApi<'Line'> | null>(null)
  const macdDeaSeriesRef = useRef<ISeriesApi<'Line'> | null>(null)
  const macdHistSeriesRef = useRef<ISeriesApi<'Custom'> | null>(null)
  const supertrendSeriesRefs = useRef<ISeriesApi<'Line'>[]>([])
  const onCrosshairPriceRef = useRef(onCrosshairPrice)
  onCrosshairPriceRef.current = onCrosshairPrice
  // 持仓价格线（开仓/止损/止盈）：用 ref 持有最新值，避免 loadKlines 依赖频繁变化
  const priceLinesRef = useRef(priceLines)
  priceLinesRef.current = priceLines
  const positionLineRefs = useRef<IPriceLine[]>([])
  // 性能优化状态：设置/主题签名（全量重绘门控）、价格线签名、最后一段 Supertrend 趋势
  const fullApplySigRef = useRef('')
  const lastPositionSigRef = useRef('')
  const lastSupertrendTrendRef = useRef<boolean | null>(null)
  const symbolRef = useRef(symbol)
  symbolRef.current = symbol
  const intervalRef = useRef(interval)
  intervalRef.current = interval
  const pendingStreamCandleRef = useRef<KlineCandle | null>(null)
  const lastStreamCandleRef = useRef<KlineCandle | null>(null)
  const boundaryRefreshKeyRef = useRef('')
  const boundaryRefreshTimerRef = useRef<number | null>(null)
  const streamApplyTimerRef = useRef<number | null>(null)
  const chartGenerationRef = useRef(0)

  const destroyChart = useCallback(() => {
    chartGenerationRef.current += 1
    if (chartRef.current) {
      chartRef.current.remove()
      chartRef.current = null
    }
    candleSeriesRef.current = null
    volumeSeriesRef.current = null
    ema21SeriesRef.current = null
    ema55SeriesRef.current = null
    ema144SeriesRef.current = null
    macdDifSeriesRef.current = null
    macdDeaSeriesRef.current = null
    macdHistSeriesRef.current = null
    macdZeroLineRef.current = null
    supertrendSeriesRefs.current = []
    positionLineRefs.current = []
    // 图表销毁后需重新全量绘制，清除增量/缓存签名与旧数据
    fullApplySigRef.current = ''
    lastPositionSigRef.current = ''
    lastSupertrendTrendRef.current = null
    lastCandlesRef.current = []
    pendingStreamCandleRef.current = null
    lastStreamCandleRef.current = null
    boundaryRefreshKeyRef.current = ''
    if (boundaryRefreshTimerRef.current !== null) {
      window.clearTimeout(boundaryRefreshTimerRef.current)
      boundaryRefreshTimerRef.current = null
    }
    if (streamApplyTimerRef.current !== null) {
      window.clearTimeout(streamApplyTimerRef.current)
      streamApplyTimerRef.current = null
    }
  }, [])

  const exitFullscreen = useCallback(() => {
    requestFullscreen(false)
  }, [requestFullscreen])

  // 同步持仓价格虚线：签名未变则跳过，避免每轮刷新重复移除/创建价格线
  const syncPositionLines = useCallback(() => {
    const series = candleSeriesRef.current
    if (!series) return
    const sig = (priceLinesRef.current || [])
      .map(item => `${item.price}|${item.title}|${item.color}`)
      .join(',')
    if (sig === lastPositionSigRef.current) return
    lastPositionSigRef.current = sig
    for (const line of positionLineRefs.current) series.removePriceLine(line)
    positionLineRefs.current = []
    for (const item of priceLinesRef.current || []) {
      if (!Number.isFinite(item.price) || item.price <= 0) continue
      positionLineRefs.current.push(
        series.createPriceLine({
          price: item.price,
          color: item.color,
          lineWidth: 1,
          lineStyle: LineStyle.Dashed,
          axisLabelVisible: true,
          title: item.title,
        })
      )
    }
  }, [])

  const initChart = useCallback(() => {
    const container = containerRef.current
    if (!container) return
    destroyChart()

    const chart = createChart(container, {
      layout: {
        background: { type: ColorType.Solid, color: palette.bg },
        textColor: palette.textMuted,
        fontSize: 10,
        // 主图/MACD 副图高度固定，禁止拖拽分隔条调整
        panes: { enableResize: false },
      },
      // 右侧价格轴标签动态压缩小数位：按可见价格范围决定精度，
      // 缩短标签宽度，让轴更窄、给 K 线区域留出更多空间
      localization: {
        priceFormatter: (price: number) => formatChartPrice(price),
      },
      grid: {
        vertLines: { color: palette.grid },
        horzLines: { color: palette.grid },
      },
      rightPriceScale: {
        borderColor: palette.border,
        scaleMargins: { top: 0.08, bottom: 0.22 },
      },
      timeScale: {
        borderColor: palette.border,
        timeVisible: true,
        secondsVisible: false,
        // 右侧预留留白：新K线刷出来后不会被顶到屏幕外
        rightOffset: 8,
      },
      crosshair: {
        mode: CrosshairMode.Normal,
        vertLine: { color: palette.textMuted, labelBackgroundColor: palette.text },
        // 隐藏原生横线价格标签，改用自定义标签（价格 + 距当前价百分比两行）
        horzLine: {
          color: palette.textMuted,
          labelBackgroundColor: palette.text,
          labelVisible: false,
        },
      },
      // 长按进入十字光标跟踪（查看）模式后，手指抬起即退出：
      // 默认 OnNextTap 需再点一下才能退出，且退出前拖动被禁用
      trackingMode: { exitMode: TrackingModeExitMode.OnTouchEnd },
      width: container.clientWidth,
      height: container.clientHeight,
    })

    candleSeriesRef.current = chart.addSeries(CandlestickSeries, {
      upColor: palette.up,
      downColor: palette.down,
      wickUpColor: palette.up,
      wickDownColor: palette.down,
      borderVisible: false,
      priceFormat: { type: 'price', precision: 8, minMove: 0.00000001 },
    })
    volumeSeriesRef.current = chart.addSeries(HistogramSeries, {
      priceFormat: { type: 'volume' },
      priceScaleId: 'vol',
      // 隐藏成交量末值标签：数字过大（如 2266704.00）会落在主图/MACD 分隔线上，既难读又挤宽右侧区域
      lastValueVisible: false,
      priceLineVisible: false,
    })
    chart.priceScale('vol').applyOptions({ scaleMargins: { top: 0.85, bottom: 0 } })

    const emaBase = {
      lineWidth: 1 as const,
      priceLineVisible: false,
      lastValueVisible: false,
      crosshairMarkerVisible: false,
    }
    ema21SeriesRef.current = chart.addSeries(LineSeries, { ...emaBase, color: palette.ema21 })
    ema55SeriesRef.current = chart.addSeries(LineSeries, { ...emaBase, color: palette.ema55 })
    ema144SeriesRef.current = chart.addSeries(LineSeries, { ...emaBase, color: palette.ema144 })

    // MACD 副图（pane 1）：快线 DIF 用 EMA21 同色绿，慢线 DEA 用 EMA144 同色紫，能量柱增加实心/减少空心
    const macdHistSeries = chart.addCustomSeries(
      new MacdHistogramSeries(),
      {
        priceLineVisible: false,
        lastValueVisible: false,
        // 精度由 localization.priceFormatter 动态压缩，避免 MACD 轴标签小数过长
        priceFormat: { type: 'price', precision: 8, minMove: 0.00000001 },
      },
      1
    )
    macdHistSeriesRef.current = macdHistSeries
    // MACD 副图固定高度，避免与主图平分
    chart.panes()[1]?.setHeight(80)
    macdDifSeriesRef.current = chart.addSeries(LineSeries, { ...emaBase, color: palette.ema21 }, 1)
    macdDeaSeriesRef.current = chart.addSeries(LineSeries, { ...emaBase, color: palette.ema144 }, 1)

    // 十字光标移动时记录光标价格（弹窗底部展示），并回传给外部（如开仓页止损价）；
    // 同时在右侧轴位置更新自定义标签：价格 + 距当前价（最后一根收盘）的百分比
    const label = crosshairLabelRef.current
    if (label) label.style.display = 'none'
    chart.subscribeCrosshairMove(param => {
      const labelEl = crosshairLabelRef.current
      if (!param.point || !candleSeriesRef.current || param.paneIndex !== 0) {
        if (labelEl) labelEl.style.display = 'none'
        return
      }
      const price = candleSeriesRef.current.coordinateToPrice(param.point.y)
      if (typeof price === 'number' && Number.isFinite(price) && price > 0) {
        setCrosshairPrice(price)
        onCrosshairPriceRef.current?.(price)
        if (labelEl) {
          const candles = lastCandlesRef.current
          const current = candles.length > 0 ? Number(candles[candles.length - 1].c) : NaN
          labelEl.style.display = 'flex'
          labelEl.style.top = `${param.point.y}px`
          const priceEl = labelEl.firstElementChild as HTMLElement
          const pctEl = labelEl.lastElementChild as HTMLElement
          if (priceEl) priceEl.textContent = formatChartPrice(price)
          if (pctEl) {
            if (Number.isFinite(current) && current > 0) {
              const pct = ((price - current) / current) * 100
              pctEl.textContent = `${pct >= 0 ? '+' : ''}${pct.toFixed(2)}%`
              pctEl.style.color = pct >= 0 ? palette.up : palette.down
            } else {
              pctEl.textContent = ''
            }
          }
        }
      } else if (labelEl) {
        labelEl.style.display = 'none'
      }
    })

    chartRef.current = chart
  }, [destroyChart, palette])

  const applyCandles = useCallback(
    (candles: KlineCandle[]) => {
      if (!candleSeriesRef.current || candles.length === 0) return
      const prevCandles = lastCandlesRef.current
      lastCandlesRef.current = candles
      // 记录应用前视窗是否贴着最新K线（或首次加载）：是才在刷新后自动滚回最新，
      // 避免打扰正在回看历史的用户
      const visibleBefore = chartRef.current?.timeScale().getVisibleLogicalRange()
      const stickToLatest =
        prevCandles.length === 0 ||
        (visibleBefore != null && visibleBefore.to >= prevCandles.length - 1.5)

      const closes = candles.map(c => Number(c.c))
      const highs = candles.map(c => Number(c.h))
      const lows = candles.map(c => Number(c.l))

      const ema21 = calcEma(closes, settings.ema21.params.period)
      const ema55 = calcEma(closes, settings.ema55.params.period)
      const ema144 = calcEma(closes, settings.ema144.params.period)
      const supertrend = calcSupertrend(
        highs,
        lows,
        closes,
        settings.supertrend.params.atrPeriod,
        settings.supertrend.params.multiplier
      )
      const macd = calcMacd(
        closes,
        settings.macd.params.fast,
        settings.macd.params.slow,
        settings.macd.params.signal
      )

      const lastIdx = candles.length - 1
      const lastT = candles[lastIdx].t as UTCTimestamp

      // Supertrend 分段重建（全量路径与趋势反转时复用）
      const rebuildSupertrendSegments = () => {
        const chart = chartRef.current
        if (!chart) return
        for (const series of supertrendSeriesRefs.current) {
          chart.removeSeries(series)
        }
        supertrendSeriesRefs.current = []
        lastSupertrendTrendRef.current = null
        if (!settings.supertrend.enabled) return
        interface Segment {
          trendUp: boolean
          points: { time: UTCTimestamp; value: number }[]
        }
        const segments: Segment[] = []
        let current: Segment | null = null
        candles.forEach((c, i) => {
          const value = supertrend.line[i]
          if (value === null) return
          const trendUp = supertrend.trendUp[i]
          if (!current || current.trendUp !== trendUp) {
            current = { trendUp, points: [] }
            segments.push(current)
          }
          current.points.push({ time: c.t as UTCTimestamp, value })
          lastSupertrendTrendRef.current = trendUp
        })
        for (const segment of segments) {
          const series = chart.addSeries(LineSeries, {
            lineWidth: 2,
            color: segment.trendUp ? palette.up : palette.down,
            priceLineVisible: false,
            lastValueVisible: false,
            crosshairMarkerVisible: false,
          })
          series.setData(segment.points)
          supertrendSeriesRefs.current.push(series)
        }
      }

      // 设置/主题签名：变化时才全量重绘（含 applyOptions 可见性同步）
      const settingsSig = `${JSON.stringify(settings)}|${palette.up}|${palette.down}`
      const settingsChanged = fullApplySigRef.current !== settingsSig
      // 增量快路径：同一窗口（未收新K线、窗口未滑动），仅最后一根在变动，
      // 用 update() 追加最后一根，避免约 10 条序列的全量 setData 重绘
      const incremental =
        !settingsChanged &&
        canUpdateLatestKline(prevCandles, candles)

      if (incremental) {
        const last = candles[lastIdx]
        candleSeriesRef.current.update({
          time: lastT,
          open: Number(last.o),
          high: Number(last.h),
          low: Number(last.l),
          close: Number(last.c),
        })
        volumeSeriesRef.current?.update({
          time: lastT,
          value: Number(last.v),
          color:
            Number(last.c) >= Number(last.o)
              ? 'rgba(14, 203, 129, 0.35)'
              : 'rgba(246, 70, 93, 0.35)',
        })
        const emaUpdates: [ISeriesApi<'Line'> | null, (number | null)[]][] = [
          [ema21SeriesRef.current, ema21],
          [ema55SeriesRef.current, ema55],
          [ema144SeriesRef.current, ema144],
        ]
        for (const [series, values] of emaUpdates) {
          const v = values[lastIdx]
          if (series && v !== null) series.update({ time: lastT, value: v })
        }
        macdDifSeriesRef.current?.update({ time: lastT, value: macd.dif[lastIdx] })
        macdDeaSeriesRef.current?.update({ time: lastT, value: macd.dea[lastIdx] })
        macdHistSeriesRef.current?.update({
          time: lastT,
          value: macd.hist[lastIdx],
          hollow: !macd.increasing[lastIdx],
          histColor: macd.hist[lastIdx] >= 0 ? palette.up : palette.down,
        } as MacdBarData)
        // Supertrend：趋势不变则只补最后一点；趋势反转才重建分段（罕见）
        if (settings.supertrend.enabled) {
          const value = supertrend.line[lastIdx]
          const trendUp = value !== null ? supertrend.trendUp[lastIdx] : null
          if (
            value !== null &&
            trendUp === lastSupertrendTrendRef.current &&
            supertrendSeriesRefs.current.length > 0
          ) {
            supertrendSeriesRefs.current[supertrendSeriesRefs.current.length - 1].update({
              time: lastT,
              value,
            })
          } else if (value !== null || supertrendSeriesRefs.current.length > 0) {
            rebuildSupertrendSegments()
          }
        }
      } else {
        fullApplySigRef.current = settingsSig

        candleSeriesRef.current.setData(
          candles.map(c => ({
            time: c.t as UTCTimestamp,
            open: Number(c.o),
            high: Number(c.h),
            low: Number(c.l),
            close: Number(c.c),
          }))
        )
        volumeSeriesRef.current?.applyOptions({ visible: settings.volume.enabled })
        volumeSeriesRef.current?.setData(
          candles.map(c => ({
            time: c.t as UTCTimestamp,
            value: Number(c.v),
            color:
              Number(c.c) >= Number(c.o) ? 'rgba(14, 203, 129, 0.35)' : 'rgba(246, 70, 93, 0.35)',
          }))
        )

        const toLineData = (values: (number | null)[]) =>
          candles
            .map((c, i) => ({ time: c.t as UTCTimestamp, value: values[i] }))
            .filter(p => p.value !== null) as { time: UTCTimestamp; value: number }[]

        const emaConfigs: [ISeriesApi<'Line'> | null, (number | null)[], boolean][] = [
          [ema21SeriesRef.current, ema21, settings.ema21.enabled],
          [ema55SeriesRef.current, ema55, settings.ema55.enabled],
          [ema144SeriesRef.current, ema144, settings.ema144.enabled],
        ]
        for (const [series, values, enabled] of emaConfigs) {
          if (!series) continue
          series.applyOptions({ visible: enabled })
          series.setData(toLineData(values))
        }

        // MACD 副图数据与开关
        const macdOn = settings.macd.enabled
        const histSeries = macdHistSeriesRef.current
        histSeries?.applyOptions({ visible: macdOn })
        macdDifSeriesRef.current?.applyOptions({ visible: macdOn })
        macdDeaSeriesRef.current?.applyOptions({ visible: macdOn })
        if (histSeries) {
          if (macdOn && !macdZeroLineRef.current) {
            macdZeroLineRef.current = histSeries.createPriceLine({
              price: 0,
              color: palette.border,
              lineWidth: 1,
              lineStyle: LineStyle.Solid,
              axisLabelVisible: false,
              title: '',
            })
          } else if (!macdOn && macdZeroLineRef.current) {
            histSeries.removePriceLine(macdZeroLineRef.current)
            macdZeroLineRef.current = null
          }
        }
        macdDifSeriesRef.current?.setData(
          candles.map((c, i) => ({ time: c.t as UTCTimestamp, value: macd.dif[i] }))
        )
        macdDeaSeriesRef.current?.setData(
          candles.map((c, i) => ({ time: c.t as UTCTimestamp, value: macd.dea[i] }))
        )
        histSeries?.setData(
          candles.map((c, i) => ({
            time: c.t as UTCTimestamp,
            value: macd.hist[i],
            hollow: !macd.increasing[i],
            histColor: macd.hist[i] >= 0 ? palette.up : palette.down,
          }))
        )

        rebuildSupertrendSegments()
      }

      if (!settings.supertrend.enabled || supertrend.line[lastIdx] === null) {
        setLastTrend(null)
      } else {
        setLastTrend(supertrend.trendUp[lastIdx] ? 'up' : 'down')
      }

      // 每次数据应用后同步持仓价格虚线（内部有签名缓存）
      syncPositionLines()

      // 视窗原本贴着最新K线时，刷新后自动滚回最新（配合 rightOffset 留白）
      if (stickToLatest) chartRef.current?.timeScale().scrollToRealTime()
    },
    [settings, palette, syncPositionLines]
  )

  // 通过 ref 调用最新的 applyCandles，避免设置变更引起 loadKlines 重建导致图表重新初始化
  const applyCandlesRef = useRef(applyCandles)
  applyCandlesRef.current = applyCandles

  const loadKlines = useCallback(
    async (fromOrigin = false): Promise<KlineCandle[] | null> => {
      if (!symbol) return null
      const reqSymbol = symbol
      const reqInterval = interval
      const generation = chartGenerationRef.current
      try {
        const snapshot = await (fromOrigin ? fetchOriginKlineSnapshot : fetchKlineSnapshot)(
          reqSymbol,
          reqInterval,
          KLINE_LIMIT
        )
        // 请求返回时周期/币种已切换：旧周期数据作废，避免画到新周期图表上
        if (generation !== chartGenerationRef.current ||
            reqSymbol !== symbolRef.current || reqInterval !== intervalRef.current) return null
        const candles = reconcileKlineSnapshot(
          snapshot,
          lastCandlesRef.current,
          lastStreamCandleRef.current,
          fromOrigin
        )
        setError('')
        applyCandlesRef.current(candles)
        return snapshot
      } catch {
        if (
          reqSymbol === symbolRef.current &&
          reqInterval === intervalRef.current &&
          generation === chartGenerationRef.current &&
          lastCandlesRef.current.length === 0
        ) {
          setError('K线加载失败')
        }
        return null
      }
    },
    [symbol, interval]
  )

  // 手动刷新：带“刷新中”状态，同周期并发请求由快照模块统一复用。
  const [manualRefreshing, setManualRefreshing] = useState(false)
  const handleManualRefresh = useCallback(async () => {
    if (manualRefreshing) return
    setManualRefreshing(true)
    try {
      await loadKlines(true)
    } finally {
      setManualRefreshing(false)
    }
  }, [manualRefreshing, loadKlines])

  // 弹窗打开/切换周期时先画本地缓存首帧，再由服务端完整快照静默校准。
  useEffect(() => {
    if (!fullscreen || !symbol) return
    initChart()
    const cached = getKlineCache(symbol, interval)
    if (cached) {
      applyCandlesRef.current(cached.candles)
      setLoading(false)
      setError('')
    } else {
      setLoading(true)
    }
    // 长按跟踪模式由 trackingMode.exitMode=OnTouchEnd 在库内部退出并清光标；
    // 这里只补一步：手指抬起时重置自定义标签与光标价格状态
    const container = containerRef.current
    const releaseCrosshair = () => {
      const labelEl = crosshairLabelRef.current
      if (labelEl) labelEl.style.display = 'none'
      setCrosshairPrice(null)
    }
    container?.addEventListener('touchend', releaseCrosshair)
    container?.addEventListener('touchcancel', releaseCrosshair)
    let cancelled = false
    loadKlines().finally(() => {
      if (!cancelled) setLoading(false)
    })
    return () => {
      cancelled = true
      if (lastCandlesRef.current.length > 0) {
        setKlineCache(symbol, interval, lastCandlesRef.current)
      }
      container?.removeEventListener('touchend', releaseCrosshair)
      container?.removeEventListener('touchcancel', releaseCrosshair)
      destroyChart()
    }
  }, [fullscreen, symbol, interval, initChart, destroyChart, loadKlines])

  // 当前周期首帧不等待预取；其余周期在后台独立补齐，之后切换可直接读对应缓存。
  useEffect(() => {
    if (!fullscreen || !symbol) return
    void prefetchMissingKlineIntervals(symbol, KLINE_INTERVAL_VALUES, interval, KLINE_LIMIT)
  }, [fullscreen, symbol, interval])

  // Binance 公共 WS 只负责行情，不带账户凭证；实时消息节流后合并到最近 300 根。
  useEffect(() => {
    if (!fullscreen || !symbol) return
    setStreamStatus('connecting')
    let stopped = false
    const scheduleStreamCalibration = (
      refreshKey: string,
      liveOpenTime: number,
      attempt: number
    ) => {
      const delay = STREAM_CALIBRATION_DELAYS_MS[attempt]
      boundaryRefreshTimerRef.current = window.setTimeout(() => {
        boundaryRefreshTimerRef.current = null
        if (stopped || boundaryRefreshKeyRef.current !== refreshKey) return
        if (document.visibilityState !== 'visible') {
          scheduleStreamCalibration(refreshKey, liveOpenTime, attempt)
          return
        }
        void loadKlines(true).then(snapshot => {
          if (stopped || boundaryRefreshKeyRef.current !== refreshKey) return
          const latest = snapshot?.[snapshot.length - 1]
          if (latest && latest.t >= liveOpenTime) return
          const nextAttempt = attempt + 1
          if (nextAttempt < STREAM_CALIBRATION_DELAYS_MS.length) {
            scheduleStreamCalibration(refreshKey, liveOpenTime, nextAttempt)
          }
        })
      }, delay)
    }
    const stop = startBinanceKlineStream({
      symbol,
      interval,
      onStatus: status => {
        setStreamStatus(status)
        if (status === 'connected') return
        lastStreamCandleRef.current = null
        pendingStreamCandleRef.current = null
        boundaryRefreshKeyRef.current = ''
        if (streamApplyTimerRef.current !== null) {
          window.clearTimeout(streamApplyTimerRef.current)
          streamApplyTimerRef.current = null
        }
        if (boundaryRefreshTimerRef.current !== null) {
          window.clearTimeout(boundaryRefreshTimerRef.current)
          boundaryRefreshTimerRef.current = null
        }
      },
      onCandle: candle => {
        const last = lastStreamCandleRef.current
        if (last && (candle.t < last.t ||
            (candle.t === last.t && Number(candle.v) < Number(last.v)))) return
        lastStreamCandleRef.current = candle
        const refreshKey = `${symbol}|${interval}|${candle.t}`
        if (boundaryRefreshKeyRef.current !== refreshKey) {
          if (boundaryRefreshTimerRef.current !== null) {
            window.clearTimeout(boundaryRefreshTimerRef.current)
            boundaryRefreshTimerRef.current = null
          }
          boundaryRefreshKeyRef.current = refreshKey
          scheduleStreamCalibration(refreshKey, candle.t, 0)
        }
        pendingStreamCandleRef.current = candle
        if (streamApplyTimerRef.current !== null) return
        streamApplyTimerRef.current = window.setTimeout(() => {
          streamApplyTimerRef.current = null
          const pending = pendingStreamCandleRef.current
          pendingStreamCandleRef.current = null
          if (!pending) return
          const candles = mergeKlineCandle(lastCandlesRef.current, pending)
          setError('')
          setLoading(false)
          applyCandlesRef.current(candles)
        }, STREAM_APPLY_THROTTLE_MS)
      },
    })
    return () => {
      stopped = true
      stop()
      pendingStreamCandleRef.current = null
      lastStreamCandleRef.current = null
      boundaryRefreshKeyRef.current = ''
      if (boundaryRefreshTimerRef.current !== null) {
        window.clearTimeout(boundaryRefreshTimerRef.current)
        boundaryRefreshTimerRef.current = null
      }
      if (streamApplyTimerRef.current !== null) {
        window.clearTimeout(streamApplyTimerRef.current)
        streamApplyTimerRef.current = null
      }
    }
  }, [fullscreen, symbol, interval, loadKlines])

  // 初始历史走边缘缓存；后续校准始终读短缓存，避免旧快照撤销已修正的历史。
  useEffect(() => {
    if (!fullscreen || !symbol) return
    const pollInterval =
      streamConnected ? SERVER_CALIBRATION_INTERVAL_MS : FALLBACK_POLL_INTERVAL_MS
    const timer = window.setInterval(() => {
      if (document.visibilityState !== 'visible') return
      void loadKlines(true)
    }, pollInterval)
    return () => window.clearInterval(timer)
  }, [fullscreen, symbol, interval, streamConnected, loadKlines])

  // 持久化指标设置
  useEffect(() => {
    try {
      localStorage.setItem(INDICATOR_SETTINGS_KEY, JSON.stringify(settings))
    } catch {
      // 忽略写入失败
    }
  }, [settings])

  // 设置变更后用最近 K 线立即重算指标（无需重新请求）
  useEffect(() => {
    if (!fullscreen || lastCandlesRef.current.length === 0) return
    applyCandles(lastCandlesRef.current)
  }, [settings, fullscreen, applyCandles])

  // 持仓价格线变化时立即同步（无需等待下次 K 线刷新）
  useEffect(() => {
    if (!fullscreen || lastCandlesRef.current.length === 0) return
    syncPositionLines()
  }, [priceLines, fullscreen, syncPositionLines])

  const adjustParam = (
    key: IndicatorKey,
    paramKey: string,
    min: number,
    max: number,
    delta: number
  ) => {
    setSettings(prev => {
      const cur = prev[key].params[paramKey] ?? min
      const next = Math.min(max, Math.max(min, cur + delta))
      return { ...prev, [key]: { ...prev[key], params: { ...prev[key].params, [paramKey]: next } } }
    })
  }

  const handleIntervalChange = useCallback(
    (nextInterval: string) => {
      if (nextInterval === interval) return
      if (lastCandlesRef.current.length > 0) {
        setKlineCache(symbol, interval, lastCandlesRef.current)
      }
      // useEffect 在浏览器绘制后才清理；这里先同步移除旧画布，避免标题已变而画面仍短暂显示上一周期。
      destroyChart()
      setError('')
      setLoading(getKlineCache(symbol, nextInterval) === null)
      setStreamStatus('connecting')
      setInterval(nextInterval)
    },
    [destroyChart, interval, symbol]
  )

  // 容器尺寸变化
  useEffect(() => {
    if (!fullscreen || !containerRef.current) return
    const observer = new ResizeObserver(entries => {
      const entry = entries[0]
      if (!entry || !chartRef.current) return
      chartRef.current.applyOptions({
        width: entry.contentRect.width,
        height: entry.contentRect.height,
      })
    })
    observer.observe(containerRef.current)
    return () => observer.disconnect()
  }, [fullscreen])

  // 大图弹窗打开期间锁定页面滚动：避免手指拖动带动页面滚动，
  // 触发 iOS 地址栏伸缩/dvh 变化导致弹窗闪烁、顶部标题露出
  useEffect(() => {
    if (!fullscreen) return
    const body = document.body
    const scrollY = window.scrollY
    const prev = {
      overflow: body.style.overflow,
      position: body.style.position,
      top: body.style.top,
      width: body.style.width,
    }
    body.style.overflow = 'hidden'
    body.style.position = 'fixed'
    body.style.top = `-${scrollY}px`
    body.style.width = '100%'
    const preventTouchMove = (e: TouchEvent) => e.preventDefault()
    document.addEventListener('touchmove', preventTouchMove, { passive: false })
    return () => {
      body.style.overflow = prev.overflow
      body.style.position = prev.position
      body.style.top = prev.top
      body.style.width = prev.width
      document.removeEventListener('touchmove', preventTouchMove)
      window.scrollTo(0, scrollY)
    }
  }, [fullscreen])

  return (
    <>
      {entry === 'icon' ? (
        // 图标入口：由外部决定摆放位置（如持仓卡片右上角）
        <button
          type="button"
          onClick={() => requestFullscreen(true)}
          className={`p-1 text-t-text-muted hover:text-t-text transition-colors ${className}`}
          aria-label="K线图"
        >
          <CandlestickChart size={18} />
        </button>
      ) : entry === 'button' ? (
        // 短按钮入口：图标+K线文字，宽度仅包含内容（如持仓卡片底部按钮区左侧）
        <button
          type="button"
          onClick={() => requestFullscreen(true)}
          className={`shrink-0 flex items-center gap-1 px-2.5 py-2 rounded-lg text-sm font-medium transition-colors border border-t-border bg-t-btn-secondary text-t-text hover:bg-t-btn-secondary-hover ${className}`}
          aria-label="K线图"
        >
          <CandlestickChart size={16} />
          <span>K线</span>
        </button>
      ) : entry === 'header' ? (
        <div
          className={`rounded-lg mb-4 overflow-hidden transition-colors bg-t-surface ${className}`}
        >
          <button
            type="button"
            onClick={() => requestFullscreen(!fullscreen)}
            className="w-full flex items-center gap-2 px-4 py-3 text-left"
            aria-expanded={fullscreen}
          >
            <span className="text-sm font-medium text-t-text">K线图</span>
            {symbol && <span className="text-xs text-t-text-muted">{symbol}</span>}
            {fullscreen && lastTrend && (
              <span
                className={`text-xs px-1.5 py-0.5 rounded ${
                  lastTrend === 'up'
                    ? 'text-[#0ECB81] bg-[#0ECB81]/10'
                    : 'text-[#F6465D] bg-[#F6465D]/10'
                }`}
              >
                ST{lastTrend === 'up' ? '多' : '空'}
              </span>
            )}
            <ChevronDown
              size={18}
              className={`ml-auto text-t-text-muted transition-transform ${fullscreen ? 'rotate-180' : ''}`}
            />
          </button>
        </div>
      ) : null}

      {/* K线大图弹出框：顶部右侧设置+关闭按钮，点遮罩或关闭按钮退出；Portal 到 body 避免被页面层叠遮挡 */}
      {fullscreen &&
        createPortal(
          <div
            className="fixed inset-0 z-[130] flex items-center justify-center bg-black/50 backdrop-blur-md"
            style={{ touchAction: 'none', overscrollBehavior: 'none' }}
            onClick={exitFullscreen}
          >
            {/* 竖版左右通栏弹窗：宽度铺满屏幕，高度约 3/4 屏高，上下边框+四周圆角，不旋转避免 canvas 模糊 */}
            <div
              className="relative flex flex-col w-full overflow-hidden rounded-2xl border-y border-t-border shadow-2xl"
              style={{
                backgroundColor: palette.bg,
                height: 'calc(100dvh * 0.75)',
              }}
              onClick={e => e.stopPropagation()}
            >
              <div className="flex items-center px-3 py-2">
                <span className="text-xs text-t-text-muted">
                  {symbol} · {INTERVALS.find(i => i.value === interval)?.label ?? interval}
                </span>
                {stopLossEnabled &&
                  // 已有光标价时显示止损价；未取价时在止损价位置显示滑动取价提示
                  (crosshairPrice !== null ? (
                    <span className="ml-2 text-xs text-t-text-muted">
                      止损价：
                      <span className="font-medium text-t-text">
                        {formatChartPrice(crosshairPrice)}
                      </span>
                    </span>
                  ) : (
                    <span className="ml-2 text-[10px] text-t-text-muted">
                      滑动可将光标价格填入止损价
                    </span>
                  ))}
                {loading && <span className="ml-2 text-xs text-t-text-muted">加载中...</span>}
                {!loading && error && <span className="ml-2 text-xs text-[#F6465D]">{error}</span>}
                {/* 右上角：设置在左，浅黄色关闭按钮在右 */}
                <div className="ml-auto flex items-center gap-2">
                  <button
                    type="button"
                    onClick={() => setShowSettings(true)}
                    className="p-1 text-t-text-muted hover:text-t-text transition-colors"
                    aria-label="指标设置"
                  >
                    <SettingsIcon size={16} />
                  </button>
                  <button
                    type="button"
                    onClick={exitFullscreen}
                    className="rounded-lg bg-[#F0B90B]/15 px-5 py-1.5 text-sm font-medium text-[#F0B90B] transition-colors"
                  >
                    关闭
                  </button>
                </div>
              </div>
              {/* 周期切换行：与内嵌展开一致 */}
              <div className="flex items-center gap-1 px-3 pb-2">
                {INTERVALS.map(item => (
                  <button
                    key={item.value}
                    type="button"
                    onClick={() => handleIntervalChange(item.value)}
                    className={`px-2 py-1 rounded text-xs transition-colors ${
                      interval === item.value
                        ? 'bg-[#F0B90B] text-black font-medium'
                        : 'text-t-text-muted hover:bg-t-surface-hover'
                    }`}
                  >
                    {item.label}
                  </button>
                ))}
              </div>
              {/* 图表区：touch-action: none，上下/左右滑动由图表自己处理，十字光标价格回传止损价 */}
              <div className="relative flex-1 min-h-0">
                <div
                  ref={containerRef}
                  className="absolute inset-0"
                  style={{ touchAction: 'none' }}
                />
                {/* 十字光标自定义价格标签：价格 + 距当前价百分比（直接 DOM 更新，不触发 React 重渲染） */}
                <div
                  ref={crosshairLabelRef}
                  className="pointer-events-none absolute z-10 -translate-y-1/2 flex-col rounded px-1 py-0.5 text-center"
                  style={{ display: 'none', right: 0, width: 56, background: palette.text }}
                >
                  <span
                    className="block text-[10px] font-medium leading-tight"
                    style={{ color: palette.bg }}
                  />
                  <span className="block text-[10px] font-medium leading-tight" />
                </div>
                {loading && (
                  <div className="absolute inset-0 flex items-center justify-center text-xs text-t-text-muted">
                    正在加载中
                  </div>
                )}
                {!loading && error && (
                  <div className="absolute inset-0 flex items-center justify-center text-xs text-[#F6465D]">
                    {error}
                  </div>
                )}
              </div>
              {/* 底部说明：持仓弹窗去掉止损价相关文案 */}
              <div className="flex items-center justify-between px-3 py-1.5">
                <span className="text-[10px] text-t-text-muted">
                  ST({settings.supertrend.params.atrPeriod},{settings.supertrend.params.multiplier})
                  · MACD({settings.macd.params.fast},{settings.macd.params.slow},
                  {settings.macd.params.signal}) 实心增/空心减
                </span>
                <span className="text-[13px] text-t-text-muted">
                  {streamStatus === 'connected' ? '实时行情' : '2s 自动刷新'} ·{' '}
                  {/* “手动刷新”可点击主动拉取最新K线，绿色下划线区分于灰色的自动刷新，刷新中显示状态 */}
                  <button
                    type="button"
                    onClick={() => void handleManualRefresh()}
                    className="text-[12px] font-medium underline underline-offset-2 text-[#0ECB81] active:opacity-70"
                  >
                    {manualRefreshing ? '刷新中' : '手动刷新'}
                  </button>
                </span>
              </div>
              {/* 底部长按钮（如信号页“去开仓”）：宽度随弹窗（通屏）铺满 */}
              {bottomAction && (
                <div className="px-3 pb-3">
                  <button
                    type="button"
                    onClick={bottomAction.onClick}
                    className="w-full rounded-lg bg-[#F0B90B] py-2.5 text-sm font-medium text-black transition-colors active:scale-[0.98]"
                  >
                    {bottomAction.label}
                  </button>
                </div>
              )}
            </div>
          </div>,
          document.body
        )}
      {showSettings &&
        createPortal(
          <div
            className="fixed inset-0 z-[130] flex items-end justify-center bg-black/60"
            onClick={() => setShowSettings(false)}
          >
            <div
              className="w-full max-w-md rounded-t-2xl bg-t-surface p-4 max-h-[70vh] overflow-auto"
              style={{ paddingBottom: 'max(24px, env(safe-area-inset-bottom, 0px))' }}
              onClick={e => e.stopPropagation()}
            >
              <div className="flex items-center justify-between mb-3">
                <span className="text-sm font-medium text-t-text">指标设置</span>
                <button
                  type="button"
                  onClick={() => setShowSettings(false)}
                  className="text-xs px-3 py-1 rounded-lg bg-t-surface-hover text-t-text-secondary"
                >
                  完成
                </button>
              </div>
              {INDICATOR_DEFS.map(def => {
                const st = settings[def.key]
                const open = expandedIndicator === def.key
                return (
                  <div key={def.key} className="mb-2 rounded-lg bg-t-page overflow-hidden">
                    <div
                      className="flex items-center justify-between px-3 py-2.5 cursor-pointer"
                      onClick={() =>
                        def.params.length > 0 && setExpandedIndicator(open ? null : def.key)
                      }
                    >
                      <span
                        className="text-sm font-medium"
                        style={def.color ? { color: def.color } : undefined}
                      >
                        {def.label(st)}
                      </span>
                      <div className="flex items-center gap-2">
                        <button
                          type="button"
                          aria-label={`${st.enabled ? '关闭' : '开启'}${def.label(st)}`}
                          onClick={e => {
                            e.stopPropagation()
                            setSettings(prev => ({
                              ...prev,
                              [def.key]: { ...prev[def.key], enabled: !prev[def.key].enabled },
                            }))
                          }}
                          className={`w-5 h-5 rounded flex items-center justify-center border transition-colors ${
                            st.enabled
                              ? 'bg-[#0ECB81] border-[#0ECB81] text-black'
                              : 'border-t-border text-transparent'
                          }`}
                        >
                          <Check size={14} />
                        </button>
                        {def.params.length > 0 && (
                          <ChevronDown
                            size={14}
                            className={`text-t-text-muted transition-transform ${open ? 'rotate-180' : ''}`}
                          />
                        )}
                      </div>
                    </div>
                    {open &&
                      def.params.map(p => (
                        <div
                          key={p.key}
                          className="flex items-center justify-between px-3 py-2 border-t border-t-border"
                        >
                          <span className="text-xs text-t-text-muted">{p.label}</span>
                          <div className="flex items-center gap-2">
                            <button
                              type="button"
                              className="w-6 h-6 rounded bg-t-surface-hover text-t-text-secondary flex items-center justify-center"
                              onClick={() => adjustParam(def.key, p.key, p.min, p.max, -1)}
                              aria-label={`${p.label}减小`}
                            >
                              <Minus size={12} />
                            </button>
                            <span className="text-xs text-t-text w-8 text-center">
                              {st.params[p.key]}
                            </span>
                            <button
                              type="button"
                              className="w-6 h-6 rounded bg-t-surface-hover text-t-text-secondary flex items-center justify-center"
                              onClick={() => adjustParam(def.key, p.key, p.min, p.max, 1)}
                              aria-label={`${p.label}增大`}
                            >
                              <Plus size={12} />
                            </button>
                          </div>
                        </div>
                      ))}
                  </div>
                )
              })}
            </div>
          </div>,
          document.body
        )}
    </>
  )
}
