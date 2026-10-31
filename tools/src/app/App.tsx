import { lazy, Suspense, useState, useEffect, useLayoutEffect, useCallback, useRef } from 'react'
import { BrowserRouter, Routes, Route, Navigate, Outlet, useLocation } from 'react-router-dom'

const TradingPage = lazy(() => import('@/pages/trading').then(m => ({ default: m.TradingPage })))
const HoldingsPage = lazy(() => import('@/pages/holdings').then(m => ({ default: m.HoldingsPage })))
const ProfilePage = lazy(() => import('@/pages/profile').then(m => ({ default: m.ProfilePage })))
const IndicatorVerificationPage = lazy(() => import('@/pages/indicator').then(m => ({ default: m.IndicatorVerificationPage })))
const LoginPage = lazy(() => import('@/pages/login').then(m => ({ default: m.LoginPage })))
const UserAgreementPage = lazy(() => import('@/pages/legal/UserAgreementPage').then(m => ({ default: m.UserAgreementPage })))
const PrivacyPolicyPage = lazy(() => import('@/pages/legal/PrivacyPolicyPage').then(m => ({ default: m.PrivacyPolicyPage })))
const StrategyManagementPage = lazy(() => import('@/pages/strategy').then(m => ({ default: m.StrategyManagementPage })))
const StrategyEditorPage = lazy(() => import('@/pages/strategy/StrategyEditorPage').then(m => ({ default: m.StrategyEditorPage })))
const WatchPlanPage = lazy(() => import('@/pages/watch-plan').then(m => ({ default: m.WatchPlanPage })))
const SignalResearchPage = lazy(() => import('@/pages/signal-research').then(m => ({ default: m.SignalResearchPage })))
const SettingsPage = lazy(() => import('@/pages/settings').then(m => ({ default: m.SettingsPage })))
const SignalsPage = lazy(() => import('@/pages/signals').then(m => ({ default: m.SignalsPage })))
const PreflightModal = lazy(() => import('@/pages/preflight').then(m => ({ default: m.PreflightModal })))
const TransferHistoryPage = lazy(() => import('@/pages/transfer-history/exports').then(m => ({ default: m.TransferHistoryPage })))
const OperationLogsPage = lazy(() => import('@/pages/operation-logs/exports').then(m => ({ default: m.OperationLogsPage })))

// Components
import { BottomNavigation } from '@/components/layout/BottomNavigation'
import { Toast } from '@/components/common/Toast'
import { ApiBindModal } from '@/components/modals/ApiBindModal'

// Providers & Stores
import { AppProviders } from './providers'
import { useAuthStore, useTradingStore } from '@/shared/store'
import { api } from '@/shared/lib/api'
import { useTradingMode } from '@/shared/hooks/useTradingMode'
import {
  ACCOUNT_BINDING_CHANGED_EVENT,
  getAccountSessionRevision,
  isCurrentAccountRequestScope,
  isCurrentAccountSession,
} from '@/shared/lib/accountBalanceState'
import { isStandaloneMode, requestAppLayoutSync } from '@/shared/lib/device'
import { getPreflightRemainingMs, isPreflightDue } from '@/shared/lib/preflight'

interface ApiInfoData {
  alias: string
  status: number
}

// ============ 路由守卫 ============

function ProtectedRoute() {
  const isAuthenticated = useAuthStore(state => state.isAuthenticated)

  if (!isAuthenticated) {
    return <Navigate to="/login" replace />
  }
  return <Outlet />
}

// ============ 布局组件 ============

function PageOutlet() {
  return (
    <Suspense fallback={<div role="status" aria-label="页面加载中" className="h-full min-h-40 grid place-items-center text-t-text-muted">加载中...</div>}>
      <Outlet />
    </Suspense>
  )
}

