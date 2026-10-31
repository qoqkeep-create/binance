import Decimal from 'decimal.js'
import {
  ArrowDownLeft,
  ArrowLeft,
  ArrowUpRight,
  CircleAlert,
  History,
  RefreshCw,
} from 'lucide-react'
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'

import { ApiError } from '@/shared/lib/api'
import {
  getAccountSessionRevision,
  isCurrentAccountRequestScope,
} from '@/shared/lib/accountBalanceState'
import { isStandaloneMode } from '@/shared/lib/device'
import { showToast, useAuthStore } from '@/shared/store'
import {
  getTransferHistorySnapshot,
  loadMoreTransferHistory,
  loadTransferHistory,
  syncTransferHistory,
} from './data'
import type { TransferHistoryData } from './data'

function decimalOf(value: string): Decimal {
  try {
    return new Decimal(value || '0')
  } catch {
    return new Decimal(0)
  }
}

function formatAmount(value: string, signed = false): string {
  const amount = decimalOf(value).toDecimalPlaces(2, Decimal.ROUND_HALF_UP)
  const absolute = amount.abs().toFixed(2).replace(/\.00$/, '').replace(/(\.\d)0$/, '$1')
  if (!signed || amount.isZero()) return `${amount.isNegative() ? '-' : ''}${absolute} U`
  return `${amount.isPositive() ? '+' : '-'}${absolute} U`
}

