import { X } from 'lucide-react'
import { useModalAccessibility } from './useModalAccessibility'

interface OpenPositionConfirmModalProps {
  isOpen: boolean
  onClose: () => void
  onConfirm: () => void
  direction: 'long' | 'short'
  tradingPair: string
  stopLossPrice?: string
  limitPrice?: string
  position: number
  fee: number
  stopLossAmount: number
  includeFeesInStopLoss: boolean
  stopLossRetracement?: number
  theme?: 'dark' | 'light'
  mode?: 'market' | 'limit'
  loading?: boolean
}

function formatDisplayNumber(value: number): string {
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

export function OpenPositionConfirmModal({
  isOpen,
  onClose,
  onConfirm,
  direction,
  tradingPair,
  stopLossPrice,
  limitPrice,
  position,
  fee,
  stopLossAmount,
  includeFeesInStopLoss,
  stopLossRetracement,
  theme = 'dark',
  mode = 'market',
  loading = false,
}: OpenPositionConfirmModalProps) {
  const { dialogProps, titleId } = useModalAccessibility(isOpen, onClose, loading)
  if (!isOpen) return null

  const actualStopLoss = includeFeesInStopLoss ? stopLossAmount : stopLossAmount + fee
  const directionText = direction === 'long' ? '多' : '空'
  const directionColor = direction === 'long' ? '#0ECB81' : '#F6465D'
  const simplifiedPair = tradingPair.replace(/X\d+$/, '').replace('USDT', '')
  const title = mode === 'limit' ? '委托确认' : '开仓确认'

  return (
    <div className="fixed inset-0 z-[60] flex items-center justify-center p-4">
      <div
        aria-hidden="true"
        className="absolute inset-0 bg-black/60 backdrop-blur-sm animate-[fadeIn_180ms_ease-out]"
        onClick={loading ? undefined : onClose}
      />

      <div
        {...dialogProps}
        className={`relative w-full max-w-sm rounded-2xl shadow-2xl transition-colors animate-[modalFadeIn_220ms_ease-out] ${
          theme === 'dark' ? 'bg-[#1A1D23]' : 'bg-white'
        }`}
      >
        <div className="flex items-center justify-between p-6 pb-4">
          <h2 id={titleId} className={`text-lg font-bold ${theme === 'dark' ? 'text-white' : 'text-gray-900'}`}>{title}</h2>
          <button
            aria-label="关闭"
            onClick={onClose}
            disabled={loading}
            className={`rounded-lg p-2 transition-colors ${
              theme === 'dark' ? 'hover:bg-[#2B2F36]' : 'hover:bg-gray-100'
            } disabled:opacity-50`}
          >
            <X size={20} className={theme === 'dark' ? 'text-gray-400' : 'text-gray-600'} />
          </button>
        </div>

        <div className="space-y-5 px-6 pb-6">
          <div className="text-center">
            <p className="text-lg font-bold uppercase" style={{ color: directionColor }}>
              即将开{simplifiedPair} {directionText}单
            </p>
          </div>

          <div className={`space-y-3 rounded-xl p-4 ${theme === 'dark' ? 'bg-[#0B0E11]' : 'bg-gray-50'}`}>
            <div className="flex items-center justify-between">
              <span className={`text-sm ${theme === 'dark' ? 'text-gray-400' : 'text-gray-600'}`}>币种</span>
              <span className={`text-base font-medium ${theme === 'dark' ? 'text-[var(--t-brand)]' : 'text-gray-900'}`}>
                {tradingPair}
              </span>
            </div>

            <div className="flex items-center justify-between">
              <span className={`text-sm ${theme === 'dark' ? 'text-gray-400' : 'text-gray-600'}`}>模式</span>
              <span className={`text-base font-medium ${theme === 'dark' ? 'text-[var(--t-brand)]' : 'text-gray-900'}`}>
                {mode === 'limit' ? '限价委托' : '市价开仓'}
              </span>
            </div>

            {stopLossPrice && (
              <div className="flex items-center justify-between">
                <span className={`text-sm ${theme === 'dark' ? 'text-gray-400' : 'text-gray-600'}`}>止损价</span>
                <span className={`text-base font-medium ${theme === 'dark' ? 'text-[var(--t-brand)]' : 'text-gray-900'}`}>
                  {stopLossPrice}
                </span>
              </div>
            )}

            {mode === 'limit' && limitPrice && (
              <div className="flex items-center justify-between">
                <span className={`text-sm ${theme === 'dark' ? 'text-gray-400' : 'text-gray-600'}`}>限价值</span>
                <span className={`text-base font-medium ${theme === 'dark' ? 'text-[var(--t-brand)]' : 'text-gray-900'}`}>
                  {limitPrice}
                </span>
              </div>
            )}

            <div className="flex items-center justify-between">
              <span className={`text-sm ${theme === 'dark' ? 'text-gray-400' : 'text-gray-600'}`}>仓位</span>
              <span className={`text-base font-medium ${theme === 'dark' ? 'text-[var(--t-brand)]' : 'text-gray-900'}`}>
                {formatDisplayNumber(position)} U
              </span>
            </div>

            <div className="flex items-center justify-between">
              <span className={`text-sm ${theme === 'dark' ? 'text-gray-400' : 'text-gray-600'}`}>手续费</span>
              <div className="text-right">
                <span
                  className="mr-2 text-xs font-medium"
                  style={{ color: includeFeesInStopLoss ? '#0ECB81' : '#F6465D' }}
                >
                  ({includeFeesInStopLoss ? '含' : '不含'})
                </span>
                <span className={`text-base font-medium ${theme === 'dark' ? 'text-[var(--t-brand)]' : 'text-gray-900'}`}>
                  {formatDisplayNumber(fee)} U
                </span>
              </div>
            </div>

            <div className="flex items-center justify-between">
              <span className={`text-sm ${theme === 'dark' ? 'text-gray-400' : 'text-gray-600'}`}>止损额</span>
              <div className="text-right">
                <span className="text-base font-medium text-[var(--t-brand)]">
                  {includeFeesInStopLoss
                    ? `${formatDisplayNumber(stopLossAmount)} U`
                    : `${formatDisplayNumber(stopLossAmount)}+${formatDisplayNumber(fee)}=${formatDisplayNumber(actualStopLoss)} U`}
                </span>
              </div>
            </div>

            {stopLossRetracement !== undefined && (
              <div className="flex items-center justify-between">
                <span className={`text-sm ${theme === 'dark' ? 'text-gray-400' : 'text-gray-600'}`}>止损回撤</span>
                <div className="text-right">
                  {stopLossRetracement < 0.5 && (
                    <span className="mr-2 text-xs font-medium text-[#F6465D]">(过小)</span>
                  )}
                  {stopLossRetracement >= 1 && stopLossRetracement <= 10 && (
                    <span className="mr-2 text-xs font-medium text-[#0ECB81]">(适中)</span>
                  )}
                  {stopLossRetracement > 10 && (
                    <span className="mr-2 text-xs font-medium text-[#F6465D]">(过大)</span>
                  )}
                  <span className={`text-base font-medium ${theme === 'dark' ? 'text-[var(--t-brand)]' : 'text-gray-900'}`}>
                    {stopLossRetracement.toFixed(2)}%
                  </span>
                </div>
              </div>
            )}
          </div>

          <div className="flex gap-3">
            <button
              data-modal-autofocus
              onClick={onClose}
              disabled={loading}
              className={`flex-1 rounded-xl py-3 font-medium transition-colors ${
                theme === 'dark'
                  ? 'bg-[#2B2F36] text-white hover:bg-[#35393F]'
                  : 'bg-gray-200 text-gray-900 hover:bg-gray-300'
              } disabled:opacity-50`}
            >
              取消
            </button>
            <button
              onClick={onConfirm}
              disabled={loading}
              className="flex-1 rounded-xl bg-gradient-to-r from-[var(--t-brand)] to-[var(--t-brand-hover)] py-3 font-bold text-black transition-all hover:shadow-lg hover:shadow-[var(--t-brand)]/30 active:scale-[0.98] disabled:opacity-60"
            >
              {loading ? '提交中...' : '确定'}
            </button>
          </div>
        </div>
      </div>
    </div>
  )
}
