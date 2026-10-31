import { useEffect, useState } from 'react'
import { ArrowLeft, Moon, Sun, SettingsIcon } from 'lucide-react'
import { useNavigate } from 'react-router-dom'

import { useTheme } from '@/app/contexts/ThemeContext'
import { api, ApiError } from '@/shared/lib/api'
import { isStandaloneMode } from '@/shared/lib/device'
import { showToast } from '@/shared/store'

interface AdminSettingsData {
  is_admin: boolean
  open_registration: boolean
}

/**
 * 设置页：对所有用户常驻。
 * - 颜色模式保留在设置页；止损额设置位于「我的」页账户控制区；
 * - 「开放注册」开关仅管理员身份判定通过后展示；
 * - 顶部标题与内容区样式参照「我的策略」页。
 */
export function SettingsPage() {
  const standalone = isStandaloneMode()
  const navigate = useNavigate()
  const { theme, toggleTheme } = useTheme()

  const [isAdmin, setIsAdmin] = useState(false)
  const [openRegistration, setOpenRegistration] = useState(false)
  const [saving, setSaving] = useState(false)

  useEffect(() => {
    let cancelled = false
    // 管理员判定：失败/非管理员时仅隐藏「开放注册」，页面其余部分正常展示
    api
      .get<AdminSettingsData>('/auth/admin-settings')
      .then(data => {
        if (cancelled) return
        setIsAdmin(Boolean(data.is_admin))
        setOpenRegistration(Boolean(data.open_registration))
      })
      .catch(() => {
        // ignore
      })
    return () => {
      cancelled = true
    }
  }, [])

  const toggleOpenRegistration = async () => {
    if (saving) return
    const next = !openRegistration
    setSaving(true)
    try {
      const data = await api.post<AdminSettingsData>('/auth/admin-settings', { open_registration: next })
      setOpenRegistration(data.open_registration)
      showToast(data.open_registration ? '开放注册已开启' : '开放注册已关闭')
    } catch (error) {
      showToast(error instanceof ApiError ? error.message : '设置失败，请稍后重试')
      try {
        const data = await api.get<AdminSettingsData>('/auth/admin-settings')
        setOpenRegistration(data.open_registration)
      } catch {
        // ignore
      }
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="h-full min-h-0 flex flex-col overflow-hidden transition-colors bg-t-page text-t-text">
      {/* Header：与「我的策略」页同款 */}
      <div
        className="shrink-0 px-4 pb-4 border-b transition-colors bg-t-surface border-t-border"
        style={{ paddingTop: standalone ? 'max(44px, env(safe-area-inset-top, 0px))' : 'env(safe-area-inset-top, 0px)' }}
      >
        <div className="h-11 flex items-center justify-center max-w-md mx-auto relative">
          <button
            onClick={() => navigate('/profile')}
            className="absolute left-0 p-2 rounded-lg transition-colors hover:bg-t-surface-hover"
            aria-label="返回我的"
          >
            <ArrowLeft size={20} />
          </button>
          <h1 className="text-lg font-bold">设置</h1>
        </div>
      </div>

      {/* Content：与「我的策略」页同款滚动区 */}
      <div
        className="flex-1 min-h-0 overflow-y-scroll overscroll-contain hide-scrollbar bg-t-page"
        style={{
          WebkitOverflowScrolling: 'touch',
          overscrollBehaviorY: 'contain',
          touchAction: 'pan-y',
        }}
      >
        <div className="max-w-md mx-auto w-full px-4 py-4 space-y-4">
          {/* 通用设置：颜色模式 */}
          <div className="rounded-2xl overflow-hidden bg-t-surface border border-t-border">
            {/* 颜色模式 */}
            <button
              onClick={toggleTheme}
              className="w-full flex items-center justify-between p-4 transition-all hover:bg-t-surface-hover"
            >
              <div className="flex items-center gap-3">
                <div className="w-10 h-10 rounded-xl flex items-center justify-center bg-yellow-100 dark:bg-[#F0B90B]/10">
                  {theme === 'dark' ? <Moon size={20} className="text-[#F0B90B]" /> : <Sun size={20} className="text-[#F0B90B]" />}
                </div>
                <span className="font-medium text-t-text">颜色模式</span>
              </div>
              <div className="flex items-center gap-3">
                <span className="text-sm font-medium text-t-text-secondary">{theme === 'dark' ? '深色' : '浅色'}</span>
                <div className="relative w-12 h-7 rounded-full transition-all duration-300 shadow-inner bg-gray-200 dark:bg-[#2B2F36]">
                  <div className={`absolute top-1 w-5 h-5 rounded-full transition-all duration-300 shadow-md ${
                    theme === 'dark'
                      ? 'translate-x-6 bg-gradient-to-br from-[#F0B90B] to-[#D9A70A]'
                      : 'translate-x-1 bg-white'
                  }`} />
                </div>
              </div>
            </button>

          </div>

          {/* 管理员设置：仅管理员可见 */}
          {isAdmin && (
            <div className="rounded-2xl overflow-hidden bg-t-surface border border-t-border">
              <div className="flex items-center gap-2 px-4 pt-4">
                <SettingsIcon size={16} className="text-[#F0B90B]" />
                <span className="text-sm font-medium text-t-text-secondary">管理员</span>
              </div>
              <div className="flex items-center justify-between p-4">
                <div className="min-w-0 pr-3">
                  <div className="font-medium text-t-text">开放注册</div>
                  <div className="mt-1 text-xs leading-relaxed text-t-text-muted">
                    开启后其他用户可以注册新账号；关闭后注册将被拒绝
                  </div>
                </div>
                <button
                  type="button"
                  role="switch"
                  aria-checked={openRegistration}
                  disabled={saving}
                  onClick={() => void toggleOpenRegistration()}
                  className={`relative h-7 w-12 shrink-0 rounded-full transition-colors ${
                    openRegistration ? 'bg-[#F0B90B]' : 'bg-t-border'
                  } ${saving ? 'opacity-60' : ''}`}
                >
                  <span
                    className={`absolute top-0.5 h-6 w-6 rounded-full bg-white shadow transition-all ${
                      openRegistration ? 'left-[22px]' : 'left-0.5'
                    }`}
                  />
                </button>
              </div>
            </div>
          )}
        </div>
      </div>

    </div>
  )
}
