import { lazy, Suspense, useCallback, useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'

import { api, ApiError } from '@/shared/lib/api'
import { isStandaloneMode } from '@/shared/lib/device'
import { useTradingStore } from '@/shared/store'
import { SignalRulesModal } from '@/components/modals/SignalRulesModal'

const KlineChartCard = lazy(() =>
  import('@/pages/trading/KlineChartCard').then(mod => ({ default: mod.KlineChartCard }))
)

interface SignalItem {
  id: number
  source: SignalSource
  symbol: string
  signal: string
  direction: 'LONG' | 'SHORT' | 'INFO'
  strategy: string
  title: string
  price_display: string
  interval: string
  comment: string
  signal_time: string
  received_at: string
  // 自有扫描附加字段
  score: number | null
  final_action: string
  entry_condition: string
  risk_points: string[]
  provider: string
  event_id: string
  indicators: Array<{ name: string; value: string }>
}

type SignalSource = 'external' | 'internal'

const REFRESH_INTERVAL = 30000
const SIGNALS_CACHE_KEY = 'tradetools:signals:v4'

function loadCachedSignals(): SignalItem[] {
  try {
    const raw = localStorage.getItem(SIGNALS_CACHE_KEY)
    if (!raw) return []
    const parsed = JSON.parse(raw) as unknown
    if (!Array.isArray(parsed)) return []
    return (parsed as Array<SignalItem & { source?: string }>).map(item => ({
      ...item,
      source: item.source === 'internal' ? 'internal' : 'external',
      provider: item.provider || '',
      event_id: item.event_id || '',
      indicators: Array.isArray(item.indicators) ? item.indicators : [],
    }))
  } catch {
    return []
  }
}

// 解析信号时间：后端/容器为 UTC，naive 时间（无时区后缀）需按 UTC 解释，
// 否则会被当作本地时间导致偏差（如 UTC+8 下多算 8 小时）
function parseSignalDate(value: string): Date | null {
  if (!value) return null
  if (/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/.test(value)) {
    const d = new Date(`${value.replace(' ', 'T')}Z`)
    return Number.isNaN(d.getTime()) ? null : d
  }
  const d = new Date(value)
  return Number.isNaN(d.getTime()) ? null : d
}

// 相对时间：分钟内显示“几分钟前”，超一小时“几小时前”，超一天“几天前”；
// 30 分钟内的信号用绿色高亮，其余保持默认灰色
function formatRelativeTime(iso: string): { text: string; isRecent: boolean } {
  const date = parseSignalDate(iso)
  if (!date) return { text: '', isRecent: false }
  const minutes = Math.floor((Date.now() - date.getTime()) / 60000)
  if (minutes < 1) return { text: '刚刚', isRecent: true }
  if (minutes < 60) return { text: `${minutes} 分钟前`, isRecent: minutes < 30 }
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return { text: `${hours} 小时前`, isRecent: false }
  return { text: `${Math.floor(hours / 24)} 天前`, isRecent: false }
}

function formatSignalTime(iso: string): string {
  const date = parseSignalDate(iso)
  if (!date) return ''
  const hours = String(date.getHours()).padStart(2, '0')
  const minutes = String(date.getMinutes()).padStart(2, '0')
  return `${date.getMonth() + 1}/${date.getDate()} ${hours}:${minutes}`
}

/**
 * 将外部信号的 symbol 归一化为币安合约交易对格式：
 * - 去掉交易所前缀（如 BINANCE:ADAUSDT → ADAUSDT）
 * - 去掉合约后缀（如 ADAUSDT.P → ADAUSDT）
 * 若不在支持列表，开仓页会自动回退到默认币种。
 */
function normalizeSignalSymbol(raw: string): string {
  let symbol = String(raw || '')
    .trim()
    .toUpperCase()
  const colonIdx = symbol.lastIndexOf(':')
  if (colonIdx >= 0) symbol = symbol.slice(colonIdx + 1)
  const dotIdx = symbol.indexOf('.')
  if (dotIdx > 0) symbol = symbol.slice(0, dotIdx)
  const normalized = symbol.replace(/[^A-Z0-9]/g, '')
  return normalized === 'UNKNOWN' ? '' : normalized
}

function DirectionBadge({ direction }: { direction: SignalItem['direction'] }) {
  if (direction === 'LONG') {
    return (
      <span className="shrink-0 px-2 py-0.5 rounded text-xs font-medium bg-[#0ECB81]/10 text-[#0ECB81]">
        多
      </span>
    )
  }
  if (direction === 'SHORT') {
    return (
      <span className="shrink-0 px-2 py-0.5 rounded text-xs font-medium bg-[#F6465D]/10 text-[#F6465D]">
        空
      </span>
    )
  }
  return (
    <span className="shrink-0 px-2 py-0.5 rounded text-xs font-medium bg-t-surface-hover text-t-text-muted">
      提醒
    </span>
  )
}

function SignalSourceBadge({ source }: { source: SignalSource }) {
  const external = source === 'external'
  return (
    <span
      className={`shrink-0 rounded px-1.5 py-0.5 text-[10px] font-medium ${
        external ? 'bg-[#2F80ED]/10 text-[#2F80ED]' : 'bg-[#F0B90B]/10 text-[#F0B90B]'
      }`}
    >
      {external ? '外部' : '内部'}
    </span>
  )
}

export function SignalsPage() {
  const standalone = isStandaloneMode()
  const navigate = useNavigate()
  const setSelectedPair = useTradingStore(s => s.setSelectedPair)
  // 首屏直接读本地缓存渲染，避免每次进入都显示“加载中”；随后静默刷新拉取增量。
  const [signals, setSignals] = useState<SignalItem[]>(() => loadCachedSignals())
  const [loading, setLoading] = useState(() => signals.length === 0)
  const [activeTab, setActiveTab] = useState<SignalSource>('external')
  const [errorMessage, setErrorMessage] = useState('')
  const [showRulesModal, setShowRulesModal] = useState(false)
  const timerRef = useRef<number | null>(null)
  // 下拉刷新（与持仓页同款逻辑/图标）
  const [isRefreshing, setIsRefreshing] = useState(false)
  const [pullDistance, setPullDistance] = useState(0)
  const [isPulling, setIsPulling] = useState(false)
  const scrollRef = useRef<HTMLDivElement | null>(null)
  const touchStartYRef = useRef<number | null>(null)
  const isRefreshingRef = useRef(false)
  const isPullingRef = useRef(false)
  const pullDistanceRef = useRef(0)
  // 点击信号卡片：在当前页弹出对应币种的 K 线图（归一化后的空串则不弹）
  const [klineSymbol, setKlineSymbol] = useState('')

  const openSignalKline = useCallback((item: SignalItem) => {
    const symbol = normalizeSignalSymbol(item.symbol)
    if (symbol) setKlineSymbol(symbol)
  }, [])

  // 弹窗底部“去开仓”：切换到信号币种并跳转开仓页
  const gotoTrading = useCallback(() => {
    if (klineSymbol) setSelectedPair(klineSymbol)
    setKlineSymbol('')
    navigate('/trading')
  }, [klineSymbol, navigate, setSelectedPair])

  useEffect(() => {
    isRefreshingRef.current = isRefreshing
  }, [isRefreshing])

  useEffect(() => {
    isPullingRef.current = isPulling
  }, [isPulling])

  useEffect(() => {
    pullDistanceRef.current = pullDistance
  }, [pullDistance])

  const signalsInFlightRef = useRef(false)
  const fetchSignals = useCallback(async (silent = false) => {
    if (document.visibilityState !== 'visible' || !navigator.onLine || signalsInFlightRef.current) return
    signalsInFlightRef.current = true
    try {
      const requestConfig = {
        suppressConnectionError: silent,
        disableRetry: silent,
        timeout: silent ? 8000 : undefined,
      }
      const [externalData, internalData] = await Promise.all([
        api.get<SignalItem[]>('/trade/tradingview/signals?source=external', requestConfig),
        api.get<SignalItem[]>('/trade/tradingview/signals?source=internal', requestConfig),
      ])
      const list = [
        ...(Array.isArray(externalData) ? externalData : []),
        ...(Array.isArray(internalData) ? internalData : []),
      ].sort((left, right) => {
        const leftTime = parseSignalDate(left.received_at)?.getTime() || 0
        const rightTime = parseSignalDate(right.received_at)?.getTime() || 0
        return rightTime - leftTime
      })
      setSignals(list)
      setErrorMessage('')
      try {
        localStorage.setItem(SIGNALS_CACHE_KEY, JSON.stringify(list))
      } catch {
        // 忽略缓存写入失败
      }
    } catch (error) {
      if (!silent) {
        setErrorMessage(error instanceof ApiError ? error.message : '获取信号失败，请稍后重试')
      }
    } finally {
      signalsInFlightRef.current = false
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    // 有缓存时首刷也走静默模式，不弹连接错误、不打断已渲染列表
    void fetchSignals(loadCachedSignals().length > 0)
    timerRef.current = window.setInterval(() => void fetchSignals(true), REFRESH_INTERVAL)

    const onResume = () => {
      if (document.visibilityState !== 'visible') return
      void fetchSignals(true)
    }
    window.addEventListener('app:resume', onResume as EventListener)
    window.addEventListener('online', onResume)
    document.addEventListener('visibilitychange', onResume)

    return () => {
      if (timerRef.current) window.clearInterval(timerRef.current)
      window.removeEventListener('app:resume', onResume as EventListener)
      window.removeEventListener('online', onResume)
      document.removeEventListener('visibilitychange', onResume)
    }
  }, [fetchSignals])

  // 下拉刷新触发：与持仓页一致的节流与状态复位节奏
  const refreshSignals = useCallback(async () => {
    if (isRefreshingRef.current) return
    isRefreshingRef.current = true
    setIsRefreshing(true)
    try {
      await fetchSignals()
    } finally {
      setTimeout(() => {
        isRefreshingRef.current = false
        setIsRefreshing(false)
        setPullDistance(0)
        setIsPulling(false)
      }, 200)
    }
  }, [fetchSignals])

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
        void refreshSignals()
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
  }, [refreshSignals])

  const refreshThreshold = 64
  const refreshIndicatorHeight = isRefreshing
    ? Math.max(refreshThreshold, pullDistance)
    : pullDistance
  const visibleSignals = signals.filter(item => item.source === activeTab)

  return (
    <div className="h-full flex flex-col max-w-md mx-auto overflow-hidden overscroll-none">
      {/* 顶部页签栏 - 延伸到状态栏区域 */}
      <div
        className="bg-t-surface"
        style={{
          paddingTop: standalone
            ? 'max(44px, env(safe-area-inset-top, 0px))'
            : 'env(safe-area-inset-top, 0px)',
        }}
      >
        <div
          className="relative flex border-b border-t-border"
          role="tablist"
          aria-label="信号来源"
        >
          {(
            [
              { key: 'external', label: '外部' },
              { key: 'internal', label: '内部' },
            ] as const
          ).map(tab => (
            <button
              key={tab.key}
              type="button"
              role="tab"
              aria-selected={activeTab === tab.key}
              onClick={() => setActiveTab(tab.key)}
              className={`flex-1 py-2.5 transition-colors ${
                activeTab === tab.key
                  ? 'text-[#F0B90B] border-b-2 border-[#F0B90B]'
                  : 'text-t-text-muted'
              }`}
            >
              {tab.label}
            </button>
          ))}
          <button
            onClick={() => setShowRulesModal(true)}
            aria-label="内部信号规则"
            className={`absolute right-2 top-1/2 z-10 -translate-y-1/2 w-8 h-8 items-center justify-center rounded-full transition-colors text-t-text-muted hover:bg-t-surface-hover ${activeTab === 'internal' ? 'flex' : 'hidden'}`}
          >
            <svg
              width="18"
              height="18"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
            >
              <circle cx="12" cy="12" r="10" />
              <path d="M12 16v-4" />
              <path d="M12 8h.01" />
            </svg>
          </button>
        </div>
      </div>

      <SignalRulesModal isOpen={showRulesModal} onClose={() => setShowRulesModal(false)} />

      {/* 可滚动内容区域（下拉刷新） */}
      <div
        ref={scrollRef}
        className="flex-1 min-h-0 overflow-y-scroll overscroll-contain hide-scrollbar bg-t-page"
        style={{
          WebkitOverflowScrolling: 'touch',
          overscrollBehaviorY: 'contain',
        }}
      >
        <div
          className={`flex items-center justify-center text-sm text-t-text-muted ${isPulling ? 'transition-none' : 'transition-all duration-150'}`}
          style={{ height: `${refreshIndicatorHeight}px` }}
        >
          {(isPulling || isRefreshing) && (
            <div className="flex items-center gap-2">
              <span className={`text-xl leading-none ${isRefreshing ? 'animate-spin' : ''}`}>
                ↻
              </span>
              <span>
                {isRefreshing
                  ? '刷新中...'
                  : pullDistance >= refreshThreshold
                    ? '释放刷新'
                    : '下拉刷新'}
              </span>
            </div>
          )}
        </div>
        <div
          className="p-4 space-y-2.5"
          style={{
            paddingBottom:
              'calc(24px + max(var(--app-safe-bottom, 0px), env(safe-area-inset-bottom, 0px)))',
          }}
        >
          {loading ? (
            <div className="pt-16 text-center text-sm text-t-text-muted">加载中...</div>
          ) : errorMessage ? (
            <div className="pt-16 text-center text-sm text-t-text-muted">{errorMessage}</div>
          ) : visibleSignals.length === 0 ? (
            <div className="pt-16 text-center text-sm text-t-text-muted">
              {activeTab === 'external' ? '暂无外部信号' : '暂无内部信号'}
            </div>
          ) : (
            visibleSignals.map(item => (
              <div
                key={item.id}
                role="button"
                tabIndex={0}
                onClick={() => openSignalKline(item)}
                onKeyDown={e => {
                  if (e.key === 'Enter' || e.key === ' ') {
                    e.preventDefault()
                    openSignalKline(item)
                  }
                }}
                className="rounded-lg p-3.5 transition-colors bg-t-surface border border-t-border active:bg-t-surface-hover cursor-pointer"
              >
                {/* 第一行：多/空标志 + 币种（自有附评分）+ 绝对及相对时间 */}
                <div className="flex items-center gap-2">
                  <DirectionBadge direction={item.direction} />
                  <span className="text-base font-semibold text-t-text">
                    {normalizeSignalSymbol(item.symbol) || item.symbol}
                  </span>
                  <SignalSourceBadge source={item.source} />
                  {item.source === 'internal' &&
                    item.score !== null &&
                    item.score !== undefined && (
                      <span className="text-xs font-medium text-[#F0B90B]">{item.score}分</span>
                    )}
                  {(() => {
                    const signalTime = item.signal_time || item.received_at
                    const absolute = formatSignalTime(signalTime)
                    const relative = formatRelativeTime(signalTime)
                    if (!absolute || !relative.text) return null
                    return (
                      <span className="ml-auto shrink-0 whitespace-nowrap text-right text-xs tabular-nums text-t-text-muted">
                        {absolute}
                        {' '}
                        <span className={relative.isRecent ? 'font-medium text-[#0ECB81]' : ''}>
                          「{relative.text}」
                        </span>
                      </span>
                    )
                  })()}
                </div>

                {item.source === 'internal' ? (
                  <>
                    {/* 自有扫描卡片：周期 + 策略类型 + 结论 */}
                    <div className="mt-2 flex flex-wrap items-center gap-1.5">
                      {item.interval ? (
                        <span className="shrink-0 px-1.5 py-0.5 rounded-md bg-t-surface-alt text-xs text-t-text-muted">
                          {item.interval}
                        </span>
                      ) : null}
                      <span className="text-sm text-t-text-secondary">{item.strategy}</span>
                      {item.final_action ? (
                        <span className="px-1.5 py-0.5 rounded text-xs font-medium bg-[#F0B90B]/10 text-[#F0B90B]">
                          {item.final_action}
                        </span>
                      ) : null}
                    </div>
                    {item.comment ? (
                      <div className="mt-1.5 text-sm text-t-text-secondary break-words">
                        {item.comment}
                      </div>
                    ) : null}
                    {item.entry_condition ? (
                      <div className="mt-1.5 text-xs leading-relaxed text-t-text-muted break-words">
                        触发条件：{item.entry_condition}
                      </div>
                    ) : null}
                    {(item.risk_points || []).length > 0 ? (
                      <div className="mt-1 text-xs leading-relaxed text-t-text-muted break-words">
                        风险：{(item.risk_points || []).join('；')}
                      </div>
                    ) : null}
                  </>
                ) : (
                  <>
                    <div className="mt-2 flex flex-wrap items-center gap-1.5 text-sm text-t-text-secondary">
                      {item.interval ? (
                        <span className="shrink-0 px-1.5 py-0.5 rounded-md bg-t-surface-alt text-xs text-t-text-muted">
                          {item.interval}
                        </span>
                      ) : null}
                      {item.strategy && item.strategy !== 'Unknown' ? (
                        <span>{item.strategy}</span>
                      ) : null}
                      {item.final_action ? (
                        <span className="px-1.5 py-0.5 rounded text-xs font-medium bg-[#F0B90B]/10 text-[#F0B90B]">
                          {item.final_action}
                        </span>
                      ) : null}
                      {item.price_display && item.price_display !== 'N/A' ? (
                        <span className="ml-auto font-medium text-t-text">
                          {item.price_display}
                        </span>
                      ) : null}
                    </div>
                    {item.comment || (item.title && item.title !== '外部信号') ? (
                      <div className="mt-1.5 break-words text-sm text-t-text-secondary">
                        {item.comment || item.title}
                      </div>
                    ) : null}
                    {item.entry_condition ? (
                      <div className="mt-1.5 text-xs leading-relaxed text-t-text-muted break-words">
                        触发条件：{item.entry_condition}
                      </div>
                    ) : null}
                    {(item.risk_points || []).length > 0 ? (
                      <div className="mt-1 text-xs leading-relaxed text-t-text-muted break-words">
                        风险：{(item.risk_points || []).join('；')}
                      </div>
                    ) : null}
                  </>
                )}
              </div>
            ))
          )}
        </div>
      </div>

      {/* 信号 K 线图弹窗：当前页内弹出，底部长按钮“去开仓”跳转开仓页 */}
      {klineSymbol && (
        <Suspense fallback={null}>
          <KlineChartCard
            entry="none"
            open
            onOpenChange={open => {
              if (!open) setKlineSymbol('')
            }}
            symbol={klineSymbol}
            bottomAction={{ label: '去开仓', onClick: gotoTrading }}
          />
        </Suspense>
      )}
    </div>
  )
}

export default SignalsPage