function MainLayout() {
  const isLead = useTradingMode() === 'lead'
  const authUserId = useAuthStore(state => state.user?.id ?? '')
  const apiConfigs = useTradingStore(s => s.apiConfigs)
  const replaceApiConfigs = useTradingStore(s => s.replaceApiConfigs)
  const needBindApi = apiConfigs.length === 0
  const [showApiPrompt, setShowApiPrompt] = useState(false)
  const [showApiBindModal, setShowApiBindModal] = useState(false)
  const [apiChecked, setApiChecked] = useState(false)
  const [bindingRevision, setBindingRevision] = useState(0)
  const apiSyncRequestIdRef = useRef(0)
  const apiPromptDismissedRef = useRef(false)
  const handleApiBoundChange = useCallback((bound: boolean) => {
    if (bound) setShowApiPrompt(false)
  }, [])

  useLayoutEffect(() => {
    apiSyncRequestIdRef.current += 1
    apiPromptDismissedRef.current = false
    setApiChecked(false)
    setShowApiPrompt(false)
    setShowApiBindModal(false)
  }, [authUserId])

  const syncBoundApi = useCallback(async () => {
    const requestUserId = authUserId
    const requestSessionRevision = getAccountSessionRevision()
    const requestId = ++apiSyncRequestIdRef.current
    const info = await api.get<ApiInfoData | null>('/api/info', {
      suppressConnectionError: true,
      disableRetry: true,
      timeout: 8000,
    })
    if (!isCurrentAccountRequestScope(
      requestUserId,
      useAuthStore.getState().user?.id ?? '',
      requestId,
      apiSyncRequestIdRef.current,
      requestSessionRevision,
      getAccountSessionRevision(),
    )) return
    if (!info) {
      replaceApiConfigs([])
      setApiChecked(true)
      requestAppLayoutSync('main-layout-api-empty')
      return
    }
    const id = `api-${info.alias}`
    replaceApiConfigs([
      {
        id,
        apiKey: '',
        secretKey: '',
        passphrase: '',
        alias: info.alias,
        isActive: true,
        createdAt: Date.now(),
      },
    ])
    setApiChecked(true)
    requestAppLayoutSync('main-layout-api-loaded')
  }, [authUserId, replaceApiConfigs])

  useEffect(() => {
    syncBoundApi().catch(() => {
      // 网络抖动时不清空本地绑定态，避免误触发“未绑定”提示
    })
  }, [syncBoundApi])

  useEffect(() => {
    const onBindingChanged = (event: Event) => {
      apiPromptDismissedRef.current = (event as CustomEvent<{ bound?: boolean }>).detail?.bound === false
      setBindingRevision(value => value + 1)
    }
    window.addEventListener(ACCOUNT_BINDING_CHANGED_EVENT, onBindingChanged)
    return () => window.removeEventListener(ACCOUNT_BINDING_CHANGED_EVENT, onBindingChanged)
  }, [])

  useEffect(() => {
    const onResume = () => {
      if (document.visibilityState !== 'visible') return
      syncBoundApi().catch(() => {
        // ignore
      })
    }
    window.addEventListener('app:resume', onResume as EventListener)
    return () => window.removeEventListener('app:resume', onResume as EventListener)
  }, [syncBoundApi])

  // API 绑定后自动关闭弹窗
  useEffect(() => {
    if (!needBindApi) setShowApiPrompt(false)
  }, [needBindApi])

  // 首次进入且未绑定时显示
  useEffect(() => {
    if (apiChecked && needBindApi && !apiPromptDismissedRef.current) setShowApiPrompt(true)
  }, [apiChecked, needBindApi])

  return (
    <div className="h-full flex flex-col overflow-hidden overscroll-none transition-colors bg-t-page text-t-text">
      <div className="flex-1 overflow-hidden overscroll-none">
        <PageOutlet key={`${authUserId}:${bindingRevision}`} />
      </div>
      <BottomNavigation />

      {/* API 未绑定提示弹窗 */}
      {apiChecked && showApiPrompt && needBindApi && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div className="absolute inset-0 bg-black/60 backdrop-blur-sm" onClick={() => setShowApiPrompt(false)} />
          <div className="relative max-w-sm w-full rounded-2xl p-6 shadow-2xl bg-t-modal">
            {/* 关闭按钮 */}
            <button
              onClick={() => setShowApiPrompt(false)}
              className="absolute top-4 right-4 w-8 h-8 flex items-center justify-center rounded-full transition-colors text-t-text-muted hover:bg-t-surface-hover"
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <line x1="18" y1="6" x2="6" y2="18" /><line x1="6" y1="6" x2="18" y2="18" />
              </svg>
            </button>
            <div className="flex justify-center mb-4">
              <div className="w-14 h-14 rounded-full bg-[var(--t-brand)]/10 flex items-center justify-center">
                <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="var(--t-brand)" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z" />
                  <line x1="12" y1="9" x2="12" y2="13" />
                  <line x1="12" y1="17" x2="12.01" y2="17" />
                </svg>
              </div>
            </div>
            <h3 className="text-lg font-bold text-center mb-2 text-t-text">尚未绑定API</h3>
            <p className="text-sm text-center mb-6 leading-relaxed text-t-text-secondary">
              {isLead ? '请使用币安「我的带单」中对应组合创建的 API，绑定后开始带单交易。' : '您还没有绑定交易所API，绑定后才能开始使用交易功能。'}
            </p>
            <button
              onClick={() => {
                setShowApiPrompt(false)
                setShowApiBindModal(true)
              }}
              className="w-full py-3 rounded-xl font-medium bg-gradient-to-r from-[var(--t-brand)] to-[var(--t-brand-hover)] text-black hover:shadow-lg hover:shadow-[var(--t-brand)]/30 transition-all active:scale-[0.98]"
            >
              立即绑定
            </button>
          </div>
        </div>
      )}

      <ApiBindModal
        isOpen={showApiBindModal}
        onClose={() => setShowApiBindModal(false)}
        onBoundChange={handleApiBoundChange}
      />
    </div>
  )
}

