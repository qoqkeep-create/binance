interface IndicatorDetailModalProps {
  isOpen: boolean
  onClose: () => void
  indicatorName: string
}

interface IndicatorCondition {
  id: string
  text: string
}

interface StoredIndicator {
  name: string
  requiredConditions?: IndicatorCondition[]
  optionalConditions?: IndicatorCondition[]
}

function isIndicatorCondition(value: unknown): value is IndicatorCondition {
  if (typeof value !== 'object' || value === null) return false
  const condition = value as Record<string, unknown>
  return typeof condition.id === 'string' && typeof condition.text === 'string'
}

function isStoredIndicator(value: unknown): value is StoredIndicator {
  if (typeof value !== 'object' || value === null) return false
  const indicator = value as Record<string, unknown>
  if (typeof indicator.name !== 'string') return false
  const required = indicator.requiredConditions
  const optional = indicator.optionalConditions
  return (
    (required === undefined ||
      (Array.isArray(required) && required.every(isIndicatorCondition))) &&
    (optional === undefined ||
      (Array.isArray(optional) && optional.every(isIndicatorCondition)))
  )
}

export function IndicatorDetailModal({ isOpen, onClose, indicatorName }: IndicatorDetailModalProps) {
  if (!isOpen) return null

  const getIndicatorData = () => {
    const stored = localStorage.getItem('crypto_trading_indicators')
    if (stored) {
      try {
        const indicators: unknown = JSON.parse(stored)
        if (!Array.isArray(indicators)) return null
        return indicators.find(
          (indicator: unknown): indicator is StoredIndicator =>
            isStoredIndicator(indicator) && indicator.name === indicatorName,
        )
      } catch {
        return null
      }
    }
    return null
  }

  const indicator = getIndicatorData()

  if (!indicator) {
    return (
      <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm" onClick={onClose}>
        <div className="mx-4 w-full max-w-sm rounded-2xl p-6 bg-t-modal" onClick={(e) => e.stopPropagation()}>
          <p className="text-center text-t-text">未找到指标数据</p>
          <button onClick={onClose} className="w-full mt-4 py-3 rounded-xl bg-[#F0B90B] text-black font-medium">关闭</button>
        </div>
      </div>
    )
  }

  const requiredConditions = indicator.requiredConditions ?? []
  const optionalConditions = indicator.optionalConditions ?? []

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm" onClick={onClose}>
      <div className="mx-4 w-full max-w-sm rounded-2xl p-6 bg-t-modal" onClick={(e) => e.stopPropagation()}>
        <h3 className="mb-4 text-lg font-bold text-center text-t-text">{indicator.name}</h3>

        <div className="rounded-lg p-4 mb-6 bg-t-surface-input">
          {requiredConditions.length > 0 && (
            <div className="mb-4">
              <div className="flex items-center justify-between mb-3">
                <h4 className="text-sm font-medium text-t-text">必备条件</h4>
                <span className="text-[#F6465D] text-xs">*必须全部满足</span>
              </div>
              <div className="space-y-2">
                {requiredConditions.map(c => (
                  <div key={c.id} className="flex items-start gap-3 p-3 rounded-lg bg-t-surface">
                    <div className="w-1.5 h-1.5 rounded-full bg-[#F6465D] flex-shrink-0 mt-2" />
                    <span className="flex-1 text-sm text-t-text-secondary">{c.text}</span>
                  </div>
                ))}
              </div>
            </div>
          )}

          {requiredConditions.length > 0 && optionalConditions.length > 0 && (
            <div className="h-px my-4 bg-t-border" />
          )}

          {optionalConditions.length > 0 && (
            <div>
              <div className="flex items-center justify-between mb-3">
                <h4 className="text-sm font-medium text-t-text">可选条件</h4>
                <span className="text-[#3DD598] text-xs">满足更多更佳</span>
              </div>
              <div className="space-y-2">
                {optionalConditions.map(c => (
                  <div key={c.id} className="flex items-start gap-3 p-3 rounded-lg bg-t-surface">
                    <div className="w-1.5 h-1.5 rounded-full bg-[#3DD598] flex-shrink-0 mt-2" />
                    <span className="flex-1 text-sm text-t-text-secondary">{c.text}</span>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>

        <button onClick={onClose}
          className="w-full py-3 rounded-xl bg-gradient-to-r from-[#F0B90B] to-[#D9A70A] text-black font-medium hover:shadow-lg hover:shadow-[#F0B90B]/30 transition-all">
          关闭
        </button>
      </div>
    </div>
  )
}
