import { useState, useEffect, useLayoutEffect, useCallback, useRef, lazy, Suspense } from 'react'
import { CandlestickChart, ChevronDown } from 'lucide-react'
import { useNavigate } from 'react-router-dom'
import { TradingPairSelector } from './TradingPairSelector'
import { OpenPositionConfirmModal } from '@/components/modals'
import { StopLossSettingsModal } from '@/components/modals/StopLossSettingsModal'
import { ApiBindModal } from '@/components/modals/ApiBindModal'
import emaCheckFailIcon from '@/assets/ema-check-fail.svg'
import emaCheckPassIcon from '@/assets/ema-check-pass.svg'
import { CURATED_TRADING_SYMBOLS } from '@/shared/constants'
import { useAuthStore, useTradingStore, showToast } from '@/shared/store'
import type { StrategyLevel } from '@/shared/types'
import { api, ApiError, isApiBindRequiredError, tokenManager } from '@/shared/lib/api'
import { isStandaloneMode, requestAppLayoutSync } from '@/shared/lib/device'
import { ensureManualEntryCapitalReady } from '@/shared/lib/manualEntryCapital'
import { getTradingMode } from '@/shared/lib/tradingMode'
import { formatChartPrice } from '@/shared/lib/chartPrice'
import {
  getAccountSessionRevision,
  isCurrentAccountRequestScope,
  parseOptionalBalance,
  scopedAccountCacheKey,
  shouldThrottleAccountRequest,
} from '@/shared/lib/accountBalanceState'
import {
  EMPTY_TRADE_REQUEST_IDENTITY,
  resolveTradeRequestIdentity,
} from '@/shared/lib/tradeRequestIdentity'

const KlineChartCard = lazy(() =>
  import('./KlineChartCard').then(mod => ({ default: mod.KlineChartCard })),
)

interface AccountInfoData {
  email_masked: string
  balance: string
  total_balance?: string
  today_pnl: string
  stop_loss_amount: string
}

interface SymbolInfoData {
  symbol: string
  current_price: string
  max_leverage: number
}

interface EmaCheckItem {
  interval: string
  label: string
  supported: boolean
  matches_direction: boolean
  relation: string
  ema21: string
  ema55: string
  ema144: string
}

interface EmaCheckResult {
  check_id: string
  symbol: string
  side: 'long' | 'short'
  stop_loss_price: string
  current_price: string
  created_at: string
  expires_at: string
  ttl_seconds: number
  has_supported_interval: boolean
  has_any_supported_interval: boolean
  has_matching_interval: boolean
  has_any_matching_interval: boolean
  items: EmaCheckItem[]
}

const TRADING_SYMBOLS_CACHE_KEY = 'tradetools:trading:symbols:v3'
const TRADING_ACCOUNT_CACHE_KEY_PREFIX = 'tradetools:trading:account:v2'
const SILENT_REFRESH_TIMEOUT = 8000
const QUOTE_POLL_INTERVAL_MS = 3000

interface CachedTradingAccount {
  balance: number
  stopLossAmount: number
}

function loadCachedSymbols(): string[] {
  if (getTradingMode() === 'lead') return []
  try {
    const raw = window.localStorage.getItem(TRADING_SYMBOLS_CACHE_KEY)
    if (!raw) return []
    const parsed = JSON.parse(raw)
    return Array.isArray(parsed) ? parsed.filter(item => typeof item === 'string') : []
  } catch {
    return []
  }
}

function saveCachedSymbols(symbols: string[]) {
  if (getTradingMode() === 'lead') return
  try {
    window.localStorage.setItem(TRADING_SYMBOLS_CACHE_KEY, JSON.stringify(symbols))
  } catch {
    // ignore
  }
}

function loadCachedTradingAccount(userId: string): CachedTradingAccount | null {
  try {
    const cacheKey = scopedAccountCacheKey(TRADING_ACCOUNT_CACHE_KEY_PREFIX, userId)
    if (!cacheKey) return null
    const raw = window.localStorage.getItem(cacheKey)
    if (!raw) return null
    const parsed = JSON.parse(raw) as Partial<CachedTradingAccount>
    if (typeof parsed.balance !== 'number' || typeof parsed.stopLossAmount !== 'number') return null
    return {
      balance: parsed.balance,
      stopLossAmount: parsed.stopLossAmount,
    }
  } catch {
    return null
  }
}

function saveCachedTradingAccount(userId: string, data: CachedTradingAccount) {
  try {
    const cacheKey = scopedAccountCacheKey(TRADING_ACCOUNT_CACHE_KEY_PREFIX, userId)
    if (cacheKey) window.localStorage.setItem(cacheKey, JSON.stringify(data))
  } catch {
    // ignore
  }
}

interface CurrentQuote {
  symbol: string
  price: number
}

interface TradingSubmitErrorInfo {
  message: string
  code: string
  detail: string
}

function cleanErrorDetail(error: unknown): string {
  const raw =
    error instanceof Error
      ? error.message
      : typeof error === 'string'
        ? error
        : Object.prototype.toString.call(error)
  return String(raw || '未知错误')
    .replace(/api[-_ ]?key[=:： ]?[^,\s，。]*/gi, 'api_key=***')
    .replace(/secret[=:： ]?[^,\s，。]*/gi, 'secret=***')
    .slice(0, 120)
}

function formatTradingSubmitError(error: unknown): TradingSubmitErrorInfo {
  if (error instanceof ApiError) {
    if (error.code === -1) {
      return {
        code: '开仓-N001',
        detail: '请求超时',
        message: '开仓请求超时，请检查网络后重试（开仓-N001）',
      }
    }
    if (error.code === -2) {
      return {
        code: '开仓-N002',
        detail: '网络连接失败',
        message: '开仓请求未连上服务器，请检查网络后重试（开仓-N002）',
      }
    }
    const code = `开仓-B${error.code}`
    return {
      code,
      detail: error.message,
      message: `${error.message}（${code}）`,
    }
  }

  const detail = cleanErrorDetail(error)
  return {
    code: '开仓-F001',
    detail,
    message: `前端开仓异常，请刷新后重试（开仓-F001：${detail}）`,
  }
}

