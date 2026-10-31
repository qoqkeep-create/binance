import { ArrowLeft, Trash2, Edit2 } from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import { useNavigate, useLocation } from 'react-router-dom'
import { ConfirmModal } from '@/components/modals'
import { useAuthStore, useTradingStore, showToast } from '@/shared/store'
import type { StrategyLevel } from '@/shared/types'
import { isStandaloneMode } from '@/shared/lib/device'
import { api, ApiError } from '@/shared/lib/api'
import { formatStrategyLevelText } from '@/shared/lib/strategyText'
import {
  getAccountSessionRevision,
  isCurrentAccountRequestScope,
  isCurrentAccountSession,
} from '@/shared/lib/accountBalanceState'

// Re-export types for backward compat
export type { Strategy, StrategyLevel } from '@/shared/types'

export function StrategyManagementPage() {
  const standalone = isStandaloneMode()
  const navigate = useNavigate()
  const location = useLocation()
  const authUserId = useAuthStore(state => state.user?.id ?? '')
  const replaceStrategies = useTradingStore(s => s.replaceStrategies)
  const strategies = useTradingStore(s => s.strategies)
  const removeStrategy = useTradingStore(s => s.removeStrategy)
  const setActiveStrategy = useTradingStore(s => s.setActiveStrategy)

  const [showDeleteConfirm, setShowDeleteConfirm] = useState<string | null>(null)
  const [showSelectConfirm, setShowSelectConfirm] = useState<{ strategyName: string; strategyId: string } | null>(null)
  const listRequestIdRef = useRef(0)

  useEffect(() => {
    const requestUserId = authUserId
    const requestSessionRevision = getAccountSessionRevision()
    const requestId = ++listRequestIdRef.current
    const isCurrentRequest = () => isCurrentAccountRequestScope(
      requestUserId,
      useAuthStore.getState().user?.id ?? '',
      requestId,
      listRequestIdRef.current,
      requestSessionRevision,
      getAccountSessionRevision(),
    )
    const loadStrategies = async () => {
      try {
        const data = await api.get<Array<{
          id: number
          name: string
          is_active: boolean
          levels: StrategyLevel[]
        }>>('/strategy/list')
        if (!isCurrentRequest()) return
        const mapped = data.map((row) => ({
          id: String(row.id),
          name: row.name,
          levels: row.levels,
        }))
        replaceStrategies(mapped)
        const active = data.find((s) => s.is_active)
        if (active) setActiveStrategy(String(active.id))
      } catch {
        // 保持本地可用，不阻断页面
      }
    }
    loadStrategies()
    return () => {
      if (listRequestIdRef.current === requestId) listRequestIdRef.current += 1
    }
  }, [authUserId, replaceStrategies, setActiveStrategy])

  const handleDeleteConfirm = async (id: string) => {
    const requestUserId = authUserId
    const requestSessionRevision = getAccountSessionRevision()
    const isCurrentSession = () => isCurrentAccountSession(
      requestUserId,
      useAuthStore.getState().user?.id ?? '',
      requestSessionRevision,
      getAccountSessionRevision(),
    )
    try {
      await api.post('/strategy/delete', { strategy_id: Number(id) })
      if (!isCurrentSession()) return
      removeStrategy(id)
      showToast('删除成功')
    } catch (error) {
      const message = error instanceof ApiError ? error.message : '删除失败，请稍后重试'
      if (isCurrentSession()) showToast(message)
    }
    if (isCurrentSession()) setShowDeleteConfirm(null)
  }

  const handleSelectStrategy = (strategyName: string, strategyId: string) => {
    setShowSelectConfirm({ strategyName, strategyId })
  }

  const confirmSelectStrategy = async () => {
    if (!showSelectConfirm) return
    const requestUserId = authUserId
    const requestSessionRevision = getAccountSessionRevision()
    const isCurrentSession = () => isCurrentAccountSession(
      requestUserId,
      useAuthStore.getState().user?.id ?? '',
      requestSessionRevision,
      getAccountSessionRevision(),
    )
    try {
      await api.post('/strategy/set-active', { strategy_id: Number(showSelectConfirm.strategyId) })
      if (!isCurrentSession()) return
      setActiveStrategy(showSelectConfirm.strategyId)
    } catch (error) {
      const message = error instanceof ApiError ? error.message : '切换失败，请稍后重试'
      if (isCurrentSession()) showToast(message)
      return
    }
    if (!isCurrentSession()) return
    setShowSelectConfirm(null)
    const fromPage = (location.state as { from?: string } | null)?.from || '/trading'
    navigate(fromPage)
  }

  return (
    <div className="h-full min-h-0 flex flex-col overflow-hidden transition-colors bg-t-page text-t-text">
      {/* Header */}
      <div
        className="shrink-0 px-4 pb-4 border-b transition-colors bg-t-surface border-t-border"
        style={{ paddingTop: standalone ? 'max(44px, env(safe-area-inset-top, 0px))' : 'env(safe-area-inset-top, 0px)' }}
      >
        <div className="h-11 flex items-center justify-center max-w-md mx-auto relative">
          <button
            onClick={() => navigate('/profile')}
            className="absolute left-0 p-2 rounded-lg transition-colors hover:bg-t-surface-hover"
          >
            <ArrowLeft size={20} />
          </button>
          <h1 className="text-lg font-bold">我的策略</h1>
        </div>
      </div>

      {/* Content */}
      <div
        className="flex-1 min-h-0 overflow-y-scroll overscroll-contain hide-scrollbar bg-t-page"
        style={{
          WebkitOverflowScrolling: 'touch',
          overscrollBehaviorY: 'contain',
          touchAction: 'pan-y',
        }}
      >
        <div className="max-w-md mx-auto w-full px-4 py-4 space-y-4">
          {/* User Strategies */}
          {strategies.map((strategy) => (
            <div
              key={strategy.id}
              onClick={() => handleSelectStrategy(strategy.name, strategy.id)}
              className="rounded-2xl p-4 transition-colors cursor-pointer bg-t-surface border border-t-border hover:bg-t-surface-hover"
            >
              <div className="flex items-start justify-between mb-3">
                <h3 className="font-medium text-t-text">{strategy.name}</h3>
                <div className="flex gap-2" onClick={(e) => e.stopPropagation()}>
                  <button
                    onClick={() => setShowDeleteConfirm(strategy.id)}
                    className="p-1.5 rounded-lg transition-colors hover:bg-t-surface-hover"
                  >
                    <Trash2 size={16} className="text-[#F6465D]" />
                  </button>
                  <button
                    onClick={() => navigate(`/strategy-management/edit/${strategy.id}`)}
                    className="p-1.5 rounded-lg transition-colors hover:bg-t-surface-hover"
                  >
                    <Edit2 size={16} className="text-t-text-secondary" />
                  </button>
                </div>
              </div>
              <div className="space-y-1.5 text-sm text-t-text-secondary">
                {strategy.levels.map((level, index) => (
                  <div key={index}>{formatStrategyLevelText(level, index)}</div>
                ))}
              </div>
            </div>
          ))}

          {/* New Strategy Button */}
          <button
            onClick={() => navigate('/strategy-management/edit')}
            className="w-full py-3.5 rounded-xl font-medium bg-gradient-to-r from-[#F0B90B] to-[#D9A70A] text-black hover:shadow-lg hover:shadow-[#F0B90B]/30 transition-all active:scale-[0.98]"
          >
            新建策略
          </button>
        </div>
      </div>

      {/* Delete Confirmation */}
      <ConfirmModal
        isOpen={!!showDeleteConfirm}
        onClose={() => setShowDeleteConfirm(null)}
        onConfirm={() => showDeleteConfirm && handleDeleteConfirm(showDeleteConfirm)}
        title="确认删除"
        confirmText="删除"
        confirmVariant="danger"
      >
        确定要删除这个策略吗？
      </ConfirmModal>

      {/* Select Strategy Confirmation */}
      <ConfirmModal
        isOpen={!!showSelectConfirm}
        onClose={() => setShowSelectConfirm(null)}
        onConfirm={confirmSelectStrategy}
        title="确认选择策略"
        confirmText="确认选择"
      >
        确定要选择策略 <strong>{showSelectConfirm?.strategyName}</strong> 吗？
      </ConfirmModal>
    </div>
  )
}
