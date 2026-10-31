import { Bell, ChevronRight, ChevronDown, ChevronUp, Link2, Target, LogOut, RefreshCw, FileText, ChartCandlestick, SettingsIcon, WalletCards, Send, TrendingUp, History } from 'lucide-react'
import { useNavigate } from 'react-router-dom'
import { useState, useEffect, useLayoutEffect, useCallback, useRef } from 'react'
import Decimal from 'decimal.js'
import { ApiBindModal } from '@/components/modals/ApiBindModal'
import { CapitalNormalizationModal, CapitalReminderModal, ConfirmModal, StopLossSettingsModal } from '@/components/modals'
import type { CapitalState } from '@/components/modals'
import { showToast, useAuthStore, useTradingStore } from '@/shared/store'
import { api, endServerSession } from '@/shared/lib/api'
import { requestAppLayoutSync } from '@/shared/lib/device'
import {
  getAccountSessionRevision,
  isCurrentAccountRequestScope,
  parseOptionalBalance,
  scopedAccountCacheKey,
} from '@/shared/lib/accountBalanceState'
import {
  clearTransferHistorySnapshot,
  loadTransferHistory,
} from '@/pages/transfer-history/data'
import { getCapitalControlAvailability } from '@/shared/lib/manualEntryCapital'
import { pendingCollection, useCapitalNormalization } from './useCapitalNormalization'

interface AccountInfoData {
  email_masked: string
  balance: string
  spot_balance: string
  funding_balance: string
  today_pnl: string
  stop_loss_amount: string
  pending_capital_collection?: boolean
}

interface VersionInfoData {
  version: string
}

interface AccountProfileData {
  bound: boolean
  display_name: string
  account_label: string
  permission: string
  position_mode: string
  email_masked: string
  avatar_url: string
  avatar_text: string
  sync_error: string
}

type AccountType = 'master' | 'sub' | 'unknown'

interface CollectAccountData {
  capital_collect_account: string
  capital_collect_address?: string
  capital_collect_network: string
  capital_collect_network_supported?: boolean
  account_type: AccountType
}

const PROFILE_ACCOUNT_CACHE_KEY_PREFIX = 'tradetools:profile:account:v2'
const PROFILE_VERSION_CACHE_KEY = 'tradetools:profile:version:v1'
const PROFILE_USER_CACHE_KEY_PREFIX = 'tradetools:profile:user:v2'
const SILENT_REFRESH_TIMEOUT = 8000
const IP_WHITELIST_TEXT = '47.236.86.243'
const CAPITAL_COLLECT_NETWORK_OPTIONS = [
  { value: 'BSC', label: 'BSC（BEP20）' },
  { value: 'TRX', label: 'TRX（TRC20）' },
  { value: 'ETH', label: 'ETH（ERC20）' },
] as const
const isSupportedCapitalCollectNetwork = (network: string) =>
  CAPITAL_COLLECT_NETWORK_OPTIONS.some(option => option.value === network.trim().toUpperCase())

interface CachedProfileAccount {
  balance: number
  spotBalance: number | null
  fundingBalance: number | null
}

interface CachedProfileUser {
  bound: boolean
  displayName: string
  avatarUrl: string
  syncError: string
}

function loadCachedProfileAccount(userId: string): CachedProfileAccount | null {
  try {
    const cacheKey = scopedAccountCacheKey(PROFILE_ACCOUNT_CACHE_KEY_PREFIX, userId)
    if (!cacheKey) return null
    const raw = window.localStorage.getItem(cacheKey)
    if (!raw) return null
    const parsed = JSON.parse(raw) as Partial<CachedProfileAccount>
    const balance = parseOptionalBalance(parsed.balance)
    if (balance === null) return null
    return {
      balance,
      spotBalance: parseOptionalBalance(parsed.spotBalance),
      fundingBalance: parseOptionalBalance(parsed.fundingBalance),
    }
  } catch {
    return null
  }
}

function saveCachedProfileAccount(userId: string, data: CachedProfileAccount) {
  try {
    const cacheKey = scopedAccountCacheKey(PROFILE_ACCOUNT_CACHE_KEY_PREFIX, userId)
    if (cacheKey) window.localStorage.setItem(cacheKey, JSON.stringify(data))
  } catch {
    // ignore storage issues
  }
}

function loadCachedVersionText(): string | null {
  try {
    const value = window.localStorage.getItem(PROFILE_VERSION_CACHE_KEY)
    return value || null
  } catch {
    return null
  }
}

function saveCachedVersionText(value: string) {
  try {
    window.localStorage.setItem(PROFILE_VERSION_CACHE_KEY, value)
  } catch {
    // ignore storage issues
  }
}

function loadCachedProfileUser(userId: string): CachedProfileUser | null {
  try {
    const cacheKey = scopedAccountCacheKey(PROFILE_USER_CACHE_KEY_PREFIX, userId)
    if (!cacheKey) return null
    const raw = window.localStorage.getItem(cacheKey)
    if (!raw) return null
    const parsed = JSON.parse(raw) as Partial<CachedProfileUser>
    if (
      typeof parsed.bound !== 'boolean' ||
      typeof parsed.displayName !== 'string' ||
      typeof parsed.avatarUrl !== 'string' ||
      typeof parsed.syncError !== 'string'
    ) return null
    const sanitized = {
      bound: parsed.bound,
      displayName: parsed.displayName,
      avatarUrl: parsed.avatarUrl,
      syncError: parsed.syncError,
    }
    // Drop fields from the previous cache shape (including the old API-key
    // based account identifier) as soon as the profile is read.
    if ('accountId' in parsed || 'accountLabel' in parsed) {
      window.localStorage.setItem(cacheKey, JSON.stringify(sanitized))
    }
    return sanitized
  } catch {
    return null
  }
}

