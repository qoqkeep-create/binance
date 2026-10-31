import { useEffect, useId, useRef } from 'react'

const FOCUSABLE_SELECTOR = [
  'button:not([disabled])',
  'a[href]',
  'input:not([disabled])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  '[tabindex]:not([tabindex="-1"])',
].join(',')

export function useModalAccessibility(
  isOpen: boolean,
  onClose: () => void,
  closeBlocked = false,
) {
  const dialogRef = useRef<HTMLDivElement>(null)
  const titleId = useId()
  const onCloseRef = useRef(onClose)
  const closeBlockedRef = useRef(closeBlocked)

  onCloseRef.current = onClose
  closeBlockedRef.current = closeBlocked

  useEffect(() => {
    if (!isOpen) return

    const previousFocus = document.activeElement instanceof HTMLElement
      ? document.activeElement
      : null
    const focusTimer = window.setTimeout(() => {
      const dialog = dialogRef.current
      if (!dialog) return
      const preferred = dialog.querySelector<HTMLElement>('[data-modal-autofocus]')
      const first = dialog.querySelector<HTMLElement>(FOCUSABLE_SELECTOR)
      ;(preferred || first || dialog).focus()
    }, 0)

    const handleKeyDown = (event: KeyboardEvent) => {
      const dialog = dialogRef.current
      if (!dialog) return
      if (event.key === 'Escape' && !closeBlockedRef.current) {
        event.preventDefault()
        onCloseRef.current()
        return
      }
      if (event.key !== 'Tab') return

      const focusable = Array.from(dialog.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR))
      if (focusable.length === 0) {
        event.preventDefault()
        dialog.focus()
        return
      }
      const first = focusable[0]
      const last = focusable[focusable.length - 1]
      const active = document.activeElement
      if (event.shiftKey && (active === first || !dialog.contains(active))) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && (active === last || !dialog.contains(active))) {
        event.preventDefault()
        first.focus()
      }
    }

    document.addEventListener('keydown', handleKeyDown)
    return () => {
      window.clearTimeout(focusTimer)
      document.removeEventListener('keydown', handleKeyDown)
      if (previousFocus?.isConnected) previousFocus.focus()
    }
  }, [isOpen])

  return {
    dialogRef,
    titleId,
    dialogProps: {
      ref: dialogRef,
      role: 'dialog' as const,
      'aria-modal': true,
      'aria-labelledby': titleId,
      tabIndex: -1,
    },
  }
}
