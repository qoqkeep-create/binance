import { api } from '@/shared/lib/api'
import { showToast } from '@/shared/store'
import Decimal from 'decimal.js'

type ManualEntryPurpose = 'entry' | 'chase'
const MIN_TRANSFERABLE_WALLET_BALANCE = 1

interface CapitalControlInput {
  thresholdLoaded: boolean
  futuresBalance: number | null
  fundingBalance: number | null
  spotBalance: number | null
  openingMinimum: number
  retentionMaximum: number
}

export function getCapitalControlAvailability({
  thresholdLoaded,
  futuresBalance,
  fundingBalance,
  spotBalance,
  openingMinimum,
  retentionMaximum,
}: CapitalControlInput) {
  const balancesKnown = futuresBalance !== null && fundingBalance !== null && spotBalance !== null
  if (!thresholdLoaded || !balancesKnown
    || ![futuresBalance, fundingBalance, spotBalance, openingMinimum, retentionMaximum].every(Number.isFinite)
    || openingMinimum <= 0 || retentionMaximum < openingMinimum) {
    return { collectionEnabled: false, reminderEnabled: false }
  }

  const usableTotal = new Decimal(futuresBalance)
    .plus(fundingBalance >= MIN_TRANSFERABLE_WALLET_BALANCE ? fundingBalance : 0)
    .plus(spotBalance >= MIN_TRANSFERABLE_WALLET_BALANCE ? spotBalance : 0)
  return {
    collectionEnabled: usableTotal.minus(retentionMaximum).gte('0.01'),
    reminderEnabled: usableTotal.lt(openingMinimum),
  }
}

interface EntryCapitalState {
  message?: string
  status: 'not_required' | 'blocked' | 'ready' | 'normalization_required' | 'shortfall' | 'collection_pending'
  reason?: string
  minimum_topup?: string
  maximum_topup?: string
  remaining_after_transfer?: string
  shortfall?: string
}

function blockedMessage(state: EntryCapitalState): string {
  if (state.message) return state.message
  if (state.reason === 'open_exchange_orders') {
    return '交易所仍有未成交挂单，请先处理挂单'
  }
  if (state.status === 'normalization_required') {
    return state.reason === 'futures_below_open_minimum'
      ? '合约余额低于开仓最低线，请先在币安将可用资金补入合约账户'
      : '合约余额超过 5 倍止损额，请先在账户页归集超额资金'
  }
  if (state.status === 'shortfall') {
    const minimum = state.minimum_topup || state.remaining_after_transfer || state.shortfall || '--'
    return `开仓资金不足，至少还需补充 ${minimum} USDT，最多可补充 ${state.maximum_topup || '--'} USDT`
  }
  return '当前资金状态不满足开仓条件，请到账户页处理'
}

export async function ensureManualEntryCapitalReady(purpose: ManualEntryPurpose = 'entry'): Promise<boolean> {
  try {
    const state = await api.post<EntryCapitalState>('/trade/capital/precheck', { purpose })
    if (state.status === 'not_required' || state.status === 'ready') return true
    showToast(blockedMessage(state))
  } catch (error) {
    showToast(error instanceof Error ? error.message : '资金检查失败，请稍后重试')
  }
  return false
}