function formatDateTime(value: string): string {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return '--'
  return new Intl.DateTimeFormat('zh-CN', {
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).format(date)
}

function formatStartDate(value: string): string {
  const matched = /^(\d{4})-(\d{2})-(\d{2})/.exec(value)
  return matched ? `${matched[1]}.${matched[2]}.${matched[3]} 起` : '2026.08.28 起'
}

function LoadingState() {
  return (
    <div className="space-y-3" aria-label="正在加载转账历史">
      <div className="h-44 animate-pulse rounded-2xl bg-t-surface border border-t-border" />
      {[0, 1, 2].map(index => (
        <div key={index} className="h-24 animate-pulse rounded-2xl bg-t-surface border border-t-border" />
      ))}
    </div>
  )
}

export function TransferHistoryPage() {
  const standalone = isStandaloneMode()
  const navigate = useNavigate()
  const authUserId = useAuthStore(state => state.user?.id ?? '')
  const [data, setData] = useState<TransferHistoryData | null>(() => getTransferHistorySnapshot())
  const [loading, setLoading] = useState(() => !getTransferHistorySnapshot())
  const [refreshing, setRefreshing] = useState(false)
  const [loadingMore, setLoadingMore] = useState(false)
  const [error, setError] = useState('')
  const requestIdRef = useRef(0)

  const beginRequest = useCallback(() => {
    const requestUserId = authUserId
    const requestSessionRevision = getAccountSessionRevision()
    const requestId = ++requestIdRef.current
    return {
      isCurrent: () => isCurrentAccountRequestScope(
        requestUserId,
        useAuthStore.getState().user?.id ?? '',
        requestId,
        requestIdRef.current,
        requestSessionRevision,
        getAccountSessionRevision(),
      ),
    }
  }, [authUserId])

  useLayoutEffect(() => {
    requestIdRef.current += 1
    const nextSnapshot = getTransferHistorySnapshot()
    setData(nextSnapshot)
    setLoading(!nextSnapshot)
    setRefreshing(false)
    setLoadingMore(false)
    setError('')
  }, [authUserId])

  const loadHistory = useCallback(async () => {
    const request = beginRequest()
    if (!getTransferHistorySnapshot()) setLoading(true)
    setError('')
    try {
      const response = await loadTransferHistory()
      if (request.isCurrent()) setData(response)
    } catch (requestError) {
      if (request.isCurrent()) {
        setError(requestError instanceof ApiError ? requestError.message : '获取转账历史失败，请稍后重试')
      }
    } finally {
      if (request.isCurrent()) setLoading(false)
    }
  }, [beginRequest])

  const loadMore = useCallback(async () => {
    if (!data?.pagination.has_next || loadingMore || refreshing) return
    const request = beginRequest()
    setLoadingMore(true)
    setError('')
    try {
      const response = await loadMoreTransferHistory(data)
      if (request.isCurrent()) setData(response)
    } catch (requestError) {
      if (request.isCurrent()) {
        setError(requestError instanceof ApiError ? requestError.message : '加载更多记录失败，请稍后重试')
      }
    } finally {
      if (request.isCurrent()) setLoadingMore(false)
    }
  }, [beginRequest, data, loadingMore, refreshing])

  const refreshHistory = useCallback(async () => {
    const request = beginRequest()
    setRefreshing(true)
    setError('')
    try {
      const response = await syncTransferHistory()
      if (!request.isCurrent()) return
      setData(response)
      showToast('转账历史已同步')
    } catch (requestError) {
      if (request.isCurrent()) {
        setError(requestError instanceof ApiError ? requestError.message : '同步转账历史失败，请稍后重试')
      }
    } finally {
      if (request.isCurrent()) setRefreshing(false)
    }
  }, [beginRequest])

  useEffect(() => {
    void loadHistory()
  }, [loadHistory])

  const net = decimalOf(data?.net_amount || '0')
  const netLabel = '净转出'
  const netColor = net.isPositive()
    ? 'text-[#0ECB81]'
    : net.isNegative()
      ? 'text-[#F6465D]'
      : 'text-t-text'
  const accountTypeLabel = data?.account_type === 'sub'
    ? '子账户'
    : data?.account_type === 'master'
      ? '主账户'
      : '待同步'

  return (
    <div className="h-full min-h-0 flex flex-col overflow-hidden transition-colors bg-t-page text-t-text">
      <div
        className="shrink-0 px-4 pb-4 border-b transition-colors bg-t-surface border-t-border"
        style={{ paddingTop: standalone ? 'max(44px, env(safe-area-inset-top, 0px))' : 'env(safe-area-inset-top, 0px)' }}
      >
        <div className="h-11 flex items-center justify-center max-w-md mx-auto relative">
          <button
            type="button"
            onClick={() => navigate('/profile')}
            aria-label="返回我的"
            className="absolute left-0 flex h-9 w-9 items-center justify-center rounded-lg transition-colors hover:bg-t-surface-hover"
          >
            <ArrowLeft size={20} />
          </button>
          <h1 className="text-lg font-bold">转账历史</h1>
          <button
            type="button"
            onClick={() => void refreshHistory()}
            disabled={refreshing || loading || loadingMore}
            aria-label="刷新转账历史"
            title="刷新"
            className="absolute right-0 flex h-9 w-9 items-center justify-center rounded-lg text-t-text-secondary transition-colors hover:bg-t-surface-hover disabled:opacity-50"
          >
            <RefreshCw size={18} className={refreshing ? 'animate-spin' : ''} />
          </button>
        </div>
      </div>

      <div
        className="flex-1 min-h-0 overflow-y-scroll overscroll-contain hide-scrollbar bg-t-page"
        style={{ WebkitOverflowScrolling: 'touch', overscrollBehaviorY: 'contain', touchAction: 'pan-y' }}
      >
        <div className="max-w-md mx-auto w-full px-4 py-4 pb-[max(1rem,env(safe-area-inset-bottom,0px))]">
          {loading && !data ? (
            <LoadingState />
          ) : error && !data ? (
            <div className="flex min-h-[360px] flex-col items-center justify-center px-6 text-center">
              <div className="flex h-12 w-12 items-center justify-center rounded-full bg-[#F6465D]/10 text-[#F6465D]">
                <CircleAlert size={24} />
              </div>
              <p className="mt-4 text-sm leading-6 text-t-text-secondary">{error}</p>
              <button
                type="button"
                onClick={() => void loadHistory()}
                className="mt-5 rounded-lg bg-[#F0B90B] px-5 py-2.5 text-sm font-semibold text-black transition-colors hover:bg-[#D9A70A]"
              >
                重新加载
              </button>
            </div>
          ) : data ? (
            <>
              <section className="overflow-hidden rounded-2xl border border-t-border bg-t-surface shadow-sm dark:shadow-none">
                <div className="px-5 pb-5 pt-4">
                  <div className="flex items-center justify-between gap-3">
                    <span className="text-xs font-medium text-t-text-muted">{formatStartDate(data.start_at)}</span>
                    <div className="flex items-center gap-2">
                      {data.sync_status === 'error' ? (
                        <span className="rounded-full bg-[#F6465D]/10 px-2.5 py-1 text-[11px] font-medium text-[#F6465D]">
                          同步异常
                        </span>
                      ) : null}
                      <span className="rounded-full bg-t-surface-alt px-2.5 py-1 text-[11px] font-medium text-t-text-secondary">
                        {accountTypeLabel}
                      </span>
                    </div>
                  </div>
                  <p className="mt-5 text-sm font-medium text-t-text-secondary">{netLabel}</p>
                  <p className={`mt-1 break-all text-3xl font-bold leading-tight ${netColor}`}>
                    {formatAmount(data.net_amount, true)}
                  </p>
                </div>
                <div className="grid grid-cols-2 border-t border-t-border">
                  <div className="px-5 py-4">
                    <p className="text-xs text-t-text-muted">累计转出</p>
                    <p className="mt-1.5 break-all text-base font-semibold text-[#0ECB81]">
                      {formatAmount(data.outgoing_total)}
                    </p>
                  </div>
                  <div className="border-l border-t-border px-5 py-4">
                    <p className="text-xs text-t-text-muted">累计收到</p>
                    <p className="mt-1.5 break-all text-base font-semibold text-[#F0B90B]">
                      {formatAmount(data.incoming_total)}
                    </p>
                  </div>
                </div>
              </section>

              {error ? (
                <div className="mt-3 flex items-center justify-between gap-3 rounded-xl border border-[#F6465D]/25 bg-[#F6465D]/5 px-4 py-3">
                  <p className="min-w-0 text-xs text-[#F6465D]">{error}</p>
                  <button type="button" onClick={() => void refreshHistory()} className="shrink-0 text-xs font-semibold text-[#F6465D]">
                    重试
                  </button>
                </div>
              ) : null}

              <div className="mb-3 mt-5 flex items-center justify-between px-1">
                <h2 className="text-sm font-semibold text-t-text">历史记录</h2>
                <span className="text-xs text-t-text-muted">共 {data.pagination.total} 笔</span>
              </div>

              {data.records.length === 0 ? (
                <div className="flex min-h-[240px] flex-col items-center justify-center rounded-2xl border border-t-border bg-t-surface px-6 text-center">
                  <div className="flex h-12 w-12 items-center justify-center rounded-full bg-t-surface-alt text-t-text-muted">
                    <History size={23} />
                  </div>
                  <p className="mt-4 text-sm font-medium text-t-text">暂无转账记录</p>
                  <p className="mt-1 text-xs text-t-text-muted">{formatStartDate(data.start_at)}</p>
                </div>
              ) : (
                <div className="space-y-3">
                  {data.records.map(record => {
                    const outgoing = record.direction === 'outgoing'
                    const DirectionIcon = outgoing ? ArrowUpRight : ArrowDownLeft
                    return (
                      <article key={record.id} className="flex min-h-24 items-center gap-3 rounded-2xl border border-t-border bg-t-surface p-4">
                        <div
                          className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-xl ${
                            outgoing ? 'bg-[#0ECB81]/10 text-[#0ECB81]' : 'bg-[#F0B90B]/10 text-[#F0B90B]'
                          }`}
                        >
                          <DirectionIcon size={20} />
                        </div>
                        <div className="min-w-0 flex-1">
                          <p className="truncate text-sm font-medium text-t-text">{record.route}</p>
                          <p className="mt-1 truncate text-xs text-t-text-muted">
                            {formatDateTime(record.occurred_at)} · {record.channel}
                          </p>
                        </div>
                        <div className="max-w-[42%] shrink-0 text-right">
                          <p className={`break-all text-sm font-semibold ${outgoing ? 'text-[#0ECB81]' : 'text-[#F0B90B]'}`}>
                            {outgoing ? '+' : '-'}{formatAmount(record.amount)}
                          </p>
                          <p className="mt-1 text-[11px] text-t-text-muted">{outgoing ? '转出' : '收到'}</p>
                        </div>
                      </article>
                    )
                  })}
                  {data.pagination.has_next ? (
                    <button
                      type="button"
                      onClick={() => void loadMore()}
                      disabled={loadingMore || refreshing}
                      className="flex h-11 w-full items-center justify-center rounded-lg border border-t-border bg-t-surface text-sm font-medium text-t-text-secondary transition-colors hover:bg-t-surface-hover disabled:opacity-50"
                    >
                      {loadingMore ? '加载中...' : '加载更多'}
                    </button>
                  ) : null}
                </div>
              )}
            </>
          ) : null}
        </div>
      </div>
    </div>
  )
}
