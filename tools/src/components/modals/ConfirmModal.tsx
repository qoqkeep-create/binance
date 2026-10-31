import { ReactNode } from 'react'
import { useModalAccessibility } from './useModalAccessibility'

interface ConfirmModalProps {
  isOpen: boolean
  onClose: () => void
  onConfirm: () => void
  title: string
  children: ReactNode
  confirmText?: string
  cancelText?: string
  showCancel?: boolean
  confirmVariant?: 'brand' | 'danger'
  busy?: boolean
}

export function ConfirmModal({
  isOpen,
  onClose,
  onConfirm,
  title,
  children,
  confirmText = '确认',
  cancelText = '取消',
  showCancel = true,
  confirmVariant = 'brand',
  busy = false,
}: ConfirmModalProps) {
  const close = () => { if (!busy) onClose() }
  const { dialogProps, titleId } = useModalAccessibility(isOpen, close, busy)
  if (!isOpen) return null

  const confirmClass =
    confirmVariant === 'danger'
      ? 'bg-gradient-to-r from-[#F6465D] to-[#E83E3E] text-white hover:shadow-lg hover:shadow-[#F6465D]/30'
      : 'bg-gradient-to-r from-[var(--t-brand)] to-[var(--t-brand-hover)] text-black hover:shadow-lg hover:shadow-[var(--t-brand)]/30'

  return (
    <div className="fixed inset-0 z-[120] flex items-center justify-center p-4">
      <div
        aria-hidden="true"
        className="absolute inset-0 bg-black/60 backdrop-blur-sm"
        onClick={close}
      />
      <div {...dialogProps} className="relative max-w-sm w-full rounded-2xl p-6 shadow-2xl bg-t-modal">
        <h3 id={titleId} className="text-lg font-bold mb-3 text-t-text">{title}</h3>
        <div className="mb-6 text-sm text-t-text-secondary">{children}</div>
        <div className="flex gap-3">
          {showCancel && (
            <button
              data-modal-autofocus
              onClick={close}
              disabled={busy}
              className="flex-1 py-3 rounded-xl font-medium transition-colors bg-t-btn-secondary text-t-text hover:bg-t-btn-secondary-hover disabled:opacity-50"
            >
              {cancelText}
            </button>
          )}
          <button
            data-modal-autofocus={!showCancel ? true : undefined}
            onClick={onConfirm}
            disabled={busy}
            className={`flex-1 py-3 rounded-xl font-medium transition-all active:scale-[0.98] disabled:opacity-50 ${confirmClass}`}
          >
            {confirmText}
          </button>
        </div>
      </div>
    </div>
  )
}
