import { X } from 'lucide-react'
import { useState, useEffect, useRef } from 'react'
import { createPortal } from 'react-dom'
import { useTheme } from '@/app/contexts/ThemeContext'
import { api, ApiError } from '@/shared/lib/api'
import {
  getAccountSessionRevision,
  isCurrentAccountRequestScope,
} from '@/shared/lib/accountBalanceState'
import { showToast, useAuthStore } from '@/shared/store'

interface StopLossSettingsModalProps {
  isOpen: boolean
  onClose: () => void
  accountBalance: number
  currentStopLoss?: number
  currentAmount?: number
  onConfirm?: (stopLoss: number) => void
  onAmountChange?: (amount: number) => void
}

interface StopLossStateData {
  current_amount: string
  pending_amount: string | null
  pending_from_amount: string | null
  pending_effective_at: string | null
  countdown_seconds: number
  balance: string | null
  total_balance?: string | null
}

export function roundUpStopLoss(value: number): number {
  const step = value < 20 ? 1 : value < 100 ? 5 : 10
  return Math.max(step, Math.ceil(value / step) * step)
}

function parseNumber(value: string | number | null | undefined, fallback = 0): number {
  const num = Number(value)
  if (Number.isNaN(num) || !Number.isFinite(num)) return fallback
  return num
}

function calcPercentFromAmount(amount: number, balance: number): number {
  if (balance <= 0) return 5
  const raw = (amount / balance) * 100
  return Math.min(25, Math.max(1, Math.round(raw)))
}

function ConfirmDialog({
  isOpen,
  message,
  onConfirm,
  onCancel,
  theme,
}: {
  isOpen: boolean
  message: string
  onConfirm: () => void
  onCancel: () => void
  theme: string
}) {
  if (!isOpen) return null
  return (
    <div className="fixed inset-0 z-[140] flex items-center justify-center">
      <div className="absolute inset-0 bg-black/45" onClick={onCancel} />
      <div className={`relative w-full max-w-sm mx-4 rounded-2xl shadow-2xl p-6 ${theme === 'dark' ? 'bg-[#1A1D23]' : 'bg-white'}`}>
        <p className={`text-base mb-6 leading-relaxed ${theme === 'dark' ? 'text-white' : 'text-gray-900'}`}>{message}</p>
        <div className="flex gap-3">
          <button
            onClick={onCancel}
            className={`flex-1 py-3 rounded-xl font-medium transition-colors ${
              theme === 'dark' ? 'bg-[#2B2F36] text-white hover:bg-[#35393F]' : 'bg-gray-200 text-gray-900 hover:bg-gray-300'
            }`}
          >
            取消
          </button>
          <button
            onClick={onConfirm}
            className="flex-1 bg-gradient-to-r from-[var(--t-brand)] to-[var(--t-brand-hover)] text-black font-bold py-3 rounded-xl hover:shadow-lg hover:shadow-[var(--t-brand)]/30 transition-all active:scale-[0.98]"
          >
            确定
          </button>
        </div>
      </div>
    </div>
  )
}