function FullScreenLayout() {
  return (
    <div className="min-h-screen transition-colors bg-t-page text-t-text">
      <PageOutlet />
    </div>
  )
}

function FullHeightLayout() {
  const standalone = isStandaloneMode()

  return (
    <div
      className="h-full min-h-0 flex flex-col overflow-hidden transition-colors bg-t-page text-t-text"
      style={standalone ? undefined : { height: '100dvh', maxHeight: '100dvh' }}
    >
      <PageOutlet />
    </div>
  )
}

// ============ 应用内容 ============

function PreflightGate() {
  const isAuthenticated = useAuthStore(state => state.isAuthenticated)
  const user = useAuthStore(state => state.user)
  const authUserId = user?.id ?? ''
  const updateUser = useAuthStore(state => state.updateUser)
  const location = useLocation()
  const [showPreflight, setShowPreflight] = useState(false)
  const statusRequestIdRef = useRef(0)
  const isWatchPlanRoute = location.pathname === '/watch-plan'

  useLayoutEffect(() => {
    statusRequestIdRef.current += 1
    setShowPreflight(false)
  }, [authUserId])

  useEffect(() => {
    if (!isAuthenticated || !isWatchPlanRoute) {
      setShowPreflight(false)
      return
    }

    let cancelled = false

    const syncPreflightStatus = async () => {
      const requestUserId = authUserId
      const requestSessionRevision = getAccountSessionRevision()
      const requestId = ++statusRequestIdRef.current
      const isCurrentRequest = () => !cancelled && isCurrentAccountRequestScope(
        requestUserId,
        useAuthStore.getState().user?.id ?? '',
        requestId,
        statusRequestIdRef.current,
        requestSessionRevision,
        getAccountSessionRevision(),
      )
      try {
        const data = await api.get<{ preflight_completed_at?: string }>('/auth/preflight-status', {
          suppressConnectionError: true,
          disableRetry: true,
          timeout: 8000,
        })
        if (!isCurrentRequest()) return
        const nextValue = data?.preflight_completed_at || ''
        updateUser({ preflightCompletedAt: nextValue })
        setShowPreflight(isPreflightDue(nextValue))
      } catch {
        if (!isCurrentRequest()) return
        setShowPreflight(isPreflightDue(user?.preflightCompletedAt || ''))
      }
    }

    void syncPreflightStatus()

    const onResume = () => {
      if (document.visibilityState !== 'visible') return
      void syncPreflightStatus()
    }

    window.addEventListener('app:resume', onResume as EventListener)
    document.addEventListener('visibilitychange', onResume)
    return () => {
      cancelled = true
      if (statusRequestIdRef.current) statusRequestIdRef.current += 1
      window.removeEventListener('app:resume', onResume as EventListener)
      document.removeEventListener('visibilitychange', onResume)
    }
  }, [authUserId, isAuthenticated, isWatchPlanRoute, updateUser, user?.preflightCompletedAt])

  useEffect(() => {
    if (!isAuthenticated || !isWatchPlanRoute || showPreflight) return
    const remaining = getPreflightRemainingMs(user?.preflightCompletedAt || '')
    if (remaining <= 0) {
      setShowPreflight(true)
      return
    }
    const timer = window.setTimeout(() => setShowPreflight(true), remaining)
    return () => window.clearTimeout(timer)
  }, [isAuthenticated, isWatchPlanRoute, showPreflight, user?.preflightCompletedAt])

  if (!isAuthenticated || !isWatchPlanRoute || !showPreflight) {
    return null
  }

  return (
    <PreflightModal
      onComplete={async () => {
        const requestUserId = authUserId
        const requestSessionRevision = getAccountSessionRevision()
        const data = await api.post<{ preflight_completed_at?: string }>('/auth/preflight-complete', {})
        if (!isCurrentAccountSession(
          requestUserId,
          useAuthStore.getState().user?.id ?? '',
          requestSessionRevision,
          getAccountSessionRevision(),
        )) return
        const nextValue = data?.preflight_completed_at || ''
        updateUser({ preflightCompletedAt: nextValue })
        setShowPreflight(false)
      }}
    />
  )
}

