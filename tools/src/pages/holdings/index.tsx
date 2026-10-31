import { useState, useEffect, useLayoutEffect, useCallback, useRef, useMemo, lazy, Suspense } from 'react'
import { useLocation } from 'react-router-dom'
import { ConfirmModal, TakeProfitStopLossModal } from '@/components/modals'
import { ApiBindModal } from '@/components/modals/ApiBindModal'
import { StrategyDetailModal } from './components/StrategyDetailModal'
import { IndicatorDetailModal } from './components/IndicatorDetailModal'
import type { Strategy } from '@/shared/types'
import { useAuthStore, useTradingStore } from '@/shared/store'
import { api, ApiError, isApiBindRequiredError } from '@/shared/lib/api'
import { formatSmartAmount } from '@/shared/lib/utils'
import { clearKlineCacheSymbol } from '@/shared/lib/klineCache'
import { ensureManualEntryCapitalReady } from '@/shared/lib/manualEntryCapital'
import {
  getAccountSessionRevision,
  isCurrentAccountRequestScope,
  scopedAccountCacheKey,
} from '@/shared/lib/accountBalanceState'
import { showToast } from '@/shared/store'
import { isStandaloneMode, requestAppLayoutSync } from '@/shared/lib/device'
import type { StrategyLevel } from '@/shared/types'
import historyLogIcon from '@/assets/history-log.svg'

const KlineChartCard = lazy(() =>
  import('../trading/KlineChartCard').then(mod => ({ default: mod.KlineChartCard })),
)

type TabType = 'positions' | 'limit-orders' | 'history'

const POSITIONS_CACHE_KEY_PREFIX = 'tradetools:holdings:positions:v3'
const LIMIT_ORDERS_CACHE_KEY_PREFIX = 'tradetools:holdings:limit-orders:v2'
const HISTORY_CACHE_KEY_PREFIX = 'tradetools:holdings:history:v2'
const LEGACY_HOLDINGS_CACHE_KEYS = [
  'tradetools:holdings:positions:v2',
  'tradetools:holdings:limit-orders:v1',
]
const LEGACY_HISTORY_CACHE_KEY_PREFIX = 'tradetools:holdings:history:v1:'
const SILENT_REFRESH_TIMEOUT = 8000
const HISTORY_PAGE_SIZE = 20

// 缓存改用 localStorage：sessionStorage 在 iOS PWA 杀进程后会清空，
// 导致每次启动都要等网络；localStorage 持久化 + 惰性初始化可让首帧直接展示缓存，
// 避免启动时闪现“加载中”（后台静默刷新仍会用最新数据覆盖）
function readLocalCache<T>(key: string | null): T | null {
  if (!key) return null
  try {
    const raw = window.localStorage.getItem(key)
    if (!raw) return null
    return JSON.parse(raw) as T
  } catch {
    return null
  }
}

interface InitialHistoryCache {
  items: HistoryPositionData[]
  pagination: HistoryPaginationData
}

function historyCacheKey(userId: string, filter: string): string | null {
  return scopedAccountCacheKey(`${HISTORY_CACHE_KEY_PREFIX}:${filter}`, userId)
}

function readInitialHistoryCache(userId: string): InitialHistoryCache | null {
  const cached = readLocalCache<HistoryResponseData | HistoryPositionData[]>(
    historyCacheKey(userId, 'all'),
  )
  if (!cached) return null
  if (Array.isArray(cached)) {
    if (!cached.length) return null
    return {
      items: cached,
      pagination: { page: 1, page_size: cached.length, total: cached.length, has_next: false, has_previous: false },
    }
  }
  if (cached.items?.length) return { items: cached.items, pagination: cached.pagination }
  return null
}

interface RefreshRequestOptions {
  suppressConnectionError?: boolean
  disableRetry?: boolean
  timeout?: number
}

// 限价委托单类型
interface LimitOrderData {
  id: number
  symbol: string
  side: number
  limit_price: string
  stop_loss_price: string
  stop_loss_amount: string
  size: string
  filled_size: string
  position_amount: string
  filled_amount: string
  leverage: number
  status: number
  status_text: string
  can_chase: boolean
  created_at: string
}

interface PositionData {
  id: number
  positionOrigin: 'web' | 'exchange_external'
  pair: string
  balance: number
  profit: number
  profitPercent: number
  openPrice: number
  initialStopPrice: number
  currentPrice: number
  exchangeSize: number
  hasManualAddition: boolean
  stopLoss: number
  stopProfit: number
  totalFee: number
  leverage: string
  stopLossAmount: number
  stopProtectionStatus: string
  stopProtectionError: string
  latestStrategyError: string
  limitStopSet: boolean
  marketStopSet: boolean
  limitStopPrice: number
  marketStopPrice: number
  entryFee: number | null
  entryFeeAsset: string
  entryFeeStatus: string
  entryFeeError: string
  canBindStrategy: boolean
  isProfit: boolean
  positionType: 'long' | 'short'
  strategyType: 'auto' | 'manual-cancelled' | 'none'
  strategyId: string
  strategy: Strategy | null
  manualTakeProfitSet: boolean
  manualTakeProfitPrice: number
  manualTakeProfitOrderType: string
  manualTakeProfitPnl: number
  createdAt: string
}

// 历史仓位类型
interface HistoryPositionData {
  id: number | null
  position_origin?: 'web' | 'exchange_external'
  symbol: string
  side: number
  size?: string
  pnl: string | null
  realized_pnl?: string | null
  pnl_ratio: string | null
  stop_loss_amount: string
  open_price: string
  close_price: string | null
  position_amount: string
  leverage: number
  fee?: string | null
  funding_fee?: string | null
  floating_pnl?: string | null
  is_partial_history?: boolean
  settlement_status?: 'pending' | 'confirmed' | 'estimated' | 'failed'
  settlement_note?: string
  has_strategy_logs?: boolean
  opened_at?: string
  created_at: string
  closed_at: string
}

interface HistoryPaginationData {
  page: number
  page_size: number
  total: number
  has_next: boolean
  has_previous: boolean
}

interface HistoryResponseData {
  items: HistoryPositionData[]
  pagination: HistoryPaginationData
}

interface PositionCloseResult {
  pnl?: string | null
  pnl_ratio?: string | null
}

function confirmedClosePnl(result: PositionCloseResult | undefined): number | null {
  if (result?.pnl === null || result?.pnl === undefined || result.pnl.trim() === '') return null
  const pnl = Number(result.pnl)
  return Number.isFinite(pnl) ? pnl : null
}

interface StrategyLogData {
  id: number
  behavior_desc: string
  trigger_r: string | null
  result: string
  error: string
  created_at: string
}

interface StrategyLogResponse {
  strategy_name: string
  strategy_config: StrategyLevel[]
  logs: StrategyLogData[]
}

function formatLogAmount(value: number) {
  const abs = Math.abs(value)
  if (abs === 0) return '0'
  if (abs >= 100) return value.toFixed(1)
  if (abs >= 1) return value.toFixed(2)

  let decimals = 0
  let nonZeroCount = 0
  while (decimals < 16 && nonZeroCount < 4) {
    decimals += 1
    const scaled = Math.floor(abs * Math.pow(10, decimals))
    if (scaled % 10 !== 0) nonZeroCount += 1
  }
  return value.toFixed(decimals).replace(/0+$/, '').replace(/\.$/, '')
}

function formatAmountsInLogText(text: string) {
  return text.replace(/-?\d+(?:\.\d+)?/g, (...args) => {
    const raw = String(args[0] ?? '')
    const offset = Number(args[args.length - 2] ?? 0)
    const full = String(args[args.length - 1] ?? '')
    const prev = full[offset - 1] || ''
    const next = full[offset + raw.length] || ''
    // Skip level markers and ratio/percent/leverage numbers.
    if (prev === 'L' || next === 'R' || next === 'r' || next === '%' || next === 'x' || next === 'X') {
      return raw
    }
    const num = Number(raw)
    if (!Number.isFinite(num)) return raw
    return formatLogAmount(num)
  })
}

function formatDateTime(value?: string | null) {
  if (!value) return '--'
  const d = new Date(value)
  if (Number.isNaN(d.getTime())) return '--'
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')} ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}:${String(d.getSeconds()).padStart(2, '0')}`
}

function formatPositionPnl(value: number) {
  if (!Number.isFinite(value)) return '0U'
  if (Math.abs(value) < 0.00000001) return '0U'
  return `${value > 0 ? '+' : ''}${formatSmartAmount(value)}U`
}

function formatSignedUsd(value: number) {
  if (!Number.isFinite(value)) return '0U'
  if (Math.abs(value) < 0.00000001) return '0U'
  return `${value > 0 ? '+' : ''}${formatSmartAmount(value)}U`
}

function formatFeeAmount(value: number, asset?: string) {
  const normalizedAsset = String(asset || '').trim().toUpperCase()
  if (!normalizedAsset || normalizedAsset === 'USDT') {
    return formatSignedUsd(value)
  }
  if (!Number.isFinite(value)) return `0${normalizedAsset}`
  if (Math.abs(value) < 0.00000001) return `0${normalizedAsset}`
  return `${value > 0 ? '+' : ''}${formatSmartAmount(value)}${normalizedAsset}`
}

function estimatedFeeLossAmount(position: PositionData | null) {
  return Math.abs(Number(position?.totalFee || 0))
}

function takeProfitOrderTypeText(value?: string) {
  return value === 'limit' ? '限价' : '市价'
}

function stopDisplayText(isSet: boolean, price: number) {
  if (!isSet || !Number.isFinite(price) || price <= 0) return '未设置'
  return formatSmartAmount(price)
}

// ============ Mock Indicator Init ============

function useInitMockIndicators() {
  useEffect(() => {
    const mockIndicators = [
      {
        id: '1', name: '趋势突破策略',
        requiredConditions: [
          { id: 'r1', text: 'K线实体突破前高阻力位，收盘价站稳阻力位上方' },
          { id: 'r2', text: '成交量明显放大，至少是前5根K线平均成交量的1.5倍以上' },
          { id: 'r3', text: 'MACD指标形成金叉，且DIF和DEA都在零轴上方' },
          { id: 'r4', text: 'RSI指标在50-70区间，显示多头强势但未超买' },
          { id: 'r5', text: '日线级别处于上升趋势中，价格在MA20均线上方运行' },
        ],
        optionalConditions: [
          { id: 'o1', text: '布林带开口扩大，价格突破上轨' },
          { id: 'o2', text: '分时图呈现明显的放量上攻态势' },
          { id: 'o3', text: '大盘同时段处于上涨状态，市场情绪良好' },
        ],
        createdAt: '2025-01-10',
      },
      {
        id: '2', name: '回调买入法',
        requiredConditions: [
          { id: 'r1', text: '价格回调至20日均线获得支撑，出现下影线较长的K线' },
          { id: 'r2', text: 'MACD指标虽有回调但未跌破零轴，保持多头排列' },
          { id: 'r3', text: 'KDJ指标在20-50之间形成金叉，显示回调结束' },
        ],
        optionalConditions: [
          { id: 'o1', text: '回调幅度控制在前期涨幅的1/3以内' },
          { id: 'o2', text: '成交量在回调过程中逐步萎缩，显示抛压减轻' },
          { id: 'o3', text: '前期突破时留下的缺口未被回补' },
          { id: 'o4', text: '市场热点板块轮动，资金面表现活跃' },
          { id: 'o5', text: '大周期（周线、月线）仍保持上涨趋势' },
        ],
        createdAt: '2025-01-11',
      },
    ]

    const stored = localStorage.getItem('crypto_trading_indicators')
    if (stored) {
      try {
        const existing: unknown = JSON.parse(stored)
        if (!Array.isArray(existing)) throw new Error('invalid indicator cache')
        const hasName = (indicator: unknown, name: string) => {
          if (typeof indicator !== 'object' || indicator === null) return false
          return (indicator as Record<string, unknown>).name === name
        }
        const hasMock1 = existing.some(indicator => hasName(indicator, '趋势突破策略'))
        const hasMock2 = existing.some(indicator => hasName(indicator, '回调买入法'))
        if (!hasMock1 || !hasMock2) {
          const updated = [...existing]
          if (!hasMock1) updated.push(mockIndicators[0])
          if (!hasMock2) updated.push(mockIndicators[1])
          localStorage.setItem('crypto_trading_indicators', JSON.stringify(updated))
        }
      } catch {
        localStorage.setItem('crypto_trading_indicators', JSON.stringify(mockIndicators))
      }
    } else {
      localStorage.setItem('crypto_trading_indicators', JSON.stringify(mockIndicators))
    }
  }, [])
}

