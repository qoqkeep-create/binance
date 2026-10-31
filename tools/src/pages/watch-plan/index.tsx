import { useEffect, useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { ArrowLeft, CheckCircle2, Check, ChevronDown, Pencil, Trash2, X } from 'lucide-react'

import { api } from '@/shared/lib/api'
import { CURATED_TRADING_SYMBOLS, PINNED_TRADING_SYMBOL_SET } from '@/shared/constants'
import { showToast } from '@/shared/store/toastStore'

type Timeframe = '15m' | '1h' | '4h' | '1d'

interface WatchPlanItem {
  id: number
  symbol: string
  plan_date: string
  plan_type: 0 | 1
  timeframe: Timeframe
  direction: 0 | 1
  content: string
  take_profit_expectation: string
  review_content: string
  status: 0 | 1 | 2
  result: 0 | 1 | 2
  result_amount: string
  score: number | null
  score_payload: {
    checks?: string[]
    vetoes?: string[]
  }
  created_at: string
  updated_at: string
}

type PlanType = 0 | 1

type ScoreItem = {
  key: string
  label: string
  points: number
}

type ScoreSection = {
  title: string
  items: ScoreItem[]
}

type ScoreGradeMeta = {
  label: string
  tone: string
  subTone: string
}

type ScoreSectionSummary = {
  title: string
  score: number
}

const TIMEFRAME_OPTIONS: Array<{ value: Timeframe; label: string }> = [
  { value: '15m', label: '15分钟' },
  { value: '1h', label: '1小时' },
  { value: '4h', label: '4小时' },
  { value: '1d', label: '1天' },
]

const TRADING_SYMBOLS_CACHE_KEY = 'tradetools:trading:symbols:v3'

const TREND_SCORE_SECTION: ScoreSection = {
  title: '趋势背景（20分）',
  items: [
    { key: 'trend-direction', label: '大周期方向明确，1D / 4H 与交易方向一致', points: 10 },
    { key: 'trend-ema-order', label: 'EMA21 / 55 / 144 顺向排列', points: 5 },
    { key: 'trend-not-chasing', label: '均线发散不极端，价格不是远离均线后追入', points: 5 },
  ],
}

const POSITION_SCORE_SECTION: ScoreSection = {
  title: '位置质量（25分）',
  items: [
    { key: 'position-structure', label: '价格处在关键支撑/压力/前高前低/结构位', points: 10 },
    { key: 'position-ema144', label: '回踩到 EMA144 或核心均线区域', points: 7 },
    { key: 'position-fib', label: 'Fib 0.618 / 0.786 与 EMA144 / 结构位重合', points: 5 },
    { key: 'position-not-middle', label: '不是震荡区中间，不是无意义位置', points: 3 },
  ],
}

const RIGHT_ENTRY_SCORE_SECTION: ScoreSection = {
  title: '入场触发（20分）',
  items: [
    { key: 'entry-right-reversal', label: '已出现明确反转 K 线', points: 8 },
    { key: 'entry-right-zone', label: '反转 K 线位置正好在关键区域', points: 5 },
    { key: 'entry-right-stop-clear', label: '反转 K 线止损点清晰', points: 4 },
    { key: 'entry-right-r-space', label: '入场后仍有足够 R 值空间', points: 3 },
  ],
}

const LEFT_ENTRY_SCORE_SECTION: ScoreSection = {
  title: '入场触发（20分）',
  items: [
    { key: 'entry-left-planned', label: '是提前计划好的左侧关键位，不是临场接刀', points: 7 },
    { key: 'entry-left-confluence', label: 'EMA144 + Fib / 结构位强共振', points: 6 },
    { key: 'entry-left-stop-clear', label: '止损放在明确失效位，比如 Fib 1 / 结构破位', points: 4 },
    { key: 'entry-left-risk-limited', label: '左侧只占部分风险，或总风险被程序严格限制', points: 3 },
  ],
}

const RISK_SCORE_SECTION: ScoreSection = {
  title: '风险收益结构（20分）',
  items: [
    { key: 'risk-stop-clear', label: '止损位置明确，不需要临场调整', points: 5 },
    { key: 'risk-two-r', label: '到前高/前低至少 ≥ 2R', points: 6 },
    { key: 'risk-three-five-r', label: '有可能走到 3R - 5R，适合趋势仓', points: 4 },
    { key: 'risk-fixed-amount', label: '单笔风险金额固定，不因信心提高', points: 3 },
    { key: 'risk-auto-tp', label: '交易后能自动执行 30-20-50 止盈', points: 2 },
  ],
}

const MINDSET_SCORE_SECTION: ScoreSection = {
  title: '清晰度 / 心理状态（15分）',
  items: [
    { key: 'mind-clear', label: '一眼能看懂，不需要反复分析', points: 6 },
    { key: 'mind-not-revenge', label: '不是因为亏损后想补回来', points: 3 },
    { key: 'mind-not-greed', label: '不是因为盈利后没赢够', points: 3 },
    { key: 'mind-not-fomo', label: '不是因为错过后想重新参与', points: 3 },
  ],
}

const SCORE_VETO_ITEMS: ScoreItem[] = [
  { key: 'veto-trend-unclear', label: '大周期方向不明确', points: 0 },
  { key: 'veto-no-key-level', label: '不在关键位置，只有局部信号', points: 0 },
  { key: 'veto-less-than-2r', label: '预期空间不足 2R', points: 0 },
  { key: 'veto-emotional', label: '情绪驱动想做，不是按系统做', points: 0 },
]

function getTodayDateValue() {
  const now = new Date()
  const year = now.getFullYear()
  const month = `${now.getMonth() + 1}`.padStart(2, '0')
  const day = `${now.getDate()}`.padStart(2, '0')
  return `${year}-${month}-${day}`
}

function formatDirection(direction: 0 | 1) {
  return direction === 0 ? '多' : '空'
}

function formatPlanType(planType: 0 | 1) {
  return planType === 1 ? '确认右侧单' : '计划左侧单'
}

function formatStatus(status: 0 | 1 | 2) {
  return status === 1 ? '已做' : '未做'
}

function formatResultAmountDisplay(result: 0 | 1 | 2, amount?: string) {
  const raw = String(amount || '').trim()
  if (!raw || result === 0) return ''
  const numeric = Number(raw)
  if (!Number.isFinite(numeric) || numeric < 0) return ''
  const rendered = Number.isInteger(numeric) ? `${numeric}` : `${numeric}`
  if (result === 1) return `止损：-${rendered}U`
  if (result === 2) return `止盈：+${rendered}U`
  return ''
}

function formatCreatedAt(value?: string) {
  if (!value) return '-'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return '-'
  const year = date.getFullYear()
  const month = `${date.getMonth() + 1}`.padStart(2, '0')
  const day = `${date.getDate()}`.padStart(2, '0')
  const hours = `${date.getHours()}`.padStart(2, '0')
  const minutes = `${date.getMinutes()}`.padStart(2, '0')
  return `${year}-${month}-${day} ${hours}:${minutes}`
}

function getScoreSections(planType: PlanType): ScoreSection[] {
  return [
    TREND_SCORE_SECTION,
    POSITION_SCORE_SECTION,
    planType === 1 ? RIGHT_ENTRY_SCORE_SECTION : LEFT_ENTRY_SCORE_SECTION,
    RISK_SCORE_SECTION,
    MINDSET_SCORE_SECTION,
  ]
}

function parseScorePayload(payload: WatchPlanItem['score_payload'] | undefined) {
  const checks = new Set(Array.isArray(payload?.checks) ? payload?.checks : [])
  const vetoes = new Set(Array.isArray(payload?.vetoes) ? payload?.vetoes : [])
  return { checks, vetoes }
}

function calculateScore(planType: PlanType, selectedChecks: Set<string>, selectedVetoes: Set<string>) {
  const sections = getScoreSections(planType)
  const total = sections
    .flatMap(section => section.items)
    .reduce((sum, item) => sum + (selectedChecks.has(item.key) ? item.points : 0), 0)
  const hasVeto = SCORE_VETO_ITEMS.some(item => selectedVetoes.has(item.key))
  return { total, hasVeto }
}

function calculateSectionScores(planType: PlanType, selectedChecks: Set<string>): ScoreSectionSummary[] {
  return getScoreSections(planType).map(section => ({
    title: section.title.replace(/（.*?）/g, ''),
    score: section.items.reduce((sum, item) => sum + (selectedChecks.has(item.key) ? item.points : 0), 0),
  }))
}

function getScoreMeta(score: number | null, hasVeto: boolean): ScoreGradeMeta {
  if (hasVeto) {
    return {
      label: '否决',
      tone: 'bg-[#F6465D]/12 text-[#F6465D] border-[#F6465D]/25',
      subTone: 'text-[#F6465D]',
    }
  }
  if (score === null) {
    return {
      label: '未评分',
      tone: 'bg-t-page text-t-text-muted border-t-border',
      subTone: 'text-t-text-muted',
    }
  }
  if (score >= 90) {
    return {
      label: 'S级',
      tone: 'bg-[#0ECB81]/12 text-[#0ECB81] border-[#0ECB81]/25',
      subTone: 'text-[#0ECB81]',
    }
  }
  if (score >= 80) {
    return {
      label: 'A级',
      tone: 'bg-[#F0B90B]/14 text-[#C48B00] border-[#F0B90B]/25',
      subTone: 'text-[#C48B00]',
    }
  }
  return {
    label: '观察',
    tone: 'bg-[#F6465D]/12 text-[#F6465D] border-[#F6465D]/25',
    subTone: 'text-[#F6465D]',
  }
}

function loadCachedSymbols(): string[] {
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
  try {
    window.localStorage.setItem(TRADING_SYMBOLS_CACHE_KEY, JSON.stringify(symbols))
  } catch {
    // ignore
  }
}

function buildBinanceFuturesUrl(symbol: string) {
  const cleaned = String(symbol || '').trim().toUpperCase()
  return `https://www.binance.com/zh-CN/futures/${encodeURIComponent(cleaned)}`
}

export function WatchPlanPage() {
  const navigate = useNavigate()

  const [items, setItems] = useState<WatchPlanItem[]>([])
  const [loading, setLoading] = useState(true)
  const [submitting, setSubmitting] = useState(false)

  const [editingId, setEditingId] = useState<number | null>(null)
  const [symbol, setSymbol] = useState('')
  const [planDate, setPlanDate] = useState(getTodayDateValue())
  const [planType, setPlanType] = useState<0 | 1>(0)
  const [timeframe, setTimeframe] = useState<Timeframe>('1h')
  const [direction, setDirection] = useState<0 | 1>(0)
  const [content, setContent] = useState('')
  const [takeProfitExpectation, setTakeProfitExpectation] = useState('')

  const [symbolList, setSymbolList] = useState<string[]>(() => {
    const cached = loadCachedSymbols()
    return cached.length > 0 ? cached : [...CURATED_TRADING_SYMBOLS]
  })
  const [showEditorModal, setShowEditorModal] = useState(false)
  const [showPairSelector, setShowPairSelector] = useState(false)
  const [pairSearch, setPairSearch] = useState('')

  const [reviewTarget, setReviewTarget] = useState<WatchPlanItem | null>(null)
  const [reviewDraft, setReviewDraft] = useState('')
  const [resultTarget, setResultTarget] = useState<WatchPlanItem | null>(null)
  const [resultDraft, setResultDraft] = useState<0 | 1 | 2>(0)
  const [resultAmountDraft, setResultAmountDraft] = useState('')
  const [scoreTarget, setScoreTarget] = useState<WatchPlanItem | null>(null)
  const [scoreChecks, setScoreChecks] = useState<Set<string>>(new Set())
  const [scoreVetoes, setScoreVetoes] = useState<Set<string>>(new Set())
  const [directionFilter, setDirectionFilter] = useState<'all' | 'long' | 'short'>('all')
  const [planTypeFilter, setPlanTypeFilter] = useState<'all' | 'left' | 'right'>('all')
  const [timeframeFilter, setTimeframeFilter] = useState<'all' | Timeframe>('all')
  const [statusFilter, setStatusFilter] = useState<'all' | 'done' | 'undone'>('all')
  const [reviewFilter, setReviewFilter] = useState<'all' | 'reviewed' | 'unreviewed'>('all')

  const timeframeLabelMap = useMemo(() => {
    return TIMEFRAME_OPTIONS.reduce<Record<string, string>>((acc, item) => {
      acc[item.value] = item.label
      return acc
    }, {})
  }, [])

  const filteredPairs = useMemo(() => {
    const term = pairSearch.trim().toLowerCase()
    if (!term) return symbolList
    return symbolList.filter(pair => pair.toLowerCase().includes(term))
  }, [pairSearch, symbolList])

  const filteredItems = useMemo(() => {
    return items.filter(item => {
      if (planTypeFilter === 'left' && item.plan_type !== 0) return false
      if (planTypeFilter === 'right' && item.plan_type !== 1) return false

      if (directionFilter === 'long' && item.direction !== 0) return false
      if (directionFilter === 'short' && item.direction !== 1) return false

      if (timeframeFilter !== 'all' && item.timeframe !== timeframeFilter) return false

      if (statusFilter === 'done' && item.status !== 1) return false
      if (statusFilter === 'undone' && item.status === 1) return false

      if (reviewFilter !== 'all') {
        if (item.status !== 1) return false
        const hasReview = Boolean((item.review_content || '').trim())
        if (reviewFilter === 'reviewed' && !hasReview) return false
        if (reviewFilter === 'unreviewed' && hasReview) return false
      }

      return true
    })
  }, [directionFilter, items, planTypeFilter, reviewFilter, statusFilter, timeframeFilter])

  async function refresh() {
    setLoading(true)
    try {
      const rows = await api.get<WatchPlanItem[]>('/watch-plan/list')
      setItems(Array.isArray(rows) ? rows : [])
    } catch (err) {
      showToast(err instanceof Error ? err.message : '加载失败')
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    refresh()
  }, [])

  useEffect(() => {
    const loadSymbols = async () => {
      try {
        const symbols = await api.get<string[]>('/trade/symbols', {
          suppressConnectionError: true,
          disableRetry: true,
          timeout: 8000,
        })
        if (Array.isArray(symbols) && symbols.length > 0) {
          setSymbolList(symbols)
          saveCachedSymbols(symbols)
        }
      } catch {
        // ignore
      }
    }
    loadSymbols()
  }, [])

  function resetEditor() {
    setEditingId(null)
    setSymbol('')
    setPlanDate(getTodayDateValue())
    setPlanType(0)
    setTimeframe('1h')
    setDirection(0)
    setContent('')
    setTakeProfitExpectation('')
  }

  async function upsert() {
    const cleanedSymbol = symbol.trim().toUpperCase()
    if (!cleanedSymbol) {
      showToast('交易对不能为空')
      return
    }
    if (!content.trim()) {
      showToast('内容不能为空')
      return
    }
    setSubmitting(true)
    try {
      if (editingId) {
        const row = await api.post<WatchPlanItem>('/watch-plan/update', {
          id: editingId,
          symbol: cleanedSymbol,
          plan_date: planDate,
          plan_type: planType,
          timeframe,
          direction,
          content: content.trim(),
          take_profit_expectation: takeProfitExpectation.trim(),
        })
        setItems(prev => prev.map(item => (item.id === editingId ? row : item)))
        setShowEditorModal(false)
        resetEditor()
        showToast('已保存')
      } else {
        const row = await api.post<WatchPlanItem>('/watch-plan/create', {
          symbol: cleanedSymbol,
          plan_date: planDate,
          plan_type: planType,
          timeframe,
          direction,
          content: content.trim(),
          take_profit_expectation: takeProfitExpectation.trim(),
        })
        setItems(prev => [row, ...prev])
        setShowEditorModal(false)
        resetEditor()
        showToast('已创建')
      }
    } catch (err) {
      showToast(err instanceof Error ? err.message : '提交失败')
    } finally {
      setSubmitting(false)
    }
  }

  async function updateItem(id: number, payload: Partial<Pick<WatchPlanItem, 'status' | 'result' | 'review_content'>>) {
    try {
      const row = await api.post<WatchPlanItem>('/watch-plan/update', { id, ...payload })
      setItems(prev => prev.map(item => (item.id === id ? row : item)))
    } catch (err) {
      showToast(err instanceof Error ? err.message : '更新失败')
    }
  }

  async function removeItem(id: number) {
    try {
      await api.post('/watch-plan/delete', { id })
      setItems(prev => prev.filter(item => item.id !== id))
      showToast('已删除')
    } catch (err) {
      showToast(err instanceof Error ? err.message : '删除失败')
    }
  }

  function openMarket(symbolText: string) {
    const url = buildBinanceFuturesUrl(symbolText)
    window.open(url, '_blank', 'noopener,noreferrer')
  }

  function openResultModal(item: WatchPlanItem) {
    setResultTarget(item)
    setResultDraft(item.result)
    setResultAmountDraft(item.result_amount || '')
  }

  function openScoreModal(item: WatchPlanItem) {
    const parsed = parseScorePayload(item.score_payload)
    setScoreTarget(item)
    setScoreChecks(parsed.checks)
    setScoreVetoes(parsed.vetoes)
  }

  async function saveScore() {
    if (!scoreTarget) return
    const payload = {
      checks: Array.from(scoreChecks),
      vetoes: Array.from(scoreVetoes),
    }
    const scoreResult = calculateScore(scoreTarget.plan_type, scoreChecks, scoreVetoes)
    try {
      const row = await api.post<WatchPlanItem>('/watch-plan/update', {
        id: scoreTarget.id,
        score: scoreResult.total,
        score_payload: payload,
      })
      setItems(prev => prev.map(item => (item.id === row.id ? row : item)))
      setScoreTarget(null)
      setScoreChecks(new Set())
      setScoreVetoes(new Set())
      showToast('评分已保存')
    } catch (err) {
      showToast(err instanceof Error ? err.message : '评分保存失败')
    }
  }

  async function saveResult() {
    if (!resultTarget) return
    if (resultDraft === 0) {
      showToast('请选择止盈或止损')
      return
    }
    const trimmedAmount = resultAmountDraft.trim()
    let payloadAmount = ''
    if (trimmedAmount) {
      const numeric = Number(trimmedAmount)
      if (!Number.isFinite(numeric) || numeric < 0) {
        showToast('请输入大于或等于0的金额')
        return
      }
      payloadAmount = String(numeric)
    }
    try {
      const row = await api.post<WatchPlanItem>('/watch-plan/update', {
        id: resultTarget.id,
        result: resultDraft,
        result_amount: payloadAmount,
      })
      setItems(prev => prev.map(item => (item.id === row.id ? row : item)))
      setResultTarget(null)
      setResultDraft(0)
      setResultAmountDraft('')
      showToast('已保存')
    } catch (err) {
      showToast(err instanceof Error ? err.message : '保存失败')
    }
  }

  return (
    <div className="min-h-screen bg-t-page text-t-text">
      <div className="sticky top-0 z-10 border-b border-t-border bg-t-page/95 backdrop-blur">
        <div className="mx-auto w-full max-w-[1480px] px-4 py-3 flex items-center gap-3">
          <button
            onClick={() => navigate('/profile', { replace: true })}
            className="inline-flex items-center gap-2 rounded-lg px-2.5 py-1.5 text-sm font-medium hover:bg-t-surface-hover"
          >
            <ArrowLeft size={18} />
            返回
          </button>
          <div className="text-lg font-bold">看盘计划</div>
          <div className="flex-1" />
          <button
            onClick={refresh}
            className="rounded-lg px-3 py-1.5 text-sm font-medium bg-t-surface hover:bg-t-surface-hover border border-t-border"
          >
            刷新
          </button>
        </div>
      </div>

      <div className="mx-auto w-full max-w-[1480px] px-4 py-4">
          <div className="rounded-2xl border border-t-border bg-t-surface shadow-sm">
            <div className="px-5 py-4 border-b border-t-border flex items-center gap-2">
              <CheckCircle2 size={18} className="text-t-text-muted" />
              <div className="font-semibold">记录</div>
              <div className="ml-4 flex flex-wrap items-center gap-2">
                <select
                  value={planTypeFilter}
                  onChange={e => setPlanTypeFilter(e.target.value as 'all' | 'left' | 'right')}
                  className="rounded-xl px-3 py-2 text-sm bg-t-page border border-t-border focus:outline-none focus:ring-2 focus:ring-[#F0B90B]/40"
                >
                  <option value="all">左右侧单</option>
                  <option value="left">计划左侧单</option>
                  <option value="right">确认右侧单</option>
                </select>
                <select
                  value={directionFilter}
                  onChange={e => setDirectionFilter(e.target.value as 'all' | 'long' | 'short')}
                  className="rounded-xl px-3 py-2 text-sm bg-t-page border border-t-border focus:outline-none focus:ring-2 focus:ring-[#F0B90B]/40"
                >
                  <option value="all">多空筛选</option>
                  <option value="long">只看做多</option>
                  <option value="short">只看做空</option>
                </select>
                <select
                  value={timeframeFilter}
                  onChange={e => setTimeframeFilter(e.target.value as 'all' | Timeframe)}
                  className="rounded-xl px-3 py-2 text-sm bg-t-page border border-t-border focus:outline-none focus:ring-2 focus:ring-[#F0B90B]/40"
                >
                  <option value="all">周期筛选</option>
                  {TIMEFRAME_OPTIONS.map(option => (
                    <option key={option.value} value={option.value}>
                      {option.label}
                    </option>
                  ))}
                </select>
                <select
                  value={statusFilter}
                  onChange={e => setStatusFilter(e.target.value as 'all' | 'done' | 'undone')}
                  className="rounded-xl px-3 py-2 text-sm bg-t-page border border-t-border focus:outline-none focus:ring-2 focus:ring-[#F0B90B]/40"
                >
                  <option value="all">状态筛选</option>
                  <option value="done">已做</option>
                  <option value="undone">未做</option>
                </select>
                <select
                  value={reviewFilter}
                  onChange={e => setReviewFilter(e.target.value as 'all' | 'reviewed' | 'unreviewed')}
                  className="rounded-xl px-3 py-2 text-sm bg-t-page border border-t-border focus:outline-none focus:ring-2 focus:ring-[#F0B90B]/40"
                >
                  <option value="all">是否复盘</option>
                  <option value="reviewed">已复盘</option>
                  <option value="unreviewed">未复盘</option>
                </select>
              </div>
              <div className="ml-auto text-sm text-t-text-muted">
                {loading ? '加载中…' : `${filteredItems.length} 条`}
              </div>
              <button
                type="button"
                onClick={() => {
                  resetEditor()
                  setShowEditorModal(true)
                }}
                className="ml-3 rounded-lg px-4 py-2 text-sm font-bold bg-[#F0B90B] text-black hover:bg-[#D9A70A]"
              >
                写计划
              </button>
            </div>
            <div className="p-5">
              <div className="overflow-x-auto">
                <div className="min-w-[1120px]">
                  <div className="grid grid-cols-[120px_120px_minmax(280px,1fr)_minmax(220px,1fr)_220px_150px] gap-3 px-3 py-2 text-xs font-semibold text-t-text-muted">
                    <div>交易对</div>
                    <div>周期/方向</div>
                    <div>内容</div>
                    <div>复盘</div>
                    <div>类型/状态/结果</div>
                    <div className="text-right">操作/时间</div>
                  </div>
                  <div className="h-px bg-t-border" />
                  {filteredItems.length === 0 ? (
                    <div className="px-3 py-10 text-center text-sm text-t-text-muted">
                      {items.length === 0 ? '暂无记录' : '暂无符合筛选条件的记录'}
                    </div>
                  ) : (
                    filteredItems.map(item => {
                      const statusText = formatStatus(item.status)
                      const isDone = item.status === 1
                      const combo = `${timeframeLabelMap[item.timeframe]}/${formatDirection(item.direction)}`
                      const planTypeText = formatPlanType(item.plan_type)
                      const resultAmountText = isDone ? formatResultAmountDisplay(item.result, item.result_amount) : ''
                      const parsedScorePayload = parseScorePayload(item.score_payload)
                      const scoreSummary = calculateScore(item.plan_type, parsedScorePayload.checks, parsedScorePayload.vetoes)
                      const scoreMeta = getScoreMeta(item.score, scoreSummary.hasVeto)
                      const planTypeTone = item.plan_type === 1
                        ? 'bg-[#FF8A1F]/14 text-[#C76500]'
                        : 'bg-[#8B5CF6]/14 text-[#6D3CE5]'
                      const directionTone = item.direction === 0
                        ? 'bg-[#0ECB81]/12 text-[#0A8F63]'
                        : 'bg-[#F6465D]/12 text-[#C63C52]'
                      return (
                        <div key={item.id} className="border-b border-t-border last:border-b-0">
                          <div className="grid grid-cols-[120px_120px_minmax(280px,1fr)_minmax(220px,1fr)_220px_150px] gap-3 px-3 py-3 items-start">
                            <div>
                              <button
                                type="button"
                                onClick={() => openMarket(item.symbol)}
                                className="font-semibold underline underline-offset-4 decoration-from-font hover:text-[#F0B90B]"
                              >
                                {item.symbol}
                              </button>
                            </div>
                            <div>
                              <div className={`inline-flex rounded-lg px-2.5 py-1 text-sm font-semibold ${directionTone}`}>
                                {combo}
                              </div>
                            </div>
                            <div className="space-y-2">
                              <div className="max-w-full rounded-xl bg-[#0ECB81]/10 px-3 py-2 text-sm text-[#157A59]">
                                <div className="whitespace-pre-wrap break-words">
                                  <span className="mr-1 font-semibold">指标和入场理由</span>
                                  {item.content || <span className="text-[#5E9B84]">未填写</span>}
                                </div>
                              </div>
                              <div className="max-w-full rounded-xl bg-[#0ECB81]/10 px-3 py-2 text-sm text-[#157A59]">
                                <div className="whitespace-pre-wrap break-words">
                                  <span className="mr-1 font-semibold">止盈预期</span>
                                  {item.take_profit_expectation || <span className="text-[#5E9B84]">未填写</span>}
                                </div>
                              </div>
                            </div>
                            <div>
                              <div className="inline-flex max-w-full items-end gap-1.5 rounded-xl bg-[#4C8DFF]/10 px-3 py-2 text-sm whitespace-pre-wrap break-words text-[#356ED8]">
                                <div className="min-w-0">
                                  {item.review_content ? item.review_content : <span className="text-[#6C88C9]">未填写</span>}
                                </div>
                                <button
                                  onClick={() => { setReviewTarget(item); setReviewDraft(item.review_content || '') }}
                                  className="flex-none rounded-md p-1 hover:bg-[#4C8DFF]/10 text-[#5C7FC9]"
                                  title="编辑复盘"
                                  aria-label="编辑复盘"
                                >
                                  <Pencil size={14} />
                                </button>
                              </div>
                            </div>
                            <div>
                              <div className="flex flex-wrap items-center gap-2">
                                <div className={`inline-flex rounded-lg px-2 py-1 text-xs font-bold ${planTypeTone}`}>
                                  {planTypeText}
                                </div>
                                <span
                                  className={`inline-flex px-2 py-1 rounded-lg text-xs font-bold ${
                                    isDone
                                      ? 'bg-[#0ECB81]/15 text-[#0ECB81]'
                                      : 'bg-t-surface-hover text-t-text-muted'
                                  }`}
                                >
                                  {statusText}
                                </span>
                              </div>
                              {isDone ? (
                                resultAmountText ? (
                                  <button
                                    type="button"
                                    onClick={() => openResultModal(item)}
                                    className={`mt-2 block text-left text-xs font-semibold ${
                                      item.result === 1 ? 'text-[#F6465D]' : 'text-[#0ECB81]'
                                    } hover:underline`}
                                  >
                                    {resultAmountText}
                                  </button>
                                ) : (
                                  <button
                                    type="button"
                                    onClick={() => openResultModal(item)}
                                    className="mt-2 inline-flex rounded-lg px-2.5 py-1 text-xs font-bold border border-t-border hover:bg-t-surface-hover"
                                  >
                                    止盈止损
                                  </button>
                                )
                              ) : null}
                            </div>
                            <div>
                              <div className="grid grid-cols-3 gap-2 justify-items-end">
                              <button
                                onClick={() => {
                                  const next = item.status === 1 ? 0 : 1
                                  void updateItem(item.id, { status: next })
                                }}
                                className={`inline-flex h-9 w-9 items-center justify-center rounded-lg border text-xs font-bold ${
                                  item.status === 1
                                    ? 'border-[#0ECB81]/20 bg-[#0ECB81]/15 text-[#0ECB81]'
                                    : 'border-t-border hover:bg-t-surface-hover'
                                }`}
                                title="切换已做"
                                aria-label="切换已做"
                              >
                                <Check size={16} />
                              </button>
                              <button
                                onClick={() => {
                                  setEditingId(item.id)
                                  setSymbol(item.symbol)
                                  setPlanDate(item.plan_date || getTodayDateValue())
                                  setPlanType(item.plan_type ?? 0)
                                  setTimeframe(item.timeframe)
                                  setDirection(item.direction)
                                  setContent(item.content || '')
                                  setTakeProfitExpectation(item.take_profit_expectation || '')
                                  setShowEditorModal(true)
                                }}
                                className="inline-flex h-9 w-9 items-center justify-center rounded-lg border border-t-border hover:bg-t-surface-hover"
                                title="编辑"
                                aria-label="编辑"
                              >
                                <Pencil size={15} />
                              </button>
                              <button
                                onClick={() => {
                                  if (!window.confirm('确定删除这条记录？')) return
                                  void removeItem(item.id)
                                }}
                                className="inline-flex h-9 w-9 items-center justify-center rounded-lg border border-[#F6465D]/30 bg-[#F6465D]/10 text-[#F6465D] hover:bg-[#F6465D]/15"
                                title="删除"
                                aria-label="删除"
                              >
                                <Trash2 size={15} />
                              </button>
                              </div>
                              <button
                                type="button"
                                onClick={() => openScoreModal(item)}
                                className={`mt-3 w-full rounded-xl border px-3 py-2 text-center ${scoreMeta.tone}`}
                              >
                                {item.score === null ? (
                                  <span className="text-sm font-bold">未评分</span>
                                ) : (
                                  <div>
                                    <div className="text-2xl font-black leading-none">{item.score}分</div>
                                    <div className={`mt-1 text-[11px] font-bold ${scoreMeta.subTone}`}>
                                      {scoreMeta.label}
                                    </div>
                                  </div>
                                )}
                              </button>
                              <div className="mt-2 text-right text-xs text-t-text-muted">{formatCreatedAt(item.created_at)}</div>
                            </div>
                          </div>
                        </div>
                      )
                    })
                  )}
                </div>
              </div>
            </div>
          </div>
      </div>

      {showPairSelector ? (
        <div className="fixed inset-0 z-[70] flex items-center justify-center p-4">
          <div className="absolute inset-0 bg-black/60 backdrop-blur-sm" onClick={() => setShowPairSelector(false)} />
          <div className="relative w-full max-w-2xl rounded-2xl overflow-hidden border border-t-border bg-t-modal shadow-2xl">
            <div className="px-5 py-4 border-b border-t-border flex items-center gap-3">
              <div className="font-bold">选择交易对</div>
              <div className="flex-1" />
              <button
                onClick={() => setShowPairSelector(false)}
                className="rounded-lg p-2 hover:bg-t-surface-hover"
              >
                <X size={18} />
              </button>
            </div>
            <div className="p-5 space-y-4">
              <input
                value={pairSearch}
                onChange={e => setPairSearch(e.target.value)}
                placeholder="搜索交易对…"
                className="w-full rounded-xl px-3 py-2 bg-t-page border border-t-border focus:outline-none focus:ring-2 focus:ring-[#F0B90B]/40"
              />
              <div className="max-h-[55vh] overflow-y-auto border border-t-border rounded-xl bg-t-page">
                {filteredPairs.map(pair => (
                  <button
                    key={pair}
                    onClick={() => { setSymbol(pair); setShowPairSelector(false) }}
                    className={`w-full text-left px-4 py-3 border-b border-t-border last:border-b-0 hover:bg-t-surface-hover ${
                      pair === symbol ? 'text-[#F0B90B] font-bold' : ''
                    }`}
                  >
                    <div className="flex items-center justify-between gap-3">
                      <span>{pair}</span>
                      {PINNED_TRADING_SYMBOL_SET.has(pair) ? (
                        <span className="rounded-full bg-[#F0B90B]/12 px-2 py-0.5 text-xs font-semibold text-[#B78103]">
                          当前精选
                        </span>
                      ) : null}
                    </div>
                  </button>
                ))}
              </div>
            </div>
          </div>
        </div>
      ) : null}

      {showEditorModal ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div className="absolute inset-0 bg-black/60 backdrop-blur-sm" onClick={() => {
            setShowEditorModal(false)
            resetEditor()
          }} />
          <div className="relative w-full max-w-5xl rounded-2xl overflow-hidden border border-t-border bg-t-modal shadow-2xl">
            <div className="px-5 py-4 border-b border-t-border flex items-center gap-2">
              <div className="font-bold">{editingId ? '编辑计划' : '写计划'}</div>
              {editingId ? (
                <div className="text-sm font-semibold text-[#F0B90B]">#{editingId}</div>
              ) : null}
              <div className="flex-1" />
              <button
                onClick={() => {
                  setShowEditorModal(false)
                  resetEditor()
                }}
                className="rounded-lg p-2 hover:bg-t-surface-hover"
              >
                <X size={18} />
              </button>
            </div>
            <div className="p-5 grid grid-cols-12 gap-4">
              <div className="col-span-2">
                <div className="text-sm font-medium text-t-text-secondary mb-2">交易对</div>
                <button
                  onClick={() => setShowPairSelector(true)}
                  className="w-full rounded-xl px-3 py-2 bg-t-page border border-t-border hover:bg-t-surface-hover text-left flex items-center justify-between"
                >
                  <span className={symbol ? 'font-semibold' : 'text-t-text-muted'}>{symbol || '点击选择/搜索'}</span>
                  <ChevronDown size={16} className="text-t-text-muted" />
                </button>
              </div>
              <div className="col-span-3">
                <div className="text-sm font-medium text-t-text-secondary mb-2">类型</div>
                <div className="inline-flex rounded-xl border border-t-border overflow-hidden bg-t-page">
                  <button
                    onClick={() => setPlanType(0)}
                    className={`px-4 py-2 text-sm font-semibold whitespace-nowrap transition-colors ${
                      planType === 0 ? 'bg-[#8B5CF6]/15 text-[#6D3CE5]' : 'hover:bg-t-surface-hover text-t-text'
                    }`}
                  >
                    计划左侧单
                  </button>
                  <button
                    onClick={() => setPlanType(1)}
                    className={`px-4 py-2 text-sm font-semibold whitespace-nowrap transition-colors ${
                      planType === 1 ? 'bg-[#FF8A1F]/15 text-[#C76500]' : 'hover:bg-t-surface-hover text-t-text'
                    }`}
                  >
                    确认右侧单
                  </button>
                </div>
              </div>
              <div className="col-span-2">
                <div className="text-sm font-medium text-t-text-secondary mb-2">周期</div>
                <select
                  value={timeframe}
                  onChange={e => setTimeframe(e.target.value as Timeframe)}
                  className="w-full rounded-xl px-3 py-2 bg-t-page border border-t-border focus:outline-none focus:ring-2 focus:ring-[#F0B90B]/40"
                >
                  {TIMEFRAME_OPTIONS.map(option => (
                    <option key={option.value} value={option.value}>
                      {option.label}
                    </option>
                  ))}
                </select>
              </div>
              <div className="col-span-2">
                <div className="text-sm font-medium text-t-text-secondary mb-2">方向</div>
                <div className="inline-flex rounded-xl border border-t-border overflow-hidden bg-t-page">
                  <button
                    onClick={() => setDirection(0)}
                    className={`px-4 py-2 text-sm font-semibold transition-colors ${
                      direction === 0 ? 'bg-[#0ECB81]/15 text-[#0ECB81]' : 'hover:bg-t-surface-hover text-t-text'
                    }`}
                  >
                    多
                  </button>
                  <button
                    onClick={() => setDirection(1)}
                    className={`px-4 py-2 text-sm font-semibold transition-colors ${
                      direction === 1 ? 'bg-[#F6465D]/15 text-[#F6465D]' : 'hover:bg-t-surface-hover text-t-text'
                    }`}
                  >
                    空
                  </button>
                </div>
              </div>
              <div className="col-span-3">
                <div className="text-sm font-medium text-t-text-secondary mb-2">日期</div>
                <input
                  type="date"
                  value={planDate}
                  onChange={e => setPlanDate(e.target.value)}
                  className="w-full rounded-xl px-3 py-2 bg-t-page border border-t-border focus:outline-none focus:ring-2 focus:ring-[#F0B90B]/40"
                />
              </div>
              <div className="col-span-12">
                <div className="text-sm font-medium text-t-text-secondary mb-2">内容</div>
                <div className="space-y-3">
                  <div>
                    <div className="mb-2 text-xs font-semibold text-t-text-muted">指标和入场理由</div>
                    <textarea
                      value={content}
                      onChange={e => setContent(e.target.value)}
                      placeholder="写下你看到的结构、指标、关键位置和入场逻辑…"
                      rows={3}
                      className="w-full rounded-xl px-3 py-2 bg-t-page border border-t-border focus:outline-none focus:ring-2 focus:ring-[#F0B90B]/40"
                    />
                  </div>
                  <div>
                    <div className="mb-2 text-xs font-semibold text-t-text-muted">止盈预期</div>
                    <textarea
                      value={takeProfitExpectation}
                      onChange={e => setTakeProfitExpectation(e.target.value)}
                      placeholder="写下止盈路径、目标区间或离场预期…"
                      rows={2}
                      className="w-full rounded-xl px-3 py-2 bg-t-page border border-t-border focus:outline-none focus:ring-2 focus:ring-[#F0B90B]/40"
                    />
                  </div>
                </div>
              </div>
              <div className="col-span-12">
                <button
                  disabled={submitting}
                  onClick={upsert}
                  className="w-full rounded-xl px-5 py-3 font-bold bg-[#F0B90B] text-black hover:bg-[#D9A70A] disabled:opacity-60"
                >
                  {editingId ? '保存' : '确定'}
                </button>
              </div>
            </div>
          </div>
        </div>
      ) : null}

      {scoreTarget ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div
            className="absolute inset-0 bg-black/60 backdrop-blur-sm"
            onClick={() => {
              setScoreTarget(null)
              setScoreChecks(new Set())
              setScoreVetoes(new Set())
            }}
          />
          <div className="relative flex w-full max-w-4xl max-h-[85vh] flex-col overflow-hidden rounded-2xl border border-t-border bg-t-modal shadow-2xl">
            <div className="px-5 py-4 border-b border-t-border flex items-center gap-2">
              <div className="font-bold">评分</div>
              <div className="text-sm text-t-text-muted">{scoreTarget.symbol}</div>
              <div className="flex-1" />
              <button
                onClick={() => {
                  setScoreTarget(null)
                  setScoreChecks(new Set())
                  setScoreVetoes(new Set())
                }}
                className="rounded-lg p-2 hover:bg-t-surface-hover"
              >
                <X size={18} />
              </button>
            </div>
            {(() => {
              const liveScore = calculateScore(scoreTarget.plan_type, scoreChecks, scoreVetoes)
              const liveMeta = getScoreMeta(liveScore.total, liveScore.hasVeto)
              const sectionScores = calculateSectionScores(scoreTarget.plan_type, scoreChecks)
              return (
                <>
                  <div className="shrink-0 p-5 pb-4 border-b border-t-border bg-t-modal">
                    <div className={`rounded-2xl border px-5 py-4 ${liveMeta.tone}`}>
                      <div className="flex flex-wrap items-start justify-between gap-4">
                        <div>
                          <div className="text-sm font-semibold">{formatPlanType(scoreTarget.plan_type)}评分</div>
                          <div className="mt-2 text-4xl font-black leading-none">{liveScore.total}分</div>
                          <div className={`mt-2 text-sm font-bold ${liveMeta.subTone}`}>
                            {liveScore.hasVeto ? '已触发否决项' : liveMeta.label}
                          </div>
                        </div>
                        <div className="grid flex-1 min-w-[320px] grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-5">
                          {sectionScores.map(section => (
                            <div
                              key={section.title}
                              className="rounded-xl border border-white/40 bg-white/40 px-3 py-3 text-center backdrop-blur-sm"
                            >
                              <div className="text-2xl font-black leading-none">{section.score}分</div>
                              <div className="mt-2 text-xs font-semibold leading-tight opacity-90">{section.title}</div>
                            </div>
                          ))}
                        </div>
                      </div>
                    </div>
                  </div>

                  <div className="flex-1 overflow-y-auto p-5 space-y-5">
                    {getScoreSections(scoreTarget.plan_type).map(section => (
                      <div key={section.title} className="rounded-2xl border border-t-border bg-t-page p-4">
                        <div className="mb-3 text-sm font-bold text-t-text">{section.title}</div>
                        <div className="grid gap-2">
                          {section.items.map(item => {
                            const active = scoreChecks.has(item.key)
                            return (
                              <button
                                key={item.key}
                                type="button"
                                onClick={() => {
                                  setScoreChecks(prev => {
                                    const next = new Set(prev)
                                    if (next.has(item.key)) next.delete(item.key)
                                    else next.add(item.key)
                                    return next
                                  })
                                }}
                                className={`rounded-xl border px-3 py-3 text-left text-sm transition-colors ${
                                  active
                                    ? 'border-[#F0B90B]/30 bg-[#F0B90B]/12 text-t-text'
                                    : 'border-t-border bg-white hover:bg-t-surface-hover'
                                }`}
                              >
                                <span className="font-medium">{item.label}</span>
                                <span className="ml-2 text-xs font-bold text-[#C48B00]">{item.points}分</span>
                              </button>
                            )
                          })}
                        </div>
                      </div>
                    ))}

                    <div className="rounded-2xl border border-[#F6465D]/20 bg-[#F6465D]/6 p-4">
                      <div className="mb-3 text-sm font-bold text-[#F6465D]">否决项</div>
                      <div className="grid gap-2">
                        {SCORE_VETO_ITEMS.map(item => {
                          const active = scoreVetoes.has(item.key)
                          return (
                            <button
                              key={item.key}
                              type="button"
                              onClick={() => {
                                setScoreVetoes(prev => {
                                  const next = new Set(prev)
                                  if (next.has(item.key)) next.delete(item.key)
                                  else next.add(item.key)
                                  return next
                                })
                              }}
                              className={`rounded-xl border px-3 py-3 text-left text-sm transition-colors ${
                                active
                                  ? 'border-[#F6465D]/30 bg-[#F6465D]/12 text-[#F6465D]'
                                  : 'border-t-border bg-white hover:bg-t-surface-hover'
                              }`}
                            >
                              <span className="font-medium">{item.label}</span>
                            </button>
                          )
                        })}
                      </div>
                    </div>
                  </div>

                  <div className="shrink-0 border-t border-t-border bg-t-modal p-5 pt-4">
                    <button
                      onClick={() => void saveScore()}
                      className="w-full rounded-xl px-5 py-3 font-bold bg-[#F0B90B] text-black hover:bg-[#D9A70A]"
                    >
                      确定
                    </button>
                  </div>
                </>
              )
            })()}
          </div>
        </div>
      ) : null}

      {reviewTarget ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div className="absolute inset-0 bg-black/60 backdrop-blur-sm" onClick={() => setReviewTarget(null)} />
          <div className="relative w-full max-w-2xl rounded-2xl overflow-hidden border border-t-border bg-t-modal shadow-2xl">
            <div className="px-5 py-4 border-b border-t-border flex items-center gap-2">
              <div className="font-bold">复盘</div>
              <div className="text-sm text-t-text-muted">{reviewTarget.symbol}</div>
              <div className="flex-1" />
              <button onClick={() => setReviewTarget(null)} className="rounded-lg p-2 hover:bg-t-surface-hover">
                <X size={18} />
              </button>
            </div>
            <div className="p-5 space-y-4">
              <textarea
                value={reviewDraft}
                onChange={e => setReviewDraft(e.target.value)}
                placeholder="填写复盘内容…"
                rows={7}
                className="w-full rounded-xl px-3 py-2 bg-t-page border border-t-border focus:outline-none focus:ring-2 focus:ring-[#F0B90B]/40"
              />
              <div className="flex items-center justify-end gap-2">
                <button
                  onClick={() => setReviewTarget(null)}
                  className="rounded-xl px-4 py-2 font-bold border border-t-border hover:bg-t-surface-hover"
                >
                  取消
                </button>
                <button
                  onClick={() => {
                    void updateItem(reviewTarget.id, { review_content: reviewDraft })
                    setReviewTarget(null)
                    showToast('已保存')
                  }}
                  className="rounded-xl px-5 py-2 font-bold bg-[#F0B90B] text-black hover:bg-[#D9A70A]"
                >
                  保存
                </button>
              </div>
            </div>
          </div>
        </div>
      ) : null}

      {resultTarget ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div
            className="absolute inset-0 bg-black/60 backdrop-blur-sm"
            onClick={() => {
              setResultTarget(null)
              setResultDraft(0)
              setResultAmountDraft('')
            }}
          />
          <div className="relative w-full max-w-md rounded-2xl overflow-hidden border border-t-border bg-t-modal shadow-2xl">
            <div className="px-5 py-4 border-b border-t-border flex items-center gap-2">
              <div className="font-bold">止盈止损</div>
              <div className="text-sm text-t-text-muted">{resultTarget.symbol}</div>
              <div className="flex-1" />
              <button
                onClick={() => {
                  setResultTarget(null)
                  setResultDraft(0)
                  setResultAmountDraft('')
                }}
                className="rounded-lg p-2 hover:bg-t-surface-hover"
              >
                <X size={18} />
              </button>
            </div>
            <div className="p-5 space-y-4">
              <div className="flex gap-3">
                <button
                  type="button"
                  onClick={() => setResultDraft(2)}
                  className={`flex-1 rounded-xl px-4 py-3 text-sm font-bold border ${
                    resultDraft === 2
                      ? 'border-[#0ECB81]/20 bg-[#0ECB81]/15 text-[#0ECB81]'
                      : 'border-t-border hover:bg-t-surface-hover'
                  }`}
                >
                  止盈
                </button>
                <button
                  type="button"
                  onClick={() => setResultDraft(1)}
                  className={`flex-1 rounded-xl px-4 py-3 text-sm font-bold border ${
                    resultDraft === 1
                      ? 'border-[#F6465D]/20 bg-[#F6465D]/15 text-[#F6465D]'
                      : 'border-t-border hover:bg-t-surface-hover'
                  }`}
                >
                  止损
                </button>
              </div>
              <div>
                <div className="mb-2 text-sm font-medium text-t-text-secondary">止盈止损金额</div>
                <div className="relative">
                  <span
                    className={`pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-sm font-bold ${
                      resultDraft === 1 ? 'text-[#F6465D]' : resultDraft === 2 ? 'text-[#0ECB81]' : 'text-t-text-muted'
                    }`}
                  >
                    {resultDraft === 1 ? '-' : resultDraft === 2 ? '+' : ''}
                  </span>
                  <input
                    value={resultAmountDraft}
                    onChange={e => setResultAmountDraft(e.target.value.replace(/[^\d.]/g, ''))}
                    placeholder="输入金额"
                    className="w-full rounded-xl border border-t-border bg-t-page py-3 pl-8 pr-3 focus:outline-none focus:ring-2 focus:ring-[#F0B90B]/40"
                  />
                </div>
              </div>
              <div className="flex items-center justify-end gap-2">
                <button
                  onClick={() => {
                    setResultTarget(null)
                    setResultDraft(0)
                    setResultAmountDraft('')
                  }}
                  className="rounded-xl px-4 py-2 font-bold border border-t-border hover:bg-t-surface-hover"
                >
                  取消
                </button>
                <button
                  onClick={() => void saveResult()}
                  className="rounded-xl px-5 py-2 font-bold bg-[#F0B90B] text-black hover:bg-[#D9A70A]"
                >
                  确定
                </button>
              </div>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  )
}
