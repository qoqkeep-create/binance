import { useCallback, useEffect, useRef, useState } from 'react'
import { ApiUnbindButton } from '@/components/common/ApiUnbindButton'
import { api, ApiError } from '@/shared/lib/api'
import {
  ACCOUNT_BINDING_CHANGED_EVENT,
  advanceAccountSessionRevision,
  clearAccountScopedCaches,
  getAccountSessionRevision,
  isCurrentAccountRequestScope,
  isCurrentAccountSession,
} from '@/shared/lib/accountBalanceState'
import { showToast, useAuthStore, useTradingStore } from '@/shared/store'
import { useTradingMode } from '@/shared/hooks/useTradingMode'

interface ApiInfoData {
  alias: string
  status: number
}

interface ApiBindModalProps {
  isOpen: boolean
  onClose: () => void
  onBoundChange?: (bound: boolean) => void
}

const API_STATUS_REQUEST_OPTIONS = {
  suppressConnectionError: true,
  disableRetry: true,
  timeout: 8000,
} as const

export function ApiBindModal({ isOpen, onClose, onBoundChange }: ApiBindModalProps) {
  const isLead = useTradingMode() === 'lead'
  const apiConfigs = useTradingStore(s => s.apiConfigs)
  const replaceApiConfigs = useTradingStore(s => s.replaceApiConfigs)
  const clearApiConfigs = useTradingStore(s => s.clearApiConfigs)
  const [loading, setLoading] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [boundInfo, setBoundInfo] = useState<ApiInfoData | null>(null)

  const [apiKey, setApiKey] = useState('')
  const [secretKey, setSecretKey] = useState('')
  const [alias, setAlias] = useState('')
  const apiRequestIdRef = useRef(0)

  const [errors, setErrors] = useState({
    apiKey: false,
    secretKey: false,
    alias: false,
  })

  const isRequestSessionCurrent = useCallback((requestUserId: string, requestSessionRevision: number) => (
    isCurrentAccountSession(
      requestUserId,
      useAuthStore.getState().user?.id ?? '',
      requestSessionRevision,
      getAccountSessionRevision(),
    )
  ), [])

  const applyBoundApi = useCallback((info: ApiInfoData, notify = true) => {
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
    setBoundInfo(info)
    if (notify) onBoundChange?.(true)
  }, [onBoundChange, replaceApiConfigs])

  const syncBoundApi = useCallback(async (validateConnection = true) => {
    const requestUserId = useAuthStore.getState().user?.id ?? ''
    const requestSessionRevision = getAccountSessionRevision()
    const requestId = ++apiRequestIdRef.current
    const isCurrentRequest = () => isCurrentAccountRequestScope(
      requestUserId,
      useAuthStore.getState().user?.id ?? '',
      requestId,
      apiRequestIdRef.current,
      requestSessionRevision,
      getAccountSessionRevision(),
    )
    setLoading(true)
    try {
      const infoPath = validateConnection ? '/api/info?validate=1' : '/api/info'
      const info = await api.get<ApiInfoData | null>(infoPath, API_STATUS_REQUEST_OPTIONS)
      if (!isCurrentRequest()) return
      if (!info) {
        clearApiConfigs()
        setBoundInfo(null)
        onBoundChange?.(false)
        return
      }
      applyBoundApi(info)
    } finally {
      if (isCurrentRequest()) setLoading(false)
    }
  }, [applyBoundApi, clearApiConfigs, onBoundChange])

  const refreshBoundApiAfterBind = useCallback(async (
    requestUserId: string,
    requestSessionRevision: number,
  ) => {
    const requestId = ++apiRequestIdRef.current
    try {
      const info = await api.get<ApiInfoData | null>('/api/info', API_STATUS_REQUEST_OPTIONS)
      if (!info || !isCurrentAccountRequestScope(
        requestUserId,
        useAuthStore.getState().user?.id ?? '',
        requestId,
        apiRequestIdRef.current,
        requestSessionRevision,
        getAccountSessionRevision(),
      )) return
      applyBoundApi(info, false)
    } catch {
      // 绑定提交已经成功；状态回读只是校准，失败不能反转成功结果。
    }
  }, [applyBoundApi])

  useEffect(() => {
    if (!isOpen) return
    syncBoundApi().catch(() => {
      // 拉取失败时保持当前状态，避免误导用户进入二次绑定
    })
  }, [isOpen, syncBoundApi])

  const shouldShowBoundSkeleton = loading && (Boolean(boundInfo) || apiConfigs.length > 0)
  const knownAlias = boundInfo?.alias || apiConfigs[0]?.alias || ''

  const inputClass = (hasError: boolean) =>
    `w-full px-4 py-3 rounded-xl border-2 transition-all outline-none font-mono bg-t-surface-input text-t-text placeholder-t-text-placeholder ${
      hasError ? 'border-[#F6465D] focus:border-[#F6465D]' : 'border-transparent focus:border-[var(--t-brand)]'
    }`

  const handleBind = async () => {
    if (submitting) return
    if (!apiKey) { setErrors({ apiKey: true, secretKey: false, alias: false }); return }
    if (!secretKey) { setErrors({ apiKey: false, secretKey: true, alias: false }); return }
    if (!alias) { setErrors({ apiKey: false, secretKey: false, alias: true }); return }
    const requestUserId = useAuthStore.getState().user?.id ?? ''
    let requestSessionRevision = getAccountSessionRevision()
    const requestId = ++apiRequestIdRef.current
    const isCurrentRequest = () => isCurrentAccountRequestScope(
      requestUserId,
      useAuthStore.getState().user?.id ?? '',
      requestId,
      apiRequestIdRef.current,
      requestSessionRevision,
      getAccountSessionRevision(),
    )
    try {
      setSubmitting(true)
      const current = await api.get<ApiInfoData | null>('/api/info', API_STATUS_REQUEST_OPTIONS)
      if (!isCurrentRequest()) return
      if (current) {
        setBoundInfo(current)
        showToast('绑定失败，当前账号已绑定过Api，请先解除绑定后再重新绑定')
        return
      }
      await api.post('/api/bind', {
        api_key: apiKey.trim(),
        secret_key: secretKey.trim(),
        alias: alias.trim(),
      })
      if (!isCurrentRequest()) return
      requestSessionRevision = advanceAccountSessionRevision()
      clearAccountScopedCaches(requestUserId)
      applyBoundApi({ alias: alias.trim(), status: 1 })
      showToast('API绑定成功')
      if (!isRequestSessionCurrent(requestUserId, requestSessionRevision)) return
      setApiKey('')
      setSecretKey('')
      setAlias('')
      onClose()
      window.dispatchEvent(new CustomEvent(ACCOUNT_BINDING_CHANGED_EVENT))
      void refreshBoundApiAfterBind(requestUserId, requestSessionRevision)
    } catch (error) {
      const message = error instanceof ApiError ? error.message : 'API绑定失败，请稍后重试'
      if (isRequestSessionCurrent(requestUserId, requestSessionRevision)) showToast(message)
    } finally {
      if (isRequestSessionCurrent(requestUserId, requestSessionRevision)) setSubmitting(false)
    }
  }

  const handleClose = () => {
    if (submitting) return
    setApiKey('')
    setSecretKey('')
    setAlias('')
    setErrors({ apiKey: false, secretKey: false, alias: false })
    onClose()
  }

  if (!isOpen) return null

  return (
    <>
      <div className="fixed inset-0 z-[120] flex items-center justify-center p-4">
        <div className="absolute inset-0 bg-black/60 backdrop-blur-sm" onClick={handleClose} />
        <div className="relative max-w-sm w-full rounded-2xl p-6 shadow-2xl bg-t-modal">
          <div className="flex items-center justify-between mb-3">
            <h3 className="text-lg font-bold text-t-text">{isLead ? '带单 ' : ''}{boundInfo || shouldShowBoundSkeleton ? 'API管理' : '绑定API'}</h3>
            <button
              onClick={handleClose}
              aria-label="关闭"
              className="w-8 h-8 flex items-center justify-center rounded-full transition-colors text-t-text-muted hover:bg-t-surface-hover"
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <line x1="18" y1="6" x2="6" y2="18" /><line x1="6" y1="6" x2="18" y2="18" />
              </svg>
            </button>
          </div>

          {isLead && (
            <div className="mb-4 rounded-xl bg-t-surface-input px-4 py-3 text-sm leading-relaxed text-t-text-secondary">
              请在币安「合约跟单 → 我的带单 → 对应组合 → API」创建专用 Key，开启合约交易并设置服务器 IP 白名单。此处绑定仅用于带单组合。
            </div>
          )}
          {shouldShowBoundSkeleton ? (
            <div className="space-y-4">
              <div className="w-full px-4 py-3 rounded-xl border-2 border-transparent bg-t-surface-input">
                <div className="space-y-1.5 text-sm">
                  <div className="flex items-center justify-between">
                    <span className="text-t-text-muted">API别名</span>
                    <span className="font-medium text-t-text-muted">{knownAlias || '加载中...'}</span>
                  </div>
                  <div className="flex items-center justify-between gap-3">
                    <span className="text-t-text-muted">连接状态</span>
                    <span className="text-t-text-muted">加载中...</span>
                  </div>
                </div>
              </div>
              <button
                disabled
                className="w-full py-3 rounded-xl font-medium transition-colors bg-[#F6465D]/10 text-[#F6465D]/50 cursor-not-allowed"
              >
                解除 API 绑定
              </button>
              <button className="w-full py-2 text-sm font-medium transition-colors text-[var(--t-brand)]/60 cursor-not-allowed" disabled>
                绑定教程
              </button>
            </div>
          ) : loading ? (
            <div className="w-full px-4 py-3 rounded-xl border-2 border-transparent bg-t-surface-input text-center text-sm text-t-text-muted">
              加载中...
            </div>
          ) : boundInfo ? (
            <div className="space-y-4">
              <div className="w-full px-4 py-3 rounded-xl border-2 border-transparent bg-t-surface-input">
                <div className="space-y-1.5 text-sm">
                  <div className="flex items-center justify-between">
                    <span className="text-t-text-muted">API别名</span>
                    <span className="font-medium text-t-text">{boundInfo.alias}</span>
                  </div>
                  <div className="flex items-center justify-between gap-3">
                    <span className="text-t-text-muted">连接状态</span>
                    <span className={boundInfo.status === 1 ? 'text-[#0ECB81]' : 'text-[#F6465D]'}>
                      {boundInfo.status === 1 ? '正常' : '不可用'}
                    </span>
                  </div>
                </div>
              </div>
              <ApiUnbindButton
                onUnbound={() => { setBoundInfo(null); onBoundChange?.(false) }}
                className="w-full py-3 rounded-xl font-medium transition-colors bg-[#F6465D]/10 text-[#F6465D] hover:bg-[#F6465D]/20 disabled:opacity-60"
              />
              <button className="w-full py-2 text-sm font-medium transition-colors text-[var(--t-brand)] hover:text-[var(--t-brand-hover)]">
                Binance 实盘教程
              </button>
            </div>
          ) : (
            <div className="space-y-4">
              <div>
                <label className="block mb-2 text-sm font-medium text-t-text-secondary">API Key</label>
                <input type="password" autoComplete="off" placeholder="请输入API Key" value={apiKey} onChange={(e) => setApiKey(e.target.value)} className={inputClass(errors.apiKey)} />
              </div>
              <div>
                <label className="block mb-2 text-sm font-medium text-t-text-secondary">Secret Key</label>
                <input type="password" autoComplete="off" placeholder="请输入Secret Key" value={secretKey} onChange={(e) => setSecretKey(e.target.value)} className={inputClass(errors.secretKey)} />
              </div>
              <div>
                <label className="block mb-2 text-sm font-medium text-t-text-secondary">API别名</label>
                <input
                  type="text"
                  placeholder="请输入API别名，便于区分和记忆"
                  value={alias}
                  onChange={(e) => setAlias(e.target.value)}
                  className={inputClass(errors.alias).replace(' font-mono', '')}
                />
              </div>
              <button
                onClick={handleBind}
                disabled={submitting}
                className="w-full py-3 rounded-xl font-medium bg-gradient-to-r from-[var(--t-brand)] to-[var(--t-brand-hover)] text-black hover:shadow-lg hover:shadow-[var(--t-brand)]/30 transition-all active:scale-[0.98] disabled:opacity-60 disabled:cursor-not-allowed"
              >
                {submitting ? '绑定中...' : '确认绑定'}
              </button>
              <button className="w-full py-2 text-sm font-medium transition-colors text-[var(--t-brand)] hover:text-[var(--t-brand-hover)]">
                Binance 实盘教程
              </button>
            </div>
          )}
        </div>
      </div>
    </>
  )
}
