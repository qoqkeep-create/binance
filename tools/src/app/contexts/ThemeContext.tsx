/**
 * 主题 Hook - 兼容层
 *
 * 此文件保持向后兼容，内部使用 Zustand store
 */
import { useThemeStore } from '@/shared/store'

export type Theme = 'dark' | 'light'

export interface ThemeContextType {
  theme: Theme
  toggleTheme: () => void
}

/**
 * 获取当前主题和切换函数
 *
 * @example
 * const { theme, toggleTheme } = useTheme()
 */
export function useTheme(): ThemeContextType {
  const theme = useThemeStore(state => state.theme)
  const toggleTheme = useThemeStore(state => state.toggleTheme)

  return { theme, toggleTheme }
}

/**
 * ThemeProvider - 兼容层（不再需要）
 *
 * 保留此组件仅为向后兼容，实际上不执行任何操作
 * 因为 Zustand store 已经处理了主题状态
 */
export function ThemeProvider({ children }: { children: React.ReactNode }) {
  return <>{children}</>
}
