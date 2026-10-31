import { AlertTriangle, ArrowRight, CheckCircle2, Loader2, Mail, WalletCards, X } from 'lucide-react'
import { useModalAccessibility } from './useModalAccessibility'

export type CapitalStatus = 'not_required' | 'blocked' | 'ready' | 'normalization_required' | 'shortfall' | 'collection_pending'

export interface CapitalState {
  status: CapitalStatus
  reason?: string
  target?: string
  upper_limit?: string
  futures_balance?: string
  futures_available?: string
  funding_available?: string
  spot_available?: string
  shortfall?: string
  internal_available?: string
  remaining_after_transfer?: string
  transfer_amount?: string
  base_target?: string
  refill_trigger?: string
  refill_required?: string
  minimum_refill_required?: string
  minimum_refill_remaining?: string
  funding_to_futures?: string
  spot_to_futures?: string
  futures_collect?: string
  funding_collect?: string
  spot_collect?: string
  collection_total?: string
  recommended_topup?: string
  account_total?: string
  usable_total?: string
  email_subject?: string
  email_body?: string
  reminder_sent?: boolean
  collection_id?: number
  collection_error?: string
  collection_created_at?: string
  completed_steps?: string[]
  plan_changed?: boolean
  plan_token?: string
  transfer_path?: 'master_address' | 'sub_to_master' | 'internal_only'
  destination_address?: string
  destination_network?: string
  settlement_method?: 'internal' | 'onchain' | ''
  minimum_open_balance?: string
  maximum_futures_balance?: string
  minimum_topup?: string
  maximum_topup?: string
  pending_collection?: CapitalState
}

interface CapitalReminderModalProps {
  isOpen: boolean
  state: CapitalState | null
  loading: boolean
  onClose: () => void
  onSend: () => void
}

interface CapitalNormalizationModalProps {
  isOpen: boolean
  state: CapitalState | null
  loading: boolean
  following?: boolean
  onClose: () => void
  onNormalize: () => void
  onContinue: () => void
  onRemind?: () => void
  mode?: 'entry' | 'manual_sweep'
}

function amount(value?: string) {
  const parsed = Number(value || 0)
  return Number.isFinite(parsed) ? `${parsed.toFixed(2)} U` : '--'
}

