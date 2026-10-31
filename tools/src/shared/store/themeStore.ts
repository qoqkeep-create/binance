import { create } from 'zustand'
import { persist } from 'zustand/middleware'

// ============ 类型定义 ============

type Theme = 'dark' | 'light'

interface ThemeState {
  theme: Theme
  toggleTheme: () => void
  setTheme: (theme: Theme) => void
}

// ============ Store ============

export const useThemeStore = create<ThemeState>()(
  persist(
    set => ({
      theme: 'dark',

      toggleTheme: () =>
        set(state => {
          const newTheme = state.theme === 'dark' ? 'light' : 'dark'
          applyTheme(newTheme)
          return { theme: newTheme }
        }),

      setTheme: theme => {
        applyTheme(theme)
        set({ theme })
      },
    }),
    {
      name: 'theme-storage',
      onRehydrateStorage: () => state => {
        // 恢复后应用主题
        if (state?.theme) {
          applyTheme(state.theme)
        }
      },
    }
  )
)

// ============ 主题应用 ============

function applyTheme(theme: Theme) {
  const root = document.documentElement

  if (theme === 'dark') {
    root.classList.add('dark')
  } else {
    root.classList.remove('dark')
  }

  // Safari 顶部状态区域更依赖浏览器主题色；暗色用标题栏色，避免出现偏黑断层
  const metaThemeColor = document.querySelector('meta[name="theme-color"]')
  const color = theme === 'dark' ? '#1A1D23' : '#FFFFFF'

  if (metaThemeColor) {
    metaThemeColor.setAttribute('content', color)
  } else {
    const meta = document.createElement('meta')
    meta.name = 'theme-color'
    meta.content = color
    document.head.appendChild(meta)
  }

  // 兜底同步根背景，兼容 Safari 对顶部空白区域取色
  root.style.backgroundColor = color
}

// 初始化时应用主题
if (typeof window !== 'undefined') {
  const stored = localStorage.getItem('theme-storage')
  if (stored) {
    try {
      const { state } = JSON.parse(stored)
      if (state?.theme) {
        applyTheme(state.theme)
      }
    } catch {
      applyTheme('dark')
    }
  } else {
    applyTheme('dark')
  }
}