function AppContent() {
  const isAuthenticated = useAuthStore(state => state.isAuthenticated)
  const mode = useTradingMode()

  return (
    <BrowserRouter>
      <>
        <Routes>
          {/* 登录相关路由(全屏布局) */}
          <Route element={<FullScreenLayout />}>
            <Route path="/login" element={<LoginPage />} />
            <Route path="/user-agreement" element={<UserAgreementPage />} />
            <Route path="/privacy-policy" element={<PrivacyPolicyPage />} />
          </Route>

          {/* 受保护的路由 */}
          <Route element={<ProtectedRoute />}>
            {/* 主应用路由(带底部导航) */}
            <Route element={<MainLayout key={mode} />}>
              <Route path="/" element={<Navigate to="/holdings" replace />} />
              <Route path="/trading" element={<TradingPage />} />
              <Route path="/holdings" element={<HoldingsPage />} />
              <Route path="/signals" element={mode === 'lead' ? <Navigate to="/profile" replace /> : <SignalsPage />} />
              <Route path="/profile" element={<ProfilePage />} />
            </Route>

            {/* 全屏页面(无底部导航) */}
            <Route element={<FullScreenLayout />}>
              <Route path="/indicator" element={mode === 'lead' ? <Navigate to="/profile" replace /> : <IndicatorVerificationPage />} />
              <Route path="/watch-plan" element={mode === 'lead' ? <Navigate to="/profile" replace /> : <WatchPlanPage />} />
              <Route path="/signal-research" element={mode === 'lead' ? <Navigate to="/profile" replace /> : <SignalResearchPage />} />
              <Route path="/settings" element={<SettingsPage />} />
            </Route>

            <Route element={<FullHeightLayout />}>
              <Route path="/strategy-management" element={<StrategyManagementPage />} />
              <Route path="/strategy-management/edit/:id?" element={<StrategyEditorPage />} />
              <Route path="/transfer-history" element={mode === 'lead' ? <Navigate to="/profile" replace /> : <TransferHistoryPage />} />
              <Route path="/operation-logs" element={<OperationLogsPage />} />
            </Route>
          </Route>

          {/* 未匹配路由重定向 */}
          <Route
            path="*"
            element={<Navigate to={isAuthenticated ? '/holdings' : '/login'} replace />}
          />
        </Routes>

        <Suspense fallback={null}>
          <PreflightGate />
        </Suspense>
      </>
    </BrowserRouter>
  )
}