function reportTradingSubmitError(info: TradingSubmitErrorInfo, context: Record<string, unknown>) {
  const token = tokenManager.get()
  if (!token) return
  const payload = {
    reason: `trade-submit-error:${info.code}`,
    path: window.location.pathname,
    standalone: isStandaloneMode(),
    user_agent: navigator.userAgent,
    metrics: {
      code: info.code,
      detail: info.detail,
      ...context,
    },
  }
  void fetch('/api/account/client-layout-log', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify(payload),
    keepalive: true,
  }).catch(() => {
    // 诊断日志不影响交易流程
  })
}

export function TradingPage() {
  const authUserId = useAuthStore(s => s.user?.id ?? '')
  const standalone = isStandaloneMode()
  const navigate = useNavigate()
  const stopLossAmount = useTradingStore(s => s.stopLossAmount)
  const setStopLossAmount = useTradingStore(s => s.setStopLossAmount)
  const activeStrategy = useTradingStore(s => s.getActiveStrategy)
  const replaceStrategies = useTradingStore(s => s.replaceStrategies)
  const setActiveStrategy = useTradingStore(s => s.setActiveStrategy)
  const tradeDraft = useTradingStore(s => s.tradeDraft)
  const updateTradeDraft = useTradingStore(s => s.updateTradeDraft)
  const resetTradeDraft = useTradingStore(s => s.resetTradeDraft)
  const apiConfigs = useTradingStore(s => s.apiConfigs)
  const selectedPair = useTradingStore(s => s.selectedPair)
  const setSelectedPair = useTradingStore(s => s.setSelectedPair)
  // K线图弹窗开关：币价区图标点击打开
  const [klineOpen, setKlineOpen] = useState(false)
  const cachedSymbols = loadCachedSymbols()
  const cachedAccount = loadCachedTradingAccount(authUserId)

  const [orderType, setOrderType] = useState<'market' | 'limit'>(tradeDraft.orderType)
  const [stopLossPrice, setStopLossPrice] = useState(tradeDraft.stopLossPrice)
  const [limitPrice, setLimitPrice] = useState(tradeDraft.limitPrice)
  const [showRetracement, setShowRetracement] = useState(false)
  const [retracement, setRetracement] = useState(0)
  const [includeFeesInStopLoss, setIncludeFeesInStopLoss] = useState(tradeDraft.includeFeesInStopLoss)
  const [strategyEnabled, setStrategyEnabled] = useState(true)
  const [symbolList, setSymbolList] = useState<string[]>(getTradingMode() === 'lead' ? [] : cachedSymbols.length > 0 ? cachedSymbols : [...CURATED_TRADING_SYMBOLS])
  const [showPairSelector, setShowPairSelector] = useState(false)
  const [showStopLossModal, setShowStopLossModal] = useState(false)
  const [showApiBindPrompt, setShowApiBindPrompt] = useState(false)
  const [showApiBindModal, setShowApiBindModal] = useState(false)
  const [showOpenConfirmModal, setShowOpenConfirmModal] = useState(false)
  const [capitalLoading, setCapitalLoading] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [emaChecking, setEmaChecking] = useState(false)
  const [emaCheck, setEmaCheck] = useState<EmaCheckResult | null>(null)
  const [emaCheckExpanded, setEmaCheckExpanded] = useState(false)
  const [accountBalance, setAccountBalance] = useState(cachedAccount?.balance ?? 0)
  const [currentQuote, setCurrentQuote] = useState<CurrentQuote>({ symbol: '', price: 0 })
  // 行情请求会在切换币种时与上一笔请求并行。只允许最新一次请求写入价格，
  // 防止旧币种（例如 DOGE）的慢响应覆盖新币种（例如 ETH）的报价。
  const quoteRequestIdRef = useRef(0)
  const quoteInFlightPairsRef = useRef(new Set<string>())
  const initialDataInFlightUserRef = useRef('')
  const initialDataRequestIdRef = useRef(0)
  const openRequestIdentityRef = useRef(EMPTY_TRADE_REQUEST_IDENTITY)
  const limitRequestIdentityRef = useRef(EMPTY_TRADE_REQUEST_IDENTITY)
  const lastInitialDataStartedRef = useRef({ userId: '', at: 0 })
  const strategy = activeStrategy()
  const selectedStrategy = strategy?.name || ''
  const currentPrice = currentQuote.symbol === selectedPair ? currentQuote.price : 0

  const isCurrentInitialDataRequest = useCallback(
    (requestUserId: string, requestId: number, requestSessionRevision: number) => isCurrentAccountRequestScope(
      requestUserId,
      useAuthStore.getState().user?.id ?? '',
      requestId,
      initialDataRequestIdRef.current,
      requestSessionRevision,
      getAccountSessionRevision(),
    ),
    [],
  )

  const FEE_RATE = 0.0005
  const TOTAL_FEE_RATE = FEE_RATE * 2

  useLayoutEffect(() => {
    const nextAccount = loadCachedTradingAccount(authUserId)
    setAccountBalance(nextAccount?.balance ?? 0)
    if (nextAccount && nextAccount.stopLossAmount > 0) {
      setStopLossAmount(nextAccount.stopLossAmount)
    }
  }, [authUserId, setStopLossAmount])

  const pairInitRef = useRef(false)
  useEffect(() => {
    quoteRequestIdRef.current += 1
    // 不复用本地报价：币种切换后宁可短暂显示“--”，也绝不显示上一币种的价格。
    setCurrentQuote({ symbol: selectedPair, price: 0 })
    // 币种切换（含信号跳转切币）时清空上一币种填入的止损价，跳过首次挂载以免清掉草稿
    if (pairInitRef.current) {
      setStopLossPrice('')
    }
    pairInitRef.current = true
  }, [selectedPair])

  useEffect(() => {
    updateTradeDraft({
      orderType,
      takeProfitMode: strategyEnabled ? 'strategy' : 'manual',
      stopLossPrice,
      limitPrice,
      includeFeesInStopLoss,
    })
  }, [includeFeesInStopLoss, limitPrice, orderType, stopLossPrice, strategyEnabled, updateTradeDraft])

  useEffect(() => {
    setEmaCheck(null)
    setEmaCheckExpanded(false)
  }, [selectedPair, stopLossPrice, orderType])

  const loadInitialData = useCallback(async (suppressConnectionError = false) => {
    const requestUserId = authUserId
    if (!requestUserId) return
    const requestSessionRevision = getAccountSessionRevision()
    const now = Date.now()
    const lastStarted = lastInitialDataStartedRef.current
    if (shouldThrottleAccountRequest(
      requestUserId,
      initialDataInFlightUserRef.current,
      lastStarted.userId,
      now - lastStarted.at,
    )) return
    initialDataInFlightUserRef.current = requestUserId
    lastInitialDataStartedRef.current = { userId: requestUserId, at: now }
    const requestId = ++initialDataRequestIdRef.current
    // 策略列表必须与服务器同步：本页策略选择来自本地缓存，若服务器侧策略被删除重建，
    // 缓存里的旧编号会导致开仓时报"策略不存在"。失败时回落本地缓存，不阻断开仓。
    api.get<Array<{ id: number; name: string; is_active: boolean; levels: StrategyLevel[] }>>('/strategy/list', {
      suppressConnectionError,
      disableRetry: suppressConnectionError,
      timeout: suppressConnectionError ? SILENT_REFRESH_TIMEOUT : undefined,
    }).then((data) => {
      if (!isCurrentInitialDataRequest(requestUserId, requestId, requestSessionRevision)) return
      replaceStrategies(data.map((row) => ({ id: String(row.id), name: row.name, levels: row.levels })))
      const active = data.find((row) => row.is_active)
      if (active) setActiveStrategy(String(active.id))
    }).catch(() => {
      // 静默回落本地缓存，与页面其他静默刷新一致
    })
    try {
      const [symbols, account] = await Promise.all([
        api.get<string[]>('/trade/symbols', {
          suppressConnectionError,
          disableRetry: suppressConnectionError,
          timeout: suppressConnectionError ? SILENT_REFRESH_TIMEOUT : undefined,
        }),
        api.get<AccountInfoData>('/account/info', {
          suppressConnectionError,
          disableRetry: suppressConnectionError,
          timeout: suppressConnectionError ? SILENT_REFRESH_TIMEOUT : undefined,
        }),
      ])
      if (!isCurrentInitialDataRequest(requestUserId, requestId, requestSessionRevision)) return
      if (symbols.length > 0 || getTradingMode() === 'lead') {
        setSymbolList(symbols)
        saveCachedSymbols(symbols)
        const activePair = useTradingStore.getState().selectedPair
        if (!activePair || !symbols.includes(activePair)) {
          setSelectedPair(symbols[0])
        }
      }
      const balanceNum = parseOptionalBalance(account.total_balance ?? account.balance)
      if (balanceNum !== null) {
        setAccountBalance(balanceNum)
      }
      const stopLoss = Number(account.stop_loss_amount)
      if (!Number.isNaN(stopLoss) && Number.isFinite(stopLoss) && stopLoss > 0) {
        setStopLossAmount(stopLoss)
      }
      const cachedBalance = balanceNum ?? cachedAccount?.balance
      if (cachedBalance !== undefined) {
        saveCachedTradingAccount(requestUserId, {
          balance: cachedBalance,
          stopLossAmount: !Number.isNaN(stopLoss) && Number.isFinite(stopLoss) && stopLoss > 0
            ? stopLoss
            : useTradingStore.getState().stopLossAmount,
        })
      }
    } catch (error) {
      if (!isCurrentInitialDataRequest(requestUserId, requestId, requestSessionRevision)) return
      if (isApiBindRequiredError(error)) {
        setShowApiBindPrompt(true)
        showToast('请先绑定API')
      }
    } finally {
      if (
        initialDataInFlightUserRef.current === requestUserId
        && initialDataRequestIdRef.current === requestId
      ) {
        initialDataInFlightUserRef.current = ''
      }
      if (isCurrentInitialDataRequest(requestUserId, requestId, requestSessionRevision)) {
        requestAppLayoutSync('trading-initial-data')
      }
    }
  }, [
    authUserId,
    cachedAccount?.balance,
    isCurrentInitialDataRequest,
    replaceStrategies,
    setActiveStrategy,
    setSelectedPair,
    setStopLossAmount,
  ])

  useEffect(() => {
    void loadInitialData(true)
  }, [loadInitialData])

  const fetchQuote = useCallback(async (requestedPair: string, suppressConnectionError = false) => {
    if (!requestedPair) return null
    if (quoteInFlightPairsRef.current.has(requestedPair)) return null
    quoteInFlightPairsRef.current.add(requestedPair)
    const requestId = ++quoteRequestIdRef.current
    const controller = new AbortController()
    const timeoutId = window.setTimeout(
      () => controller.abort(),
      suppressConnectionError ? SILENT_REFRESH_TIMEOUT : 30_000,
    )
    try {
      const info = await api.get<SymbolInfoData>(`/trade/symbol/info?symbol=${encodeURIComponent(requestedPair)}`, {
        disableRetry: true,
        suppressConnectionError,
        timeout: suppressConnectionError ? SILENT_REFRESH_TIMEOUT : 30_000,
        signal: controller.signal,
      })
      if (!info) return null
      const nextPrice = Number(info.current_price)
      const currentSelectedPair = useTradingStore.getState().selectedPair
      if (
        quoteRequestIdRef.current === requestId &&
        currentSelectedPair === requestedPair &&
        info.symbol === requestedPair &&
        !Number.isNaN(nextPrice) &&
        Number.isFinite(nextPrice)
      ) {
        setCurrentQuote({ symbol: info.symbol, price: nextPrice })
      }
      return Number.isFinite(nextPrice) ? nextPrice : null
    } catch {
      // 保持已有价格
      return null
    } finally {
      window.clearTimeout(timeoutId)
      quoteInFlightPairsRef.current.delete(requestedPair)
    }
  }, [])

  const loadSymbolInfo = useCallback(
    (suppressConnectionError = false) => fetchQuote(selectedPair, suppressConnectionError),
    [fetchQuote, selectedPair],
  )

  useEffect(() => {
    void loadSymbolInfo(true)
  }, [loadSymbolInfo])

  useEffect(() => {
    if (!selectedPair) return
    const timer = window.setInterval(() => {
      if (document.visibilityState !== 'visible') return
      void loadSymbolInfo(true)
    }, QUOTE_POLL_INTERVAL_MS)
    return () => window.clearInterval(timer)
  }, [loadSymbolInfo, selectedPair])

  useEffect(() => {
    const onResume = () => {
      if (document.visibilityState !== 'visible') return
      void loadInitialData(true)
      void loadSymbolInfo(true)
    }
    window.addEventListener('app:resume', onResume as EventListener)
    return () => window.removeEventListener('app:resume', onResume as EventListener)
  }, [loadInitialData, loadSymbolInfo])

  const calculatePosition = () => {
    const stopPrice = parseFloat(stopLossPrice)
    let referencePrice = currentPrice
    if (orderType === 'limit') {
      const limitPriceValue = parseFloat(limitPrice)
      if (!isNaN(limitPriceValue) && limitPriceValue > 0) {
        referencePrice = limitPriceValue
      } else {
        return { position: 0, fee: 0, stopLossAmount }
      }
    }
    if (referencePrice <= 0 || isNaN(stopPrice) || stopPrice <= 0) {
      return { position: 0, fee: 0, stopLossAmount }
    }
    const priceDiff = Math.abs(referencePrice - stopPrice)
    const priceChangeRatio = priceDiff / referencePrice
    if (priceChangeRatio === 0) {
      return { position: 0, fee: 0, stopLossAmount }
    }
    const position = includeFeesInStopLoss
      ? stopLossAmount / (priceChangeRatio + TOTAL_FEE_RATE)
      : stopLossAmount / priceChangeRatio
    const fee = position * TOTAL_FEE_RATE
    return {
      position: Math.round(position * 100) / 100,
      fee: Math.round(fee * 100) / 100,
      stopLossAmount,
    }
  }

  const positionData = calculatePosition()

  useEffect(() => {
    if (!stopLossPrice || stopLossPrice.trim() === '') {
      setShowRetracement(false)
      return
    }
    const timer = setTimeout(() => {
      const stopPrice = parseFloat(stopLossPrice)
      const referencePrice = orderType === 'limit' ? parseFloat(limitPrice) : currentPrice
      if (!isNaN(stopPrice) && stopPrice > 0 && !isNaN(referencePrice) && referencePrice > 0) {
        setRetracement(((stopPrice - referencePrice) / referencePrice) * 100)
        setShowRetracement(true)
      } else {
        setShowRetracement(false)
      }
    }, 1000)
    return () => clearTimeout(timer)
  }, [stopLossPrice, currentPrice, orderType, limitPrice])

  const derivedMarketSide = (() => {
    const stopPrice = parseFloat(stopLossPrice)
    if (!stopLossPrice || stopLossPrice.trim() === '' || isNaN(stopPrice) || currentPrice <= 0 || stopPrice === currentPrice) {
      return null
    }
    return stopPrice < currentPrice ? 'long' : 'short'
  })()

  const emaCheckExpired = emaCheck ? new Date(emaCheck.expires_at).getTime() <= Date.now() : false
  const emaCheckDirectionChanged = !!emaCheck && !!derivedMarketSide && emaCheck.side !== derivedMarketSide
  const hasValidPassingEmaCheck = !!(
    emaCheck &&
    !emaCheckExpired &&
    !emaCheckDirectionChanged &&
    emaCheck.symbol === selectedPair &&
    emaCheck.has_any_matching_interval
  )

  const getButtonState = () => {
    const stopPrice = parseFloat(stopLossPrice)
    if (orderType === 'market') {
      if (!stopLossPrice || stopLossPrice.trim() === '' || isNaN(stopPrice) || currentPrice <= 0 || !derivedMarketSide) {
        return { disabled: true, text: '输入止损价开仓', bgColor: 'bg-gray-600 dark:bg-gray-600', hoverColor: '', isLong: null, action: 'none' as const }
      }
      if (strategyEnabled && !strategy) {
        return { disabled: true, text: '请选择止盈策略', bgColor: 'bg-gray-600 dark:bg-gray-600', hoverColor: '', isLong: null, action: 'none' as const }
      }
      if (emaChecking) {
        return { disabled: true, text: '检测中...', bgColor: 'bg-gray-600 dark:bg-gray-600', hoverColor: '', isLong: null, action: 'none' as const }
      }
      if (hasValidPassingEmaCheck) {
        const isLong = derivedMarketSide === 'long'
        return {
          disabled: submitting,
          text: isLong ? '市价开多' : '市价开空',
          bgColor: isLong ? 'bg-[#0ECB81]' : 'bg-[#F6465D]',
          hoverColor: isLong ? 'hover:bg-[#0DB872]' : 'hover:bg-[#E0394D]',
          isLong,
          action: 'open' as const,
        }
      }
      if (!hasValidPassingEmaCheck) {
        return {
          disabled: false,
          text: emaCheck && (emaCheckExpired || emaCheckDirectionChanged || !emaCheck.has_any_matching_interval) ? '重新方向初筛' : '方向初筛',
          bgColor: 'bg-gradient-to-r from-[var(--t-brand)] to-[var(--t-brand-hover)]',
          hoverColor: 'hover:shadow-lg hover:shadow-[var(--t-brand)]/30',
          isLong: derivedMarketSide === 'long',
          action: 'ema-check' as const,
        }
      }
    }
    const limitPriceValue = parseFloat(limitPrice)
    if (!stopLossPrice || isNaN(stopPrice) || !limitPrice || isNaN(limitPriceValue)) {
      return { disabled: true, text: '输入止损价/限价开仓', bgColor: 'bg-gray-600 dark:bg-gray-600', hoverColor: '', isLong: null, action: 'none' as const }
    }
    if (strategyEnabled && !strategy) {
      return { disabled: true, text: '请选择止盈策略', bgColor: 'bg-gray-600 dark:bg-gray-600', hoverColor: '', isLong: null, action: 'none' as const }
    }
    const isLong = stopPrice < limitPriceValue
    return {
      disabled: submitting,
      text: isLong ? '限价开多' : '限价开空',
      bgColor: isLong ? 'bg-[#0ECB81]' : 'bg-[#F6465D]',
      hoverColor: isLong ? 'hover:bg-[#0DB872]' : 'hover:bg-[#E0394D]',
      isLong,
      action: 'open' as const,
    }
  }

  const buttonState = getButtonState()
  const showMarketOpenButton = Boolean(
    orderType === 'market' &&
      hasValidPassingEmaCheck &&
      derivedMarketSide &&
      buttonState.action !== 'open',
  )
  const marketOpenButtonState = showMarketOpenButton
    ? {
        disabled: submitting,
        text: derivedMarketSide === 'long' ? '市价开多' : '市价开空',
        bgColor: derivedMarketSide === 'long' ? 'bg-[#0ECB81]' : 'bg-[#F6465D]',
        hoverColor: derivedMarketSide === 'long' ? 'hover:bg-[#0DB872]' : 'hover:bg-[#E0394D]',
        isLong: derivedMarketSide === 'long',
      }
    : null
  const tradingContentBottomPadding = marketOpenButtonState
    ? 'calc(220px + max(var(--app-safe-bottom, 0px), env(safe-area-inset-bottom, 0px)))'
    : 'calc(156px + max(var(--app-safe-bottom, 0px), env(safe-area-inset-bottom, 0px)))'
  const emaSupportedCount = emaCheck ? emaCheck.items.filter(item => item.supported).length : 0
  const emaMatchingCount = emaCheck ? emaCheck.items.filter(item => item.supported && item.matches_direction).length : 0
  const emaSummaryDenominator = emaSupportedCount > 0 ? emaSupportedCount : (emaCheck?.items.length ?? 0)

  useEffect(() => {
    requestAppLayoutSync('trading-action-area-changed')
  }, [emaCheckExpanded, showMarketOpenButton])

  const getConfirmRetracement = () => {
    const stopPrice = parseFloat(stopLossPrice)
    if (Number.isNaN(stopPrice) || stopPrice <= 0) return undefined
    const referencePrice = orderType === 'limit' ? parseFloat(limitPrice) : currentPrice
    if (Number.isNaN(referencePrice) || referencePrice <= 0) return undefined
    return Math.abs(((referencePrice - stopPrice) / referencePrice) * 100)
  }

  const handleRunEmaCheck = async () => {
    if (apiConfigs.length === 0) {
      setShowApiBindPrompt(true)
      return
    }
    try {
      setEmaChecking(true)
      const result = await api.post<EmaCheckResult>('/trade/ema-check', {
        symbol: selectedPair,
        stop_loss_price: stopLossPrice,
      })
      setEmaCheck(result)
      setEmaCheckExpanded(false)
      showToast(result.has_any_matching_interval ? '方向初筛通过' : '方向初筛未通过')
    } catch (error) {
      const message = error instanceof ApiError ? error.message : '方向初筛失败，请稍后重试'
      if (isApiBindRequiredError(error)) {
        setShowApiBindPrompt(true)
      }
      showToast(message)
    } finally {
      setEmaChecking(false)
    }
  }

  const handleSubmitIntent = () => {
    if (buttonState.disabled) return
    if (apiConfigs.length === 0) {
      setShowApiBindPrompt(true)
      return
    }
    if (buttonState.action === 'ema-check') {
      void handleRunEmaCheck()
      return
    }
    setShowOpenConfirmModal(true)
  }

  const handleOpenIntent = () => {
    if (!marketOpenButtonState || marketOpenButtonState.disabled) return
    if (apiConfigs.length === 0) {
      setShowApiBindPrompt(true)
      return
    }
    setShowOpenConfirmModal(true)
  }

  const handleOpenPosition = async () => {
    if (apiConfigs.length === 0) {
      setShowApiBindPrompt(true)
      return
    }
    if (submitting) return
    try {
      setSubmitting(true)

      if (orderType === 'limit') {
        if (strategyEnabled && !strategy) {
          showToast('请先选择止盈策略')
          return
        }
        const openPayload: Record<string, unknown> = {
          symbol: selectedPair,
          limit_price: limitPrice,
          stop_loss_price: stopLossPrice,
          stop_loss_amount: String(stopLossAmount),
        }
        if (strategyEnabled && strategy) {
          openPayload.strategy_id = strategy.id
          openPayload.strategy_name = strategy.name
          openPayload.strategy_config = strategy.levels
        }
        limitRequestIdentityRef.current = resolveTradeRequestIdentity(
          limitRequestIdentityRef.current,
          openPayload,
        )
        openPayload.client_request_id = limitRequestIdentityRef.current.requestId
        const payload = await api.post<{ limit_order_id: number }>('/trade/limit-order/create', openPayload)
        if (payload?.limit_order_id) {
          limitRequestIdentityRef.current = EMPTY_TRADE_REQUEST_IDENTITY
          resetTradeDraft()
          showToast('限价委托提交成功')
          navigate('/holdings', { state: { activeTab: 'limit-orders' } })
        } else {
          limitRequestIdentityRef.current = EMPTY_TRADE_REQUEST_IDENTITY
          resetTradeDraft()
          showToast('限价委托已提交')
          navigate('/holdings', { state: { activeTab: 'limit-orders' } })
        }
      } else {
        if (strategyEnabled && !strategy) {
          showToast('请先选择止盈策略')
          setSubmitting(false)
          return
        }
        if (!emaCheck || !hasValidPassingEmaCheck) {
          showToast(emaCheckExpired || emaCheckDirectionChanged ? '方向初筛已过期，请重新检测' : '请先完成方向初筛')
          setSubmitting(false)
          return
        }

        // The server always obtains a fresh Binance ticker before calculating size
        // and sending the order. Keep this UI quote refresh opportunistic so opening
        // is never blocked by the lower-frequency display poll.
        void fetchQuote(selectedPair, false)
        const openPayload: Record<string, unknown> = {
          symbol: selectedPair,
          stop_loss_price: stopLossPrice,
          stop_loss_amount: String(stopLossAmount),
          include_fee: includeFeesInStopLoss,
          ema_check_id: emaCheck.check_id,
        }

        if (strategyEnabled && strategy) {
          openPayload.strategy_id = strategy.id
          openPayload.strategy_name = strategy.name
          openPayload.strategy_config = strategy.levels
        }
        openRequestIdentityRef.current = resolveTradeRequestIdentity(
          openRequestIdentityRef.current,
          openPayload,
        )
        openPayload.client_request_id = openRequestIdentityRef.current.requestId

        const payload = await api.post<{ position_id: number }>('/trade/open', openPayload)
        if (payload?.position_id) {
          openRequestIdentityRef.current = EMPTY_TRADE_REQUEST_IDENTITY
          resetTradeDraft()
          setEmaCheck(null)
          showToast('开仓成功')
          navigate('/holdings')
        } else {
          openRequestIdentityRef.current = EMPTY_TRADE_REQUEST_IDENTITY
          resetTradeDraft()
          setEmaCheck(null)
          showToast('开仓请求已提交')
          navigate('/holdings')
        }
      }
    } catch (error) {
      const requestMustBeReused = error instanceof ApiError && (
        error.code === 409 || error.code < 0 || error.code >= 500
      )
      if (!requestMustBeReused) {
        if (orderType === 'limit') limitRequestIdentityRef.current = EMPTY_TRADE_REQUEST_IDENTITY
        else openRequestIdentityRef.current = EMPTY_TRADE_REQUEST_IDENTITY
      }
      const errorInfo = formatTradingSubmitError(error)
      reportTradingSubmitError(errorInfo, {
        action: orderType === 'limit' ? 'limit-order-create' : 'market-open',
        symbol: selectedPair,
        stop_loss_price: stopLossPrice,
        stop_loss_amount: String(stopLossAmount),
        has_ema_check: Boolean(emaCheck?.check_id),
        strategy_enabled: strategyEnabled,
      })
      if (isApiBindRequiredError(error)) {
        setShowApiBindPrompt(true)
      }
      showToast(errorInfo.message)
    } finally {
      setSubmitting(false)
    }
  }

  const handleCapitalPrecheck = async () => {
    if (capitalLoading || submitting) return
    setCapitalLoading(true)
    try {
      const ready = await ensureManualEntryCapitalReady('entry')
      if (!ready) return
      setShowOpenConfirmModal(false)
      await handleOpenPosition()
    } finally {
      setCapitalLoading(false)
    }
  }

  const handlePairSelect = (pair: string) => {
    if (pair === selectedPair) return
    setSelectedPair(pair)
    resetTradeDraft()
    setOrderType('market')
    setStopLossPrice('')
    setLimitPrice('')
    setIncludeFeesInStopLoss(false)
    setStrategyEnabled(true)
    setShowRetracement(false)
    setRetracement(0)
    setEmaCheck(null)
    setEmaCheckExpanded(false)
  }

  return (
    <div className="h-full flex flex-col max-w-md mx-auto overscroll-none">
      {/* 顶部标题栏 - 延伸到状态栏区域 */}
      <div
        className="bg-t-surface"
        style={{ paddingTop: standalone ? 'max(44px, env(safe-area-inset-top, 0px))' : 'env(safe-area-inset-top, 0px)' }}
      >
        <div
          onClick={() => setShowPairSelector(true)}
          className="flex items-center justify-center py-3 cursor-pointer"
        >
          <span className="text-t-text font-medium">{selectedPair || '选择交易对'}</span>
          <ChevronDown size={18} className="text-t-text-muted ml-1" />
        </div>
      </div>

      {/* 可滚动内容区域 */}
      <div className="flex-1 min-h-0 overflow-auto overscroll-contain hide-scrollbar bg-t-page">
        <div
          className="p-4"
          style={{ paddingBottom: tradingContentBottomPadding }}
        >
          <Suspense fallback={null}>
            <KlineChartCard
              entry="none"
              open={klineOpen}
              onOpenChange={setKlineOpen}
              stopLossEnabled
              symbol={selectedPair}
              onCrosshairPrice={(price) => {
                // K线图十字光标滑动时，将光标价格自动填入止损价栏位（按精度规则格式化）
                if (price > 0) setStopLossPrice(formatChartPrice(price))
              }}
            />
          </Suspense>
          <div className="rounded-lg p-4 mb-4 transition-colors bg-t-surface">
        <div className="flex justify-between items-center mb-4">
          <div className="text-t-text-muted text-sm">币价</div>
          <div className="flex gap-2">
            {(['market', 'limit'] as const).map(type => (
              <button
                key={type}
                onClick={() => setOrderType(type)}
                className={`px-3 py-1 rounded text-sm transition-colors ${
                  orderType === type
                    ? 'bg-[var(--t-brand)] text-black'
                    : 'bg-t-btn-secondary text-t-text-secondary hover:bg-t-btn-secondary-hover'
                }`}
              >
                {type === 'market' ? '市价开仓' : '限价委托'}
              </button>
            ))}
          </div>
        </div>

        <div className="mb-4 flex items-center gap-2">
          {/* 价格下划线可点击：与 K 线按钮一样打开 K 线图弹窗 */}
          <button
            type="button"
            onClick={() => setKlineOpen(true)}
            className="text-2xl text-t-text underline underline-offset-4 cursor-pointer"
            title="打开K线图"
          >
            {currentPrice > 0 ? currentPrice : '--'}
          </button>
          {/* K线图入口：与持仓卡片底部同款短按钮（图标+K线文字） */}
          <button
            type="button"
            onClick={() => setKlineOpen(true)}
            className="shrink-0 flex items-center gap-1 px-2.5 py-2 rounded-lg text-sm font-medium transition-colors border border-t-border bg-t-btn-secondary text-t-text hover:bg-t-btn-secondary-hover"
            aria-label="K线图"
          >
            <CandlestickChart size={16} />
            <span>K线</span>
          </button>
        </div>

        {orderType === 'limit' && (
          <div className="mb-4">
            <div className="text-t-text-muted text-sm mb-2">限价</div>
            <input
              type="text"
              value={limitPrice}
              onChange={(e) => setLimitPrice(e.target.value)}
              placeholder="请输入限价"
              className="w-full rounded-lg px-4 py-3 placeholder:text-t-text-placeholder focus:outline-none focus:ring-2 focus:ring-[var(--t-brand)] transition-colors bg-t-surface-input text-t-text"
            />
          </div>
        )}

        <div className="mb-4">
          <div className="text-t-text-muted text-sm mb-2">止损价</div>
          <div className="relative">
            <input
              type="text"
              value={stopLossPrice}
              onChange={(e) => setStopLossPrice(e.target.value)}
              placeholder="请输入止损价"
              className="w-full rounded-lg px-4 py-3 pr-24 placeholder:text-t-text-placeholder focus:outline-none focus:ring-2 focus:ring-[var(--t-brand)] transition-colors bg-t-surface-input text-t-text"
            />
            {showRetracement && (
              <div className={`absolute right-4 top-1/2 -translate-y-1/2 text-sm ${retracement >= 0 ? 'text-[#3DD598]' : 'text-[#F6465D]'}`}>
                回撤：{retracement.toFixed(2)}%
              </div>
            )}
          </div>
        </div>

        <div className="mb-3">
          <div className="flex items-center justify-between mb-2">
            <div className="text-t-text-muted text-sm">止盈策略</div>
            <button
              type="button"
              onClick={() => setStrategyEnabled(prev => !prev)}
              className={`h-6 w-6 rounded-md border transition-all flex items-center justify-center ${
                strategyEnabled
                  ? 'bg-[var(--t-brand)] border-[var(--t-brand)] text-black shadow-sm shadow-[var(--t-brand)]/25'
                  : 'bg-t-btn-secondary border-t-border text-transparent'
              }`}
              aria-label={strategyEnabled ? '关闭止盈策略' : '启用止盈策略'}
            >
              ✓
            </button>
          </div>
          <button
            onClick={() => navigate('/strategy-management', { state: { from: '/trading' } })}
            className={`w-full rounded-lg p-3 border-2 transition-all ${
              strategyEnabled
                ? selectedStrategy
                  ? 'bg-[var(--t-brand)]/12 border-[var(--t-brand)]/35 border-dashed hover:bg-[var(--t-brand)]/18'
                  : 'bg-[var(--t-brand)]/8 border-[var(--t-brand)]/25 border-dashed hover:bg-[var(--t-brand)]/12'
                : 'bg-t-btn-secondary/70 border-t-border border-dashed hover:bg-t-btn-secondary-hover'
            }`}
          >
            <span className={`text-sm font-medium ${
              strategyEnabled
                ? selectedStrategy ? 'text-[var(--t-brand)]' : 'text-[var(--t-brand)]/75'
                : 'text-t-text-muted'
            }`}>
              {strategyEnabled ? (selectedStrategy || '请选择策略') : '未启用自动止盈策略'}
            </span>
          </button>
        </div>

      </div>

      <div className="mb-4">
        <div className="rounded-lg p-4 transition-colors bg-t-surface">
          <div className="grid grid-cols-3 gap-4 mb-3">
            {[
              { label: '止损金额', value: positionData.stopLossAmount },
              { label: '预估仓位', value: positionData.position },
              { label: '预估手续费', value: positionData.fee },
            ].map(item => (
              <div key={item.label} className="text-center">
                <div className="text-t-text-muted text-sm mb-2">{item.label}</div>
                <div className="text-2xl text-t-text">{item.value}</div>
              </div>
            ))}
          </div>

          <div className="pt-3 border-t border-t-border flex items-center justify-between">
            <button
              onClick={() => setShowStopLossModal(true)}
              className="bg-gradient-to-r from-[var(--t-brand)] to-[var(--t-brand-hover)] text-black px-6 py-2 rounded-lg text-sm font-medium transition-all hover:shadow-lg hover:shadow-[var(--t-brand)]/30 active:scale-[0.98]"
            >
              调整止损金额
            </button>
            <div className="flex items-center gap-2">
              <span className="text-t-text-muted text-sm">止损含手续费</span>
              <button
                type="button"
                onClick={() => setIncludeFeesInStopLoss(!includeFeesInStopLoss)}
                className={`relative w-12 h-7 shrink-0 rounded-full transition-colors ${
                  includeFeesInStopLoss ? 'bg-[var(--t-brand)]' : 'bg-t-btn-secondary'
                }`}
              >
                <div className={`absolute left-0.5 top-0.5 w-6 h-6 rounded-full bg-white shadow-md transition-transform ${includeFeesInStopLoss ? 'translate-x-5' : 'translate-x-0'}`} />
              </button>
            </div>
          </div>
        </div>
      </div>

      {orderType === 'market' && emaCheck && (
        <div className={`rounded-lg border p-3 mb-4 ${emaCheck.has_any_matching_interval && !emaCheckExpired && !emaCheckDirectionChanged ? 'border-[#0ECB81]/25 bg-[#0ECB81]/8' : 'border-[var(--t-brand)]/30 bg-[var(--t-brand)]/10'}`}>
          <button
            type="button"
            onClick={() => setEmaCheckExpanded(prev => !prev)}
            className="w-full text-left"
          >
            <div className="flex items-start justify-between gap-3">
              <div>
                <div className={`text-sm font-medium ${emaCheck.has_any_matching_interval && !emaCheckExpired && !emaCheckDirectionChanged ? 'text-[#0ECB81]' : 'text-[var(--t-brand)]'}`}>
                  {emaCheckExpired
                    ? '方向初筛已过期'
                    : emaCheckDirectionChanged
                      ? '方向初筛方向已变化'
                      : emaCheck.has_any_matching_interval
                        ? '方向初筛通过'
                        : '所有周期暂不支持当前方向'}
                </div>
                <div className="text-xs text-t-text-muted mt-1">
                  {emaCheck.side === 'long' ? '做多' : '做空'} · 3分钟内有效
                </div>
              </div>
              <div className="flex items-center gap-2">
                <div className="text-sm font-semibold text-t-text">{`${emaMatchingCount}/${emaSummaryDenominator || 0}`}</div>
                <ChevronDown
                  size={18}
                  className={`text-t-text-muted transition-transform ${emaCheckExpanded ? 'rotate-180' : ''}`}
                />
              </div>
            </div>
            {!emaCheckExpanded && (
              <div className="mt-3 flex flex-wrap items-center gap-x-3 gap-y-2">
                {emaCheck.items.map(item => (
                  <div key={item.interval} className="flex items-center gap-1.5">
                    <img
                      src={item.supported && item.matches_direction ? emaCheckPassIcon : emaCheckFailIcon}
                      alt={item.supported && item.matches_direction ? '通过' : '未通过'}
                      className="h-4 w-4 shrink-0"
                    />
                    <span className={`text-xs ${item.supported && item.matches_direction ? 'text-[#04bf81]' : 'text-[#d81e06]'}`}>
                      {item.label}
                    </span>
                  </div>
                ))}
              </div>
            )}
          </button>
          {emaCheckExpanded && (
            <div className="mt-3 space-y-2">
              {emaCheck.items.map(item => (
                <div key={`${item.interval}-detail`} className="rounded-md bg-t-surface px-3 py-2">
                  <div className="flex items-center justify-between gap-3">
                    <div className="flex items-center gap-2">
                      <img
                        src={item.supported && item.matches_direction ? emaCheckPassIcon : emaCheckFailIcon}
                        alt={item.supported && item.matches_direction ? '通过' : '未通过'}
                        className="h-4 w-4 shrink-0"
                      />
                      <div className="text-sm text-t-text">{item.label}</div>
                    </div>
                    <div className={`text-xs font-medium ${item.supported ? (item.matches_direction ? 'text-[#0ECB81]' : 'text-[#F6465D]') : 'text-t-text-muted'}`}>
                      {!item.supported ? '数据不足' : item.matches_direction ? '支持' : '不支持'}
                    </div>
                  </div>
                  <div className="text-xs text-t-text-muted mt-1">{item.relation}</div>
                </div>
              ))}
            </div>
          )}
        </div>
      )}

      <button
        onClick={handleSubmitIntent}
        className={`w-full ${buttonState.bgColor} ${buttonState.hoverColor} ${buttonState.action === 'ema-check' ? 'text-black active:scale-[0.98]' : 'text-white'} py-3 rounded-lg transition-all font-medium ${marketOpenButtonState ? 'mb-4' : ''}`}
        disabled={buttonState.disabled}
      >
        {emaChecking ? '检测中...' : buttonState.text}
      </button>

      {marketOpenButtonState && (
        <button
          onClick={handleOpenIntent}
          className={`w-full ${marketOpenButtonState.bgColor} ${marketOpenButtonState.hoverColor} text-white py-3 rounded-lg transition-colors font-medium`}
          disabled={marketOpenButtonState.disabled}
        >
          {submitting ? '提交中...' : marketOpenButtonState.text}
        </button>
      )}
        </div>
      </div>

      <TradingPairSelector
        isOpen={showPairSelector}
        onClose={() => setShowPairSelector(false)}
        onSelect={handlePairSelect}
        currentPair={selectedPair}
        pairs={symbolList}
      />

      <StopLossSettingsModal
        isOpen={showStopLossModal}
        onClose={() => setShowStopLossModal(false)}
        currentAmount={stopLossAmount}
        accountBalance={accountBalance}
        onAmountChange={setStopLossAmount}
      />

      <OpenPositionConfirmModal
        isOpen={showOpenConfirmModal}
        onClose={() => setShowOpenConfirmModal(false)}
        onConfirm={async () => {
          await handleCapitalPrecheck()
        }}
        direction={(marketOpenButtonState?.isLong ?? buttonState.isLong) ? 'long' : 'short'}
        tradingPair={selectedPair}
        stopLossPrice={stopLossPrice}
        limitPrice={orderType === 'limit' ? limitPrice : undefined}
        position={positionData.position}
        fee={positionData.fee}
        stopLossAmount={positionData.stopLossAmount}
        includeFeesInStopLoss={includeFeesInStopLoss}
        stopLossRetracement={getConfirmRetracement()}
        mode={orderType}
        loading={submitting || capitalLoading}
      />

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
              开仓前需要绑定交易所API，请先前往绑定。
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
    </div>
  )
}
