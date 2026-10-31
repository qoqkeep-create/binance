import { useEffect } from 'react'
import { useToastStore } from '@/shared/store/toastStore'

export function Toast() {
  const { message, visible, duration, hide } = useToastStore()

  useEffect(() => {
    if (!visible) return
    const timer = setTimeout(hide, duration)
    return () => clearTimeout(timer)
  }, [visible, message, duration, hide])

  if (!visible) return null

  return (
    <div className="fixed inset-0 z-[100] flex items-center justify-center pointer-events-none">
      <div
        className="rounded-2xl px-8 py-6 flex flex-col items-center gap-3 max-w-[70vw] shadow-lg animate-in fade-in duration-200"
        style={{ backgroundColor: '#4a5565' }}
      >
        <svg viewBox="0 0 1024 1024" width="36" height="36" fill="#ffffff">
          <path d="M512 960c49.6 0 88-38.4 88-88H424c0 49.6 38.4 88 88 88z m288.8-286.4V444.8c0-137.6-97.6-252.8-224.8-283.2v-28.8c0-32-17.6-60.8-48-67.2-44-10.4-80 23.2-80 66.4v30.4C320.8 192 223.2 307.2 223.2 444.8v228.8L136 763.2v44.8h752v-44.8l-87.2-89.6z" />
        </svg>
        <span className="text-white text-sm text-center leading-relaxed whitespace-pre-line">{message}</span>
      </div>
    </div>
  )
}
