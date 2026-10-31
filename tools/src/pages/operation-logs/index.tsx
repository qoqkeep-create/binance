import { ArrowLeft, CircleAlert, ClipboardList, RefreshCw } from 'lucide-react'
import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from 'react'
import { useNavigate } from 'react-router-dom'

import { ApiError } from '@/shared/lib/api'
import { isStandaloneMode } from '@/shared/lib/device'
import {
  getOperationLogScope,
  loadOperationLogs,
  mergeOperationLogs,
  subscribeOperationLogScope,
} from './data'
import type { OperationLog, OperationLogPage } from './data'

const sourceLabels: Record<OperationLog['source'], string> = {
  system: '系统', user: '手动', strategy: '策略', trade: '成交',
}
const statuses: Record<OperationLog['status'], { label: string; className: string }> = {
  success: { label: '已执行', className: 'bg-[#0ECB81]/10 text-[#0ECB81]' },
  pending: { label: '待确认', className: 'bg-[var(--t-brand)]/12 text-[var(--t-brand)]' },
  failed: { label: '失败', className: 'bg-[#F6465D]/10 text-[#F6465D]' },
  info: { label: '记录', className: 'bg-t-surface-alt text-t-text-secondary' },
}
const timeFormatter = new Intl.DateTimeFormat('zh-CN', {
  timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit',
  hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false,
})

function formatTime(value: string): string {
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? '--' : timeFormatter.format(date)
}

function canRefresh(): boolean {
  return document.visibilityState === 'visible' && navigator.onLine
}