function saveCachedProfileUser(userId: string, data: CachedProfileUser) {
  try {
    const cacheKey = scopedAccountCacheKey(PROFILE_USER_CACHE_KEY_PREFIX, userId)
    if (cacheKey) window.localStorage.setItem(cacheKey, JSON.stringify(data))
  } catch {
    // ignore storage issues
  }
}

import { useTradingMode } from '@/shared/hooks/useTradingMode'
import { TradingModeSwitch } from '@/components/common/TradingModeSwitch'
import { ApiUnbindButton } from '@/components/common/ApiUnbindButton'

export function ProfilePage() {
  const isLead = useTradingMode() === 'lead'
  const navigate = useNavigate()
  const logout = useAuthStore(s => s.logout)
  const authUserId = useAuthStore(s => s.user?.id ?? '')
  const setStopLossAmount = useTradingStore(s => s.setStopLossAmount)
  const stopLossAmount = useTradingStore(s => s.stopLossAmount)
  const activeApi = useTradingStore(s => s.getActiveApi)
  const apiConfigs = useTradingStore(s => s.apiConfigs)
  const cachedAccount = loadCachedProfileAccount(authUserId)
  const cachedVersionText = loadCachedVersionText()
  const cachedProfileUser = loadCachedProfileUser(authUserId)

  const [accountBalance, setAccountBalance] = useState<number | null>(cachedAccount?.balance ?? null)
  const [spotBalance, setSpotBalance] = useState<number | null>(cachedAccount?.spotBalance ?? null)
  const [fundingBalance, setFundingBalance] = useState<number | null>(cachedAccount?.fundingBalance ?? null)
  const currentAPIAlias = activeApi()?.alias ?? null

  const [showLogoutConfirm, setShowLogoutConfirm] = useState(false)
  const [showApiBindModal, setShowApiBindModal] = useState(false)
  const [showReminderModal, setShowReminderModal] = useState(false)
  const [reminderState, setReminderState] = useState<CapitalState | null>(null)
  const [reminderLoading, setReminderLoading] = useState(false)
  const [profileData, setProfileData] = useState<AccountProfileData | null>(null)
  const [accountRefreshing, setAccountRefreshing] = useState(false)
  const [capitalThresholdLoaded, setCapitalThresholdLoaded] = useState(false)
  const [hasPendingCollection, setHasPendingCollection] = useState(false)
  const [showCollectAccountModal, setShowCollectAccountModal] = useState(false)
  const [collectAccount, setCollectAccount] = useState('')
  const [collectAccountInput, setCollectAccountInput] = useState('')
  const [collectNetwork, setCollectNetwork] = useState('')
  const [collectNetworkInput, setCollectNetworkInput] = useState('')
  const [collectAccountSaving, setCollectAccountSaving] = useState(false)
  const [collectAccountType, setCollectAccountType] = useState<AccountType | ''>('')
  const [showStopLossModal, setShowStopLossModal] = useState(false)
  const [showMoreFeatures, setShowMoreFeatures] = useState(false)
  const collectPromptTimerRef = useRef<number | null>(null)
  const accountRequestIdRef = useRef(0)
  const profileRequestIdRef = useRef(0)
  const collectAccountRequestIdRef = useRef(0)
  const [versionText, setVersionText] = useState(cachedVersionText ?? 'unknown')
  const versionDisplayText = `${versionText}【IP 白名单：${IP_WHITELIST_TEXT}】`
  const accountTotal = (accountBalance ?? 0) + (fundingBalance ?? 0) + (spotBalance ?? 0)
  const capitalOpenMinimum = new Decimal(stopLossAmount).times('1.5').toNumber()
  const capitalMaximum = new Decimal(stopLossAmount).times(5).toNumber()
  const { collectionEnabled, reminderEnabled } = getCapitalControlAvailability({
    thresholdLoaded: capitalThresholdLoaded,
    futuresBalance: accountBalance,
    fundingBalance,
    spotBalance,
    openingMinimum: capitalOpenMinimum,
    retentionMaximum: capitalMaximum,
  })
  const isApiBound = profileData?.bound ?? cachedProfileUser?.bound ?? apiConfigs.length > 0
  const apiAlias = profileData?.bound ? profileData.display_name : currentAPIAlias
  const displayName = profileData?.display_name || cachedProfileUser?.displayName || currentAPIAlias || 'Binance 账户'
  const avatarUrl = isApiBound ? (profileData?.avatar_url || cachedProfileUser?.avatarUrl || '') : ''
  const profileSyncError = profileData?.sync_error || cachedProfileUser?.syncError || ''
  const accountTypeLabel = isLead ? '带单组合' : collectAccountType === 'sub' ? '子账户' : collectAccountType === 'master' ? '主账户' : ''
  const accountTypeClass = collectAccountType === 'sub'
    ? 'border-[#0ECB81]/30 bg-[#0ECB81]/10 text-[#0ECB81]'
    : 'border-[var(--t-brand)]/30 bg-[var(--t-brand)]/10 text-[var(--t-brand)]'

  useLayoutEffect(() => {
    accountRequestIdRef.current += 1
    profileRequestIdRef.current += 1
    collectAccountRequestIdRef.current += 1
    const nextAccount = loadCachedProfileAccount(authUserId)
    setAccountBalance(nextAccount?.balance ?? null)
    setSpotBalance(nextAccount?.spotBalance ?? null)
    setFundingBalance(nextAccount?.fundingBalance ?? null)
    setProfileData(null)
    setAccountRefreshing(false)
    setCapitalThresholdLoaded(false)
    setHasPendingCollection(false)
    setCollectAccount('')
    setCollectAccountInput('')
    setCollectNetwork('')
    setCollectNetworkInput('')
    setCollectAccountType('')
    setReminderState(null)
    setShowReminderModal(false)
    setShowCollectAccountModal(false)
    setShowStopLossModal(false)
  }, [authUserId])

  const loadAccount = useCallback(async (suppressConnectionError = false, fresh = false) => {
    const requestUserId = authUserId
    const requestSessionRevision = getAccountSessionRevision()
    const requestId = ++accountRequestIdRef.current
    const isCurrentRequest = () => isCurrentAccountRequestScope(
      requestUserId,
      useAuthStore.getState().user?.id ?? '',
      requestId,
      accountRequestIdRef.current,
      requestSessionRevision,
      getAccountSessionRevision(),
    )
    try {
      setAccountRefreshing(true)
      const data = await api.get<AccountInfoData>(fresh ? '/account/info?fresh=1' : '/account/info', {
        suppressConnectionError,
        disableRetry: suppressConnectionError,
        timeout: suppressConnectionError ? SILENT_REFRESH_TIMEOUT : undefined,
      })
      if (!isCurrentRequest()) return
      setHasPendingCollection(Boolean(data.pending_capital_collection))
      const nextBalance = parseOptionalBalance(data.balance)
      const nextSpotBalance = parseOptionalBalance(data.spot_balance)
      const nextFundingBalance = parseOptionalBalance(data.funding_balance)
      if (nextBalance !== null) setAccountBalance(nextBalance)
      if (nextSpotBalance !== null) setSpotBalance(nextSpotBalance)
      if (nextFundingBalance !== null) setFundingBalance(nextFundingBalance)
      if (nextBalance !== null && nextSpotBalance !== null && nextFundingBalance !== null) {
        saveCachedProfileAccount(requestUserId, {
          balance: nextBalance,
          spotBalance: nextSpotBalance,
          fundingBalance: nextFundingBalance,
        })
      }
      const sl = Number(data.stop_loss_amount)
      if (!Number.isNaN(sl) && Number.isFinite(sl) && sl > 0) {
        setStopLossAmount(sl)
        setCapitalThresholdLoaded(true)
      }
    } catch {
      // ignore
    } finally {
      if (isCurrentRequest()) {
        setAccountRefreshing(false)
        requestAppLayoutSync('profile-account-loaded')
      }
    }
  }, [authUserId, setStopLossAmount])

  const loadVersion = useCallback(async (suppressConnectionError = false) => {
    try {
      const data = await api.get<VersionInfoData>('/account/version', {
        suppressConnectionError,
        disableRetry: suppressConnectionError,
        timeout: suppressConnectionError ? SILENT_REFRESH_TIMEOUT : undefined,
      })
      if (data.version) {
        setVersionText(data.version)
        saveCachedVersionText(data.version)
      }
    } catch {
      // ignore
    } finally {
      requestAppLayoutSync('profile-version-loaded')
    }
  }, [])

  const loadProfile = useCallback(async (suppressConnectionError = false) => {
    const requestUserId = authUserId
    const requestSessionRevision = getAccountSessionRevision()
    const requestId = ++profileRequestIdRef.current
    const isCurrentRequest = () => isCurrentAccountRequestScope(
      requestUserId,
      useAuthStore.getState().user?.id ?? '',
      requestId,
      profileRequestIdRef.current,
      requestSessionRevision,
      getAccountSessionRevision(),
    )
    try {
      const data = await api.get<AccountProfileData>('/account/profile', {
        suppressConnectionError,
        disableRetry: suppressConnectionError,
        timeout: suppressConnectionError ? SILENT_REFRESH_TIMEOUT : undefined,
      })
      if (!isCurrentRequest()) return
      setProfileData(data)
      saveCachedProfileUser(requestUserId, {
        bound: data.bound,
        displayName: data.display_name,
        avatarUrl: data.avatar_url,
        syncError: data.sync_error || '',
      })
    } catch {
      // ignore
    } finally {
      if (isCurrentRequest()) {
        requestAppLayoutSync('profile-user-loaded')
      }
    }
  }, [authUserId])

  useEffect(() => {
    let inFlight = false
    const refresh = async (includeVersion = false) => {
      if (document.visibilityState !== 'visible' || !navigator.onLine || inFlight) return
      inFlight = true
      try {
        await Promise.all([loadAccount(true), loadProfile(true), ...(includeVersion ? [loadVersion(true)] : [])])
      } finally {
        inFlight = false
      }
    }
    const onResume = () => { void refresh(true) }
    void refresh()
    const timer = window.setInterval(() => void refresh(), 30000)
    window.addEventListener('app:resume', onResume)
    window.addEventListener('online', onResume)
    document.addEventListener('visibilitychange', onResume)
    return () => {
      window.clearInterval(timer)
      window.removeEventListener('app:resume', onResume)
      window.removeEventListener('online', onResume)
      document.removeEventListener('visibilitychange', onResume)
    }
  }, [loadAccount, loadProfile, loadVersion])

  useEffect(() => {
    void loadVersion(true)
  }, [loadVersion])

  useEffect(() => {
    if (!isApiBound || isLead) return
    void loadTransferHistory().catch(() => undefined)
  }, [isApiBound, isLead])

  const confirmLogout = () => {
    setShowLogoutConfirm(false)
    void endServerSession().catch(() => undefined)
    logout()
    navigate('/login')
  }


  const capital = useCapitalNormalization(() => { void loadAccount(true, true) })

  const handleCapitalPrecheck = async () => {
    if (capital.loading) return
    const requestSession = getAccountSessionRevision()
    let accountType = collectAccountType
    let configuredAddress = collectAccount
    let configuredNetwork = collectNetwork
    // The initial account-type probe runs in parallel with the balance load.
    // Refresh it on a fast click so a master account cannot bypass this guard
    // while the probe is still pending.
    if (!accountType || accountType === 'unknown') {
      const data = await loadCollectAccount()
      accountType = data?.account_type || accountType
      configuredAddress = data?.capital_collect_address || data?.capital_collect_account || configuredAddress
      configuredNetwork = data?.capital_collect_network || configuredNetwork
    }
    if (requestSession !== getAccountSessionRevision()) return
    const state = await capital.check()
    if (!state) return
    setHasPendingCollection(Boolean(pendingCollection(state)))
    if (!pendingCollection(state) && state.status === 'normalization_required' && Number(state.transfer_amount || 0) > 0
      && accountType === 'master' && (!configuredAddress || !isSupportedCapitalCollectNetwork(configuredNetwork))) {
      capital.close()
      promptCollectAccountSetup()
      return
    }
  }

  const handleReminderPreview = async () => {
    if (!reminderEnabled || reminderLoading) return
    setReminderLoading(true)
    try {
      const state = await api.get<CapitalState>('/trade/capital/remind')
      if (state.status !== 'shortfall') {
        await loadAccount(true, true)
        showToast('账户总余额已达到开仓最低要求，无需发送补资提醒')
        return
      }
      setReminderState(state)
      setShowReminderModal(true)
    } catch (error) {
      showToast(error instanceof Error ? error.message : '补资提醒检查失败，请稍后重试')
    } finally {
      setReminderLoading(false)
    }
  }

  const handleSendReminder = async () => {
    if (!reminderState || reminderState.status !== 'shortfall' || reminderLoading) return
    setReminderLoading(true)
    try {
      const state = await api.post<CapitalState>('/trade/capital/remind', {})
      setReminderState(state)
      setShowReminderModal(false)
      showToast('补资提醒已发送')
    } catch (error) {
      showToast(error instanceof Error ? error.message : '补资提醒发送失败，请稍后重试')
    } finally {
      setReminderLoading(false)
    }
  }

  const loadCollectAccount = useCallback(async (): Promise<CollectAccountData | null> => {
    const requestUserId = authUserId
    const requestSessionRevision = getAccountSessionRevision()
    const requestId = ++collectAccountRequestIdRef.current
    const isCurrentRequest = () => isCurrentAccountRequestScope(
      requestUserId,
      useAuthStore.getState().user?.id ?? '',
      requestId,
      collectAccountRequestIdRef.current,
      requestSessionRevision,
      getAccountSessionRevision(),
    )
    try {
      const data = await api.get<CollectAccountData>('/account/capital-collect-account', {
        suppressConnectionError: true,
        disableRetry: true,
      })
      if (!isCurrentRequest()) return null
      setCollectAccount(data.capital_collect_address || data.capital_collect_account || '')
      setCollectNetwork(data.capital_collect_network || '')
      setCollectAccountType(data.account_type || '')
      return data
    } catch {
      if (isCurrentRequest()) {
        setCollectAccountType('unknown')
      }
      return null
    }
  }, [authUserId])

  useEffect(() => {
    if (!isLead) void loadCollectAccount()
  }, [loadCollectAccount, isLead])

  const openCollectAccountModal = () => {
    if (collectPromptTimerRef.current !== null) {
      window.clearTimeout(collectPromptTimerRef.current)
      collectPromptTimerRef.current = null
    }
    const networkSupported = isSupportedCapitalCollectNetwork(collectNetwork)
    setCollectAccountInput(networkSupported ? collectAccount : '')
    setCollectNetworkInput(networkSupported ? collectNetwork.trim().toUpperCase() : '')
    setShowCollectAccountModal(true)
  }

  const promptCollectAccountSetup = () => {
    if (collectPromptTimerRef.current !== null) {
      window.clearTimeout(collectPromptTimerRef.current)
    }
    showToast('请先填写资金归集账号', 500)
    collectPromptTimerRef.current = window.setTimeout(() => {
      collectPromptTimerRef.current = null
      openCollectAccountModal()
    }, 550)
  }

  useEffect(() => {
    return () => {
      if (collectPromptTimerRef.current !== null) {
        window.clearTimeout(collectPromptTimerRef.current)
      }
    }
  }, [])

  const handleSaveCollectAccount = async (address: string, network: string) => {
    if (collectAccountSaving) return
    setCollectAccountSaving(true)
    try {
      const data = await api.post<CollectAccountData>('/account/capital-collect-account', {
        capital_collect_address: address,
        capital_collect_network: address ? network : '',
      })
      setCollectAccount(data.capital_collect_address || data.capital_collect_account || '')
      setCollectNetwork(data.capital_collect_network || '')
      if (data.account_type) {
        setCollectAccountType(data.account_type)
      }
      setShowCollectAccountModal(false)
      showToast(data.capital_collect_address || data.capital_collect_account ? '资金归集目标已保存' : '资金归集目标已清除')
    } catch (error) {
      showToast(error instanceof Error ? error.message : '保存失败，请稍后重试')
    } finally {
      setCollectAccountSaving(false)
    }
  }

  const handleApiBoundChange = useCallback((bound: boolean) => {
    clearTransferHistorySnapshot()
    setProfileData(previous => previous ? { ...previous, bound } : previous)
    void loadProfile(true)
    if (bound && !isLead) {
      void loadCollectAccount()
      void loadTransferHistory().catch(() => undefined)
    } else {
      setCollectAccount('')
      setCollectAccountInput('')
      setCollectNetwork('')
      setCollectNetworkInput('')
      setCollectAccountType('')
    }
  }, [loadCollectAccount, loadProfile, isLead])

  return (
    <div className="account-mode-enter h-full min-h-0 max-w-md mx-auto flex flex-col overflow-y-auto overscroll-contain bg-t-page" style={{ WebkitOverflowScrolling: 'touch' }}>
      <div
        className="flex-1 px-4 pt-6 flex flex-col bg-t-page"
        style={{
          paddingTop: 'calc(max(44px, env(safe-area-inset-top, 0px)) + 1rem)',
          paddingBottom: 'calc(92px + max(var(--app-safe-bottom, 0px), env(safe-area-inset-bottom, 0px)))',
        }}
      >
        {/* Account identity and balance */}
        <div className={`rounded-2xl p-6 bg-gradient-to-br border shadow-md dark:from-[var(--t-brand)]/5 dark:to-[var(--t-brand)]/10 dark:border-[var(--t-brand)]/20 dark:shadow-none ${isLead ? 'from-sky-50 to-blue-50 border-sky-200' : 'from-yellow-50 to-amber-50 border-yellow-200'}`}>
          <div className="flex items-start justify-between gap-3 mb-5">
            {isApiBound ? (
              <div className="flex min-w-0 flex-1 items-start gap-2 min-[360px]:gap-3">
                <div className="w-10 h-10 min-[360px]:w-12 min-[360px]:h-12 shrink-0 rounded-xl overflow-hidden shadow-lg bg-t-surface">
                  {avatarUrl ? (
                    <img src={avatarUrl} alt={displayName} className="w-full h-full object-cover" />
                  ) : (
                    <div className="w-full h-full bg-gradient-to-br from-[var(--t-brand)] to-[var(--t-brand-hover)] flex items-center justify-center">
                      <span className="text-black text-xl font-bold">B</span>
                    </div>
                  )}
                </div>
                <div className="min-w-0 flex-1 text-left">
                  <h3 className="truncate text-base font-bold mb-1 text-t-text" title={apiAlias || displayName}>{apiAlias || displayName}</h3>
                  <p className="text-xs mt-1">
                    <span className={`inline-flex items-center rounded-md border px-1.5 py-0.5 font-semibold leading-none ${accountTypeClass}`}>
                      {accountTypeLabel || '账户类型同步中'}
                    </span>
                  </p>
                  <ApiUnbindButton onUnbound={() => handleApiBoundChange(false)} />
                </div>
              </div>
            ) : (
              <button type="button" onClick={() => setShowApiBindModal(true)}
                className="flex min-w-0 items-center gap-2 py-2 text-left transition-opacity hover:opacity-75">
                <Link2 size={22} className="shrink-0 text-[var(--t-brand)]" />
                <span className="text-sm font-semibold text-t-text">请先绑定 API</span>
              </button>
            )}
            <TradingModeSwitch />
          </div>

          <div className={`h-px mb-4 dark:bg-[var(--t-brand)]/10 ${isLead ? 'bg-sky-200/50' : 'bg-yellow-200/50'}`} />

          <div className="mb-2">
            <div className="flex items-center gap-2">
              <span className="text-sm font-medium text-t-text-secondary">{isLead ? '带单组合可用余额' : '合约余额'} (USDT)</span>
              <button
                type="button"
                onClick={() => void loadAccount(false, true)}
                disabled={accountRefreshing}
                className="inline-flex items-center gap-1 text-xs text-t-text-muted underline underline-offset-2 disabled:opacity-50"
              >
                <RefreshCw size={12} className={accountRefreshing ? 'animate-spin' : ''} />
                刷新
              </button>
            </div>
          </div>
          <div className="flex min-w-0 items-center justify-between gap-4">
            <div className="min-w-0">
              <div className="text-4xl font-bold tracking-tight text-gray-900 dark:text-[var(--t-brand)]">
                {accountBalance === null ? '--' : accountBalance.toFixed(2)}
              </div>
              {!isLead && <div className="mt-3 space-y-1.5">
                <BalanceItem label="资金" value={fundingBalance} />
                <BalanceItem label="现货" value={spotBalance} />
              </div>}
            </div>
            {!isLead && <div className="flex shrink-0 flex-col gap-2">
              <button
                type="button"
                onClick={() => void handleCapitalPrecheck()}
                disabled={!collectionEnabled || capital.loading}
                title={collectionEnabled ? '归集超过合约保留上限的资金' : '可用资金未超过保留上限，或超额不足 0.01 U（单个钱包低于 1 U 的残差忽略）'}
                className="inline-flex h-9 items-center justify-center gap-1.5 rounded-lg bg-[var(--t-brand)] px-3 text-xs font-semibold text-black transition-colors hover:bg-[var(--t-brand-hover)] disabled:opacity-50"
              >
                <WalletCards size={14} />
                归集余额
              </button>
              {hasPendingCollection && <button
                type="button"
                onClick={() => void handleCapitalPrecheck()}
                disabled={capital.loading}
                className="text-xs text-t-muted underline underline-offset-4 disabled:opacity-50"
              >
                核对上次归集
              </button>}
              <button
                type="button"
                onClick={() => void handleReminderPreview()}
                disabled={!reminderEnabled || reminderLoading}
                title={reminderEnabled ? '预览补资提醒' : '账户总余额已达到补资触发线'}
                className="inline-flex h-9 items-center justify-center gap-1.5 rounded-lg bg-[#2B2F36] px-3 text-xs font-semibold text-white transition-colors hover:bg-[#35393F] disabled:cursor-not-allowed disabled:opacity-35"
              >
                <Bell size={14} />
                补资提醒
              </button>
            </div>}
          </div>
          {isLead && <p className="mt-4 text-xs leading-relaxed text-t-text-secondary">组合充值、转出请在币安「我的带单」页面操作。此处止损额度仅用于带单交易。</p>}
        </div>

        {/* Account actions and navigation */}
        <div className="rounded-2xl overflow-hidden mt-4 bg-t-surface border border-t-border shadow-md dark:shadow-none">
          {/* Stop-loss setting */}
          <button
            onClick={() => setShowStopLossModal(true)}
            className="w-full flex items-center justify-between p-4 transition-all hover:bg-t-surface-hover"
          >
            <div className="flex items-center gap-3">
              <div className={`w-10 h-10 rounded-xl flex items-center justify-center dark:bg-[var(--t-brand)]/10 ${isLead ? 'bg-sky-100' : 'bg-yellow-100'}`}>
                <TrendingUp size={20} className="text-[var(--t-brand)]" />
              </div>
              <span className="font-medium text-t-text">止损额设置</span>
            </div>
            <div className="flex items-center gap-2">
              <span className="text-sm font-bold text-gray-900 dark:text-[var(--t-brand)]">{stopLossAmount} USDT</span>
              <ChevronRight size={18} className="text-t-text-muted" />
            </div>
          </button>

          <div className="h-px mx-4 bg-t-border" />

          {/* Capital Collect Account */}
          {!isLead && <>
          <button
            onClick={openCollectAccountModal}
            className="w-full flex items-center justify-between p-4 transition-all hover:bg-t-surface-hover"
          >
            <div className="flex items-center gap-3">
              <div className="w-10 h-10 rounded-xl flex items-center justify-center bg-yellow-100 dark:bg-[var(--t-brand)]/10">
                <Send size={20} className="text-[var(--t-brand)]" />
              </div>
              <span className="font-medium text-t-text">资金归集账号</span>
            </div>
            <div className="flex items-center gap-2">
              <span className="max-w-[140px] truncate text-xs font-medium text-t-text-muted">
                {collectAccount ? `${collectAccount} ${collectNetwork ? `(${collectNetwork})` : ''}` : '未配置'}
              </span>
              <ChevronRight size={18} className="text-t-text-muted" />
            </div>
          </button>

          <div className="h-px mx-4 bg-t-border" />

          {/* Transfer History */}
          <button
            onClick={() => navigate('/transfer-history')}
            className="w-full flex items-center justify-between p-4 transition-all hover:bg-t-surface-hover"
          >
            <div className="flex items-center gap-3">
              <div className="w-10 h-10 rounded-xl flex items-center justify-center bg-yellow-100 dark:bg-[var(--t-brand)]/10">
                <History size={20} className="text-[var(--t-brand)]" />
              </div>
              <span className="font-medium text-t-text">转账历史</span>
            </div>
            <ChevronRight size={18} className="text-t-text-muted" />
          </button>

          <div className="h-px mx-4 bg-t-border" />

          {/* Strategy Management */}
          </>}
          <button
            onClick={() => navigate('/strategy-management')}
            className="w-full flex items-center justify-between p-4 transition-all hover:bg-t-surface-hover"
          >
            <div className="flex items-center gap-3">
              <div className={`w-10 h-10 rounded-xl flex items-center justify-center dark:bg-[var(--t-brand)]/10 ${isLead ? 'bg-sky-100' : 'bg-yellow-100'}`}>
                <Target size={20} className="text-[var(--t-brand)]" />
              </div>
              <span className="font-medium text-t-text">止盈止损策略</span>
            </div>
            <ChevronRight size={18} className="text-t-text-muted" />
          </button>

          <div className="h-px mx-4 bg-t-border" />

          <button
            onClick={() => setShowMoreFeatures(value => !value)}
            aria-expanded={showMoreFeatures}
            className="w-full flex items-center justify-between p-4 transition-all hover:bg-t-surface-hover"
          >
            <div className="flex items-center gap-3">
              <div className={`w-10 h-10 rounded-xl flex items-center justify-center dark:bg-[var(--t-brand)]/10 ${isLead ? 'bg-sky-100' : 'bg-yellow-100'}`}>
                <FileText size={20} className="text-[var(--t-brand)]" />
              </div>
              <span className="font-medium text-t-text">更多功能</span>
            </div>
            {showMoreFeatures ? <ChevronUp size={18} className="text-t-text-muted" /> : <ChevronDown size={18} className="text-t-text-muted" />}
          </button>

          {showMoreFeatures && (
            <>
              <div className="h-px ml-[4.75rem] mr-4 bg-t-border" />
              <button
                onClick={() => navigate('/operation-logs')}
                className="w-full flex items-center justify-between py-3 pl-7 pr-4 transition-all hover:bg-t-surface-hover"
              >
                <div className="flex items-center gap-3">
                  <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-[#4F6D7A]/10 dark:bg-[#86A6B4]/10">
                    <History size={16} className="text-[#4F6D7A] dark:text-[#86A6B4]" />
                  </div>
                  <span className="text-sm font-normal text-t-text-secondary">日志</span>
                </div>
                <ChevronRight size={16} className="text-t-text-muted" />
              </button>
              {!isLead && <>
              <div className="h-px ml-[4.75rem] mr-4 bg-t-border" />
              <button
                onClick={() => navigate('/watch-plan')}
                className="w-full flex items-center justify-between py-3 pl-7 pr-4 transition-all hover:bg-t-surface-hover"
              >
                <div className="flex items-center gap-3">
                  <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-[#4F6D7A]/10 dark:bg-[#86A6B4]/10">
                    <FileText size={16} className="text-[#4F6D7A] dark:text-[#86A6B4]" />
                  </div>
                  <span className="text-sm font-normal text-t-text-secondary">看盘计划</span>
                </div>
                <ChevronRight size={16} className="text-t-text-muted" />
              </button>

              <div className="h-px ml-[4.75rem] mr-4 bg-t-border" />

              <button
                onClick={() => navigate('/signal-research')}
                className="w-full flex items-center justify-between py-3 pl-7 pr-4 transition-all hover:bg-t-surface-hover"
              >
                <div className="flex items-center gap-3">
                  <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-[#4F6D7A]/10 dark:bg-[#86A6B4]/10">
                    <ChartCandlestick size={16} className="text-[#4F6D7A] dark:text-[#86A6B4]" />
                  </div>
                  <span className="text-sm font-normal text-t-text-secondary">信号研究</span>
                </div>
                <ChevronRight size={16} className="text-t-text-muted" />
              </button>
              </>}
            </>
          )}

          {/* 设置页保留颜色模式和管理员选项。 */}
          <div className="h-px mx-4 bg-t-border" />
          <button
            onClick={() => navigate('/settings')}
            className="w-full flex items-center justify-between p-4 transition-all hover:bg-t-surface-hover"
          >
            <div className="flex items-center gap-3">
              <div className={`w-10 h-10 rounded-xl flex items-center justify-center dark:bg-[var(--t-brand)]/10 ${isLead ? 'bg-sky-100' : 'bg-yellow-100'}`}>
                <SettingsIcon size={20} className="text-[var(--t-brand)]" />
              </div>
              <span className="font-medium text-t-text">设置</span>
            </div>
            <ChevronRight size={18} className="text-t-text-muted" />
          </button>
        </div>

        <div className="mt-3 mb-1 text-center text-xs text-t-text-muted">
          {profileSyncError ? `账户资料同步提示：${profileSyncError}` : ''}
        </div>
        <div className="mt-1 mb-1 text-center text-xs text-t-text-muted">
          版本号：{versionDisplayText}
        </div>

        {/* Logout Button */}
        <div className="flex-1 flex items-start justify-center min-h-[80px] py-4">
          <button
            onClick={() => setShowLogoutConfirm(true)}
            className="inline-flex items-center justify-center gap-2 text-[#F6465D] underline underline-offset-4 transition-opacity hover:opacity-80 active:opacity-70"
          >
            <LogOut size={20} className="text-[#F6465D]" />
            <span className="font-medium">退出登录</span>
          </button>
        </div>
      </div>

      {/* Capital Collect Account Modal */}
      {showCollectAccountModal && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div className="absolute inset-0 bg-black/60 backdrop-blur-sm" onClick={() => setShowCollectAccountModal(false)} />
          <div className="relative max-w-sm w-full rounded-2xl p-6 shadow-2xl bg-t-modal">
            <h3 className="text-lg font-bold mb-3 text-t-text">资金归集账号</h3>
            {collectAccountType === 'sub' ? (
              <>
                <div className="w-full mb-4 px-4 py-3 rounded-xl border-2 border-transparent bg-t-surface-input">
                  <p className="text-sm leading-relaxed font-medium text-[#0ECB81]">
                    当前是子账户，资金将归集到该账户从属的主账户，无需配置归集账户。
                  </p>
                </div>
                <button
                  onClick={() => setShowCollectAccountModal(false)}
                  className="w-full py-3 rounded-xl font-medium bg-gradient-to-r from-[var(--t-brand)] to-[var(--t-brand-hover)] text-black hover:shadow-lg hover:shadow-[var(--t-brand)]/30 transition-all"
                >
                  知道了
                </button>
              </>
            ) : collectAccountType === 'master' ? (
              <>
                <p className="text-xs mb-4 leading-relaxed text-t-text-muted">
                  当绑定的是币安主账户时，系统会使用 Spot 提现接口向目标主账户的充值地址发起申请。
                  如果地址属于 Binance 且 Fast Withdraw 条件满足，通常会内部到账、无需上链；请以目标主账户
                  Spot 充值页面显示的网络和地址为准。子账户归集到所属主账户时无需配置。
                </p>
                <select
                  value={collectNetworkInput}
                  onChange={e => setCollectNetworkInput(e.target.value)}
                  className="w-full mb-4 px-4 py-3 rounded-xl border-2 text-t-text bg-t-surface-input border-transparent focus:border-[var(--t-brand)] outline-none"
                >
                  <option value="">请选择网络</option>
                  {CAPITAL_COLLECT_NETWORK_OPTIONS.map(option => (
                    <option key={option.value} value={option.value}>{option.label}</option>
                  ))}
                </select>
                <input
                  type="text"
                  value={collectAccountInput}
                  onChange={e => setCollectAccountInput(e.target.value)}
                  placeholder="目标主账户 Spot 充值地址（与网络匹配）"
                  autoComplete="off"
                  className="w-full mb-4 px-4 py-3 rounded-xl border-2 text-t-text bg-t-surface-input border-transparent focus:border-[var(--t-brand)] outline-none"
                />
                <div className="w-full mb-4 px-4 py-3 rounded-xl border-2 border-transparent bg-t-surface-input">
                  <p className="text-sm leading-relaxed font-medium text-[#0ECB81]">
                    支持网络：BSC（BEP20）、TRX（TRC20）、ETH（ERC20）
                  </p>
                  <p className="mt-1 text-xs leading-relaxed text-t-text-muted">
                    当前资金归集仅支持以上三种网络，请确保充值地址与所选网络一致。
                  </p>
                  {collectNetwork && !isSupportedCapitalCollectNetwork(collectNetwork) && (
                    <p className="mt-2 text-xs leading-relaxed text-[var(--t-brand)]">
                      检测到不支持的旧网络配置（{collectNetwork}），请重新选择网络并填写匹配的充值地址。
                    </p>
                  )}
                </div>
                <div className="flex gap-3">
                  <button
                    onClick={() => setShowCollectAccountModal(false)}
                    disabled={collectAccountSaving}
                    className="flex-1 py-3 rounded-xl font-medium transition-colors bg-t-btn-secondary text-t-text hover:bg-t-btn-secondary-hover disabled:opacity-50"
                  >
                    取消
                  </button>
                  {collectAccount ? (
                    <button
                      onClick={() => void handleSaveCollectAccount('', '')}
                      disabled={collectAccountSaving}
                      className="flex-1 py-3 rounded-xl font-medium transition-colors bg-[#F6465D]/10 text-[#F6465D] hover:bg-[#F6465D]/20 disabled:opacity-50"
                    >
                      清除
                    </button>
                  ) : null}
                  <button
                    onClick={() => void handleSaveCollectAccount(collectAccountInput.trim(), collectNetworkInput)}
                    disabled={collectAccountSaving || !collectAccountInput.trim() || !collectNetworkInput}
                    className="flex-1 py-3 rounded-xl font-medium bg-gradient-to-r from-[var(--t-brand)] to-[var(--t-brand-hover)] text-black hover:shadow-lg hover:shadow-[var(--t-brand)]/30 transition-all disabled:opacity-50"
                  >
                    {collectAccountSaving ? '保存中…' : '保存'}
                  </button>
                </div>
              </>
            ) : (
              <>
                <div className="w-full mb-4 px-4 py-3 rounded-xl border-2 border-transparent bg-t-surface-input">
                  <p className="text-sm leading-relaxed font-medium text-t-text-muted">
                    暂时无法确认当前 Binance 账户类型，请刷新页面后重试。
                  </p>
                </div>
                <button
                  onClick={() => setShowCollectAccountModal(false)}
                  className="w-full py-3 rounded-xl font-medium bg-gradient-to-r from-[var(--t-brand)] to-[var(--t-brand-hover)] text-black hover:shadow-lg hover:shadow-[var(--t-brand)]/30 transition-all"
                >
                  知道了
                </button>
              </>
            )}
          </div>
        </div>
      )}

      {/* Logout Confirmation */}
      <ConfirmModal
        isOpen={showLogoutConfirm}
        onClose={() => setShowLogoutConfirm(false)}
        onConfirm={confirmLogout}
        title="确认退出登录"
        confirmText="确认"
      >
        确认要退出登录吗？
      </ConfirmModal>

      <ApiBindModal
        isOpen={showApiBindModal}
        onClose={() => setShowApiBindModal(false)}
        onBoundChange={handleApiBoundChange}
      />

      <CapitalNormalizationModal
        isOpen={capital.isOpen}
        state={capital.state}
        loading={capital.loading}
        following={capital.following}
        mode="manual_sweep"
        onClose={capital.close}
        onNormalize={() => void capital.confirm()}
        onContinue={() => undefined}
      />

      <CapitalReminderModal
        isOpen={showReminderModal}
        state={reminderState}
        loading={reminderLoading}
        onClose={() => setShowReminderModal(false)}
        onSend={() => void handleSendReminder()}
      />

      <StopLossSettingsModal
        isOpen={showStopLossModal}
        onClose={() => setShowStopLossModal(false)}
        accountBalance={accountTotal}
        currentStopLoss={stopLossAmount}
        onConfirm={(newAmount) => {
          setStopLossAmount(newAmount)
          setShowStopLossModal(false)
        }}
      />
    </div>
  )
}

function BalanceItem({ label, value }: { label: string; value: number | null }) {
  return (
    <div className="flex items-baseline gap-2">
      <span className="w-7 shrink-0 text-xs text-t-text-secondary">{label}</span>
      <span className="text-xs font-semibold text-gray-900 dark:text-t-text">
        {value === null ? '--' : `${value.toFixed(2)} USDT`}
      </span>
    </div>
  )
}
