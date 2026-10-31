import { ArrowLeft, Pencil, Trash2 } from 'lucide-react'
import { useEffect, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { ConfirmModal } from '@/components/modals'
import { useTradingStore, showToast } from '@/shared/store'
import type { Strategy, StrategyLevel } from '@/shared/types'
import { api, ApiError } from '@/shared/lib/api'
import { isStandaloneMode } from '@/shared/lib/device'
import {
  getAccountSessionRevision,
  isCurrentAccountSession,
} from '@/shared/lib/accountBalanceState'
import { useAuthStore } from '@/shared/store/authStore'
import { useTradingMode } from '@/shared/hooks/useTradingMode'
import { getTradingModeRevision } from '@/shared/lib/tradingMode'

export function StrategyEditorPage() {
  const { id } = useParams<{ id?: string }>()
  const user = useAuthStore(state => state.user)
  const mode = useTradingMode()
  const navigate = useNavigate()
  const standalone = isStandaloneMode()
  const sessionRevision = getAccountSessionRevision()
  const scope = `${user?.id ?? ''}:${sessionRevision}:${mode}:${id ?? ''}`
  const [attempt, setAttempt] = useState(0)
  const [loaded, setLoaded] = useState<{ scope: string; strategy: Strategy | null; error: string } | null>(null)

  useEffect(() => {
    if (!id || !user?.id) return
    const controller = new AbortController()
    const modeRevision = getTradingModeRevision()
    const isCurrent = () => !controller.signal.aborted && modeRevision === getTradingModeRevision()
      && isCurrentAccountSession(user.id, useAuthStore.getState().user?.id ?? '', sessionRevision, getAccountSessionRevision())
    void api.get<Array<{ id: number; name: string; levels: StrategyLevel[] }>>('/strategy/list', {
      signal: controller.signal, disableRetry: true, timeout: 8000,
    }).then(rows => {
      if (!isCurrent()) return
      const row = rows.find(item => String(item.id) === id)
      setLoaded({ scope, strategy: row ? { ...row, id: String(row.id) } : null, error: row ? '' : '策略不存在，请返回策略列表检查。' })
    }).catch(error => {
      if (isCurrent()) setLoaded({ scope, strategy: null, error: error instanceof ApiError ? error.message : '加载策略失败，请稍后重试' })
    })
    return () => controller.abort()
  }, [id, user, mode, sessionRevision, scope, attempt])

  if (!id) return <StrategyEditorForm key={scope} editingStrategy={null} />
  if (loaded?.scope === scope && loaded.strategy) {
    return <StrategyEditorForm key={scope} editingStrategy={loaded.strategy} />
  }
  const error = loaded?.scope === scope ? loaded.error : ''
  return (
    <div className="h-full flex flex-col bg-t-page text-t-text">
      <header className="shrink-0 border-b border-t-border bg-t-surface px-4"
        style={{ paddingTop: standalone ? 'max(44px, env(safe-area-inset-top, 0px))' : 'env(safe-area-inset-top, 0px)' }}>
        <div className="relative mx-auto flex h-14 max-w-md items-center justify-center">
          <button type="button" onClick={() => navigate('/strategy-management')} aria-label="返回策略列表"
            className="absolute left-0 p-2 rounded-lg hover:bg-t-surface-hover"><ArrowLeft size={20} /></button>
          <h1 className="text-lg font-bold">编辑策略</h1>
        </div>
      </header>
      <div className="mx-auto w-full max-w-md p-6 text-center">
        {error ? <><p role="alert" className="text-sm text-[#F6465D]">{error}</p>
          <button type="button" onClick={() => { setLoaded(null); setAttempt(value => value + 1) }}
            className="mt-4 rounded-lg bg-[var(--t-brand)] px-4 py-2 text-sm font-medium text-black">重新加载</button></>
          : <p role="status" className="text-sm text-t-text-muted">正在加载策略...</p>}
      </div>
    </div>
  )
}

function StrategyEditorForm({ editingStrategy }: { editingStrategy: Strategy | null }) {
  const standalone = isStandaloneMode()
  const navigate = useNavigate()
  const authUserId = useAuthStore(state => state.user?.id ?? '')
  const addStrategy = useTradingStore(s => s.addStrategy)
  const updateStrategy = useTradingStore(s => s.updateStrategy)
  const stopLossAmount = useTradingStore(s => s.stopLossAmount)
  const [saving, setSaving] = useState(false)

  const initialLevels: StrategyLevel[] = (editingStrategy?.levels || [{ profitRR: 0, reducePosition: 0, stopLossType: 'none' }]).map((level) => ({
    profitRR: Number(level.profitRR || 0),
    reducePosition: Number(level.reducePosition || 0),
    stopLossType: level.stopLossType || 'none',
    stopLossRR: level.stopLossRR == null ? undefined : Number(level.stopLossRR),
    stopLossAbsoluteRR: level.stopLossAbsoluteRR == null ? undefined : Number(level.stopLossAbsoluteRR),
  }))
  const [strategyName, setStrategyName] = useState(editingStrategy?.name || '策略1')
  const [isEditingName, setIsEditingName] = useState(false)
  const [levels, setLevels] = useState<StrategyLevel[]>(initialLevels)
  const [showInvalidRRAlert, setShowInvalidRRAlert] = useState(false)
  const [invalidRRMessage, setInvalidRRMessage] = useState('')
  const [showInvalidNameAlert, setShowInvalidNameAlert] = useState(false)
  const [draftInputs, setDraftInputs] = useState<Record<string, string>>({})
  const [reduceSelected, setReduceSelected] = useState<boolean[]>(
    initialLevels.map((level) => level.reducePosition > 0)
  )

  const getRemainingBeforeLevel = (upToIndex: number) => {
    if (upToIndex === 0) return 100
    let remaining = 100
    for (let i = 0; i < upToIndex; i++) remaining -= levels[i].reducePosition
    return remaining
  }

  const isValidOneDecimal = (val: string) => val === '' || /^\d*(\.\d?)?$/.test(val)
  const isValidSignedOneDecimal = (val: string) => val === '' || /^-?\d*(\.\d?)?$/.test(val)
  const isValidInteger = (val: string) => val === '' || /^\d*$/.test(val)
  const getDraftKey = (index: number, field: 'profitRR' | 'stopLossAbsoluteRR' | 'stopLossRR') => `${index}-${field}`
  const getDraftDisplay = (index: number, field: 'profitRR' | 'stopLossAbsoluteRR' | 'stopLossRR', value: number | null | undefined) => {
    const draft = draftInputs[getDraftKey(index, field)]
    if (draft !== undefined) return draft
    if (value == null) return ''
    if (value === 0 && field !== 'stopLossAbsoluteRR') return ''
    return String(value)
  }
  const setDecimalDraft = (index: number, field: 'profitRR' | 'stopLossAbsoluteRR' | 'stopLossRR', value: string) => {
    const key = getDraftKey(index, field)
    setDraftInputs((prev) => ({ ...prev, [key]: value }))
    if (value === '') {
      handleLevelChange(index, field, 0)
      return
    }
    if (!value.endsWith('.')) {
      handleLevelChange(index, field, parseFloat(value))
    }
  }
  const getLockedMinStopRBeforeLevel = (targetIndex: number) => {
    let lockedMin = -1
    for (let i = 0; i < targetIndex; i++) {
      const lv = levels[i]
      if (!lv.profitRR || lv.profitRR <= 0) continue
      if (lv.stopLossType === 'absoluteRR' && lv.stopLossAbsoluteRR != null) {
        lockedMin = Math.max(lockedMin, lv.stopLossAbsoluteRR)
      }
      if (lv.stopLossType === 'fixedRR' && lv.stopLossRR && lv.stopLossRR > 0) {
        const stopAtTrigger = lv.profitRR - lv.stopLossRR
        lockedMin = Math.max(lockedMin, stopAtTrigger)
      }
    }
    return lockedMin
  }
  const clearDecimalField = (index: number, field: 'profitRR' | 'stopLossAbsoluteRR' | 'stopLossRR') => {
    handleLevelChange(index, field, 0)
    setDraftInputs((prev) => {
      const next = { ...prev }
      delete next[getDraftKey(index, field)]
      return next
    })
  }
  const validateDecimalField = (index: number, field: 'profitRR' | 'stopLossAbsoluteRR' | 'stopLossRR', value: number) => {
    const level = levels[index]
    const prevProfitRR = index > 0 ? levels[index - 1].profitRR : 0
    const prevLockedMin = getLockedMinStopRBeforeLevel(index)
    if (field === 'profitRR') {
      if (value <= 0) {
        setInvalidRRMessage('盈利倍数不能小于 0')
        setShowInvalidRRAlert(true)
        clearDecimalField(index, field)
        return false
      }
      if (index > 0 && value <= prevProfitRR) {
        setInvalidRRMessage(`L${index + 1} 触发R必须大于 L${index} 触发R`)
        setShowInvalidRRAlert(true)
        clearDecimalField(index, field)
        return false
      }
      return true
    }
    if (field === 'stopLossAbsoluteRR') {
      if (value <= -1) {
        setInvalidRRMessage('选择“移动到xR位置”时，x 必须大于 -1')
        setShowInvalidRRAlert(true)
        clearDecimalField(index, field)
        return false
      }
      if (value < prevLockedMin) {
        setInvalidRRMessage(`固定止损R不能低于上一层锁定止损位（>= ${prevLockedMin}R）`)
        setShowInvalidRRAlert(true)
        clearDecimalField(index, field)
        return false
      }
      if (value >= level.profitRR) {
        setInvalidRRMessage('此处 R 必须小于上方填写的 R 判断条件')
        setShowInvalidRRAlert(true)
        clearDecimalField(index, field)
        return false
      }
      return true
    }
    if (value <= 0) return false
    const maxAllowedByCurrent = level.profitRR - prevLockedMin
    if (maxAllowedByCurrent <= 0) {
      setInvalidRRMessage('当前层触发R过小，无法设置持续回撤止损，请提高触发R')
      setShowInvalidRRAlert(true)
      clearDecimalField(index, field)
      return false
    }
    if (value >= maxAllowedByCurrent) {
      setInvalidRRMessage(`此处 R 必须 < ${maxAllowedByCurrent}，否则会触及或跌破已锁定止损位`)
      setShowInvalidRRAlert(true)
      clearDecimalField(index, field)
      return false
    }
    return true
  }
  const commitDecimalDraft = (index: number, field: 'profitRR' | 'stopLossAbsoluteRR' | 'stopLossRR') => {
    const key = getDraftKey(index, field)
    const draft = draftInputs[key]
    if (draft === undefined) return
    if (draft === '') {
      handleLevelChange(index, field, 0)
    } else {
      const normalized = draft.endsWith('.') ? draft.slice(0, -1) : draft
      const value = normalized ? parseFloat(normalized) : 0
      handleLevelChange(index, field, value)
      validateDecimalField(index, field, value)
    }
    setDraftInputs((prev) => {
      const next = { ...prev }
      delete next[key]
      return next
    })
  }
  const validateReducePosition = (index: number, value: number) => {
    if (!reduceSelected[index]) return true
    if (!Number.isInteger(value) || value < 1 || value > 100) {
      setInvalidRRMessage('减仓比例不能为空，且必须为 1-100 的正整数')
      setShowInvalidRRAlert(true)
      handleLevelChange(index, 'reducePosition', 0)
      return false
    }
    return true
  }

  const handleAddLevel = () => {
    if (levels.length < 5) {
      setLevels([...levels, { profitRR: 0, reducePosition: 0, stopLossType: 'none' }])
      setReduceSelected([...reduceSelected, false])
    }
  }

  const handleDeleteLevel = (index: number) => {
    if (levels.length > 1) {
      setLevels(levels.filter((_, i) => i !== index))
      setReduceSelected(reduceSelected.filter((_, i) => i !== index))
    }
  }

  const handleLevelChange = (index: number, field: keyof StrategyLevel, value: StrategyLevel[keyof StrategyLevel]) => {
    const next = [...levels]
    next[index] = { ...next[index], [field]: value }

    setLevels(next)
  }

  const handleSave = async () => {
    if (saving) return
    if (!strategyName.trim()) {
      setShowInvalidNameAlert(true)
      return
    }
    for (let i = 1; i < levels.length; i++) {
      if (levels[i].profitRR > 0 && levels[i].profitRR <= levels[i - 1].profitRR) {
        setInvalidRRMessage(`L${i + 1} 触发R必须大于 L${i} 触发R`)
        setShowInvalidRRAlert(true)
        return
      }
    }
    for (let i = 0; i < levels.length; i++) {
      const level = levels[i]
      if (!level.profitRR || level.profitRR <= 0) {
        setInvalidRRMessage(`L${i + 1} 的盈利数值必须大于0`)
        setShowInvalidRRAlert(true)
        return
      }
      const hasReduceAction = reduceSelected[i] && Number.isInteger(level.reducePosition) && level.reducePosition >= 1 && level.reducePosition <= 100
      const hasMoveAction = level.stopLossType !== 'none'
      if (!hasReduceAction && !hasMoveAction) {
        setInvalidRRMessage(`L${i + 1} 仅有触发条件，未设置执行动作。请至少选择“减仓”或“移动止损位”`)
        setShowInvalidRRAlert(true)
        return
      }
      if (reduceSelected[i] && (!Number.isInteger(level.reducePosition) || level.reducePosition < 1 || level.reducePosition > 100)) {
        setInvalidRRMessage(`L${i + 1} 减仓比例不能为空，且必须为 1-100 的正整数`)
        setShowInvalidRRAlert(true)
        return
      }
      if (level.stopLossType === 'fixedRR' && (!level.stopLossRR || level.stopLossRR <= 0)) {
        setInvalidRRMessage(`L${i + 1} 选择“移动到当前浮盈-xR”时，x 必须大于0`)
        setShowInvalidRRAlert(true)
        return
      }
      const prevLockedMin = getLockedMinStopRBeforeLevel(i)
      if (level.stopLossType === 'fixedRR' && level.stopLossRR && level.stopLossRR >= level.profitRR - prevLockedMin) {
        setInvalidRRMessage(`L${i + 1} 此处 R 必须 < ${level.profitRR - prevLockedMin}，否则会触及或跌破已锁定止损位`)
        setShowInvalidRRAlert(true)
        return
      }
      if (level.stopLossType === 'absoluteRR' && (level.stopLossAbsoluteRR == null || level.stopLossAbsoluteRR <= -1)) {
        setInvalidRRMessage(`L${i + 1} 选择“移动到xR位置”时，x 必须大于-1`)
        setShowInvalidRRAlert(true)
        return
      }
      if (level.stopLossType === 'absoluteRR' && level.stopLossAbsoluteRR != null && level.stopLossAbsoluteRR < prevLockedMin) {
        setInvalidRRMessage(`L${i + 1} 固定止损R不能低于上一层锁定止损位（>= ${prevLockedMin}R）`)
        setShowInvalidRRAlert(true)
        return
      }
    }
    const payloadLevels = levels.map((level) => ({
      profitRR: level.profitRR,
      reducePosition: level.reducePosition,
      stopLossType: level.stopLossType,
      stopLossRR: level.stopLossType === 'fixedRR' ? level.stopLossRR : undefined,
      stopLossAbsoluteRR: level.stopLossType === 'absoluteRR' ? level.stopLossAbsoluteRR : undefined,
    }))
    const requestUserId = authUserId
    const requestSessionRevision = getAccountSessionRevision()
    const requestModeRevision = getTradingModeRevision()
    const isCurrentSession = () => isCurrentAccountSession(
      requestUserId,
      useAuthStore.getState().user?.id ?? '',
      requestSessionRevision,
      getAccountSessionRevision(),
    ) && requestModeRevision === getTradingModeRevision()
    try {
      setSaving(true)
      const saved = await api.post<{
        id: number
        name: string
        levels: StrategyLevel[]
      }>('/strategy/save', {
        strategy_id: editingStrategy ? Number(editingStrategy.id) : undefined,
        name: strategyName.trim(),
        levels: payloadLevels,
      })
      if (!isCurrentSession()) return
      if (editingStrategy) {
        updateStrategy(editingStrategy.id, { name: saved.name, levels: saved.levels })
      } else {
        addStrategy({ name: saved.name, levels: saved.levels })
      }
      showToast('保存成功')
      navigate('/strategy-management')
    } catch (error) {
      const message = error instanceof ApiError ? error.message : '保存失败，请稍后重试'
      if (isCurrentSession()) showToast(message)
    } finally {
      if (isCurrentSession()) setSaving(false)
    }
  }

  const isSubmitEnabled = (() => {
    if (saving) return false
    if (!strategyName.trim()) return false
    let reduceSum = 0
    for (let i = 0; i < levels.length; i++) {
      const level = levels[i]
      if (!level.profitRR || level.profitRR <= 0) return false
      if (i > 0 && level.profitRR <= levels[i - 1].profitRR) return false

      const hasReduceAction = reduceSelected[i] && Number.isInteger(level.reducePosition) && level.reducePosition >= 1 && level.reducePosition <= 100
      const hasMoveAction = level.stopLossType !== 'none'
      if (!hasReduceAction && !hasMoveAction) return false

      if (reduceSelected[i]) {
        if (!level.reducePosition || level.reducePosition <= 0 || level.reducePosition > 100) return false
      }
      reduceSum += level.reducePosition || 0
      const prevLockedMin = getLockedMinStopRBeforeLevel(i)

      if (level.stopLossType === 'absoluteRR') {
        if (level.stopLossAbsoluteRR == null || level.stopLossAbsoluteRR <= -1) return false
        if (level.stopLossAbsoluteRR < prevLockedMin) return false
        if (level.stopLossAbsoluteRR >= level.profitRR) return false
      }
      if (level.stopLossType === 'fixedRR') {
        if (!level.stopLossRR || level.stopLossRR <= 0) return false
        if (level.stopLossRR >= level.profitRR - prevLockedMin) return false
      }
    }
    if (reduceSum > 100) return false
    return true
  })()

  const numInputClass = 'w-16 px-2 py-1.5 rounded-lg text-center transition-colors bg-t-surface-alt text-t-text border border-t-border'
  const smallInputClass = 'w-14 px-2 py-1 rounded-lg text-center transition-colors bg-t-surface-alt text-t-text border border-t-border'

  return (
    <div className="h-full min-h-0 flex flex-col overflow-hidden overscroll-none transition-colors bg-t-page text-t-text">
      <div
        className="shrink-0 px-4 pb-4 border-b transition-colors bg-t-surface border-t-border"
        style={{ paddingTop: standalone ? 'max(44px, env(safe-area-inset-top, 0px))' : 'env(safe-area-inset-top, 0px)' }}
      >
        <div className="h-11 flex items-center justify-center max-w-md mx-auto relative">
          <button onClick={() => navigate('/strategy-management')} className="absolute left-0 p-2 rounded-lg transition-colors hover:bg-t-surface-hover">
            <ArrowLeft size={20} />
          </button>
          <div className="flex items-center gap-2">
            {isEditingName ? (
              <input
                type="text"
                value={strategyName}
                onChange={(e) => setStrategyName(e.target.value)}
                onBlur={() => setIsEditingName(false)}
                autoFocus
                className="text-lg font-bold bg-transparent border-b-2 border-[#F0B90B] outline-none text-center text-t-text"
              />
            ) : (
              <>
                <h1 className="text-lg font-bold">{strategyName}</h1>
                <button onClick={() => setIsEditingName(true)} className="p-1 hover:bg-t-surface-hover rounded transition-colors">
                  <Pencil size={16} className="text-t-text-muted" />
                </button>
              </>
            )}
          </div>
        </div>
      </div>

      <div
        className="flex-1 min-h-0 overflow-y-scroll overscroll-contain hide-scrollbar bg-t-page"
        style={{
          WebkitOverflowScrolling: 'touch',
          overscrollBehaviorY: 'contain',
          touchAction: 'pan-y',
          paddingBottom: 'calc(96px + env(safe-area-inset-bottom, 0px))',
        }}
      >
        <div className="max-w-md mx-auto w-full p-4 space-y-3 min-h-full">
          <div className="px-3 py-2 rounded-lg bg-[#FFF9E6] dark:bg-[#2B2412]">
            <p className="text-sm text-[#B8860B] dark:text-[#F0B90B]">
              说明：R是指基准止损金额，您当前的基准止损金额为{stopLossAmount}U
            </p>
          </div>

          {levels.map((level, index) => {
            const cardRemaining = getRemainingBeforeLevel(index)
            const cardRemainingClass = cardRemaining === 100
              ? 'bg-[#FFF9E6] dark:bg-[#2B2412] text-[#B8860B] dark:text-[#F0B90B]'
              : cardRemaining < 0
              ? 'bg-[#2D1A1E] text-[#F6465D]'
              : cardRemaining === 0
                ? 'bg-[#0D2318] text-[#0ECB81]'
                : 'bg-t-btn-secondary text-t-text-muted'

            return (
              <div key={index} className="rounded-2xl p-4 transition-colors relative bg-t-surface border border-t-border">
                <div className="flex items-center justify-between mb-3">
                  <div className="flex items-center gap-2">
                    <h3 className="text-base font-semibold text-t-text">L{index + 1}:</h3>
                    <div className={`flex items-center gap-1 px-2 py-0.5 rounded-full text-sm ${cardRemainingClass}`}>
                      <span>剩余仓位</span>
                      <span className="font-medium">{cardRemaining}%</span>
                    </div>
                  </div>
                  {levels.length > 1 && (
                    <button onClick={() => handleDeleteLevel(index)} className="p-1.5 rounded-lg transition-colors hover:bg-t-surface-hover">
                      <Trash2 size={16} className="text-[#F6465D]" />
                    </button>
                  )}
                </div>

                <div className="pb-3">
                  <div className="flex items-center gap-2 flex-wrap">
                    <span className="text-sm text-t-text-secondary">当盈利达到</span>
                    <div className="relative">
                      <input
                        type="text"
                        inputMode="decimal"
                        value={getDraftDisplay(index, 'profitRR', level.profitRR)}
                        onChange={(e) => {
                          const v = e.target.value
                          if (isValidOneDecimal(v)) setDecimalDraft(index, 'profitRR', v)
                        }}
                        onBlur={() => commitDecimalDraft(index, 'profitRR')}
                        className={`${numInputClass} pr-5`}
                      />
                      <span className="absolute right-2 top-1/2 -translate-y-1/2 text-sm font-medium text-[#F0B90B]">R</span>
                    </div>
                    <span className="text-sm text-t-text-secondary">时</span>
                  </div>
                </div>

                <div className="border-t border-t-border mb-3" />

                <div className="pb-3 space-y-2.5">
                  <button
                    type="button"
                    className="w-full flex items-center gap-2.5 text-left"
                    onClick={() => {
                      const next = [...reduceSelected]
                      next[index] = false
                      setReduceSelected(next)
                      handleLevelChange(index, 'reducePosition', 0)
                    }}
                  >
                    <RadioOption
                      checked={!reduceSelected[index]}
                      onChange={() => {
                        const next = [...reduceSelected]
                        next[index] = false
                        setReduceSelected(next)
                      }}
                      label="不减仓"
                    />
                  </button>

                  <div
                    role="button"
                    tabIndex={0}
                    className="w-full flex items-center gap-2.5 cursor-pointer"
                    onClick={() => {
                      const next = [...reduceSelected]
                      next[index] = true
                      setReduceSelected(next)
                    }}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter' || e.key === ' ') {
                        e.preventDefault()
                        const next = [...reduceSelected]
                        next[index] = true
                        setReduceSelected(next)
                      }
                    }}
                  >
                    <RadioOption
                      checked={reduceSelected[index]}
                      onChange={() => {
                        const next = [...reduceSelected]
                        next[index] = true
                        setReduceSelected(next)
                      }}
                      label="减仓"
                    />
                    {reduceSelected[index] && (
                      <>
                        <input
                          type="text"
                          inputMode="numeric"
                          value={level.reducePosition > 0 ? level.reducePosition : ''}
                          onChange={(e) => {
                            const v = e.target.value
                            if (isValidInteger(v)) {
                              const val = v === '' ? 0 : parseInt(v, 10)
                              handleLevelChange(index, 'reducePosition', val)
                            }
                          }}
                          onBlur={() => validateReducePosition(index, level.reducePosition)}
                          onClick={(e) => e.stopPropagation()}
                          className={smallInputClass}
                        />
                        <span className="text-sm text-t-text-secondary">%</span>
                      </>
                    )}
                  </div>
                </div>

                <div className="relative my-3">
                  <div className="border-t border-t-border" />
                  <div className="absolute inset-0 flex items-center justify-center">
                    <span className="px-2 text-xs bg-t-surface text-t-text-muted">同时</span>
                  </div>
                </div>

                <div className="space-y-2.5">
                  <button
                    type="button"
                    className="w-full flex items-center gap-2.5 text-left"
                    onClick={() => handleLevelChange(index, 'stopLossType', 'none')}
                  >
                    <RadioOption checked={level.stopLossType === 'none'} onChange={() => handleLevelChange(index, 'stopLossType', 'none')} label="不移动止损位" />
                  </button>
                  <button
                    type="button"
                    className="w-full flex items-center gap-2.5 text-left"
                    onClick={() => handleLevelChange(index, 'stopLossType', level.stopLossType === 'none' ? 'absoluteRR' : level.stopLossType)}
                  >
                    <RadioOption
                      checked={level.stopLossType !== 'none'}
                      onChange={() => handleLevelChange(index, 'stopLossType', level.stopLossType === 'none' ? 'absoluteRR' : level.stopLossType)}
                      label="移动止损位"
                    />
                  </button>

                  {level.stopLossType !== 'none' && (
                    <>
                      <div
                        role="button"
                        tabIndex={0}
                        className="w-full flex items-center gap-2.5 flex-wrap cursor-pointer pl-6"
                        onClick={() => handleLevelChange(index, 'stopLossType', 'absoluteRR')}
                        onKeyDown={(e) => {
                          if (e.key === 'Enter' || e.key === ' ') {
                            e.preventDefault()
                            handleLevelChange(index, 'stopLossType', 'absoluteRR')
                          }
                        }}
                      >
                        <RadioOption
                          checked={level.stopLossType === 'absoluteRR'}
                          onChange={() => {
                            handleLevelChange(index, 'stopLossType', 'absoluteRR')
                          }}
                          label="移动到"
                        />
                        <div className="relative">
                          <input
                            type="text"
                            inputMode="text"
                            value={getDraftDisplay(index, 'stopLossAbsoluteRR', level.stopLossAbsoluteRR)}
                            onChange={(e) => {
                              const v = e.target.value
                              if (isValidSignedOneDecimal(v)) setDecimalDraft(index, 'stopLossAbsoluteRR', v)
                            }}
                            onBlur={() => commitDecimalDraft(index, 'stopLossAbsoluteRR')}
                            onClick={(e) => {
                              e.stopPropagation()
                              if (level.stopLossType !== 'absoluteRR') handleLevelChange(index, 'stopLossType', 'absoluteRR')
                            }}
                            className={`${smallInputClass} pr-5`}
                          />
                          <span className="absolute right-2 top-1/2 -translate-y-1/2 text-sm font-medium text-[#F0B90B]">R</span>
                        </div>
                        <span className="text-sm text-t-text-secondary">位置</span>
                        <span className="px-2 py-0.5 rounded text-xs font-medium border bg-[#0ECB81]/10 border-[#0ECB81]/30 text-[#0ECB81]">
                          一次
                        </span>
                      </div>

                      <div
                        role="button"
                        tabIndex={0}
                        className="w-full flex items-center gap-2.5 flex-wrap cursor-pointer pl-6"
                        onClick={() => handleLevelChange(index, 'stopLossType', 'fixedRR')}
                        onKeyDown={(e) => {
                          if (e.key === 'Enter' || e.key === ' ') {
                            e.preventDefault()
                            handleLevelChange(index, 'stopLossType', 'fixedRR')
                          }
                        }}
                      >
                        <RadioOption
                          checked={level.stopLossType === 'fixedRR'}
                          onChange={() => {
                            handleLevelChange(index, 'stopLossType', 'fixedRR')
                          }}
                          label="移动到 当前浮盈 -"
                        />
                        <div className="relative">
                          <input
                            type="text"
                            inputMode="decimal"
                            value={getDraftDisplay(index, 'stopLossRR', level.stopLossRR)}
                            onChange={(e) => {
                              const v = e.target.value
                              if (isValidOneDecimal(v)) setDecimalDraft(index, 'stopLossRR', v)
                            }}
                            onBlur={() => commitDecimalDraft(index, 'stopLossRR')}
                            onClick={(e) => {
                              e.stopPropagation()
                              if (level.stopLossType !== 'fixedRR') handleLevelChange(index, 'stopLossType', 'fixedRR')
                            }}
                            className={`${smallInputClass} pr-5`}
                          />
                          <span className="absolute right-2 top-1/2 -translate-y-1/2 text-sm font-medium text-[#F0B90B]">R</span>
                        </div>
                        <span className="text-sm text-t-text-secondary">位置</span>
                        <span className="px-2 py-0.5 rounded text-xs font-medium border bg-[#0ECB81]/10 border-[#0ECB81]/30 text-[#0ECB81]">
                          持续
                        </span>
                      </div>
                    </>
                  )}
                </div>
              </div>
            )
          })}

          {levels.length < 5 && (
            <button
              onClick={handleAddLevel}
              className="w-full py-3 rounded-xl text-sm font-medium transition-colors border border-[#F0B90B] text-[#F0B90B] bg-transparent hover:bg-[#F0B90B]/10"
            >
              添加L{levels.length + 1}
            </button>
          )}
        </div>
      </div>

      <div
        className="fixed bottom-0 left-1/2 -translate-x-1/2 w-full max-w-md px-4 pt-3 transition-colors bg-t-page border-t border-t-border"
        style={{ paddingBottom: 'calc(12px + env(safe-area-inset-bottom, 0px))' }}
      >
        <div className="w-full">
          <button
            onClick={handleSave}
            disabled={!isSubmitEnabled}
            className={`w-full py-3.5 rounded-xl font-medium transition-all ${
              isSubmitEnabled
                ? 'bg-gradient-to-r from-[#F0B90B] to-[#D9A70A] text-black hover:shadow-lg hover:shadow-[#F0B90B]/30 active:scale-[0.98]'
                : 'bg-[#5B657A] text-[#A9B1C1] cursor-not-allowed'
            }`}
          >
            {saving ? '保存中...' : '确定'}
          </button>
        </div>
      </div>

      <ConfirmModal
        isOpen={showInvalidRRAlert}
        onClose={() => setShowInvalidRRAlert(false)}
        onConfirm={() => setShowInvalidRRAlert(false)}
        title="盈利数值错误"
        confirmText="知道了"
        showCancel={false}
      >
        {invalidRRMessage}
      </ConfirmModal>

      <ConfirmModal
        isOpen={showInvalidNameAlert}
        onClose={() => setShowInvalidNameAlert(false)}
        onConfirm={() => setShowInvalidNameAlert(false)}
        title="策略名称不能为空"
        confirmText="知道了"
        showCancel={false}
      >
        请先输入策略名称后再保存
      </ConfirmModal>
    </div>
  )
}

function RadioOption({ checked, onChange, label }: { checked: boolean; onChange: () => void; label: string }) {
  return (
    <span className="flex items-center gap-2.5">
      <div className={`w-4 h-4 rounded-full border-2 flex items-center justify-center ${checked ? 'border-[#F0B90B]' : 'border-gray-600 dark:border-gray-600'}`}>
        {checked && <div className="w-2 h-2 rounded-full bg-[#F0B90B]" />}
      </div>
      <input type="radio" checked={checked} onChange={onChange} className="hidden" />
      <span className="text-sm text-t-text-secondary">{label}</span>
    </span>
  )
}