export function StopLossSettingsModal({
  isOpen,
  onClose,
  accountBalance,
  currentStopLoss,
  currentAmount,
  onConfirm,
  onAmountChange,
}: StopLossSettingsModalProps) {
  const { theme } = useTheme()
  const effectiveOnConfirm = onConfirm || onAmountChange || (() => {})

  const [balance, setBalance] = useState(0)
  const [percentage, setPercentage] = useState(1)
  const [currentEffective, setCurrentEffective] = useState(0)
  const [pendingStopLoss, setPendingStopLoss] = useState<{ from: number; to: number } | null>(null)
  const [countdown, setCountdown] = useState(0)
  const [completedAdjustment, setCompletedAdjustment] = useState<{ from: number; to: number } | null>(null)
  const [confirmDialog, setConfirmDialog] = useState<{ isOpen: boolean; message: string; onConfirm: () => void } | null>(null)
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const requestIdRef = useRef(0)

  const rawStopLoss = (balance * percentage) / 100
  const roundedStopLoss = roundUpStopLoss(rawStopLoss)
  const isCurrent = roundedStopLoss === currentEffective

  useEffect(() => {
    if (!isOpen) return
    const body = document.body
    const html = document.documentElement
    const prevBodyOverflow = body.style.overflow
    const prevBodyPosition = body.style.position
    const prevBodyTop = body.style.top
    const prevBodyWidth = body.style.width
    const prevHtmlOverflow = html.style.overflow
    const scrollY = window.scrollY

    body.style.overflow = 'hidden'
    body.style.position = 'fixed'
    body.style.top = `-${scrollY}px`
    body.style.width = '100%'
    html.style.overflow = 'hidden'

    return () => {
      body.style.overflow = prevBodyOverflow
      body.style.position = prevBodyPosition
      body.style.top = prevBodyTop
      body.style.width = prevBodyWidth
      html.style.overflow = prevHtmlOverflow
      window.scrollTo(0, scrollY)
    }
  }, [isOpen])

  useEffect(() => {
    if (!isOpen) {
      requestIdRef.current += 1
      return
    }
    const requestUserId = useAuthStore.getState().user?.id ?? ''
    const requestSessionRevision = getAccountSessionRevision()
    const requestId = ++requestIdRef.current
    const isCurrentRequest = () => isCurrentAccountRequestScope(
      requestUserId,
      useAuthStore.getState().user?.id ?? '',
      requestId,
      requestIdRef.current,
      requestSessionRevision,
      getAccountSessionRevision(),
    )
    const loadState = async () => {
      try {
        setLoading(true)
        const data = await api.get<StopLossStateData>('/account/stop-loss')
        if (!isCurrentRequest()) return
        const nextBalance = parseNumber(data.total_balance ?? data.balance, accountBalance)
        const nextCurrent = parseNumber(data.current_amount, currentStopLoss || currentAmount || 120)
        setBalance(nextBalance)
        setCurrentEffective(nextCurrent)
        setPercentage(calcPercentFromAmount(nextCurrent, nextBalance))

        if (data.pending_amount && data.pending_from_amount) {
          setPendingStopLoss({
            from: parseNumber(data.pending_from_amount),
            to: parseNumber(data.pending_amount),
          })
          setCountdown(Math.max(0, Number(data.countdown_seconds || 0)))
        } else {
          setPendingStopLoss(null)
          setCountdown(0)
        }
      } catch (error) {
        const message = error instanceof ApiError ? error.message : '获取止损设置失败'
        if (isCurrentRequest()) showToast(message)
      } finally {
        if (isCurrentRequest()) setLoading(false)
      }
    }
    loadState()
    return () => {
      if (requestIdRef.current === requestId) requestIdRef.current += 1
    }
  }, [isOpen, accountBalance, currentAmount, currentStopLoss])

  useEffect(() => {
    if (!pendingStopLoss) return
    const timer = setInterval(() => {
      setCountdown(prev => (prev > 0 ? prev - 1 : 0))
    }, 1000)
    return () => clearInterval(timer)
  }, [pendingStopLoss])

  const formatCountdown = (seconds: number) => {
    const hours = Math.floor(seconds / 3600)
    const minutes = Math.floor((seconds % 3600) / 60)
    const secs = seconds % 60
    return `${hours.toString().padStart(2, '0')}:${minutes.toString().padStart(2, '0')}:${secs.toString().padStart(2, '0')}`
  }

  const applyState = (data: StopLossStateData, prevCurrent: number, targetAmount: number) => {
    const nextCurrent = parseNumber(data.current_amount, prevCurrent)
    setCurrentEffective(nextCurrent)
    effectiveOnConfirm(nextCurrent)

    if (data.pending_amount && data.pending_from_amount) {
      setPendingStopLoss({
        from: parseNumber(data.pending_from_amount),
        to: parseNumber(data.pending_amount),
      })
      setCountdown(Math.max(0, Number(data.countdown_seconds || 0)))
      setCompletedAdjustment(null)
    } else {
      setPendingStopLoss(null)
      setCountdown(0)
      if (nextCurrent !== prevCurrent && nextCurrent === targetAmount) {
        setCompletedAdjustment({ from: prevCurrent, to: nextCurrent })
      }
    }
  }

  const submitUpdate = async () => {
    const requestUserId = useAuthStore.getState().user?.id ?? ''
    const requestSessionRevision = getAccountSessionRevision()
    const requestId = ++requestIdRef.current
    const isCurrentRequest = () => isCurrentAccountRequestScope(
      requestUserId,
      useAuthStore.getState().user?.id ?? '',
      requestId,
      requestIdRef.current,
      requestSessionRevision,
      getAccountSessionRevision(),
    )
    try {
      setSaving(true)
      const prev = currentEffective
      const data = await api.post<StopLossStateData>('/account/stop-loss', { percentage })
      if (isCurrentRequest()) applyState(data, prev, roundedStopLoss)
    } catch (error) {
      const message = error instanceof ApiError ? error.message : '更新止损设置失败'
      if (isCurrentRequest()) showToast(message)
    } finally {
      if (isCurrentRequest()) setSaving(false)
    }
  }

  const handleCancelPending = () => {
    setConfirmDialog({
      isOpen: true,
      message: '确认取消调整止损金额？',
      onConfirm: async () => {
        const requestUserId = useAuthStore.getState().user?.id ?? ''
        const requestSessionRevision = getAccountSessionRevision()
        const requestId = ++requestIdRef.current
        const isCurrentRequest = () => isCurrentAccountRequestScope(
          requestUserId,
          useAuthStore.getState().user?.id ?? '',
          requestId,
          requestIdRef.current,
          requestSessionRevision,
          getAccountSessionRevision(),
        )
        try {
          setSaving(true)
          const data = await api.post<StopLossStateData>('/account/stop-loss/cancel', {})
          if (isCurrentRequest()) applyState(data, currentEffective, currentEffective)
        } catch (error) {
          const message = error instanceof ApiError ? error.message : '取消失败，请稍后重试'
          if (isCurrentRequest()) showToast(message)
        } finally {
          if (isCurrentRequest()) {
            setSaving(false)
            setConfirmDialog(null)
          }
        }
      },
    })
  }

  const handleConfirm = () => {
    if (isCurrent || loading || saving) return
    setConfirmDialog({
      isOpen: true,
      message: `您将调整止损金额由${currentEffective.toFixed(0)}调整到${roundedStopLoss.toFixed(0)}，确认后立即生效，是否确认？`,
      onConfirm: async () => {
        setConfirmDialog(null)
        await submitUpdate()
      },
    })
  }

  let riskLevel = ''
  let riskColor = ''
  if (percentage >= 1 && percentage <= 4) {
    riskLevel = '低风险'
    riskColor = '#0ECB81'
  } else if (percentage >= 5 && percentage <= 10) {
    riskLevel = '中风险'
    riskColor = 'var(--t-brand)'
  } else if (percentage >= 11 && percentage <= 25) {
    riskLevel = '高风险'
    riskColor = '#F6465D'
  }

  if (!isOpen) return null

  return createPortal(
    <>
      {/* Portal 到 body，避免 iOS/PWA 下页面滚动容器的合成层压住弹窗。 */}
      <div className="fixed inset-0 z-[130] flex items-end justify-center px-4 pb-[calc(8px+env(safe-area-inset-bottom,0px))] overscroll-none">
        <div className="absolute inset-0 bg-black/45" onClick={onClose} />
        <div className={`relative w-full max-w-md rounded-2xl shadow-2xl transition-colors ${theme === 'dark' ? 'bg-[#1A1D23]' : 'bg-white'}`}>
          <div className="flex items-center justify-between p-6 pb-4">
            <h2 className={`text-xl font-bold ${theme === 'dark' ? 'text-white' : 'text-gray-900'}`}>止损设置</h2>
            <button onClick={onClose} className={`p-2 rounded-lg transition-colors ${theme === 'dark' ? 'hover:bg-[#2B2F36]' : 'hover:bg-gray-100'}`}>
              <X size={20} />
            </button>
          </div>

          <div className="px-6 pb-6 space-y-6">
            <div>
              <p className={`text-sm mb-2 ${theme === 'dark' ? 'text-gray-400' : 'text-gray-600'}`}>账户总资产（USDT）</p>
              <p className={`text-2xl font-bold ${theme === 'dark' ? 'text-white' : 'text-gray-900'}`}>{balance.toFixed(2)} USDT</p>
            </div>

            <div>
              <div className="flex items-center justify-between mb-3">
                <p className={`text-sm ${theme === 'dark' ? 'text-gray-400' : 'text-gray-600'}`}>单笔止损占账户总资产百分比</p>
                <div className="flex items-center gap-2">
                  <span className="text-2xl font-bold text-[var(--t-brand)]">{percentage}%</span>
                  <span className="text-sm font-medium" style={{ color: riskColor }}>{riskLevel}</span>
                </div>
              </div>
              <div className={`mb-4 p-4 rounded-xl ${theme === 'dark' ? 'bg-[#0B0E11]' : 'bg-gray-50'}`}>
                <p className={`text-sm mb-1 ${theme === 'dark' ? 'text-gray-400' : 'text-gray-600'}`}>
                  单笔止损额：
                  <span className="text-xs ml-1">({balance.toFixed(2)}*{percentage}%={rawStopLoss.toFixed(2)} USDT 向上取整)</span>
                </p>
                <div className="flex items-baseline gap-2">
                  <p className="text-2xl font-bold text-[var(--t-brand)]">{roundedStopLoss.toFixed(2)} USDT</p>
                  {!loading && isCurrent && <span className="text-[var(--t-brand)]" style={{ fontSize: '70%' }}>当前</span>}
                </div>
              </div>
              <div className="relative">
                <input
                  type="range"
                  min="1"
                  max="25"
                  value={percentage}
                  onChange={(e) => setPercentage(Number(e.target.value))}
                  disabled={loading}
                  className="w-full h-2 rounded-full appearance-none cursor-pointer disabled:opacity-50"
                  style={{
                    background: `linear-gradient(to right, var(--t-brand) 0%, var(--t-brand) ${((percentage - 1) / 24) * 100}%, ${theme === 'dark' ? '#2B2F36' : '#E5E7EB'} ${((percentage - 1) / 24) * 100}%, ${theme === 'dark' ? '#2B2F36' : '#E5E7EB'} 100%)`,
                  }}
                />
                <div className="flex justify-between mt-2">
                  <span className={`text-xs ${theme === 'dark' ? 'text-gray-500' : 'text-gray-400'}`}>1%</span>
                  <span className={`text-xs ${theme === 'dark' ? 'text-gray-500' : 'text-gray-400'}`}>25%</span>
                </div>
              </div>
            </div>

            <div className="space-y-2">
              <p className={`text-xs leading-relaxed ${theme === 'dark' ? 'text-gray-500' : 'text-gray-500'}`}>1. 止损金额按合约、资金、现货三类账户的 USDT 总资产计算</p>
              <p className={`text-xs leading-relaxed ${theme === 'dark' ? 'text-gray-500' : 'text-gray-500'}`}>2. 止损金额设定后，不再随账户余额变动而变动</p>
              <p className={`text-xs leading-relaxed ${theme === 'dark' ? 'text-gray-500' : 'text-gray-500'}`}>3. 确认后止损额立即生效（测试阶段暂不启用调高冷却）</p>
            </div>

            {pendingStopLoss !== null && (
              <div className={`rounded-lg p-3 flex items-center justify-between ${theme === 'dark' ? 'bg-[var(--t-brand)]/10' : 'bg-yellow-100'}`}>
                <span className={`text-sm ${theme === 'dark' ? 'text-[var(--t-brand)]' : 'text-yellow-900'}`}>
                  您已调整止损金额{pendingStopLoss.from.toFixed(0)} → {pendingStopLoss.to.toFixed(0)}，{formatCountdown(countdown)}后生效
                </span>
                <button
                  onClick={handleCancelPending}
                  className={`text-sm underline ml-2 whitespace-nowrap ${theme === 'dark' ? 'text-[var(--t-brand)] hover:text-[var(--t-brand-hover)]' : 'text-yellow-900 hover:text-yellow-800'} transition-colors`}
                >
                  取消
                </button>
              </div>
            )}

            {completedAdjustment !== null && (
              <div className={`rounded-lg p-3 flex items-center justify-between ${theme === 'dark' ? 'bg-[#0ECB81]/10' : 'bg-green-100'}`}>
                <span className={`text-sm ${theme === 'dark' ? 'text-[#0ECB81]' : 'text-green-900'}`}>
                  您已调整止损金额{completedAdjustment.from.toFixed(0)} → {completedAdjustment.to.toFixed(0)}。
                </span>
                <button
                  onClick={() => setCompletedAdjustment(null)}
                  className={`text-sm underline ml-2 whitespace-nowrap ${theme === 'dark' ? 'text-[#0ECB81] hover:text-[#0DB574]' : 'text-green-900 hover:text-green-800'} transition-colors`}
                >
                  知道了
                </button>
              </div>
            )}

            <button
              onClick={handleConfirm}
              disabled={loading || isCurrent || saving}
              className={`w-full font-bold py-4 rounded-xl transition-all ${
                loading || isCurrent || saving
                  ? theme === 'dark'
                    ? 'bg-[#2B2F36] text-gray-500 cursor-not-allowed'
                    : 'bg-gray-300 text-gray-500 cursor-not-allowed'
                  : 'bg-gradient-to-r from-[var(--t-brand)] to-[var(--t-brand-hover)] text-black hover:shadow-lg hover:shadow-[var(--t-brand)]/30 active:scale-[0.98]'
              }`}
            >
              {saving ? '提交中...' : '确定'}
            </button>
          </div>
        </div>

        <style>{`
          input[type="range"]::-webkit-slider-thumb {
            appearance: none;
            width: 20px;
            height: 20px;
            border-radius: 50%;
            background: var(--t-brand);
            cursor: pointer;
            border: 3px solid ${theme === 'dark' ? '#1A1D23' : 'white'};
            box-shadow: 0 2px 8px rgba(240, 185, 11, 0.3);
          }
          input[type="range"]::-moz-range-thumb {
            width: 20px;
            height: 20px;
            border-radius: 50%;
            background: var(--t-brand);
            cursor: pointer;
            border: 3px solid ${theme === 'dark' ? '#1A1D23' : 'white'};
            box-shadow: 0 2px 8px rgba(240, 185, 11, 0.3);
          }
        `}</style>
      </div>

      {confirmDialog && (
        <ConfirmDialog
          isOpen={confirmDialog.isOpen}
          message={confirmDialog.message}
          onConfirm={confirmDialog.onConfirm}
          onCancel={() => setConfirmDialog(null)}
          theme={theme}
        />
      )}
    </>,
    document.body,
  )
}