export function CapitalNormalizationModal({
  isOpen,
  state,
  loading,
  following = false,
  onClose,
  onNormalize,
  onContinue,
  onRemind,
  mode = 'entry',
}: CapitalNormalizationModalProps) {
  const { dialogProps, titleId } = useModalAccessibility(isOpen && Boolean(state), onClose, loading)
  if (!isOpen || !state) return null

  const isReady = state.status === 'ready'
  const isBlocked = state.status === 'blocked'
  const isNormalizationRequired = state.status === 'normalization_required'
  // 待确认流水不再阻塞开仓：预检时以嵌套字段透出，确认流程返回时仍是顶层状态。
  const sweepInfo = state.status === 'collection_pending' ? state : state.pending_collection
  const isCollectionPending = Boolean(sweepInfo)
  const collectSource = isCollectionPending && sweepInfo ? sweepInfo : state
  const isCollectionCompleted = state.reason === 'normalization_completed'
  const hasRemainingShortfall = Number(state.minimum_refill_remaining || state.remaining_after_transfer || 0) > 0
  const isManualSweep = mode === 'manual_sweep'
  const title = isCollectionPending ? following ? '资金调整中' : '确认归集结果'
    : isCollectionCompleted ? '资金调整完成'
    : isReady
      ? isManualSweep ? '无需归集' : '资金检查完成'
      : isBlocked ? isManualSweep ? '暂时无法归集' : '暂时无法开仓'
        : isNormalizationRequired ? '调整账户资金'
          : isManualSweep ? '暂时无法归集' : '补充合约资金'
  const blockedText = state.reason === 'active_position'
    ? '交易所当前存在真实持仓。持仓期间资金作为保证金使用，不能执行余额归集。'
    : state.reason === 'capital_sweep_binding_mismatch'
      ? '检测到旧 API 绑定留下的未确认资金流水。为避免使用当前 API 重复划转，系统已停止继续执行；请先人工核对该流水。'
      : isManualSweep
        ? '交易所仍有未成交的普通挂单或条件单。请先处理挂单，再执行余额归集。'
        : '交易所仍有未成交的普通挂单或条件单。请先处理挂单，再开始新的交易周期。'
  const showPrimaryAction = isCollectionPending || isNormalizationRequired || (!isManualSweep && !isCollectionCompleted && (isReady || state.status === 'shortfall'))

  return (
    <div className="fixed inset-0 z-[70] flex items-center justify-center p-4">
      <div aria-hidden="true" className="absolute inset-0 bg-black/60 backdrop-blur-sm" onClick={loading ? undefined : onClose} />
      <div {...dialogProps} className="relative max-h-[85vh] w-full max-w-sm overflow-y-auto rounded-lg bg-[#1A1D23] shadow-2xl">
        <div className="flex items-center justify-between border-b border-white/10 px-5 py-4">
          <div className="flex items-center gap-3">
            {isReady || isCollectionCompleted ? <CheckCircle2 className="text-[#0ECB81]" size={22} /> : isBlocked ? <AlertTriangle className="text-[#F6465D]" size={22} /> : <WalletCards className="text-[#F0B90B]" size={22} />}
            <h2 id={titleId} className="text-base font-bold text-white">{title}</h2>
          </div>
          <button aria-label="关闭" onClick={onClose} disabled={loading} className="p-2 text-gray-400 hover:text-white disabled:opacity-50">
            <X size={19} />
          </button>
        </div>

        <div className="space-y-4 p-5">
          {isBlocked && <p className="text-sm leading-6 text-gray-300">{blockedText}</p>}

          {isReady && (
            <p className="text-sm leading-6 text-gray-300">
              {isCollectionCompleted
                ? Number(state.transfer_amount || 0) > 0
                  ? state.settlement_method === 'onchain'
                    ? '本次资金调整已完成，Binance 已通过所选网络转出；到账金额和手续费请以目标账户为准。'
                    : '本次资金调整已完成，多余资金已转入目标主账户的现货账户。'
                  : '本次资金调整已完成，其他钱包的可用资金已补入合约账户。'
                : isManualSweep
                ? '当前没有超过保留上限的可归集资金。'
                : '合约账户余额已处于 1.5 倍至 5 倍止损额的可开仓区间。继续后才会正式提交开仓，请确认交易参数未发生变化。'}
            </p>
          )}

          {isCollectionCompleted && !isReady && (
            <p className="text-sm leading-6 text-gray-300">
              可用资金已尽量补入合约账户，但仍未达到开仓最低线。请发送补资提醒后再开仓。
            </p>
          )}

          {(isNormalizationRequired || isCollectionPending || state.status === 'shortfall' || isReady) && (
            <div className="divide-y divide-white/10 border-y border-white/10 text-sm">
              <Row label="开仓最低线" value={amount(state.minimum_open_balance || state.refill_trigger)} />
              <Row label="合约最高保留" value={amount(state.maximum_futures_balance || state.upper_limit || state.target)} />
              {state.futures_balance !== undefined && <Row label="合约余额" value={amount(state.futures_balance)} />}
              {(isNormalizationRequired || isCollectionPending || isCollectionCompleted) && Number(collectSource.funding_to_futures || 0) > 0 && (
                <DirectionRow
                  label="资金 -> 合约"
                  value={amount(collectSource.funding_to_futures)}
                  completed={isCollectionCompleted || collectSource.completed_steps?.includes('funding_to_futures')}
                />
              )}
              {(isNormalizationRequired || isCollectionPending || isCollectionCompleted) && Number(collectSource.spot_to_futures || 0) > 0 && (
                <DirectionRow
                  label="现货 -> 合约"
                  value={amount(collectSource.spot_to_futures)}
                  completed={isCollectionCompleted || collectSource.completed_steps?.includes('spot_to_futures')}
                />
              )}
              {(isNormalizationRequired || isCollectionPending || isCollectionCompleted) && Number(collectSource.futures_collect || 0) > 0 && (
                <DirectionRow
                  label="合约 -> 现货"
                  value={amount(collectSource.futures_collect)}
                  completed={isCollectionCompleted || collectSource.completed_steps?.includes('futures_collect')}
                />
              )}
              {(isNormalizationRequired || isCollectionPending || isCollectionCompleted) && Number(collectSource.funding_collect || 0) > 0 && (
                <DirectionRow
                  label="资金 -> 现货"
                  value={amount(collectSource.funding_collect)}
                  completed={isCollectionCompleted || collectSource.completed_steps?.includes('funding_collect')}
                />
              )}
              {(isNormalizationRequired || isCollectionPending || isCollectionCompleted) && Number(collectSource.transfer_amount || 0) > 0 && (
                <DirectionRow
                  label="现货 -> 主账户"
                  value={amount(collectSource.transfer_amount)}
                  highlight
                  completed={isCollectionCompleted || collectSource.completed_steps?.includes('transfer_amount')}
                />
              )}
              {collectSource.destination_address && <Row label="目标 Spot 地址" value={`${collectSource.destination_address}${collectSource.destination_network ? ` (${collectSource.destination_network})` : ''}`} />}
              {(state.status === 'shortfall' || hasRemainingShortfall) && (
                <>
                  <Row label="账户总余额" value={amount(state.account_total)} />
                  <Row label="资金账户可用" value={amount(state.funding_available)} />
                  <Row label="现货账户可用" value={amount(state.spot_available)} />
                  <Row label="本次最多转入" value={amount(state.internal_available)} highlight />
                  <Row label="转入后仍缺" value={amount(state.remaining_after_transfer)} danger={Number(state.remaining_after_transfer || 0) > 0} />
                  <Row label="至少补充" value={amount(state.minimum_topup || state.remaining_after_transfer)} highlight />
                  <Row label="最多补充" value={amount(state.maximum_topup)} highlight />
                  <Row label="建议主账户转入" value={amount(state.recommended_topup)} highlight />
                </>
              )}
            </div>
          )}

          {isNormalizationRequired && <p className="text-xs leading-5 text-gray-400">{isManualSweep
            ? '确认后按上方计划保留合约资金，将超额部分转出；合约不足保留上限时，先从其他钱包补足。结果未确认前不会重复转账。'
            : '确认后系统会先用资金账户、现货账户尽量把合约补到 5 倍止损额；资金不足时按实际可用金额补入。只有合约高于 5 倍或补入后仍有可归集余额，才会继续转出。每一步都会先记录再执行，结果未确认前不会重复提交。'}</p>}
          {state.plan_changed && <p className="text-xs leading-5 text-[#F0B90B]">余额或止损设置已变化。已完成的步骤保留，上方为重新计算的剩余计划，请确认后执行。</p>}
          {isCollectionPending && <p className="text-xs leading-5 text-[#F0B90B]">{sweepInfo?.collection_error || '交易所划转结果正在确认，可重新确认结果。归集确认不影响开仓判定。'}</p>}
          {isCollectionPending && state.pending_collection && Number(state.futures_collect || 0) > 0 && state.futures_collect !== sweepInfo?.futures_collect && (
            <p className="text-xs leading-5 text-gray-400">上方为上一笔归集。当前余额另有 合约 -&gt; 现货 {amount(state.futures_collect)}，需先确认上一笔结果，再按最新余额重新确认；不会并入旧流水自动转出。</p>
          )}
          {following && <p role="status" className="text-xs leading-5 text-gray-400">正在自动跟进同一笔归集，确认到账后继续下一步。关闭面板会停止后续跟进，已提交的转账仍以交易所结果为准。</p>}
          {!isManualSweep && state.status === 'shortfall' && <p className="text-xs leading-5 text-gray-400">点击“发送提醒”后，系统会邮件通知账户持有人，将建议金额转入该交易账户的资金账户。建议金额已按整 U 向上取整。</p>}
          {isManualSweep && state.status === 'shortfall' && !isCollectionCompleted && <p className="text-sm leading-6 text-gray-300">当前没有可继续补入合约的资金。请至少补充 {amount(state.minimum_topup || state.remaining_after_transfer)}，最多补充 {amount(state.maximum_topup)}。</p>}

          <div className="flex gap-3 pt-1">
            <button data-modal-autofocus onClick={onClose} disabled={loading} className="flex-1 rounded-lg bg-[#2B2F36] py-3 font-medium text-white hover:bg-[#35393F] disabled:opacity-50">
              {isBlocked || isReady || (isManualSweep && state.status === 'shortfall') ? '知道了' : '取消'}
            </button>
            {showPrimaryAction && (
              <button
                onClick={isCollectionPending ? onNormalize : isReady ? onContinue : state.status === 'shortfall' ? onRemind : onNormalize}
                disabled={loading || following}
                className="flex flex-1 items-center justify-center gap-2 rounded-lg bg-[#F0B90B] py-3 font-bold text-black hover:bg-[#D9A70A] disabled:opacity-60"
              >
                {loading ? <Loader2 size={18} className="animate-spin" /> : <ArrowRight size={18} />}
                {loading ? '处理中...' : following ? '自动确认中...' : isCollectionPending ? '重新确认结果' : isReady ? '继续开仓' : isNormalizationRequired ? '确认调整' : '发送提醒'}
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  )
}

export function CapitalReminderModal({
  isOpen,
  state,
  loading,
  onClose,
  onSend,
}: CapitalReminderModalProps) {
  const { dialogProps, titleId } = useModalAccessibility(isOpen && Boolean(state), onClose, loading)
  if (!isOpen || !state) return null

  return (
    <div className="fixed inset-0 z-[75] flex items-center justify-center p-4">
      <div aria-hidden="true" className="absolute inset-0 bg-black/60 backdrop-blur-sm" onClick={loading ? undefined : onClose} />
      <div {...dialogProps} className="relative max-h-[85vh] w-full max-w-sm overflow-y-auto rounded-lg bg-[#1A1D23] shadow-2xl">
        <div className="flex items-center justify-between border-b border-white/10 px-5 py-4">
          <div className="flex items-center gap-3">
            <Mail className="text-[#F0B90B]" size={22} />
            <h2 id={titleId} className="text-base font-bold text-white">补资提醒预览</h2>
          </div>
          <button aria-label="关闭" onClick={onClose} disabled={loading} className="p-2 text-gray-400 hover:text-white disabled:opacity-50">
            <X size={19} />
          </button>
        </div>

        <div className="space-y-4 p-5">
          <div className="divide-y divide-white/10 border-y border-white/10 text-sm">
            <Row label="账户总余额" value={amount(state.account_total)} />
            <Row label="开仓最低线" value={amount(state.minimum_open_balance || state.refill_trigger)} />
            <Row label="补资上限" value={amount(state.maximum_futures_balance || state.target)} />
            <Row label="至少补充" value={amount(state.minimum_topup || state.remaining_after_transfer)} danger />
            <Row label="最多补充" value={amount(state.maximum_topup)} highlight />
            <Row label="建议转入" value={amount(state.recommended_topup)} highlight />
          </div>

          <div className="space-y-2">
            <div className="text-xs text-gray-500">邮件标题</div>
            <div className="rounded-md bg-black/20 px-3 py-2 text-sm leading-5 text-gray-200">{state.email_subject}</div>
          </div>
          <div className="space-y-2">
            <div className="text-xs text-gray-500">邮件正文</div>
            <div className="whitespace-pre-wrap rounded-md bg-black/20 px-3 py-3 text-sm leading-6 text-gray-300">{state.email_body}</div>
          </div>

          <div className="flex gap-3 pt-1">
            <button data-modal-autofocus onClick={onClose} disabled={loading} className="flex-1 rounded-lg bg-[#2B2F36] py-3 font-medium text-white hover:bg-[#35393F] disabled:opacity-50">
              取消
            </button>
            <button onClick={onSend} disabled={loading} className="flex flex-1 items-center justify-center gap-2 rounded-lg bg-[#F0B90B] py-3 font-bold text-black hover:bg-[#D9A70A] disabled:opacity-60">
              {loading ? <Loader2 size={18} className="animate-spin" /> : <Mail size={18} />}
              {loading ? '发送中...' : '发送通知'}
            </button>
          </div>
        </div>
      </div>
    </div>
  )
}

function Row({ label, value, highlight = false, danger = false }: { label: string; value: string; highlight?: boolean; danger?: boolean }) {
  return (
    <div className="flex items-center justify-between py-3">
      <span className="text-gray-400">{label}</span>
      <span className={`max-w-[68%] break-all text-right ${danger ? 'font-medium text-[#F6465D]' : highlight ? 'font-medium text-[#F0B90B]' : 'font-medium text-white'}`}>{value}</span>
    </div>
  )
}

function DirectionRow({
  label,
  value,
  highlight = false,
  completed = false,
}: {
  label: string
  value: string
  highlight?: boolean
  completed?: boolean
}) {
  return (
    <div className="flex items-center justify-between py-3">
      <span className="flex items-center gap-1.5 text-gray-400">
        {label}
        {completed && <CheckCircle2 aria-label="已完成" className="text-[#0ECB81]" size={15} />}
      </span>
      <span className={`max-w-[68%] break-all text-right ${highlight ? 'font-medium text-[#F0B90B]' : 'font-medium text-white'}`}>{value}</span>
    </div>
  )
}
