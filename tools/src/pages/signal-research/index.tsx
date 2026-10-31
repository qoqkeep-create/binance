import { useEffect, useMemo, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import {
  CandlestickSeries,
  createChart,
  createSeriesMarkers,
  LineSeries,
  type IChartApi,
} from 'lightweight-charts'
import {
  ArrowLeft,
  BarChart3,
  BookOpen,
  CandlestickChart,
  ChevronRight,
  Code2,
  Copy,
  Database,
  Download,
  Eye,
  LineChart,
  LoaderCircle,
  Play,
  Plus,
  RefreshCw,
  Trash2,
  X,
} from 'lucide-react'

import { api } from '@/shared/lib/api'
import { CURATED_TRADING_SYMBOLS } from '@/shared/constants'
import { showToast } from '@/shared/store/toastStore'
import { isStandaloneMode } from '@/shared/lib/device'

type Timeframe = '1m' | '3m' | '5m' | '15m' | '1h' | '4h' | '1d'
type Tab = 'entry' | 'analysis' | 'rules' | 'backtest'
type Direction = 'long' | 'short'

interface Candle {
  time: number
  open_time: number
  close_time: number
  open: number
  high: number
  low: number
  close: number
  volume: number
  ema21: number | null
  ema55: number | null
  ema144: number | null
  supertrend: number | null
  trend: number | null
}
interface Sample {
  id: number
  symbol: string
  timeframe: Timeframe
  expected_direction: 'long' | 'short' | 'neutral'
  signal_time: string
  note: string
  trusted: boolean | null
  features: Record<string, unknown>
  fetched_at: string
  candles?: Candle[]
}
interface BacktestRow {
  symbol: string
  timeframe: Timeframe
  signal_time: number
  direction: Direction
  features: Record<string, unknown>
}
interface Strategy {
  id: number
  name: string
  version: number
  status: 'draft' | 'published'
  provider: string
  model: string
  natural_rules: string[]
  definition: Record<string, unknown>
  code: string
  rationale: string
  research_packet: { trusted_count?: number }
}
interface ResearchPreview {
  packet: Record<string, unknown>
  request: Record<string, unknown>
}
interface AiModel {
  id: number
  name: string
  provider: string
  base_url: string
  model: string
  is_active: boolean
  is_default: boolean
}

const TIMEFRAMES: Array<{ value: Timeframe; label: string }> = [
  { value: '1m', label: '1分钟' },
  { value: '3m', label: '3分钟' },
  { value: '5m', label: '5分钟' },
  { value: '15m', label: '15分钟' },
  { value: '1h', label: '1小时' },
  { value: '4h', label: '4小时' },
  { value: '1d', label: '1天' },
]
const NAV: Array<{ key: Tab; label: string; icon: typeof Database }> = [
  { key: 'entry', label: '数据录入', icon: Database },
  { key: 'analysis', label: '数据分析', icon: BarChart3 },
  { key: 'rules', label: '规则与代码', icon: Code2 },
  { key: 'backtest', label: '策略回测', icon: Play },
]

function localDateTime(value: string | number) {
  const date = new Date(typeof value === 'number' ? value : value)
  if (Number.isNaN(date.getTime())) return '-'
  return date.toLocaleString('zh-CN', { hour12: false })
}
function toInputDateTime(date: Date) {
  return new Date(date.getTime() - date.getTimezoneOffset() * 60_000).toISOString().slice(0, 16)
}
function labelOfTimeframe(value: string) {
  return TIMEFRAMES.find(item => item.value === value)?.label || value
}
function formatFeature(value: unknown) {
  return typeof value === 'boolean'
    ? value
      ? '是'
      : '否'
    : typeof value === 'number'
      ? value.toLocaleString('zh-CN', { maximumFractionDigits: 4 })
      : String(value ?? '-')
}
function directionLabel(direction: Sample['expected_direction']) {
  if (direction === 'long')
    return {
      text: '做多',
      tone: 'bg-green-50 text-green-700 dark:bg-green-500/15 dark:text-green-400',
    }
  if (direction === 'short')
    return { text: '做空', tone: 'bg-red-50 text-red-700 dark:bg-red-500/15 dark:text-red-400' }
  return { text: '仅观察', tone: 'bg-t-surface-alt text-t-text-muted' }
}
const FEATURE_LABELS: Record<string, string> = {
  trend: '趋势 · Trend',
  supertrend_flip: '超级趋势翻转 · SuperTrend Flip',
  ema_alignment: '均线排列 · EMA Alignment',
  close_to_ema21_atr: '距 EMA21（ATR）· Close to EMA21 ATR',
  close_to_ema55_atr: '距 EMA55（ATR）· Close to EMA55 ATR',
  close_to_ema144_atr: '距 EMA144（ATR）· Close to EMA144 ATR',
  ema21_slope_5: 'EMA21 斜率（5根）· EMA21 Slope 5',
  ema21_slope_10_atr: 'EMA21 斜率（10根）· EMA21 Slope 10 ATR',
  ema21_slope_20_atr: 'EMA21 斜率（20根）· EMA21 Slope 20 ATR',
  ema21_55_gap_atr: 'EMA21/55 间距 · EMA21/55 Gap ATR',
  ema55_144_gap_atr: 'EMA55/144 间距 · EMA55/144 Gap ATR',
  supertrend_age_bars: '趋势持续K数 · SuperTrend Age',
  atr_percent: 'ATR 波动率 · ATR Percent',
  range_atr: 'K线振幅（ATR）· Range ATR',
  volume_ratio_20: '20根量比 · Volume Ratio 20',
  volume_zscore_20: '成交量 Z 分数 · Volume Z-Score 20',
  return_1_pct: '1根收益率 · Return 1',
  return_5_pct: '5根收益率 · Return 5',
  return_20_pct: '20根收益率 · Return 20',
  realized_volatility_20_pct: '20根实现波动率 · Realized Volatility 20',
  close_position_20: '20根区间位置 · Close Position 20',
  close_position_55: '55根区间位置 · Close Position 55',
  drawdown_from_20_high_pct: '距20根高点回撤 · Drawdown from 20 High',
  upside_from_20_low_pct: '距20根低点涨幅 · Upside from 20 Low',
  bollinger_width_pct: '布林带宽度 · Bollinger Width',
  bollinger_percent_b: '布林带位置 · Bollinger %B',
  body_atr: '实体大小（ATR）· Body ATR',
  upper_wick_atr: '上影线（ATR）· Upper Wick ATR',
  lower_wick_atr: '下影线（ATR）· Lower Wick ATR',
  close_location_value: '收盘位置 · Close Location',
  pullback_to_ema21: '是否回踩 EMA21 · Pullback to EMA21',
  close: '收盘价 · Close',
}

function CandleModal({
  payload,
  onClose,
}: {
  payload: { symbol: string; timeframe: string; signalTime: number; candles: Candle[] } | null
  onClose: () => void
}) {
  const chartHost = useRef<HTMLDivElement>(null)
  const chartRef = useRef<IChartApi | null>(null)
  useEffect(() => {
    if (!payload || !chartHost.current) return
    const chart = createChart(chartHost.current, {
      height: 520,
      layout: { background: { color: '#ffffff' }, textColor: '#6b7280' },
      grid: { vertLines: { color: '#f3f4f6' }, horzLines: { color: '#f3f4f6' } },
      rightPriceScale: { borderColor: '#e5e7eb' },
      timeScale: { borderColor: '#e5e7eb', timeVisible: true },
    })
    chartRef.current = chart
    const series = chart.addSeries(CandlestickSeries, {
      upColor: '#16a34a',
      downColor: '#dc2626',
      borderVisible: false,
      wickUpColor: '#16a34a',
      wickDownColor: '#dc2626',
    })
    series.setData(
      payload.candles.map(row => ({
        time: row.time as never,
        open: row.open,
        high: row.high,
        low: row.low,
        close: row.close,
      }))
    )
    const addLine = (color: string, data: Array<{ time: number; value: number | null }>) => {
      const line = chart.addSeries(LineSeries, {
        color,
        lineWidth: 2,
        priceLineVisible: false,
        lastValueVisible: false,
      })
      line.setData(
        data
          .filter(row => row.value !== null)
          .map(row => ({ time: row.time as never, value: row.value as number }))
      )
    }
    addLine(
      '#2563eb',
      payload.candles.map(row => ({ time: row.time, value: row.ema21 }))
    )
    addLine(
      '#f59e0b',
      payload.candles.map(row => ({ time: row.time, value: row.ema55 }))
    )
    addLine(
      '#7c3aed',
      payload.candles.map(row => ({ time: row.time, value: row.ema144 }))
    )
    addLine(
      '#111827',
      payload.candles.map(row => ({ time: row.time, value: row.supertrend }))
    )
    const signal = payload.candles.find(row => row.close_time >= payload.signalTime)
    if (signal)
      createSeriesMarkers(series, [
        {
          time: signal.time as never,
          position: 'belowBar',
          color: '#f0b90b',
          shape: 'arrowUp',
          text: '信号',
        },
      ])
    chart.timeScale().fitContent()
    const resize = () => chart.applyOptions({ width: chartHost.current?.clientWidth || 800 })
    resize()
    window.addEventListener('resize', resize)
    return () => {
      window.removeEventListener('resize', resize)
      chart.remove()
      chartRef.current = null
    }
  }, [payload])
  if (!payload) return null
  return (
    <div
      className="fixed inset-0 z-[70] flex items-center justify-center bg-black/45 p-4"
      onClick={onClose}
    >
      <div
        className="max-h-[92vh] w-full max-w-6xl overflow-auto rounded-2xl border border-t-border bg-white shadow-2xl"
        onClick={event => event.stopPropagation()}
      >
        <div className="sticky top-0 z-10 flex items-center justify-between border-b border-t-border bg-white px-5 py-4">
          <div>
            <div className="font-bold">
              {payload.symbol} · {labelOfTimeframe(payload.timeframe)} · K线复核
            </div>
            <div className="mt-1 text-xs text-t-text-muted">
              信号收盘：{localDateTime(payload.signalTime)}
            </div>
          </div>
          <button className="rounded-lg p-2 hover:bg-t-surface-hover" onClick={onClose}>
            <X size={20} />
          </button>
        </div>
        <div className="p-4">
          <div className="mb-3 flex flex-wrap gap-3 text-xs text-t-text-muted">
            <span className="text-[#2563eb]">● EMA 21</span>
            <span className="text-[#f59e0b]">● EMA 55</span>
            <span className="text-[#7c3aed]">● EMA 144</span>
            <span className="text-[#111827]">● SuperTrend (10, 6)</span>
          </div>
          <div ref={chartHost} className="w-full min-w-[700px]" />
        </div>
      </div>
    </div>
  )
}

export function SignalResearchPage() {
  const standalone = isStandaloneMode()
  const navigate = useNavigate()
  const [tab, setTab] = useState<Tab>('entry')
  const [samples, setSamples] = useState<Sample[]>([])
  const [loading, setLoading] = useState(true)
  const [working, setWorking] = useState<number | null>(null)
  const [batchFetching, setBatchFetching] = useState(false)
  const [symbol, setSymbol] = useState<string>(CURATED_TRADING_SYMBOLS[0] || 'BTCUSDT')
  const [timeframe, setTimeframe] = useState<Timeframe>('1h')
  const [signalTime, setSignalTime] = useState(toInputDateTime(new Date()))
  const [note, setNote] = useState('')
  const [expectedDirection, setExpectedDirection] = useState<'long' | 'short' | 'neutral'>(
    'neutral'
  )
  const [selected, setSelected] = useState<Sample | null>(null)
  const [strategies, setStrategies] = useState<Strategy[]>([])
  const [selectedStrategy, setSelectedStrategy] = useState<Strategy | null>(null)
  const [generatingStrategy, setGeneratingStrategy] = useState(false)
  const [researchPreview, setResearchPreview] = useState<ResearchPreview | null>(null)
  const [aiModels, setAiModels] = useState<AiModel[]>([])
  const [pendingAiModelId, setPendingAiModelId] = useState(0)
  const [showModelPicker, setShowModelPicker] = useState(false)
  const [backtestStart, setBacktestStart] = useState(
    toInputDateTime(new Date(Date.now() - 30 * 86_400_000))
  )
  const [backtestEnd, setBacktestEnd] = useState(toInputDateTime(new Date()))
  const [backtests, setBacktests] = useState<BacktestRow[]>([])
  const [backtesting, setBacktesting] = useState(false)
  const [chart, setChart] = useState<{
    symbol: string
    timeframe: string
    signalTime: number
    candles: Candle[]
  } | null>(null)
  const loadSamples = async () => {
    setLoading(true)
    try {
      setSamples(await api.get<Sample[]>('/signal-research/samples'))
    } catch (error) {
      showToast(error instanceof Error ? error.message : '加载失败')
    } finally {
      setLoading(false)
    }
  }
  useEffect(() => {
    void loadSamples()
  }, [])
  const loadStrategies = async () => {
    try {
      const data = await api.get<Strategy[]>('/signal-research/strategies')
      setStrategies(data)
      setSelectedStrategy(current =>
        current ? data.find(item => item.id === current.id) || null : data[0] || null
      )
    } catch (error) {
      showToast(error instanceof Error ? error.message : '策略加载失败')
    }
  }
  useEffect(() => {
    if (tab === 'rules' || tab === 'backtest') void loadStrategies()
  }, [tab])
  const selectedFeatures = useMemo(
    () =>
      selected?.features
        ? Object.entries(selected.features).filter(([key]) => key !== 'ready')
        : [],
    [selected]
  )
  async function createSample() {
    try {
      const item = await api.post<Sample>('/signal-research/samples', {
        symbol,
        timeframe,
        signal_time: new Date(signalTime).toISOString(),
        expected_direction: expectedDirection,
        note,
        trusted: null,
      })
      setSamples(list => [item, ...list])
      setNote('')
      showToast('样本已保存，请点击“获取数据”')
    } catch (error) {
      showToast(error instanceof Error ? error.message : '保存失败')
    }
  }
  async function fetchSample(id: number, switchToAnalysis = true) {
    setWorking(id)
    try {
      const item = await api.post<Sample>(`/signal-research/samples/${id}/fetch`, {})
      setSamples(list => list.map(row => (row.id === id ? item : row)))
      setSelected(item)
      if (switchToAnalysis) setTab('analysis')
      showToast('K线与指标已生成')
      return true
    } catch (error) {
      showToast(error instanceof Error ? error.message : '获取失败')
      return false
    } finally {
      setWorking(null)
    }
  }
  async function fetchPendingSamples() {
    const pending = samples.filter(item => !item.fetched_at)
    if (!pending.length) return
    setBatchFetching(true)
    let completed = 0
    for (const item of pending) if (await fetchSample(item.id, false)) completed += 1
    setBatchFetching(false)
    showToast(`批量采集完成：${completed}/${pending.length} 项`)
  }
  async function deleteSample(id: number) {
    try {
      await api.delete(`/signal-research/samples/${id}`)
      setSamples(list => list.filter(row => row.id !== id))
      if (selected?.id === id) setSelected(null)
    } catch (error) {
      showToast(error instanceof Error ? error.message : '删除失败')
    }
  }
  async function setTrusted(sample: Sample, trusted: boolean | null) {
    try {
      const item = await api.patch<Sample>(`/signal-research/samples/${sample.id}`, { trusted })
      setSamples(list => list.map(row => (row.id === item.id ? item : row)))
      if (selected?.id === item.id) setSelected(item)
    } catch (error) {
      showToast(error instanceof Error ? error.message : '更新失败')
    }
  }
  async function openChart(
    symbolValue: string,
    timeframeValue: string,
    signalTimeValue: number | string
  ) {
    try {
      const data = await api.get<{ candles: Candle[]; signal_time: number }>(
        `/signal-research/chart?symbol=${symbolValue}&timeframe=${timeframeValue}&signal_time=${encodeURIComponent(new Date(signalTimeValue).toISOString())}`
      )
      setChart({
        symbol: symbolValue,
        timeframe: timeframeValue,
        signalTime: data.signal_time,
        candles: data.candles,
      })
    } catch (error) {
      showToast(error instanceof Error ? error.message : '图表加载失败')
    }
  }
  async function generateStrategy() {
    setGeneratingStrategy(true)
    try {
      const item = await api.post<Strategy>('/signal-research/strategies/generate', {})
      setStrategies(list => [item, ...list])
      setSelectedStrategy(item)
      showToast('AI 策略草案已生成，请审核后发布')
    } catch (error) {
      showToast(error instanceof Error ? error.message : '生成失败')
    } finally {
      setGeneratingStrategy(false)
    }
  }
  async function openResearchPreview() {
    try {
      setResearchPreview(await api.get<ResearchPreview>('/signal-research/strategies/preview'))
    } catch (error) {
      showToast(error instanceof Error ? error.message : '研究包加载失败')
    }
  }
  async function loadAiModels() {
    try {
      const rows = await api.get<AiModel[]>('/signal-research/ai-models')
      const models = rows.length
        ? rows
        : [
            {
              id: 0,
              name: '火山方舟 · Ark Code 最新版',
              provider: 'volcengine_ark',
              base_url: '',
              model: 'ark-code-latest',
              is_active: true,
              is_default: true,
            },
          ]
      setAiModels(models)
      setPendingAiModelId(models.find(item => item.is_active)?.id ?? models[0].id)
    } catch (error) {
      showToast(error instanceof Error ? error.message : '模型加载失败')
    }
  }
  async function activateAiModel(id: number) {
    if (!id) {
      setAiModels(list => list.map(row => ({ ...row, is_active: row.id === 0 })))
      return
    }
    try {
      const item = await api.post<AiModel>(`/signal-research/ai-models/${id}/activate`, {})
      setAiModels(list =>
        list.map(row => (row.id === item.id ? item : { ...row, is_active: false }))
      )
      setShowModelPicker(false)
    } catch (error) {
      showToast(error instanceof Error ? error.message : '选择失败')
    }
  }
  async function confirmAiModel() {
    if (!pendingAiModelId) {
      setAiModels(list => list.map(row => ({ ...row, is_active: row.id === 0 })))
      setShowModelPicker(false)
      return
    }
    await activateAiModel(pendingAiModelId)
  }
  async function copyResearchPreview() {
    if (!researchPreview) return
    try {
      await navigator.clipboard.writeText(JSON.stringify(researchPreview.request, null, 2))
      showToast('完整研究请求已复制')
    } catch {
      showToast('无法复制，请手动选择文本')
    }
  }
  async function publishStrategy() {
    if (!selectedStrategy) return
    try {
      const item = await api.post<Strategy>(
        `/signal-research/strategies/${selectedStrategy.id}/publish`,
        {}
      )
      setStrategies(list => list.map(row => (row.id === item.id ? item : row)))
      setSelectedStrategy(item)
      showToast('策略版本已发布，可以开始回测')
    } catch (error) {
      showToast(error instanceof Error ? error.message : '发布失败')
    }
  }
  async function runBacktest() {
    if (!selectedStrategy || selectedStrategy.status !== 'published') {
      showToast('请先选择一个已发布的策略版本')
      return
    }
    setBacktesting(true)
    try {
      const result = await api.post<{ results: BacktestRow[] }>('/signal-research/backtest', {
        symbol,
        timeframe,
        strategy_id: selectedStrategy.id,
        start_time: new Date(backtestStart).toISOString(),
        end_time: new Date(backtestEnd).toISOString(),
      })
      setBacktests(result.results)
      showToast(`完成，找到 ${result.results.length} 个信号`)
    } catch (error) {
      showToast(error instanceof Error ? error.message : '回测失败')
    } finally {
      setBacktesting(false)
    }
  }
  return (
    <div className="signal-research h-[100dvh] max-h-[100dvh] min-h-0 overflow-hidden bg-t-page text-t-text">
      <div className="flex h-full min-h-0">
        <aside className="hidden h-full w-64 shrink-0 overflow-y-auto border-r border-t-border bg-[#fafafa] p-5 md:flex md:flex-col">
          <button
            onClick={() => navigate('/profile')}
            className="mb-8 flex items-center gap-2 text-sm text-t-text-muted hover:text-t-text"
          >
            <ArrowLeft size={17} /> 返回我的
          </button>
          <div className="mb-8">
            <div className="text-[11px] font-bold tracking-[0.18em] text-[#a3a3a3]">TRADETOOLS</div>
            <div className="mt-2 text-xl font-bold tracking-tight">信号研究</div>
            <p className="mt-2 text-xs leading-5 text-t-text-muted">把盘感沉淀为可验证的策略。</p>
          </div>
          <nav className="space-y-1">
            {NAV.map(item => {
              const Icon = item.icon
              return (
                <button
                  key={item.key}
                  onClick={() => setTab(item.key)}
                  className={`flex w-full items-center gap-3 rounded-xl px-3 py-3 text-sm font-medium transition ${tab === item.key ? 'bg-white text-t-text shadow-sm ring-1 ring-black/5' : 'text-t-text-muted hover:bg-white/70 hover:text-t-text'}`}
                >
                  <Icon size={18} className={tab === item.key ? 'text-[#d4a514]' : ''} />
                  {item.label}
                  <ChevronRight size={15} className="ml-auto opacity-40" />
                </button>
              )
            })}
          </nav>
          <div className="mt-auto rounded-xl border border-[#f1e4bd] bg-[#fffaf0] p-3 text-xs leading-5 text-[#7a5d10]">
            数据源：Binance USDT 永续
            <br />
            所有信号按 K 线收盘确认。
          </div>
        </aside>
        <div className="flex h-full min-h-0 min-w-0 flex-1 flex-col">
          {/* 手机端顶部标题栏：参照「我的策略」页（桌面端侧边栏已有标题，不重复展示） */}
          <div
            className="md:hidden shrink-0 px-4 pb-4 border-b transition-colors bg-t-surface border-t-border"
            style={{ paddingTop: standalone ? 'max(44px, env(safe-area-inset-top, 0px))' : 'env(safe-area-inset-top, 0px)' }}
          >
            <div className="h-11 flex items-center justify-center max-w-md mx-auto relative">
              <button
                onClick={() => navigate('/profile')}
                className="absolute left-0 p-2 rounded-lg transition-colors hover:bg-t-surface-hover"
                aria-label="返回我的"
              >
                <ArrowLeft size={20} />
              </button>
              <h1 className="text-lg font-bold">信号研究</h1>
            </div>
          </div>
          <main className="min-h-0 flex-1 overflow-y-auto overscroll-contain">
          <header className="sticky top-0 z-20 flex items-center justify-between border-b border-t-border bg-t-page px-5 py-4 md:px-8">
            <div>
              <div className="text-lg font-bold">{NAV.find(item => item.key === tab)?.label}</div>
              <div className="mt-0.5 text-xs text-t-text-muted">
                EMA 21 / 55 / 144 · SuperTrend (ATR 10, ×6)
              </div>
            </div>
            <button
              onClick={() => void loadSamples()}
              className="rounded-lg border border-t-border p-2 text-t-text-muted hover:bg-t-surface-hover"
            >
              <RefreshCw size={17} />
            </button>
          </header>
          <div className="mx-auto max-w-6xl p-5 md:p-8">
            {tab === 'entry' && (
              <section className="space-y-6">
                <div className="rounded-2xl border border-t-border bg-white p-5 shadow-sm">
                  <div className="mb-5 flex items-center gap-3">
                    <span className="flex h-8 w-8 items-center justify-center rounded-lg bg-[#fff7df] text-[#b78600]">
                      <Plus size={18} />
                    </span>
                    <div>
                      <h2 className="font-bold">录入一个已收盘信号样本</h2>
                      <p className="text-xs text-t-text-muted">
                        保存后，再由你主动确认是否向币安获取历史数据。
                      </p>
                    </div>
                  </div>
                  <div className="grid gap-4 md:grid-cols-4">
                    <label className="text-sm font-medium">
                      合约币种
                      <select
                        value={symbol}
                        onChange={event => setSymbol(event.target.value)}
                        className="mt-2 w-full rounded-xl border border-t-border bg-white p-3"
                      >
                        {CURATED_TRADING_SYMBOLS.map(item => (
                          <option key={item}>{item}</option>
                        ))}
                      </select>
                    </label>
                    <label className="text-sm font-medium">
                      K线周期
                      <select
                        value={timeframe}
                        onChange={event => setTimeframe(event.target.value as Timeframe)}
                        className="mt-2 w-full rounded-xl border border-t-border bg-white p-3"
                      >
                        {TIMEFRAMES.map(item => (
                          <option key={item.value} value={item.value}>
                            {item.label}
                          </option>
                        ))}
                      </select>
                    </label>
                    <label className="text-sm font-medium">
                      预期方向
                      <select
                        value={expectedDirection}
                        onChange={event =>
                          setExpectedDirection(event.target.value as 'long' | 'short' | 'neutral')
                        }
                        className="mt-2 w-full rounded-xl border border-t-border bg-white p-3"
                      >
                        <option value="long">做多</option>
                        <option value="short">做空</option>
                        <option value="neutral">仅观察</option>
                      </select>
                    </label>
                    <label className="text-sm font-medium md:col-span-2">
                      K线收盘时间
                      <input
                        type="datetime-local"
                        value={signalTime}
                        onChange={event => setSignalTime(event.target.value)}
                        className="mt-2 w-full rounded-xl border border-t-border bg-white p-3"
                      />
                    </label>
                  </div>
                  <label className="mt-4 block text-sm font-medium">
                    观察备注（可选）
                    <textarea
                      value={note}
                      onChange={event => setNote(event.target.value)}
                      placeholder="例如：此处由空转多，回踩 EMA21 后收回..."
                      className="mt-2 min-h-24 w-full rounded-xl border border-t-border p-3"
                    />
                  </label>
                  <div className="mt-5 flex justify-end">
                    <button
                      onClick={() => void createSample()}
                      className="rounded-xl bg-[#f0b90b] px-5 py-3 text-sm font-bold text-black hover:bg-[#d9a70a]"
                    >
                      保存样本
                    </button>
                  </div>
                </div>
                <div className="overflow-hidden rounded-2xl border border-t-border">
                  <div className="flex items-center justify-between gap-3 border-b border-t-border px-5 py-4">
                    <div className="font-bold">
                      已录入样本{' '}
                      <span className="ml-1 text-sm font-normal text-t-text-muted">
                        {samples.length}
                      </span>
                    </div>
                    {samples.some(item => !item.fetched_at) && (
                      <button
                        onClick={() => void fetchPendingSamples()}
                        disabled={batchFetching || working !== null}
                        className="rounded-lg border border-t-border px-3 py-2 text-xs font-semibold hover:bg-t-surface-hover disabled:opacity-50"
                      >
                        {batchFetching
                          ? '正在批量采集...'
                          : `一键采集 ${samples.filter(item => !item.fetched_at).length} 项待采集数据`}
                      </button>
                    )}
                  </div>
                  {loading ? (
                    <div className="p-10 text-center text-t-text-muted">正在加载...</div>
                  ) : samples.length === 0 ? (
                    <div className="p-10 text-center text-sm text-t-text-muted">
                      还没有样本。先录入你认为可信的信号。
                    </div>
                  ) : (
                    <div className="divide-y divide-t-border">
                      {samples.map(item => (
                        <div key={item.id} className="flex flex-wrap items-center gap-3 p-4">
                          {(() => {
                            const direction = directionLabel(item.expected_direction)
                            return (
                              <span
                                className={`rounded-full px-2.5 py-1 text-xs font-bold ${direction.tone}`}
                              >
                                {direction.text}
                              </span>
                            )
                          })()}
                          <div className="min-w-[190px]">
                            <div className="font-semibold">
                              {item.symbol}{' '}
                              <span className="ml-1 text-xs font-normal text-t-text-muted">
                                {labelOfTimeframe(item.timeframe)}
                              </span>
                            </div>
                            <div className="mt-1 text-xs text-t-text-muted">
                              {localDateTime(item.signal_time)}
                            </div>
                          </div>
                          <div className="min-w-[120px] text-xs text-t-text-muted">
                            {item.fetched_at ? '已获取数据' : '待获取数据'}
                          </div>
                          <div className="ml-auto flex items-center gap-2">
                            <button
                              onClick={() => void fetchSample(item.id)}
                              disabled={working === item.id || Boolean(item.fetched_at)}
                              className="rounded-lg border border-t-border px-3 py-2 text-xs font-semibold hover:bg-t-surface-hover disabled:opacity-50"
                            >
                              {item.fetched_at ? (
                                '已获取数据'
                              ) : working === item.id ? (
                                '获取中...'
                              ) : (
                                <>
                                  <Download className="mr-1 inline" size={14} />
                                  获取数据
                                </>
                              )}
                            </button>
                            <button
                              onClick={() => void deleteSample(item.id)}
                              className="rounded-lg p-2 text-t-text-muted hover:bg-red-50 hover:text-red-600"
                            >
                              <Trash2 size={16} />
                            </button>
                          </div>
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              </section>
            )}
            {tab === 'analysis' && (
              <section className="grid min-h-[calc(100dvh-9rem)] gap-6 lg:grid-cols-[300px_1fr]">
                <div className="flex h-[calc(100dvh-9rem)] flex-col overflow-hidden rounded-2xl border border-t-border">
                  <div className="border-b border-t-border px-4 py-3 font-bold">数据样本</div>
                  <div className="hide-scrollbar min-h-0 flex-1 overflow-y-auto">
                    {samples
                      .filter(item => item.fetched_at)
                      .map(item => (
                        <div
                          key={item.id}
                          className={`flex w-full items-center gap-2 border-b border-t-border p-4 ${selected?.id === item.id ? 'bg-[#fffaf0]' : 'hover:bg-t-surface-hover'}`}
                        >
                          <button
                            onClick={() => setSelected(item)}
                            className="min-w-0 flex-1 text-left"
                          >
                            <div className="font-semibold">
                              {item.symbol} · {labelOfTimeframe(item.timeframe)}
                              {(() => {
                                const direction = directionLabel(item.expected_direction)
                                return (
                                  <span
                                    className={`ml-2 rounded-full px-2 py-0.5 text-[11px] font-bold ${direction.tone}`}
                                  >
                                    {direction.text}
                                  </span>
                                )
                              })()}
                            </div>
                            <div className="mt-1 text-xs text-t-text-muted">
                              {localDateTime(item.signal_time)}
                            </div>
                          </button>
                          <div className="flex shrink-0 gap-1">
                            <button
                              onClick={() => void setTrusted(item, true)}
                              title="可信：纳入后续 AI 研究"
                              className={`rounded border p-1 text-xs ${item.trusted === true ? 'border-green-600 bg-green-600 text-white' : 'border-green-500/40 text-green-600 hover:bg-green-50 dark:text-green-400 dark:hover:bg-green-500/10'}`}
                            >
                              ✓
                            </button>
                            <button
                              onClick={() => void setTrusted(item, false)}
                              title="不可信：作为反例保留"
                              className={`rounded border p-1 text-xs ${item.trusted === false ? 'border-red-600 bg-red-600 text-white' : 'border-red-500/40 text-red-600 hover:bg-red-50 dark:text-red-400 dark:hover:bg-red-500/10'}`}
                            >
                              ×
                            </button>
                            <button
                              onClick={() => void setTrusted(item, null)}
                              title="未标注"
                              className={`rounded border p-1 text-xs ${item.trusted === null ? 'border-t-border bg-t-surface-alt text-t-text' : 'border-t-border text-t-text-muted hover:bg-t-surface-hover'}`}
                            >
                              —
                            </button>
                          </div>
                          <button
                            onClick={() => void deleteSample(item.id)}
                            className="rounded-lg p-2 text-t-text-muted hover:bg-red-50 hover:text-red-600"
                            title="删除该采集样本"
                          >
                            <Trash2 size={16} />
                          </button>
                        </div>
                      ))}
                    {!samples.some(item => item.fetched_at) && (
                      <div className="p-5 text-sm text-t-text-muted">
                        请先在“数据录入”获取一个样本。
                      </div>
                    )}
                  </div>
                </div>
                <div>
                  {selected ? (
                    <div className="space-y-5">
                      <div className="rounded-2xl border border-t-border p-5">
                        <div className="flex flex-wrap items-start justify-between gap-4">
                          <div>
                            <h2 className="text-xl font-bold">
                              {selected.symbol} · {labelOfTimeframe(selected.timeframe)}
                            </h2>
                            <p className="mt-1 text-sm text-t-text-muted">
                              收盘时间：{localDateTime(selected.signal_time)}
                            </p>
                          </div>
                          <button
                            onClick={() =>
                              void openChart(
                                selected.symbol,
                                selected.timeframe,
                                selected.signal_time
                              )
                            }
                            className="inline-flex items-center gap-2 rounded-xl border border-t-border px-4 py-2 text-sm font-semibold hover:bg-t-surface-hover"
                          >
                            <CandlestickChart size={17} />
                            查看蜡烛图
                          </button>
                        </div>
                      </div>
                      <div className="rounded-2xl border border-t-border">
                        <div className="border-b border-t-border px-5 py-4">
                          <div className="font-bold">量化特征快照</div>
                          <div className="mt-1 text-xs text-t-text-muted">
                            以下值均只使用该根 K 线收盘前的数据计算。
                          </div>
                        </div>
                        <div className="grid divide-x divide-y divide-t-border sm:grid-cols-2 xl:grid-cols-3">
                          {selectedFeatures.map(([key, value]) => (
                            <div key={key} className="p-4">
                              <div className="text-xs text-t-text-muted">
                                {FEATURE_LABELS[key] || key.replace(/_/g, ' ')}
                              </div>
                              <div className="mt-1 font-semibold">{formatFeature(value)}</div>
                            </div>
                          ))}
                        </div>
                      </div>
                    </div>
                  ) : (
                    <div className="rounded-2xl border border-dashed border-t-border p-12 text-center text-t-text-muted">
                      选择一个已获取数据的样本。
                    </div>
                  )}
                </div>
              </section>
            )}
            {tab === 'rules' && (
              <section className="grid max-w-5xl gap-5 lg:grid-cols-[280px_1fr]">
                <div className="rounded-2xl border border-t-border p-4">
                  <button
                    onClick={() => {
                      setShowModelPicker(true)
                      void loadAiModels()
                    }}
                    className="mb-3 flex w-full items-center justify-center gap-2 rounded-xl border border-t-border px-4 py-2.5 text-sm font-semibold hover:bg-t-surface-hover"
                  >
                    选择大模型
                  </button>
                  <button
                    onClick={() => void openResearchPreview()}
                    className="mb-3 flex w-full items-center justify-center gap-2 rounded-xl border border-t-border px-4 py-2.5 text-sm font-semibold hover:bg-t-surface-hover"
                  >
                    <Eye size={16} />
                    预览本次研究包
                  </button>
                  <button
                    onClick={() => void generateStrategy()}
                    disabled={generatingStrategy}
                    className="w-full rounded-xl bg-[#f0b90b] px-4 py-3 text-sm font-bold text-black disabled:opacity-60"
                  >
                    {generatingStrategy ? 'AI 正在生成...' : 'AI 生成策略草案'}
                  </button>
                  <p className="mt-3 text-xs leading-5 text-t-text-muted">
                    仅在你点击后发送已标注样本的压缩特征、备注与正反例；不会后台自动调用。
                  </p>
                  <div className="mt-4 space-y-2">
                    {strategies.map(item => (
                      <button
                        key={item.id}
                        onClick={() => setSelectedStrategy(item)}
                        className={`w-full rounded-lg border p-3 text-left text-sm ${selectedStrategy?.id === item.id ? 'border-[#e4bf56] bg-[#fffaf0]' : 'border-t-border'}`}
                      >
                        <div className="font-semibold">
                          {item.name} v{item.version}
                        </div>
                        <div className="mt-1 text-xs text-t-text-muted">
                          {item.status === 'published' ? '已发布' : '待审核草案'}
                        </div>
                      </button>
                    ))}
                  </div>
                </div>
                {selectedStrategy ? (
                  <div className="space-y-5">
                    <div className="rounded-2xl border border-t-border p-6">
                      <div className="flex items-start justify-between gap-4">
                        <div>
                          <div className="flex items-center gap-2">
                            <BookOpen className="text-[#b78600]" />
                            <h2 className="text-xl font-bold">
                              {selectedStrategy.name} v{selectedStrategy.version}
                            </h2>
                          </div>
                          <p className="mt-2 text-sm text-t-text-muted">
                            依据 {selectedStrategy.research_packet.trusted_count || 0}{' '}
                            个可信样本生成 ·{' '}
                            {selectedStrategy.status === 'published'
                              ? '已发布且不可修改'
                              : '请审核后发布'}
                          </p>
                        </div>
                        {selectedStrategy.status === 'draft' && (
                          <button
                            onClick={() => void publishStrategy()}
                            className="rounded-xl bg-[#f0b90b] px-4 py-2 text-sm font-bold text-black"
                          >
                            确认发布
                          </button>
                        )}
                      </div>
                      <ol className="mt-6 space-y-3">
                        {selectedStrategy.natural_rules.map((rule, index) => (
                          <li key={rule} className="flex gap-3 text-sm leading-6">
                            <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-[#fff7df] text-xs font-bold text-[#9a7000]">
                              {index + 1}
                            </span>
                            {rule}
                          </li>
                        ))}
                      </ol>
                      {selectedStrategy.rationale && (
                        <div className="mt-5 rounded-xl bg-[#fffaf0] p-4 text-sm leading-6 text-[#7a5d10]">
                          {selectedStrategy.rationale}
                        </div>
                      )}
                    </div>
                    <div className="overflow-hidden rounded-2xl border border-t-border">
                      <div className="flex items-center gap-2 border-b border-t-border px-5 py-4 font-bold">
                        <Code2 size={18} />
                        受限策略代码
                      </div>
                      <pre className="overflow-auto bg-[#181818] p-5 text-sm leading-7 text-[#d6e4cf]">
                        <code>{selectedStrategy.code}</code>
                      </pre>
                    </div>
                  </div>
                ) : (
                  <div className="rounded-2xl border border-dashed border-t-border p-12 text-center text-t-text-muted">
                    先标注可信样本，再点击“AI 生成策略草案”。
                  </div>
                )}
              </section>
            )}
            {tab === 'backtest' && (
              <section className="space-y-6">
                <div className="rounded-2xl border border-t-border p-5">
                  <div className="mb-5 flex items-center gap-3">
                    <span className="flex h-8 w-8 items-center justify-center rounded-lg bg-[#fff7df] text-[#b78600]">
                      <LineChart size={18} />
                    </span>
                    <div>
                      <h2 className="font-bold">运行策略回测</h2>
                      <p className="text-xs text-t-text-muted">
                        扫描已收盘 K 线；结果可逐条打开蜡烛图核验。
                      </p>
                    </div>
                  </div>
                  <div className="grid gap-4 md:grid-cols-5">
                    <label className="text-sm font-medium">
                      策略版本
                      <select
                        value={selectedStrategy?.id || ''}
                        onChange={event =>
                          setSelectedStrategy(
                            strategies.find(item => item.id === Number(event.target.value)) || null
                          )
                        }
                        className="mt-2 w-full rounded-xl border border-t-border p-3"
                      >
                        <option value="">请选择</option>
                        {strategies
                          .filter(item => item.status === 'published')
                          .map(item => (
                            <option key={item.id} value={item.id}>
                              {item.name} v{item.version}
                            </option>
                          ))}
                      </select>
                    </label>
                    <label className="text-sm font-medium">
                      币种
                      <select
                        value={symbol}
                        onChange={event => setSymbol(event.target.value)}
                        className="mt-2 w-full rounded-xl border border-t-border p-3"
                      >
                        {CURATED_TRADING_SYMBOLS.map(item => (
                          <option key={item}>{item}</option>
                        ))}
                      </select>
                    </label>
                    <label className="text-sm font-medium">
                      周期
                      <select
                        value={timeframe}
                        onChange={event => setTimeframe(event.target.value as Timeframe)}
                        className="mt-2 w-full rounded-xl border border-t-border p-3"
                      >
                        {TIMEFRAMES.map(item => (
                          <option key={item.value} value={item.value}>
                            {item.label}
                          </option>
                        ))}
                      </select>
                    </label>
                    <label className="text-sm font-medium">
                      开始时间
                      <input
                        type="datetime-local"
                        value={backtestStart}
                        onChange={event => setBacktestStart(event.target.value)}
                        className="mt-2 w-full rounded-xl border border-t-border p-3"
                      />
                    </label>
                    <label className="text-sm font-medium">
                      结束时间
                      <input
                        type="datetime-local"
                        value={backtestEnd}
                        onChange={event => setBacktestEnd(event.target.value)}
                        className="mt-2 w-full rounded-xl border border-t-border p-3"
                      />
                    </label>
                  </div>
                  <div className="mt-5 flex justify-end">
                    <button
                      onClick={() => void runBacktest()}
                      disabled={backtesting}
                      className="inline-flex items-center gap-2 rounded-xl bg-[#f0b90b] px-5 py-3 text-sm font-bold text-black disabled:opacity-60"
                    >
                      {backtesting ? (
                        <LoaderCircle className="animate-spin" size={17} />
                      ) : (
                        <Play size={17} />
                      )}
                      {backtesting ? '回测中...' : '开始回测'}
                    </button>
                  </div>
                </div>
                <div className="overflow-hidden rounded-2xl border border-t-border">
                  <div className="flex items-center justify-between border-b border-t-border px-5 py-4">
                    <div className="font-bold">命中信号</div>
                    <div className="text-sm text-t-text-muted">{backtests.length} 条</div>
                  </div>
                  {backtests.length === 0 ? (
                    <div className="p-10 text-center text-sm text-t-text-muted">
                      选择区间并运行回测后，结果会出现在这里。
                    </div>
                  ) : (
                    <div className="divide-y divide-t-border">
                      {backtests.map((item, index) => (
                        <div
                          key={`${item.signal_time}-${index}`}
                          className="flex flex-wrap items-center gap-3 p-4"
                        >
                          <div className="min-w-[270px]">
                            <span className="font-semibold">{localDateTime(item.signal_time)}</span>
                            <span className="mx-2 text-t-text-muted">·</span>
                            <span>{item.symbol}</span>
                            <span className="mx-2 text-t-text-muted">·</span>
                            <span>{labelOfTimeframe(item.timeframe)}</span>
                          </div>
                          <span
                            className={`rounded-full px-2.5 py-1 text-xs font-bold ${item.direction === 'long' ? 'bg-green-50 text-green-700' : 'bg-red-50 text-red-700'}`}
                          >
                            {item.direction === 'long' ? '做多' : '做空'}
                          </span>
                          <span className="text-xs text-t-text-muted">
                            {formatFeature(item.features.supertrend_flip)} · EMA21 距离{' '}
                            {formatFeature(item.features.close_to_ema21_atr)} ATR
                          </span>
                          <button
                            onClick={() =>
                              void openChart(item.symbol, item.timeframe, item.signal_time)
                            }
                            className="ml-auto inline-flex items-center gap-2 rounded-lg border border-t-border px-3 py-2 text-xs font-semibold hover:bg-t-surface-hover"
                          >
                            <CandlestickChart size={15} />
                            K线图
                          </button>
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              </section>
            )}
          </div>
        </main>
        </div>
      </div>
      <CandleModal payload={chart} onClose={() => setChart(null)} />
      {researchPreview && (
        <div
          className="fixed inset-0 z-[75] flex items-center justify-center bg-black/45 p-4"
          onClick={() => setResearchPreview(null)}
        >
          <div
            className="max-h-[92vh] w-full max-w-5xl overflow-auto rounded-2xl bg-white shadow-2xl"
            onClick={event => event.stopPropagation()}
          >
            <div className="sticky top-0 flex items-center justify-between border-b border-t-border bg-white px-5 py-4">
              <div>
                <div className="font-bold">AI 研究包预览</div>
                <div className="mt-1 text-xs text-t-text-muted">
                  以下内容将原样发送；不含 API Key、账户或未来数据。
                </div>
              </div>
              <button
                className="rounded-lg p-2 hover:bg-t-surface-hover"
                onClick={() => setResearchPreview(null)}
              >
                <X size={19} />
              </button>
            </div>
            <div className="space-y-4 p-5">
              <div className="flex justify-end">
                <button
                  onClick={() => void copyResearchPreview()}
                  className="inline-flex items-center gap-2 rounded-lg border border-t-border px-3 py-2 text-sm font-semibold"
                >
                  <Copy size={15} />
                  复制完整请求
                </button>
              </div>
              <div>
                <div className="mb-2 text-sm font-bold">完整请求体</div>
                <pre className="max-h-[58vh] overflow-auto rounded-xl bg-[#181818] p-4 text-xs leading-6 text-[#d6e4cf]">
                  <code>{JSON.stringify(researchPreview.request, null, 2)}</code>
                </pre>
              </div>
              <button
                onClick={() => {
                  setResearchPreview(null)
                  void generateStrategy()
                }}
                disabled={generatingStrategy}
                className="w-full rounded-xl bg-[#f0b90b] px-4 py-3 text-sm font-bold text-black"
              >
                确认发送给 AI
              </button>
            </div>
          </div>
        </div>
      )}
      {showModelPicker && (
        <div
          className="fixed inset-0 z-[76] flex items-center justify-center bg-black/45 p-4"
          onClick={() => setShowModelPicker(false)}
        >
          <div
            className="w-full max-w-2xl rounded-2xl bg-white p-5 shadow-2xl"
            onClick={event => event.stopPropagation()}
          >
            <div className="flex items-center justify-between">
              <h2 className="text-lg font-bold">选择大模型</h2>
              <button onClick={() => setShowModelPicker(false)}>
                <X size={20} />
              </button>
            </div>
            <p className="mt-2 text-xs text-t-text-muted">选择用于生成本账户策略草案的大模型。</p>
            <div className="mt-5 space-y-2">
              {aiModels.map(item => (
                <button
                  key={item.id}
                  onClick={() => setPendingAiModelId(item.id)}
                  className={`w-full rounded-xl border p-3 text-left ${pendingAiModelId === item.id ? 'border-[#e4bf56] bg-[#fffaf0]' : 'border-t-border'}`}
                >
                  <div className="flex justify-between font-semibold">
                    <span>{item.name}</span>
                    <span className="text-xs text-t-text-muted">
                      {pendingAiModelId === item.id ? '已选择' : item.model}
                    </span>
                  </div>
                  <div className="mt-1 text-xs text-t-text-muted">
                    {item.provider} · {item.model}
                  </div>
                </button>
              ))}
            </div>
            <div className="mt-5 flex justify-end">
              <button
                onClick={() => void confirmAiModel()}
                className="rounded-xl bg-[#f0b90b] px-5 py-2.5 text-sm font-bold text-black"
              >
                确定使用
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
