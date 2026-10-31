import type { Strategy } from '@/shared/types'
import { formatStrategyLevelText } from '@/shared/lib/strategyText'

interface StrategyDetailModalProps {
  isOpen: boolean
  onClose: () => void
  strategy: Strategy
  logs: string[]
  logsLoading?: boolean
  onCancelStrategy?: () => void
  showCancelAction?: boolean
  closeText?: string
  hideFooterActions?: boolean
}

export function StrategyDetailModal({
  isOpen,
  onClose,
  strategy,
  logs,
  logsLoading = false,
  onCancelStrategy,
  showCancelAction = true,
  closeText = '关闭',
  hideFooterActions = false,
}: StrategyDetailModalProps) {
  if (!isOpen) return null

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm overscroll-none"
      onClick={onClose}
      onWheel={(e) => e.stopPropagation()}
      onTouchMove={(e) => e.stopPropagation()}
    >
      <div
        className="mx-4 w-full max-w-sm max-h-[calc(100dvh-48px)] rounded-2xl p-6 transition-colors bg-t-modal flex flex-col overflow-hidden"
        onClick={(e) => e.stopPropagation()}
        onWheel={(e) => e.stopPropagation()}
        onTouchMove={(e) => e.stopPropagation()}
      >
        <div className="mb-4 flex items-center justify-between gap-3">
          <div className="w-8" />
          <h3 className="text-lg font-bold text-center text-t-text">策略和执行日志</h3>
          <button
            onClick={onClose}
            className="flex h-8 w-8 items-center justify-center rounded-full text-t-text-muted transition-colors hover:bg-t-surface-hover"
            aria-label="关闭"
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <line x1="18" y1="6" x2="6" y2="18" />
              <line x1="6" y1="6" x2="18" y2="18" />
            </svg>
          </button>
        </div>

        <div className="rounded-xl p-4 mb-6 bg-t-surface-input overflow-y-auto overscroll-contain min-h-0">
          <div className="text-sm text-t-text-secondary">
            <div className="mb-2">
              <div className="font-medium text-t-text whitespace-nowrap overflow-hidden text-ellipsis">策略名称：{strategy.name}</div>
            </div>
            <div className="space-y-2">
              {strategy.levels.map((level, index) => (
                <div key={index}>{formatStrategyLevelText(level, index)}</div>
              ))}
            </div>
            <div className="my-3 border-t border-t-border" />
            <div className="font-medium text-t-text mb-1">执行日志：</div>
            {logsLoading ? (
              <div>加载中...</div>
            ) : logs.length > 0 ? (
              <div className="space-y-1">
                {logs.map((line, i) => (
                  <div key={i}>{line}</div>
                ))}
              </div>
            ) : (
              <div>暂未执行任何止损止盈操作</div>
            )}
          </div>
        </div>

        {!hideFooterActions && showCancelAction ? (
          <div className="flex gap-3">
            <button onClick={onClose}
              className="flex-1 py-3 rounded-xl font-medium transition-colors bg-t-btn-secondary text-t-text hover:bg-t-btn-secondary-hover">
              {closeText}
            </button>
            <button onClick={onCancelStrategy}
              className="flex-1 py-3 rounded-xl font-medium bg-[#F6465D] text-white hover:bg-[#E5354C] transition-colors">
              取消策略
            </button>
          </div>
        ) : !hideFooterActions ? (
          <div className="flex">
            <button onClick={onClose}
              className="w-full py-3 rounded-xl font-medium transition-colors bg-t-btn-secondary text-t-text hover:bg-t-btn-secondary-hover">
              {closeText}
            </button>
          </div>
        ) : null}
      </div>
    </div>
  )
}
