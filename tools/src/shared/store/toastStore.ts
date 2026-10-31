import { create } from 'zustand'

interface ToastState {
  message: string
  visible: boolean
  duration: number
  show: (message: string, duration?: number) => void
  hide: () => void
}

export const useToastStore = create<ToastState>((set) => ({
  message: '',
  visible: false,
  duration: 2500,
  show: (message: string, duration = 2500) => {
    set({ message, visible: true, duration })
  },
  hide: () => {
    set({ visible: false })
  },
}))

/** 全局调用: showToast('提示文字')；可选第二参数指定显示毫秒数。 */
export const showToast = (message: string, duration = 2500) => {
  useToastStore.getState().show(message, duration)
}