function OperationLogFeed({ scope }: { scope: string }) {
  const navigate = useNavigate()
  const standalone = isStandaloneMode()
  const [data, setData] = useState<OperationLogPage | null>(null)
  const [loading, setLoading] = useState<'refresh' | 'more' | null>(null)
  const [error, setError] = useState('')
  const [active, setActive] = useState(canRefresh)
  const [loadedOlder, setLoadedOlder] = useState(false)
  const loadedOlderRef = useRef(false)
  const requestRef = useRef<AbortController | null>(null)

  const read = useCallback(async (kind: 'refresh' | 'more', cursor: string | null = null) => {
    if (!scope || !canRefresh() || requestRef.current) return
    const controller = new AbortController()
    requestRef.current = controller
    const isCurrent = () => !controller.signal.aborted
      && requestRef.current === controller && getOperationLogScope() === scope
    setLoading(kind)
    setError('')
    try {
      const response = await loadOperationLogs(cursor, controller.signal)
      if (!isCurrent()) return
      setData(previous => ({
        ...response,
        records: mergeOperationLogs(kind === 'more' ? previous?.records ?? [] : [], response.records),
      }))
      setLoadedOlder(kind === 'more')
      loadedOlderRef.current = kind === 'more'
    } catch (requestError) {
      if (isCurrent()) {
        setError(requestError instanceof ApiError ? requestError.message : '获取日志失败，请稍后重试')
      }
    } finally {
      if (requestRef.current === controller) {
        requestRef.current = null
        if (!controller.signal.aborted && getOperationLogScope() === scope) setLoading(null)
      }
    }
  }, [scope])

  useEffect(() => {
    const update = () => setActive(canRefresh())
    document.addEventListener('visibilitychange', update)
    window.addEventListener('online', update)
    window.addEventListener('offline', update)
    return () => {
      document.removeEventListener('visibilitychange', update)
      window.removeEventListener('online', update)
      window.removeEventListener('offline', update)
      requestRef.current?.abort()
      requestRef.current = null
    }
  }, [])

  useEffect(() => {
    if (active && !loadedOlderRef.current) void read('refresh')
  }, [active, read])

  useEffect(() => {
    if (!active || loadedOlder || !scope) return
    const timer = window.setInterval(() => void read('refresh'), 30_000)
    return () => window.clearInterval(timer)
  }, [active, loadedOlder, read, scope])

  return (
    <div className="h-full min-h-0 flex flex-col overflow-hidden bg-t-page text-t-text">
      <header
        className="shrink-0 border-b border-t-border bg-t-surface px-4"
        style={{ paddingTop: standalone ? 'max(44px, env(safe-area-inset-top, 0px))' : 'env(safe-area-inset-top, 0px)' }}
      >
        <div className="relative mx-auto flex h-14 max-w-md items-center justify-center">
          <button type="button" onClick={() => navigate('/profile')} aria-label="返回我的"
            className="absolute left-0 grid h-9 w-9 place-items-center rounded-lg hover:bg-t-surface-hover">
            <ArrowLeft size={20} />
          </button>
          <h1 className="text-lg font-bold">日志</h1>
          <button type="button" onClick={() => void read('refresh')} disabled={loading !== null || !active || !scope}
            aria-label="刷新日志" title="刷新"
            className="absolute right-0 grid h-9 w-9 place-items-center rounded-lg text-t-text-secondary hover:bg-t-surface-hover disabled:opacity-50">
            <RefreshCw size={18} className={loading === 'refresh' ? 'animate-spin' : ''} />
          </button>
        </div>
      </header>

      <main className="min-h-0 flex-1 overflow-y-auto overscroll-contain">
        <div className="mx-auto max-w-md px-4 py-4 pb-[max(1rem,env(safe-area-inset-bottom,0px))]">
          <p className="mb-3 text-xs text-t-text-muted">北京时间 · 最新记录在前</p>
          {!active && <p role="status" className="mb-3 text-sm text-t-text-muted">自动刷新已暂停，页面可见且联网后继续。</p>}
          {error && (
            <div role="alert" className="mb-4 rounded-xl border border-[#F6465D]/20 bg-[#F6465D]/5 p-3">
              <div className="flex items-start gap-2 text-sm text-[#F6465D]">
                <CircleAlert size={17} className="mt-0.5 shrink-0" />
                <p className="whitespace-pre-wrap break-words leading-6">{error}</p>
              </div>
              {data?.records.length ? <p className="mt-1 text-xs text-t-text-muted">已保留之前加载的日志。</p> : null}
              {!data && <button type="button" onClick={() => void read('refresh')} disabled={loading !== null || !active}
                className="mt-3 rounded-lg bg-[var(--t-brand)] px-4 py-2 text-sm font-medium text-black disabled:opacity-50">重新加载</button>}
            </div>
          )}
          {!data && loading && <div role="status" className="py-16 text-center text-sm text-t-text-muted">正在加载日志...</div>}
          {data?.records.length === 0 && <div className="grid justify-items-center gap-3 py-16 text-t-text-muted">
            <ClipboardList size={28} strokeWidth={1.5} />
            <p className="text-sm">暂无日志</p>
          </div>}
          {data && data.records.length > 0 && (
            <ol aria-label="交易操作日志" className="space-y-3">
              {data.records.map(record => {
                const status = statuses[record.status] ?? statuses.info
                return <li key={record.id} className="rounded-xl border border-t-border bg-t-surface p-4">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="font-semibold">{record.symbol}</span>
                    <span className={`text-xs ${record.side === 'long' ? 'text-[#0ECB81]' : 'text-[#F6465D]'}`}>{record.side === 'long' ? '多' : '空'}</span>
                    {record.position_origin === 'exchange_external' && <span className="rounded bg-[var(--t-brand)]/12 px-1.5 py-0.5 text-xs text-[var(--t-brand)]">手动仓</span>}
                    <span className={`ml-auto rounded px-2 py-0.5 text-xs ${status.className}`}>{status.label}</span>
                  </div>
                  <div className="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-xs text-t-text-muted">
                    <span>{sourceLabels[record.source] ?? '系统'}</span>
                    <span>仓位 #{record.order_id}</span>
                    <time dateTime={record.occurred_at}>{formatTime(record.occurred_at)}</time>
                  </div>
                  <p className="mt-3 whitespace-pre-wrap break-words text-sm leading-6 text-t-text-secondary">{record.message}</p>
                </li>
              })}
            </ol>
          )}
          {data?.has_more && data.next_cursor && <button type="button"
            onClick={() => void read('more', data.next_cursor)} disabled={loading !== null || !active}
            className="mt-4 w-full rounded-xl border border-t-border bg-t-surface py-3 text-sm text-t-text-secondary hover:bg-t-surface-hover disabled:opacity-50">
            {loading === 'more' ? '加载中...' : '加载更多'}
          </button>}
          {data && data.records.length > 0 && !data.has_more && <p className="pt-5 text-center text-xs text-t-text-muted">已显示全部日志</p>}
        </div>
      </main>
    </div>
  )
}

export function OperationLogsPage() {
  const scope = useSyncExternalStore(subscribeOperationLogScope, getOperationLogScope, () => '')
  return <OperationLogFeed key={scope} scope={scope} />
}
