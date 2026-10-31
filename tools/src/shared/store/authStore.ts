import { create } from 'zustand'
import { persist, devtools } from 'zustand/middleware'
import { tokenManager } from '@/shared/lib/api'
import {
  advanceAccountSessionRevision,
  clearAccountScopedCaches,
} from '@/shared/lib/accountBalanceState'
import { useTradingStore } from './tradingStore'

// ============ 类型定义 ============

interface User {
  id: string
  email: string
  nickname?: string
  avatar?: string
  preflightCompletedAt?: string
}

interface AuthState {
  user: User | null
  isAuthenticated: boolean

  // Actions
  login: (user: User, token: string) => void
  logout: () => void
  updateUser: (updates: Partial<User>) => void
}

// ============ Store ============

export const useAuthStore = create<AuthState>()(
  devtools(
    persist(
      set => ({
        user: null,
        isAuthenticated: false,

        login: (user, token) => {
          advanceAccountSessionRevision()
          useTradingStore.getState().activateAccount(user.id)
          tokenManager.set(token)
          set({ user, isAuthenticated: true })
        },

        logout: () => {
          const userId = useAuthStore.getState().user?.id || ''
          advanceAccountSessionRevision()
          tokenManager.remove()
          clearAccountScopedCaches(userId)
          useTradingStore.getState().resetAccountState()
          set({ user: null, isAuthenticated: false })
        },

        updateUser: updates =>
          set(state => ({
            user: state.user ? { ...state.user, ...updates } : null,
          })),
      }),
      {
        name: 'auth-storage',
        partialize: state => ({
          user: state.user,
          isAuthenticated: state.isAuthenticated,
        }),
        onRehydrateStorage: () => state => {
          if (state?.user?.id) {
            useTradingStore.getState().activateAccount(state.user.id)
          } else {
            useTradingStore.getState().resetAccountState()
          }
        },
      }
    ),
    { name: 'AuthStore', enabled: import.meta.env.VITE_ENABLE_DEVTOOLS === 'true' }
  )
)

// ============ 监听未授权事件 ============

if (typeof window !== 'undefined') {
  window.addEventListener('auth:unauthorized', () => {
    useAuthStore.getState().logout()
  })
}