// ============ 根组件 ============

export default function App() {
  const mode = useTradingMode()
  useLayoutEffect(() => {
    document.documentElement.dataset.tradingMode = mode
  }, [mode])
  const [isBooting, setIsBooting] = useState(true)
  const [bootTimeout, setBootTimeout] = useState(false)
  const [connectionErrorMessage, setConnectionErrorMessage] = useState('')
  const [showConnectionError, setShowConnectionError] = useState(false)

  useEffect(() => {
    const t = window.setTimeout(() => setBootTimeout(true), 8000)
    requestAnimationFrame(() => requestAnimationFrame(() => setIsBooting(false)))
    return () => window.clearTimeout(t)
  }, [])

  useEffect(() => {
    if (isBooting) return
    requestAppLayoutSync('app-boot-finished')
  }, [isBooting])

  useEffect(() => {
    const onConnectionError = (event: Event) => {
      const detail = (event as CustomEvent<{ message?: string }>).detail
      setConnectionErrorMessage(detail?.message || '无法连接服务器，请检查网络后重试')
      setShowConnectionError(true)
    }

    const onConnectionOk = () => {
      setShowConnectionError(false)
    }

    const onOnline = () => {
      setShowConnectionError(false)
    }

    window.addEventListener('app:connection-error', onConnectionError as EventListener)
    window.addEventListener('app:connection-ok', onConnectionOk)
    window.addEventListener('online', onOnline)
    return () => {
      window.removeEventListener('app:connection-error', onConnectionError as EventListener)
      window.removeEventListener('app:connection-ok', onConnectionOk)
      window.removeEventListener('online', onOnline)
    }
  }, [])

  return (
    <AppProviders>
      {/* 视觉背景层：外层标题栏色 + 中间内容黑底 */}
      <div className="fixed inset-0 bg-t-surface pointer-events-none" />
      <div
        className="fixed top-0 left-1/2 w-full max-w-md -translate-x-1/2 bg-t-page pointer-events-none"
        style={{ bottom: 0 }}
      />

      <div className="relative z-10 h-full overscroll-none">
        <AppContent />
        <Toast />
      </div>

      {isBooting && (
        <div className="fixed inset-0 z-[80] flex items-center justify-center bg-t-page text-t-text">
          <div className="text-center px-6">
            <div className="text-base font-medium">正在启动...</div>
            {bootTimeout && (
              <button
                type="button"
                onClick={() => window.location.reload()}
                className="mt-4 px-4 py-2 rounded-lg bg-[var(--t-brand)] text-black font-medium"
              >
                重新加载
              </button>
            )}
          </div>
        </div>
      )}

      {showConnectionError && !isBooting && (
        <div className="fixed inset-0 z-[110] flex items-center justify-center p-4">
          <div className="absolute inset-0 bg-black/60 backdrop-blur-sm" />
          <div className="relative max-w-sm w-full rounded-2xl p-6 shadow-2xl bg-t-modal">
            <div className="flex justify-center mb-4">
              <div className="w-14 h-14 rounded-full bg-[#F6465D]/10 flex items-center justify-center">
                <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="#F6465D" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M3 12a9 9 0 1118 0 9 9 0 01-18 0z" />
                  <path d="M12 8v5" />
                  <path d="M12 16h.01" />
                </svg>
              </div>
            </div>
            <h3 className="text-lg font-bold text-center mb-2 text-t-text">连接异常</h3>
            <p className="text-sm text-center mb-6 leading-relaxed text-t-text-secondary">
              {connectionErrorMessage}
            </p>
            <button
              onClick={() => {
                setShowConnectionError(false)
                window.dispatchEvent(new Event('app:resume'))
              }}
              className="w-full py-3 rounded-xl font-medium bg-gradient-to-r from-[var(--t-brand)] to-[var(--t-brand-hover)] text-black hover:shadow-lg hover:shadow-[var(--t-brand)]/30 transition-all active:scale-[0.98]"
            >
              重试
            </button>
          </div>
        </div>
      )}
    </AppProviders>
  )
}