// ============ Main Page ============

export function HoldingsPage() {
  const standalone = isStandaloneMode()
  const location = useLocation()
  const authUserId = useAuthStore(s => s.user?.id ?? '')
  useInitMockIndicators()

  const positionsCacheKey = scopedAccountCacheKey(POSITIONS_CACHE_KEY_PREFIX, authUserId)
  const limitOrdersCacheKey = scopedAccountCacheKey(LIMIT_ORDERS_CACHE_KEY_PREFIX, authUserId)

  const initTab = (location.state as { activeTab?: TabType } | null)?.activeTab || 'positions'
  const [activeTab, setActiveTab] = useState<TabType>(initTab)
  const [historyFilter, setHistoryFilter] = useState<'all' | 'day' | 'three-days' | 'week'>('all')

  // Modal states
  const [showCloseConfirm, setShowCloseConfirm] = useState(false)
  const [showCloseAllConfirm, setShowCloseAllConfirm] = useState(false)
  const [skipCloseAllConfirm, setSkipCloseAllConfirm] = useState(false)
  const [showChaseConfirm, setShowChaseConfirm] = useState(false)
  const [showCancelStrategyConfirm, setShowCancelStrategyConfirm] = useState(false)
  const [showManualProfitInfo, setShowManualProfitInfo] = useState(false)
  const [showApiBindPrompt, setShowApiBindPrompt] = useState(false)
  const [showApiBindModal, setShowApiBindModal] = useState(false)
  const [showStrategyDetail, setShowStrategyDetail] = useState(false)
  const [showIndicatorDetail, setShowIndicatorDetail] = useState(false)
  const [showStrategyPicker, setShowStrategyPicker] = useState(false)
  const [showTakeProfitModal, setShowTakeProfitModal] = useState(false)
  const [takeProfitPriceInput, setTakeProfitPriceInput] = useState('')
  const [takeProfitIsLimit, setTakeProfitIsLimit] = useState(false)
  const [takeProfitSubmitting, setTakeProfitSubmitting] = useState(false)
  const [showBreakEvenModal, setShowBreakEvenModal] = useState(false)
  const [breakEvenSubmitting, setBreakEvenSubmitting] = useState(false)

  const [selectedPosition, setSelectedPosition] = useState<PositionData | null>(null)
  const [selectedIndicatorName, setSelectedIndicatorName] = useState<string | null>(null)
  const [selectedStrategyForDetail, setSelectedStrategyForDetail] = useState<Strategy | null>(null)
  const [selectedStrategyLogLines, setSelectedStrategyLogLines] = useState<string[]>([])
  const [selectedStrategyLogLoading, setSelectedStrategyLogLoading] = useState(false)
  const [closingAll, setClosingAll] = useState(false)
  const [closingPosition, setClosingPosition] = useState(false)
  const [chaseSubmitting, setChaseSubmitting] = useState(false)
  const [positions, setPositions] = useState<PositionData[]>(
    () => readLocalCache<PositionData[]>(positionsCacheKey) ?? [],
  )
  const [positionsLoading, setPositionsLoading] = useState(
    () => (readLocalCache<PositionData[]>(positionsCacheKey)?.length ?? 0) === 0,
  )

  // 持仓卡片当前价格：走币安公开行情接口，不使用 API Key
  const [livePrices, setLivePrices] = useState<Record<string, number>>({})
  const livePriceSymbols = useMemo(
    () => [...new Set(positions.map((item) => String(item.pair || '').toUpperCase()).filter(Boolean))],
    [positions],
  )

  // 限价委托数据
  const [limitOrders, setLimitOrders] = useState<LimitOrderData[]>(() => readLocalCache<LimitOrderData[]>(limitOrdersCacheKey) ?? [])
  const [limitOrdersLoading, setLimitOrdersLoading] = useState(() => (readLocalCache<LimitOrderData[]>(limitOrdersCacheKey)?.length ?? 0) === 0)
  const [selectedLimitOrder, setSelectedLimitOrder] = useState<LimitOrderData | null>(null)
  const [showCancelOrderConfirm, setShowCancelOrderConfirm] = useState(false)

  // 历史仓位数据
  const [historyPositions, setHistoryPositions] = useState<HistoryPositionData[]>(() => readInitialHistoryCache(authUserId)?.items ?? [])
  const [historyPagination, setHistoryPagination] = useState<HistoryPaginationData>(
    () => readInitialHistoryCache(authUserId)?.pagination ?? {
      page: 1,
      page_size: HISTORY_PAGE_SIZE,
      total: 0,
      has_next: false,
      has_previous: false,
    },
  )
  const [historyLoading, setHistoryLoading] = useState(() => readInitialHistoryCache(authUserId) === null)
  const [availableStrategies, setAvailableStrategies] = useState<Strategy[]>([])
  const replaceStrategies = useTradingStore(s => s.replaceStrategies)
  const [isRefreshing, setIsRefreshing] = useState(false)
  const [pullDistance, setPullDistance] = useState(0)
  const [isPulling, setIsPulling] = useState(false)
  const scrollRef = useRef<HTMLDivElement | null>(null)
  const historyLoadMoreRef = useRef<HTMLDivElement | null>(null)
  const touchStartYRef = useRef<number | null>(null)
  const isRefreshingRef = useRef(false)
  const isPullingRef = useRef(false)
  const pullDistanceRef = useRef(0)
  const positionsLoadedRef = useRef(positions.length > 0)
  // 上一次持仓列表中的币种：用于检测持仓结束并清理对应K线缓存
  const prevPositionSymbolsRef = useRef<string[] | null>(null)
  const limitOrdersLoadedRef = useRef(limitOrders.length > 0)
  const historyLoadedRef = useRef(historyPositions.length > 0)
  const positionsRequestIdRef = useRef(0)
  const limitOrdersRequestIdRef = useRef(0)
  const historyRequestIdRef = useRef(0)
  const strategiesRequestIdRef = useRef(0)

  const readCache = useCallback(<T,>(key: string | null): T | null => {
    if (!key) return null
    try {
      const raw = window.localStorage.getItem(key)
      if (!raw) return null
      return JSON.parse(raw) as T
    } catch {
      return null
    }
  }, [])

  const writeCache = useCallback((key: string | null, value: unknown) => {
    if (!key) return
    try {
      window.localStorage.setItem(key, JSON.stringify(value))
    } catch {
      // ignore cache failures
    }
  }, [])

  useEffect(() => {
    try {
      for (const key of LEGACY_HOLDINGS_CACHE_KEYS) window.localStorage.removeItem(key)
      const legacyKeys = Array.from({ length: window.localStorage.length }, (_, index) =>
        window.localStorage.key(index),
      )
      for (const key of legacyKeys) {
        if (key?.startsWith(LEGACY_HISTORY_CACHE_KEY_PREFIX)) window.localStorage.removeItem(key)
      }
    } catch {
      // Browser storage is an optional performance cache.
    }
  }, [])

  useLayoutEffect(() => {
    positionsRequestIdRef.current += 1
    limitOrdersRequestIdRef.current += 1
    historyRequestIdRef.current += 1
    strategiesRequestIdRef.current += 1
    const cachedPositions = readCache<PositionData[]>(positionsCacheKey) ?? []
    setPositions(cachedPositions)
    positionsLoadedRef.current = cachedPositions.length > 0
    setPositionsLoading(cachedPositions.length === 0)

    const cachedLimitOrders = readCache<LimitOrderData[]>(limitOrdersCacheKey) ?? []
    setLimitOrders(cachedLimitOrders)
    limitOrdersLoadedRef.current = cachedLimitOrders.length > 0
    setLimitOrdersLoading(cachedLimitOrders.length === 0)
    setLivePrices({})
    setAvailableStrategies([])
    setSelectedPosition(null)
    setShowStrategyPicker(false)
    setShowTakeProfitModal(false)
    setShowBreakEvenModal(false)
    prevPositionSymbolsRef.current = null
  }, [authUserId, limitOrdersCacheKey, positionsCacheKey, readCache])

  useEffect(() => {
    const cachedHistory = readCache<HistoryResponseData | HistoryPositionData[]>(
      historyCacheKey(authUserId, historyFilter),
    )
    if (cachedHistory) {
      if (Array.isArray(cachedHistory) && cachedHistory.length) {
        setHistoryPositions(cachedHistory)
        setHistoryPagination({
          page: 1,
          page_size: cachedHistory.length,
          total: cachedHistory.length,
          has_next: false,
          has_previous: false,
        })
      } else if (!Array.isArray(cachedHistory) && cachedHistory.items?.length) {
        setHistoryPositions(cachedHistory.items)
        setHistoryPagination(cachedHistory.pagination)
      } else {
        return
      }
      historyLoadedRef.current = true
      setHistoryLoading(false)
      return
    }
    setHistoryPositions([])
    setHistoryPagination({
      page: 1,
      page_size: HISTORY_PAGE_SIZE,
      total: 0,
      has_next: false,
      has_previous: false,
    })
    historyLoadedRef.current = false
    setHistoryLoading(true)
  }, [authUserId, historyFilter, readCache])

  useEffect(() => {
    isRefreshingRef.current = isRefreshing
  }, [isRefreshing])

  useEffect(() => {
    isPullingRef.current = isPulling
  }, [isPulling])

  useEffect(() => {
    pullDistanceRef.current = pullDistance
  }, [pullDistance])

  const loadPositions = useCallback(async (showError = true, requestOptions: RefreshRequestOptions = {}) => {
    const shouldSyncLayout = !positionsLoadedRef.current
    const requestUserId = authUserId
    const requestSessionRevision = getAccountSessionRevision()
    const requestId = ++positionsRequestIdRef.current
    const isCurrentRequest = () => isCurrentAccountRequestScope(
      requestUserId,
      useAuthStore.getState().user?.id ?? '',
      requestId,
      positionsRequestIdRef.current,
      requestSessionRevision,
      getAccountSessionRevision(),
    )
    try {
      const data = await api.get<Array<{
        id: number
        position_origin?: 'web' | 'exchange_external'
        symbol: string
        side: number
        position_amount: string
        pnl: string
        pnl_ratio: string
        open_price: string
        initial_stop_price: string
        current_price: string
        exchange_size: string
        has_manual_addition: boolean
        stop_loss_price: string
        limit_stop_price: string
        market_stop_price: string
        stop_loss_pnl: string
        stop_loss_amount: string
        stop_protection_status: string
        stop_protection_error: string
        latest_strategy_error?: string
        limit_stop_set: boolean
        market_stop_set: boolean
        estimated_total_fee: string
        entry_realized_fee: string | null
        entry_fee_asset: string
        entry_fee_status: string
        entry_fee_error: string
        leverage: string
        strategy_status: number
        can_bind_strategy: boolean
        strategy_snapshot_id: number | null
        strategy_name: string
        strategy_config: StrategyLevel[] | null
        manual_take_profit_set: boolean
        manual_take_profit_price: string
        manual_take_profit_order_type: string
        manual_take_profit_pnl: string
        created_at: string | null
      }>>('/position/list', requestOptions)
      if (!isCurrentRequest()) return false

      const mapped = data.map((row) => {
        const pnl = Number(row.pnl || 0)
        const strategyType = row.strategy_status === 1
          ? ('auto' as const)
          : row.strategy_status === 2
            ? ('manual-cancelled' as const)
            : ('none' as const)
        return {
          id: row.id,
          positionOrigin: row.position_origin === 'exchange_external' ? ('exchange_external' as const) : ('web' as const),
          pair: row.symbol,
          balance: Number(row.position_amount || 0),
          profit: pnl,
          profitPercent: Number(row.pnl_ratio || 0),
          openPrice: Number(row.open_price || 0),
          initialStopPrice: Number(row.initial_stop_price || row.stop_loss_price || 0),
          currentPrice: Number(row.current_price || 0),
          exchangeSize: Number(row.exchange_size || 0),
          hasManualAddition: !!row.has_manual_addition,
          stopLoss: Number(row.stop_loss_price || 0),
          stopProfit: Number(row.stop_loss_pnl || 0),
          totalFee: Number(row.estimated_total_fee || 0),
          leverage: row.leverage || '--',
          stopLossAmount: Number(row.stop_loss_amount || 0),
          stopProtectionStatus: row.stop_protection_status || 'complete',
          stopProtectionError: row.stop_protection_error || '',
          latestStrategyError: row.latest_strategy_error || '',
          limitStopSet: !!row.limit_stop_set,
          marketStopSet: !!row.market_stop_set,
          limitStopPrice: Number(row.limit_stop_price || 0),
          marketStopPrice: Number(row.market_stop_price || 0),
          entryFee: row.entry_realized_fee === null || row.entry_realized_fee === undefined
            ? null
            : Number(row.entry_realized_fee || 0),
          entryFeeAsset: row.entry_fee_asset || '',
          entryFeeStatus: row.entry_fee_status || 'pending',
          entryFeeError: row.entry_fee_error || '',
          canBindStrategy: !!row.can_bind_strategy,
          isProfit: pnl >= 0,
          positionType: row.side === 0 ? ('long' as const) : ('short' as const),
          strategyType,
          strategyId: row.strategy_snapshot_id ? String(row.strategy_snapshot_id) : '',
          strategy: row.strategy_name && Array.isArray(row.strategy_config)
            ? {
                id: row.strategy_snapshot_id ? String(row.strategy_snapshot_id) : String(row.id),
                name: row.strategy_name,
                levels: row.strategy_config,
              }
            : null,
          manualTakeProfitSet: !!row.manual_take_profit_set,
          manualTakeProfitPrice: Number(row.manual_take_profit_price || 0),
          manualTakeProfitOrderType: row.manual_take_profit_order_type || '',
          manualTakeProfitPnl: Number(row.manual_take_profit_pnl || 0),
          createdAt: row.created_at || '',
        }
      })
      setPositions(mapped)
      writeCache(positionsCacheKey, mapped)
      positionsLoadedRef.current = true
      // 持仓结束的币种：清理对应K线缓存
      const activeSymbols = mapped.map(p => String(p.pair || '').toUpperCase()).filter(Boolean)
      if (prevPositionSymbolsRef.current) {
        const active = new Set(activeSymbols)
        for (const sym of prevPositionSymbolsRef.current) {
          if (!active.has(sym)) clearKlineCacheSymbol(sym)
        }
      }
      prevPositionSymbolsRef.current = activeSymbols
      return true
    } catch (error) {
      if (!isCurrentRequest()) return false
      if (isApiBindRequiredError(error)) {
        if (showError) setShowApiBindPrompt(true)
        return false
      }
      if (showError) {
        const message = error instanceof ApiError ? error.message : '获取持仓失败，请稍后重试'
        showToast(message)
      }
      return false
    } finally {
      if (isCurrentRequest()) {
        setPositionsLoading(false)
        if (shouldSyncLayout) {
          requestAppLayoutSync('holdings-positions-loaded')
        }
      }
    }
  }, [authUserId, positionsCacheKey, writeCache])

  // 每 5 秒轮询公开行情最新价，仅刷新卡片上的当前价格，不触发带 API Key 的持仓接口
  useEffect(() => {
    if (activeTab !== 'positions' || livePriceSymbols.length === 0) return
    let cancelled = false
    let inflight = false
    const fetchPrices = async () => {
      // 页面不可见或上一轮未返回时跳过，避免后台耗电与请求堆积
      if (document.visibilityState !== 'visible' || inflight) return
      inflight = true
      try {
        const data = await api.get<{ prices: Record<string, string> }>(
          `/trade/market/prices?symbols=${livePriceSymbols.join(',')}`,
          { suppressConnectionError: true, disableRetry: true },
        )
        if (cancelled || !data?.prices) return
        const next: Record<string, number> = {}
        for (const [symbol, raw] of Object.entries(data.prices)) {
          const value = Number(raw)
          if (value > 0) next[symbol] = value
        }
        setLivePrices(next)
      } catch {
        // 静默轮询：行情获取失败时保留上一次价格
      } finally {
        inflight = false
      }
    }
    void fetchPrices()
    const timer = window.setInterval(fetchPrices, 5000)
    return () => {
      cancelled = true
      window.clearInterval(timer)
    }
  }, [activeTab, livePriceSymbols])

  const loadStrategies = useCallback(async () => {
    const requestUserId = authUserId
    const requestSessionRevision = getAccountSessionRevision()
    const requestId = ++strategiesRequestIdRef.current
    const data = await api.get<Array<{
      id: number
      name: string
      is_active: boolean
      levels: StrategyLevel[]
    }>>('/strategy/list')
    if (!isCurrentAccountRequestScope(
      requestUserId,
      useAuthStore.getState().user?.id ?? '',
      requestId,
      strategiesRequestIdRef.current,
      requestSessionRevision,
      getAccountSessionRevision(),
    )) return []
    const mapped = data.map((row) => ({
      id: String(row.id),
      name: row.name,
      levels: row.levels,
    }))
    setAvailableStrategies(mapped)
    replaceStrategies(mapped)
    return mapped
  }, [authUserId, replaceStrategies])

  const openStrategyPicker = useCallback(async (position: PositionData) => {
    if (!position.canBindStrategy) {
      showToast('该订单无法添加止盈策略')
      return
    }
    try {
      const strategies = await loadStrategies()
      if (!strategies.length) {
        showToast('暂无可用策略，请先创建策略')
        return
      }
      setSelectedPosition(position)
      setShowStrategyPicker(true)
    } catch (error) {
      const message = error instanceof ApiError ? error.message : '获取策略列表失败，请稍后重试'
      showToast(message)
    }
  }, [loadStrategies])

  const getTriggeredLevelIndexes = useCallback((strategyId?: string) => {
    if (!selectedPosition?.id) return []
    const selectedStrategy = availableStrategies.find((item) => item.id === strategyId) || null
    if (!selectedStrategy) return []

    const openPrice = Number(selectedPosition.openPrice || 0)
    const initialStopPrice = Number(selectedPosition.initialStopPrice || 0)
    const currentPrice = Number(selectedPosition.currentPrice || 0)
    const baseR = Math.abs(openPrice - initialStopPrice)
    if (!baseR || !currentPrice) return []

    return selectedStrategy.levels.reduce<number[]>((indexes, level, index) => {
      const triggerPrice = selectedPosition.positionType === 'long'
        ? openPrice + Number(level.profitRR || 0) * baseR
        : openPrice - Number(level.profitRR || 0) * baseR
      const triggered = selectedPosition.positionType === 'long'
        ? currentPrice >= triggerPrice
        : currentPrice <= triggerPrice
      if (triggered) indexes.push(index)
      return indexes
    }, [])
  }, [availableStrategies, selectedPosition])

  const openTakeProfitEditor = useCallback((position: PositionData) => {
    setSelectedPosition(position)
    setTakeProfitPriceInput(position.manualTakeProfitPrice > 0 ? String(position.manualTakeProfitPrice) : '')
    setTakeProfitIsLimit(position.manualTakeProfitOrderType === 'limit')
    setShowTakeProfitModal(true)
  }, [])

  const openBreakEvenEditor = useCallback((position: PositionData) => {
    // 浮亏时也允许设置：后端会改挂收益为 0 的保本止盈单
    setSelectedPosition(position)
    setShowBreakEvenModal(true)
  }, [])

  const submitBreakEvenStop = useCallback(async (mode: 'with_fee' | 'without_fee') => {
    if (!selectedPosition?.id) return
    const feeLoss = estimatedFeeLossAmount(selectedPosition)
    const inProfit = Number(selectedPosition.profit || 0) > 0
    if (inProfit && mode === 'with_fee' && Number(selectedPosition.profit || 0) <= feeLoss) {
      showToast('当前浮盈不足以覆盖手续费')
      return
    }
    try {
      setBreakEvenSubmitting(true)
      const result = await api.post<{ type?: string; stop_loss_price?: string; take_profit_price?: string }>('/position/break-even-stop', {
        position_id: selectedPosition.id,
        mode,
      })
      setShowBreakEvenModal(false)
      if (result?.type === 'take_profit') {
        showToast(`保本止盈已挂单\n止盈价 ${formatSmartAmount(Number(result?.take_profit_price || 0))}`)
      } else {
        showToast(`保本损已设置\n止损价 ${formatSmartAmount(Number(result?.stop_loss_price || 0))}`)
      }
      await loadPositions(false, { suppressConnectionError: true, disableRetry: true, timeout: SILENT_REFRESH_TIMEOUT })
    } catch (error) {
      if (isApiBindRequiredError(error)) {
        setShowApiBindPrompt(true)
        return
      }
      const message = error instanceof ApiError ? error.message : '设置保本损失败，请稍后重试'
      showToast(message)
    } finally {
      setBreakEvenSubmitting(false)
    }
  }, [loadPositions, selectedPosition])

  const submitManualTakeProfit = useCallback(async () => {
    if (!selectedPosition?.id) return
    const price = Number(takeProfitPriceInput)
    if (!Number.isFinite(price) || price <= 0) {
      showToast('请输入有效止盈价格')
      return
    }
    try {
      setTakeProfitSubmitting(true)
      const result = await api.post<{ strategy_cancelled?: boolean }>('/position/take-profit', {
        position_id: selectedPosition.id,
        take_profit_price: takeProfitPriceInput,
        order_type: takeProfitIsLimit ? 'limit' : 'market',
      })
      setShowTakeProfitModal(false)
      showToast(result?.strategy_cancelled ? '止盈已设置，自动止盈策略已取消' : '止盈已设置')
      await loadPositions(false, { suppressConnectionError: true, disableRetry: true, timeout: SILENT_REFRESH_TIMEOUT })
    } catch (error) {
      if (isApiBindRequiredError(error)) {
        setShowApiBindPrompt(true)
        return
      }
      const message = error instanceof ApiError ? error.message : '设置止盈失败，请稍后重试'
      showToast(message)
    } finally {
      setTakeProfitSubmitting(false)
    }
  }, [loadPositions, selectedPosition?.id, takeProfitIsLimit, takeProfitPriceInput])

  const cancelManualTakeProfit = useCallback(async () => {
    if (!selectedPosition?.id) return
    try {
      setTakeProfitSubmitting(true)
      await api.delete('/position/take-profit', { data: { position_id: selectedPosition.id } })
      setShowTakeProfitModal(false)
      showToast('止盈已取消')
      await loadPositions(false, { suppressConnectionError: true, disableRetry: true, timeout: SILENT_REFRESH_TIMEOUT })
    } catch (error) {
      if (isApiBindRequiredError(error)) {
        setShowApiBindPrompt(true)
        return
      }
      const message = error instanceof ApiError ? error.message : '取消止盈失败，请稍后重试'
      showToast(message)
    } finally {
      setTakeProfitSubmitting(false)
    }
  }, [loadPositions, selectedPosition?.id])

  const loadLimitOrders = useCallback(async (requestOptions: RefreshRequestOptions = {}) => {
    const requestUserId = authUserId
    const requestSessionRevision = getAccountSessionRevision()
    const requestId = ++limitOrdersRequestIdRef.current
    const isCurrentRequest = () => isCurrentAccountRequestScope(
      requestUserId,
      useAuthStore.getState().user?.id ?? '',
      requestId,
      limitOrdersRequestIdRef.current,
      requestSessionRevision,
      getAccountSessionRevision(),
    )
    try {
      const data = await api.get<LimitOrderData[]>('/trade/limit-order/list', requestOptions)
      if (!isCurrentRequest()) return false
      setLimitOrders(data)
      writeCache(limitOrdersCacheKey, data)
      limitOrdersLoadedRef.current = true
      return true
    } catch (error) {
      if (!isCurrentRequest()) return false
      if (isApiBindRequiredError(error)) {
        setShowApiBindPrompt(true)
        return false
      }
      console.error('获取限价委托失败', error)
      return false
    } finally {
      if (isCurrentRequest()) {
        setLimitOrdersLoading(false)
        requestAppLayoutSync('holdings-limit-orders-loaded')
      }
    }
  }, [authUserId, limitOrdersCacheKey, writeCache])

  const loadHistory = useCallback(async (
    requestOptions: RefreshRequestOptions = {},
    page = 1,
    append = false,
  ) => {
    const requestUserId = authUserId
    const requestSessionRevision = getAccountSessionRevision()
    const requestId = ++historyRequestIdRef.current
    const isCurrentRequest = () => isCurrentAccountRequestScope(
      requestUserId,
      useAuthStore.getState().user?.id ?? '',
      requestId,
      historyRequestIdRef.current,
      requestSessionRevision,
      getAccountSessionRevision(),
    )
    try {
      const data = await api.get<HistoryResponseData>(
        `/position/history?filter=${historyFilter}&page=${page}&page_size=${HISTORY_PAGE_SIZE}`,
        requestOptions,
      )
      if (!isCurrentRequest()) return
      const items = Array.isArray(data?.items) ? data.items : []
      setHistoryPositions(prev => (append ? [...prev, ...items] : items))
      setHistoryPagination(data?.pagination || {
        page,
        page_size: HISTORY_PAGE_SIZE,
        total: items.length,
        has_next: false,
        has_previous: page > 1,
      })
      if (!append) {
        writeCache(historyCacheKey(requestUserId, historyFilter), data)
      }
      historyLoadedRef.current = true
    } catch (error) {
      if (!isCurrentRequest()) return
      if (isApiBindRequiredError(error)) {
        setShowApiBindPrompt(true)
        return
      }
      console.error('获取历史仓位失败', error)
    } finally {
      if (isCurrentRequest()) {
        setHistoryLoading(false)
        requestAppLayoutSync('holdings-history-loaded')
      }
    }
  }, [authUserId, historyFilter, writeCache])

  const loadMoreHistory = useCallback(async () => {
    if (historyLoading || !historyPagination.has_next) return
    setHistoryLoading(true)
    await loadHistory(
      {
        suppressConnectionError: true,
        disableRetry: true,
        timeout: SILENT_REFRESH_TIMEOUT,
      },
      historyPagination.page + 1,
      true,
    )
  }, [historyLoading, historyPagination.has_next, historyPagination.page, loadHistory])

  useEffect(() => {
    if (activeTab !== 'history') return
    const scroller = scrollRef.current
    const sentinel = historyLoadMoreRef.current
    if (!scroller || !sentinel || !historyPagination.has_next) return

    const observer = new IntersectionObserver(
      (entries) => {
        const entry = entries[0]
        if (entry?.isIntersecting) {
          void loadMoreHistory()
        }
      },
      {
        root: scroller,
        rootMargin: '0px 0px 120px 0px',
        threshold: 0.1,
      },
    )

    observer.observe(sentinel)
    return () => observer.disconnect()
  }, [activeTab, historyPagination.has_next, loadMoreHistory])

  useEffect(() => {
    const scroller = scrollRef.current
    if (!showStrategyDetail || !scroller) return

    const previousOverflowY = scroller.style.overflowY
    const previousOverscrollBehaviorY = scroller.style.overscrollBehaviorY
    scroller.style.overflowY = 'hidden'
    scroller.style.overscrollBehaviorY = 'none'

    return () => {
      scroller.style.overflowY = previousOverflowY
      scroller.style.overscrollBehaviorY = previousOverscrollBehaviorY
    }
  }, [showStrategyDetail])

  const openStrategyExecutionDetail = useCallback(async (
    positionId: number | null,
    fallbackStrategy: Strategy | null,
    _mode: 'running' | 'history',
  ) => {
    if (!positionId) return
    try {
      setShowStrategyDetail(true)
      setSelectedStrategyLogLoading(true)
      setSelectedStrategyLogLines([])
      if (fallbackStrategy) {
        setSelectedStrategyForDetail(fallbackStrategy)
      } else {
        setSelectedStrategyForDetail(null)
      }
      const detail = await api.get<StrategyLogResponse>(`/strategy/log?position_id=${positionId}`)
      const strategyFromApi: Strategy | null =
        detail.strategy_name && Array.isArray(detail.strategy_config)
          ? {
              id: String(positionId),
              name: detail.strategy_name,
              levels: detail.strategy_config,
            }
          : null
      const finalStrategy = fallbackStrategy || strategyFromApi
      if (!finalStrategy) {
        throw new Error('策略详情不存在')
      }
      setSelectedStrategyForDetail(finalStrategy)
      const lines = (detail.logs || []).map((log) => {
        const prefix = log.result ? `[${log.result}] ` : ''
        const formattedDesc = formatAmountsInLogText(log.behavior_desc || '')
        const suffix = log.error ? `（${formatAmountsInLogText(log.error)}）` : ''
        return `${prefix}${formattedDesc}${suffix}`
      })
      setSelectedStrategyLogLines(lines)
    } catch (error) {
      setShowStrategyDetail(false)
      const message = error instanceof ApiError ? error.message : '获取日志失败，请稍后重试'
      showToast(message)
    } finally {
      setSelectedStrategyLogLoading(false)
    }
  }, [])

  useEffect(() => {
    if (activeTab !== 'positions') return
    const FOREGROUND_MS = 3000
    const BACKGROUND_MS = 60000
    const MAX_BACKOFF_MS = 120000
    let timer: number | null = null
    let disposed = false
    let consecutiveFails = 0

    const withJitter = (base: number) => {
      // Add light jitter to avoid bursty synchronized polling from multiple clients.
      const jitter = Math.floor(Math.random() * 700)
      return base + jitter
    }

    const nextDelay = () => {
      const base = document.visibilityState === 'visible' ? FOREGROUND_MS : BACKGROUND_MS
      if (consecutiveFails <= 0) return withJitter(base)
      const backedOff = Math.min(base * Math.pow(2, Math.min(consecutiveFails, 2)), MAX_BACKOFF_MS)
      return withJitter(backedOff)
    }

    const tick = async () => {
      if (disposed) return
      if (document.visibilityState !== 'visible') {
        timer = window.setTimeout(tick, nextDelay())
        return
      }
      const success = await loadPositions(false, {
        suppressConnectionError: true,
        disableRetry: true,
        timeout: SILENT_REFRESH_TIMEOUT,
      })
      if (disposed) return
      consecutiveFails = success ? 0 : Math.min(consecutiveFails + 1, 3)
      timer = window.setTimeout(tick, nextDelay())
    }

    setPositionsLoading(!positionsLoadedRef.current && positions.length === 0)
    if (document.visibilityState === 'visible') {
      void loadPositions(false, {
        suppressConnectionError: true,
        disableRetry: true,
        timeout: SILENT_REFRESH_TIMEOUT,
      })
    }
    timer = window.setTimeout(tick, nextDelay())

    return () => {
      disposed = true
      if (timer !== null) window.clearTimeout(timer)
    }
  }, [activeTab, loadPositions, positions.length])

  // 加载限价委托列表
  useEffect(() => {
    if (activeTab !== 'limit-orders') return
    const FOREGROUND_MS = 10000
    const BACKGROUND_MS = 45000
    const MAX_BACKOFF_MS = 60000
    let timer: number | null = null
    let disposed = false
    let consecutiveFails = 0

    const nextDelay = () => {
      const base = document.visibilityState === 'visible' ? FOREGROUND_MS : BACKGROUND_MS
      if (consecutiveFails <= 0) return base
      return Math.min(base * Math.pow(2, Math.min(consecutiveFails, 2)), MAX_BACKOFF_MS)
    }

    const tick = async () => {
      if (disposed) return
      const success = await loadLimitOrders({
        suppressConnectionError: true,
        disableRetry: true,
        timeout: SILENT_REFRESH_TIMEOUT,
      })
      if (disposed) return
      consecutiveFails = success ? 0 : Math.min(consecutiveFails + 1, 3)
      timer = window.setTimeout(tick, nextDelay())
    }

    setLimitOrdersLoading(!limitOrdersLoadedRef.current && limitOrders.length === 0)
    void loadLimitOrders({
      suppressConnectionError: true,
      disableRetry: true,
      timeout: SILENT_REFRESH_TIMEOUT,
    })
    timer = window.setTimeout(tick, nextDelay())

    return () => {
      disposed = true
      if (timer !== null) window.clearTimeout(timer)
    }
  }, [activeTab, loadLimitOrders, limitOrders.length])

  // 加载历史仓位
  useEffect(() => {
    if (activeTab !== 'history') return
    setHistoryLoading(!historyLoadedRef.current)
    void loadHistory({
      suppressConnectionError: true,
      disableRetry: true,
      timeout: SILENT_REFRESH_TIMEOUT,
    })
  }, [activeTab, historyFilter, loadHistory])

  useEffect(() => {
    setPullDistance(0)
    setIsPulling(false)
  }, [activeTab])

  const refreshActiveTab = useCallback(async () => {
    if (isRefreshingRef.current) return
    isRefreshingRef.current = true
    setIsRefreshing(true)
    try {
      if (activeTab === 'positions') {
        await loadPositions(true)
      } else if (activeTab === 'limit-orders') {
        await loadLimitOrders()
      } else {
        await loadHistory({}, 1, false)
      }
    } finally {
      setTimeout(() => {
        isRefreshingRef.current = false
        setIsRefreshing(false)
        setPullDistance(0)
        setIsPulling(false)
      }, 200)
    }
  }, [activeTab, loadHistory, loadLimitOrders, loadPositions])

  useEffect(() => {
    const onResume = () => {
      if (document.visibilityState !== 'visible') return
      if (isRefreshingRef.current) return
      if (activeTab === 'positions') {
        void loadPositions(false, {
          suppressConnectionError: true,
          disableRetry: true,
          timeout: SILENT_REFRESH_TIMEOUT,
        })
      } else if (activeTab === 'limit-orders') {
        void loadLimitOrders({
          suppressConnectionError: true,
          disableRetry: true,
          timeout: SILENT_REFRESH_TIMEOUT,
        })
      } else {
        void loadHistory({
          suppressConnectionError: true,
          disableRetry: true,
          timeout: SILENT_REFRESH_TIMEOUT,
        })
      }
    }
    window.addEventListener('app:resume', onResume as EventListener)
    return () => window.removeEventListener('app:resume', onResume as EventListener)
  }, [activeTab, loadHistory, loadLimitOrders, loadPositions])

  const tabs: { key: TabType; label: string }[] = [
    { key: 'positions', label: '持仓' },
    { key: 'limit-orders', label: '限价委托' },
    { key: 'history', label: '历史仓位' },
  ]

  const historyFilters = [
    { key: 'all' as const, label: '全部' },
    { key: 'day' as const, label: '一天内' },
    { key: 'three-days' as const, label: '三天' },
    { key: 'week' as const, label: '一周' },
  ]
  const contentBottomPadding = standalone
    ? '124px'
    : '88px'
  const refreshThreshold = 64
  const refreshIndicatorHeight = isRefreshing ? Math.max(refreshThreshold, pullDistance) : pullDistance
  const totalPositionsPnl = positions.reduce((sum, position) => sum + Number(position.profit || 0), 0)
  const totalPositionsPnlText = `${totalPositionsPnl >= 0 ? '+' : ''}${formatSmartAmount(totalPositionsPnl)}`
  const closeAllButtonClass = totalPositionsPnl >= 0
    ? 'bg-[#0ECB81] hover:bg-[#0DB872]'
    : 'bg-[#F6465D] hover:bg-[#E0394D]'
  const selectedBreakEvenFeeLoss = estimatedFeeLossAmount(selectedPosition)
  const selectedBreakEvenProfit = Number(selectedPosition?.profit || 0)
  // 浮亏时后端改挂保本止盈单，不再要求浮盈覆盖手续费
  const selectedBreakEvenInProfit = selectedBreakEvenProfit > 0
  const canSubmitBreakEvenWithFee = !selectedBreakEvenInProfit || selectedBreakEvenProfit > selectedBreakEvenFeeLoss

  const closeAllPositions = useCallback(async () => {
    if (closingAll) return
    const targets = positions.filter((position) => position.id)
    if (targets.length <= 1) {
      setShowCloseAllConfirm(false)
      return
    }

    setClosingAll(true)
    const closedIds: number[] = []
    let successCount = 0
    let failedCount = 0
    let actualPnl = 0
    let hasUnknownPnl = false
    let lastError = ''
    let apiBindRequired = false

    for (const position of targets) {
      try {
        const result = await api.post<PositionCloseResult>('/position/close', { position_id: position.id })
        closedIds.push(position.id)
        successCount += 1
        const pnl = confirmedClosePnl(result)
        if (pnl === null) hasUnknownPnl = true
        else actualPnl += pnl
      } catch (error) {
        failedCount += 1
        if (isApiBindRequiredError(error)) {
          apiBindRequired = true
          break
        }
        lastError = error instanceof ApiError ? error.message : '平仓失败，请稍后重试'
      }
    }

    if (closedIds.length > 0) {
      // 持仓结束：清理对应K线缓存
      for (const position of targets) {
        if (closedIds.includes(position.id)) clearKlineCacheSymbol(String(position.pair || '').toUpperCase())
      }
      setPositions((prev) => prev.filter((position) => !closedIds.includes(position.id)))
    }
    setClosingAll(false)
    setShowCloseAllConfirm(false)

    if (apiBindRequired) {
      setShowApiBindPrompt(true)
      return
    }

    if (successCount > 0) {
      const actualPnlText = actualPnl >= 0 ? `+${formatSmartAmount(actualPnl)}` : formatSmartAmount(actualPnl)
      const pnlSummary = hasUnknownPnl ? '部分盈亏待核对' : `合计${actualPnlText}U`
      showToast(
        failedCount > 0
          ? `已平仓${successCount}笔，${failedCount}笔失败\n${pnlSummary}`
          : `已全部平仓\n${pnlSummary}`,
      )
      void loadPositions(false, {
        suppressConnectionError: true,
        disableRetry: true,
        timeout: SILENT_REFRESH_TIMEOUT,
      })
      return
    }

    showToast(lastError || '全部平仓失败，请稍后重试')
  }, [closingAll, loadPositions, positions])

  useEffect(() => {
    const scroller = scrollRef.current
    if (!scroller) return

    const onTouchStart = (event: TouchEvent) => {
      if (isRefreshingRef.current) {
        touchStartYRef.current = null
        return
      }
      if (scroller.scrollTop > 0) {
        touchStartYRef.current = null
        return
      }
      const y = event.touches[0]?.clientY
      touchStartYRef.current = typeof y === 'number' ? y : null
    }

    const onTouchMove = (event: TouchEvent) => {
      const startY = touchStartYRef.current
      if (startY === null || isRefreshingRef.current) return
      const y = event.touches[0]?.clientY
      if (typeof y !== 'number') return
      const delta = y - startY
      if (delta <= 0) {
        setPullDistance(0)
        setIsPulling(false)
        return
      }
      const next = Math.min(110, delta * 0.9)
      if (event.cancelable) {
        event.preventDefault()
      }
      setIsPulling(true)
      setPullDistance(next)
    }

    const onTouchEnd = () => {
      touchStartYRef.current = null
      if (!isPullingRef.current || isRefreshingRef.current) return
      if (pullDistanceRef.current >= refreshThreshold) {
        refreshActiveTab()
        return
      }
      setPullDistance(0)
      setIsPulling(false)
    }

    scroller.addEventListener('touchstart', onTouchStart, { passive: true })
    scroller.addEventListener('touchmove', onTouchMove, { passive: false })
    scroller.addEventListener('touchend', onTouchEnd, { passive: true })
    scroller.addEventListener('touchcancel', onTouchEnd, { passive: true })
    return () => {
      scroller.removeEventListener('touchstart', onTouchStart)
      scroller.removeEventListener('touchmove', onTouchMove)
      scroller.removeEventListener('touchend', onTouchEnd)
      scroller.removeEventListener('touchcancel', onTouchEnd)
    }
  }, [refreshActiveTab, refreshThreshold])

  return (
    <div className="h-full flex flex-col max-w-md mx-auto overflow-hidden overscroll-none">
      {/* 顶部标题栏 - 延伸到状态栏区域 */}
      <div
        className="bg-t-surface"
        style={{ paddingTop: standalone ? 'max(44px, env(safe-area-inset-top, 0px))' : 'env(safe-area-inset-top, 0px)' }}
      >
        <div className="flex justify-between border-b border-t-border">
          {tabs.map(tab => (
            <button
              key={tab.key}
              className={`flex-1 py-2.5 transition-colors ${
                activeTab === tab.key ? 'text-[var(--t-brand)] border-b-2 border-[var(--t-brand)]' : 'text-t-text-muted'
              }`}
              onClick={() => setActiveTab(tab.key)}
            >
              {tab.label}
            </button>
          ))}
        </div>
      </div>

      {/* 可滚动内容区域 */}
      <div
        ref={scrollRef}
        className="flex-1 min-h-0 overflow-y-scroll overscroll-contain hide-scrollbar bg-t-page"
        style={{
          WebkitOverflowScrolling: 'touch',
          overscrollBehaviorY: 'contain',
          paddingBottom: contentBottomPadding,
        }}
      >
        <div
          className={`flex items-center justify-center text-sm text-t-text-muted ${isPulling ? 'transition-none' : 'transition-all duration-150'}`}
          style={{ height: `${refreshIndicatorHeight}px` }}
        >
          {(isPulling || isRefreshing) && (
            <div className="flex items-center gap-2">
              <span className={`text-xl leading-none ${isRefreshing ? 'animate-spin' : ''}`}>↻</span>
              <span>{isRefreshing ? '刷新中...' : pullDistance >= refreshThreshold ? '释放刷新' : '下拉刷新'}</span>
            </div>
          )}
        </div>
        {/* ========== Positions Tab ========== */}
        {activeTab === 'positions' && (
          <div className="p-4 space-y-2.5 min-h-full">
          {positionsLoading && positions.length === 0 ? (
            <div className="flex justify-center items-center py-12">
              <div className="text-t-text-muted">加载中...</div>
            </div>
          ) : positions.length === 0 ? (
            <div className="flex justify-center items-center py-12">
              <div className="text-t-text-muted">暂无持仓</div>
            </div>
          ) : (
            <>
              {positions.map((position, index) => {
                // K线图弹窗叠加的开仓/止损/止盈(已挂单)虚线，头部与底部按钮入口共用
                const positionPriceLines = [
                  ...(position.openPrice > 0
                    ? [{ price: position.openPrice, title: '开仓', color: 'var(--t-brand)' }]
                    : []),
                  ...((position.marketStopSet ? position.marketStopPrice : position.stopLoss) > 0
                    ? [{
                        price: position.marketStopSet ? position.marketStopPrice : position.stopLoss,
                        title: '止损',
                        color: '#F6465D',
                      }]
                    : []),
                  ...(position.manualTakeProfitSet &&
                  position.manualTakeProfitOrderType === 'limit' &&
                  position.manualTakeProfitPrice > 0
                    ? [{ price: position.manualTakeProfitPrice, title: '止盈', color: '#0ECB81' }]
                    : []),
                ]
                return (
                <div key={index} className="rounded-xl p-3.5 transition-colors bg-t-surface">
                  {/* Header */}
                  <div className="flex flex-wrap items-center gap-2 mb-3.5">
                    <div className={`w-5 h-5 rounded flex items-center justify-center text-xs font-medium text-white ${
                      position.positionType === 'long' ? 'bg-[#0ECB81]' : 'bg-[#F6465D]'
                    }`}>
                      {position.positionType === 'long' ? '多' : '空'}
                    </div>
                          <span className="font-medium text-t-text">{position.pair}</span>
                          {position.positionOrigin === 'exchange_external' && (
                            <span className="bg-[var(--t-brand)]/15 text-[var(--t-brand)] text-xs px-1.5 py-0.5 rounded">手动仓</span>
                          )}
                          <span className="text-sm text-t-text-muted">x{position.leverage}</span>
                          <span className="bg-[var(--t-brand)]/15 text-[var(--t-brand)] text-xs px-1.5 py-0.5 rounded">
                            {position.stopLossAmount > 0 ? `止损${position.stopLossAmount}U` : '止损额度未设置'}
                          </span>
                          {position.hasManualAddition && (
                            <span className="bg-[var(--t-brand)]/15 text-[var(--t-brand)] text-xs px-1.5 py-0.5 rounded">有增仓</span>
                          )}
                          {position.stopProtectionStatus === 'pending' && (
                            <span className="bg-[var(--t-brand)]/15 text-[#B67A12] text-xs px-1.5 py-0.5 rounded">止损保护重试中</span>
                          )}
                          {position.stopProtectionStatus === 'alerted' && (
                            <span className="bg-[#F6465D]/15 text-[#F6465D] text-xs px-1.5 py-0.5 rounded">止损保护持续失败</span>
                          )}
                          {position.stopProtectionStatus === 'emergency_close' && (
                            <span className="bg-[#F6465D]/20 text-[#F6465D] text-xs px-1.5 py-0.5 rounded">需立即确认仓位</span>
                          )}
                        </div>

                  <div className="space-y-2">
                    <div className="grid grid-cols-2 gap-x-4 text-sm text-t-text-muted">
                      <span>
                        开仓额度：
                        <span className="font-medium text-t-text">{formatSmartAmount(position.balance || 0)}U</span>
                      </span>
                      <span
                        className={`font-medium ${
                          position.profit > 0
                            ? 'text-[#0ECB81]'
                            : position.profit < 0
                              ? 'text-[#F6465D]'
                              : 'text-t-text-muted'
                        }`}
                      >
                        持仓盈亏：{formatPositionPnl(position.profit)}
                      </span>
                    </div>
                    <div className="grid grid-cols-2 gap-x-4 text-sm text-t-text-muted">
                      <span>
                        开仓价格：
                        <span className="font-medium text-t-text">{formatSmartAmount(position.openPrice || 0)}</span>
                      </span>
                      <span>
                        当前价格：
                        <span className="font-medium text-t-text">{formatSmartAmount(livePrices[position.pair] ?? position.currentPrice ?? 0)}</span>
                      </span>
                    </div>
                    <div className="text-sm text-t-text-muted">
                      市价止损：
                      <span className="font-medium text-t-text">
                        {stopDisplayText(position.marketStopSet, position.marketStopPrice)}
                      </span>
                      {position.marketStopSet && position.stopProfit !== 0 && (
                        <span className="text-[#F6465D]">
                          （{formatPositionPnl(position.stopProfit)}）
                        </span>
                      )}
                    </div>
                    <div className="flex items-center gap-x-2 text-sm text-t-text-muted">
                      <span>
                        市价止盈：
                        {position.manualTakeProfitSet ? (
                          <>
                            <span className="font-medium text-t-text">
                              {formatSmartAmount(position.manualTakeProfitPrice)}
                            </span>
                            <span className={position.manualTakeProfitPnl >= 0 ? 'text-[#0ECB81]' : 'text-[#F6465D]'}>
                              （{formatPositionPnl(position.manualTakeProfitPnl)}）
                            </span>
                          </>
                        ) : (
                          <span className="text-t-text-muted">未设置</span>
                        )}
                      </span>
                      <button
                        type="button"
                        onClick={() => openTakeProfitEditor(position)}
                        className="rounded-md border border-[var(--t-brand)]/35 bg-[var(--t-brand)]/10 px-2 py-0.5 text-xs font-medium text-[var(--t-brand)] transition-colors hover:bg-[var(--t-brand)]/15"
                      >
                        设置
                      </button>
                    </div>
                    <div className="text-sm text-t-text-muted">
                      手续费：
                      {position.entryFeeStatus === 'confirmed' && position.entryFee !== null ? (
                        <span className="font-medium text-[#F6465D]">
                          {formatFeeAmount(position.entryFee, position.entryFeeAsset)}
                        </span>
                      ) : (
                        <>
                          <span className="text-t-text-muted">估</span>
                          <span className="font-medium text-[#F6465D]">
                            {formatSignedUsd(-Math.abs(position.totalFee || 0) / 2)}
                          </span>
                        </>
                      )}
                      <span className="text-t-text-muted">
                        （估{formatSignedUsd(-Math.abs(position.totalFee || 0))}）
                      </span>
                    </div>
                    <div className="text-sm text-t-text-muted">
                      {position.positionOrigin === 'exchange_external' ? '接管时间' : '开仓时间'}：{formatDateTime(position.createdAt)}
                    </div>
                    {position.stopProtectionStatus === 'pending' && (
                      <div className="text-xs text-[#B67A12]">
                        {position.stopProtectionError || '止损保护正在后台重试，恢复前不可继续开仓'}
                      </div>
                    )}
                    {position.stopProtectionStatus === 'alerted' && (
                      <div className="text-xs font-medium text-[#F6465D]">
                        止损保护持续失败，请立即检查 Binance。{position.stopProtectionError || ''}
                      </div>
                    )}
                    {position.stopProtectionStatus === 'emergency_close' && (
                      <div className="text-xs font-medium text-[#F6465D]">
                        已触发紧急保护，请立即在 Binance 确认仓位状态。{position.stopProtectionError || ''}
                      </div>
                    )}
                    {position.latestStrategyError && (
                      <div className="rounded-lg bg-[var(--t-brand)]/14 px-3 py-2 text-sm text-[#B67A12]">
                        {formatAmountsInLogText(position.latestStrategyError)}
                      </div>
                    )}
                  </div>

                  {/* Actions */}
                  <div className="flex gap-2 mt-4 pt-3.5 border-t border-t-border">
                    {/* K线图短按钮：图标+K线文字，弹窗内叠加开仓/止损/止盈虚线 */}
                    <Suspense fallback={null}>
                      <KlineChartCard
                        entry="button"
                        symbol={position.pair}
                        priceLines={positionPriceLines}
                      />
                    </Suspense>
                    {position.positionOrigin !== 'exchange_external' && position.strategyType === 'none' && (
                      <button
                        onClick={() => void openStrategyPicker(position)}
                        className={`flex-1 py-2 rounded-lg text-sm font-medium transition-colors border ${
                          position.canBindStrategy
                            ? 'bg-t-btn-secondary text-t-text border-t-border hover:bg-t-btn-secondary-hover'
                            : 'bg-t-btn-secondary/50 text-t-text-muted border-t-border cursor-not-allowed'
                        }`}
                        disabled={!position.canBindStrategy}
                      >
                        {position.canBindStrategy ? '添加自动止盈' : '手动止盈'}
                      </button>
                    )}
                    {position.positionOrigin !== 'exchange_external' && position.strategyType === 'auto' && (
                      <button
                        onClick={() => {
                          setSelectedPosition(position)
                          void openStrategyExecutionDetail(position.id, position.strategy, 'running')
                        }}
                        className="flex-1 py-2 rounded-lg text-sm font-medium transition-colors bg-[#0ECB81]/10 border border-[#0ECB81]/30 text-[#0ECB81] hover:bg-[#0ECB81]/15"
                      >
                        自动止盈中
                      </button>
                    )}
                    {position.positionOrigin !== 'exchange_external' && position.strategyType === 'manual-cancelled' && (
                      <button
                        onClick={() => void openStrategyPicker(position)}
                        className={`flex-1 py-2 rounded-lg text-sm font-medium transition-colors border ${
                          position.canBindStrategy
                            ? 'bg-t-btn-secondary text-t-text border-t-border hover:bg-t-btn-secondary-hover'
                            : 'bg-t-btn-secondary/50 text-t-text-muted border-t-border cursor-not-allowed'
                        }`}
                        disabled={!position.canBindStrategy}
                      >
                        {position.canBindStrategy ? '添加自动止盈' : '手动止盈'}
                      </button>
                    )}
                    {position.positionOrigin !== 'exchange_external' && (
                      <button
                        type="button"
                        onClick={() => openBreakEvenEditor(position)}
                        title={Number(position.profit || 0) > 0 ? '设置保本损' : '浮亏时将挂收益为 0 的保本止盈单'}
                        className="flex-1 py-2 rounded-lg text-sm font-medium transition-colors border border-[#0ECB81]/30 bg-[#0ECB81]/10 text-[#0ECB81] hover:bg-[#0ECB81]/15"
                      >
                        设置保本损
                      </button>
                    )}
                    <button
                      onClick={() => { setSelectedPosition(position); setShowCloseConfirm(true) }}
                      className="flex-1 bg-[var(--t-brand)] hover:bg-[var(--t-brand-hover)] text-black py-2 rounded-lg text-sm font-medium transition-colors"
                    >
                      立即平仓
                    </button>
                  </div>
                </div>
                )
              })}
              {positions.length > 1 && (
                <div className="flex gap-2.5">
                  <button
                    type="button"
                    onClick={() => setSkipCloseAllConfirm((value) => !value)}
                    disabled={closingAll}
                    aria-pressed={skipCloseAllConfirm}
                    className={`shrink-0 w-[106px] flex items-center justify-center gap-1.5 rounded-lg border py-3 text-sm font-medium transition-colors disabled:opacity-60 ${
                      skipCloseAllConfirm
                        ? 'border-[var(--t-brand)] bg-[var(--t-brand)]/12 text-[var(--t-brand)]'
                        : 'border-t-border bg-t-btn-secondary text-t-text-muted hover:bg-t-btn-secondary-hover'
                    }`}
                  >
                    <span
                      className={`flex h-4 w-4 items-center justify-center rounded border text-[11px] leading-none ${
                        skipCloseAllConfirm
                          ? 'border-[var(--t-brand)] bg-[var(--t-brand)] text-black'
                          : 'border-t-text-muted'
                      }`}
                    >
                      {skipCloseAllConfirm ? '✓' : ''}
                    </span>
                    <span>无需确认</span>
                  </button>
                  <button
                    onClick={() => {
                      if (skipCloseAllConfirm) {
                        void closeAllPositions()
                        return
                      }
                      setShowCloseAllConfirm(true)
                    }}
                    disabled={closingAll}
                    className={`w-full ${closeAllButtonClass} text-white py-3 rounded-lg transition-colors font-medium active:scale-[0.98] disabled:opacity-60`}
                  >
                    {closingAll ? '平仓中...' : `全部平仓(${totalPositionsPnlText})`}
                  </button>
                </div>
              )}
            </>
          )}
        </div>
      )}

      {/* ========== Limit Orders Tab ========== */}
      {activeTab === 'limit-orders' && (
        <div className="p-4 space-y-2.5 min-h-full">
          {limitOrdersLoading && limitOrders.length === 0 ? (
            <div className="flex justify-center items-center py-12">
              <div className="text-t-text-muted">加载中...</div>
            </div>
          ) : limitOrders.length === 0 ? (
            <div className="flex justify-center items-center py-12">
              <div className="text-t-text-muted">暂无限价委托</div>
            </div>
          ) : limitOrders.map((order) => (
            <div key={order.id} className="rounded-xl p-3.5 transition-colors bg-t-surface">
              <div className="flex items-center justify-between mb-3.5">
                <div className="flex items-center gap-2">
                  <div className={`w-5 h-5 rounded flex items-center justify-center text-xs font-medium text-white ${
                    order.side === 0 ? 'bg-[#0ECB81]' : 'bg-[#F6465D]'
                  }`}>
                    {order.side === 0 ? '多' : '空'}
                  </div>
                  <span className="font-medium text-t-text">{order.symbol}</span>
                  <span className="bg-[var(--t-brand)]/15 text-[var(--t-brand)] text-xs px-1.5 py-0.5 rounded">止损{order.stop_loss_amount}U</span>
                </div>
                <span className={`text-xs px-1.5 py-0.5 rounded ${
                  order.status === 0 ? 'bg-[var(--t-brand)]/20 text-[var(--t-brand)]' :
                  order.status === 1 ? 'bg-[#0ECB81]/20 text-[#0ECB81]' :
                  'bg-t-text-muted/20 text-t-text-muted'
                }`}>{order.status_text}</span>
              </div>

              <div className="grid grid-cols-2 gap-x-5 gap-y-3 mb-4">
                <DetailItem label="限价" value={formatSmartAmount(order.limit_price)} bold />
                <DetailItem label="止损价" value={formatSmartAmount(order.stop_loss_price)} bold />
                <DetailItem label="委托仓位" value={`${formatSmartAmount(order.position_amount)}U`} />
                <DetailItem label="已成交" value={`${formatSmartAmount(order.filled_amount)}/${formatSmartAmount(order.position_amount)}U`} />
              </div>

              {order.status === 0 && (
                <div className="flex gap-2 pt-3.5 border-t border-t-border">
                  <button
                    onClick={() => { setSelectedLimitOrder(order); setShowChaseConfirm(true) }}
                    disabled={!order.can_chase}
                    className={`flex-1 py-2 rounded-lg text-sm font-medium transition-colors ${
                      order.can_chase
                        ? 'bg-t-btn-secondary text-t-text border border-t-border hover:bg-t-btn-secondary-hover'
                        : 'bg-t-btn-secondary/50 text-t-text-muted border border-t-border cursor-not-allowed'
                    }`}
                  >
                    {order.can_chase ? '追单' : '已部分成交'}
                  </button>
                  <button
                    onClick={() => { setSelectedLimitOrder(order); setShowCancelOrderConfirm(true) }}
                    className="flex-1 bg-[var(--t-brand)] hover:bg-[var(--t-brand-hover)] text-black py-2 rounded-lg text-sm font-medium transition-colors"
                  >
                    撤单
                  </button>
                </div>
              )}
            </div>
          ))}
        </div>
      )}

      {/* ========== History Tab ========== */}
        {activeTab === 'history' && (
        <>
          {/* Filter Buttons */}
          <div className="flex gap-2 px-4 py-2.5">
            {historyFilters.map(f => (
              <button
                key={f.key}
                onClick={() => setHistoryFilter(f.key)}
                className={`flex-1 py-1.5 rounded-lg text-sm font-medium transition-colors ${
                  historyFilter === f.key
                    ? 'bg-[var(--t-brand)] text-black'
                    : 'bg-t-btn-secondary text-t-text-secondary hover:bg-t-btn-secondary-hover'
                }`}
              >
                {f.label}
              </button>
            ))}
          </div>

          <div className="px-4 space-y-2.5">
          {historyLoading && historyPositions.length === 0 ? (
            <div className="flex justify-center items-center py-12">
              <div className="text-t-text-muted">加载中...</div>
            </div>
            ) : historyPositions.length === 0 ? (
              <div className="flex justify-center items-center py-12">
                <div className="text-t-text-muted">暂无历史仓位记录</div>
              </div>
            ) : historyPositions.map((position, idx) => {
              const isExternal = position.position_origin === 'exchange_external'
              const totalPnl = isExternal && position.pnl == null ? null : Number(position.pnl || 0)
              const totalIsProfit = totalPnl !== null && totalPnl >= 0
              const floatingPnl = position.floating_pnl === null || position.floating_pnl === undefined
                ? null
                : Number(position.floating_pnl || 0)
              const stopLossAmount = Number(position.stop_loss_amount || 0)
              const rrValue = totalPnl !== null && stopLossAmount > 0 ? totalPnl / stopLossAmount : null
              const tradingFee = Number(position.fee || 0)
              const fundingFee = Number(position.funding_fee || 0)
              const mergedFee = isExternal && (position.fee == null || position.funding_fee == null)
                ? null
                : tradingFee + fundingFee
              const closePrice = isExternal && position.close_price == null ? null : Number(position.close_price || 0)
              const rrDisplay = rrValue === null ? '--' : `${rrValue.toFixed(1)}:1`
              const formatTime = (iso: string) => {
                if (!iso) return '--'
                const d = new Date(iso)
                return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')} ${String(d.getHours()).padStart(2,'0')}:${String(d.getMinutes()).padStart(2,'0')}:${String(d.getSeconds()).padStart(2,'0')}`
              }
              return (
                <div key={position.id ?? `pos-${idx}`} className="rounded-xl p-3.5 transition-colors bg-t-surface">
                  <div className="flex items-center justify-between gap-3 mb-3">
                    <div className="flex flex-wrap items-center gap-2">
                      <div className={`w-5 h-5 rounded flex items-center justify-center text-xs font-medium text-white ${
                        position.side === 0 ? 'bg-[#0ECB81]' : 'bg-[#F6465D]'
                      }`}>
                        {position.side === 0 ? '多' : '空'}
                      </div>
                      <span className="font-medium text-t-text">{position.symbol}</span>
                      {position.position_origin === 'exchange_external' && (
                        <span className="bg-[var(--t-brand)]/15 text-[var(--t-brand)] text-xs px-1.5 py-0.5 rounded">手动仓</span>
                      )}
                      {position.stop_loss_amount && position.stop_loss_amount !== '--' && (
                        <span className="bg-[var(--t-brand)]/15 text-[var(--t-brand)] text-xs px-1.5 py-0.5 rounded">止损{position.stop_loss_amount}U</span>
                      )}
                      {position.settlement_status === 'estimated' && (
                        <span
                          className="bg-[var(--t-brand)]/15 text-[var(--t-brand)] text-xs px-1.5 py-0.5 rounded"
                          title={position.settlement_note || '部分结算数据为估算值'}
                        >
                          估算
                        </span>
                      )}
                    </div>
                    {floatingPnl !== null && (
                      <div className={`shrink-0 text-xs font-medium ${floatingPnl >= 0 ? 'text-[#0ECB81]' : 'text-[#F6465D]'}`}>
                        浮动：{floatingPnl >= 0 ? '+' : ''}{formatSmartAmount(floatingPnl)}U
                      </div>
                    )}
                  </div>

                  <div className="grid grid-cols-3 gap-x-2.5 gap-y-3 mb-3">
                    <DetailItem
                      label="平仓盈亏"
                      value={totalPnl === null ? '--' : `${totalIsProfit ? '+' : ''}${formatSmartAmount(totalPnl)}U`}
                      valueClass={totalPnl === null ? '' : totalIsProfit ? 'text-[#0ECB81]' : 'text-[#F6465D]'}
                      bold
                    />
                    <DetailItem
                      label="盈亏比"
                      value={rrDisplay}
                      valueClass={rrValue === null ? '' : (rrValue >= 0 ? 'text-[#0ECB81]' : 'text-[#F6465D]')}
                    />
                    <DetailItem label="开仓价格" value={formatSmartAmount(Number(position.open_price || 0))} />
                    <DetailItem label="平仓价格" value={closePrice === null ? '--' : formatSmartAmount(closePrice)} />
                    <DetailItem label="持仓额" value={`${formatSmartAmount(Number(position.position_amount || 0))}U`} />
                    <DetailItem
                      label="手续费"
                      value={mergedFee === null ? '--' : `${formatSmartAmount(mergedFee)}U`}
                      valueClass={mergedFee === null ? '' : mergedFee <= 0 ? 'text-[#F6465D]' : 'text-[#0ECB81]'}
                    />
                  </div>

                  <div className="py-2.5 border-t border-t-border flex items-end justify-between gap-3">
                    <div className="space-y-1">
                      <div className="text-t-text-muted text-sm">{position.position_origin === 'exchange_external' ? '接管时间' : '开仓时间'}  {formatTime(position.created_at)}</div>
                      <div className="text-t-text-muted text-sm">平仓时间  {formatTime(position.closed_at)}</div>
                    </div>
                    {position.id && position.has_strategy_logs && (
                      <button
                        onClick={() => void openStrategyExecutionDetail(position.id, null, 'history')}
                        className="p-1 rounded-md transition-colors hover:bg-t-surface-hover"
                        title="查看止盈止损记录"
                      >
                        <img src={historyLogIcon} alt="日志" className="w-5 h-5" />
                      </button>
                    )}
                  </div>
                </div>
              )
            })}

            {historyPagination.has_next && (
              <div ref={historyLoadMoreRef} className="flex justify-center py-3 text-sm text-t-text-muted">
                {historyLoading ? '加载中...' : ''}
              </div>
            )}
          </div>
        </>
      )}
      </div>

      {/* ========== Modals ========== */}

      <ConfirmModal isOpen={showCloseConfirm} onClose={() => setShowCloseConfirm(false)}
        onConfirm={async () => {
          if (closingPosition) return
          if (!selectedPosition?.id) {
            setShowCloseConfirm(false)
            return
          }
          setClosingPosition(true)
          try {
            const result = await api.post<PositionCloseResult>('/position/close', { position_id: selectedPosition.id })
            setShowCloseConfirm(false)
            setPositions((prev) => prev.filter((p) => p.id !== selectedPosition.id))
            // 持仓结束：清理对应K线缓存
            clearKlineCacheSymbol(String(selectedPosition.pair || '').toUpperCase())
            const pnl = confirmedClosePnl(result)
            if (pnl === null) {
              showToast('已平仓，盈亏待核对')
            } else {
              const pnlText = pnl >= 0 ? `+${formatSmartAmount(pnl)}` : formatSmartAmount(pnl)
              showToast(`已平仓\n${pnl >= 0 ? '盈利' : '亏损'}${pnlText}U`)
            }
          } catch (error) {
            if (isApiBindRequiredError(error)) {
              setShowApiBindPrompt(true)
              return
            }
            const message = error instanceof ApiError ? error.message : '平仓失败，请稍后重试'
            showToast(message)
          } finally {
            setClosingPosition(false)
          }
        }} title="立即平仓" confirmText={closingPosition ? '平仓中...' : '确认'} busy={closingPosition}>
        {selectedPosition && (
          <div className="mb-2 font-medium text-t-text">
            {selectedPosition.pair} · {selectedPosition.positionType === 'long' ? '多单' : '空单'}{selectedPosition.positionOrigin === 'exchange_external' ? ' · 手动仓' : ''}
          </div>
        )}
        预估收益
        <span className={`${(selectedPosition?.profit || 0) >= 0 ? 'text-[#0ECB81]' : 'text-[#F6465D]'} font-medium`}>
          {selectedPosition ? `${formatSmartAmount(selectedPosition.profit)} USDT` : '--'}
        </span>
        ，确认平仓？
      </ConfirmModal>

      <ConfirmModal
        isOpen={showCloseAllConfirm}
        onClose={() => {
          if (!closingAll) setShowCloseAllConfirm(false)
        }}
        onConfirm={() => void closeAllPositions()}
        title="全部平仓"
        confirmText={closingAll ? '平仓中...' : '确认'}
        confirmVariant="danger"
      >
        当前共 {positions.length} 笔持仓，预估总盈亏
        <span className={`${totalPositionsPnl >= 0 ? 'text-[#0ECB81]' : 'text-[#F6465D]'} font-medium`}>
          {` ${totalPositionsPnlText} USDT`}
        </span>
        ，确认全部平仓？
      </ConfirmModal>

      <ConfirmModal isOpen={showChaseConfirm} onClose={() => setShowChaseConfirm(false)}
        onConfirm={async () => {
          if (!selectedLimitOrder?.id || chaseSubmitting) {
            setShowChaseConfirm(false)
            return
          }
          setChaseSubmitting(true)
          try {
            if (!await ensureManualEntryCapitalReady('chase')) {
              setShowChaseConfirm(false)
              return
            }
            await api.post('/trade/limit-order/chase', { limit_order_id: selectedLimitOrder.id })
            setShowChaseConfirm(false)
            // 刷新限价委托列表
            const data = await api.get<LimitOrderData[]>('/trade/limit-order/list')
            setLimitOrders(data)
            showToast('追单成功，已转为市价开仓')
          } catch (error) {
            if (isApiBindRequiredError(error)) {
              setShowApiBindPrompt(true)
              return
            }
            const message = error instanceof ApiError ? error.message : '追单失败，请稍后重试'
            showToast(message)
          } finally {
            setChaseSubmitting(false)
          }
        }} title="市价追单" confirmText={chaseSubmitting ? '检查中...' : '确认'}>
        确认撤销当前限价委托并以市价开仓？
      </ConfirmModal>

      <ConfirmModal isOpen={showCancelOrderConfirm} onClose={() => setShowCancelOrderConfirm(false)}
        onConfirm={async () => {
          if (!selectedLimitOrder?.id) {
            setShowCancelOrderConfirm(false)
            return
          }
          try {
            await api.post('/trade/limit-order/cancel', { limit_order_id: selectedLimitOrder.id })
            setShowCancelOrderConfirm(false)
            // 刷新限价委托列表
            const data = await api.get<LimitOrderData[]>('/trade/limit-order/list')
            setLimitOrders(data)
          } catch (error) {
            if (isApiBindRequiredError(error)) {
              setShowApiBindPrompt(true)
              return
            }
            const message = error instanceof ApiError ? error.message : '撤单失败，请稍后重试'
            showToast(message)
          }
        }} title="撤销委托" confirmText="确认">
        确认撤销该限价委托单？
      </ConfirmModal>

      <ConfirmModal isOpen={showCancelStrategyConfirm} onClose={() => setShowCancelStrategyConfirm(false)}
        onConfirm={async () => {
          if (!selectedPosition?.id) {
            setShowCancelStrategyConfirm(false)
            return
          }
          try {
            await api.post('/strategy/cancel', { position_id: selectedPosition.id })
            setPositions((prev) => prev.map((p) => {
              if (p.id !== selectedPosition.id) return p
              return {
                ...p,
                strategyType: 'manual-cancelled' as const,
                strategy: null,
                direction: '强制止损/手动止盈',
              }
            }))
            setShowCancelStrategyConfirm(false)
            showToast('已取消自动止盈，改为手动止盈')
          } catch (error) {
            if (isApiBindRequiredError(error)) {
              setShowApiBindPrompt(true)
              return
            }
            const message = error instanceof ApiError ? error.message : '取消策略失败，请稍后重试'
            showToast(message)
          }
        }}
        title="取消止盈策略" confirmText="确认" confirmVariant="danger">
        取消止盈策略后，仍将保留止损订单。若当前仓位仍与开仓仓位一致，后续仍可重新添加自动止盈策略。确认取消吗？
      </ConfirmModal>

      <ConfirmModal isOpen={showManualProfitInfo} onClose={() => setShowManualProfitInfo(false)}
        onConfirm={() => setShowManualProfitInfo(false)} title="手动止盈" confirmText="知道了" showCancel={false}>
        该笔订单需手动止盈
      </ConfirmModal>

      {showBreakEvenModal && selectedPosition && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div
            className="absolute inset-0 bg-black/60 backdrop-blur-sm"
            onClick={() => !breakEvenSubmitting && setShowBreakEvenModal(false)}
          />
          <div className="relative w-full max-w-sm rounded-2xl bg-t-modal p-5 shadow-2xl">
            <button
              onClick={() => setShowBreakEvenModal(false)}
              disabled={breakEvenSubmitting}
              className="absolute right-4 top-4 flex h-8 w-8 items-center justify-center rounded-full text-t-text-muted transition-colors hover:bg-t-surface-hover"
            >
              ×
            </button>
            <div className="mb-5">
              <div className="text-lg font-bold text-t-text">设置保本损</div>
              <div className="mt-1 text-sm text-t-text-muted">
                {selectedPosition.pair} · {selectedPosition.positionType === 'long' ? '多单' : '空单'}
                {!selectedBreakEvenInProfit && ' · 浮亏时将挂保本止盈单'}
              </div>
            </div>

            <div className="mb-4 rounded-xl border border-t-border bg-t-surface px-4 py-3">
              <div className="flex items-center justify-between text-sm">
                <span className="text-t-text-muted">当前浮盈</span>
                <span className={`font-medium ${selectedBreakEvenProfit >= 0 ? 'text-[#0ECB81]' : 'text-[#F6465D]'}`}>
                  {formatSmartAmount(selectedBreakEvenProfit)} USDT
                </span>
              </div>
              <div className="mt-2 flex items-center justify-between text-sm">
                <span className="text-t-text-muted">预估总手续费</span>
                <span className="font-medium text-[#F6465D]">
                  -{formatSmartAmount(selectedBreakEvenFeeLoss)} USDT
                </span>
              </div>
            </div>

            <div className="flex flex-col gap-3">
              <button
                type="button"
                onClick={() => void submitBreakEvenStop('with_fee')}
                disabled={breakEvenSubmitting || !canSubmitBreakEvenWithFee}
                title={canSubmitBreakEvenWithFee ? '净盈亏为 0 的保本' : '当前浮盈不足以覆盖总手续费'}
                className={`w-full rounded-xl py-3 font-semibold transition-colors active:scale-[0.98] ${
                  canSubmitBreakEvenWithFee
                    ? 'bg-gradient-to-r from-[var(--t-brand)] to-[var(--t-brand-hover)] text-black hover:shadow-lg hover:shadow-[var(--t-brand)]/30'
                    : 'bg-t-btn-secondary/50 text-t-text-muted cursor-not-allowed'
                }`}
              >
                <div className="text-sm font-semibold">含手续费保本（净盈亏 0）</div>
                <div className="mt-0.5 text-xs font-normal opacity-80">
                  {selectedBreakEvenInProfit
                    ? '止损移至开仓价 ± 手续费对应价位'
                    : '挂止盈单至开仓价 ± 手续费价位，回价自动平仓'}
                </div>
              </button>

              <button
                type="button"
                onClick={() => void submitBreakEvenStop('without_fee')}
                disabled={breakEvenSubmitting}
                title={selectedBreakEvenInProfit ? '止损到开仓价，净亏损约等于手续费' : '挂止盈单至开仓价，回价自动平仓，净亏损约等于手续费'}
                className="w-full rounded-xl py-3 font-semibold transition-colors active:scale-[0.98] border border-[#0ECB81]/30 bg-[#0ECB81]/10 text-[#0ECB81] hover:bg-[#0ECB81]/15"
              >
                <div className="text-sm font-semibold">
                  不含手续费保本（净盈亏 -{formatSmartAmount(selectedBreakEvenFeeLoss)}）
                </div>
                <div className="mt-0.5 text-xs font-normal opacity-80">
                  {selectedBreakEvenInProfit
                    ? '止损移至开仓价，亏损约等于手续费'
                    : '挂止盈单至开仓价，回到开仓价自动平仓，亏损约等于手续费'}
                </div>
              </button>
            </div>
          </div>
        </div>
      )}

      {showTakeProfitModal && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div className="absolute inset-0 bg-black/60 backdrop-blur-sm" onClick={() => !takeProfitSubmitting && setShowTakeProfitModal(false)} />
          <div className="relative w-full max-w-sm rounded-2xl bg-t-modal p-5 shadow-2xl">
            <button
              onClick={() => setShowTakeProfitModal(false)}
              disabled={takeProfitSubmitting}
              className="absolute right-4 top-4 flex h-8 w-8 items-center justify-center rounded-full text-t-text-muted transition-colors hover:bg-t-surface-hover"
            >
              ×
            </button>
            <div className="mb-4">
              <div className="text-lg font-bold text-t-text">设置止盈</div>
              <div className="mt-1 text-sm text-t-text-muted">
                {selectedPosition?.pair} · {selectedPosition?.positionType === 'long' ? '多单' : '空单'}
              </div>
            </div>

            <div className="space-y-4">
              <label className="block">
                <div className="mb-2 text-sm font-medium text-t-text-secondary">止盈价格</div>
                <div className="flex items-center gap-2">
                  <input
                    value={takeProfitPriceInput}
                    onChange={(event) => setTakeProfitPriceInput(event.target.value)}
                    inputMode="decimal"
                    placeholder="请输入止盈价格"
                    className="min-w-0 flex-1 rounded-xl bg-t-surface-input px-4 py-3 text-t-text outline-none transition focus:ring-2 focus:ring-[var(--t-brand)]"
                  />
                  <div className="flex shrink-0 rounded-full border border-t-border bg-t-btn-secondary/70 p-0.5">
                    {[
                      { label: '市价', isLimit: false },
                      { label: '限价', isLimit: true },
                    ].map((item) => {
                      const selected = takeProfitIsLimit === item.isLimit
                      return (
                        <button
                          key={item.label}
                          type="button"
                          onClick={() => setTakeProfitIsLimit(item.isLimit)}
                          className={`rounded-full px-3 py-2 text-xs font-semibold transition-all ${
                            selected
                              ? 'bg-[var(--t-brand)] text-black shadow-sm shadow-[var(--t-brand)]/25'
                              : 'text-t-text-muted hover:text-t-text'
                          }`}
                        >
                          {item.label}
                        </button>
                      )
                    })}
                  </div>
                </div>
              </label>

              {selectedPosition?.manualTakeProfitSet && (
                <div className="flex items-center justify-between rounded-xl border border-[#0ECB81]/20 bg-[#0ECB81]/8 px-4 py-3">
                  <div className="text-sm font-medium text-t-text">
                    止盈：
                    <span className="text-[#0ECB81]">
                      {formatSmartAmount(selectedPosition.manualTakeProfitPrice)}
                      [{takeProfitOrderTypeText(selectedPosition.manualTakeProfitOrderType)}]
                      {formatPositionPnl(selectedPosition.manualTakeProfitPnl)}
                    </span>
                  </div>
                  <button
                    type="button"
                    onClick={() => void cancelManualTakeProfit()}
                    disabled={takeProfitSubmitting}
                    className="rounded-lg bg-[#F6465D]/12 px-3 py-1.5 text-xs font-medium text-[#F6465D] transition-colors hover:bg-[#F6465D]/18 disabled:opacity-60"
                  >
                    取消
                  </button>
                </div>
              )}
            </div>

            <button
              type="button"
              onClick={() => void submitManualTakeProfit()}
              disabled={takeProfitSubmitting}
              className="mt-5 w-full rounded-xl bg-[var(--t-brand)] py-3 font-semibold text-black transition-colors hover:bg-[var(--t-brand-hover)] disabled:opacity-60"
            >
              {takeProfitSubmitting ? '处理中...' : '确认设置'}
            </button>
          </div>
        </div>
      )}

      {showApiBindPrompt && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div className="absolute inset-0 bg-black/60 backdrop-blur-sm" onClick={() => setShowApiBindPrompt(false)} />
          <div className="relative max-w-sm w-full rounded-2xl p-6 shadow-2xl bg-t-modal">
            <button
              onClick={() => setShowApiBindPrompt(false)}
              className="absolute top-4 right-4 w-8 h-8 flex items-center justify-center rounded-full transition-colors text-t-text-muted hover:bg-t-surface-hover"
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <line x1="18" y1="6" x2="6" y2="18" /><line x1="6" y1="6" x2="18" y2="18" />
              </svg>
            </button>
            <div className="flex justify-center mb-4">
              <div className="w-14 h-14 rounded-full bg-[var(--t-brand)]/10 flex items-center justify-center">
                <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="var(--t-brand)" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z" />
                  <line x1="12" y1="9" x2="12" y2="13" />
                  <line x1="12" y1="17" x2="12.01" y2="17" />
                </svg>
              </div>
            </div>
            <h3 className="text-lg font-bold text-center mb-2 text-t-text">请先绑定API</h3>
            <p className="text-sm text-center mb-6 leading-relaxed text-t-text-secondary">
              使用持仓功能前需要绑定交易所API，请先前往绑定。
            </p>
            <button
              onClick={() => { setShowApiBindPrompt(false); setShowApiBindModal(true) }}
              className="w-full py-3 rounded-xl font-medium bg-gradient-to-r from-[var(--t-brand)] to-[var(--t-brand-hover)] text-black hover:shadow-lg hover:shadow-[var(--t-brand)]/30 transition-all active:scale-[0.98]"
            >
              立即绑定
            </button>
          </div>
        </div>
      )}

      <ApiBindModal
        isOpen={showApiBindModal}
        onClose={() => setShowApiBindModal(false)}
      />

      <TakeProfitStopLossModal
        isOpen={showStrategyPicker}
        onClose={() => setShowStrategyPicker(false)}
        strategies={availableStrategies}
        autoOnly
        currentStrategyType="auto"
        currentStrategyId={selectedPosition?.strategyId}
        onManageStrategies={() => window.location.assign('/strategy-management')}
        getTriggeredLevelIndexes={getTriggeredLevelIndexes}
        onConfirm={async (_strategyType, selectedStrategyId) => {
          if (!selectedPosition?.id || !selectedStrategyId) {
            showToast('请先选择止盈策略')
            return
          }
          try {
            await api.post('/strategy/rebind', {
              position_id: selectedPosition.id,
              strategy_id: Number(selectedStrategyId),
            })
            const matchedStrategy = availableStrategies.find((item) => item.id === selectedStrategyId) || null
            setPositions((prev) => prev.map((p) => {
              if (p.id !== selectedPosition.id) return p
              return {
                ...p,
                strategyType: 'auto' as const,
                strategyId: selectedStrategyId,
                strategy: matchedStrategy,
              }
            }))
            setShowStrategyPicker(false)
            showToast('已添加自动止盈策略')
          } catch (error) {
            const message = error instanceof ApiError ? error.message : '添加止盈策略失败，请稍后重试'
            showToast(message)
          }
        }}
      />

      {showStrategyDetail && selectedStrategyForDetail && (
        <StrategyDetailModal
          isOpen={showStrategyDetail}
          onClose={() => setShowStrategyDetail(false)}
          strategy={selectedStrategyForDetail}
          logs={selectedStrategyLogLines}
          logsLoading={selectedStrategyLogLoading}
          showCancelAction={false}
          hideFooterActions
        />
      )}

      {showIndicatorDetail && selectedIndicatorName && (
        <IndicatorDetailModal
          isOpen={showIndicatorDetail}
          onClose={() => { setShowIndicatorDetail(false); setSelectedIndicatorName(null) }}
          indicatorName={selectedIndicatorName}
        />
      )}
    </div>
  )
}

// ============ Shared Sub-components ============

function DetailItem({ label, value, valueClass, bold, small }: {
  label: string
  value: string | number
  valueClass?: string
  bold?: boolean
  small?: boolean
}) {
  return (
    <div>
      <div className="text-t-text-muted text-sm mb-1">{label}</div>
      <div className={`${small ? 'text-sm' : 'text-base'} ${bold ? 'font-medium' : ''} ${valueClass || 'text-t-text'}`}>
        {value}
      </div>
    </div>
  )
}
